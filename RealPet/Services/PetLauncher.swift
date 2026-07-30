import Foundation

@MainActor
class PetLauncher: ObservableObject {
    private var runningPets: [UUID: any PetRuntimeController] = [:]
    private var supplementalAdapters: [ObjectIdentifier: InteractionAdapter] = [:]
    @Published private(set) var lastRuntimeError: String?
    @Published private(set) var behaviorSnapshots: [UUID: PetBehaviorSnapshot] = [:]
    let interactionHub = InteractionHub()

    private lazy var interactionAdapterBus = InteractionAdapterBus(
        hub: interactionHub)

    private lazy var behaviorDirector = PetBehaviorDirector(
        hub: interactionHub,
        onStateChange: { [weak self] petId, snapshot in
            self?.behaviorSnapshots[petId] = snapshot
        }) { [weak self] petId, command in
            self?.runningPets[petId]?.send(command)
        }

    @discardableResult
    func launch(pet: Pet) -> Bool {
        lastRuntimeError = nil
        if let configuration = sourceFrameConfiguration(for: pet) {
            let runtime = FrameSequencePetRuntime(
                petId: pet.id,
                framesDirectory: configuration.framesDirectory,
                fps: configuration.fps,
                startHidden: false)
            let started = activate(
                runtime,
                personality: pet.personality ?? .balanced,
                capabilities: configuration.capabilities)
            if started { lastRuntimeError = nil }
            return started
        }
        guard let configuration = live2DConfiguration(for: pet) else {
            return false
        }
        let runtime = CubismWebPetRuntime(
            petId: pet.id,
            modelURL: configuration.modelURL,
            resources: configuration.resources,
            startHidden: false)
        let started = activate(
            runtime,
            personality: pet.personality ?? .balanced,
            capabilities: configuration.manifest.runtimeCapabilities)
        if started {
            lastRuntimeError = nil
        }
        return started
    }

    func canLaunch(pet: Pet) -> Bool {
        sourceFrameConfiguration(for: pet) != nil
            || live2DConfiguration(for: pet, publishError: false) != nil
    }

    func stop(petId: UUID) {
        let runtime = runningPets.removeValue(forKey: petId)
        behaviorDirector.unregister(petId: petId)
        behaviorSnapshots.removeValue(forKey: petId)
        runtime?.terminate()
    }

    func isRunning(petId: UUID) -> Bool {
        runningPets[petId]?.isRunning == true
    }

    func updatePersonality(petId: UUID, personality: PetPersonality) {
        behaviorDirector.updatePersonality(petId: petId, personality: personality)
    }

    func setBehaviorPlanningCoordinator(
        _ coordinator: BehaviorPlanningCoordinator?
    ) {
        behaviorDirector.setPlanningCoordinator(coordinator)
    }

    func attachInteractionAdapter(_ adapter: InteractionAdapter) throws {
        let id = ObjectIdentifier(adapter)
        guard supplementalAdapters[id] == nil else { return }
        interactionAdapterBus.bind(adapter)
        supplementalAdapters[id] = adapter
        do {
            try adapter.start()
        } catch {
            supplementalAdapters.removeValue(forKey: id)
            interactionAdapterBus.unbind(adapter)
            throw error
        }
    }

    func detachInteractionAdapter(_ adapter: InteractionAdapter) {
        let id = ObjectIdentifier(adapter)
        supplementalAdapters.removeValue(forKey: id)
        interactionAdapterBus.unbind(adapter)
        adapter.stop()
    }

    func stopAll() {
        behaviorDirector.cancelPlanning()
        let runtimes = runningPets
        runningPets.removeAll()
        for (petId, runtime) in runtimes {
            behaviorDirector.unregister(petId: petId)
            runtime.terminate()
        }
        behaviorSnapshots.removeAll()
        let adapters = supplementalAdapters.values
        supplementalAdapters.removeAll()
        for adapter in adapters {
            interactionAdapterBus.unbind(adapter)
            adapter.stop()
        }
    }

    @discardableResult
    private func activate(
        _ runtime: any PetRuntimeController,
        personality: PetPersonality,
        capabilities: PetActionCapabilities
    ) -> Bool {
        let petId = runtime.petId
        interactionAdapterBus.bind(runtime)
        runtime.onTermination = { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.interactionAdapterBus.unbind(runtime)
            if let current = self.runningPets[petId], current === runtime {
                self.runningPets.removeValue(forKey: petId)
                self.behaviorDirector.unregister(petId: petId)
                self.behaviorSnapshots.removeValue(forKey: petId)
                NotificationCenter.default.post(
                    name: .petStopped,
                    object: nil,
                    userInfo: ["petId": petId])
            }
        }

        do {
            try runtime.start()
        } catch {
            interactionAdapterBus.unbind(runtime)
            lastRuntimeError = error.localizedDescription
            fputs("PET RUNTIME START ERROR: \(error.localizedDescription)\n", stderr)
            return false
        }

        let previous = runningPets[petId]
        runningPets[petId] = runtime
        behaviorDirector.register(
            petId: petId,
            personality: personality,
            capabilities: capabilities)
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                previous.terminate()
            }
        }
        return true
    }

    private struct Live2DConfiguration {
        let manifest: InteractivePetModelManifest
        let modelURL: URL
        let resources: CubismWebRuntimeResources
    }

    private struct SourceFrameConfiguration {
        let framesDirectory: URL
        let fps: Int
        let capabilities: PetActionCapabilities
    }

    private func sourceFrameConfiguration(for pet: Pet) -> SourceFrameConfiguration? {
        guard pet.preferredRenderer == .sourceFrames,
              let framesPath = pet.framesDir else { return nil }
        let framesDirectory = URL(fileURLWithPath: framesPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard (try? SourceFrameSequence.load(
            at: framesDirectory, fps: pet.fps)) != nil else { return nil }
        return SourceFrameConfiguration(
            framesDirectory: framesDirectory,
            fps: pet.fps,
            capabilities: SourceFrameActionResolver.capabilities(
                framesDirectory: framesDirectory))
    }

    private func live2DConfiguration(
        for pet: Pet,
        publishError: Bool = true
    ) -> Live2DConfiguration? {
        func fail(_ message: String) -> Live2DConfiguration? {
            if publishError { lastRuntimeError = message }
            return nil
        }

        guard let manifestPath = pet.rigManifestPath else {
            return fail("尚未生成完整 Live2D 模型，请重试自动制作")
        }
        guard let manifest = InteractivePetModelManifest.load(at: manifestPath) else {
            return fail("Live2D 模型清单损坏或版本不兼容，请重新生成")
        }
        guard manifest.isRuntimeReady else {
            switch manifest.stage {
            case .partsPrepared:
                return fail("Live2D 部件已准备，但自动模板安装尚未完成，请重试")
            case .cubismCompiled:
                return fail("Live2D 模型能力配置不完整，请重新导入已编译模型")
            }
        }
        guard let modelURL = manifest.resolvedModelURL(
            manifestPath: manifestPath) else {
            return fail("找不到 Live2D .model3.json，请重新导入已编译模型")
        }
        do {
            try CubismModelPackageValidator.validate(modelURL: modelURL)
        } catch {
            return fail(error.localizedDescription)
        }
        guard let resources = CubismWebRuntimeResources.discover(
            projectRoot: PythonBridge.projectRoot) else {
            return fail("缺少已授权的 Live2D Cubism Web Core/Runtime/Shaders")
        }
        return Live2DConfiguration(
            manifest: manifest, modelURL: modelURL, resources: resources)
    }
}

extension Notification.Name {
    static let petStopped = Notification.Name("petStopped")
}
