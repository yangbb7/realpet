import Combine
import Foundation
import SwiftUI

@MainActor
class PetListViewModel: ObservableObject {
    @Published var pets: [Pet] = []
    @Published private(set) var activeActionImport: ActiveActionImport?
    @Published private(set) var actionLibraryRevision = 0
    @Published private(set) var validatingActionPetId: UUID?
    @Published private(set) var preparingActionPetId: UUID?
    @Published var showPetImageManager = false
    @Published private(set) var pendingActionReview: PendingActionReview?
    /// The pet whose action composer is currently expanded in the main console.
    @Published var motionComposerPet: Pet?
    @Published private(set) var selectedMotionAction: FixedPetAction = .headFollow
    @Published private(set) var generatingMotionAction: FixedPetAction?
    @Published private(set) var motionWorkflowState: MotionWorkflowState = .idle
    @Published private(set) var motionServiceConfiguration: MotionServiceConfiguration
    @Published private(set) var assetProfile: PetAssetProfile
    @Published private(set) var recoverableMotionJobs: [MotionGenerationJob] = []
    /// Preview files are expendable cache entries. Owner photos themselves
    /// live only in the signed-in user's private cloud gallery.
    @Published private(set) var cloudReferencePreviewURLs: [UUID: URL] = [:]
    @Published private(set) var isSynchronizingCloudGallery = false
    @Published private(set) var cloudAccountIsReady = false
    @Published private(set) var cloudGalleryError: String?
    @Published private(set) var queuedActionPackRemainingCount = 0

    let pythonBridge = PythonBridge()
    let petLauncher = PetLauncher()

    /// The app delegate supplies the first-use venv UI. Keeping this at the
    /// application boundary lets the signed-in console open immediately.
    var requestPipelineSetup: (((@escaping (String?) -> Void) -> Void))?

    private var generatedInitialPetId: UUID?
    private var motionGenerationTask: Task<Void, Never>?
    private var activeMotionJobID: UUID?
    private let motionJobStore = MotionGenerationJobStore.shared
    private var activeCloudOwnerID: UUID?
    private var cloudGalleryTask: Task<Void, Never>?
    private var pendingLegacyPets: [Pet] = []
    private var preparationStartedAt: [UUID: Date] = [:]
    private var pipelineSetupInProgress = false
    private var deferredPreparation: DeferredPreparation?
    private var actionPackPetID: UUID?
    private var actionPackQueue: [FixedPetAction] = []

    var pet: Pet? { pets.first }

    struct ActiveActionImport: Equatable {
        let petId: UUID
        let kind: PetActionManifest.Action.Kind
        let actionID: String
        let displayNameOverride: String?
        let rootFramesDirectory: String
        let workDirectory: String
        let sourceVideoPath: String?
        let origin: PetActionManifest.Action.Origin
    }

    struct PendingActionReview: Identifiable, Equatable {
        let id: UUID
        let petId: UUID
        let kind: PetActionManifest.Action.Kind
        let actionID: String
        let displayName: String
        let framesDirectory: String
        let frameCount: Int
        let fps: Int
        let identitySimilarity: Double?
        let origin: PetActionManifest.Action.Origin
    }

    private struct StagedGeneratedMotionVideo {
        let petID: UUID
        let kind: PetActionManifest.Action.Kind
        let rootFramesDirectory: String?
        let workDirectory: String
        let videoURL: URL
    }

    private struct GeneratedRemoteMotionVideo {
        let remoteJobID: String
        let localJobID: UUID
        let data: Data
    }

    private struct DeferredPreparation {
        let petID: UUID
        let videoPath: String
        let outputDirectory: String
    }

    struct ClipChoice {
        let start: Double
        let duration: Double
        let score: Double
        let recommended: Bool
    }

    init() {
        motionServiceConfiguration = MotionServiceConfigurationStore.load()
        assetProfile = PetAssetProfileStore.load()
        let storedPets: [Pet]
        do {
            storedPets = try PetStorage.shared.load()
        } catch {
            storedPets = []
            pythonBridge.error = error.localizedDescription
        }
        let recovery = Pet.recoveringAfterLaunch(storedPets)
        var recoveredPets = recovery.pets
        var referenceImagesChanged = false
        for index in recoveredPets.indices {
            let localReferences = recoveredPets[index].referenceImages
            let limitedLocalReferences = Array(localReferences.prefix(
                PetImageLibraryPolicy.maximumImageCount))
            let cloudReferences = recoveredPets[index].cloudReferences
            let limitedCloudReferences = Array(cloudReferences.prefix(
                PetImageLibraryPolicy.maximumImageCount))
            if limitedLocalReferences.count != localReferences.count {
                recoveredPets[index].referenceImagePaths = limitedLocalReferences
                referenceImagesChanged = true
            }
            if limitedCloudReferences.count != cloudReferences.count {
                recoveredPets[index].cloudReferenceImages = limitedCloudReferences
                referenceImagesChanged = true
            }
        }
        pets = recoveredPets
        if recovery.changed || referenceImagesChanged {
            persistPets()
        }
        for pet in pets {
            guard let framesDir = pet.framesDir else { continue }
            do {
                try PetActionLibrary.recoverInterruptedInstall(
                    rootFramesDirectory: URL(fileURLWithPath: framesDir))
                if try PetActionLibrary.deduplicateGeneratedOrbitFrames(
                    rootFramesDirectory: URL(fileURLWithPath: framesDir)) {
                    actionLibraryRevision += 1
                }
            } catch {
                pythonBridge.error = "无法恢复动作安装：\(error.localizedDescription)"
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(onProcessingComplete(_:)),
            name: .processingComplete, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onPetStopped(_:)),
            name: .petStopped, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onSegmentationPoor(_:)),
            name: .segmentationPoor, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onProcessingFailed(_:)),
            name: .processingFailed, object: nil
        )
        loadRecoverableMotionJobs()
    }

    private func loadRecoverableMotionJobs() {
        do {
            recoverableMotionJobs = try motionJobStore.load()
        } catch {
            recoverableMotionJobs = []
            motionWorkflowState = .failed("无法恢复未完成的视频任务：\(error.localizedDescription)")
        }
    }

    @discardableResult
    private func persistMotionJob(_ job: MotionGenerationJob) throws -> MotionGenerationJob {
        var updated = job
        updated.updatedAt = Date()
        try motionJobStore.upsert(updated)
        if let index = recoverableMotionJobs.firstIndex(where: { $0.id == updated.id }) {
            recoverableMotionJobs[index] = updated
        } else {
            recoverableMotionJobs.append(updated)
        }
        return updated
    }

    private func removeMotionJob(_ id: UUID) {
        do {
            try motionJobStore.remove(id: id)
            recoverableMotionJobs.removeAll { $0.id == id }
        } catch {
            motionWorkflowState = .failed("视频已生成，但无法清理任务记录：\(error.localizedDescription)")
        }
    }

    private func markMotionJob(
        _ id: UUID,
        state: MotionGenerationJob.State,
        failureMessage: String? = nil
    ) {
        guard let existing = recoverableMotionJobs.first(where: { $0.id == id }) else { return }
        var updated = existing
        updated.state = state
        updated.failureMessage = failureMessage
        _ = try? persistMotionJob(updated)
    }

    private func cancelPersistedMotionJob(_ id: UUID) {
        guard let job = recoverableMotionJobs.first(where: { $0.id == id }) else { return }
        // A task without a provider ID was never submitted, so retaining it
        // cannot produce a recoverable result after relaunch.
        guard job.remoteJobID != nil else {
            removeMotionJob(id)
            return
        }
        markMotionJob(id, state: .cancelledLocally)
    }

    private func resumeMotionGeneration(_ job: MotionGenerationJob) async {
        guard !motionWorkflowState.isBusy,
              let pet = pets.first(where: { $0.id == job.petID }),
              let remoteJobID = job.remoteJobID else { return }
        selectedMotionAction = job.action
        generatingMotionAction = job.action
        activeMotionJobID = job.id
        motionWorkflowState = .waitingForVideo(provider: job.provider, progress: nil)
        do {
            guard job.provider != .legacyAgnes else {
                throw SupabaseMiniMaxVideoGatewayError.failed(
                    "旧版直连视频任务无法恢复，请重新生成")
            }
            let (storageConfiguration, storageCredentials) = try await cloudStorageAccess()
            let client = SupabaseMiniMaxVideoGatewayClient()
            var remote = try await client.retrieve(
                id: remoteJobID,
                configuration: storageConfiguration,
                credentials: storageCredentials)
            while remote.status == .queued || remote.status == .processing {
                try await Task.sleep(for: .seconds(5))
                remote = try await client.retrieve(
                    id: remoteJobID,
                    configuration: storageConfiguration,
                    credentials: storageCredentials)
            }
            guard remote.status == .completed else {
                throw SupabaseMiniMaxVideoGatewayError.failed("恢复的 MiniMax 任务未成功完成")
            }
            markMotionJob(job.id, state: .downloading)
            let data = try await client.downloadContent(job: remote)
            let staged = try stageGeneratedMotionVideo(
                data: data, for: pet, kind: job.action.kind, jobID: remoteJobID)
            try startGeneratedActionImport(staged)
            removeMotionJob(job.id)
            activeMotionJobID = nil
        } catch {
            markMotionJob(job.id, state: .failed, failureMessage: error.localizedDescription)
            activeMotionJobID = nil
            generatingMotionAction = nil
            motionWorkflowState = .failed("恢复视频任务失败：\(error.localizedDescription)")
        }
    }

    func recoverableMotionJob(for pet: Pet) -> MotionGenerationJob? {
        recoverableMotionJobs
            .filter { $0.petID == pet.id && $0.remoteJobID != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    func resumeMotionGenerationJob(_ job: MotionGenerationJob) {
        guard !motionWorkflowState.isBusy,
              job.remoteJobID != nil,
              job.state != .failed else { return }
        markMotionJob(job.id, state: .submitted)
        Task { [weak self] in
            await self?.resumeMotionGeneration(job)
        }
    }

    func discardMotionGenerationJob(_ job: MotionGenerationJob) {
        guard !motionWorkflowState.isBusy else { return }
        removeMotionJob(job.id)
    }

    var hasActiveWorkflow: Bool {
        motionWorkflowState.isBusy
            || activeActionImport != nil
            || pythonBridge.isProcessing
            || pets.contains {
                $0.status == .detecting
                    || $0.status == .detected
                    || $0.status == .processing
            }
    }

    /// A pet record is required for every motion task. If an old task is left
    /// behind after its pet was removed, it must not permanently disable the
    /// two import entry points on the empty start screen.
    var canImportPetMedia: Bool {
        guard cloudAccountIsReady else { return false }
        guard pets.isEmpty else {
            return !hasActiveWorkflow && !isSynchronizingCloudGallery
        }
        return activeActionImport == nil
            && !pythonBridge.isProcessing
            && !isSynchronizingCloudGallery
    }

    private func clearOrphanedMotionWorkflowBeforeImport() {
        guard pets.isEmpty, motionWorkflowState.isBusy else { return }
        cancelMotionGeneration()
    }

    func importCustomActionVideo(url: URL, named name: String) {
        guard !hasActiveWorkflow else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        guard let currentPet = pet,
              let rootFramesDirectory = currentPet.framesDir else {
            pythonBridge.error = "请先完成头部跟随，再导入自定义动作"
            return
        }
        let displayName = String(name.trimmingCharacters(
            in: .whitespacesAndNewlines).prefix(40))
        guard !displayName.isEmpty else {
            pythonBridge.error = "请填写自定义动作名称"
            return
        }
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let actionID = "custom-\(UUID().uuidString.lowercased())"
        let workDirectory = PetStorage.shared.petDirectory(for: currentPet.id)
            .appendingPathComponent("custom-action-imports")
            .appendingPathComponent(actionID)
        try? FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: true)
        let extensionName = url.pathExtension.isEmpty
            ? "mp4" : url.pathExtension.lowercased()
        let sourceVideo = workDirectory.appendingPathComponent("source.\(extensionName)")
        do {
            try FileManager.default.copyItem(at: url, to: sourceVideo)
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            pythonBridge.error = "自定义动作视频导入失败：\(error.localizedDescription)"
            return
        }

        activeActionImport = ActiveActionImport(
            petId: currentPet.id,
            kind: .custom,
            actionID: actionID,
            displayNameOverride: displayName,
            rootFramesDirectory: rootFramesDirectory,
            workDirectory: workDirectory.path,
            sourceVideoPath: sourceVideo.path,
            origin: .captured)
        beginPreparation(
            petId: currentPet.id,
            videoPath: sourceVideo.path,
            outputDir: workDirectory.path)
    }

    func presentPetImageManager() {
        clearOrphanedMotionWorkflowBeforeImport()
        guard cloudAccountIsReady else {
            pythonBridge.error = "云端图库尚未就绪，请先完成同步"
            return
        }
        guard !hasActiveWorkflow else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        showPetImageManager = true
    }

    func dismissPetImageManager() {
        guard !hasActiveWorkflow else { return }
        showPetImageManager = false
    }

    func cloudReferenceImages(for pet: Pet) -> [PetCloudReference] {
        Array(pet.cloudReferences.prefix(PetImageLibraryPolicy.maximumImageCount))
    }

    func cloudReferencePreview(for reference: PetCloudReference) -> URL? {
        guard let url = cloudReferencePreviewURLs[reference.id],
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func managedPetImages() -> [URL] {
        guard let pet else { return [] }
        return cloudReferenceImages(for: pet).compactMap(cloudReferencePreview)
    }

    /// Called after a valid Google session becomes available. Older versions
    /// kept copies under Application Support; migrate those once, then remove
    /// the originals so the cloud gallery is the only persistent photo source.
    func activateCloudGallery() {
        guard !isSynchronizingCloudGallery else { return }
        cloudGalleryTask?.cancel()
        cloudAccountIsReady = false
        cloudGalleryError = nil
        // The unscoped catalog predates account-scoped storage. Do not show
        // it while the owner boundary is being resolved; it is adopted only
        // when this is the first authenticated owner with no own catalog.
        let unclaimedPets = pets.filter { $0.cloudOwnerID == nil }
        if !unclaimedPets.isEmpty {
            pendingLegacyPets = unclaimedPets
        }
        activeCloudOwnerID = nil
        pets = []
        motionComposerPet = nil
        cloudReferencePreviewURLs = [:]
        cloudGalleryTask = Task { [weak self] in
            await self?.synchronizeCloudGallery()
        }
    }

    func clearCloudAccountSession() {
        cloudGalleryTask?.cancel()
        cloudGalleryTask = nil
        cloudAccountIsReady = false
        cloudGalleryError = nil
        activeCloudOwnerID = nil
        isSynchronizingCloudGallery = false
        pets = []
        motionComposerPet = nil
        cloudReferencePreviewURLs = [:]
    }

    func addPetImages(urls: [URL]) {
        clearOrphanedMotionWorkflowBeforeImport()
        guard cloudAccountIsReady else {
            pythonBridge.error = "云端图库尚未就绪，请先完成同步"
            return
        }
        guard !hasActiveWorkflow, !isSynchronizingCloudGallery else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        guard !urls.isEmpty else { return }
        let existingCount = pet.map { cloudReferenceImages(for: $0).count } ?? 0
        guard PetImageLibraryPolicy.accepts(
            existingCount: existingCount, incomingCount: urls.count
        ) else {
            pythonBridge.error = "宠物图片最多保留 4 张"
            return
        }

        isSynchronizingCloudGallery = true
        let sourceAccess = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        Task { [weak self] in
            defer {
                for (url, accessed) in sourceAccess where accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            await self?.uploadPetImagesToCloud(urls: urls)
        }
    }

    func removePetImage(at index: Int) {
        guard !hasActiveWorkflow, !isSynchronizingCloudGallery else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        guard let currentPet = pet,
              cloudReferenceImages(for: currentPet).indices.contains(index) else { return }
        let reference = cloudReferenceImages(for: currentPet)[index]
        isSynchronizingCloudGallery = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSynchronizingCloudGallery = false }
            do {
                let (configuration, credentials) = try await self.cloudStorageAccess()
                try await SupabasePetReferenceStorageClient().delete(
                    reference, configuration: configuration, credentials: credentials)
                guard var updated = self.pet,
                      let storedIndex = updated.cloudReferences.firstIndex(where: {
                          $0.id == reference.id
                      }) else { return }
                var references = updated.cloudReferences
                references.remove(at: storedIndex)
                updated.cloudReferenceImages = references
                self.pets = [updated]
                self.cloudReferencePreviewURLs[reference.id] = nil
                try? FileManager.default.removeItem(at: self.previewURL(for: reference))
                self.persistPets()
                self.pythonBridge.error = nil
            } catch {
                self.pythonBridge.error = "云端图片删除失败：\(error.localizedDescription)"
            }
        }
    }

    private func uploadPetImagesToCloud(urls: [URL]) async {
        defer { isSynchronizingCloudGallery = false }
        let id = pet?.id ?? UUID()
        do {
            let (configuration, credentials) = try await cloudStorageAccess()
            let storage = SupabasePetReferenceStorageClient()
            var uploaded: [PetCloudReference] = []
            do {
                for url in urls {
                    uploaded.append(try await storage.uploadReference(
                        from: url, petID: id, configuration: configuration,
                        credentials: credentials))
                }
            } catch {
                for reference in uploaded {
                    try? await storage.delete(
                        reference, configuration: configuration, credentials: credentials)
                }
                throw error
            }

            if var currentPet = pet {
                let legacyPaths = currentPet.referenceImages
                currentPet.cloudReferenceImages = currentPet.cloudReferences + uploaded
                currentPet.referenceImagePaths = []
                pets = [currentPet]
                persistPets()
                try? removeLegacyLocalReferences(for: currentPet, paths: legacyPaths)
            } else {
                let newPet = Pet(
                    id: id,
                    name: urls[0].deletingPathExtension().lastPathComponent,
                    sourcePath: nil,
                    framesDir: nil,
                    referenceImagePaths: [],
                    cloudReferenceImages: uploaded,
                    frameCount: 0,
                    fps: 10,
                    createdAt: Date(),
                    status: .draft)
                replacePersistentPet(with: newPet)
            }
            if let currentPet = pet {
                try? await cacheCloudReferencePreviews(
                    for: currentPet, configuration: configuration, credentials: credentials)
            }
            pythonBridge.error = nil
        } catch {
            pythonBridge.error = "图片上传到云端图库失败：\(error.localizedDescription)"
        }
    }

    private func synchronizeCloudGallery() async {
        guard !isSynchronizingCloudGallery else { return }
        let startedAt = Date()
        isSynchronizingCloudGallery = true
        defer {
            isSynchronizingCloudGallery = false
            if !Task.isCancelled,
               SupabaseGoogleLoginCoordinator.shared.state.isSignedIn {
                resumePendingMotionJobAfterSignIn()
            }
        }
        do {
            let (configuration, credentials) = try await cloudStorageAccess()
            try Task.checkCancellation()
            guard let ownerID = credentials.ownerID else {
                throw SupabaseReferenceStorageError.missingAuthenticatedOwner
            }
            try loadCloudOwnerCatalog(ownerID: ownerID)
            try Task.checkCancellation()
            guard let currentPet = pet else {
                pythonBridge.error = nil
                cloudAccountIsReady = true
                RuntimeMetrics.recordDuration(
                    "cloud_gallery.sync", startedAt: startedAt, outcome: "succeeded")
                return
            }
            let legacyURLs = Array(currentPet.referenceImages.prefix(
                PetImageLibraryPolicy.maximumImageCount))
                .map(URL.init(fileURLWithPath:))
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !legacyURLs.isEmpty {
                guard PetImageLibraryPolicy.accepts(
                    existingCount: currentPet.cloudReferences.count,
                    incomingCount: legacyURLs.count) else {
                    throw SupabaseReferenceStorageError.invalidObjectPath
                }
                let storage = SupabasePetReferenceStorageClient()
                var uploaded: [PetCloudReference] = []
                do {
                    for url in legacyURLs {
                        let reference = try await storage.uploadReference(
                            from: url, petID: currentPet.id,
                            configuration: configuration, credentials: credentials)
                        try Task.checkCancellation()
                        uploaded.append(reference)
                    }
                } catch {
                    for reference in uploaded {
                        try? await storage.delete(
                            reference, configuration: configuration, credentials: credentials)
                    }
                    throw error
                }
                try Task.checkCancellation()
                guard var updated = pet, updated.id == currentPet.id else { return }
                let legacyPaths = updated.referenceImages
                updated.cloudReferenceImages = updated.cloudReferences + uploaded
                updated.referenceImagePaths = []
                pets = [updated]
                persistPets()
                try? removeLegacyLocalReferences(for: updated, paths: legacyPaths)
            }
            if let updated = pet {
                try? await cacheCloudReferencePreviews(
                    for: updated, configuration: configuration, credentials: credentials)
            }
            try Task.checkCancellation()
            pythonBridge.error = nil
            cloudAccountIsReady = true
            RuntimeMetrics.recordDuration(
                "cloud_gallery.sync", startedAt: startedAt, outcome: "succeeded")
        } catch is CancellationError {
            return
        } catch {
            let message = "云端图库同步失败：\(error.localizedDescription)"
            cloudGalleryError = message
            pythonBridge.error = message
            RuntimeMetrics.recordDuration(
                "cloud_gallery.sync", startedAt: startedAt, outcome: "failed")
        }
    }

    private func cloudStorageAccess() async throws -> (
        SupabaseReferenceStorageConfiguration, SupabaseReferenceStorageCredentials
    ) {
        let configuration = try BundledSupabaseReferenceStorage.configuration()
        let credentials = try await SupabaseGoogleSessionStore.shared.credentials(
            configuration: configuration,
            publishableKey: try BundledSupabaseReferenceStorage.publishableKey())
        return (configuration, credentials)
    }

    private func loadCloudOwnerCatalog(ownerID: UUID) throws {
        guard activeCloudOwnerID != ownerID else { return }
        let stored = try PetStorage.shared.load(ownerID: ownerID)
        if !stored.isEmpty {
            let recovery = Pet.recoveringAfterLaunch(stored)
            pets = recovery.pets
            pendingLegacyPets = []
        } else {
            // Only an unclaimed legacy record can be adopted by the first
            // authenticated owner. A record already claimed by another owner
            // never leaks into this account's local video/action catalog.
            var legacy = pendingLegacyPets.filter { $0.cloudOwnerID == nil }
            for index in legacy.indices {
                legacy[index].cloudOwnerID = ownerID
            }
            pets = legacy
            if !legacy.isEmpty {
                try PetStorage.shared.save(legacy, ownerID: ownerID)
            }
            pendingLegacyPets = []
        }
        activeCloudOwnerID = ownerID
        cloudReferencePreviewURLs = [:]
    }

    private func cacheCloudReferencePreviews(
        for pet: Pet,
        configuration: SupabaseReferenceStorageConfiguration,
        credentials: SupabaseReferenceStorageCredentials
    ) async throws {
        let storage = SupabasePetReferenceStorageClient()
        let references = cloudReferenceImages(for: pet)
        let completed = try await withThrowingTaskGroup(
            of: (PetCloudReference, URL).self,
            returning: [(PetCloudReference, URL)].self
        ) { group in
            for reference in references {
                let destination = previewURL(for: reference)
                group.addTask {
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        let image = try await storage.download(
                            reference, configuration: configuration, credentials: credentials)
                        let previewData = try PetReferencePreviewGenerator.jpegPreview(
                            from: image.data)
                        try FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try previewData.write(to: destination, options: .atomic)
                    }
                    return (reference, destination)
                }
            }
            var results: [(PetCloudReference, URL)] = []
            for try await result in group { results.append(result) }
            return results
        }
        try Task.checkCancellation()
        for (reference, destination) in completed {
            removeStalePreviewFiles(for: reference, keeping: destination)
            cloudReferencePreviewURLs[reference.id] = destination
        }
    }

    private func previewURL(for reference: PetCloudReference) -> URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RealPet", isDirectory: true)
            .appendingPathComponent("pet-reference-previews", isDirectory: true)
            .appendingPathComponent("\(reference.id.uuidString.lowercased()).jpg")
    }

    private func removeStalePreviewFiles(
        for reference: PetCloudReference,
        keeping destination: URL
    ) {
        let directory = destination.deletingLastPathComponent()
        let prefix = "\(reference.id.uuidString.lowercased())."
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry != destination
                && entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func removeLegacyLocalReferences(for pet: Pet, paths: [String]) throws {
        let directory = PetStorage.shared.petDirectory(for: pet.id)
            .appendingPathComponent("references").standardizedFileURL
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if url.deletingLastPathComponent() == directory {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func resumePendingMotionJobAfterSignIn() {
        guard !motionWorkflowState.isBusy,
              let job = recoverableMotionJobs
                .sorted(by: { $0.createdAt < $1.createdAt })
                .first(where: { $0.state == .submitted || $0.state == .downloading }) else {
            return
        }
        Task { [weak self] in
            await self?.resumeMotionGeneration(job)
        }
    }

    func presentMotionComposer(
        for pet: Pet,
        action: FixedPetAction = .headFollow
    ) {
        guard !isSynchronizingCloudGallery else {
            pythonBridge.error = "宠物图片正在同步到云端图库"
            return
        }
        guard !cloudReferenceImages(for: pet).isEmpty else {
            pythonBridge.error = "请先在图片管理中上传宠物图片"
            return
        }
        guard !motionWorkflowState.isBusy else {
            pythonBridge.error = "当前有动作正在生成"
            return
        }
        selectedMotionAction = action
        motionComposerPet = pets.first(where: { $0.id == pet.id })
    }

    private func replacePersistentPet(with pet: Pet) {
        for existing in pets where existing.id != pet.id {
            petLauncher.stop(petId: existing.id)
        }
        pets = [pet]
        motionComposerPet = nil
        persistPets()
    }

    private func persistPets() {
        do {
            if let activeCloudOwnerID {
                try PetStorage.shared.save(pets, ownerID: activeCloudOwnerID)
            } else {
                try PetStorage.shared.save(pets)
            }
        } catch {
            pythonBridge.error = error.localizedDescription
        }
    }

    func dismissMotionComposer() {
        guard !motionWorkflowState.isBusy else { return }
        motionComposerPet = nil
        if case .failed = motionWorkflowState {
            motionWorkflowState = .idle
        }
    }

    func saveMotionServiceConfiguration(
        seconds: Int,
        resolution: MiniMaxH3VideoResolution
    ) throws {
        let configuration = try MotionServiceConfiguration(
            seconds: seconds, resolution: resolution)
            .migratedToSupportedProviders()
            .validated()
        motionServiceConfiguration = configuration
        MotionServiceConfigurationStore.save(configuration)
    }

    func saveAssetProfile(_ profile: PetAssetProfile) {
        assetProfile = profile
        PetAssetProfileStore.save(profile)
    }

    func missingFixedActions(for pet: Pet) -> [FixedPetAction] {
        let installedKinds = Set(actionManifest(for: pet)?.actions.map(\.kind) ?? [])
        return FixedPetAction.missingActions(installedKinds: installedKinds)
    }

    /// Starts the remaining fixed actions in catalog order. At most one task
    /// exists at a time; the next action starts only after the current preview
    /// passes validation and its owner explicitly installs it.
    func generateMissingActionPack(for pet: Pet) {
        guard !hasActiveWorkflow, !isSynchronizingCloudGallery else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        let missingActions = missingFixedActions(for: pet)
        guard !missingActions.isEmpty else {
            pythonBridge.error = "十二个固定动作都已安装"
            return
        }
        actionPackPetID = pet.id
        actionPackQueue = missingActions
        updateActionPackProgress()
        generateNextActionPackStep()
    }

    private func generateNextActionPackStep() {
        guard let petID = actionPackPetID,
              let pet = pets.first(where: { $0.id == petID }),
              let action = actionPackQueue.first,
              !hasActiveWorkflow else { return }
        generateAction(for: pet, action: action)
    }

    private func completeCurrentActionPackStep(_ kind: PetActionManifest.Action.Kind) {
        guard let current = actionPackQueue.first,
              current.kind == kind else { return }
        actionPackQueue.removeFirst()
        updateActionPackProgress()
        guard !actionPackQueue.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.generateNextActionPackStep()
        }
    }

    private func cancelActionPack() {
        actionPackPetID = nil
        actionPackQueue = []
        updateActionPackProgress()
    }

    private func failActionPackIfCurrent(_ action: FixedPetAction) {
        guard actionPackQueue.first == action else { return }
        cancelActionPack()
    }

    private func updateActionPackProgress() {
        queuedActionPackRemainingCount = actionPackQueue.count
    }

    /// Generates exactly one independent video for the selected action.
    func generateAction(
        for pet: Pet,
        action: FixedPetAction
    ) {
        guard !motionWorkflowState.isBusy else { return }
        guard pet.framesDir != nil || action == .headFollow else {
            motionWorkflowState = .failed("请先生成鼠标注视跟随，为桌宠创建基础帧库")
            failActionPackIfCurrent(action)
            return
        }
        do {
            selectedMotionAction = action
            let validatedConfiguration = try motionServiceConfiguration.validated()
            guard cloudAccountIsReady, !isSynchronizingCloudGallery else {
                motionWorkflowState = .failed("宠物图片正在同步到云端图库")
                failActionPackIfCurrent(action)
                return
            }
            let cloudReferences = cloudReferenceImages(for: pet)
            guard !cloudReferences.isEmpty else {
                motionWorkflowState = .failed("请先在图片管理中上传宠物图片")
                failActionPackIfCurrent(action)
                return
            }
            generatingMotionAction = action
            motionGenerationTask?.cancel()
            var durableJob = MotionGenerationJob(
                petID: pet.id,
                action: action,
                provider: validatedConfiguration.provider,
                state: .submitted)
            do {
                durableJob = try persistMotionJob(durableJob)
                activeMotionJobID = durableJob.id
            } catch {
                generatingMotionAction = nil
                motionWorkflowState = .failed("无法保存视频生成任务：\(error.localizedDescription)")
                failActionPackIfCurrent(action)
                return
            }
            motionGenerationTask = Task { [weak self] in
                guard let self else { return }
                var stagedVideo: StagedGeneratedMotionVideo?
                var didHandoffStagedVideo = false
                defer {
                    if !didHandoffStagedVideo, let stagedVideo {
                        try? FileManager.default.removeItem(atPath: stagedVideo.workDirectory)
                    }
                }
                do {
                    let generatedVideo = try await self.generateMiniMaxActionVideo(
                        pet: pet,
                        action: action,
                        configuration: validatedConfiguration,
                        durableJob: durableJob)
                    try Task.checkCancellation()
                    stagedVideo = try self.stageGeneratedMotionVideo(
                        data: generatedVideo.data,
                        for: pet,
                        kind: action.kind,
                        jobID: generatedVideo.remoteJobID)
                    guard let stagedVideo else {
                        throw SupabaseMiniMaxVideoGatewayError.invalidResponse
                    }
                    try self.startGeneratedActionImport(stagedVideo)
                    self.removeMotionJob(generatedVideo.localJobID)
                    self.activeMotionJobID = nil
                    didHandoffStagedVideo = true
                } catch is CancellationError {
                    self.cancelPersistedMotionJob(durableJob.id)
                    self.activeMotionJobID = nil
                    self.generatingMotionAction = nil
                    self.motionWorkflowState = .idle
                    self.failActionPackIfCurrent(action)
                } catch {
                    self.markMotionJob(
                        durableJob.id, state: .failed,
                        failureMessage: error.localizedDescription)
                    self.activeMotionJobID = nil
                    self.generatingMotionAction = nil
                    self.motionWorkflowState = .failed(error.localizedDescription)
                    self.failActionPackIfCurrent(action)
                }
            }
        } catch {
            generatingMotionAction = nil
            motionWorkflowState = .failed(error.localizedDescription)
            failActionPackIfCurrent(action)
        }
    }

    private func generateMiniMaxActionVideo(
        pet: Pet,
        action: FixedPetAction,
        configuration: MotionServiceConfiguration,
        durableJob: MotionGenerationJob
    ) async throws -> GeneratedRemoteMotionVideo {
        let startedAt = Date()
        do {
            let (storageConfiguration, storageCredentials) = try await cloudStorageAccess()
            let client = SupabaseMiniMaxVideoGatewayClient()
            motionWorkflowState = .submittingVideo(provider: .miniMaxH3)
            var pendingJob = try await client.create(
                petID: pet.id,
                action: action,
                seconds: configuration.seconds,
                resolution: configuration.resolution,
                configuration: storageConfiguration,
                credentials: storageCredentials)
            var persistedJob = durableJob
            persistedJob.remoteJobID = pendingJob.id
            persistedJob.state = .submitted
            persistedJob = try persistMotionJob(persistedJob)
            while !Task.isCancelled {
                switch pendingJob.status {
                case .completed:
                    motionWorkflowState = .downloadingVideo
                    persistedJob.state = .downloading
                    persistedJob = try persistMotionJob(persistedJob)
                    let data = try await client.downloadContent(job: pendingJob)
                    RuntimeMetrics.recordDuration(
                        "provider.minimax_video",
                        startedAt: startedAt,
                        outcome: "succeeded",
                        attributes: [
                            "action": action.rawValue,
                            "duration_seconds": String(configuration.seconds),
                            "provider_resolution": pendingJob.providerResolution.rawValue,
                            "provider_cost_cents": pendingJob.providerCostCents
                                .map(String.init) ?? "unknown",
                        ])
                    return .init(
                        remoteJobID: pendingJob.id,
                        localJobID: persistedJob.id,
                        data: data)
                case .failed(let message):
                    throw SupabaseMiniMaxVideoGatewayError.failed(message)
                case .queued, .processing:
                    motionWorkflowState = .waitingForVideo(
                        provider: .miniMaxH3, progress: nil)
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    pendingJob = try await client.retrieve(
                        id: pendingJob.id,
                        configuration: storageConfiguration,
                        credentials: storageCredentials)
                }
            }
            throw CancellationError()
        } catch {
            RuntimeMetrics.recordDuration(
                "provider.minimax_video",
                startedAt: startedAt,
                outcome: error is CancellationError ? "cancelled" : "failed",
                attributes: [
                    "action": action.rawValue,
                    "duration_seconds": String(configuration.seconds),
                ])
            throw error
        }
    }

    func cancelMotionGeneration() {
        motionGenerationTask?.cancel()
        motionGenerationTask = nil
        cancelActionPack()
        if let activeMotionJobID {
            // MiniMax has no documented video-task cancellation endpoint. Keep
            // the remote ID so the owner can
            // recover a completed paid task instead of losing its result.
            cancelPersistedMotionJob(activeMotionJobID)
            self.activeMotionJobID = nil
        }
        generatingMotionAction = nil
        if activeActionImport?.origin == .generated || generatedInitialPetId != nil {
            pythonBridge.cancelProcessing()
        }
        if motionWorkflowState.isBusy {
            motionWorkflowState = .idle
        }
    }

    private func beginPreparation(petId: UUID, videoPath: String, outputDir: String) {
        guard PythonBridge.findTrackMattePython() != nil else {
            deferPreparationUntilPythonIsReady(
                petID: petId, videoPath: videoPath, outputDirectory: outputDir)
            return
        }
        pythonBridge.error = nil
        preparationStartedAt[petId] = Date()
        RuntimeMetrics.record("pipeline.preparation_started", attributes: [
            "asset_profile": assetProfile.rawValue,
            "generated_motion": GeneratedMotionProcessingPolicy
                .bypassesRecordedFootageQualityGate(
                    actionOrigin: activeActionImport?.origin,
                    isInitialGeneratedPet: generatedInitialPetId == petId) ? "true" : "false",
        ])
        // Warm Faster R-CNN in parallel with quality/clip analysis. Requests
        // queue in the daemon until the model is ready, avoiding a duplicate
        // detector subprocess on the first import.
        pythonBridge.warmDetector()
        if activeActionImport?.petId != petId {
            updatePetStatus(id: petId, status: .detecting)
        }

        let isGeneratedMotion = GeneratedMotionProcessingPolicy
            .bypassesRecordedFootageQualityGate(
                actionOrigin: activeActionImport?.origin,
                isInitialGeneratedPet: generatedInitialPetId == petId)
        if isGeneratedMotion {
            pythonBridge.statusText = "正在分析生成的宠物动作…"
            beginClipAnalysis(
                petId: petId, videoPath: videoPath, outputDir: outputDir)
            return
        }

        // Step 0: Quality gate — reject bad videos before clip analysis.
        pythonBridge.qualityCheck(videoPath: videoPath, outputDir: outputDir) { [weak self] qcResult in
            guard let self = self else { return }
            if let qc = qcResult, (qc["passed"] as? Bool) == false {
                let reason = qc["message"] as? String ?? "素材不合格"
                self.failPreparation(petId: petId, message: reason)
                return
            }
            self.beginClipAnalysis(
                petId: petId, videoPath: videoPath, outputDir: outputDir)
        } // QC gate closure
    }

    private func deferPreparationUntilPythonIsReady(
        petID: UUID,
        videoPath: String,
        outputDirectory: String
    ) {
        deferredPreparation = DeferredPreparation(
            petID: petID, videoPath: videoPath, outputDirectory: outputDirectory)
        guard !pipelineSetupInProgress else { return }
        guard let requestPipelineSetup else {
            failPreparation(petId: petID, message: "Python 环境尚未配置")
            return
        }
        pipelineSetupInProgress = true
        requestPipelineSetup { [weak self] message in
            guard let self else { return }
            self.pipelineSetupInProgress = false
            guard let preparation = self.deferredPreparation else { return }
            self.deferredPreparation = nil
            guard message == nil,
                  PythonBridge.findTrackMattePython() != nil else {
                self.failPreparation(
                    petId: preparation.petID,
                    message: message ?? "Python 环境创建未完成，请重试")
                return
            }
            self.beginPreparation(
                petId: preparation.petID,
                videoPath: preparation.videoPath,
                outputDir: preparation.outputDirectory)
        }
    }

    private func beginClipAnalysis(petId: UUID, videoPath: String, outputDir: String) {
        pythonBridge.analyzeClips(
            videoPath: videoPath, outputDir: outputDir) { [weak self] clips in
                guard let self = self else { return }
                if let clips = clips, (clips["needs_selection"] as? Bool) == true {
                    let cands = (clips["candidates"] as? [[String: Any]] ?? []).map { c in
                        ClipChoice(start: c["start"] as? Double ?? 0,
                                   duration: c["duration"] as? Double ?? 0,
                                   score: c["score"] as? Double ?? 0,
                                   recommended: c["recommended"] as? Bool ?? false)
                    }
                    guard let selected = cands.first(where: \.recommended)
                            ?? cands.max(by: { $0.score < $1.score }) else {
                        self.failPreparation(
                            petId: petId, message: "没有找到适合制作宠物的片段")
                        return
                    }
                    self.runDetection(
                        petId: petId, videoPath: videoPath,
                        outputDir: outputDir, startTime: selected.start,
                        duration: selected.duration)
                } else {
                    // Short video / analysis unavailable → use the whole clip.
                    self.runDetection(petId: petId, videoPath: videoPath,
                                      outputDir: outputDir,
                                      startTime: -1, duration: -1)
                }
            }
    }

    /// Detect the pet in the automatically selected segment.
    private func runDetection(petId: UUID, videoPath: String, outputDir: String,
                              startTime: Double, duration: Double) {
        if activeActionImport?.petId != petId {
            updatePetStatus(id: petId, status: .detecting)
        }
        pythonBridge.detectPet(videoPath: videoPath, outputDir: outputDir,
                               startTime: max(0, startTime)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, let result = result else {
                    self?.failPreparation(petId: petId, message: "宠物检测失败")
                    return
                }
                let type = result["type"] as? String
                if type == "detected" {
                    let cx = result["cx"] as? Int ?? 0
                    let cy = result["cy"] as? Int ?? 0
                    let bboxValues = (result["bbox"] as? [Any])?.compactMap {
                        ($0 as? NSNumber)?.doubleValue
                    }
                    let bbox = bboxValues?.count == 4 ? bboxValues : nil
                    let detectedClass = result["name"] as? String ?? "pet"
                    let framePath = result["frame"] as? String ?? ""
                    self.classifyAndStartSegmentation(
                        petId: petId, videoPath: videoPath,
                        outputDir: outputDir, framePath: framePath,
                        detectedClass: detectedClass,
                        clickX: cx, clickY: cy, bbox: bbox,
                        startTime: startTime, duration: duration)
                } else if type == "no_pet" {
                    // QC gate should have caught this, but keep as safety net.
                    self.failPreparation(petId: petId, message: "视频中没有识别到宠物")
                } else {
                    self.failPreparation(petId: petId, message: "宠物检测失败")
                }
            }
        }
    }

    private func classifyAndStartSegmentation(
        petId: UUID,
        videoPath: String,
        outputDir: String,
        framePath: String,
        detectedClass: String,
        clickX: Int,
        clickY: Int,
        bbox: [Double]?,
        startTime: Double,
        duration: Double
    ) {
        if activeActionImport?.petId != petId {
            updatePetStatus(id: petId, status: .processing)
        }
        pythonBridge.statusText = "正在提取真实宠物画面…"
        if let index = pets.firstIndex(where: { $0.id == petId }) {
            pets[index].detectedAnimalClass = detectedClass
            persistPets()
        }
        let isGeneratedMotion = GeneratedMotionProcessingPolicy
            .bypassesRecordedFootageQualityGate(
                actionOrigin: activeActionImport?.petId == petId
                    ? activeActionImport?.origin
                : nil,
                isInitialGeneratedPet: generatedInitialPetId == petId)
        pythonBridge.startWithClick(
            videoPath: videoPath, outputDir: outputDir,
            clickX: clickX, clickY: clickY, bbox: bbox,
            startTime: startTime, duration: duration,
            skipQualityCheck: isGeneratedMotion,
            assetProfile: assetProfile,
            preservesSourceVideo: isGeneratedMotion)
    }

    private func failPreparation(petId: UUID, message: String) {
        if let startedAt = preparationStartedAt.removeValue(forKey: petId) {
            RuntimeMetrics.recordDuration(
                "pipeline.preparation", startedAt: startedAt, outcome: "failed")
        }
        if let actionImport = activeActionImport,
           actionImport.petId == petId {
            activeActionImport = nil
            pendingActionReview = nil
            preparingActionPetId = nil
            validatingActionPetId = nil
            try? FileManager.default.removeItem(
                atPath: actionImport.workDirectory)
        } else {
            updatePetStatus(id: petId, status: .failed)
        }
        if generatedInitialPetId == petId {
            generatedInitialPetId = nil
            motionWorkflowState = .failed(message)
        } else if activeActionImport == nil, motionWorkflowState.isBusy {
            motionWorkflowState = .failed(message)
        }
        generatingMotionAction = nil
        cancelActionPack()
        pythonBridge.error = message
    }

    /// Update pet status by id
    private func updatePetStatus(id: UUID, status: PetStatus) {
        if let idx = pets.firstIndex(where: { $0.id == id }) {
            pets[idx].status = status
            persistPets()
        }
    }

    /// Final processing complete
    @objc private func onProcessingComplete(_ notification: Notification) {
        guard let info = notification.userInfo as? [String: Any] else { return }

        let framesDir = info["frames_dir"] as? String
            ?? info["segmented_dir"] as? String
        let frameCount = info["frame_count"] as? Int ?? info["frames"] as? Int
        let fps = max(1, info["fps"] as? Int ?? 10)

        guard let framesDir = framesDir, let frameCount = frameCount else { return }
        let reportedSourceFrameCount = info["source_frame_count"] as? Int
        let reportedOutputFrameCount = info["output_frame_count"] as? Int
        guard reportedSourceFrameCount == nil || reportedSourceFrameCount == frameCount,
              reportedOutputFrameCount == nil || reportedOutputFrameCount == frameCount else {
            let petId = activeActionImport?.petId
                ?? pets.last(where: { $0.status == .processing })?.id
            if let petId {
                failPreparation(
                    petId: petId,
                    message: "帧完整性校验失败：处理链路报告的输入与输出帧数不一致")
            }
            return
        }
        let actualFrameCount: Int
        do {
            actualFrameCount = try PetActionLibrary.frameCount(
                in: URL(fileURLWithPath: framesDir))
        } catch {
            let petId = activeActionImport?.petId
                ?? pets.last(where: { $0.status == .processing })?.id
            if let petId {
                failPreparation(
                    petId: petId,
                    message: "帧完整性校验失败：\(error.localizedDescription)")
            }
            return
        }
        guard actualFrameCount == frameCount else {
            let petId = activeActionImport?.petId
                ?? pets.last(where: { $0.status == .processing })?.id
            if let petId {
                failPreparation(
                    petId: petId,
                    message: "帧完整性校验失败：应为 \(frameCount) 帧，实际为 \(actualFrameCount) 帧")
            }
            return
        }

        if activeActionImport != nil {
            prepareOrValidateActionImport(
                framesDirectory: framesDir, frameCount: frameCount, fps: fps)
            return
        }

        if let idx = pets.lastIndex(where: { $0.status == .processing }) {
            pets[idx].framesDir = framesDir
            pets[idx].frameCount = frameCount
            pets[idx].fps = fps
            let isGeneratedInitialPet = generatedInitialPetId == pets[idx].id
            do {
                if isGeneratedInitialPet {
                    let installedVideo = try installGeneratedInitialOrbit(
                        framesDirectory: framesDir,
                        fps: max(1, pets[idx].fps),
                        sourceVideoURL: pets[idx].sourcePath.map(URL.init(fileURLWithPath:)))
                    if let installedVideo {
                        pets[idx].sourcePath = installedVideo.path
                    }
                } else {
                    let idleManifest = PetActionManifest(
                        version: PetActionManifest.currentVersion,
                        defaultAction: "idle",
                        actions: [PetActionManifest.Action(
                            id: "idle", kind: .idle, framesDirectory: ".",
                            fps: max(1, pets[idx].fps), loop: true,
                            translatesWindow: false, origin: .captured)])
                    try idleManifest.save(framesDirectory: framesDir)
                }
            } catch {
                failPreparation(
                    petId: pets[idx].id,
                    message: "无法安装头眼注视帧库：\(error.localizedDescription)")
                return
            }
            let petId = pets[idx].id
            pets[idx].status = .processing
            persistPets()
            let featureDirectory = URL(fileURLWithPath: framesDir)
            Task { [weak self] in
                let features = await Task.detached(priority: .userInitiated) {
                    PetFeatureExtractor.extract(from: featureDirectory)
                }.value
                if let features {
                    try? features.save(framesDirectory: featureDirectory)
                }
                self?.finishSourceFrameImport(petId: petId)
            }
        }
    }

    private func finishSourceFrameImport(petId: UUID) {
        guard let index = pets.firstIndex(where: { $0.id == petId }),
              pets[index].status == .processing else { return }
        pets[index].status = .ready
        persistPets()
        if petLauncher.launch(pet: pets[index]) {
            pets[index].status = .showing
            persistPets()
            pythonBridge.error = nil
        } else {
            pets[index].status = .failed
            persistPets()
            pythonBridge.error = petLauncher.lastRuntimeError
                ?? "无法启动真实宠物桌面窗口"
        }
        let completedGeneratedInitialAction = generatedInitialPetId == petId
        if completedGeneratedInitialAction {
            generatedInitialPetId = nil
            generatingMotionAction = nil
            motionWorkflowState = .idle
        }
        if let startedAt = preparationStartedAt.removeValue(forKey: petId) {
            RuntimeMetrics.recordDuration(
                "pipeline.preparation",
                startedAt: startedAt,
                outcome: pets[index].status == .showing ? "succeeded" : "failed")
        }
        if completedGeneratedInitialAction {
            completeCurrentActionPackStep(.gazeOrbit)
        }
    }

    /// Post-processing gate failed (too many red frames). The pipeline hard-
    /// returns without emitting "complete", so no pet should land. Retract any
    /// preview pet already on the desktop and mark this pet failed.
    @objc private func onSegmentationPoor(_ notification: Notification) {
        if let actionImport = activeActionImport {
            failPreparation(
                petId: actionImport.petId,
                message: notification.userInfo?["message"] as? String
                    ?? "动作素材分割质量不达标")
            return
        }
        guard let idx = pets.lastIndex(where: { $0.status == .processing }) else { return }
        let petID = pets[idx].id
        pets[idx].status = .failed
        persistPets()
        if let startedAt = preparationStartedAt.removeValue(forKey: petID) {
            RuntimeMetrics.recordDuration(
                "pipeline.preparation", startedAt: startedAt, outcome: "failed")
        }
        if generatedInitialPetId == pets[idx].id {
            generatedInitialPetId = nil
            motionWorkflowState = .failed(
                notification.userInfo?["message"] as? String
                    ?? "生成动作的分割质量不达标")
            cancelActionPack()
        }
    }

    /// A crashed or cancelled worker must never leave a persisted task looking
    /// active after there is no process behind it.
    @objc private func onProcessingFailed(_ notification: Notification) {
        if let actionImport = activeActionImport {
            let cancelled = notification.userInfo?["cancelled"] as? Bool ?? false
            failPreparation(
                petId: actionImport.petId,
                message: cancelled ? "已中断动作制作" : "动作制作失败")
            return
        }
        guard let idx = pets.lastIndex(where: { $0.status == .processing }) else { return }
        let petID = pets[idx].id
        let cancelled = notification.userInfo?["cancelled"] as? Bool ?? false
        pets[idx].status = cancelled ? .interrupted : .failed
        persistPets()
        if let startedAt = preparationStartedAt.removeValue(forKey: petID) {
            RuntimeMetrics.recordDuration(
                "pipeline.preparation",
                startedAt: startedAt,
                outcome: cancelled ? "cancelled" : "failed")
        }
        if generatedInitialPetId == pets[idx].id {
            generatedInitialPetId = nil
            motionWorkflowState = .failed(
                cancelled ? "已中断生成动作安装" : "生成动作安装失败")
            cancelActionPack()
        }
    }

    @objc private func onPetStopped(_ notification: Notification) {
        guard let info = notification.userInfo as? [String: Any],
              let petId = info["petId"] as? UUID else { return }
        if let idx = pets.firstIndex(where: { $0.id == petId }),
           pets[idx].status == .showing {
            pets[idx].status = .ready
            persistPets()
        }
    }

    func showPet(_ pet: Pet) {
        guard let idx = pets.firstIndex(where: { $0.id == pet.id }) else { return }
        guard pets[idx].status != .showing else { return }  // already showing, no double-launch
        guard petLauncher.launch(pet: pets[idx]) else {
            if let message = petLauncher.lastRuntimeError {
                pythonBridge.error = message
            }
            return
        }
        pets[idx].status = .showing
        pythonBridge.error = nil
        if let message = petLauncher.lastRuntimeError {
            pythonBridge.error = message
        }
        persistPets()
    }

    func hidePet(_ pet: Pet) {
        let windowOrigin = petLauncher.stop(petId: pet.id)
        if let idx = pets.firstIndex(where: { $0.id == pet.id }) {
            if let windowOrigin {
                pets[idx].desktopPosition = PetDesktopPosition(
                    x: windowOrigin.x, y: windowOrigin.y)
            }
            pets[idx].status = .ready  // always reset, even if process was already dead
            persistPets()
        }
    }

    func displayScale(for pet: Pet) -> Double {
        pets.first(where: { $0.id == pet.id })?.resolvedDisplayScale
            ?? pet.resolvedDisplayScale
    }

    func setDisplayScale(_ scale: Double, for pet: Pet) {
        guard let index = pets.firstIndex(where: { $0.id == pet.id }) else { return }
        let normalized = min(1.75, max(0.55, scale))
        pets[index].displayScale = normalized
        if let windowOrigin = petLauncher.setDisplayScale(petId: pet.id, scale: normalized) {
            pets[index].desktopPosition = PetDesktopPosition(
                x: windowOrigin.x, y: windowOrigin.y)
        }
        persistPets()
    }

    func deletePet(_ pet: Pet) {
        guard activeActionImport?.petId != pet.id else {
            pythonBridge.error = "动作制作期间不能删除该宠物，请先停止处理"
            return
        }
        petLauncher.stop(petId: pet.id)
        let cloudReferences = pet.cloudReferences
        let previousPets = pets
        pets.removeAll { $0.id == pet.id }
        do {
            if let activeCloudOwnerID {
                try PetStorage.shared.save(pets, ownerID: activeCloudOwnerID)
            } else {
                try PetStorage.shared.save(pets)
            }
        } catch {
            pets = previousPets
            pythonBridge.error = error.localizedDescription
            return
        }
        do {
            try PetStorage.shared.deletePet(pet)
        } catch {
            pythonBridge.error = "宠物已从列表移除，但本地文件清理失败：\(error.localizedDescription)"
        }
        guard !cloudReferences.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let (configuration, credentials) = try await self.cloudStorageAccess()
                let storage = SupabasePetReferenceStorageClient()
                for reference in cloudReferences {
                    try await storage.delete(
                        reference, configuration: configuration, credentials: credentials)
                    try? FileManager.default.removeItem(at: self.previewURL(for: reference))
                }
            } catch {
                self.pythonBridge.error = "本地宠物已删除，但云端图片清理失败：\(error.localizedDescription)"
            }
        }
    }

    func actionManifest(for pet: Pet) -> PetActionManifest? {
        _ = actionLibraryRevision
        guard let framesDir = pet.framesDir else { return nil }
        return PetActionManifest.load(framesDirectory: framesDir)
    }

    func customActions(for pet: Pet) -> [PetActionManifest.Action] {
        actionManifest(for: pet)?.actions.filter(\.isCustom) ?? []
    }

    func canImportCustomAction(for pet: Pet) -> Bool {
        cloudAccountIsReady && pet.framesDir != nil && !hasActiveWorkflow
    }

    func playCustomAction(_ action: PetActionManifest.Action, for pet: Pet) {
        guard action.isCustom else { return }
        guard !hasActiveWorkflow else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        if !petLauncher.isRunning(petId: pet.id) {
            showPet(pet)
        }
        guard petLauncher.playCustomAction(petId: pet.id, actionID: action.id) else {
            pythonBridge.error = "无法播放自定义动作，请重新导入该视频"
            return
        }
        pythonBridge.error = nil
    }

    func deleteCustomAction(_ action: PetActionManifest.Action, for pet: Pet) {
        guard action.isCustom,
              let currentPet = pets.first(where: { $0.id == pet.id }),
              let framesDir = currentPet.framesDir else { return }
        guard !hasActiveWorkflow else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        let wasShowing = currentPet.status == .showing
        if wasShowing { hidePet(currentPet) }
        do {
            _ = try PetActionLibrary.removeCustomAction(
                id: action.id,
                rootFramesDirectory: URL(fileURLWithPath: framesDir))
            actionLibraryRevision += 1
            pythonBridge.error = nil
            if wasShowing { showPet(currentPet) }
        } catch {
            pythonBridge.error = "删除自定义动作失败：\(error.localizedDescription)"
            if wasShowing { showPet(currentPet) }
        }
    }

    func canShowPet(_ pet: Pet) -> Bool {
        pet.status == .showing || petLauncher.canLaunch(pet: pet)
    }

    private func representativeFrame(for pet: Pet) -> URL? {
        guard let framesDirectory = pet.framesDir,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: framesDirectory),
                includingPropertiesForKeys: nil) else {
            return nil
        }
        let frames = entries.filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasPrefix("frame_")
                && !name.hasSuffix("_a.jpg")
                && (name.hasSuffix(".png")
                    || name.hasSuffix(".jpg")
                    || name.hasSuffix(".jpeg"))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !frames.isEmpty else { return nil }
        return frames[frames.count / 2]
    }

    private func prepareOrValidateActionImport(
        framesDirectory: String,
        frameCount: Int,
        fps: Int
    ) {
        guard let context = activeActionImport else { return }
        guard [.react, .shakeHead, .play, .lieDown, .paw, .eat, .custom]
            .contains(context.kind) else {
            validateActionImport(
                framesDirectory: framesDirectory, frameCount: frameCount, fps: fps)
            return
        }

        preparingActionPetId = context.petId
        let outputDirectory = URL(fileURLWithPath: context.workDirectory)
            .appendingPathComponent("prepared-\(UUID().uuidString)").path
        pythonBridge.prepareAction(
            framesDirectory: framesDirectory,
            outputDirectory: outputDirectory,
            kind: context.kind.rawValue,
            fps: fps) { [weak self] result in
                guard let self,
                      self.activeActionImport == context else { return }
                self.preparingActionPetId = nil
                guard let result,
                      result["prepared"] as? Bool == true,
                      let preparedDirectory = result["frames_dir"] as? String,
                      let preparedFrameCount = result["frame_count"] as? Int,
                      preparedFrameCount > 0 else {
                    self.failPreparation(
                        petId: context.petId,
                        message: result?["message"] as? String
                            ?? "无法从素材中提取有效互动动作")
                    return
                }
                guard preparedFrameCount == frameCount else {
                    self.failPreparation(
                        petId: context.petId,
                        message: "动作帧完整性校验失败：应为 \(frameCount) 帧，实际为 \(preparedFrameCount) 帧")
                    return
                }
                self.validateActionImport(
                    framesDirectory: preparedDirectory,
                    frameCount: preparedFrameCount,
                    fps: fps)
            }
    }

    private func validateActionImport(
        framesDirectory: String,
        frameCount: Int,
        fps: Int
    ) {
        guard let context = activeActionImport else { return }
        guard frameCount > 0 else {
            failPreparation(petId: context.petId, message: "动作处理没有生成有效帧")
            return
        }
        validatingActionPetId = context.petId
        pythonBridge.validateAction(
            framesDirectory: framesDirectory,
            kind: context.kind.rawValue,
            referenceFramesDirectory: PetActionLibrary.identityReferenceDirectory(
                rootFramesDirectory: URL(fileURLWithPath: context.rootFramesDirectory)).path
        ) { [weak self] result in
                guard let self,
                      self.activeActionImport == context else { return }
                self.validatingActionPetId = nil
                guard let result,
                      result["passed"] as? Bool == true else {
                    RuntimeMetrics.record(
                        "identity_validation", attributes: ["outcome": "failed"])
                    self.failPreparation(
                        petId: context.petId,
                        message: result?["message"] as? String
                            ?? "动作验证失败，请更换素材")
                    return
                }
                let identity = (result["identity"] as? [String: Any])?["similarity"]
                    as? Double
                RuntimeMetrics.record("identity_validation", attributes: [
                    "outcome": "passed",
                    "similarity_milli": identity.map {
                        String(Int(($0 * 1_000).rounded()))
                    } ?? "unavailable",
                ])
                if let startedAt = self.preparationStartedAt.removeValue(
                    forKey: context.petId) {
                    RuntimeMetrics.recordDuration(
                        "pipeline.preparation",
                        startedAt: startedAt,
                        outcome: "validated")
                }
                self.pendingActionReview = PendingActionReview(
                    id: UUID(), petId: context.petId, kind: context.kind,
                    actionID: context.actionID,
                    displayName: context.displayNameOverride ?? context.kind.displayName,
                    framesDirectory: framesDirectory, frameCount: frameCount,
                    fps: fps, identitySimilarity: identity,
                    origin: context.origin)
            }
    }

    func acceptPendingActionReview() {
        guard let review = pendingActionReview else { return }
        pendingActionReview = nil
        installActionImport(
            framesDirectory: review.framesDirectory,
            frameCount: review.frameCount,
            fps: review.fps)
    }

    func discardPendingActionReview() {
        guard let context = activeActionImport else {
            pendingActionReview = nil
            return
        }
        try? FileManager.default.removeItem(atPath: context.workDirectory)
        pendingActionReview = nil
        activeActionImport = nil
        preparingActionPetId = nil
        validatingActionPetId = nil
        cancelActionPack()
        if motionWorkflowState.isBusy {
            motionWorkflowState = .idle
        }
        pythonBridge.error = nil
    }

    private func installActionImport(
        framesDirectory: String,
        frameCount: Int,
        fps: Int
    ) {
        guard let context = activeActionImport,
              frameCount > 0 else { return }
        let fm = FileManager.default
        let source = URL(fileURLWithPath: framesDirectory)
        let root = URL(fileURLWithPath: context.rootFramesDirectory)

        do {
            // Keep the source video beside its extracted frames. This makes
            // each action independently reviewable while the runtime renders
            // the processed frame sequence.
            if let sourceVideoPath = context.sourceVideoPath {
                let video = URL(fileURLWithPath: sourceVideoPath)
                guard fm.fileExists(atPath: video.path) else {
                    throw SupabaseMiniMaxVideoGatewayError.invalidResponse
                }
                let companion = source.appendingPathComponent("action.mp4")
                if fm.fileExists(atPath: companion.path) {
                    try fm.removeItem(at: companion)
                }
                try fm.copyItem(at: video, to: companion)
            }
            try PetActionLibrary.install(
                kind: context.kind,
                processedFramesDirectory: source,
                rootFramesDirectory: root,
                fps: fps,
                origin: context.origin,
                actionID: context.actionID,
                displayNameOverride: context.displayNameOverride)
            try? fm.removeItem(atPath: context.workDirectory)
            activeActionImport = nil
            pendingActionReview = nil
            preparingActionPetId = nil
            validatingActionPetId = nil
            actionLibraryRevision += 1
            pythonBridge.error = nil

            if let pet = pets.first(where: {
                $0.id == context.petId && $0.status == .showing
            }) {
                petLauncher.launch(pet: pet)
                if let message = petLauncher.lastRuntimeError {
                    pythonBridge.error = message
                }
            }

            motionWorkflowState = .idle
            generatingMotionAction = nil
            completeCurrentActionPackStep(context.kind)
        } catch {
            try? fm.removeItem(atPath: context.workDirectory)
            activeActionImport = nil
            pendingActionReview = nil
            preparingActionPetId = nil
            validatingActionPetId = nil
            motionWorkflowState = .failed("动作安装失败：\(error.localizedDescription)")
            generatingMotionAction = nil
            cancelActionPack()
            pythonBridge.error = "动作安装失败：\(error.localizedDescription)"
        }
    }

    private func stageGeneratedMotionVideo(
        data: Data,
        for pet: Pet,
        kind: PetActionManifest.Action.Kind,
        jobID: String
    ) throws -> StagedGeneratedMotionVideo {
        guard !data.isEmpty else {
            throw SupabaseMiniMaxVideoGatewayError.invalidResponse
        }
        guard let currentPet = pets.first(where: { $0.id == pet.id }) else {
            throw SupabaseMiniMaxVideoGatewayError.failed("宠物已被删除")
        }
        let petDirectory = PetStorage.shared.petDirectory(for: currentPet.id)
        let workDirectory = petDirectory
            .appendingPathComponent("generated-video")
            .appendingPathComponent("\(kind.rawValue)-\(jobID)")
        try FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: true)
        let videoURL = workDirectory.appendingPathComponent("generated.mp4")
        try data.write(to: videoURL, options: .atomic)
        return StagedGeneratedMotionVideo(
            petID: currentPet.id,
            kind: kind,
            rootFramesDirectory: currentPet.framesDir,
            workDirectory: workDirectory.path,
            videoURL: videoURL)
    }

    private func startGeneratedActionImport(_ stagedVideo: StagedGeneratedMotionVideo) throws {
        guard let currentPet = pets.first(where: { $0.id == stagedVideo.petID }) else {
            throw SupabaseMiniMaxVideoGatewayError.failed("宠物已被删除")
        }
        motionWorkflowState = .installing
        if let rootFramesDirectory = stagedVideo.rootFramesDirectory {
            activeActionImport = ActiveActionImport(
                petId: stagedVideo.petID,
                kind: stagedVideo.kind,
                actionID: stagedVideo.kind.rawValue,
                displayNameOverride: nil,
                rootFramesDirectory: rootFramesDirectory,
                workDirectory: stagedVideo.workDirectory,
                sourceVideoPath: stagedVideo.videoURL.path,
                origin: .generated)
            beginPreparation(
                petId: stagedVideo.petID,
                videoPath: stagedVideo.videoURL.path,
                outputDir: stagedVideo.workDirectory)
            return
        }
        guard stagedVideo.kind == .gazeOrbit else {
            throw SupabaseMiniMaxVideoGatewayError.failed(
                "请先生成鼠标注视跟随，为桌宠创建基础帧库")
        }
        generatedInitialPetId = currentPet.id
        if let index = pets.firstIndex(where: { $0.id == currentPet.id }) {
            pets[index].sourcePath = stagedVideo.videoURL.path
            pets[index].status = .detecting
            persistPets()
        }
        beginPreparation(
            petId: currentPet.id,
            videoPath: stagedVideo.videoURL.path,
            outputDir: PetStorage.shared.petDirectory(for: currentPet.id).path)
    }

    /// A photo-only pet retains every generated frame in its own head-follow
    /// action directory. A separate one-frame idle copy avoids playing the
    /// directional sweep until the pointer actually moves.
    private func installGeneratedInitialOrbit(
        framesDirectory: String,
        fps: Int,
        sourceVideoURL: URL?
    ) throws -> URL? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: framesDirectory)
        let frameEntries = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("frame_")
            }
        let colorFrames = frameEntries.filter { entry in
            let name = entry.lastPathComponent.lowercased()
            return !name.hasSuffix("_a.jpg")
                && ["png", "jpg"].contains(entry.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let initialFrame = colorFrames.first else {
            throw PetActionLibrary.InstallError.noFrames
        }

        let staging = root.appendingPathComponent(
            ".generated-gaze-orbit-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for entry in frameEntries {
                try fm.copyItem(at: entry, to: staging.appendingPathComponent(
                    entry.lastPathComponent))
            }
            if let sourceVideoURL,
               fm.fileExists(atPath: sourceVideoURL.path) {
                try fm.copyItem(
                    at: sourceVideoURL,
                    to: staging.appendingPathComponent("action.mp4"))
            }
            let manifest = try PetActionLibrary.install(
                kind: .gazeOrbit,
                processedFramesDirectory: staging,
                rootFramesDirectory: root,
                fps: fps,
                origin: .generated)
            let idleDirectory = root.appendingPathComponent("actions/idle")
            try fm.createDirectory(at: idleDirectory, withIntermediateDirectories: true)
            try fm.copyItem(
                at: initialFrame,
                to: idleDirectory.appendingPathComponent(initialFrame.lastPathComponent))
            let alpha = root.appendingPathComponent(
                "\(initialFrame.deletingPathExtension().lastPathComponent)_a.jpg")
            if fm.fileExists(atPath: alpha.path) {
                try fm.copyItem(at: alpha, to: idleDirectory.appendingPathComponent(alpha.lastPathComponent))
            }
            let generatedBaseManifest = PetActionManifest(
                version: manifest.version,
                defaultAction: manifest.defaultAction,
                actions: manifest.actions.map { action in
                    guard action.kind == .idle else { return action }
                    return PetActionManifest.Action(
                        id: action.id,
                        kind: action.kind,
                        framesDirectory: "actions/idle",
                        fps: action.fps,
                        loop: action.loop,
                        translatesWindow: action.translatesWindow,
                        origin: .generated)
                })
            try generatedBaseManifest.save(framesDirectory: framesDirectory)
            _ = try? PetActionLibrary.deduplicateGeneratedOrbitFrames(
                rootFramesDirectory: root)
            let installedVideo = root
                .appendingPathComponent("actions")
                .appendingPathComponent(PetActionManifest.Action.Kind.gazeOrbit.rawValue)
                .appendingPathComponent("action.mp4")
            if let sourceVideoURL,
               fm.fileExists(atPath: sourceVideoURL.path),
               fm.fileExists(atPath: installedVideo.path) {
                try? fm.removeItem(at: sourceVideoURL)
            }
            actionLibraryRevision += 1
            return fm.fileExists(atPath: installedVideo.path) ? installedVideo : nil
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    func motionReferenceImages(for pet: Pet) -> [URL] {
        cloudReferenceImages(for: pet).compactMap(cloudReferencePreview)
    }

}
