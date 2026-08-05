import AppKit
import CoreImage
import CoreVideo
import Foundation
import ImageIO

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
    let timeline: PetActionFrameTimeline
    let loop: Bool

    static func load(
        at directory: URL,
        fps: Int,
        timelinePath: String? = nil
    ) throws -> SourceFrameSequence {
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
            let frames = pngs.map { Frame(rgbURL: $0, alphaURL: nil) }
            return makeSequence(
                root: root,
                frames: frames,
                fps: max(1, fps),
                loop: true,
                timelinePath: timelinePath)
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
        return makeSequence(
            root: root, frames: frames, fps: max(1, fps), loop: true,
            timelinePath: timelinePath)
    }

    func with(loop: Bool) -> SourceFrameSequence {
        SourceFrameSequence(
            root: root, frames: frames, fps: fps, timeline: timeline, loop: loop)
    }

    var duration: TimeInterval { timeline.duration }

    func frameIndex(at time: TimeInterval) -> Int {
        timeline.index(at: time, looping: loop)
    }

    private static func makeSequence(
        root: URL,
        frames: [Frame],
        fps: Int,
        loop: Bool,
        timelinePath: String?
    ) -> SourceFrameSequence {
        SourceFrameSequence(
            root: root,
            frames: frames,
            fps: fps,
            timeline: PetActionFrameTimeline.load(
                at: root, relativePath: timelinePath,
                frameCount: frames.count, fallbackFPS: fps),
            loop: loop)
    }
}

/// A stable rendered frame together with the sequence that owns it. Keeping
/// both values is essential when a separate playback sequence changes.
struct SourceFrameHold: Equatable {
    let sequence: SourceFrameSequence
    let index: Int

    init(sequence: SourceFrameSequence, index: Int) {
        self.sequence = sequence
        self.index = min(max(0, index), sequence.frames.count - 1)
    }

    var frame: SourceFrameSequence.Frame {
        sequence.frames[index]
    }
}

/// Anchors a drag in global screen coordinates. Window-local coordinates are
/// invalid after the window itself moves and cause the desktop pet to bounce
/// back toward its starting point on successive drag events.
struct PetWindowDragAnchor: Equatable {
    let pointerAtStart: NSPoint
    let windowOriginAtStart: NSPoint

    func windowOrigin(for pointer: NSPoint) -> NSPoint {
        NSPoint(
            x: windowOriginAtStart.x + pointer.x - pointerAtStart.x,
            y: windowOriginAtStart.y + pointer.y - pointerAtStart.y)
    }

    func isTap(at pointer: NSPoint, threshold: CGFloat = 4) -> Bool {
        hypot(pointer.x - pointerAtStart.x, pointer.y - pointerAtStart.y) < threshold
    }
}

enum FrameSequencePresentationGate {
    static func allowsFrameOrPointerUpdate(
        paused: Bool,
        isDragging: Bool,
        awaitingImageDecode: Bool = false
    ) -> Bool {
        !paused && !isDragging && !awaitingImageDecode
    }
}

enum PetWindowPlacement {
    static func origin(
        preferred: CGPoint?,
        size: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        guard let preferred else {
            return NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2)
        }
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        return NSPoint(
            x: min(max(visibleFrame.minX, preferred.x), maxX),
            y: min(max(visibleFrame.minY, preferred.y), maxY))
    }
}

/// Maps a pointer angle to a stable frame inside a generated head-gaze sweep.
/// Every generated frame remains reachable; no leading or trailing portion is
/// discarded at playback time.
enum GazeSweepFrameSelector {
    static func phase(
        horizontalOffset: Double,
        verticalOffset: Double,
        deadZone: Double = 0.16
    ) -> Double? {
        guard hypot(horizontalOffset, verticalOffset) >= deadZone else { return nil }
        let fullTurn = 2 * Double.pi
        let angle = atan2(horizontalOffset, verticalOffset)
        return angle >= 0 ? angle / fullTurn : (angle + fullTurn) / fullTurn
    }

    static func index(
        frameCount: Int,
        horizontalOffset: Double,
        verticalOffset: Double,
        deadZone: Double = 0.16,
        leadingHoldFraction: Double = 0,
        trailingHoldFraction: Double = 0
    ) -> Int? {
        guard frameCount > 0,
              let progress = phase(
                  horizontalOffset: horizontalOffset,
                  verticalOffset: verticalOffset,
                  deadZone: deadZone) else { return nil }
        let maxIndex = frameCount - 1
        let firstOrbitIndex = min(
            maxIndex,
            max(0, Int((Double(maxIndex) * leadingHoldFraction).rounded())))
        let lastOrbitIndex = max(
            firstOrbitIndex,
            min(maxIndex, maxIndex - Int((Double(maxIndex) * trailingHoldFraction).rounded())))
        return Int((Double(firstOrbitIndex)
            + Double(lastOrbitIndex - firstOrbitIndex) * progress).rounded())
    }
}

/// Converts a behavioral spatial target back into the same local coordinate
/// system used by raw desktop pointer sampling.
enum FrameSequenceGazeTargetMapper {
    static func offset(
        for target: SpatialContext,
        windowFrame: NSRect,
        visibleFrame: NSRect
    ) -> CGPoint? {
        switch target.space {
        case .petLocalNormalized:
            return CGPoint(x: (target.x - 0.5) * 2, y: (target.y - 0.5) * 2)
        case .screenNormalized:
            return CGPoint(
                x: ((target.x * visibleFrame.width + visibleFrame.minX)
                    - windowFrame.midX) / max(180, windowFrame.width * 1.2),
                y: ((target.y * visibleFrame.height + visibleFrame.minY)
                    - windowFrame.midY) / max(180, windowFrame.height * 1.2))
        case .cameraNormalized:
            return nil
        }
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
                framesDirectory: framesDirectory.path),
              let kind = kind(for: cue) else { return nil }
        return sequence(
            for: kind, manifest: manifest, framesDirectory: framesDirectory,
            fallbackFPS: fallbackFPS)
    }

    static func fallbackReactionCue(framesDirectory: URL) -> PetAnimationCue? {
        guard let manifest = PetActionManifest.load(
            framesDirectory: framesDirectory.path) else { return nil }
        return PetInteractionBinding.fallbackReactionPriority.first { cue in
            guard let kind = kind(for: cue) else { return false }
            return sequence(
                for: kind, manifest: manifest, framesDirectory: framesDirectory,
                fallbackFPS: 1) != nil
        }
    }

    private static func kind(for cue: PetAnimationCue) -> PetActionManifest.Action.Kind? {
        switch cue {
        case .cry: return .cry
        case .angryStomp: return .angryStomp
        case .roll: return .roll
        case .stretch: return .stretch
        case .sleepSnore: return .sleepSnore
        case .wave: return .wave
        case .jumpCheer: return .jumpCheer
        case .puzzledTilt: return .puzzledTilt
        case .cuddle: return .cuddle
        case .startledRetreat: return .startledRetreat
        case .patrolRun: return .patrolRun
        case .react: return nil
        case .shakeHead: return .shakeHead
        case .play: return .play
        case .lieDown: return .lieDown
        case .paw: return .paw
        case .eat: return .eat
        }
    }

    static func defaultSequence(
        framesDirectory: URL,
        fallbackFPS: Int
    ) -> SourceFrameSequence? {
        guard let manifest = PetActionManifest.load(
            framesDirectory: framesDirectory.path),
              let action = manifest.actions.first(where: {
                  $0.id == manifest.defaultAction
              }) else {
            return try? SourceFrameSequence.load(at: framesDirectory, fps: fallbackFPS)
        }
        return sequence(
            for: action.kind, manifest: manifest, framesDirectory: framesDirectory,
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

    static func sequence(
        forActionID actionID: String,
        framesDirectory: URL,
        fallbackFPS: Int
    ) -> SourceFrameSequence? {
        guard let manifest = PetActionManifest.load(
            framesDirectory: framesDirectory.path),
              let action = manifest.actions.first(where: { $0.id == actionID }) else {
            return nil
        }
        return sequence(
            for: action, framesDirectory: framesDirectory,
            fallbackFPS: fallbackFPS)
    }

    private static func sequence(
        for kind: PetActionManifest.Action.Kind,
        manifest: PetActionManifest,
        framesDirectory: URL,
        fallbackFPS: Int
    ) -> SourceFrameSequence? {
        if kind == .gazeOrbit,
           !manifest.actions.contains(where: { $0.kind == .gazeOrbit }),
           PetActionManifest.Action.Kind.gazeCapture.allSatisfy({ legacyKind in
               manifest.actions.contains {
                   $0.kind == legacyKind && $0.effectiveOrigin == .captured
               }
           }) {
            return try? SourceFrameSequence.load(at: framesDirectory, fps: fallbackFPS)
                .with(loop: false)
        }
        guard let action = manifest.actions.first(where: { $0.kind == kind }),
              let sequence = sequence(
                for: action, framesDirectory: framesDirectory,
                fallbackFPS: fallbackFPS) else { return nil }
        return sequence
    }

    private static func sequence(
        for action: PetActionManifest.Action,
        framesDirectory: URL,
        fallbackFPS: Int
    ) -> SourceFrameSequence? {
        guard let actionRoot = safeActionDirectory(
            action.framesDirectory, beneath: framesDirectory) else { return nil }
        let fps = action.fps > 0 ? action.fps : fallbackFPS
        return try? SourceFrameSequence.load(
            at: actionRoot, fps: fps, timelinePath: action.timelinePath)
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

/// Computes a disposable presentation cache from the actual desktop-pet size.
/// Source images are never resized on disk and a cache eviction only requires a
/// background re-decode from the installed source frames.
struct SourceFramePresentationPolicy: Equatable {
    let targetPixelDimension: Int
    let prefetchFrameCount: Int
    let totalCostLimit: Int

    static func make(
        viewSize: NSSize,
        backingScale: CGFloat,
        nominalFPS: Int,
        qualityOverscan: CGFloat = 1.35
    ) -> Self {
        let requestedFrames = min(60, max(8, Int((Double(max(1, nominalFPS)) * 1.25).rounded(.up))))
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let deviceBudget = Int(min(
            UInt64(256 * 1024 * 1024),
            max(UInt64(48 * 1024 * 1024), physicalMemory / 20)))
        let largestVisiblePixelDimension = max(viewSize.width, viewSize.height)
            * max(1, backingScale) * max(1, qualityOverscan)
        // Reserve room for at least two decoded frames even on an unusually
        // large desktop display. Source thumbnails never upscale past media.
        let memoryBound = Int(sqrt(
            Double(deviceBudget) / Double(max(2, requestedFrames) * 4)))
        let target = max(1, min(
            Int(largestVisiblePixelDimension.rounded(.up)), memoryBound))
        let estimatedFrameBytes = max(1, target * target * 4)
        let count = max(2, min(requestedFrames, deviceBudget / estimatedFrameBytes))
        return Self(
            targetPixelDimension: target,
            prefetchFrameCount: count,
            totalCostLimit: min(deviceBudget, max(24 * 1024 * 1024, estimatedFrameBytes * count)))
    }
}

private final class SourceFrameImageCache {
    private let cache = NSCache<NSString, NSImage>()
    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.realpet.frame-image-decoder"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let lock = NSLock()
    private var pendingCallbacks: [String: [(NSImage?) -> Void]] = [:]
    private var policy: SourceFramePresentationPolicy

    init(policy: SourceFramePresentationPolicy = .make(
        viewSize: NSSize(width: 260, height: 260), backingScale: 2, nominalFPS: 24
    )) {
        self.policy = policy
        cache.countLimit = max(1, policy.prefetchFrameCount)
        cache.totalCostLimit = max(1, policy.totalCostLimit)
    }

    @discardableResult
    func configure(_ policy: SourceFramePresentationPolicy) -> Bool {
        guard self.policy != policy else { return false }
        self.policy = policy
        cache.removeAllObjects()
        cache.countLimit = max(1, policy.prefetchFrameCount)
        cache.totalCostLimit = max(1, policy.totalCostLimit)
        return true
    }

    var prefetchFrameCount: Int { policy.prefetchFrameCount }

    func image(for frame: SourceFrameSequence.Frame) -> NSImage? {
        let key = cacheKey(for: frame, policy: policy) as NSString
        return cache.object(forKey: key)
    }

    func request(
        _ frame: SourceFrameSequence.Frame,
        completion: @escaping (NSImage?) -> Void
    ) {
        let policy = policy
        let key = cacheKey(for: frame, policy: policy)
        if let cached = cache.object(forKey: key as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        lock.lock()
        let alreadyDecoding = pendingCallbacks[key] != nil
        pendingCallbacks[key, default: []].append(completion)
        lock.unlock()
        guard !alreadyDecoding else { return }
        decodeQueue.addOperation { [weak self] in
            guard let self else { return }
            let image = Self.decodedImage(
                for: frame, maximumPixelDimension: policy.targetPixelDimension)
            let cost = Self.cost(of: image)
            DispatchQueue.main.async {
                self.completeDecode(
                    key: key, image: image, cost: cost, policy: policy)
            }
        }
    }

    func prefetch(_ frames: some Sequence<SourceFrameSequence.Frame>) {
        for frame in frames {
            request(frame) { _ in }
        }
    }

    private func completeDecode(
        key: String,
        image: NSImage?,
        cost: Int,
        policy: SourceFramePresentationPolicy
    ) {
        if let image, self.policy == policy {
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        lock.lock()
        let callbacks = pendingCallbacks.removeValue(forKey: key) ?? []
        lock.unlock()
        callbacks.forEach { $0(image) }
    }

    private func cacheKey(
        for frame: SourceFrameSequence.Frame,
        policy: SourceFramePresentationPolicy
    ) -> String {
        "\(frame.rgbURL.path)#\(policy.targetPixelDimension)"
    }

    private static func decodedImage(
        for frame: SourceFrameSequence.Frame,
        maximumPixelDimension: Int
    ) -> NSImage? {
        autoreleasepool {
            if let alphaURL = frame.alphaURL {
                return resizedImage(
                    compositedImage(rgbURL: frame.rgbURL, alphaURL: alphaURL),
                    maximumPixelDimension: maximumPixelDimension)
            }
            return thumbnailImage(
                at: frame.rgbURL, maximumPixelDimension: maximumPixelDimension)
        }
    }

    private static func thumbnailImage(
        at url: URL,
        maximumPixelDimension: Int
    ) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  // Force PNG/JPEG decompression on the background queue. A
                  // lazy provider can otherwise inflate during NSImage.draw.
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
              ] as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(
            width: image.width, height: image.height))
    }

    private static func compositedImage(rgbURL: URL, alphaURL: URL) -> NSImage? {
        guard let rgb = CIImage(contentsOf: rgbURL),
              let alpha = CIImage(contentsOf: alphaURL),
              let filter = CIFilter(name: "CIBlendWithAlphaMask") else { return nil }
        let transparent = CIImage(color: .clear).cropped(to: rgb.extent)
        filter.setValue(rgb, forKey: kCIInputImageKey)
        filter.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        filter.setValue(alpha, forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage,
              let cgImage = CIContext(options: [.cacheIntermediates: false])
                .createCGImage(output, from: rgb.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(
            width: rgb.extent.width, height: rgb.extent.height))
    }

    private static func resizedImage(
        _ image: NSImage?,
        maximumPixelDimension: Int
    ) -> NSImage? {
        guard let image,
              let cgImage = image.cgImage(
                  forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let largestDimension = max(cgImage.width, cgImage.height)
        guard largestDimension > maximumPixelDimension else { return image }
        let scale = CGFloat(maximumPixelDimension) / CGFloat(largestDimension)
        let width = max(1, Int((CGFloat(cgImage.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(cgImage.height) * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return image }
        return NSImage(cgImage: resized, size: NSSize(width: width, height: height))
    }

    private static func cost(of image: NSImage?) -> Int {
        guard let representation = image?.representations.first else { return 1 }
        return max(1, representation.pixelsWide * representation.pixelsHigh * 4)
    }
}

@MainActor
private final class SourceFramePetView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var headRegion: PetFeatureManifest.Region?
    var onPointer: ((String, CGPoint) -> Void)?
    var onFileDrop: ((Bool, CGPoint) -> Void)?

    private var dragAnchor: PetWindowDragAnchor?

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
        if let origin = window?.frame.origin {
            dragAnchor = PetWindowDragAnchor(
                pointerAtStart: NSEvent.mouseLocation,
                windowOriginAtStart: origin)
        }
        onPointer?(InteractionKind.dragStarted, normalized(point))
    }

    override func mouseDragged(with _: NSEvent) {
        guard let dragAnchor else { return }
        window?.setFrameOrigin(dragAnchor.windowOrigin(for: NSEvent.mouseLocation))
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        onPointer?(InteractionKind.dragEnded, normalized(point))
        if dragAnchor.isTap(at: NSEvent.mouseLocation) {
            onPointer?(InteractionKind.petTapped, normalized(point))
        }
        self.dragAnchor = nil
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

/// Coalesces CoreVideo display refreshes onto the main thread. The CoreVideo
/// callback never performs AppKit work, image decoding, or disk I/O.
private final class SourceFrameDisplayLink {
    private let tick: () -> Void
    private let lock = NSLock()
    private var isTickQueued = false
    private var displayLink: CVDisplayLink?

    init(tick: @escaping () -> Void) {
        self.tick = tick
    }

    func start(for screen: NSScreen?) {
        stop()
        let displayID: CGDirectDisplayID
        if let screenNumber = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            displayID = CGDirectDisplayID(screenNumber.uint32Value)
        } else {
            displayID = CGMainDisplayID()
        }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &link) == kCVReturnSuccess,
              let link else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard CVDisplayLinkSetOutputCallback(link, Self.callback, context)
            == kCVReturnSuccess else { return }
        displayLink = link
        CVDisplayLinkStart(link)
    }

    func stop() {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
        lock.lock()
        isTickQueued = false
        lock.unlock()
    }

    private static let callback: CVDisplayLinkOutputCallback = {
        _, _, _, _, _, context in
        guard let context else { return kCVReturnSuccess }
        let driver = Unmanaged<SourceFrameDisplayLink>
            .fromOpaque(context).takeUnretainedValue()
        driver.queueTick()
        return kCVReturnSuccess
    }

    private func queueTick() {
        lock.lock()
        guard !isTickQueued else {
            lock.unlock()
            return
        }
        isTickQueued = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.isTickQueued = false
            self.lock.unlock()
            self.tick()
        }
    }

    deinit { stop() }
}

@MainActor
final class FrameSequencePetRuntime: NSObject, PetRuntimeController,
    NSWindowDelegate {

    let petId: UUID
    private let rendererKind = "sourceFrames"
    var onObservation: ((InteractionObservation) -> Void)?
    var onTermination: (() -> Void)?
    private(set) var isRunning = false
    var windowOrigin: CGPoint? { window?.frame.origin }
    private var isPresentationActive: Bool

    private let framesDirectory: URL
    private let fallbackFPS: Int
    private var baseSequence: SourceFrameSequence?
    private var activeSequence: SourceFrameSequence?
    private var playbackStartedAt: TimeInterval = 0
    private var displayLink: SourceFrameDisplayLink?
    private var window: NSPanel?
    private var petView: SourceFramePetView?
    private var cache = SourceFrameImageCache()
    private var paused = false
    private var isDragging = false
    private var terminated = false
    private var actionEndsAt: TimeInterval?
    private var activeGazeAction: PetActionManifest.Action.Kind?
    private var heldFrame: SourceFrameHold?
    private var pendingDisplayFrame: SourceFrameSequence.Frame?
    private var imageRequestGeneration = 0
    private var features: PetFeatureManifest?
    private var hasGazeSupport = false
    private var pointerWasNear = false
    private var lastNearEmission = 0.0
    private var displayScale: Double
    private let initialWindowOrigin: CGPoint?

    init(
        petId: UUID,
        framesDirectory: URL,
        fps: Int,
        displayScale: Double = 1.0,
        initialWindowOrigin: CGPoint? = nil,
        startHidden: Bool = false
    ) {
        self.petId = petId
        self.framesDirectory = framesDirectory.standardizedFileURL
        fallbackFPS = max(1, fps)
        self.displayScale = Self.clampedDisplayScale(displayScale)
        self.initialWindowOrigin = initialWindowOrigin
        isPresentationActive = !startHidden
    }

    func start() throws {
        let sequence = try SourceFrameActionResolver.defaultSequence(
            framesDirectory: framesDirectory, fallbackFPS: fallbackFPS)
            ?? SourceFrameSequence.load(at: framesDirectory, fps: fallbackFPS)
        features = PetFeatureManifest.load(framesDirectory: framesDirectory)
        hasGazeSupport = SourceFrameActionResolver.capabilities(
            framesDirectory: framesDirectory).orientation
        baseSequence = sequence
        activeSequence = sequence
        let aspect = 0.8
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = windowSize(aspect: aspect, visibleFrame: visible)
        let origin = PetWindowPlacement.origin(
            preferred: initialWindowOrigin, size: size, visibleFrame: visible)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        Self.keepVisibleWhenAppDeactivates(panel)
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        let view = SourceFramePetView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.autoresizingMask = [.width, .height]
        configurePresentationCache(sequence: sequence, panel: panel, view: view)
        present(sequence.frames[0], in: view)
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
        playbackStartedAt = ProcessInfo.processInfo.systemUptime
        prefetch(sequence: sequence, from: 0)
        startDisplayLink(for: panel)
        if isPresentationActive {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        emitSystem(kind: "runtime.ready", attributes: [
            "renderer": rendererKind,
            "featureAnchors": features?.head == nil ? "geometry_fallback" : "vision",
        ])
    }

    func setDisplayScale(_ scale: Double) {
        displayScale = Self.clampedDisplayScale(scale)
        guard let panel = window else { return }
        let aspect = petView?.image.map {
            $0.size.width / max(1, $0.size.height)
        } ?? panel.frame.width / max(1, panel.frame.height)
        resize(panel: panel, to: windowSize(
            aspect: aspect,
            visibleFrame: panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)))
        if let sequence = activeSequence, let view = petView {
            configurePresentationCache(sequence: sequence, panel: panel, view: view)
            let elapsed = ProcessInfo.processInfo.systemUptime - playbackStartedAt
            prefetch(sequence: sequence, from: sequence.frameIndex(at: elapsed))
        }
    }

    func send(_ command: PetCommand) {
        guard isRunning,
              command.petId == petId,
              command.schemaVersion == PetCommand.currentSchemaVersion,
              command.expiresAt >= Date().timeIntervalSince1970 else { return }
        switch command.action {
        case .faceToward:
            guard !isDragging else {
                emitCommand(command, applied: true)
                return
            }
            guard let target = command.target else {
                emitCommand(command, applied: false, reason: "missing_target")
                return
            }
            updateGaze(for: target, intensity: command.intensity)
            emitCommand(command, applied: true)
        case .react:
            let cue = command.animation
                ?? SourceFrameActionResolver.fallbackReactionCue(
                    framesDirectory: framesDirectory)
            if let cue, play(cue: cue) {
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
        displayLink?.stop()
        displayLink = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        petView = nil
        activeSequence = nil
        baseSequence = nil
        heldFrame = nil
        pendingDisplayFrame = nil
        imageRequestGeneration &+= 1
        isDragging = false
        onTermination?()
    }

    func stop() { terminate() }

    func windowWillClose(_ notification: Notification) { terminate() }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let panel = window,
              let view = petView,
              let sequence = activeSequence else { return }
        configurePresentationCache(sequence: sequence, panel: panel, view: view)
        startDisplayLink(for: panel)
        let elapsed = ProcessInfo.processInfo.systemUptime - playbackStartedAt
        prefetch(sequence: sequence, from: sequence.frameIndex(at: elapsed))
    }

    private static func clampedDisplayScale(_ scale: Double) -> Double {
        min(1.75, max(0.55, scale))
    }

    /// Desktop pets remain visible while the owner works in another app.
    static func keepVisibleWhenAppDeactivates(_ panel: NSPanel) {
        panel.hidesOnDeactivate = false
    }

    private func windowSize(aspect: CGFloat, visibleFrame: NSRect) -> NSSize {
        let height = min(
            460,
            max(145, min(visibleFrame.height - 80, 260 * displayScale)))
        return NSSize(width: max(110, height * aspect), height: height)
    }

    private func resize(panel: NSPanel, to size: NSSize) {
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = PetWindowPlacement.origin(
            preferred: panel.frame.origin, size: size, visibleFrame: visible)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func configurePresentationCache(
        sequence: SourceFrameSequence,
        panel: NSPanel,
        view: SourceFramePetView
    ) {
        let policy = SourceFramePresentationPolicy.make(
            viewSize: view.bounds.size,
            backingScale: panel.backingScaleFactor,
            nominalFPS: sequence.fps)
        if cache.configure(policy) {
            pendingDisplayFrame = nil
            imageRequestGeneration &+= 1
        }
    }

    private func startDisplayLink(for panel: NSPanel) {
        let driver = SourceFrameDisplayLink { [weak self] in
            self?.displayTick()
        }
        displayLink?.stop()
        displayLink = driver
        driver.start(for: panel.screen)
    }

    private func activate(sequence: SourceFrameSequence) {
        activeSequence = sequence
        heldFrame = nil
        pendingDisplayFrame = nil
        imageRequestGeneration &+= 1
        playbackStartedAt = ProcessInfo.processInfo.systemUptime
        if let panel = window, let view = petView {
            configurePresentationCache(sequence: sequence, panel: panel, view: view)
        }
        prefetch(sequence: sequence, from: 0)
    }

    private func displayTick() {
        guard isRunning,
              let sequence = activeSequence,
              let view = petView else { return }
        observePointer()
        guard FrameSequencePresentationGate.allowsFrameOrPointerUpdate(
            paused: paused, isDragging: isDragging) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let endsAt = actionEndsAt, now >= endsAt {
            actionEndsAt = nil
            activeGazeAction = nil
            if hasGazeSupport {
                observePointer()
            } else {
                restoreCenteredGaze()
            }
            return
        }
        if let heldFrame {
            render(heldFrame)
            return
        }
        let displayIndex = sequence.frameIndex(at: now - playbackStartedAt)
        let frame = sequence.frames[displayIndex]
        _ = present(frame, in: view)
        prefetch(sequence: sequence, from: displayIndex)
    }

    private func observePointer() {
        guard isRunning, isPresentationActive,
              FrameSequencePresentationGate.allowsFrameOrPointerUpdate(
                paused: paused, isDragging: isDragging),
              let window, petView != nil else { return }
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
        switch kind {
        case InteractionKind.dragStarted:
            isDragging = true
        case InteractionKind.dragEnded:
            isDragging = false
            pointerWasNear = false
        default:
            break
        }
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

    private func updateGaze(for target: SpatialContext, intensity _: Double) {
        guard let window else { return }
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        guard let point = FrameSequenceGazeTargetMapper.offset(
            for: target, windowFrame: window.frame, visibleFrame: visibleFrame) else { return }
        // A semantic command's intensity must not scale a spatial target for a
        // frame-sequence pet. Near the desktop pet, a low-intensity
        // `pointerNear` command used to shrink the same mouse coordinate into
        // the center dead-zone. The 60 Hz raw pointer update then restored the
        // real coordinate, producing a recurring first-frame flash.
        updateCapturedGaze(
            horizontalOffset: point.x,
            verticalOffset: point.y)
    }

    private func updateCapturedGaze(
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat
    ) {
        guard actionEndsAt == nil, hasGazeSupport else { return }
        if let orbitSequence = SourceFrameActionResolver.sequence(
            for: .gazeOrbit, framesDirectory: framesDirectory, fallbackFPS: fallbackFPS) {
            // Keep the center dead-zone in the same generated gaze video.
            // The idle action is often a separately extracted still, so
            // switching to it while the pointer crosses the center produces
            // a visible flash between its first frame and the held gaze frame.
            let phase = GazeSweepFrameSelector.phase(
                horizontalOffset: Double(horizontalOffset),
                verticalOffset: Double(verticalOffset)) ?? 0
            let selectedFrameIndex = orbitSequence.timeline.index(
                forNormalizedPhase: phase)
            activeGazeAction = .gazeOrbit
            hold(frameAt: selectedFrameIndex, in: orbitSequence)
            return
        }
        let requested = PetActionManifest.Action.Kind.gazeAction(
            horizontalOffset: Double(horizontalOffset),
            verticalOffset: Double(verticalOffset))
        if let requested, requested == activeGazeAction { return }
        guard let requested,
              let sequence = SourceFrameActionResolver.sequence(
                for: requested, framesDirectory: framesDirectory,
                fallbackFPS: fallbackFPS) else {
            restoreCenteredGaze()
            return
        }
        activeGazeAction = requested
        hold(frameAt: sequence.frames.count - 1, in: sequence)
    }

    private func restoreCenteredGaze() {
        activeGazeAction = nil
        guard let baseSequence else { return }
        if activeSequence?.root != baseSequence.root {
            activate(sequence: baseSequence)
        }
        hold(frameAt: 0, in: baseSequence)
    }

    private func hold(frameAt index: Int, in sequence: SourceFrameSequence) {
        if let heldFrame,
           heldFrame.sequence.root == sequence.root,
           heldFrame.index == min(max(0, index), sequence.frames.count - 1) {
            return
        }
        let next = SourceFrameHold(sequence: sequence, index: index)
        heldFrame = next
        render(next)
        prefetchNeighbors(of: next)
    }

    private func prefetchNeighbors(of hold: SourceFrameHold) {
        let radius = min(4, max(0, hold.sequence.frames.count - 1))
        let frames = (-radius...radius).map { offset in
            let index = min(
                max(0, hold.index + offset),
                hold.sequence.frames.count - 1)
            return hold.sequence.frames[index]
        }
        cache.prefetch(frames)
    }

    private func render(_ heldFrame: SourceFrameHold) {
        guard let view = petView else { return }
        _ = present(heldFrame.frame, in: view)
    }

    @discardableResult
    private func present(
        _ frame: SourceFrameSequence.Frame,
        in view: SourceFramePetView
    ) -> Bool {
        if let image = cache.image(for: frame) {
            view.image = image
            view.needsDisplay = true
            return true
        }
        let generation = imageRequestGeneration
        pendingDisplayFrame = frame
        cache.request(frame) { [weak self, weak view] image in
            guard let self,
                  self.imageRequestGeneration == generation,
                  self.pendingDisplayFrame == frame else { return }
            self.pendingDisplayFrame = nil
            guard let image, let view else { return }
            view.image = image
            view.needsDisplay = true
        }
        return false
    }

    private func prefetch(sequence: SourceFrameSequence, from index: Int) {
        guard !sequence.frames.isEmpty else { return }
        let count = min(cache.prefetchFrameCount, sequence.frames.count)
        let frames = (0..<count).map { offset -> SourceFrameSequence.Frame in
            let next = sequence.loop
                ? (index + offset) % sequence.frames.count
                : min(sequence.frames.count - 1, index + offset)
            return sequence.frames[next]
        }
        cache.prefetch(frames)
    }

    private func play(cue: PetAnimationCue) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let sequence = SourceFrameActionResolver.sequence(
            for: cue, framesDirectory: framesDirectory, fallbackFPS: fallbackFPS) {
            activate(sequence: sequence)
            actionEndsAt = now + sequence.duration
            return true
        }
        return false
    }

    @discardableResult
    func playCustomAction(id: String) -> Bool {
        guard actionEndsAt == nil,
              let sequence = SourceFrameActionResolver.sequence(
                forActionID: id,
                framesDirectory: framesDirectory,
                fallbackFPS: fallbackFPS) else { return false }
        activate(sequence: sequence)
        actionEndsAt = ProcessInfo.processInfo.systemUptime + sequence.duration
        return true
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
            "renderer": rendererKind,
        ]
        if let reason { attributes["reason"] = reason }
        emitSystem(
            kind: applied ? "runtime.command_applied" : "runtime.command_rejected",
            attributes: attributes)
    }
}
