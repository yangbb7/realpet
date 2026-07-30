import Foundation

enum CubismSemanticAction: String, CaseIterable, Codable, Sendable {
    case idle
    case walk
    case react
    case shakeHead = "shake_head"
    case play

    var loops: Bool { self == .idle || self == .walk }

    var defaultDuration: TimeInterval {
        switch self {
        case .idle: return 4
        case .walk: return 1
        case .react: return 1.4
        case .shakeHead: return 1.2
        case .play: return 1.8
        }
    }
}

struct CubismMotionFrame: Codable, Equatable, Sendable {
    let time: TimeInterval
    let parameters: [String: Double]
}

struct CubismProceduralMotionClip: Codable, Equatable, Sendable {
    let action: CubismSemanticAction
    let duration: TimeInterval
    let loop: Bool
    let frames: [CubismMotionFrame]

    var jsonObject: [String: Any] {
        [
            "action": action.rawValue,
            "duration": duration,
            "loop": loop,
            "frames": frames.map { frame in
                ["time": frame.time, "parameters": frame.parameters]
            },
        ]
    }
}

enum CubismProceduralMotionSynthesizer {
    private static let parameterRanges: [String: ClosedRange<Double>] = [
        "ParamAngleX": -30...30,
        "ParamAngleY": -30...30,
        "ParamAngleZ": -30...30,
        "ParamBodyAngleX": -10...10,
        "ParamBodyAngleY": -10...10,
        "ParamBodyAngleZ": -10...10,
        "ParamBodyY": -1...1,
        // Eye openness is additive to the model's default value of one.
        "ParamEyeLOpen": -1...0,
        "ParamEyeROpen": -1...0,
        "ParamMouthOpenY": 0...1,
        "ParamEarL": -1...1,
        "ParamEarR": -1...1,
        "ParamBreath": 0...1,
        "ParamTail": -1...1,
        "ParamLegFrontL": -1...1,
        "ParamPawFrontL": -1...1,
        "ParamLegFrontR": -1...1,
        "ParamPawFrontR": -1...1,
        "ParamLegHindL": -1...1,
        "ParamPawHindL": -1...1,
        "ParamLegHindR": -1...1,
        "ParamPawHindR": -1...1,
    ]

    static func clip(
        action: CubismSemanticAction,
        duration requestedDuration: TimeInterval? = nil,
        intensity: Double = 1,
        framesPerSecond: Int = 30
    ) -> CubismProceduralMotionClip {
        let duration = min(10, max(0.2, requestedDuration ?? action.defaultDuration))
        let fps = min(60, max(12, framesPerSecond))
        let frameCount = max(2, Int(ceil(duration * Double(fps))) + 1)
        let strength = min(1, max(0, intensity))
        let frames = (0..<frameCount).map { index -> CubismMotionFrame in
            let time = min(duration, Double(index) / Double(fps))
            return CubismMotionFrame(
                time: time,
                parameters: bounded(sample(
                    action: action,
                    progress: time / duration,
                    intensity: strength)))
        }
        return CubismProceduralMotionClip(
            action: action,
            duration: duration,
            loop: action.loops,
            frames: frames)
    }

    private static func sample(
        action: CubismSemanticAction,
        progress: Double,
        intensity: Double
    ) -> [String: Double] {
        let p = min(1, max(0, progress))
        let tau = Double.pi * 2
        switch action {
        case .idle:
            let breath = 0.48 + 0.4 * sin(tau * p)
            let earDrift = 0.07 * sin(tau * p + 0.7) * intensity
            let blinkDistance = abs(p - 0.76)
            let blink = blinkDistance < 0.035
                ? -(1 - blinkDistance / 0.035) : 0
            return [
                "ParamBreath": breath,
                "ParamBodyY": 0.025 * sin(tau * p),
                "ParamAngleZ": 0.8 * sin(tau * p * 0.5) * intensity,
                "ParamEarL": earDrift,
                "ParamEarR": -earDrift * 0.7,
                "ParamTail": 0.16 * sin(tau * p * 1.5) * intensity,
                "ParamEyeLOpen": blink,
                "ParamEyeROpen": blink,
            ]

        case .walk:
            let phase = tau * p
            let stride = sin(phase) * intensity
            let paw = sin(phase + Double.pi / 2) * intensity
            return [
                "ParamLegFrontL": stride,
                "ParamLegFrontR": -stride,
                "ParamLegHindL": -stride,
                "ParamLegHindR": stride,
                "ParamPawFrontL": paw,
                "ParamPawFrontR": -paw,
                "ParamPawHindL": -paw,
                "ParamPawHindR": paw,
                "ParamBodyY": abs(sin(phase)) * 0.13 * intensity,
                "ParamBodyAngleY": cos(phase) * 1.1 * intensity,
                "ParamBodyAngleZ": sin(phase) * 2.4 * intensity,
                "ParamTail": sin(phase) * 0.38 * intensity,
                "ParamBreath": 0.55 + 0.25 * sin(phase * 2),
            ]

        case .react:
            let envelope = sin(Double.pi * p) * intensity
            let wiggle = sin(tau * p * 2)
            return [
                "ParamAngleX": sin(tau * p) * 7 * envelope,
                "ParamAngleZ": wiggle * 3 * envelope,
                "ParamBodyY": sin(Double.pi * p) * 0.3 * intensity,
                "ParamBodyAngleZ": wiggle * 4.5 * envelope,
                "ParamEarL": envelope * 0.75,
                "ParamEarR": envelope * 0.58,
                "ParamTail": wiggle * 0.85 * envelope,
            ]

        case .shakeHead:
            let envelope = sin(Double.pi * p) * intensity
            let shake = sin(tau * p * 4)
            let counter = -shake
            let blink = -max(0, sin(tau * p * 2)) * 0.22 * envelope
            return [
                "ParamAngleX": shake * 27 * envelope,
                "ParamAngleY": sin(tau * p * 8) * 3.5 * envelope,
                "ParamAngleZ": counter * 8 * envelope,
                "ParamBodyAngleZ": counter * 4.2 * envelope,
                "ParamEarL": counter * 0.92 * envelope,
                "ParamEarR": shake * 0.92 * envelope,
                "ParamEyeLOpen": blink,
                "ParamEyeROpen": blink,
            ]

        case .play:
            let envelope = sin(Double.pi * p) * intensity
            let wag = sin(tau * p * 5)
            let pawBounce = sin(tau * p * 2)
            return [
                "ParamBodyY": -0.42 * envelope,
                "ParamAngleZ": sin(tau * p) * 2.5 * envelope,
                "ParamBodyAngleY": -5.5 * envelope,
                "ParamBodyAngleZ": sin(tau * p * 2) * 4.2 * envelope,
                "ParamLegFrontL": (-0.82 + pawBounce * 0.12) * envelope,
                "ParamLegFrontR": (-0.82 - pawBounce * 0.12) * envelope,
                "ParamPawFrontL": 0.62 * envelope,
                "ParamPawFrontR": 0.62 * envelope,
                "ParamLegHindL": 0.28 * envelope,
                "ParamLegHindR": 0.28 * envelope,
                "ParamPawHindL": -0.18 * envelope,
                "ParamPawHindR": -0.18 * envelope,
                "ParamMouthOpenY": 0.82 * envelope,
                "ParamEarL": 0.35 * envelope,
                "ParamEarR": 0.28 * envelope,
                "ParamTail": wag * 0.96 * envelope,
            ]
        }
    }

    private static func bounded(_ values: [String: Double]) -> [String: Double] {
        values.reduce(into: [:]) { result, entry in
            guard entry.value.isFinite, let range = parameterRanges[entry.key] else {
                return
            }
            result[entry.key] = min(range.upperBound, max(range.lowerBound, entry.value))
        }
    }
}
