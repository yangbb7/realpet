import Foundation

enum SpeechInteractionState: Equatable, Sendable {
    case disabled
    case requestingPermission
    case starting
    case listening
    case denied
    case restricted
    case unavailable(String)
    case failed(String)
}

struct SpeechSemanticDetection: Equatable, Sendable {
    let kind: String
    let confidence: Double
}

/// Converts incremental speech transcripts into the same allow-listed semantic
/// observations used by pointer, camera, and VLM adapters.
struct SpeechCommandInterpreter {
    private struct Rule {
        let kind: String
        let phrases: [String]
        let requiresFinal: Bool
    }

    private static let rules: [Rule] = [
        Rule(
            kind: InteractionKind.userRequestsResume,
            phrases: ["继续", "动起来", "继续玩", "continue", "keep going"],
            requiresFinal: true),
        Rule(
            kind: InteractionKind.userRequestsPause,
            phrases: ["停下", "别动", "安静", "暂停", "stop", "stay still"],
            requiresFinal: true),
        Rule(
            kind: InteractionKind.userInvitesPlay,
            phrases: ["一起玩", "玩一下", "来玩", "玩游戏", "let's play", "play with me"],
            requiresFinal: false),
        Rule(
            kind: InteractionKind.userPraisesPet,
            phrases: ["真棒", "好乖", "乖孩子", "做得好", "good dog", "good boy", "good girl", "well done"],
            requiresFinal: false),
        Rule(
            kind: InteractionKind.userCallsPet,
            phrases: ["过来", "来这里", "到这来", "你好", "嗨", "come here", "hello", "hi"],
            requiresFinal: false),
    ]

    private let cooldown: TimeInterval
    private var emittedInUtterance: Set<String> = []
    private var lastEmissionAt: [String: TimeInterval] = [:]

    init(cooldown: TimeInterval = 1.8) {
        self.cooldown = max(0.5, cooldown)
    }

    mutating func process(
        transcript: String,
        isFinal: Bool,
        capturedAt: TimeInterval
    ) -> [SpeechSemanticDetection] {
        guard capturedAt.isFinite else { return [] }
        let normalized = Self.normalized(transcript)
        var detections: [SpeechSemanticDetection] = []

        for rule in Self.rules where !emittedInUtterance.contains(rule.kind) {
            guard isFinal || !rule.requiresFinal else { continue }
            guard rule.phrases.contains(where: {
                Self.contains(phrase: $0, in: normalized)
            }) else { continue }
            if let last = lastEmissionAt[rule.kind], capturedAt - last < cooldown {
                emittedInUtterance.insert(rule.kind)
                continue
            }
            emittedInUtterance.insert(rule.kind)
            lastEmissionAt[rule.kind] = capturedAt
            detections.append(SpeechSemanticDetection(
                kind: rule.kind,
                confidence: isFinal ? 0.92 : 0.82))
            break
        }

        if isFinal {
            emittedInUtterance.removeAll(keepingCapacity: true)
        }
        return detections
    }

    mutating func resetUtterance() {
        emittedInUtterance.removeAll(keepingCapacity: true)
    }

    mutating func reset() {
        emittedInUtterance.removeAll(keepingCapacity: true)
        lastEmissionAt.removeAll(keepingCapacity: true)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: "[^\\p{L}\\p{N}]+",
                with: " ",
                options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func contains(phrase: String, in transcript: String) -> Bool {
        let phrase = normalized(phrase)
        guard !phrase.isEmpty else { return false }
        let usesWordBoundaries = phrase.unicodeScalars.allSatisfy { $0.isASCII }
        if usesWordBoundaries {
            return " \(transcript) ".contains(" \(phrase) ")
        }
        return transcript.replacingOccurrences(of: " ", with: "")
            .contains(phrase.replacingOccurrences(of: " ", with: ""))
    }
}
