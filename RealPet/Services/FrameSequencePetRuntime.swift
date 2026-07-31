import AppKit
import CoreImage
import Foundation

enum FrameSequenceRuntimeError: LocalizedError {
    case noFrames(URL)

    var errorDescription: String? {
        switch self {
        case .noFrames(let directory):
            return "No usable source frames found in \(directory.lastPathComponent)"
        }
    }
}

struct SourceFrameSequence: Equatable {
    struct Frame: Equatable {
        let rgbURL: URL
        let alphaURL: URL?
    }

    let root: URL
    let frames: [Frame]
    let fps: Int
    let loop: Bool

    static func load(at directory: URL, fps: Int) throws -> SourceFrameSequence {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        let pngs = entries.filter {
            $0.pathExtension.lowercased() == "png"
                && $0.lastPathComponent.hasPrefix("frame_")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !pngs.isEmpty {
            return SourceFrameSequence(
                root: root,
                frames: pngs.map { Frame(rgbURL: $0, alphaURL: nil) },
                fps: max(1, min(60, fps)),
                loop: true)
        }

        let jpegs = entries.filter {
            let name = $0.lastPathComponent
            return $0.pathExtension.lowercased() == "jpg"
                && name.hasPrefix("frame_")
                && !name.hasSuffix("_a.jpg")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let frames = jpegs.map { rgbURL -> Frame in
            let stem = rgbURL.deletingPathExtension().lastPathComponent
            let alphaURL = root.appendingPathComponent("\(stem)_a.jpg")
            return Frame(
                rgbURL: rgbURL,
                alphaURL: FileManager.default.fileExists(atPath: alphaURL.path)
                    ? alphaURL : nil)
        }
        guard !frames.isEmpty else { throw FrameSequenceRuntimeError.noFrames(root) }
        return SourceFrameSequence(
            root: root, frames: frames, fps: max(1, min(60, fps)), loop: true)
    }

    func with(loop: Bool) -> SourceFrameSequence {
        SourceFrameSequence(root: root, frames: frames, fps: fps, loop: loop)
    }
}

/// Maps a pointer angle to a stable frame inside a generated 360-degree orbit.
/// The opening and closing holds are excluded so both resolve to the same
/// front-facing frame instead of being mistaken for intermediate viewpoints.
enum OrbitFrameSelector {
    static func index(
        frameCount: Int,
        horizontalOffset: Double,
        verticalOffset: Double,
        deadZone: Double = 0.16,
        edgeHoldFraction: Double = 0.12
    ) -> Int? {
        guard frameCount > 0,
              hypot(horizontalOffset, verticalOffset) >= deadZone else { return nil }
        let fullTurn = 2 * Double.pi
        let angle = atan2(horizontalOffset, verticalOffset)
        let progress = angle >= 0 ? angle / fullTurn : (angle + fullTurn) / fullTurn
        let maxIndex = frameCount - 1
        let firstOrbitIndex = min(
            maxIndex,
            max(0, Int((Double(maxIndex) * edgeHoldFraction).rounded())))
        let lastOrbitIndex = max(
            firstOrbitIndex,
            min(maxIndex, maxIndex - firstOrbitIndex))
        return Int((Double(firstOrbitIndex)
            + Double(lastOrbitIndex - firstOrbitIndex) * progress).rounded())
    }
}

enum SourceFrameActionResolver {
    static func sequence(
        for cue: PetAnimationCue?,
        framesDirectory: URL,
        fallbackFPS: Int
    ) -> SourceFrameSequence? {
        guard let cue,
              let manifest = PetActionManifest.load(
                framesDirectory: framesDirectory.path) else { return nil }
        let kind: PetActionManifest.Action.Kind
        switch cue {
        case .react: kind = .react
        case .shakeHead: kind = .shakeHead
        case .play: kind = .play
        case .lieDown: kind = .lieDown
        case .paw: kind = .paw
        case .eat: kind = .eat
        }
        return sequence(
            for: kind, manifest: manifest, framesDirectory: framesDirectory,
            fallbackFPS: fallbackFPS)
    }

    static func sequence(
        for kind: PetActionManifest.Action.Kind,
        framesDirectory: URL,
        fallbackFPS: Int
    ) -> SourceFrameSequence? {
        guard let manifest = PetActionManifest.load(
            framesDirectory: framesDirectory.path) else { return nil }
        return sequence(
            for: kind, manifest: manifest, framesDirectory: framesDirectory,
            fallbackFPS: fallbackFPS)
    }

    private static func sequence(
        for kind: PetActionManifest.Action.Kind,
        manifest: PetActionManifest,
        framesDirectory: URL,
        fallbackFPS: Int
    ) -> SourceFrameSequence? {
        guard let action = manifest.actions.first(where: { $0.kind == kind }),
              let actionRoot = safeActionDirectory(
                action.framesDirectory, beneath: framesDirectory) else { return nil }
        let fps = action.fps > 0 ? action.fps : fallbackFPS
        return try? SourceFrameSequence.load(at: actionRoot, fps: fps)
            .with(loop: action.loop)
    }

    static func capabilities(
        framesDirectory: URL
    ) -> PetActionCapabilities {
        PetActionManifest.load(
            framesDirectory: framesDirectory.path)?.capabilities ?? .idleOnly
    }

    private static func safeActionDirectory(
        _ relative: String,
        beneath root: URL
    ) -> URL? {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolvedRoot.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        let prefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path : resolvedRoot.path + "/"
        return candidate.path.hasPrefix(prefix) ? candidate : nil
    }
}

enum PetFeatureHitTester {
    static func isHead(
        x: Double,
        y: Double,
        head: PetFeatureManifest.Region?
    ) -> Bool {
        (head?.contains(x: x, y: y) ?? false) || y >= 0.60
    }
}

@MainActor
private final class SourceFrameImageCache {
    private let cache = NSCache<NSString, NSImage>()
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(limit: Int = 24) {
        cache.countLimit = max(1, limit)
    }

    func image(for frame: SourceFrameSequence.Frame) -> NSImage? {
        let key = frame.rgbURL.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage?
        if let alphaURL = frame.alphaURL {
            image = compositedImage(rgbURL: frame.rgbURL, alphaURL: alphaURL)
        } else {
            image = NSImage(contentsOf: frame.rgbURL)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private func compositedImage(rgbURL: URL, alphaURL: URL) -> NSImage? {
        guard let rgb = CIImage(contentsOf: rgbURL),
              let alpha = CIImage(contentsOf: alphaURL),
              let filter = CIFilter(name: "CIBlendWithAlphaMask") else { return nil }
        let transparent = CIImage(color: .clear).cropped(to: rgb.extent)
        filter.setValue(rgb, forKey: kCIInputImageKey)
        filter.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        filter.setValue(alpha, forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: rgb.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(
            width: rgb.extent.width, height: rgb.extent.height))
    }
}

@MainActor
private final class SourceFramePetView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var headRegion: PetFeatureManifest.Region?
    var onPointer: ((String, CGPoint) -> Void)?
    var onFileDrop: ((Bool, CGPoint) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var windowOrigin: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }
        let aspect = image.size.width / max(1, image.size.height)
        var destination = bounds.insetBy(dx: 8, dy: 8)
        if destination.width / max(1, destination.height) > aspect {
            let width = destination.height * aspect
            destination.origin.x += (destination.width - width) / 2
            destination.size.width = width
        } else {
            let height = destination.width / aspect
            destination.origin.y += (destination.height - height) / 2
            destination.size.height = height
        }

        image.draw(in: destination)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        windowOrigin = window?.frame.origin
        onPointer?(InteractionKind.dragStarted, normalized(point))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint,
              let origin = windowOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        window?.setFrameOrigin(NSPoint(
            x: origin.x + point.x - start.x,
            y: origin.y + point.y - start.y))
        onPointer?("pointer.move", normalized(point))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        onPointer?(InteractionKind.dragEnded, normalized(point))
        if hypot(point.x - start.x, point.y - start.y) < 4 {
            onPointer?(InteractionKind.petTapped, normalized(point))
        }
        mouseDownPoint = nil
        windowOrigin = nil
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer?("pointer.move", normalized(convert(event.locationInWindow, from: nil)))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [:])
            ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [:]) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let normalized = normalized(point)
        let isHead = PetFeatureHitTester.isHead(
            x: normalized.x, y: normalized.y, head: headRegion)
        onFileDrop?(isHead, normalized)
        return true
    }

    private func normalized(_ point: NSPoint) -> CGPoint {
        CGPoint(
            x: min(1, max(0, point.x / max(1, bounds.width))),
            y: min(1, max(0, point.y / max(1, bounds.height))))
    }

}

@MainActor
final class FrameSequencePetRuntime: NSObject, PetRuntimeController,
    NSWindowDelegate {

    let petId: UUID
    private let rendererKind = PetRendererKind.sourceFrames
    var onObservation: ((InteractionObservation) -> Void)?
    var onTermination: (() -> Void)?
    private(set) var isRunning = false
    private var isPresentationActive: Bool

    private let framesDirectory: URL
    private let fallbackFPS: Int
    private var baseSequence: SourceFrameSequence?
    private var activeSequence: SourceFrameSequence?
    private var frameIndex = 0
    private var frameTimer: Timer?
    private var activePlaybackFPS: Int?
    private var pointerTimer: Timer?
    private var window: NSPanel?
    private var petView: SourceFramePetView?
    private var cache = SourceFrameImageCache()
    private var paused = false
    private var terminated = false
    private var actionEndsAt: TimeInterval?
    private var activeGazeAction: PetActionManifest.Action.Kind?
    private var heldFrameIndex: Int?
    private var features: PetFeatureManifest?
    private var pointerWasNear = false
    private var lastNearEmission = 0.0

    init(
        petId: UUID,
        framesDirectory: URL,
        fps: Int,
        startHidden: Bool = false
    ) {
        self.petId = petId
        self.framesDirectory = framesDirectory.standardizedFileURL
        fallbackFPS = max(1, min(60, fps))
        isPresentationActive = !startHidden
    }

    func start() throws {
        let sequence = try SourceFrameSequence.load(
            at: framesDirectory, fps: fallbackFPS)
        features = PetFeatureManifest.load(framesDirectory: framesDirectory)
        baseSequence = sequence
        activeSequence = sequence
        let firstImage = cache.image(for: sequence.frames[0])
        let aspect = firstImage.map { $0.size.width / max(1, $0.size.height) } ?? 0.8
        let height = min(560, max(260, NSScreen.main?.visibleFrame.height ?? 420))
        let width = min(520, max(180, height * aspect))
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = NSPanel(
            contentRect: NSRect(
                x: visible.midX - width / 2, y: visible.midY - height / 2,
                width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        let view = SourceFramePetView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.image = firstImage
        view.headRegion = features?.head
        view.onPointer = { [weak self] kind, point in
            self?.handlePointer(kind: kind, point: point)
        }
        view.onFileDrop = { [weak self] isHead, point in
            self?.handleFileDrop(isHead: isHead, point: point)
        }
        panel.contentView = view
        window = panel
        petView = view
        isRunning = true
        terminated = false
        frameIndex = 0
        startTimers(fps: sequence.fps)
        if isPresentationActive {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        emitSystem(kind: "runtime.ready", attributes: [
            "renderer": rendererKind.rawValue,
            "featureAnchors": features?.head == nil ? "geometry_fallback" : "vision",
        ])
    }

    func send(_ command: PetCommand) {
        guard isRunning,
              command.petId == petId,
              command.schemaVersion == PetCommand.currentSchemaVersion,
              command.expiresAt >= Date().timeIntervalSince1970 else { return }
        switch command.action {
        case .faceToward:
            guard let target = command.target else {
                emitCommand(command, applied: false, reason: "missing_target")
                return
            }
            updateGaze(for: target, intensity: command.intensity)
            emitCommand(command, applied: true)
        case .react:
            let cue = command.animation ?? .react
            if play(cue: cue) {
                emitCommand(command, applied: true)
            } else {
                emitCommand(
                    command, applied: false,
                    reason: "missing_captured_response")
            }
        case .pause:
            paused = true
            emitCommand(command, applied: true)
        case .resume:
            paused = false
            emitCommand(command, applied: true)
        case .moveToward, .moveAway, .moveTo:
            emitCommand(command, applied: false, reason: "missing_captured_locomotion")
        }
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        isRunning = false
        frameTimer?.invalidate()
        pointerTimer?.invalidate()
        frameTimer = nil
        pointerTimer = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        petView = nil
        activeSequence = nil
        baseSequence = nil
        heldFrameIndex = nil
        onTermination?()
    }

    func stop() { terminate() }

    func windowWillClose(_ notification: Notification) { terminate() }

    private func startTimers(fps: Int) {
        startFrameTimer(fps: fps)
        let pointerTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.observePointer() }
        }
        RunLoop.main.add(pointerTimer, forMode: .common)
        self.pointerTimer = pointerTimer
    }

    private func startFrameTimer(fps: Int) {
        let boundedFPS = max(1, min(60, fps))
        guard activePlaybackFPS != boundedFPS || frameTimer == nil else { return }
        frameTimer?.invalidate()
        let frameTimer = Timer(
            timeInterval: 1.0 / Double(boundedFPS), repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceFrame() }
        }
        RunLoop.main.add(frameTimer, forMode: .common)
        self.frameTimer = frameTimer
        activePlaybackFPS = boundedFPS
    }

    private func activate(sequence: SourceFrameSequence) {
        activeSequence = sequence
        heldFrameIndex = nil
        frameIndex = 0
        startFrameTimer(fps: sequence.fps)
    }

    private func advanceFrame() {
        guard isRunning, !paused,
              let sequence = activeSequence,
              let view = petView else { return }
        let now = Date().timeIntervalSince1970
        if let endsAt = actionEndsAt, now >= endsAt {
            actionEndsAt = nil
            activeGazeAction = nil
            if let baseSequence {
                activate(sequence: baseSequence)
            }
            advanceFrame()
            return
        }
        if let heldFrameIndex {
            let displayIndex = min(max(0, heldFrameIndex), sequence.frames.count - 1)
            view.image = cache.image(for: sequence.frames[displayIndex])
            view.needsDisplay = true
            return
        }
        let displayIndex = sequence.loop
            ? frameIndex % sequence.frames.count
            : min(frameIndex, sequence.frames.count - 1)
        view.image = cache.image(for: sequence.frames[displayIndex])
        frameIndex = sequence.loop
            ? (frameIndex + 1) % sequence.frames.count
            : min(frameIndex + 1, sequence.frames.count - 1)
        view.needsDisplay = true
    }

    private func observePointer() {
        guard isRunning, isPresentationActive, let window, petView != nil else { return }
        let pointer = NSEvent.mouseLocation
        let frame = window.frame
        let dx = (pointer.x - frame.midX) / max(180, frame.width * 1.2)
        let dy = (pointer.y - frame.midY) / max(180, frame.height * 1.2)
        updateCapturedGaze(horizontalOffset: dx, verticalOffset: dy)
        let distance = hypot(pointer.x - frame.midX, pointer.y - frame.midY)
        let nearby = distance <= max(frame.width, frame.height) * 0.7 + 70
        let now = Date().timeIntervalSince1970
        if nearby && (!pointerWasNear || now - lastNearEmission >= 0.45),
           let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            emit(
                kind: InteractionKind.pointerNear,
                spatial: SpatialContext(
                    space: .screenNormalized,
                    x: min(1, max(0, (pointer.x - visible.minX) / visible.width)),
                    y: min(1, max(0, (pointer.y - visible.minY) / visible.height))))
            lastNearEmission = now
        }
        pointerWasNear = nearby
    }

    private func handlePointer(kind: String, point: CGPoint) {
        guard kind != "pointer.move" else { return }
        emit(
            kind: kind,
            spatial: SpatialContext(
                space: .petLocalNormalized, x: point.x, y: point.y))
    }

    private func handleFileDrop(isHead: Bool, point: CGPoint) {
        emit(
            kind: isHead ? InteractionKind.fileDroppedOnHead : InteractionKind.fileDroppedOnBody,
            spatial: SpatialContext(
                space: .petLocalNormalized, x: point.x, y: point.y),
            attributes: ["fileHandling": "none"])
    }

    private func updateGaze(for target: SpatialContext, intensity: Double) {
        guard let window else { return }
        let point: CGPoint
        switch target.space {
        case .petLocalNormalized:
            point = CGPoint(x: (target.x - 0.5) * 2, y: (target.y - 0.5) * 2)
        case .screenNormalized:
            guard let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            point = CGPoint(
                x: ((target.x * visible.width + visible.minX) - window.frame.midX)
                    / max(180, window.frame.width * 1.2),
                y: ((target.y * visible.height + visible.minY) - window.frame.midY)
                    / max(180, window.frame.height * 1.2))
        case .cameraNormalized:
            return
        }
        let gain = min(1, max(0, intensity))
        updateCapturedGaze(
            horizontalOffset: point.x * gain,
            verticalOffset: point.y * gain)
    }

    private func updateCapturedGaze(
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat
    ) {
        guard actionEndsAt == nil else { return }
        if let orbitSequence = SourceFrameActionResolver.sequence(
            for: .gazeOrbit, framesDirectory: framesDirectory, fallbackFPS: fallbackFPS) {
            guard let selectedFrameIndex = OrbitFrameSelector.index(
                frameCount: orbitSequence.frames.count,
                horizontalOffset: Double(horizontalOffset),
                verticalOffset: Double(verticalOffset)) else {
                guard activeGazeAction != nil else { return }
                activeGazeAction = nil
                heldFrameIndex = nil
                if let baseSequence {
                    activate(sequence: baseSequence)
                }
                return
            }
            if activeSequence?.root != orbitSequence.root {
                activate(sequence: orbitSequence)
            }
            activeGazeAction = .gazeOrbit
            heldFrameIndex = selectedFrameIndex
            if let view = petView {
                view.image = cache.image(for: orbitSequence.frames[selectedFrameIndex])
                view.needsDisplay = true
            }
            return
        }
        let requested = PetActionManifest.Action.Kind.gazeAction(
            horizontalOffset: Double(horizontalOffset),
            verticalOffset: Double(verticalOffset))
        guard requested != activeGazeAction else { return }
        guard let requested,
              let sequence = SourceFrameActionResolver.sequence(
                for: requested, framesDirectory: framesDirectory,
                fallbackFPS: fallbackFPS) else {
            activeGazeAction = nil
            if let baseSequence {
                activate(sequence: baseSequence)
            }
            return
        }
        activeGazeAction = requested
        activate(sequence: sequence)
    }

    private func play(cue: PetAnimationCue) -> Bool {
        let now = Date().timeIntervalSince1970
        if let sequence = SourceFrameActionResolver.sequence(
            for: cue, framesDirectory: framesDirectory, fallbackFPS: fallbackFPS) {
            activate(sequence: sequence)
            actionEndsAt = now + Double(sequence.frames.count) / Double(sequence.fps)
            return true
        }
        return false
    }

    private func emit(
        kind: String,
        spatial: SpatialContext?,
        attributes: [String: String] = [:]
    ) {
        onObservation?(InteractionObservation(
            petId: petId,
            source: InteractionSource.pointer,
            kind: kind,
            expiresAt: Date().timeIntervalSince1970 + 1,
            spatial: spatial,
            attributes: attributes))
    }

    private func emitSystem(kind: String, attributes: [String: String]) {
        onObservation?(InteractionObservation(
            petId: petId,
            source: InteractionSource.system,
            kind: kind,
            expiresAt: Date().timeIntervalSince1970 + 2,
            attributes: attributes))
    }

    private func emitCommand(
        _ command: PetCommand,
        applied: Bool,
        reason: String? = nil
    ) {
        var attributes = [
            "commandId": command.id.uuidString,
            "action": command.action.rawValue,
            "renderer": rendererKind.rawValue,
        ]
        if let reason { attributes["reason"] = reason }
        emitSystem(
            kind: applied ? "runtime.command_applied" : "runtime.command_rejected",
            attributes: attributes)
    }
}
