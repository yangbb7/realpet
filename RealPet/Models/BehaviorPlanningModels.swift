import Foundation

enum BehaviorPlanAction: String, Codable, CaseIterable, Sendable {
    case none
    case react
    case wander
}

struct BehaviorPlanningRequest: Equatable, Sendable {
    let id: UUID
    let petId: UUID
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval
    let personality: PetPersonality
    let context: PetBehaviorContext
    let capabilities: PetActionCapabilities
    let recentInteractionKinds: [String]

    init(
        id: UUID = UUID(),
        petId: UUID,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval,
        personality: PetPersonality,
        context: PetBehaviorContext,
        capabilities: PetActionCapabilities,
        recentInteractionKinds: [String]
    ) {
        self.id = id
        self.petId = petId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.personality = personality
        self.context = context
        self.capabilities = capabilities
        self.recentInteractionKinds = Array(recentInteractionKinds.suffix(8))
    }

    func isFresh(at now: TimeInterval) -> Bool {
        issuedAt.isFinite
            && expiresAt.isFinite
            && issuedAt <= now
            && expiresAt >= now
            && expiresAt > issuedAt
    }
}

struct BehaviorPlanningResult: Equatable, Sendable {
    let action: BehaviorPlanAction
    let energy: Double

    var isValid: Bool {
        energy.isFinite && (0...1).contains(energy)
    }
}

protocol BehaviorPlanningModel: Sendable {
    func plan(_ request: BehaviorPlanningRequest) async throws
        -> BehaviorPlanningResult
}

enum BehaviorPlanningCoordinatorError: Error, Equatable {
    case expired
    case invalidResult
}
