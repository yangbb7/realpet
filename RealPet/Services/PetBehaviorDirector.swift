import Foundation

@MainActor
final class PetBehaviorDirector {
    private struct RuntimeState {
        var personality: PetPersonality
        var capabilities: PetActionCapabilities
        var world = PetWorldState()
        var memory: PetBehaviorMemory
        var nextAutonomousActionAt: TimeInterval
        var lastCommandAt: [PetCommand.Action: TimeInterval] = [:]
        var lastPublishedSnapshot: PetBehaviorSnapshot?
    }

    private let hub: InteractionHub
    private let sendCommand: (UUID, PetCommand) -> Void
    private let now: () -> TimeInterval
    private let randomUnit: () -> Double
    private let onStateChange: (UUID, PetBehaviorSnapshot) -> Void
    private var states: [UUID: RuntimeState] = [:]
    private var observerToken: UUID?
    private var timer: Timer?
    private var planningCoordinator: BehaviorPlanningCoordinator?
    private var planningPetId: UUID?

    init(
        hub: InteractionHub,
        startTimer: Bool = false,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        randomUnit: @escaping () -> Double = { Double.random(in: 0...1) },
        onStateChange: @escaping (UUID, PetBehaviorSnapshot) -> Void = { _, _ in },
        sendCommand: @escaping (UUID, PetCommand) -> Void
    ) {
        self.hub = hub
        self.now = now
        self.randomUnit = randomUnit
        self.onStateChange = onStateChange
        self.sendCommand = sendCommand
        observerToken = hub.addObserver { [weak self] observation, world in
            self?.handle(observation, world: world)
        }
        if startTimer {
            timer = Timer.scheduledTimer(
                withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.runAutonomousBehavior() }
                }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func register(
        petId: UUID,
        personality: PetPersonality,
        capabilities: PetActionCapabilities
    ) {
        let now = now()
        if var state = states[petId] {
            state.personality = personality
            state.capabilities = capabilities
            let context = state.memory.context(
                at: now,
                personality: personality,
                isPaused: state.world.isPaused || state.world.isDragging)
            state.nextAutonomousActionAt = now + autonomousDelay(
                for: personality, context: context)
            store(state, for: petId)
            return
        }
        var memory = PetBehaviorMemory(now: now, personality: personality)
        let context = memory.context(
            at: now, personality: personality, isPaused: false)
        store(RuntimeState(
            personality: personality,
            capabilities: capabilities,
            memory: memory,
            nextAutonomousActionAt: now + autonomousDelay(
                for: personality, context: context)), for: petId)
    }

    func updatePersonality(petId: UUID, personality: PetPersonality) {
        guard var state = states[petId] else { return }
        let now = now()
        state.personality = personality
        let context = state.memory.context(
            at: now,
            personality: personality,
            isPaused: state.world.isPaused || state.world.isDragging)
        state.nextAutonomousActionAt = now
            + autonomousDelay(for: personality, context: context)
        store(state, for: petId)
    }

    func unregister(petId: UUID) {
        if planningPetId == petId {
            planningCoordinator?.cancelCurrent()
            planningPetId = nil
        }
        states.removeValue(forKey: petId)
        hub.removePet(petId)
    }

    func setPlanningCoordinator(_ coordinator: BehaviorPlanningCoordinator?) {
        planningCoordinator?.cancelCurrent()
        planningPetId = nil
        planningCoordinator = coordinator
    }

    func cancelPlanning() {
        planningCoordinator?.cancelCurrent()
        planningPetId = nil
    }

    private func handle(_ observation: InteractionObservation, world: PetWorldState) {
        guard var state = states[observation.petId] else { return }
        let now = now()
        state.world = world
        state.memory.observe(
            observation, personality: state.personality, now: now)
        let context = state.memory.context(
            at: now,
            personality: state.personality,
            isPaused: state.world.isPaused || state.world.isDragging)
        state.nextAutonomousActionAt = now
            + max(5, autonomousDelay(
                for: state.personality, context: context) * 0.6)
        store(state, for: observation.petId)

        guard let proposedIntent = PetBehaviorPolicy.intent(
                for: observation, personality: state.personality, now: now),
              !((world.isDragging || world.isPaused)
                  && proposedIntent.action != .pause
                  && proposedIntent.action != .resume),
              let intent = PetBehaviorPolicy.supportedIntent(
                proposedIntent, capabilities: state.capabilities) else { return }
        execute(intent)
    }

    private func execute(_ intent: PetIntent) {
        guard var state = states[intent.petId] else { return }
        let now = now()
        let command = PetCommand.executing(intent, now: now)
        let cooldown: Double
        switch command.action {
        case .faceToward: cooldown = 0.35
        case .moveToward, .moveAway: cooldown = 1.5
        case .react: cooldown = 0.25
        case .pause, .resume: cooldown = 0
        case .moveTo: cooldown = 3
        }
        if let previous = state.lastCommandAt[command.action],
           now - previous < cooldown { return }
        state.lastCommandAt[command.action] = now
        store(state, for: intent.petId)
        sendCommand(intent.petId, command)
    }

    func runAutonomousBehavior() {
        let now = now()
        for petId in Array(states.keys) {
            guard var state = states[petId] else { continue }
            let context = state.memory.context(
                at: now,
                personality: state.personality,
                isPaused: state.world.isPaused || state.world.isDragging)
            store(state, for: petId)
            guard !state.world.isDragging,
                  !state.world.isPaused,
                  (state.capabilities.locomotion || state.capabilities.reaction),
                  now >= state.nextAutonomousActionAt else { continue }

            let target = SpatialContext(
                space: .screenNormalized,
                x: 0.12 + min(1, max(0, randomUnit())) * 0.76,
                y: 0.10 + min(1, max(0, randomUnit())) * 0.72)
            let reactionRoll = min(1, max(0, randomUnit()))
            if requestModelPlan(
                petId: petId,
                state: state,
                context: context,
                target: target,
                reactionRoll: reactionRoll,
                now: now) {
                state.nextAutonomousActionAt = now + autonomousDelay(
                    for: state.personality, context: context)
                store(state, for: petId)
                continue
            }
            if let intent = PetBehaviorPolicy.autonomousIntent(
                petId: petId,
                personality: state.personality,
                capabilities: state.capabilities,
                target: target,
                reactionRoll: reactionRoll,
                context: context) {
                execute(intent)
            }
            state = states[petId] ?? state
            state.nextAutonomousActionAt = now + autonomousDelay(
                for: state.personality, context: context)
            store(state, for: petId)
        }
    }

    private func requestModelPlan(
        petId: UUID,
        state: RuntimeState,
        context: PetBehaviorContext,
        target: SpatialContext,
        reactionRoll: Double,
        now: TimeInterval
    ) -> Bool {
        guard let planningCoordinator else { return false }
        let request = BehaviorPlanningRequest(
            petId: petId,
            issuedAt: now,
            expiresAt: now + 8,
            personality: state.personality,
            context: context,
            capabilities: state.capabilities,
            recentInteractionKinds: state.memory.recentInteractions.map(\.kind))
        let accepted = planningCoordinator.submit(request) {
            [weak self] result in
            self?.finishModelPlan(
                request: request,
                result: result,
                target: target,
                reactionRoll: reactionRoll)
        }
        if accepted { planningPetId = petId }
        return accepted
    }

    private func finishModelPlan(
        request: BehaviorPlanningRequest,
        result: Result<BehaviorPlanningResult, Error>,
        target: SpatialContext,
        reactionRoll: Double
    ) {
        guard planningPetId == request.petId else { return }
        planningPetId = nil
        guard var state = states[request.petId],
              !state.world.isPaused,
              !state.world.isDragging else { return }
        let currentTime = now()
        let context = state.memory.context(
            at: currentTime,
            personality: state.personality,
            isPaused: false)
        let intent: PetIntent?
        switch result {
        case .success(let suggestion):
            intent = PetBehaviorPolicy.modelSuggestedIntent(
                petId: request.petId,
                result: suggestion,
                personality: state.personality,
                context: context,
                capabilities: state.capabilities,
                wanderTarget: target)
        case .failure:
            intent = PetBehaviorPolicy.autonomousIntent(
                petId: request.petId,
                personality: state.personality,
                capabilities: state.capabilities,
                target: target,
                reactionRoll: reactionRoll,
                context: context)
        }
        if let intent { execute(intent) }
        state = states[request.petId] ?? state
        state.nextAutonomousActionAt = currentTime + autonomousDelay(
            for: state.personality, context: context)
        store(state, for: request.petId)
    }

    private func autonomousDelay(
        for personality: PetPersonality,
        context: PetBehaviorContext
    ) -> Double {
        max(
            5,
            10 + (1 - personality.energy) * 18
                + personality.independence * 5
                - context.engagement * 5
                - context.arousal * 3
                + context.stress * 4)
    }

    private func store(
        _ value: RuntimeState,
        for petId: UUID
    ) {
        var state = value
        let snapshot = state.memory.snapshot(
            isPaused: state.world.isPaused || state.world.isDragging)
        let changed = snapshot != state.lastPublishedSnapshot
        state.lastPublishedSnapshot = snapshot
        states[petId] = state
        if changed {
            onStateChange(petId, snapshot)
        }
    }
}
