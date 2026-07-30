import Foundation

enum PetActionLibrary {
    enum InstallError: LocalizedError {
        case noFrames

        var errorDescription: String? {
            switch self {
            case .noFrames: return "动作目录中没有有效帧"
            }
        }
    }

    @discardableResult
    static func install(
        kind: PetActionManifest.Action.Kind,
        processedFramesDirectory: URL,
        rootFramesDirectory: URL,
        fps: Int,
        origin: PetActionManifest.Action.Origin = .captured
    ) throws -> PetActionManifest {
        let fm = FileManager.default
        let frames = try fm.contentsOfDirectory(
            at: processedFramesDirectory,
            includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix("frame_")
                    && ["png", "jpg"].contains($0.pathExtension.lowercased())
                    && !$0.lastPathComponent.hasSuffix("_a.jpg")
            }
        guard !frames.isEmpty else { throw InstallError.noFrames }

        let actionsDirectory = rootFramesDirectory.appendingPathComponent("actions")
        let destination = actionsDirectory.appendingPathComponent(kind.rawValue)
        let backup = actionsDirectory.appendingPathComponent(
            ".\(kind.rawValue)-backup-\(UUID().uuidString)")
        var movedExistingToBackup = false

        try fm.createDirectory(at: actionsDirectory, withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: backup)
                movedExistingToBackup = true
            }
            try fm.moveItem(at: processedFramesDirectory, to: destination)

            let existing = PetActionManifest.load(
                framesDirectory: rootFramesDirectory.path)
            let manifest = PetActionManifest.registering(
                kind: kind,
                relativeFramesDirectory: "actions/\(kind.rawValue)",
                fps: fps,
                origin: origin,
                in: existing)
            try manifest.save(framesDirectory: rootFramesDirectory.path)
            if movedExistingToBackup {
                try? fm.removeItem(at: backup)
            }
            return manifest
        } catch {
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            if movedExistingToBackup {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

}
