import CryptoKit
import Foundation

/// Immutable facts about the original video kept alongside an installed action.
/// Presentation caches are intentionally excluded: they are disposable runtime
/// assets and must never become the source of truth for an action.
struct PetActionSourceMedia: Codable, Equatable, Sendable {
    static let fileName = "source-media.json"

    let version: Int
    let sourceFilename: String
    let sha256: String
    let width: Int
    let height: Int
    let duration: TimeInterval
    let nominalFrameRate: Double
    let variableFrameRate: Bool
    let colorTransfer: String?
    let colorPrimaries: String?

    init(
        version: Int = 1,
        sourceFilename: String = "action.mp4",
        sha256: String,
        width: Int,
        height: Int,
        duration: TimeInterval,
        nominalFrameRate: Double,
        variableFrameRate: Bool,
        colorTransfer: String? = nil,
        colorPrimaries: String? = nil
    ) {
        self.version = version
        self.sourceFilename = sourceFilename
        self.sha256 = sha256
        self.width = width
        self.height = height
        self.duration = duration
        self.nominalFrameRate = nominalFrameRate
        self.variableFrameRate = variableFrameRate
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
    }

    static func load(at directory: URL) -> Self? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(Self.self, from: data),
              metadata.version == 1,
              !metadata.sourceFilename.isEmpty,
              metadata.sourceFilename == URL(fileURLWithPath: metadata.sourceFilename)
                .lastPathComponent,
              !metadata.sha256.isEmpty,
              metadata.width > 0,
              metadata.height > 0,
              metadata.duration >= 0,
              metadata.nominalFrameRate > 0 else {
            return nil
        }
        return metadata
    }

    /// Returns nil when this action has no copied media yet. This preserves
    /// compatibility with historical frame-only actions while making every new
    /// `action.mp4` installation independently verifiable.
    func verifiesMedia(at directory: URL) -> Bool? {
        let mediaURL = directory.appendingPathComponent(sourceFilename)
        guard FileManager.default.fileExists(atPath: mediaURL.path),
              let handle = try? FileHandle(forReadingFrom: mediaURL) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data: Data
            do {
                data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            } catch {
                return false
            }
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            .caseInsensitiveCompare(sha256) == .orderedSame
    }
}

/// The presentation time of every extracted source frame. Existing actions
/// without this sidecar retain the legacy constant-FPS fallback.
struct PetActionFrameTimeline: Codable, Equatable, Sendable {
    struct Frame: Codable, Equatable, Sendable {
        let pts: TimeInterval
        let duration: TimeInterval
    }

    static let fileName = "timeline.json"

    let version: Int
    let frames: [Frame]

    init(version: Int = 1, frames: [Frame]) {
        self.version = version
        self.frames = frames
    }

    static func uniform(frameCount: Int, fps: Int) -> Self {
        let duration = 1.0 / Double(max(1, fps))
        return Self(frames: (0..<max(0, frameCount)).map {
            Frame(pts: Double($0) * duration, duration: duration)
        })
    }

    static func load(
        at directory: URL,
        relativePath: String? = nil,
        frameCount: Int,
        fallbackFPS: Int
    ) -> Self {
        let filename = relativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = directory.appendingPathComponent(
            filename?.isEmpty == false ? filename! : fileName)
        guard let data = try? Data(contentsOf: url),
              let timeline = try? JSONDecoder().decode(Self.self, from: data),
              timeline.isValid(frameCount: frameCount) else {
            return uniform(frameCount: frameCount, fps: fallbackFPS)
        }
        return timeline.normalized()
    }

    var duration: TimeInterval {
        guard let last = frames.last else { return 0 }
        return max(0, last.pts + last.duration)
    }

    func index(at time: TimeInterval, looping: Bool) -> Int {
        guard !frames.isEmpty else { return 0 }
        let totalDuration = duration
        guard totalDuration > 0 else { return frames.count - 1 }
        let normalizedTime: TimeInterval
        if looping {
            normalizedTime = time.truncatingRemainder(dividingBy: totalDuration)
        } else {
            normalizedTime = min(max(0, time), max(0, totalDuration - .ulpOfOne))
        }
        var lowerBound = 0
        var upperBound = frames.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if frames[middle].pts <= normalizedTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let candidate = max(0, lowerBound - 1)
        if normalizedTime < frames[candidate].pts + frames[candidate].duration {
            return candidate
        }
        return min(frames.count - 1, candidate + 1)
    }

    func index(forNormalizedPhase phase: Double) -> Int {
        guard !frames.isEmpty else { return 0 }
        let progress = min(1, max(0, phase))
        return index(at: progress * max(duration - .ulpOfOne, 0), looping: false)
    }

    private func isValid(frameCount: Int) -> Bool {
        guard version == 1, frames.count == frameCount, !frames.isEmpty else {
            return false
        }
        var previousEnd: TimeInterval = -1
        for frame in frames {
            guard frame.pts.isFinite,
                  frame.duration.isFinite,
                  frame.pts >= 0,
                  frame.duration > 0,
                  frame.pts + 0.000_001 >= previousEnd else {
                return false
            }
            previousEnd = frame.pts + frame.duration
        }
        return true
    }

    private func normalized() -> Self {
        guard let first = frames.first, first.pts != 0 else { return self }
        return Self(version: version, frames: frames.map {
            Frame(pts: max(0, $0.pts - first.pts), duration: $0.duration)
        })
    }
}
