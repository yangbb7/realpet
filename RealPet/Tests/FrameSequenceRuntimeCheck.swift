import Foundation

@main
struct FrameSequenceRuntimeCheck {
    static func main() throws {
        try testSourceFramesPreferPNGAndPairJPEGAlpha()
        try testActionResolverIsRootConfined()
        try testFeatureManifestAndHeadHitTesting()
        print("Frame sequence runtime checks passed")
    }

    private static func testSourceFramesPreferPNGAndPairJPEGAlpha() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("png".utf8).write(to: root.appendingPathComponent("frame_0001.png"))
        try Data("jpg".utf8).write(to: root.appendingPathComponent("frame_0000.jpg"))
        try Data("alpha".utf8).write(to: root.appendingPathComponent("frame_0000_a.jpg"))
        let png = try SourceFrameSequence.load(at: root, fps: 99)
        precondition(png.frames.count == 1)
        precondition(png.frames[0].rgbURL.lastPathComponent == "frame_0001.png")
        precondition(png.frames[0].alphaURL == nil)
        precondition(png.fps == 60)

        try FileManager.default.removeItem(at: root.appendingPathComponent("frame_0001.png"))
        let jpeg = try SourceFrameSequence.load(at: root, fps: 0)
        precondition(jpeg.frames.count == 1)
        precondition(jpeg.frames[0].alphaURL?.lastPathComponent == "frame_0000_a.jpg")
        precondition(jpeg.fps == 1)
    }

    private static func testActionResolverIsRootConfined() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("frame".utf8).write(to: root.appendingPathComponent("frame_0000.png"))
        let actionRoot = root.appendingPathComponent("actions/lie_down", isDirectory: true)
        try FileManager.default.createDirectory(at: actionRoot, withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: actionRoot.appendingPathComponent("frame_0000.png"))
        let gazeKinds: [PetActionManifest.Action.Kind] = [
            .gazeLeft, .gazeRight, .gazeUp, .gazeDown,
        ]
        for kind in gazeKinds {
            let directory = root.appendingPathComponent(
                "actions/\(kind.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data("frame".utf8).write(
                to: directory.appendingPathComponent("frame_0000.png"))
        }
        let manifest = PetActionManifest(
            version: 1,
            defaultAction: "idle",
            actions: [
                .init(id: "idle", kind: .idle, framesDirectory: ".", fps: 10,
                      loop: true, translatesWindow: false),
                .init(id: "lie_down", kind: .lieDown,
                      framesDirectory: "actions/lie_down", fps: 8,
                      loop: false, translatesWindow: false),
            ] + gazeKinds.map {
                .init(id: $0.rawValue, kind: $0,
                      framesDirectory: "actions/\($0.rawValue)", fps: 8,
                      loop: true, translatesWindow: false)
            })
        try manifest.save(framesDirectory: root.path)
        let action = SourceFrameActionResolver.sequence(
            for: .lieDown, framesDirectory: root, fallbackFPS: 10)
        precondition(action?.frames.count == 1)
        precondition(action?.fps == 8)
        precondition(PetActionManifest.load(framesDirectory: root.path)?.actions
            .first(where: { $0.id == "lie_down" })?.effectiveOrigin == .captured)
        let capabilities = SourceFrameActionResolver.capabilities(framesDirectory: root)
        precondition(capabilities.reaction && capabilities.orientation)
        let gaze = SourceFrameActionResolver.sequence(
            for: .gazeLeft, framesDirectory: root, fallbackFPS: 10)
        precondition(gaze?.frames.count == 1)
        precondition(PetActionManifest.Action.Kind.gazeAction(
            horizontalOffset: -0.8, verticalOffset: 0) == .gazeLeft)
        precondition(PetActionManifest.Action.Kind.gazeAction(
            horizontalOffset: 0, verticalOffset: 0.8) == .gazeUp)
        precondition(PetActionManifest.Action.Kind.gazeAction(
            horizontalOffset: 0.02, verticalOffset: 0) == nil)

        let escaping = PetActionManifest(
            version: 1,
            defaultAction: "idle",
            actions: [
                .init(id: "idle", kind: .idle, framesDirectory: ".", fps: 10,
                      loop: true, translatesWindow: false),
                .init(id: "eat", kind: .eat,
                      framesDirectory: "../../\(outside.lastPathComponent)", fps: 10,
                      loop: false, translatesWindow: false),
            ])
        try escaping.save(framesDirectory: root.path)
        precondition(SourceFrameActionResolver.sequence(
            for: .eat, framesDirectory: root, fallbackFPS: 10) == nil)

        let generated = PetActionManifest.Action(
            id: "generated_paw", kind: .paw, framesDirectory: "actions/paw",
            fps: 10, loop: false, translatesWindow: false, origin: .generated)
        precondition(generated.effectiveOrigin == .generated)
        let generatedOnly = PetActionManifest(
            version: 1, defaultAction: "idle",
            actions: [
                .init(id: "idle", kind: .idle, framesDirectory: ".", fps: 10,
                      loop: true, translatesWindow: false),
                generated,
            ])
        try generatedOnly.save(framesDirectory: root.path)
        precondition(SourceFrameActionResolver.sequence(
            for: .paw, framesDirectory: root, fallbackFPS: 10) == nil)
        let legacy = PetActionManifest.Action(
            id: "legacy_paw", kind: .paw, framesDirectory: "actions/paw",
            fps: 10, loop: false, translatesWindow: false)
        precondition(legacy.effectiveOrigin == .captured)
    }

    private static func testFeatureManifestAndHeadHitTesting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = PetFeatureManifest.Region(
            x: 0.2, y: 0.5, width: 0.3, height: 0.3, confidence: 0.9)
        let manifest = PetFeatureManifest(
            version: 1, sourceFrame: "frame_0002.png", confidence: 0.9,
            head: head,
            leftEye: .init(x: 0.27, y: 0.66, confidence: 0.91),
            rightEye: .init(x: 0.43, y: 0.66, confidence: 0.90),
            nose: .init(x: 0.35, y: 0.59, confidence: 0.92),
            leftFrontPaw: nil, rightFrontPaw: nil)
        try manifest.save(framesDirectory: root)
        precondition(PetFeatureManifest.load(framesDirectory: root) == manifest)
        precondition(PetFeatureHitTester.isHead(x: 0.35, y: 0.65, head: head))
        precondition(!PetFeatureHitTester.isHead(x: 0.80, y: 0.30, head: head))
        precondition(PetFeatureHitTester.isHead(x: 0.80, y: 0.70, head: nil))
    }

    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "realpet-frame-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
