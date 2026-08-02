import Foundation

@main
struct CubismRuntimeContractCheck {
    static func main() throws {
        try testManifestRuntimeGateAndPathResolution()
        try testRuntimeResourceDiscovery()
        try testResourcePathContainment()
        testParameterMapping()
        testWindowMotionPlanner()
        testPettingGestureRecognizer()
        testProceduralMotionSynthesis()
        print("Cubism runtime contract checks passed")
    }

    private static func testManifestRuntimeGateAndPathResolution() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDirectory, withIntermediateDirectories: true)
        let modelURL = modelDirectory.appendingPathComponent("pet.model3.json")
        try Data("moc".utf8).write(
            to: modelDirectory.appendingPathComponent("pet.moc3"))
        try Data("texture".utf8).write(
            to: modelDirectory.appendingPathComponent("pet.png"))
        let modelJSON = """
        {"Version":3,"FileReferences":{"Moc":"pet.moc3","Textures":["pet.png"]}}
        """
        try Data(modelJSON.utf8).write(to: modelURL)
        let manifestURL = root.appendingPathComponent("rig.json")

        let prepared = InteractivePetModelManifest(
            version: 1, targetRenderer: .live2dCubism,
            stage: .partsPrepared, sourceModel: "gpt-image-2",
            template: "quadruped-v1", atlas: "atlas.png", parts: [:],
            capabilities: .init(
                headPose: false, eyeGaze: false, breathing: false))
        precondition(!prepared.isRuntimeReady)
        precondition(!prepared.runtimeCapabilities.orientation)

        let compiled = InteractivePetModelManifest(
            version: 1, targetRenderer: .live2dCubism,
            stage: .cubismCompiled, sourceModel: "gpt-image-2",
            template: "quadruped-v1", atlas: "atlas.png", parts: [:],
            model: "model/pet.model3.json",
            capabilities: .init(
                headPose: true, eyeGaze: true, breathing: true))
        let encoded = try JSONEncoder().encode(compiled)
        try encoded.write(to: manifestURL)
        precondition(InteractivePetModelManifest.load(at: manifestURL.path) == compiled)
        precondition(compiled.resolvedModelURL(manifestPath: manifestURL.path) == modelURL)
        try CubismModelPackageValidator.validate(modelURL: modelURL)
        precondition(compiled.runtimeCapabilities.orientation)
        precondition(!compiled.runtimeCapabilities.locomotion)
        precondition(!compiled.runtimeCapabilities.reaction)

        let animated = InteractivePetModelManifest(
            version: 1, targetRenderer: .live2dCubism,
            stage: .cubismCompiled, sourceModel: "gpt-image-2",
            template: "quadruped-v1", atlas: "atlas.png", parts: [:],
            model: "model/pet.model3.json",
            capabilities: .init(
                headPose: true, eyeGaze: true, breathing: true,
                locomotion: true, reaction: true))
        precondition(animated.runtimeCapabilities.locomotion)
        precondition(animated.runtimeCapabilities.reaction)

        let escaping = InteractivePetModelManifest(
            version: 1, targetRenderer: .live2dCubism,
            stage: .cubismCompiled, sourceModel: "gpt-image-2",
            template: "quadruped-v1", atlas: "atlas.png", parts: [:],
            model: "../outside.model3.json",
            capabilities: .init(
                headPose: true, eyeGaze: true, breathing: true))
        precondition(escaping.resolvedModelURL(manifestPath: manifestURL.path) == nil)

        try FileManager.default.removeItem(
            at: modelDirectory.appendingPathComponent("pet.moc3"))
        do {
            try CubismModelPackageValidator.validate(modelURL: modelURL)
            preconditionFailure("missing moc3 must be rejected")
        } catch CubismModelPackageError.missingReferencedFile("pet.moc3") {
            // Expected.
        }

        // Version 1 manifests created before `model` was added remain readable.
        let legacy = """
        {"version":1,"targetRenderer":"live2dCubism","stage":"partsPrepared",
        "sourceModel":"gpt-image-2","template":"quadruped-v1","atlas":"atlas.png",
        "parts":{},"capabilities":{"headPose":false,"eyeGaze":false,"breathing":false}}
        """
        let decodedLegacy = try JSONDecoder().decode(
            InteractivePetModelManifest.self, from: Data(legacy.utf8))
        precondition(decodedLegacy.model == nil)
        precondition(!decodedLegacy.isRuntimeReady)
        precondition(!decodedLegacy.capabilities.locomotion)
        precondition(!decodedLegacy.capabilities.reaction)
    }

    private static func testRuntimeResourceDiscovery() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        precondition(CubismWebRuntimeResources.discover(
            environment: [:], bundleResources: root, projectRoot: nil,
            applicationSupport: nil) == nil)

        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let shaders = runtime.appendingPathComponent("shaders", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shaders, withIntermediateDirectories: true)
        for relative in [
            "live2dcubismcore.min.js", "realpet-cubism.bundle.js",
            "CUBISM_SDK_LICENSE.md", "LIVE2D_OPEN_SOFTWARE_LICENSE.md",
            "shaders/CubismShader_WebGL.frag",
        ] {
            let size = relative.hasSuffix(".js") ? 12_000 : 80
            try Data(repeating: 1, count: size).write(
                to: runtime.appendingPathComponent(relative))
        }
        let found = CubismWebRuntimeResources.discover(
            environment: ["REALPET_CUBISM_WEB_RUNTIME": runtime.path],
            bundleResources: nil, projectRoot: nil, applicationSupport: nil)
        precondition(found?.root == runtime.standardizedFileURL)

        try FileManager.default.removeItem(
            at: runtime.appendingPathComponent("CUBISM_SDK_LICENSE.md"))
        precondition(CubismWebRuntimeResources.discover(
            environment: ["REALPET_CUBISM_WEB_RUNTIME": runtime.path],
            bundleResources: nil, projectRoot: nil,
            applicationSupport: nil) == nil)
    }

    private static func testResourcePathContainment() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let model = root.appendingPathComponent("pet.model3.json")
        try Data("{}".utf8).write(to: model)
        let normal = URL(string: "realpet://model/pet.model3.json")!
        precondition(CubismResourcePathResolver.resolve(
            url: normal, beneath: root) == model.standardizedFileURL)

        let traversal = URL(string: "realpet://model/%2E%2E/secret")!
        precondition(CubismResourcePathResolver.resolve(
            url: traversal, beneath: root) == nil)

        let secret = outside.appendingPathComponent("secret")
        try Data("secret".utf8).write(to: secret)
        let symlink = root.appendingPathComponent("linked-secret")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secret)
        let linked = URL(string: "realpet://model/linked-secret")!
        precondition(CubismResourcePathResolver.resolve(
            url: linked, beneath: root) == nil)
    }

    private static func testParameterMapping() {
        let parameters = CubismParameterMapper.parameters(
            target: SpatialContext(
                space: .petLocalNormalized, x: 1, y: 0),
            windowCenter: nil, intensity: 1)
        precondition(parameters?[CubismParameterMapper.angleX] == 30)
        precondition(parameters?[CubismParameterMapper.angleY] == -20)
        precondition(parameters?[CubismParameterMapper.angleZ] == -3)
        precondition(parameters?[CubismParameterMapper.bodyAngleX] == 8)
        precondition(parameters?[CubismParameterMapper.eyeX] == 1)
        precondition(parameters?[CubismParameterMapper.eyeY] == -1)
        let centered = CubismParameterMapper.parameters(
            normalizedDeltaX: 0.02, normalizedDeltaY: -0.02, intensity: 1)
        precondition(centered.values.allSatisfy { $0 == 0 })
        let following = CubismParameterMapper.parameters(
            normalizedDeltaX: 0.5, normalizedDeltaY: 0.5, intensity: 1)
        precondition((following[CubismParameterMapper.eyeX] ?? 0) > 0.45)
        precondition((following[CubismParameterMapper.angleX] ?? 0) > 13)
        precondition((following[CubismParameterMapper.angleY] ?? 0) > 9)
        precondition((following[CubismParameterMapper.angleZ] ?? 0) < -1.4)
        precondition(CubismParameterMapper.parameters(
            target: SpatialContext(
                space: .cameraNormalized, x: 0.5, y: 0.5),
            windowCenter: nil, intensity: 1) == nil)
    }

    private static func testWindowMotionPlanner() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let window = NSRect(x: 100, y: 100, width: 200, height: 200)
        let target = SpatialContext(
            space: .screenNormalized, x: 0.9, y: 0.8)
        let toward = CubismWindowMotionPlanner.plan(
            action: .moveToward, target: target,
            windowFrame: window, visibleFrame: visible,
            duration: 1.5, intensity: 1)
        precondition(toward != nil)
        precondition(toward!.targetOrigin.x > window.origin.x)
        precondition(toward!.targetOrigin.y > window.origin.y)
        precondition(toward!.duration == 1.5)

        let away = CubismWindowMotionPlanner.plan(
            action: .moveAway, target: target,
            windowFrame: window, visibleFrame: visible,
            duration: 0, intensity: 1)
        precondition(away != nil)
        precondition(away!.targetOrigin.x <= window.origin.x)
        precondition(away!.duration == 0.2)

        let exact = CubismWindowMotionPlanner.plan(
            action: .moveTo, target: target,
            windowFrame: window, visibleFrame: visible,
            duration: 20, intensity: 0.5)
        precondition(exact?.targetOrigin == NSPoint(x: 800, y: 540))
        precondition(exact?.duration == 10)
        precondition(CubismWindowMotionPlanner.plan(
            action: .moveTo,
            target: SpatialContext(
                space: .cameraNormalized, x: 0.5, y: 0.5),
            windowFrame: window, visibleFrame: visible,
            duration: 1, intensity: 1) == nil)
    }

    private static func testPettingGestureRecognizer() {
        var recognizer = PettingGestureRecognizer()
        precondition(!recognizer.update(x: 0, y: 10, at: 0))
        precondition(!recognizer.update(x: 40, y: 10, at: 0.1))
        precondition(recognizer.update(x: 0, y: 10, at: 0.2))

        // The cooldown prevents a continuous stroke from flooding observations.
        precondition(!recognizer.update(x: 40, y: 10, at: 0.3))
        precondition(!recognizer.update(x: 0, y: 10, at: 0.4))

        // A long pause resets the path; a later complete stroke can emit again.
        precondition(!recognizer.update(x: 0, y: 10, at: 1.6))
        precondition(!recognizer.update(x: 40, y: 10, at: 1.7))
        precondition(recognizer.update(x: 0, y: 10, at: 1.8))

        var oneWay = PettingGestureRecognizer()
        precondition(!oneWay.update(x: 0, y: 0, at: 0))
        precondition(!oneWay.update(x: 40, y: 0, at: 0.1))
        precondition(!oneWay.update(x: 80, y: 0, at: 0.2))

        var vertical = PettingGestureRecognizer()
        precondition(!vertical.update(x: 10, y: 0, at: 0))
        precondition(!vertical.update(x: 10, y: 40, at: 0.1))
        precondition(!vertical.update(x: 10, y: 0, at: 0.2))
    }

    private static func testProceduralMotionSynthesis() {
        let clips = Dictionary(uniqueKeysWithValues:
            CubismSemanticAction.allCases.map {
                ($0, CubismProceduralMotionSynthesizer.clip(
                    action: $0, intensity: 1))
            })
        for (action, clip) in clips {
            precondition(clip.action == action)
            precondition(clip.frames.count >= 2)
            precondition(clip.loop == action.loops)
            precondition(clip.frames.first?.time == 0)
            precondition(clip.frames.last?.time == clip.duration)
            precondition(zip(clip.frames, clip.frames.dropFirst()).allSatisfy {
                $0.time <= $1.time
            })
            precondition(clip.frames.allSatisfy { frame in
                frame.parameters.values.allSatisfy(\.isFinite)
                    && abs(frame.parameters["ParamTail"] ?? 0) <= 1
            })
        }

        let idle = clips[.idle]!
        precondition(values("ParamEyeLOpen", in: idle).min()! < -0.5)
        precondition(values("ParamAngleZ", in: idle).max()! > 0.5)

        let walk = clips[.walk]!
        let walking = walk.frames[walk.frames.count / 4].parameters
        precondition(abs((walking["ParamLegFrontL"] ?? 0)
            - (walking["ParamLegHindR"] ?? 0)) < 0.0001)
        precondition(abs((walking["ParamLegFrontL"] ?? 0)
            + (walking["ParamLegFrontR"] ?? 0)) < 0.0001)
        precondition(abs(walking["ParamLegFrontL"] ?? 0) > 0.8)

        let shake = clips[.shakeHead]!
        let shakeAngles = values("ParamAngleX", in: shake)
        precondition(shakeAngles.max()! > 15)
        precondition(shakeAngles.min()! < -15)
        precondition(values("ParamAngleZ", in: shake).max()! > 4)
        precondition(values("ParamAngleZ", in: shake).min()! < -4)
        let shakeSigns = shakeAngles.filter { abs($0) > 1 }.map { $0 > 0 }
        precondition(zip(shakeSigns, shakeSigns.dropFirst()).filter { $0 != $1 }.count >= 5)

        let play = clips[.play]!
        precondition(values("ParamBodyY", in: play).min()! < -0.3)
        precondition(values("ParamMouthOpenY", in: play).max()! > 0.7)
        precondition(values("ParamLegFrontL", in: play).min()! < -0.6)
        precondition(values("ParamMouthOpenY", in: shake).max() == 0)
    }

    private static func values(
        _ identifier: String,
        in clip: CubismProceduralMotionClip
    ) -> [Double] {
        clip.frames.map { $0.parameters[identifier] ?? 0 }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-cubism-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }
}
