import Foundation

enum PetTemplateProfile: String, Codable, CaseIterable, Sendable {
    case cat = "cat-v1"
    case dogLongSnout = "dog-long-snout-v1"
    case dogShortSnout = "dog-short-snout-v1"

    var displayName: String {
        switch self {
        case .cat: return "猫"
        case .dogLongSnout: return "长嘴犬"
        case .dogShortSnout: return "短嘴犬"
        }
    }

    var atlasPromptGuidance: String {
        switch self {
        case .cat:
            return "Preserve feline facial proportions, triangular ears, compact muzzle, flexible spine, and feline paws."
        case .dogLongSnout:
            return "Preserve canine anatomy with a clearly projected long or medium muzzle, natural ear shape, and breed-accurate leg proportions."
        case .dogShortSnout:
            return "Preserve compact brachycephalic or round-faced canine proportions, a short muzzle, broad head, and breed-accurate compact body."
        }
    }
}
