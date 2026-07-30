import Foundation

enum PetMood: String, Equatable, Sendable {
    case calm
    case curious
    case happy
    case playful
    case cautious
    case resting

    var displayName: String {
        switch self {
        case .calm: return "平静"
        case .curious: return "好奇"
        case .happy: return "开心"
        case .playful: return "想玩"
        case .cautious: return "警觉"
        case .resting: return "休息"
        }
    }

    var symbolName: String {
        switch self {
        case .calm: return "wind"
        case .curious: return "eye"
        case .happy: return "heart.fill"
        case .playful: return "sparkles"
        case .cautious: return "exclamationmark.triangle"
        case .resting: return "pause.fill"
        }
    }
}

struct PetBehaviorContext: Equatable, Sendable {
    let valence: Double
    let arousal: Double
    let engagement: Double
    let stress: Double
    let mood: PetMood

    static let neutral = PetBehaviorContext(
        valence: 0,
        arousal: 0.3,
        engagement: 0.2,
        stress: 0,
        mood: .calm)
}

struct PetBehaviorSnapshot: Equatable, Sendable {
    let mood: PetMood
    let isPaused: Bool
    let lastInteractionKind: String?
}

struct PetInteractionMemoryEntry: Equatable, Sendable {
    let source: String
    let kind: String
    let occurredAt: TimeInterval
    let confidence: Double
}

/// Short-lived semantic memory. It intentionally stores no raw evidence,
/// transcript, image, or provider payload.
struct PetBehaviorMemory: Equatable, Sendable {
    private(set) var valence: Double = 0
    private(set) var arousal: Double
    private(set) var engagement: Double
    private(set) var stress: Double = 0
    private(set) var recentInteractions: [PetInteractionMemoryEntry] = []
    private var updatedAt: TimeInterval

    init(now: TimeInterval, personality: PetPersonality) {
        updatedAt = now
        arousal = Self.baselineArousal(personality)
        engagement = Self.baselineEngagement(personality)
    }

    mutating func observe(
        _ observation: InteractionObservation,
        personality: PetPersonality,
        now: TimeInterval
    ) {
        guard now.isFinite else { return }
        decay(to: now, personality: personality)
        let weight = min(1, max(0, observation.confidence))
        var valenceDelta = 0.0
        var arousalDelta = 0.0
        var engagementDelta = 0.0
        var stressDelta = 0.0

        switch observation.kind {
        case InteractionKind.petTapped:
            valenceDelta = 0.22 + personality.affection * 0.18
            engagementDelta = 0.24
            arousalDelta = 0.10
        case InteractionKind.petDoubleTapped:
            valenceDelta = 0.25 + personality.playfulness * 0.20
            engagementDelta = 0.32
            arousalDelta = 0.24
        case InteractionKind.petPetted:
            valenceDelta = 0.34 + personality.affection * 0.22
            engagementDelta = 0.38
            arousalDelta = 0.08
            stressDelta = -0.16
        case InteractionKind.userWaves, InteractionKind.userCallsPet,
             InteractionKind.userLooksAtPet, InteractionKind.userAppears:
            valenceDelta = 0.12
            engagementDelta = 0.25 + personality.curiosity * 0.12
            arousalDelta = 0.08
        case InteractionKind.userPraisesPet:
            valenceDelta = 0.34 + personality.affection * 0.20
            engagementDelta = 0.34
            arousalDelta = 0.10
            stressDelta = -0.12
        case InteractionKind.userInvitesPlay, InteractionKind.userOffersObject:
            valenceDelta = 0.24 + personality.playfulness * 0.16
            engagementDelta = 0.42
            arousalDelta = 0.30 + personality.energy * 0.10
        case InteractionKind.pointerApproachingFast,
             InteractionKind.userApproachesPet:
            arousalDelta = 0.30
            engagementDelta = 0.18
            stressDelta = 0.20 + (1 - personality.boldness) * 0.42
            valenceDelta = personality.boldness >= 0.55 ? 0.08 : -0.16
        case InteractionKind.dragStarted:
            arousalDelta = 0.18
            stressDelta = max(0, 0.24 - personality.affection * 0.16)
        case InteractionKind.dragEnded:
            valenceDelta = 0.08
            stressDelta = -0.10
        case InteractionKind.userRequestsPause:
            arousalDelta = -0.30
            stressDelta = -0.08
        case InteractionKind.userRequestsResume:
            arousalDelta = 0.12
            engagementDelta = 0.12
        default:
            break
        }

        valence = Self.clamp(valence + valenceDelta * weight, lower: -1, upper: 1)
        arousal = Self.clamp(arousal + arousalDelta * weight)
        engagement = Self.clamp(engagement + engagementDelta * weight)
        stress = Self.clamp(stress + stressDelta * weight)
        recentInteractions.append(PetInteractionMemoryEntry(
            source: observation.source,
            kind: observation.kind,
            occurredAt: observation.occurredAt,
            confidence: observation.confidence))
        prune(at: now)
    }

    mutating func context(
        at now: TimeInterval,
        personality: PetPersonality,
        isPaused: Bool
    ) -> PetBehaviorContext {
        decay(to: now, personality: personality)
        return PetBehaviorContext(
            valence: valence,
            arousal: arousal,
            engagement: engagement,
            stress: stress,
            mood: mood(isPaused: isPaused))
    }

    func snapshot(isPaused: Bool) -> PetBehaviorSnapshot {
        PetBehaviorSnapshot(
            mood: mood(isPaused: isPaused),
            isPaused: isPaused,
            lastInteractionKind: recentInteractions.last?.kind)
    }

    mutating func decay(to now: TimeInterval, personality: PetPersonality) {
        guard now.isFinite, now > updatedAt else { return }
        let elapsed = now - updatedAt
        let fastFactor = pow(0.5, elapsed / 22)
        let slowFactor = pow(0.5, elapsed / 38)
        valence *= slowFactor
        arousal = Self.baselineArousal(personality)
            + (arousal - Self.baselineArousal(personality)) * fastFactor
        engagement = Self.baselineEngagement(personality)
            + (engagement - Self.baselineEngagement(personality)) * slowFactor
        stress *= fastFactor
        updatedAt = now
        prune(at: now)
    }

    private func mood(isPaused: Bool) -> PetMood {
        if isPaused { return .resting }
        if stress >= 0.38 { return .cautious }
        if arousal >= 0.62, engagement >= 0.42 { return .playful }
        if valence >= 0.28 { return .happy }
        if engagement >= 0.32 { return .curious }
        return .calm
    }

    private mutating func prune(at now: TimeInterval) {
        recentInteractions.removeAll { now - $0.occurredAt > 45 }
        if recentInteractions.count > 8 {
            recentInteractions.removeFirst(recentInteractions.count - 8)
        }
    }

    private static func baselineArousal(_ personality: PetPersonality) -> Double {
        0.12 + personality.energy * 0.35
    }

    private static func baselineEngagement(_ personality: PetPersonality) -> Double {
        0.08 + (1 - personality.independence) * 0.16
    }

    private static func clamp(
        _ value: Double,
        lower: Double = 0,
        upper: Double = 1
    ) -> Double {
        min(upper, max(lower, value))
    }
}
