import Foundation

enum PetActionLibrary {
    enum InstallError: LocalizedError {
        case noFrames
        case frameCountMismatch(expected: Int, actual: Int)
        case unsupportedAction(PetActionManifest.Action.Kind)

        var errorDescription: String? {
            switch self {
            case .noFrames: return "动作目录中没有有效帧"
            case .frameCountMismatch(let expected, let actual):
                return "动作帧不完整（应为 \(expected) 帧，实际为 \(actual) 帧）"
            case .unsupportedAction(let kind):
                return "不支持安装动作：\(kind.displayName)"
            }
        }
    }

    private struct InstallTransaction: Codable {
        enum Phase: String, Codable {
            case prepared
            case existingMovedToBackup
            case destinationMoved
        }

        let actionID: String
        let destinationName: String
        let backupName: String
        let hadExistingDestination: Bool
        var phase: Phase
    }

    @discardableResult
    static func install(
        kind: PetActionManifest.Action.Kind,
        processedFramesDirectory: URL,
        rootFramesDirectory: URL,
        fps: Int,
        origin: PetActionManifest.Action.Origin = .captured,
        actionID: String? = nil,
        displayNameOverride: String? = nil
    ) throws -> PetActionManifest {
        guard kind.isFixedAction || kind == .custom else {
            throw InstallError.unsupportedAction(kind)
        }
        let resolvedActionID = actionID ?? kind.rawValue
        guard isSafeActionID(resolvedActionID) else {
            throw InstallError.unsupportedAction(kind)
        }
        let fm = FileManager.default
        let frames = try sourceFrames(in: processedFramesDirectory)
        guard !frames.isEmpty else { throw InstallError.noFrames }

        let root = rootFramesDirectory.standardizedFileURL
        let actionsDirectory = root.appendingPathComponent("actions")
        let destination = actionsDirectory.appendingPathComponent(resolvedActionID)
        let backupName = ".\(resolvedActionID)-backup-\(UUID().uuidString)"
        let backup = actionsDirectory.appendingPathComponent(backupName)

        try fm.createDirectory(at: actionsDirectory, withIntermediateDirectories: true)
        try recoverInterruptedInstall(rootFramesDirectory: root)
        var transaction = InstallTransaction(
            actionID: resolvedActionID,
            destinationName: resolvedActionID,
            backupName: backupName,
            hadExistingDestination: fm.fileExists(atPath: destination.path),
            phase: .prepared)
        try save(transaction: transaction, rootFramesDirectory: root)
        var manifestSaved = false
        do {
            if transaction.hadExistingDestination {
                try fm.moveItem(at: destination, to: backup)
                transaction.phase = .existingMovedToBackup
                try save(transaction: transaction, rootFramesDirectory: root)
            }
            try fm.moveItem(at: processedFramesDirectory, to: destination)
            transaction.phase = .destinationMoved
            try save(transaction: transaction, rootFramesDirectory: root)
            let installedFrameCount = try sourceFrames(in: destination).count
            guard installedFrameCount == frames.count else {
                throw InstallError.frameCountMismatch(
                    expected: frames.count, actual: installedFrameCount)
            }

            let existing = PetActionManifest.load(
                framesDirectory: root.path)
            let manifest = PetActionManifest.registering(
                kind: kind,
                relativeFramesDirectory: "actions/\(resolvedActionID)",
                fps: fps,
                origin: origin,
                actionID: resolvedActionID,
                displayNameOverride: displayNameOverride,
                in: existing)
            try manifest.save(framesDirectory: root.path)
            manifestSaved = true
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try removeTransaction(rootFramesDirectory: root)
            return manifest
        } catch {
            if !manifestSaved {
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                if transaction.hadExistingDestination,
                   fm.fileExists(atPath: backup.path) {
                    try? fm.moveItem(at: backup, to: destination)
                }
                try? removeTransaction(rootFramesDirectory: root)
            }
            throw error
        }
    }

    /// Restores an interrupted action replacement before the runtime reads its
    /// manifest. A committed manifest wins; otherwise the prior directory is
    /// restored and the incomplete replacement is removed.
    static func recoverInterruptedInstall(rootFramesDirectory: URL) throws {
        let root = rootFramesDirectory.standardizedFileURL
        let journal = transactionURL(rootFramesDirectory: root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: journal.path) else { return }
        let transaction = try JSONDecoder().decode(
            InstallTransaction.self, from: Data(contentsOf: journal))
        guard isSafeActionID(transaction.actionID),
              transaction.destinationName == transaction.actionID,
              transaction.backupName.hasPrefix(".\(transaction.actionID)-backup-") else {
            try fm.removeItem(at: journal)
            return
        }
        let actionsDirectory = root.appendingPathComponent("actions")
        let destination = actionsDirectory.appendingPathComponent(transaction.destinationName)
        let backup = actionsDirectory.appendingPathComponent(transaction.backupName)
        let manifestPointsToDestination = PetActionManifest.load(
            framesDirectory: root.path)?.actions.contains {
                $0.id == transaction.actionID
                    && $0.framesDirectory == "actions/\(transaction.destinationName)"
            } ?? false

        if manifestPointsToDestination {
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        } else {
            if fm.fileExists(atPath: destination.path),
               (!transaction.hadExistingDestination
                    || transaction.phase != .prepared
                    || fm.fileExists(atPath: backup.path)) {
                try fm.removeItem(at: destination)
            }
            if transaction.hadExistingDestination,
               fm.fileExists(atPath: backup.path),
               !fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: backup, to: destination)
            }
        }
        try fm.removeItem(at: journal)
    }

    /// Counts the exact frames that the source-frame runtime will render.
    static func frameCount(in directory: URL) throws -> Int {
        try sourceFrames(in: directory).count
    }

    static func removeCustomAction(
        id: String,
        rootFramesDirectory: URL
    ) throws -> PetActionManifest {
        guard isSafeActionID(id),
              let existing = PetActionManifest.load(
                framesDirectory: rootFramesDirectory.path),
              let action = existing.actions.first(where: {
                  $0.id == id && $0.kind == .custom
              }) else {
            throw InstallError.unsupportedAction(.custom)
        }

        let root = rootFramesDirectory.standardizedFileURL
        let actionDirectory = root.appendingPathComponent(action.framesDirectory)
            .standardizedFileURL
        let actionsRoot = root.appendingPathComponent("actions").standardizedFileURL
        guard actionDirectory.deletingLastPathComponent() == actionsRoot else {
            throw InstallError.unsupportedAction(.custom)
        }
        let backup = actionsRoot.appendingPathComponent(
            ".\(id)-backup-\(UUID().uuidString)")
        let fm = FileManager.default
        var movedToBackup = false
        do {
            if fm.fileExists(atPath: actionDirectory.path) {
                try fm.moveItem(at: actionDirectory, to: backup)
                movedToBackup = true
            }
            let manifest = PetActionManifest(
                version: existing.version,
                defaultAction: existing.defaultAction,
                actions: existing.actions.filter { $0.id != id })
            try manifest.save(framesDirectory: root.path)
            if movedToBackup { try? fm.removeItem(at: backup) }
            return manifest
        } catch {
            if movedToBackup, !fm.fileExists(atPath: actionDirectory.path) {
                try? fm.moveItem(at: backup, to: actionDirectory)
            }
            throw error
        }
    }

    private static func sourceFrames(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix("frame_")
                    && ["png", "jpg"].contains($0.pathExtension.lowercased())
                    && !$0.lastPathComponent.hasSuffix("_a.jpg")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isSafeActionID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,96}$", options: .regularExpression) != nil
    }

    private static func transactionURL(rootFramesDirectory: URL) -> URL {
        rootFramesDirectory.appendingPathComponent("actions/.install-transaction.json")
    }

    private static func save(
        transaction: InstallTransaction,
        rootFramesDirectory: URL
    ) throws {
        try JSONEncoder().encode(transaction).write(
            to: transactionURL(rootFramesDirectory: rootFramesDirectory),
            options: .atomic)
    }

    private static func removeTransaction(rootFramesDirectory: URL) throws {
        let journal = transactionURL(rootFramesDirectory: rootFramesDirectory)
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        try FileManager.default.removeItem(at: journal)
    }

}
