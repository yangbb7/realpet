import Foundation

@MainActor
final class EphemeralEvidenceBuffer {
    private struct StoredSnapshot {
        let createdAt: TimeInterval
        let expiresAt: TimeInterval
        let frames: [MultimodalEvidenceFrame]
        let byteCount: Int
    }

    let maximumBytes: Int
    let maximumFrames: Int
    let retentionDuration: TimeInterval

    private(set) var bufferedBytes = 0
    private(set) var retainedSnapshotBytes = 0
    private var frames: [MultimodalEvidenceFrame] = []
    private var snapshots: [String: StoredSnapshot] = [:]

    init(
        maximumBytes: Int = 12 * 1_024 * 1_024,
        maximumFrames: Int = 24,
        retentionDuration: TimeInterval = 4
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumFrames = max(1, maximumFrames)
        self.retentionDuration = max(0.25, retentionDuration)
    }

    @discardableResult
    func append(
        data: Data,
        mimeType: String = "image/jpeg",
        capturedAt: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              mimeType.hasPrefix("image/"),
              capturedAt.isFinite,
              frames.last.map({ capturedAt >= $0.capturedAt }) ?? true else {
            return false
        }

        purge(now: capturedAt)
        frames.append(MultimodalEvidenceFrame(
            id: UUID(), capturedAt: capturedAt,
            mimeType: mimeType, data: data))
        bufferedBytes += data.count
        trimToLimits()
        return true
    }

    func makeSnapshot(
        now: TimeInterval = Date().timeIntervalSince1970,
        lookback: TimeInterval = 2,
        expiresAt: TimeInterval
    ) -> EphemeralEvidenceSnapshot? {
        guard now.isFinite,
              expiresAt.isFinite,
              expiresAt > now else { return nil }
        purge(now: now)
        let start = now - max(0.1, min(lookback, retentionDuration))
        let selected = frames.filter {
            $0.capturedAt >= start && $0.capturedAt <= now
        }
        guard let first = selected.first,
              let last = selected.last else { return nil }

        let reference = "realpet-evidence://\(UUID().uuidString)"
        let byteCount = selected.reduce(0) { $0 + $1.data.count }
        while retainedSnapshotBytes + byteCount > maximumBytes,
              let oldest = snapshots.min(by: {
                $0.value.createdAt < $1.value.createdAt
              }) {
            removeSnapshot(reference: oldest.key)
        }
        guard retainedSnapshotBytes + byteCount <= maximumBytes else { return nil }
        snapshots[reference] = StoredSnapshot(
            createdAt: now, expiresAt: expiresAt,
            frames: selected, byteCount: byteCount)
        retainedSnapshotBytes += byteCount
        return EphemeralEvidenceSnapshot(
            evidence: ObservationEvidence(
                reference: reference,
                mimeType: "application/x-realpet-frame-sequence",
                startedAt: first.capturedAt,
                endedAt: last.capturedAt,
                ephemeral: true),
            expiresAt: expiresAt,
            frames: selected)
    }

    func resolve(
        reference: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [MultimodalEvidenceFrame]? {
        purge(now: now)
        guard let snapshot = snapshots[reference],
              snapshot.expiresAt >= now else { return nil }
        return snapshot.frames
    }

    func purge(now: TimeInterval = Date().timeIntervalSince1970) {
        let oldest = now - retentionDuration
        while let first = frames.first, first.capturedAt < oldest {
            bufferedBytes -= first.data.count
            frames.removeFirst()
        }
        let expiredReferences = snapshots.compactMap {
            $0.value.expiresAt < now ? $0.key : nil
        }
        for reference in expiredReferences {
            removeSnapshot(reference: reference)
        }
    }

    func removeAll() {
        frames.removeAll(keepingCapacity: false)
        snapshots.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        retainedSnapshotBytes = 0
    }

    private func trimToLimits() {
        while frames.count > maximumFrames || bufferedBytes > maximumBytes {
            let removed = frames.removeFirst()
            bufferedBytes -= removed.data.count
        }
    }

    private func removeSnapshot(reference: String) {
        guard let removed = snapshots.removeValue(forKey: reference) else { return }
        retainedSnapshotBytes -= removed.byteCount
    }
}
