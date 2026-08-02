import AppKit
import Foundation

@main
@MainActor
struct FrameSequenceRuntimeCheck {
    static func main() throws {
        try testSourceFramesPreferPNGAndPairJPEGAlpha()
        testWindowDragAnchorUsesGlobalPointerCoordinates()
        testDragRenderGate()
        testWindowPlacementPreservesOrigin()
        testDesktopPanelStaysVisibleAfterAppDeactivation()
        try testFrameHoldKeepsItsOwningSequence()
        testNearPointerCommandMatchesRawPointerFrame()
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
        precondition(png.fps == 99)

        try FileManager.default.removeItem(at: root.appendingPathComponent("frame_0001.png"))
        let jpeg = try SourceFrameSequence.load(at: root, fps: 0)
        precondition(jpeg.frames.count == 1)
        precondition(jpeg.frames[0].alphaURL?.lastPathComponent == "frame_0000_a.jpg")
        precondition(jpeg.fps == 1)
    }

    private static func testFrameHoldKeepsItsOwningSequence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseRoot = root.appendingPathComponent("base", isDirectory: true)
        let gazeRoot = root.appendingPathComponent("gaze", isDirectory: true)
        try FileManager.default.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gazeRoot, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data("base-\(index)".utf8).write(
                to: baseRoot.appendingPathComponent(String(format: "frame_%04d.png", index)))
            try Data("gaze-\(index)".utf8).write(
                to: gazeRoot.appendingPathComponent(String(format: "frame_%04d.png", index)))
        }
        let base = try SourceFrameSequence.load(at: baseRoot, fps: 24)
        let gaze = try SourceFrameSequence.load(at: gazeRoot, fps: 24)
        let held = SourceFrameHold(sequence: gaze, index: 2)
        precondition(base.root != held.sequence.root)
        precondition(held.frame.rgbURL.lastPathComponent == "frame_0002.png")
        let renderedFrameData = try Data(contentsOf: held.frame.rgbURL)
        precondition(renderedFrameData == Data("gaze-2".utf8))
    }

    private static func testWindowDragAnchorUsesGlobalPointerCoordinates() {
        let anchor = PetWindowDragAnchor(
            pointerAtStart: NSPoint(x: 500, y: 300),
            windowOriginAtStart: NSPoint(x: 120, y: 80))
        precondition(anchor.windowOrigin(for: NSPoint(x: 560, y: 350))
            == NSPoint(x: 180, y: 130))
        precondition(anchor.windowOrigin(for: NSPoint(x: 730, y: 470))
            == NSPoint(x: 350, y: 250))
        precondition(!anchor.isTap(at: NSPoint(x: 560, y: 350)))
        precondition(anchor.isTap(at: NSPoint(x: 502, y: 301)))
    }

    private static func testDragRenderGate() {
        precondition(FrameSequencePresentationGate.allowsFrameOrPointerUpdate(
            paused: false, isDragging: false))
        precondition(!FrameSequencePresentationGate.allowsFrameOrPointerUpdate(
            paused: true, isDragging: false))
        precondition(!FrameSequencePresentationGate.allowsFrameOrPointerUpdate(
            paused: false, isDragging: true))
    }

    private static func testWindowPlacementPreservesOrigin() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = CGPoint(x: 230, y: 140)
        let originalSize = NSSize(width: 280, height: 220)
        let enlargedSize = NSSize(width: 400, height: 340)
        precondition(PetWindowPlacement.origin(
            preferred: saved, size: originalSize, visibleFrame: visible) == saved)
        precondition(PetWindowPlacement.origin(
            preferred: saved, size: enlargedSize, visibleFrame: visible) == saved)
        precondition(PetWindowPlacement.origin(
            preferred: CGPoint(x: 1_420, y: 860), size: enlargedSize,
            visibleFrame: visible) == NSPoint(x: 1_040, y: 560))
    }

    private static func testDesktopPanelStaysVisibleAfterAppDeactivation() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        precondition(panel.hidesOnDeactivate)
        FrameSequencePetRuntime.keepVisibleWhenAppDeactivates(panel)
        precondition(!panel.hidesOnDeactivate)
    }

    private static func testNearPointerCommandMatchesRawPointerFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSRect(x: 450, y: 250, width: 300, height: 240)
        let pointer = CGPoint(x: window.midX + 80, y: window.midY + 20)
        let direct = CGPoint(
            x: (pointer.x - window.midX) / max(180, window.width * 1.2),
            y: (pointer.y - window.midY) / max(180, window.height * 1.2))
        let target = SpatialContext(
            space: .screenNormalized,
            x: (pointer.x - visible.minX) / visible.width,
            y: (pointer.y - visible.minY) / visible.height)
        let command = FrameSequenceGazeTargetMapper.offset(
            for: target, windowFrame: window, visibleFrame: visible)
        precondition(command != nil)
        precondition(abs(command!.x - direct.x) < 0.000_001)
        precondition(abs(command!.y - direct.y) < 0.000_001)
        let directFrame = GazeSweepFrameSelector.index(
            frameCount: 193,
            horizontalOffset: Double(direct.x),
            verticalOffset: Double(direct.y))
        let commandFrame = GazeSweepFrameSelector.index(
            frameCount: 193,
            horizontalOffset: Double(command!.x),
            verticalOffset: Double(command!.y))
        precondition(directFrame != nil && directFrame == commandFrame)
    }

    private static func testActionResolverIsRootConfined() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("frame".utf8).write(to: root.appendingPathComponent("frame_0000.png"))
        let actionRoot = root.appendingPathComponent("actions/cry", isDirectory: true)
        try FileManager.default.createDirectory(at: actionRoot, withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: actionRoot.appendingPathComponent("frame_0000.png"))
        let customActionID = "custom-happy-dance"
        let customActionRoot = root.appendingPathComponent(
            "actions/\(customActionID)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: customActionRoot, withIntermediateDirectories: true)
        try Data("frame".utf8).write(
            to: customActionRoot.appendingPathComponent("frame_0000.png"))
        let cryRoot = root.appendingPathComponent("actions/cry_generated", isDirectory: true)
        try FileManager.default.createDirectory(at: cryRoot, withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: cryRoot.appendingPathComponent("frame_0000.png"))
        let orbitRoot = root.appendingPathComponent("actions/gaze_orbit", isDirectory: true)
        try FileManager.default.createDirectory(at: orbitRoot, withIntermediateDirectories: true)
        for index in 0..<10 {
            try Data("frame".utf8).write(
                to: orbitRoot.appendingPathComponent(
                    String(format: "frame_%04d.png", index)))
        }
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
                .init(id: "cry", kind: .cry,
                      framesDirectory: "actions/cry", fps: 8,
                      loop: false, translatesWindow: false),
                .init(id: customActionID, kind: .custom,
                      displayNameOverride: "开心舞步",
                      framesDirectory: "actions/\(customActionID)", fps: 9,
                      loop: false, translatesWindow: false),
            ] + gazeKinds.map {
                .init(id: $0.rawValue, kind: $0,
                      framesDirectory: "actions/\($0.rawValue)", fps: 8,
                      loop: false, translatesWindow: false, origin: .generated)
            })
        try manifest.save(framesDirectory: root.path)
        let action = SourceFrameActionResolver.sequence(
            for: .cry, framesDirectory: root, fallbackFPS: 10)
        precondition(action?.frames.count == 1)
        precondition(action?.fps == 8)
        let customAction = SourceFrameActionResolver.sequence(
            forActionID: customActionID, framesDirectory: root, fallbackFPS: 10)
        precondition(customAction?.frames.count == 1)
        precondition(customAction?.fps == 9)
        precondition(PetActionManifest.load(framesDirectory: root.path)?.actions
            .first(where: { $0.id == customActionID })?.displayName == "开心舞步")
        precondition(PetActionManifest.load(framesDirectory: root.path)?.actions
            .first(where: { $0.id == "cry" })?.effectiveOrigin == .captured)
        let capabilities = SourceFrameActionResolver.capabilities(framesDirectory: root)
        precondition(capabilities.reaction && capabilities.orientation)
        let gaze = SourceFrameActionResolver.sequence(
            for: .gazeLeft, framesDirectory: root, fallbackFPS: 10)
        precondition(gaze?.frames.count == 1)
        precondition(gaze?.loop == false)
        precondition(PetActionManifest.Action.Kind.gazeAction(
            horizontalOffset: -0.8, verticalOffset: 0) == .gazeLeft)
        precondition(PetActionManifest.Action.Kind.gazeAction(
            horizontalOffset: 0, verticalOffset: 0.8) == .gazeUp)
        precondition(PetActionManifest.Action.Kind.gazeAction(
            horizontalOffset: 0.02, verticalOffset: 0) == nil)

        for index in 1..<10 {
            try Data("frame".utf8).write(
                to: root.appendingPathComponent(String(format: "frame_%04d.png", index)))
        }
        let legacyCaptured = PetActionManifest(
            version: 1,
            defaultAction: "idle",
            actions: [
                .init(id: "idle", kind: .idle, framesDirectory: ".", fps: 24,
                      loop: true, translatesWindow: false, origin: .captured),
            ] + gazeKinds.map {
                .init(id: $0.rawValue, kind: $0,
                      framesDirectory: "actions/\($0.rawValue)", fps: 24,
                      loop: false, translatesWindow: false, origin: .captured)
            })
        try legacyCaptured.save(framesDirectory: root.path)
        let legacyOrbit = SourceFrameActionResolver.sequence(
            for: .gazeOrbit, framesDirectory: root, fallbackFPS: 24)
        precondition(legacyOrbit?.frames.count == 10)
        precondition(legacyOrbit?.fps == 24)
        precondition(legacyOrbit?.loop == false)

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
            id: "generated_cry", kind: .cry, framesDirectory: "actions/cry_generated",
            fps: 10, loop: false, translatesWindow: false, origin: .generated)
        let generatedOrbit = PetActionManifest.Action(
            id: "generated_gaze_orbit", kind: .gazeOrbit,
            framesDirectory: "actions/gaze_orbit", fps: 10,
            loop: false, translatesWindow: false, origin: .generated)
        precondition(generated.effectiveOrigin == .generated)
        let generatedOnly = PetActionManifest(
            version: 1, defaultAction: "idle",
            actions: [
                .init(id: "idle", kind: .idle, framesDirectory: ".", fps: 10,
                      loop: true, translatesWindow: false),
                generated,
                generatedOrbit,
            ])
        try generatedOnly.save(framesDirectory: root.path)
        let generatedSequence = SourceFrameActionResolver.sequence(
            for: .cry, framesDirectory: root, fallbackFPS: 10)
        precondition(generatedSequence?.frames.count == 1)
        precondition(generatedSequence?.loop == false)
        precondition(SourceFrameActionResolver.capabilities(
            framesDirectory: root).reaction)
        let orbitSequence = SourceFrameActionResolver.sequence(
            for: .gazeOrbit, framesDirectory: root, fallbackFPS: 10)
        precondition(orbitSequence?.frames.count == 10)
        precondition(orbitSequence?.loop == false)
        precondition(SourceFrameActionResolver.capabilities(
            framesDirectory: root).orientation)
        let up = GazeSweepFrameSelector.index(
            frameCount: 100, horizontalOffset: 0, verticalOffset: 1)
        let right = GazeSweepFrameSelector.index(
            frameCount: 100, horizontalOffset: 1, verticalOffset: 0)
        let down = GazeSweepFrameSelector.index(
            frameCount: 100, horizontalOffset: 0, verticalOffset: -1)
        let left = GazeSweepFrameSelector.index(
            frameCount: 100, horizontalOffset: -1, verticalOffset: 0)
        precondition(up != nil && right != nil && down != nil && left != nil)
        precondition(up! < right! && right! < down! && down! < left!)
        precondition(up == 0 && right == 25 && down == 50 && left == 74)
        let centerIndex = GazeSweepFrameSelector.index(
            frameCount: 100, horizontalOffset: 0.01, verticalOffset: 0) ?? 0
        precondition(centerIndex == 0)
        // A close, off-center pointer must remain an orbit frame. Behavior
        // intent intensity is deliberately not part of this spatial lookup.
        precondition(GazeSweepFrameSelector.index(
            frameCount: 100, horizontalOffset: 0.22, verticalOffset: 0) != nil)
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
