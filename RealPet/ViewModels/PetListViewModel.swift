import Combine
import Foundation
import SwiftUI

@MainActor
class PetListViewModel: ObservableObject {
    @Published var pets: [Pet] = []
    @Published var showFilePicker = false
    @Published var showPhotoPicker = false
    @Published var showActionFilePicker = false
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
    @Published private(set) var localBehaviorPlannerConfiguration:
        LocalBehaviorPlannerConfiguration
    @Published private(set) var localBehaviorPlannerRuntimeState:
        LocalBehaviorPlannerRuntimeState
    @Published private(set) var behaviorSnapshots: [UUID: PetBehaviorSnapshot] = [:]
    @Published var personalitySetupPet: Pet?
    @Published private(set) var rigGenerationPetId: UUID?
    @Published private(set) var rigGenerationStage: String?
    @Published var capturePackPet: Pet?
    @Published private(set) var pendingActionReview: PendingActionReview?
    @Published var motionStudioPet: Pet?
    @Published private(set) var motionWorkflowState: MotionWorkflowState = .idle
    @Published private(set) var motionServiceConfiguration: MotionServiceConfiguration

    let pythonBridge = PythonBridge()
    let petLauncher = PetLauncher()
    let multimodalEvidenceBuffer = EphemeralEvidenceBuffer()

    private var pendingActionImportRequest: ActionImportRequest?
    private var generatedInitialPetId: UUID?
    private var motionGenerationTask: Task<Void, Never>?
    private var preparedAgnesReference: (petID: UUID, url: URL)?
    private var cameraInteractionAdapter: CameraInteractionAdapter?
    private var vlmInteractionAdapter: VLMInteractionAdapter?
    private var speechInteractionAdapter: SpeechInteractionAdapter?
    private var behaviorSnapshotsCancellable: AnyCancellable?
    private var behaviorPlanningCoordinator: BehaviorPlanningCoordinator?
    private let templateClassifier = PetTemplateClassifier()

    struct ActionImportRequest {
        let petId: UUID
        let kind: PetActionManifest.Action.Kind
    }

    struct ActiveActionImport: Equatable {
        let petId: UUID
        let kind: PetActionManifest.Action.Kind
        let rootFramesDirectory: String
        let workDirectory: String
        let origin: PetActionManifest.Action.Origin
    }

    struct PendingActionReview: Identifiable, Equatable {
        let id: UUID
        let petId: UUID
        let kind: PetActionManifest.Action.Kind
        let framesDirectory: String
        let frameCount: Int
        let fps: Int
        let identitySimilarity: Double?
        let origin: PetActionManifest.Action.Origin
    }

    struct ClipChoice {
        let start: Double
        let duration: Double
        let score: Double
        let recommended: Bool
    }

    init() {
        let vlmConfiguration = LocalVLMConfigurationStore.load()
        let plannerConfiguration = LocalBehaviorPlannerConfigurationStore.load()
        motionServiceConfiguration = MotionServiceConfigurationStore.load()
        localVLMConfiguration = vlmConfiguration
        localVLMRuntimeState = Self.restingVLMState(for: vlmConfiguration)
        localBehaviorPlannerConfiguration = plannerConfiguration
        localBehaviorPlannerRuntimeState = Self.restingPlannerState(
            for: plannerConfiguration)
        let recovery = Pet.recoveringAfterLaunch(PetStorage.shared.load())
        pets = recovery.pets
        if recovery.changed {
            PetStorage.shared.save(pets)
        }
        behaviorSnapshotsCancellable = petLauncher.$behaviorSnapshots
            .sink { [weak self] snapshots in
                self?.behaviorSnapshots = snapshots
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
        do {
            try configureBehaviorPlanner()
        } catch {
            localBehaviorPlannerRuntimeState = .failed(error.localizedDescription)
        }
    }

    var hasActiveWorkflow: Bool {
        rigGenerationPetId != nil
            || motionWorkflowState.isBusy
            || activeActionImport != nil
            || pendingActionImportRequest != nil
            || pythonBridge.isProcessing
            || pets.contains {
                $0.status == .detecting
                    || $0.status == .detected
                    || $0.status == .processing
            }
    }

    func importVideo(url: URL) {
        guard !hasActiveWorkflow else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let id = UUID()
        let petDir = PetStorage.shared.petDirectory(for: id)
        try? FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)

        let destPath = petDir.appendingPathComponent(url.lastPathComponent).path
        do {
            try FileManager.default.copyItem(atPath: url.path, toPath: destPath)
        } catch {
            pythonBridge.error = "Failed to copy video: \(error.localizedDescription)"
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let pet = Pet(
            id: id,
            name: name,
            sourcePath: destPath,
            framesDir: nil,
            frameCount: 0,
            fps: 10,
            createdAt: Date(),
            status: .detecting
        )
        pets.append(pet)
        PetStorage.shared.save(pets)

        beginPreparation(petId: id, videoPath: destPath, outputDir: petDir.path)
    }

    func importPhotos(urls: [URL]) {
        guard !hasActiveWorkflow else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        guard !urls.isEmpty else { return }
        guard urls.count <= 6 else {
            pythonBridge.error = "一次最多导入 6 张宠物照片"
            return
        }

        let id = UUID()
        let petDirectory = PetStorage.shared.petDirectory(for: id)
        let referencesDirectory = petDirectory.appendingPathComponent("references")
        do {
            try FileManager.default.createDirectory(
                at: referencesDirectory, withIntermediateDirectories: true)
            var copiedPaths: [String] = []
            for (index, sourceURL) in urls.enumerated() {
                let hasSecurityScopedAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScopedAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                let extensionName = sourceURL.pathExtension.isEmpty
                    ? "jpg" : sourceURL.pathExtension.lowercased()
                let destination = referencesDirectory.appendingPathComponent(
                    String(format: "reference-%02d.%@", index + 1, extensionName))
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                copiedPaths.append(destination.path)
            }
            let pet = Pet(
                id: id,
                name: urls[0].deletingPathExtension().lastPathComponent,
                sourcePath: nil,
                framesDir: nil,
                referenceImagePaths: copiedPaths,
                frameCount: 0,
                fps: 10,
                createdAt: Date(),
                status: .draft)
            pets.append(pet)
            PetStorage.shared.save(pets)
            pythonBridge.error = nil
            motionStudioPet = pet
        } catch {
            try? FileManager.default.removeItem(at: petDirectory)
            pythonBridge.error = "照片导入失败：\(error.localizedDescription)"
        }
    }

    func beginActionImport(for pet: Pet, kind: PetActionManifest.Action.Kind) {
        guard !hasActiveWorkflow,
              pet.status == .ready || pet.status == .showing,
              pet.framesDir != nil else {
            pythonBridge.error = "当前有其他任务正在处理"
            return
        }
        pendingActionImportRequest = ActionImportRequest(petId: pet.id, kind: kind)
        showActionFilePicker = true
    }

    func presentMotionStudio(for pet: Pet) {
        guard !referenceImages(for: pet).isEmpty else {
            pythonBridge.error = "找不到这只宠物的参考图"
            return
        }
        guard !motionWorkflowState.isBusy else {
            pythonBridge.error = "当前有动作正在生成"
            return
        }
        motionStudioPet = pets.first(where: { $0.id == pet.id })
    }

    func dismissMotionStudio() {
        guard !motionWorkflowState.isBusy else { return }
        motionStudioPet = nil
        if case .failed = motionWorkflowState {
            motionWorkflowState = .idle
        }
    }

    var hasPromptMotionServiceCredential: Bool {
        guard let key = OpenAIAPIKeyStore.loadPromptMotionService() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAgnesMotionServiceCredential: Bool {
        guard let key = OpenAIAPIKeyStore.loadAgnesMotionService() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasMiniMaxMotionServiceCredential: Bool {
        guard let key = OpenAIAPIKeyStore.loadMiniMaxMotionService() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveMotionServiceConfiguration(
        baseURLString: String,
        promptModel: String,
        agnesBaseURLString: String,
        imageModel: String,
        miniMaxBaseURLString: String,
        videoModel: String,
        seconds: Int,
        size: String,
        promptAPIKey: String?,
        agnesAPIKey: String?,
        miniMaxAPIKey: String?
    ) throws {
        let configuration = try MotionServiceConfiguration(
            baseURLString: baseURLString,
            promptModel: promptModel,
            agnesBaseURLString: agnesBaseURLString,
            imageModel: imageModel,
            miniMaxBaseURLString: miniMaxBaseURLString,
            videoModel: videoModel,
            seconds: seconds,
            size: size).validated()
        if let promptAPIKey {
            let trimmed = promptAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try OpenAIAPIKeyStore.savePromptMotionService(trimmed)
            }
        }
        if let agnesAPIKey {
            let trimmed = agnesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try OpenAIAPIKeyStore.saveAgnesMotionService(trimmed)
            }
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

    func optimizeMotionPrompt(
        for pet: Pet,
        kind: PetActionManifest.Action.Kind,
        naturalLanguage: String
    ) async -> PetMotionPromptOptimization? {
        guard !motionWorkflowState.isBusy else { return nil }
        guard !naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            motionWorkflowState = .failed("请先描述希望宠物做什么动作")
            return nil
        }
        let references = referenceImages(for: pet)
        guard !references.isEmpty else {
            motionWorkflowState = .failed("找不到这只宠物的参考图")
            return nil
        }
        guard let promptAPIKey = OpenAIAPIKeyStore.loadPromptMotionService() else {
            motionWorkflowState = .failed("请先在服务配置中填写中转 Prompt Key")
            return nil
        }
        do {
            let configuration = try motionServiceConfiguration.validated()
            let promptAPIConfiguration = try configuration.validatedPromptAPIConfiguration()
            preparedAgnesReference = nil
            motionWorkflowState = .optimizing
            let result = try await OpenAIPetPromptOptimizer().optimize(
                naturalLanguage: "目标动作：\(kind.displayName)。\(naturalLanguage)",
                referenceImageURLs: references,
                apiKey: promptAPIKey,
                configuration: promptAPIConfiguration,
                model: configuration.promptModel)
            guard motionStudioPet?.id == pet.id else { return nil }
            motionWorkflowState = .optimized
            return result
        } catch {
            motionWorkflowState = .failed(error.localizedDescription)
            return nil
        }
    }

    func generateMotion(
        for pet: Pet,
        kind: PetActionManifest.Action.Kind,
        optimizedPrompt: String
    ) {
        guard !motionWorkflowState.isBusy else { return }
        guard pet.framesDir != nil || kind == .idle else {
            motionWorkflowState = .failed("请先生成待机动作，再生成互动动作")
            return
        }
        guard let agnesAPIKey = OpenAIAPIKeyStore.loadAgnesMotionService() else {
            motionWorkflowState = .failed("请先在服务配置中填写 Agnes API Key")
            return
        }
        guard let miniMaxAPIKey = OpenAIAPIKeyStore.loadMiniMaxMotionService() else {
            motionWorkflowState = .failed("请先在服务配置中填写 MiniMax API Key")
            return
        }
        let prompt = optimizedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            motionWorkflowState = .failed("请先优化提示词")
            return
        }
        do {
            let configuration = try motionServiceConfiguration.validated()
            let agnesAPIConfiguration = try configuration.validatedAgnesAPIConfiguration()
            let miniMaxAPIConfiguration = try configuration.validatedMiniMaxAPIConfiguration()
            guard let imageModel = configuration.imageModel?.trimmingCharacters(
                in: .whitespacesAndNewlines), !imageModel.isEmpty else {
                throw MotionServiceConfigurationError.missingImageModel
            }
            let references = referenceImages(for: pet)
            guard !references.isEmpty else {
                motionWorkflowState = .failed("找不到这只宠物的参考图")
                return
            }
            motionGenerationTask?.cancel()
            motionGenerationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    self.motionWorkflowState = .preparingReference
                    let referenceImageURL = try await AgnesImageReferenceGenerator()
                        .generateReference(
                            referenceImageURLs: references,
                            apiKey: agnesAPIKey,
                            configuration: agnesAPIConfiguration,
                            model: imageModel)
                    self.preparedAgnesReference = (pet.id, referenceImageURL)
                    self.motionWorkflowState = .submittingVideo
                    let client = MiniMaxH3VideoGenerationClient()
                    var job = try await client.create(
                        prompt: prompt,
                        firstFrameURL: referenceImageURL,
                        apiKey: miniMaxAPIKey,
                        configuration: miniMaxAPIConfiguration,
                        seconds: configuration.seconds)
                    while !Task.isCancelled {
                        switch job.status {
                        case .completed:
                            self.motionWorkflowState = .downloadingVideo
                            let video = try await client.downloadContent(job: job)
                            try self.installGeneratedVideo(
                                data: video, for: pet, kind: kind, jobID: job.id)
                            return
                        case .failed(let message):
                            throw MiniMaxH3VideoGenerationError.failed(message)
                        case .queued, .processing:
                            self.motionWorkflowState = .waitingForVideo(
                                progress: nil)
                            try await Task.sleep(for: .seconds(5))
                            try Task.checkCancellation()
                            job = try await client.retrieve(
                                id: job.id,
                                apiKey: miniMaxAPIKey,
                                configuration: miniMaxAPIConfiguration)
                        }
                    }
                } catch is CancellationError {
                    self.motionWorkflowState = .idle
                } catch {
                    self.motionWorkflowState = .failed(error.localizedDescription)
                }
            }
        } catch {
            motionWorkflowState = .failed(error.localizedDescription)
        }
    }

    func cancelMotionGeneration() {
        motionGenerationTask?.cancel()
        motionGenerationTask = nil
        if motionWorkflowState.isBusy {
            motionWorkflowState = .idle
        }
    }

    func presentCapturePack(for pet: Pet) {
        guard pet.framesDir != nil else { return }
        capturePackPet = pets.first(where: { $0.id == pet.id })
    }

    func dismissCapturePack() {
        capturePackPet = nil
    }

    func importActionVideo(url: URL) {
        guard let request = pendingActionImportRequest,
              let pet = pets.first(where: { $0.id == request.petId }),
              let rootFramesDirectory = pet.framesDir else { return }
        pendingActionImportRequest = nil

        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let petDirectory = PetStorage.shared.petDirectory(for: pet.id)
        let workDirectory = petDirectory
            .appendingPathComponent("action_work")
            .appendingPathComponent("\(request.kind.rawValue)-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: workDirectory, withIntermediateDirectories: true)
            let destination = workDirectory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            activeActionImport = ActiveActionImport(
                petId: pet.id,
                kind: request.kind,
                rootFramesDirectory: rootFramesDirectory,
                workDirectory: workDirectory.path,
                origin: .captured)
            beginPreparation(
                petId: pet.id,
                videoPath: destination.path,
                outputDir: workDirectory.path)
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            pythonBridge.error = "动作视频导入失败：\(error.localizedDescription)"
        }
    }

    func cancelActionImportSelection() {
        pendingActionImportRequest = nil
    }

    /// Retry an interrupted or failed import without copying the source again.
    func retryPet(_ pet: Pet) {
        guard pet.status == .failed || pet.status == .interrupted else { return }
        guard !pythonBridge.isProcessing,
              !pets.contains(where: {
                  $0.id != pet.id && ($0.status == .detecting
                                      || $0.status == .detected
                                      || $0.status == .processing)
              }) else {
            pythonBridge.error = "另一个宠物任务正在处理中"
            return
        }
        guard let sourcePath = pet.sourcePath,
              FileManager.default.fileExists(atPath: sourcePath) else {
            pythonBridge.error = "原视频不存在，无法重试"
            return
        }

        let outputDir = PetStorage.shared.petDirectory(for: pet.id).path
        beginPreparation(petId: pet.id, videoPath: sourcePath, outputDir: outputDir)
    }

    private func beginAutomaticRigGeneration(for pet: Pet) {
        guard rigGenerationPetId == nil else {
            failRigGeneration(
                petId: pet.id, message: "另一个宠物正在生成 Live2D 模型")
            return
        }
        guard let profile = pet.templateProfile else {
            failRigGeneration(
                petId: pet.id, message: "无法确定猫狗形态模板")
            return
        }
        guard CubismTemplateResources.discover(
            profile: profile, projectRoot: PythonBridge.projectRoot) != nil else {
            failRigGeneration(
                petId: pet.id,
                message: "应用缺少内置\(profile.displayName) Live2D 模板")
            return
        }

        if interactiveModel(for: pet)?.stage == .partsPrepared,
           let manifestPath = pet.rigManifestPath {
            let atlas = URL(fileURLWithPath: manifestPath)
                .deletingLastPathComponent()
                .appendingPathComponent("atlas.png")
            if FileManager.default.fileExists(atPath: atlas.path) {
                beginPreparedRigCompilation(
                    pet: pet, atlas: atlas, profile: profile)
                return
            }
        }

        guard let apiKey = OpenAIAPIKeyStore.load()?.trimmingCharacters(
            in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            failRigGeneration(
                petId: pet.id, message: "图像服务凭据未配置")
            return
        }
        guard let reference = representativeFrame(for: pet) else {
            failRigGeneration(
                petId: pet.id, message: "找不到可用于建模的宠物参考图")
            return
        }
        beginRigAssetGeneration(
            pet: pet, reference: reference, apiKey: apiKey,
            apiConfiguration: .defaultRelay, profile: profile)
    }

    private func beginPreparedRigCompilation(
        pet: Pet,
        atlas: URL,
        profile: PetTemplateProfile
    ) {
        let petDirectory = PetStorage.shared.petDirectory(for: pet.id)
        let workDirectory = petDirectory
            .appendingPathComponent("rig-compile-work")
            .appendingPathComponent(UUID().uuidString)
        let stagingDirectory = petDirectory
            .appendingPathComponent("rig-next-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: workDirectory, withIntermediateDirectories: true)
        } catch {
            failRigGeneration(
                petId: pet.id, message: "无法创建 Live2D 模型工作目录")
            return
        }
        rigGenerationPetId = pet.id
        rigGenerationStage = "正在自动套用\(profile.displayName)模板…"
        pythonBridge.error = nil
        pythonBridge.prepareRigAtlas(
            atlasPath: atlas.path,
            outputDirectory: stagingDirectory.path,
            profile: profile
        ) { [weak self] result in
            self?.finishRigPreparation(
                pet: pet, workDirectory: workDirectory,
                stagingDirectory: stagingDirectory, result: result)
        }
    }

    private func beginRigAssetGeneration(
        pet: Pet,
        reference: URL,
        apiKey: String,
        apiConfiguration: OpenAIImageAPIConfiguration,
        profile: PetTemplateProfile
    ) {
        let petDirectory = PetStorage.shared.petDirectory(for: pet.id)
        let workDirectory = petDirectory
            .appendingPathComponent("rig-work")
            .appendingPathComponent(UUID().uuidString)
        let stagingDirectory = petDirectory
            .appendingPathComponent("rig-next-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: workDirectory, withIntermediateDirectories: true)
        } catch {
            pythonBridge.error = "无法创建动态素材工作目录"
            return
        }

        rigGenerationPetId = pet.id
        rigGenerationStage = "正在生成宠物部件…"
        pythonBridge.error = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let atlas = try await GPTImage2RigAssetGenerator().generateAtlas(
                    referenceImageURL: reference,
                    apiKey: apiKey,
                    configuration: apiConfiguration,
                    profile: profile)
                let atlasURL = workDirectory.appendingPathComponent("atlas.png")
                try atlas.write(to: atlasURL, options: .atomic)
                self.rigGenerationStage = "正在校验部件并套用动态模板…"
                self.pythonBridge.prepareRigAtlas(
                    atlasPath: atlasURL.path,
                    outputDirectory: stagingDirectory.path,
                    profile: profile
                ) { [weak self] result in
                    self?.finishRigPreparation(
                        pet: pet,
                        workDirectory: workDirectory,
                        stagingDirectory: stagingDirectory,
                        result: result)
                }
            } catch {
                try? FileManager.default.removeItem(at: workDirectory)
                try? FileManager.default.removeItem(at: stagingDirectory)
                self.failRigGeneration(
                    petId: pet.id, message: error.localizedDescription)
            }
        }
    }

    private func failRigGeneration(petId: UUID, message: String) {
        rigGenerationPetId = nil
        rigGenerationStage = nil
        if let index = pets.firstIndex(where: { $0.id == petId }) {
            pets[index].status = .failed
            PetStorage.shared.save(pets)
        }
        pythonBridge.error = message
    }

    private func beginPreparation(petId: UUID, videoPath: String, outputDir: String) {
        pythonBridge.error = nil
        if activeActionImport?.petId != petId {
            updatePetStatus(id: petId, status: .detecting)
        }

        // Step 0: Quality gate — reject bad videos before clip analysis.
        pythonBridge.qualityCheck(videoPath: videoPath, outputDir: outputDir) { [weak self] qcResult in
            guard let self = self else { return }
            if let qc = qcResult, (qc["passed"] as? Bool) == false {
                let reason = qc["message"] as? String ?? "素材不合格"
                self.failPreparation(petId: petId, message: reason)
                return
            }
            // QC passed → continue to clip analysis.
            self.pythonBridge.analyzeClips(
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
        } // QC gate closure
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
        updatePetStatus(id: petId, status: .processing)
        pythonBridge.statusText = "正在提取真实宠物画面…"
        if let index = pets.firstIndex(where: { $0.id == petId }) {
            pets[index].detectedAnimalClass = detectedClass
            pets[index].rendererKind = .sourceFrames
            PetStorage.shared.save(pets)
        }
        pythonBridge.startWithClick(
            videoPath: videoPath, outputDir: outputDir,
            clickX: clickX, clickY: clickY, bbox: bbox,
            startTime: startTime, duration: duration)
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
        pythonBridge.error = message
    }

    /// Update pet status by id
    private func updatePetStatus(id: UUID, status: PetStatus) {
        if let idx = pets.firstIndex(where: { $0.id == id }) {
            pets[idx].status = status
            PetStorage.shared.save(pets)
        }
    }

    /// Final processing complete
    @objc private func onProcessingComplete(_ notification: Notification) {
        guard let info = notification.userInfo as? [String: Any] else { return }

        let framesDir = info["frames_dir"] as? String
            ?? info["segmented_dir"] as? String
        let frameCount = info["frame_count"] as? Int ?? info["frames"] as? Int

        guard let framesDir = framesDir, let frameCount = frameCount else { return }

        if activeActionImport != nil {
            prepareOrValidateActionImport(
                framesDirectory: framesDir, frameCount: frameCount)
            return
        }

        if let idx = pets.lastIndex(where: { $0.status == .processing }) {
            pets[idx].framesDir = framesDir
            pets[idx].frameCount = frameCount
            pets[idx].rendererKind = .sourceFrames
            let idleManifest = PetActionManifest(
                version: PetActionManifest.currentVersion,
                defaultAction: "idle",
                actions: [PetActionManifest.Action(
                    id: "idle", kind: .idle, framesDirectory: ".",
                    fps: max(1, pets[idx].fps), loop: true,
                    translatesWindow: false,
                    origin: generatedInitialPetId == pets[idx].id
                        ? .generated : .captured)])
            try? idleManifest.save(framesDirectory: framesDir)
            let petId = pets[idx].id
            pets[idx].status = .processing
            PetStorage.shared.save(pets)
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
        PetStorage.shared.save(pets)
        if petLauncher.launch(pet: pets[index]) {
            pets[index].status = .showing
            PetStorage.shared.save(pets)
            pythonBridge.error = nil
        } else {
            pets[index].status = .failed
            PetStorage.shared.save(pets)
            pythonBridge.error = petLauncher.lastRuntimeError
                ?? "无法启动真实宠物桌面窗口"
        }
        if generatedInitialPetId == petId {
            generatedInitialPetId = nil
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
        PetStorage.shared.save(pets)
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
        PetStorage.shared.save(pets)
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
            PetStorage.shared.save(pets)
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
        PetStorage.shared.save(pets)
    }

    func hidePet(_ pet: Pet) {
        petLauncher.stop(petId: pet.id)
        if let idx = pets.firstIndex(where: { $0.id == pet.id }) {
            pets[idx].status = .ready  // always reset, even if process was already dead
            PetStorage.shared.save(pets)
        }
        disableSensorsIfNoVisiblePets()
    }

    func deletePet(_ pet: Pet) {
        guard activeActionImport?.petId != pet.id else {
            pythonBridge.error = "动作制作期间不能删除该宠物，请先停止处理"
            return
        }
        petLauncher.stop(petId: pet.id)
        PetStorage.shared.deletePet(pet)
        pets.removeAll { $0.id == pet.id }
        PetStorage.shared.save(pets)
        disableSensorsIfNoVisiblePets()
    }

    func setPersonality(_ preset: PetPersonality.Preset, for pet: Pet) {
        setPersonality(.forPreset(preset), for: pet)
    }

    func setPersonality(_ personality: PetPersonality, for pet: Pet) {
        guard let idx = pets.firstIndex(where: { $0.id == pet.id }) else { return }
        pets[idx].personality = personality
        PetStorage.shared.save(pets)
        if petLauncher.isRunning(petId: pet.id) {
            petLauncher.updatePersonality(petId: pet.id, personality: personality)
        }
    }

    func presentPersonalityEditor(for pet: Pet) {
        personalitySetupPet = pets.first(where: { $0.id == pet.id })
    }

    func cancelPersonalityEditor() {
        personalitySetupPet = nil
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
        let vision = localVLMHelp
        let behavior: String
        switch localBehaviorPlannerRuntimeState {
        case .disabled:
            behavior = "行为模型未启用"
        case .ready(let model):
            behavior = "行为模型已就绪：\(model)"
        case .planning(let model):
            behavior = "\(model) 正在规划下一行为"
        case .failed(let message):
            behavior = "行为模型调用失败：\(message)"
        }
        return "\(vision)；\(behavior)"
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
        let configuration = try LocalBehaviorPlannerConfiguration(
            isEnabled: false, endpoint: endpoint, modelName: nil)
        let catalog = try OllamaModelCatalog(baseURL: configuration.endpointURL)
        return try await catalog.inventory()
    }

    func updateLocalIntelligenceConfigurations(
        endpoint: String,
        visionEnabled: Bool,
        visionModelName: String?,
        behaviorEnabled: Bool,
        behaviorModelName: String?
    ) throws {
        let visionConfiguration = try LocalVLMConfiguration(
            isEnabled: visionEnabled,
            endpoint: endpoint,
            modelName: visionModelName)
        let plannerConfiguration = try LocalBehaviorPlannerConfiguration(
            isEnabled: behaviorEnabled,
            endpoint: endpoint,
            modelName: behaviorModelName)

        LocalVLMConfigurationStore.save(visionConfiguration)
        LocalBehaviorPlannerConfigurationStore.save(plannerConfiguration)
        localVLMConfiguration = visionConfiguration
        localVLMRuntimeState = Self.restingVLMState(for: visionConfiguration)
        localBehaviorPlannerConfiguration = plannerConfiguration
        localBehaviorPlannerRuntimeState = Self.restingPlannerState(
            for: plannerConfiguration)
        try configureBehaviorPlanner()

        if cameraInteractionEnabled {
            stopCameraInteraction()
            setCameraInteractionEnabled(true)
        }
    }

    private func configureBehaviorPlanner() throws {
        behaviorPlanningCoordinator?.cancelCurrent()
        behaviorPlanningCoordinator = nil
        petLauncher.setBehaviorPlanningCoordinator(nil)
        guard localBehaviorPlannerConfiguration.isEnabled,
              let modelName = localBehaviorPlannerConfiguration.modelName else {
            localBehaviorPlannerRuntimeState = .disabled
            return
        }
        let model = try OllamaBehaviorPlanningModel(
            modelName: modelName,
            baseURL: localBehaviorPlannerConfiguration.endpointURL)
        let coordinator = BehaviorPlanningCoordinator(model: model)
        coordinator.onActivityChange = { [weak self, weak coordinator] active in
            guard let self,
                  let coordinator,
                  self.behaviorPlanningCoordinator === coordinator else { return }
            self.localBehaviorPlannerRuntimeState = active
                ? .planning(modelName) : .ready(modelName)
        }
        coordinator.onError = { [weak self, weak coordinator] message in
            guard let self,
                  let coordinator,
                  self.behaviorPlanningCoordinator === coordinator else { return }
            self.localBehaviorPlannerRuntimeState = .failed(message)
        }
        behaviorPlanningCoordinator = coordinator
        petLauncher.setBehaviorPlanningCoordinator(coordinator)
        localBehaviorPlannerRuntimeState = .ready(modelName)
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

    private static func restingPlannerState(
        for configuration: LocalBehaviorPlannerConfiguration
    ) -> LocalBehaviorPlannerRuntimeState {
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

    func interactiveModel(for pet: Pet) -> InteractivePetModelManifest? {
        guard let path = pet.rigManifestPath else { return nil }
        return InteractivePetModelManifest.load(at: path)
    }

    func canShowPet(_ pet: Pet) -> Bool {
        pet.status == .showing || petLauncher.canLaunch(pet: pet)
    }

    func rigGenerationLabel(for pet: Pet) -> String? {
        guard rigGenerationPetId == pet.id else { return nil }
        return rigGenerationStage ?? "正在生成动态素材…"
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

    private func finishRigPreparation(
        pet: Pet,
        workDirectory: URL,
        stagingDirectory: URL,
        result: [String: Any]?
    ) {
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
            rigGenerationPetId = nil
            rigGenerationStage = nil
        }
        guard result?["prepared"] as? Bool == true,
              result?["compiled"] as? Bool == true else {
            try? FileManager.default.removeItem(at: stagingDirectory)
            failRigGeneration(
                petId: pet.id,
                message: result?["message"] as? String
                    ?? "内置 Live2D 模板安装失败")
            return
        }
        if let expectedProfile = pet.templateProfile,
           result?["profile"] as? String != expectedProfile.rawValue {
            try? FileManager.default.removeItem(at: stagingDirectory)
            failRigGeneration(
                petId: pet.id, message: "Live2D 模板类型与宠物分类不匹配")
            return
        }

        let fm = FileManager.default
        let finalDirectory = PetStorage.shared.petDirectory(for: pet.id)
            .appendingPathComponent("rig")
        let backupDirectory = finalDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("rig-old-\(UUID().uuidString)")
        do {
            if fm.fileExists(atPath: finalDirectory.path) {
                try fm.moveItem(at: finalDirectory, to: backupDirectory)
            }
            do {
                try fm.moveItem(at: stagingDirectory, to: finalDirectory)
            } catch {
                if fm.fileExists(atPath: backupDirectory.path) {
                    try? fm.moveItem(at: backupDirectory, to: finalDirectory)
                }
                throw error
            }
            try? fm.removeItem(at: backupDirectory)
            guard let index = pets.firstIndex(where: { $0.id == pet.id }) else {
                return
            }
            pets[index].rigManifestPath = finalDirectory
                .appendingPathComponent("rig.json").path
            guard petLauncher.launch(pet: pets[index]) else {
                let message = petLauncher.lastRuntimeError
                    ?? "Live2D 模型安装后无法启动"
                failRigGeneration(petId: pet.id, message: message)
                return
            }
            pets[index].status = .showing
            PetStorage.shared.save(pets)
            pythonBridge.error = nil
        } catch {
            try? fm.removeItem(at: stagingDirectory)
            failRigGeneration(
                petId: pet.id,
                message: "Live2D 模型安装失败：\(error.localizedDescription)")
        }
    }

    private func prepareOrValidateActionImport(
        framesDirectory: String,
        frameCount: Int
    ) {
        guard let context = activeActionImport else { return }
        guard [.react, .shakeHead, .play, .lieDown, .paw, .eat].contains(context.kind) else {
            validateActionImport(
                framesDirectory: framesDirectory, frameCount: frameCount)
            return
        }

        preparingActionPetId = context.petId
        let outputDirectory = URL(fileURLWithPath: context.workDirectory)
            .appendingPathComponent("prepared-\(UUID().uuidString)").path
        pythonBridge.prepareAction(
            framesDirectory: framesDirectory,
            outputDirectory: outputDirectory,
            kind: context.kind.rawValue,
            fps: 10) { [weak self] result in
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
                self.validateActionImport(
                    framesDirectory: preparedDirectory,
                    frameCount: preparedFrameCount)
            }
    }

    private func validateActionImport(framesDirectory: String, frameCount: Int) {
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
                self.capturePackPet = nil
                self.pendingActionReview = PendingActionReview(
                    id: UUID(), petId: context.petId, kind: context.kind,
                    framesDirectory: framesDirectory, frameCount: frameCount,
                    fps: 10, identitySimilarity: identity,
                    origin: context.origin)
            }
    }

    func acceptPendingActionReview() {
        guard let review = pendingActionReview else { return }
        pendingActionReview = nil
        installActionImport(
            framesDirectory: review.framesDirectory,
            frameCount: review.frameCount)
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

    private func installActionImport(framesDirectory: String, frameCount: Int) {
        guard let context = activeActionImport,
              frameCount > 0 else { return }
        let fm = FileManager.default
        let source = URL(fileURLWithPath: framesDirectory)
        let root = URL(fileURLWithPath: context.rootFramesDirectory)

        do {
            try PetActionLibrary.install(
                kind: context.kind,
                processedFramesDirectory: source,
                rootFramesDirectory: root,
                fps: 10,
                origin: context.origin)
            try? fm.removeItem(atPath: context.workDirectory)
            activeActionImport = nil
            pendingActionReview = nil
            preparingActionPetId = nil
            validatingActionPetId = nil
            actionLibraryRevision += 1
            motionWorkflowState = .idle
            pythonBridge.error = nil

            if let pet = pets.first(where: {
                $0.id == context.petId && $0.status == .showing
            }) {
                petLauncher.launch(pet: pet)
                if let message = petLauncher.lastRuntimeError {
                    pythonBridge.error = message
                }
            }
        } catch {
            try? fm.removeItem(atPath: context.workDirectory)
            activeActionImport = nil
            pendingActionReview = nil
            preparingActionPetId = nil
            validatingActionPetId = nil
            motionWorkflowState = .failed("动作安装失败：\(error.localizedDescription)")
            pythonBridge.error = "动作安装失败：\(error.localizedDescription)"
        }
    }

    private func installGeneratedVideo(
        data: Data,
        for pet: Pet,
        kind: PetActionManifest.Action.Kind,
        jobID: String
    ) throws {
        guard !data.isEmpty else {
            throw MiniMaxH3VideoGenerationError.invalidResponse
        }
        guard let currentPet = pets.first(where: { $0.id == pet.id }) else {
            throw MiniMaxH3VideoGenerationError.failed("宠物已被删除")
        }
        let petDirectory = PetStorage.shared.petDirectory(for: currentPet.id)
        let workDirectory = petDirectory
            .appendingPathComponent("generated-video")
            .appendingPathComponent("\(kind.rawValue)-\(jobID)")
        try FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: true)
        let videoURL = workDirectory.appendingPathComponent("generated.mp4")
        try data.write(to: videoURL, options: .atomic)

        motionWorkflowState = .installing
        motionStudioPet = nil
        if let rootFramesDirectory = currentPet.framesDir {
            activeActionImport = ActiveActionImport(
                petId: currentPet.id,
                kind: kind,
                rootFramesDirectory: rootFramesDirectory,
                workDirectory: workDirectory.path,
                origin: .generated)
            beginPreparation(
                petId: currentPet.id,
                videoPath: videoURL.path,
                outputDir: workDirectory.path)
        } else {
            generatedInitialPetId = currentPet.id
            if let index = pets.firstIndex(where: { $0.id == currentPet.id }) {
                pets[index].sourcePath = videoURL.path
                pets[index].status = .detecting
                PetStorage.shared.save(pets)
            }
            beginPreparation(
                petId: currentPet.id,
                videoPath: videoURL.path,
                outputDir: petDirectory.path)
        }
    }

    private func referenceImages(for pet: Pet) -> [URL] {
        let ownerImages = pet.referenceImages.map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !ownerImages.isEmpty { return ownerImages }
        if let representative = representativeFrame(for: pet) {
            return [representative]
        }
        return []
    }

    func motionReferenceImages(for pet: Pet) -> [URL] {
        referenceImages(for: pet)
    }

    private static func normalizedVideoProgress(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return value > 1 ? min(1, value / 100) : min(1, max(0, value))
    }
}
