import Darwin
import Foundation

/// Local, privacy-preserving operational measurements. Events never include
/// image bytes, prompts, account identifiers, or credentials.
enum RuntimeMetrics {
    private struct Event: Codable {
        let name: String
        let timestamp: Date
        let attributes: [String: String]
    }

    private static let launchStartedAt = Date()
    private static let writer = DispatchQueue(label: "com.realpet.runtime-metrics")

    static func recordStartup() {
        let elapsed = Date().timeIntervalSince(launchStartedAt)
        record("app.startup", attributes: [
            "elapsed_ms": milliseconds(elapsed),
            "max_rss_bytes": String(maxResidentBytes()),
        ])

        let appSupport = PetStorage.shared.appSupportURL
        let bundleResources = Bundle.main.resourceURL
        Task.detached(priority: .utility) {
            var attributes = [
                "app_support_bytes": String(directorySize(at: appSupport)),
            ]
            if let bundleResources {
                attributes["bundle_resources_bytes"] = String(directorySize(at: bundleResources))
            }
            record("storage.footprint", attributes: attributes)
        }
    }

    static func recordDuration(
        _ name: String,
        startedAt: Date,
        outcome: String,
        attributes: [String: String] = [:]
    ) {
        var values = attributes
        values["elapsed_ms"] = milliseconds(Date().timeIntervalSince(startedAt))
        values["outcome"] = outcome
        record(name, attributes: values)
    }

    static func record(_ name: String, attributes: [String: String] = [:]) {
        let event = Event(name: name, timestamp: Date(), attributes: attributes)
        writer.async {
            guard let data = try? JSONEncoder().encode(event) else { return }
            let line = data + Data([0x0a])
            let destination = metricsURL()
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path),
               let handle = try? FileHandle(forWritingTo: destination) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: destination, options: .atomic)
            }
        }
    }

    private static func metricsURL() -> URL {
        PetStorage.shared.appSupportURL.appendingPathComponent("runtime-metrics.jsonl")
    }

    private static func maxResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss)) * 1_024
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String {
        String(Int((max(0, seconds) * 1_000).rounded()))
    }

    private static func directorySize(at directory: URL) -> UInt64 {
        guard let entries = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in entries {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += UInt64(max(0, values.fileSize ?? 0))
        }
        return total
    }
}
