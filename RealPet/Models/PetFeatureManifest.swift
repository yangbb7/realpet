import Foundation

/// Local, source-frame-relative landmarks. Coordinates use a bottom-left
/// normalized origin, matching Vision and AppKit view coordinates.
struct PetFeatureManifest: Codable, Equatable, Sendable {
    struct Landmark: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let confidence: Double

        var isValid: Bool {
            x.isFinite && y.isFinite && confidence.isFinite
                && (0...1).contains(x) && (0...1).contains(y)
                && (0...1).contains(confidence)
        }
    }

    struct Region: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let confidence: Double

        var isValid: Bool {
            x.isFinite && y.isFinite && width.isFinite && height.isFinite
                && confidence.isFinite && (0...1).contains(x)
                && (0...1).contains(y) && width > 0 && height > 0
                && x + width <= 1 && y + height <= 1
                && (0...1).contains(confidence)
        }

        func contains(x: Double, y: Double) -> Bool {
            isValid && x >= self.x && x <= self.x + width
                && y >= self.y && y <= self.y + height
        }
    }

    static let currentVersion = 1
    static let filename = "pet-features.json"

    let version: Int
    let sourceFrame: String
    let confidence: Double
    let head: Region?
    let leftEye: Landmark?
    let rightEye: Landmark?
    let nose: Landmark?
    let leftFrontPaw: Landmark?
    let rightFrontPaw: Landmark?

    var isValid: Bool {
        version == Self.currentVersion
            && !sourceFrame.isEmpty
            && confidence.isFinite && (0...1).contains(confidence)
            && (head?.isValid ?? true)
            && [leftEye, rightEye, nose, leftFrontPaw, rightFrontPaw]
                .allSatisfy { $0?.isValid ?? true }
    }

    static func load(framesDirectory: URL) -> PetFeatureManifest? {
        let url = framesDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              manifest.isValid else { return nil }
        return manifest
    }

    func save(framesDirectory: URL) throws {
        guard isValid else { return }
        let url = framesDirectory.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
