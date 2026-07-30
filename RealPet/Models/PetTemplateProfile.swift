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

enum PetTemplateSelection {
    private static let shortSnoutIdentifiers = [
        "affenpinscher", "boston bull", "boston terrier", "boxer",
        "brabancon griffon", "bulldog", "bull mastiff", "chow",
        "french bulldog", "japanese spaniel", "lhasa", "pekingese",
        "pug", "shih-tzu", "shih tzu",
    ]

    static func select(
        detectedClass: String,
        classificationIdentifiers: [String]
    ) -> PetTemplateProfile? {
        let detected = normalize(detectedClass)
        let labels = classificationIdentifiers.map(normalize)
        if detected == "cat" || labels.contains(where: isCat) {
            return .cat
        }
        guard detected == "dog" || labels.contains(where: isDog) else {
            return nil
        }
        return labels.contains(where: isShortSnoutDog)
            ? .dogShortSnout : .dogLongSnout
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCat(_ value: String) -> Bool {
        value == "cat" || value.contains("domestic cat")
            || value.contains("tabby") || value.contains("kitten")
    }

    private static func isDog(_ value: String) -> Bool {
        value == "dog" || value.contains("domestic dog")
            || value.contains("puppy") || value.contains("terrier")
            || value.contains("retriever") || value.contains("spaniel")
            || value.contains("shepherd") || value.contains("hound")
    }

    private static func isShortSnoutDog(_ value: String) -> Bool {
        shortSnoutIdentifiers.contains { identifier in
            value.contains(normalize(identifier))
        }
    }
}
