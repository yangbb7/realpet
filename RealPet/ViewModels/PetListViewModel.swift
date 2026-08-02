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
    @Published private(set) var cameraInteractionEnabled = false
    @Published private(set) var cameraInteractionState: CameraInteractionState = .disabled
    @Published private(set) var speechInteractionEnabled = false
    @Published private(set) var speechInteractionState: SpeechInteractionState = .disabled
    @Published var showVisionModelSetup = false
    @Published private(set) var localVLMConfiguration: LocalVLMConfiguration
    @Published private(set) var localVLMRuntimeState: LocalVLMRuntimeState
    @Published var showPetImageManager = false
    @Published private(set) var pendingActionReview: PendingActionReview?
    /// The pet whose action composer is currently expanded in the main console.
    @Published var motionComposerPet: Pet?
    @Published private(set) var selectedMotionAction: FixedPetAction = .headFollow
    @Published private(set) var generatingMotionAction: FixedPetAction?
    @Published private(set) var motionWorkflowState: MotionWorkflowState = .idle
    @Published private(set) var motionServiceConfiguration: MotionServiceConfiguration
    @Published private(set) var recoverableMotionJobs: [MotionGenerationJob] = []
    /// Preview files are expendable cache entries. Owner photos themselves
    /// live only in the signed-in user's private cloud gallery.
    @Published private(set) var cloudReferencePreviewURLs: [UUID: URL] = [:]
    @Published private(set) var isSynchronizingCloudGallery = false
    @Published private(set) var cloudAccountIsReady = false
    @Published private(set) var cloudGalleryError: String?

    let pythonBridge = PythonBridge()
    let petLauncher = PetLauncher()
    let multimodalEvidenceBuffer = EphemeralEvidenceBuffer()

    private var generatedInitialPetId: UUID?
    private var motionGenerationTask: Task<Void, Never>?
    private var activeMotionJobID: UUID?
    private let motionJobStore = MotionGenerationJobStore.shared
    private var activeCloudOwnerID: UUID?
    private var cameraInteractionAdapter: CameraInteractionAdapter?
    private var vlmInteractionAdapter: VLMInteractionAdapter?
    private var speechInteractionAdapter: SpeechInteractionAdapter?

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

    struct ClipChoice {
        let start: Double
        let duration: Double
        let score: Double
        let recommended: Bool
    }

    init() {
        let vlmConfiguration = LocalVLMConfigurationStore.load()
        motionServiceConfiguration = MotionServiceConfigurationStore.load()
        localVLMConfiguration = vlmConfiguration
        localVLMRuntimeState = Self.restingVLMState(for: vlmConfiguration)
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
            let data: Data
            switch job.provider {
            case .agnes:
                let key = try BundledAgnesVideoService.apiKey()
                let configuration = try motionServiceConfiguration.validatedAgnesAPIConfiguration()
                let client = AgnesVideoGenerationClient()
                var remote = try await client.retrieve(
                    id: remoteJobID, apiKey: key, configuration: configuration)
                while remote.status == .queued || remote.status == .processing {
                    try await Task.sleep(for: .seconds(5))
                    remote = try await client.retrieve(
                        id: remoteJobID, apiKey: key, configuration: configuration)
                }
                guard remote.status == .completed else {
                    throw AgnesVideoGenerationError.failed("恢复的 Agnes Video 任务未成功完成")
                }
                markMotionJob(job.id, state: .downloading)
                data = try await client.downloadContent(job: remote)
            case .miniMaxH3:
                guard let key = OpenAIAPIKeyStore.loadMiniMaxMotionService() else {
                    throw MiniMaxH3VideoGenerationError.invalidAPIKey
                }
                let configuration = try MiniMaxVideoAPIConfiguration(
                    baseURLString: motionServiceConfiguration.resolvedMiniMaxBaseURLString)
                let client = MiniMaxH3VideoGenerationClient()
                var remote = try await client.retrieve(
                    id: remoteJobID, apiKey: key, configuration: configuration)
                while remote.status == .queued || remote.status == .processing {
                    try await Task.sleep(for: .seconds(5))
                    remote = try await client.retrieve(
                        id: remoteJobID, apiKey: key, configuration: configuration)
                }
                guard remote.status == .completed else {
                    throw MiniMaxH3VideoGenerationError.failed("恢复的 MiniMax 任务未成功完成")
                }
                markMotionJob(job.id, state: .downloading)
                data = try await client.downloadContent(job: remote)
            }
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
        cloudAccountIsReady = false
        cloudGalleryError = nil
        Task { [weak self] in
            await self?.synchronizeCloudGallery()
        }
    }

    func clearCloudAccountSession() {
        cloudAccountIsReady = false
        cloudGalleryError = nil
        activeCloudOwnerID = nil
        cloudReferencePreviewURLs = [:]
    }

    func addPetImages(urls: [URL]) {
        clearOrphanedMotionWorkflowBeforeImport()
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
        isSynchronizingCloudGallery = true
        defer {
            isSynchronizingCloudGallery = false
            resumePendingMotionJobAfterSignIn()
        }
        do {
            let (configuration, credentials) = try await cloudStorageAccess()
            guard let ownerID = credentials.ownerID else {
                throw SupabaseReferenceStorageError.missingAuthenticatedOwner
            }
            try loadCloudOwnerCatalog(ownerID: ownerID)
            guard let currentPet = pet else {
                pythonBridge.error = nil
                cloudAccountIsReady = true
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
                        uploaded.append(try await storage.uploadReference(
                            from: url, petID: currentPet.id,
                            configuration: configuration, credentials: credentials))
                    }
                } catch {
                    for reference in uploaded {
                        try? await storage.delete(
                            reference, configuration: configuration, credentials: credentials)
                    }
                    throw error
                }
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
            pythonBridge.error = nil
            cloudAccountIsReady = true
        } catch {
            let message = "云端图库同步失败：\(error.localizedDescription)"
            cloudGalleryError = message
            pythonBridge.error = message
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
        } else {
            // Only an unclaimed legacy record can be adopted by the first
            // authenticated owner. A record already claimed by another owner
            // never leaks into this account's local video/action catalog.
            var legacy = pets.filter { $0.cloudOwnerID == nil || $0.cloudOwnerID == ownerID }
            for index in legacy.indices {
                legacy[index].cloudOwnerID = ownerID
            }
            pets = legacy
            if !legacy.isEmpty {
                try PetStorage.shared.save(legacy, ownerID: ownerID)
            }
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
        for reference in cloudReferenceImages(for: pet) {
            let destination = previewURL(for: reference)
            if !FileManager.default.fileExists(atPath: destination.path) {
                let image = try await storage.download(
                    reference, configuration: configuration, credentials: credentials)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try image.data.write(to: destination, options: .atomic)
            }
            cloudReferencePreviewURLs[reference.id] = destination
        }
    }

    private func previewURL(for reference: PetCloudReference) -> URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let ext: String
        switch reference.mimeType {
        case "image/png": ext = "png"
        case "image/webp": ext = "webp"
        default: ext = "jpg"
        }
        return base.appendingPathComponent("RealPet", isDirectory: true)
            .appendingPathComponent("pet-reference-previews", isDirectory: true)
            .appendingPathComponent("\(reference.id.uuidString.lowercased()).\(ext)")
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
        provider: MotionVideoProvider,
        miniMaxBaseURLString: String,
        seconds: Int,
        miniMaxAPIKey: String?
    ) throws {
        let configuration = try MotionServiceConfiguration(
            provider: provider,
            agnesBaseURLString: BundledAgnesVideoService.baseURLString,
            miniMaxBaseURLString: miniMaxBaseURLString,
            videoModel: provider.modelName,
            seconds: seconds,
            size: provider == .agnes
                ? BundledAgnesVideoService.size : motionServiceConfiguration.size)
            .migratedToSupportedProviders()
            .validated()
        if provider == .agnes {
            _ = try BundledSupabaseReferenceStorage.configuration()
        }
        if let miniMaxAPIKey {
            let trimmed = miniMaxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try OpenAIAPIKeyStore.saveMiniMaxMotionService(trimmed)
            }
        }
        motionServiceConfiguration = configuration
        MotionServiceConfigurationStore.save(configuration)
    }

    /// Generates exactly one independent video for the selected action.
    /// There is deliberately no scenario queue or hidden fan-out: one action
    /// slot maps to one provider task and one installed frame directory.
    func generateAction(
        for pet: Pet,
        action: FixedPetAction
    ) {
        guard !motionWorkflowState.isBusy else { return }
        guard pet.framesDir != nil || action == .headFollow else {
            motionWorkflowState = .failed("请先生成鼠标注视跟随，为桌宠创建基础帧库")
            return
        }
        do {
            selectedMotionAction = action
            let validatedConfiguration = try motionServiceConfiguration.validated()
            guard !isSynchronizingCloudGallery else {
                motionWorkflowState = .failed("宠物图片正在同步到云端图库")
                return
            }
            let cloudReferences = cloudReferenceImages(for: pet)
            guard !cloudReferences.isEmpty else {
                motionWorkflowState = .failed("请先在图片管理中上传宠物图片")
                return
            }
            let actionPrompt = action.prompt(
                referenceImageCount: cloudReferences.count,
                provider: validatedConfiguration.provider)
            generatingMotionAction = action
            motionGenerationTask?.cancel()
            var durableJob = MotionGenerationJob(
                petID: pet.id,
                action: action,
                provider: validatedConfiguration.provider,
                state: validatedConfiguration.provider == .agnes
                    ? .preparingReference : .submitted)
            do {
                durableJob = try persistMotionJob(durableJob)
                activeMotionJobID = durableJob.id
            } catch {
                generatingMotionAction = nil
                motionWorkflowState = .failed("无法保存视频生成任务：\(error.localizedDescription)")
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
                    let generatedVideo: GeneratedRemoteMotionVideo
                    switch validatedConfiguration.provider {
                    case .agnes:
                        generatedVideo = try await self.generateAgnesActionVideo(
                            action: action,
                            primaryReference: cloudReferences[0],
                            prompt: actionPrompt,
                            configuration: validatedConfiguration,
                            durableJob: durableJob)
                    case .miniMaxH3:
                        generatedVideo = try await self.generateMiniMaxActionVideo(
                            cloudReferences: cloudReferences,
                            prompt: actionPrompt,
                            configuration: validatedConfiguration,
                            durableJob: durableJob)
                    }
                    try Task.checkCancellation()
                    stagedVideo = try self.stageGeneratedMotionVideo(
                        data: generatedVideo.data,
                        for: pet,
                        kind: action.kind,
                        jobID: generatedVideo.remoteJobID)
                    guard let stagedVideo else {
                        throw AgnesVideoGenerationError.invalidResponse
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
                } catch {
                    self.markMotionJob(
                        durableJob.id, state: .failed,
                        failureMessage: error.localizedDescription)
                    self.activeMotionJobID = nil
                    self.generatingMotionAction = nil
                    self.motionWorkflowState = .failed(error.localizedDescription)
                }
            }
        } catch {
            generatingMotionAction = nil
            motionWorkflowState = .failed(error.localizedDescription)
        }
    }

    private func generateAgnesActionVideo(
        action: FixedPetAction,
        primaryReference: PetCloudReference,
        prompt: String,
        configuration: MotionServiceConfiguration,
        durableJob: MotionGenerationJob
    ) async throws -> GeneratedRemoteMotionVideo {
        let agnesAPIKey = try BundledAgnesVideoService.apiKey()
        let (storageConfiguration, storageCredentials) = try await cloudStorageAccess()
        let agnesConfiguration = try configuration.validatedAgnesAPIConfiguration()
        guard let videoSettings = AgnesVideoGenerationRequestSettings(
            size: configuration.size,
            seconds: max(configuration.seconds, action.minimumVideoSeconds)
        ) else {
            throw MotionServiceConfigurationError.invalidSize
        }

        let storage = SupabasePetReferenceStorageClient()
        motionWorkflowState = .preparingReference
        let firstFrameURL = try await storage.signedURL(
            for: primaryReference,
            configuration: storageConfiguration,
            credentials: storageCredentials)
        var persistedJob = durableJob
        persistedJob.referenceObjectPath = primaryReference.objectPath
        persistedJob = try persistMotionJob(persistedJob)
        do {
            let client = AgnesVideoGenerationClient()
            motionWorkflowState = .submittingVideo(provider: .agnes)
            var pendingJob = try await client.create(
                prompt: prompt,
                firstFrameURL: firstFrameURL,
                apiKey: agnesAPIKey,
                configuration: agnesConfiguration,
                settings: videoSettings)
            persistedJob.remoteJobID = pendingJob.id
            persistedJob.state = .submitted
            persistedJob = try persistMotionJob(persistedJob)
            while !Task.isCancelled {
                switch pendingJob.status {
                case .completed:
                    motionWorkflowState = .downloadingVideo
                    persistedJob.state = .downloading
                    persistedJob = try persistMotionJob(persistedJob)
                    let video = try await client.downloadContent(job: pendingJob)
                    return .init(
                        remoteJobID: pendingJob.id,
                        localJobID: persistedJob.id,
                        data: video)
                case .failed(let message):
                    throw AgnesVideoGenerationError.failed(message)
                case .queued, .processing:
                    motionWorkflowState = .waitingForVideo(
                        provider: .agnes, progress: pendingJob.progress)
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    pendingJob = try await client.retrieve(
                        id: pendingJob.id,
                        apiKey: agnesAPIKey,
                        configuration: agnesConfiguration)
                }
            }
            throw CancellationError()
        } catch { throw error }
    }

    private func generateMiniMaxActionVideo(
        cloudReferences: [PetCloudReference],
        prompt: String,
        configuration: MotionServiceConfiguration,
        durableJob: MotionGenerationJob
    ) async throws -> GeneratedRemoteMotionVideo {
        guard let miniMaxAPIKey = OpenAIAPIKeyStore.loadMiniMaxMotionService() else {
            throw MiniMaxH3VideoGenerationError.invalidAPIKey
        }
        let miniMaxConfiguration = try MiniMaxVideoAPIConfiguration(
            baseURLString: configuration.resolvedMiniMaxBaseURLString)
        let (storageConfiguration, storageCredentials) = try await cloudStorageAccess()
        motionWorkflowState = .preparingReference
        let storage = SupabasePetReferenceStorageClient()
        var references: [PetReferenceImageData] = []
        for reference in cloudReferences {
            references.append(try await storage.download(
                reference, configuration: storageConfiguration,
                credentials: storageCredentials))
        }
        guard !references.isEmpty else {
            throw MiniMaxH3VideoGenerationError.invalidReferenceImage
        }

        let client = MiniMaxH3VideoGenerationClient()
        motionWorkflowState = .submittingVideo(provider: .miniMaxH3)
        var pendingJob = try await client.create(
            prompt: prompt,
            referenceImages: references,
            apiKey: miniMaxAPIKey,
            configuration: miniMaxConfiguration,
            seconds: configuration.seconds)
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
                return .init(
                    remoteJobID: pendingJob.id,
                    localJobID: persistedJob.id,
                    data: try await client.downloadContent(job: pendingJob))
            case .failed(let message):
                throw MiniMaxH3VideoGenerationError.failed(message)
            case .queued, .processing:
                motionWorkflowState = .waitingForVideo(
                    provider: .miniMaxH3, progress: nil)
                try await Task.sleep(for: .seconds(5))
                try Task.checkCancellation()
                pendingJob = try await client.retrieve(
                    id: pendingJob.id,
                    apiKey: miniMaxAPIKey,
                    configuration: miniMaxConfiguration)
            }
        }
        throw CancellationError()
    }

    func cancelMotionGeneration() {
        motionGenerationTask?.cancel()
        motionGenerationTask = nil
        if let activeMotionJobID {
            // Neither supported provider has a documented video-task
            // cancellation endpoint. Keep the remote ID so the owner can
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
        pythonBridge.error = nil
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
            pets[index].rendererKind = .sourceFrames
            persistPets()
        }
        let skipsQualityCheck = GeneratedMotionProcessingPolicy
            .bypassesRecordedFootageQualityGate(
                actionOrigin: activeActionImport?.petId == petId
                    ? activeActionImport?.origin
                    : nil,
                isInitialGeneratedPet: generatedInitialPetId == petId)
        pythonBridge.startWithClick(
            videoPath: videoPath, outputDir: outputDir,
            clickX: clickX, clickY: clickY, bbox: bbox,
            startTime: startTime, duration: duration,
            skipQualityCheck: skipsQualityCheck)
    }

    private func failPreparation(petId: UUID, message: String) {
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
            pets[idx].rendererKind = .sourceFrames
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
        if generatedInitialPetId == petId {
            generatedInitialPetId = nil
            generatingMotionAction = nil
            motionWorkflowState = .idle
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
        pets[idx].status = .failed
        persistPets()
        if generatedInitialPetId == pets[idx].id {
            generatedInitialPetId = nil
            motionWorkflowState = .failed(
                notification.userInfo?["message"] as? String
                    ?? "生成动作的分割质量不达标")
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
        let cancelled = notification.userInfo?["cancelled"] as? Bool ?? false
        pets[idx].status = cancelled ? .interrupted : .failed
        persistPets()
        if generatedInitialPetId == pets[idx].id {
            generatedInitialPetId = nil
            motionWorkflowState = .failed(
                cancelled ? "已中断生成动作安装" : "生成动作安装失败")
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
        disableSensorsIfNoVisiblePets()
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
        disableSensorsIfNoVisiblePets()
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
        disableSensorsIfNoVisiblePets()
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

    var hasVisiblePet: Bool {
        pets.contains { $0.status == .showing }
    }

    var cameraInteractionHelp: String {
        switch cameraInteractionState {
        case .disabled: return "开启本地视觉互动"
        case .requestingPermission: return "等待摄像头权限"
        case .starting: return "正在启动摄像头"
        case .running:
            if localVLMConfiguration.isEnabled,
               let model = localVLMConfiguration.modelName {
                return "视觉互动已开启（本机 Vision + \(model)）"
            }
            return "视觉互动已开启（本机 Vision）"
        case .denied: return "摄像头权限已拒绝"
        case .unavailable: return "没有可用摄像头"
        case .failed(let message): return message
        }
    }

    var speechInteractionHelp: String {
        switch speechInteractionState {
        case .disabled: return "开启本机语音互动：过来、真棒、一起玩、停下、继续"
        case .requestingPermission: return "等待语音识别和麦克风权限"
        case .starting: return "正在启动设备端语音识别"
        case .listening: return "正在聆听本机语音指令"
        case .denied: return "语音识别或麦克风权限已拒绝"
        case .restricted: return "系统限制了语音识别或麦克风"
        case .unavailable(let message), .failed(let message): return message
        }
    }

    func setSpeechInteractionEnabled(_ enabled: Bool) {
        guard enabled != speechInteractionEnabled else { return }
        if enabled {
            guard hasVisiblePet else {
                pythonBridge.error = "请先显示一只宠物，再开启语音互动"
                return
            }
            let adapter = SpeechInteractionAdapter(
                targetPetIds: { [weak self] in
                    self?.pets.filter { $0.status == .showing }.map(\.id) ?? []
                })
            adapter.onStateChange = { [weak self] state in
                self?.handleSpeechInteractionState(state)
            }
            speechInteractionAdapter = adapter
            speechInteractionEnabled = true
            do {
                try petLauncher.attachInteractionAdapter(adapter)
            } catch {
                petLauncher.detachInteractionAdapter(adapter)
                speechInteractionAdapter = nil
                speechInteractionEnabled = false
                speechInteractionState = .failed(error.localizedDescription)
                pythonBridge.error = "语音互动启动失败：\(error.localizedDescription)"
            }
        } else {
            stopSpeechInteraction()
        }
    }

    private func handleSpeechInteractionState(_ state: SpeechInteractionState) {
        speechInteractionState = state
        let message: String?
        switch state {
        case .denied:
            message = "语音权限已拒绝，可在系统设置 > 隐私与安全性中开启语音识别和麦克风"
        case .restricted:
            message = "系统限制了语音识别或麦克风访问"
        case .unavailable(let detail):
            message = "语音互动不可用：\(detail)"
        case .failed(let detail):
            message = "语音互动启动失败：\(detail)"
        default:
            message = nil
        }
        guard let message else { return }

        let adapter = speechInteractionAdapter
        speechInteractionAdapter = nil
        speechInteractionEnabled = false
        if let adapter {
            petLauncher.detachInteractionAdapter(adapter)
        }
        speechInteractionState = state
        pythonBridge.error = message
    }

    private func stopSpeechInteraction() {
        let adapter = speechInteractionAdapter
        speechInteractionAdapter = nil
        speechInteractionEnabled = false
        if let adapter {
            petLauncher.detachInteractionAdapter(adapter)
        }
        speechInteractionState = .disabled
    }

    var localVLMHelp: String {
        switch localVLMRuntimeState {
        case .disabled:
            return "视觉模型未启用"
        case .ready(let model):
            return "本机视觉模型已就绪：\(model)"
        case .inferencing(let model):
            return "\(model) 正在理解当前互动"
        case .failed(let message):
            return "视觉模型调用失败：\(message)"
        }
    }

    var localIntelligenceHelp: String {
        localVLMHelp
    }

    func setCameraInteractionEnabled(_ enabled: Bool) {
        guard enabled != cameraInteractionEnabled else { return }
        if enabled {
            guard hasVisiblePet else {
                pythonBridge.error = "请先显示一只宠物，再开启视觉互动"
                return
            }
            let adapter = CameraInteractionAdapter(
                evidenceBuffer: multimodalEvidenceBuffer,
                targetPetIds: { [weak self] in
                    self?.pets.filter { $0.status == .showing }.map(\.id) ?? []
                })
            adapter.onVLMTrigger = { [weak self] petIds in
                self?.submitLocalVLMInference(for: petIds)
            }
            adapter.onStateChange = { [weak self] state in
                self?.handleCameraInteractionState(state)
            }
            cameraInteractionAdapter = adapter
            cameraInteractionEnabled = true
            do {
                try petLauncher.attachInteractionAdapter(adapter)
                try attachConfiguredLocalVLM()
            } catch {
                if let vlmInteractionAdapter {
                    petLauncher.detachInteractionAdapter(vlmInteractionAdapter)
                    self.vlmInteractionAdapter = nil
                }
                petLauncher.detachInteractionAdapter(adapter)
                cameraInteractionAdapter = nil
                cameraInteractionEnabled = false
                cameraInteractionState = .failed(error.localizedDescription)
                pythonBridge.error = "视觉互动启动失败：\(error.localizedDescription)"
            }
        } else {
            stopCameraInteraction()
        }
    }

    private func handleCameraInteractionState(_ state: CameraInteractionState) {
        cameraInteractionState = state
        let message: String?
        switch state {
        case .denied:
            message = "摄像头权限已拒绝，可在系统设置 > 隐私与安全性 > 摄像头中开启"
        case .unavailable:
            message = "没有检测到可用摄像头"
        case .failed(let detail):
            message = "视觉互动启动失败：\(detail)"
        default:
            message = nil
        }
        guard let message else { return }

        let adapter = cameraInteractionAdapter
        cameraInteractionAdapter = nil
        cameraInteractionEnabled = false
        if let adapter {
            petLauncher.detachInteractionAdapter(adapter)
        }
        cameraInteractionState = state
        pythonBridge.error = message
    }

    private func stopCameraInteraction() {
        let adapter = cameraInteractionAdapter
        let vlmAdapter = vlmInteractionAdapter
        cameraInteractionAdapter = nil
        vlmInteractionAdapter = nil
        cameraInteractionEnabled = false
        if let vlmAdapter {
            petLauncher.detachInteractionAdapter(vlmAdapter)
        }
        if let adapter {
            petLauncher.detachInteractionAdapter(adapter)
        } else {
            multimodalEvidenceBuffer.removeAll()
        }
        cameraInteractionState = .disabled
        localVLMRuntimeState = Self.restingVLMState(
            for: localVLMConfiguration)
    }

    func discoverLocalModelInventory(endpoint: String) async throws
        -> OllamaModelInventory {
        let configuration = try LocalVLMConfiguration(
            isEnabled: false, endpoint: endpoint, modelName: nil)
        let catalog = try OllamaModelCatalog(baseURL: configuration.endpointURL)
        return try await catalog.inventory()
    }

    func updateLocalIntelligenceConfigurations(
        endpoint: String,
        visionEnabled: Bool,
        visionModelName: String?
    ) throws {
        let visionConfiguration = try LocalVLMConfiguration(
            isEnabled: visionEnabled,
            endpoint: endpoint,
            modelName: visionModelName)

        LocalVLMConfigurationStore.save(visionConfiguration)
        localVLMConfiguration = visionConfiguration
        localVLMRuntimeState = Self.restingVLMState(for: visionConfiguration)

        if cameraInteractionEnabled {
            stopCameraInteraction()
            setCameraInteractionEnabled(true)
        }
    }

    private func attachConfiguredLocalVLM() throws {
        guard localVLMConfiguration.isEnabled,
              let modelName = localVLMConfiguration.modelName else {
            localVLMRuntimeState = .disabled
            return
        }
        let model = try OllamaVLMModel(
            modelName: modelName,
            baseURL: localVLMConfiguration.endpointURL)
        let adapter = VLMInteractionAdapter(
            model: model,
            evidenceBuffer: multimodalEvidenceBuffer)
        adapter.onInferenceActivityChange = { [weak self, weak adapter] active in
            guard let self,
                  let adapter,
                  self.vlmInteractionAdapter === adapter else { return }
            self.localVLMRuntimeState = active
                ? .inferencing(modelName) : .ready(modelName)
        }
        adapter.onInferenceError = { [weak self, weak adapter] message in
            guard let self,
                  let adapter,
                  self.vlmInteractionAdapter === adapter else { return }
            self.localVLMRuntimeState = .failed(message)
        }
        try petLauncher.attachInteractionAdapter(adapter)
        vlmInteractionAdapter = adapter
        localVLMRuntimeState = .ready(modelName)
    }

    private func submitLocalVLMInference(for petIds: [UUID]) {
        guard let adapter = vlmInteractionAdapter else { return }
        let visiblePetIds = petIds.filter { id in
            pets.contains { $0.id == id && $0.status == .showing }
        }
        _ = adapter.submit(
            petIds: visiblePetIds,
            lookback: 2.0,
            maximumLatency: 10.0)
    }

    private static func restingVLMState(
        for configuration: LocalVLMConfiguration
    ) -> LocalVLMRuntimeState {
        guard configuration.isEnabled,
              let modelName = configuration.modelName else { return .disabled }
        return .ready(modelName)
    }


    private func disableSensorsIfNoVisiblePets() {
        guard !hasVisiblePet else { return }
        if cameraInteractionEnabled { stopCameraInteraction() }
        if speechInteractionEnabled { stopSpeechInteraction() }
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
        pet.framesDir != nil && !hasActiveWorkflow
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
            referenceFramesDirectory: context.rootFramesDirectory) { [weak self] result in
                guard let self,
                      self.activeActionImport == context else { return }
                self.validatingActionPetId = nil
                guard let result,
                      result["passed"] as? Bool == true else {
                    self.failPreparation(
                        petId: context.petId,
                        message: result?["message"] as? String
                            ?? "动作验证失败，请更换素材")
                    return
                }
                let identity = (result["identity"] as? [String: Any])?["similarity"]
                    as? Double
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
                    throw AgnesVideoGenerationError.invalidResponse
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
        } catch {
            try? fm.removeItem(atPath: context.workDirectory)
            activeActionImport = nil
            pendingActionReview = nil
            preparingActionPetId = nil
            validatingActionPetId = nil
            motionWorkflowState = .failed("动作安装失败：\(error.localizedDescription)")
            generatingMotionAction = nil
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
            throw AgnesVideoGenerationError.invalidResponse
        }
        guard let currentPet = pets.first(where: { $0.id == pet.id }) else {
            throw AgnesVideoGenerationError.failed("宠物已被删除")
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
            throw AgnesVideoGenerationError.failed("宠物已被删除")
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
            throw AgnesVideoGenerationError.failed(
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
