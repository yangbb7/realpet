import Foundation

struct PetPersonality: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Hashable, Sendable {
        case balanced
        case gentle
        case lively
        case shy
        case mischievous
        case independent
        case custom

        static var builtIn: [Preset] {
            allCases.filter { $0 != .custom }
        }

        var displayName: String {
            switch self {
            case .balanced: return "均衡"
            case .gentle: return "温顺"
            case .lively: return "活泼"
            case .shy: return "胆小"
            case .mischievous: return "淘气"
            case .independent: return "独立"
            case .custom: return "自定义"
            }
        }

        var symbolName: String {
            switch self {
            case .balanced: return "circle.hexagongrid"
            case .gentle: return "heart"
            case .lively: return "bolt"
            case .shy: return "leaf"
            case .mischievous: return "sparkles"
            case .independent: return "moon"
            case .custom: return "slider.horizontal.3"
            }
        }
    }

    var preset: Preset
    var energy: Double
    var curiosity: Double
    var affection: Double
    var boldness: Double
    var playfulness: Double
    var independence: Double

    private enum CodingKeys: String, CodingKey {
        case preset
        case energy
        case curiosity
        case affection
        case boldness
        case playfulness
        case independence
    }

    static let balanced = values(
        .balanced, energy: 0.50, curiosity: 0.55, affection: 0.55,
        boldness: 0.50, playfulness: 0.50, independence: 0.45)

    static func forPreset(_ preset: Preset) -> PetPersonality {
        switch preset {
        case .balanced:
            return .balanced
        case .gentle:
            return values(preset, energy: 0.32, curiosity: 0.45, affection: 0.88,
                          boldness: 0.48, playfulness: 0.38, independence: 0.22)
        case .lively:
            return values(preset, energy: 0.92, curiosity: 0.82, affection: 0.72,
                          boldness: 0.75, playfulness: 0.90, independence: 0.30)
        case .shy:
            return values(preset, energy: 0.38, curiosity: 0.42, affection: 0.58,
                          boldness: 0.16, playfulness: 0.30, independence: 0.62)
        case .mischievous:
            return values(preset, energy: 0.80, curiosity: 0.92, affection: 0.52,
                          boldness: 0.82, playfulness: 0.96, independence: 0.55)
        case .independent:
            return values(preset, energy: 0.45, curiosity: 0.62, affection: 0.30,
                          boldness: 0.68, playfulness: 0.35, independence: 0.92)
        case .custom:
            return values(preset, energy: 0.50, curiosity: 0.55, affection: 0.55,
                          boldness: 0.50, playfulness: 0.50, independence: 0.45)
        }
    }

    static func customized(
        energy: Double,
        curiosity: Double,
        affection: Double,
        boldness: Double,
        playfulness: Double,
        independence: Double
    ) -> PetPersonality {
        values(
            .custom,
            energy: energy,
            curiosity: curiosity,
            affection: affection,
            boldness: boldness,
            playfulness: playfulness,
            independence: independence)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try values.decodeIfPresent(Preset.self, forKey: .preset)
            ?? .balanced
        let fallback = Self.forPreset(preset)
        self.init(
            preset: preset,
            energy: try values.decodeIfPresent(Double.self, forKey: .energy)
                ?? fallback.energy,
            curiosity: try values.decodeIfPresent(Double.self, forKey: .curiosity)
                ?? fallback.curiosity,
            affection: try values.decodeIfPresent(Double.self, forKey: .affection)
                ?? fallback.affection,
            boldness: try values.decodeIfPresent(Double.self, forKey: .boldness)
                ?? fallback.boldness,
            playfulness: try values.decodeIfPresent(Double.self, forKey: .playfulness)
                ?? fallback.playfulness,
            independence: try values.decodeIfPresent(Double.self, forKey: .independence)
                ?? fallback.independence)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(preset, forKey: .preset)
        try values.encode(energy, forKey: .energy)
        try values.encode(curiosity, forKey: .curiosity)
        try values.encode(affection, forKey: .affection)
        try values.encode(boldness, forKey: .boldness)
        try values.encode(playfulness, forKey: .playfulness)
        try values.encode(independence, forKey: .independence)
    }

    private init(
        preset: Preset,
        energy: Double,
        curiosity: Double,
        affection: Double,
        boldness: Double,
        playfulness: Double,
        independence: Double
    ) {
        self.preset = preset
        self.energy = Self.normalized(energy)
        self.curiosity = Self.normalized(curiosity)
        self.affection = Self.normalized(affection)
        self.boldness = Self.normalized(boldness)
        self.playfulness = Self.normalized(playfulness)
        self.independence = Self.normalized(independence)
    }

    private static func values(
        _ preset: Preset,
        energy: Double,
        curiosity: Double,
        affection: Double,
        boldness: Double,
        playfulness: Double,
        independence: Double
    ) -> PetPersonality {
        PetPersonality(
            preset: preset,
            energy: energy,
            curiosity: curiosity,
            affection: affection,
            boldness: boldness,
            playfulness: playfulness,
            independence: independence)
    }

    private static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }
}
