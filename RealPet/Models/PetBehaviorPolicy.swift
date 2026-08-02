import Foundation

enum PetBehaviorPolicy {
    static func intent(
        for observation: InteractionObservation,
        personality: PetPersonality,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> PetIntent? {
        guard observation.petId != UUID(), observation.isFresh(at: now) else { return nil }

        switch observation.kind {
        case InteractionKind.petTapped:
            guard let cue = PetInteractionBinding.cue(for: observation.kind) else { return nil }
            return interactionResponseIntent(
                for: observation, cue: cue,
                emotion: "affectionate", priority: 78)

        case InteractionKind.petDoubleTapped:
            return nil

        case InteractionKind.petPetted:
            return PetIntent(
                petId: observation.petId, action: .react,
                target: observation.spatial, emotion: "affectionate", priority: 72,
                duration: 1.0, intensity: 0.45 + personality.affection * 0.45,
                interruptPolicy: .replace, animation: .cuddle)

        case InteractionKind.fileDroppedOnBody:
            guard let cue = PetInteractionBinding.cue(for: observation.kind) else { return nil }
            return interactionResponseIntent(
                for: observation, cue: cue, emotion: "curious", priority: 82)

        case InteractionKind.fileDroppedOnHead:
            guard let cue = PetInteractionBinding.cue(for: observation.kind) else { return nil }
            return interactionResponseIntent(
                for: observation, cue: cue, emotion: "content", priority: 84)

        case InteractionKind.pointerEntered, InteractionKind.pointerNear:
            guard personality.curiosity >= 0.20 else { return nil }
            return PetIntent(
                petId: observation.petId, action: .orient,
                target: observation.spatial, emotion: "curious", priority: 45,
                duration: 1.0, intensity: personality.curiosity,
                interruptPolicy: .replace)

        case InteractionKind.pointerApproachingFast:
            return PetIntent(
                petId: observation.petId,
                action: .orient,
                target: observation.spatial,
                emotion: "attentive",
                priority: 48,
                duration: 1.0,
                intensity: 0.8,
                interruptPolicy: .replace)

        case InteractionKind.dragStarted:
            return PetIntent(
                petId: observation.petId, action: .pause,
                target: observation.spatial, emotion: "held", priority: 100,
                duration: 10, intensity: 1, interruptPolicy: .replace)

        case InteractionKind.dragEnded:
            return PetIntent(
                petId: observation.petId, action: .resume,
                target: observation.spatial, emotion: "released", priority: 100,
                duration: 0, intensity: 1, interruptPolicy: .replace)

        case InteractionKind.userWaves:
            return PetIntent(
                petId: observation.petId, action: .react,
                target: safeRuntimeTarget(observation.spatial),
                emotion: "engaged", priority: 58,
                duration: 1.0,
                intensity: 0.35 + personality.playfulness * 0.5,
                interruptPolicy: .replace, animation: .wave)

        case InteractionKind.userOffersObject:
            return PetIntent(
                petId: observation.petId, action: .react,
                target: safeRuntimeTarget(observation.spatial),
                emotion: personality.boldness < 0.35 ? "cautious" : "curious",
                priority: 68, duration: 1.2,
                intensity: 0.4 + personality.curiosity * 0.45,
                interruptPolicy: .replace, animation: .paw)

        case InteractionKind.userLooksAtPet, InteractionKind.userAppears:
            let target = safeRuntimeTarget(observation.spatial)
            return PetIntent(
                petId: observation.petId,
                action: target == nil ? .react : .orient,
                target: target,
                emotion: "attentive", priority: 42,
                duration: 1.0, intensity: personality.curiosity,
                interruptPolicy: .replace)

        case InteractionKind.userApproachesPet:
            let canLocateActor = safeRuntimeTarget(observation.spatial) != nil
            return PetIntent(
                petId: observation.petId,
                action: canLocateActor ? .orient : .react,
                target: safeRuntimeTarget(observation.spatial),
                emotion: "engaged",
                priority: 58, duration: 1.0,
                intensity: 0.6,
                interruptPolicy: .replace)

        case InteractionKind.userCallsPet:
            return PetIntent(
                petId: observation.petId, action: .react,
                target: nil, emotion: "attentive", priority: 64,
                duration: 0.9,
                intensity: 0.35 + personality.affection * 0.45,
                interruptPolicy: .replace, animation: .wave)

        case InteractionKind.userPraisesPet:
            return PetIntent(
                petId: observation.petId, action: .react,
                target: nil, emotion: "happy", priority: 58,
                duration: 0.9,
                intensity: 0.30 + personality.affection * 0.50,
                interruptPolicy: .replace, animation: .jumpCheer)

        case InteractionKind.userInvitesPlay:
            return PetIntent(
                petId: observation.petId, action: .react,
                target: nil, emotion: "playful", priority: 76,
                duration: 1.2,
                intensity: 0.45 + personality.playfulness * 0.50,
                interruptPolicy: .replace, animation: .jumpCheer)

        case InteractionKind.userRequestsPause:
            return PetIntent(
                petId: observation.petId, action: .pause,
                target: nil, emotion: "calm", priority: 100,
                duration: 30, intensity: 1,
                interruptPolicy: .replace)

        case InteractionKind.userRequestsResume:
            return PetIntent(
                petId: observation.petId, action: .resume,
                target: nil, emotion: "ready", priority: 100,
                duration: 0, intensity: 1,
                interruptPolicy: .replace)

        default:
            return nil
        }
    }

    private static func safeRuntimeTarget(_ spatial: SpatialContext?) -> SpatialContext? {
        guard let spatial,
              spatial.space != .cameraNormalized else { return nil }
        return spatial
    }

    private static func interactionResponseIntent(
        for observation: InteractionObservation,
        cue: PetAnimationCue,
        emotion: String,
        priority: Int
    ) -> PetIntent {
        PetIntent(
            petId: observation.petId, action: .react,
            target: observation.spatial, emotion: emotion, priority: priority,
            duration: 1.2, intensity: 0.8, interruptPolicy: .replace,
            animation: cue)
    }

    static func autonomousWanderIntent(
        petId: UUID,
        personality: PetPersonality,
        target: SpatialContext,
        context: PetBehaviorContext = .neutral
    ) -> PetIntent {
        let motionEnergy = clamp(
            personality.energy * 0.65 + context.arousal * 0.35
                - context.stress * 0.20)
        return PetIntent(
            petId: petId, action: .wander, target: target,
            emotion: context.mood.rawValue,
            priority: 10, duration: 2.5 + motionEnergy * 3,
            intensity: 0.20 + motionEnergy * 0.60,
            interruptPolicy: .preserve)
    }

    static func autonomousIntent(
        petId: UUID,
        personality: PetPersonality,
        capabilities: PetActionCapabilities,
        target: SpatialContext,
        reactionRoll: Double,
        context: PetBehaviorContext = .neutral
    ) -> PetIntent? {
        guard petId != UUID() else { return nil }
        let reactionChance = clamp(
            0.18 + personality.playfulness * 0.62
                + context.engagement * 0.25
                + max(0, context.valence) * 0.15
                - context.stress * 0.25)
        if capabilities.reaction,
           (!capabilities.locomotion || reactionRoll < reactionChance) {
            let reactionEnergy = clamp(
                personality.playfulness * 0.55
                    + context.arousal * 0.25
                    + context.engagement * 0.20)
            return PetIntent(
                petId: petId,
                action: .react,
                target: nil,
                emotion: context.mood.rawValue,
                priority: 12,
                duration: 0.7 + reactionEnergy * 0.6,
                intensity: 0.25 + reactionEnergy * 0.70,
                interruptPolicy: .preserve)
        }
        guard capabilities.locomotion else { return nil }
        return autonomousWanderIntent(
            petId: petId, personality: personality, target: target,
            context: context)
    }

    static func supportedIntent(
        _ intent: PetIntent,
        capabilities: PetActionCapabilities
    ) -> PetIntent? {
        switch intent.action {
        case .approach, .retreat, .wander:
            return capabilities.locomotion ? intent : nil
        case .react:
            return capabilities.reaction ? intent : nil
        case .orient:
            return capabilities.orientation ? intent : nil
        case .pause, .resume:
            return intent
        }
    }

    static func modelSuggestedIntent(
        petId: UUID,
        result: BehaviorPlanningResult,
        personality: PetPersonality,
        context: PetBehaviorContext,
        capabilities: PetActionCapabilities,
        wanderTarget: SpatialContext
    ) -> PetIntent? {
        guard result.isValid else { return nil }
        let blendedEnergy = clamp(
            result.energy * 0.50
                + personality.energy * 0.25
                + context.arousal * 0.25)
        let intent: PetIntent
        switch result.action {
        case .none:
            return nil
        case .react:
            intent = PetIntent(
                petId: petId,
                action: .react,
                target: nil,
                emotion: context.mood.rawValue,
                priority: 11,
                duration: 0.7 + blendedEnergy * 0.7,
                intensity: 0.25 + blendedEnergy * 0.70,
                interruptPolicy: .preserve)
        case .wander:
            intent = PetIntent(
                petId: petId,
                action: .wander,
                target: wanderTarget,
                emotion: context.mood.rawValue,
                priority: 11,
                duration: 2.5 + blendedEnergy * 3,
                intensity: 0.20 + blendedEnergy * 0.60,
                interruptPolicy: .preserve)
        }
        return supportedIntent(intent, capabilities: capabilities)
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
