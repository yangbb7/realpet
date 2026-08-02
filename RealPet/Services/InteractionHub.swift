import Foundation

struct PetWorldState: Equatable, Sendable {
    var pointer: SpatialContext?
    var isDragging = false
    var isPaused = false
    var lastInteractionAt: TimeInterval?
    var recentKinds: [String] = []

    mutating func apply(_ observation: InteractionObservation) {
        if observation.source == InteractionSource.pointer,
           let spatial = observation.spatial {
            pointer = spatial
        }
        switch observation.kind {
        case InteractionKind.dragStarted:
            isDragging = true
        case InteractionKind.dragEnded:
            isDragging = false
        case InteractionKind.userRequestsPause:
            isPaused = true
        case InteractionKind.userRequestsResume:
            isPaused = false
        default:
            break
        }
        lastInteractionAt = observation.occurredAt
        recentKinds.append(observation.kind)
        if recentKinds.count > 12 {
            recentKinds.removeFirst(recentKinds.count - 12)
        }
    }
}

@MainActor
final class InteractionHub {
    typealias Observer = (InteractionObservation, PetWorldState) -> Void

    private var observers: [UUID: Observer] = [:]
    private var worldStates: [UUID: PetWorldState] = [:]
    private var seenEventIds: Set<UUID> = []
    private var seenEventOrder: [UUID] = []

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func publish(
        _ observation: InteractionObservation,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard observation.isFresh(at: now),
              seenEventIds.insert(observation.id).inserted else { return }

        seenEventOrder.append(observation.id)
        if seenEventOrder.count > 256 {
            let excess = seenEventOrder.count - 256
            let expired = seenEventOrder.prefix(excess)
            seenEventIds.subtract(expired)
            seenEventOrder.removeFirst(excess)
        }

        var state = worldStates[observation.petId] ?? PetWorldState()
        state.apply(observation)
        worldStates[observation.petId] = state
        for observer in observers.values {
            observer(observation, state)
        }
    }

    func state(for petId: UUID) -> PetWorldState {
        worldStates[petId] ?? PetWorldState()
    }

    func removePet(_ petId: UUID) {
        worldStates.removeValue(forKey: petId)
    }
}
