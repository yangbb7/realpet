import Foundation

enum PetAssetProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case highQuality = "high_quality"
    case spaceSaver = "space_saver"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "标准"
        case .highQuality: return "高清"
        case .spaceSaver: return "省空间"
        }
    }

    var maximumOutputDimension: Int {
        switch self {
        case .standard: return 960
        case .highQuality: return 1280
        case .spaceSaver: return 640
        }
    }

    var frameRate: Int {
        switch self {
        case .standard: return 16
        case .highQuality: return 24
        case .spaceSaver: return 12
        }
    }

    var detail: String {
        "\(maximumOutputDimension)px / \(frameRate) FPS"
    }
}

enum PetAssetProfileStore {
    private static let key = "pet-asset-profile-v1"

    static func load() -> PetAssetProfile {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let profile = PetAssetProfile(rawValue: raw) else {
            return .standard
        }
        return profile
    }

    static func save(_ profile: PetAssetProfile) {
        UserDefaults.standard.set(profile.rawValue, forKey: key)
    }
}
