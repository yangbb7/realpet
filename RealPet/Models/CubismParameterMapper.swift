import Foundation

enum CubismParameterMapper {
    static let angleX = "ParamAngleX"
    static let angleY = "ParamAngleY"
    static let angleZ = "ParamAngleZ"
    static let bodyAngleX = "ParamBodyAngleX"
    static let eyeX = "ParamEyeBallX"
    static let eyeY = "ParamEyeBallY"

    static func parameters(
        target: SpatialContext,
        windowCenter: (x: Double, y: Double)?,
        intensity: Double
    ) -> [String: Double]? {
        let delta: (Double, Double)
        switch target.space {
        case .petLocalNormalized:
            delta = ((target.x - 0.5) * 2, (target.y - 0.5) * 2)
        case .screenNormalized:
            guard let windowCenter else { return nil }
            delta = (
                (target.x - windowCenter.x) * 2,
                (target.y - windowCenter.y) * 2)
        case .cameraNormalized:
            return nil
        }
        return parameters(
            normalizedDeltaX: delta.0,
            normalizedDeltaY: delta.1,
            intensity: intensity)
    }

    static func parameters(
        normalizedDeltaX: Double,
        normalizedDeltaY: Double,
        intensity: Double
    ) -> [String: Double] {
        let dx = applyDeadZone(normalizedDeltaX)
        let dy = applyDeadZone(normalizedDeltaY)
        let gain = 0.45 + 0.55 * min(1, max(0, intensity))
        return [
            angleX: dx * 30 * gain,
            angleY: dy * 20 * gain,
            angleZ: -dx * 3 * gain,
            bodyAngleX: dx * 8 * gain,
            eyeX: dx,
            eyeY: dy,
        ]
    }

    private static func applyDeadZone(_ value: Double) -> Double {
        let clamped = min(1, max(-1, value))
        let deadZone = 0.025
        guard abs(clamped) > deadZone else { return 0 }
        return clamped.sign == .minus
            ? -(abs(clamped) - deadZone) / (1 - deadZone)
            : (clamped - deadZone) / (1 - deadZone)
    }
}
