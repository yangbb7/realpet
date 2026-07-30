import Foundation

struct NormalizedBounds: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var area: Double { width * height }
    var center: SpatialContext {
        SpatialContext(
            space: .cameraNormalized,
            x: min(1, max(0, x + width / 2)),
            y: min(1, max(0, y + height / 2)))
    }
}

struct NormalizedPoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double
}

struct CameraVisionSample: Equatable, Sendable {
    let capturedAt: TimeInterval
    let person: NormalizedBounds?
    let wrists: [NormalizedPoint]
}

struct CameraSemanticDetection: Equatable, Sendable {
    let kind: String
    let confidence: Double
    let spatial: SpatialContext?
}

struct CameraVLMTriggerPolicy {
    let warmupDuration: TimeInterval
    let semanticChangeInterval: TimeInterval
    let periodicInterval: TimeInterval

    private var visibleSince: TimeInterval?
    private var lastTriggerAt: TimeInterval = -.infinity
    private var lastSampleAt: TimeInterval = -.infinity

    init(
        warmupDuration: TimeInterval = 1.0,
        semanticChangeInterval: TimeInterval = 2.5,
        periodicInterval: TimeInterval = 5.0
    ) {
        self.warmupDuration = max(0.25, warmupDuration)
        self.semanticChangeInterval = max(1, semanticChangeInterval)
        self.periodicInterval = max(semanticChangeInterval, periodicInterval)
    }

    mutating func shouldTrigger(
        capturedAt: TimeInterval,
        personVisible: Bool,
        hasSemanticChange: Bool
    ) -> Bool {
        guard capturedAt.isFinite, capturedAt >= lastSampleAt else {
            reset()
            return false
        }
        lastSampleAt = capturedAt
        guard personVisible else {
            visibleSince = nil
            return false
        }
        if visibleSince == nil {
            visibleSince = capturedAt
            return false
        }
        guard capturedAt - visibleSince! >= warmupDuration else { return false }

        let interval = hasSemanticChange
            ? semanticChangeInterval : periodicInterval
        guard capturedAt - lastTriggerAt >= interval else { return false }
        lastTriggerAt = capturedAt
        return true
    }

    mutating func reset() {
        visibleSince = nil
        lastTriggerAt = -.infinity
        lastSampleAt = -.infinity
    }
}

struct CameraGestureInterpreter {
    private var lastPersonSeenAt: TimeInterval?
    private var approachBaseline: (time: TimeInterval, area: Double)?
    private var wristSamples: [(time: TimeInterval, x: Double)] = []
    private var lastApproachAt: TimeInterval = -.infinity
    private var lastWaveAt: TimeInterval = -.infinity

    mutating func process(_ sample: CameraVisionSample) -> [CameraSemanticDetection] {
        guard sample.capturedAt.isFinite else { return [] }
        var detections: [CameraSemanticDetection] = []

        guard let person = sample.person,
              person.area > 0.01 else {
            if let lastPersonSeenAt,
               sample.capturedAt - lastPersonSeenAt > 1.5 {
                self.lastPersonSeenAt = nil
                approachBaseline = nil
                wristSamples.removeAll(keepingCapacity: true)
            }
            return []
        }

        if lastPersonSeenAt == nil {
            detections.append(CameraSemanticDetection(
                kind: InteractionKind.userAppears,
                confidence: 0.82,
                spatial: person.center))
        }
        lastPersonSeenAt = sample.capturedAt

        if let baseline = approachBaseline,
           sample.capturedAt - baseline.time <= 1.5,
           person.area >= baseline.area * 1.35,
           sample.capturedAt - lastApproachAt >= 2.0 {
            detections.append(CameraSemanticDetection(
                kind: InteractionKind.userApproachesPet,
                confidence: min(0.98, 0.72 + (person.area / baseline.area - 1) * 0.25),
                spatial: person.center))
            lastApproachAt = sample.capturedAt
            approachBaseline = (sample.capturedAt, person.area)
        } else if approachBaseline == nil
                    || sample.capturedAt - approachBaseline!.time > 1.5
                    || person.area < approachBaseline!.area * 0.92 {
            approachBaseline = (sample.capturedAt, person.area)
        }

        if let wrist = sample.wrists
            .filter({ $0.confidence >= 0.55 })
            .max(by: { $0.y < $1.y }) {
            wristSamples.append((sample.capturedAt, wrist.x))
        }
        wristSamples.removeAll { sample.capturedAt - $0.time > 1.2 }
        if isWave(wristSamples), sample.capturedAt - lastWaveAt >= 2.5 {
            detections.append(CameraSemanticDetection(
                kind: InteractionKind.userWaves,
                confidence: 0.88,
                spatial: person.center))
            lastWaveAt = sample.capturedAt
            wristSamples.removeAll(keepingCapacity: true)
        }
        return detections
    }

    private func isWave(_ samples: [(time: TimeInterval, x: Double)]) -> Bool {
        guard samples.count >= 5,
              let minimum = samples.map(\.x).min(),
              let maximum = samples.map(\.x).max(),
              maximum - minimum >= 0.16 else { return false }

        var directions: [Int] = []
        for pair in zip(samples, samples.dropFirst()) {
            let delta = pair.1.x - pair.0.x
            guard abs(delta) >= 0.025 else { continue }
            let direction = delta > 0 ? 1 : -1
            if directions.last != direction {
                directions.append(direction)
            }
        }
        return directions.count >= 3
    }
}
