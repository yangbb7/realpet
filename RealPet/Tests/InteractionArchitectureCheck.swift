import Foundation

@main
struct InteractionArchitectureCheck {
    @MainActor
    static func main() throws {
        try testObservationContractRoundTrip()
        testInteractionHubDropsExpiredAndDuplicateEvents()
        testInteractionHubRejectsMalformedEvents()
        testPointerInteractionUsesFixedBinding()
        testFileDropUsesFixedActionSlots()
        testPettingGestureAndPolicy()
        testDirectorUsesInstalledActionCapabilities()
        try testIntentProducesVersionedCommand()
        print("Interaction architecture checks passed")
    }

    private static func testObservationContractRoundTrip() throws {
        let now = Date().timeIntervalSince1970
        let event = InteractionObservation(
            petId: UUID(), source: InteractionSource.pointer,
            kind: InteractionKind.petTapped, occurredAt: now,
            expiresAt: now + 1,
            spatial: SpatialContext(
                space: .petLocalNormalized, x: 0.4, y: 0.7),
            attributes: ["button": "primary"])

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(InteractionObservation.self, from: encoded)
        precondition(decoded == event)
        precondition(decoded.isFresh(at: now + 0.5))
        precondition(!decoded.isFresh(at: now + 2))
    }

    @MainActor
    private static func testInteractionHubDropsExpiredAndDuplicateEvents() {
        let hub = InteractionHub()
        let petId = UUID()
        var received = 0
        hub.addObserver { _, _ in received += 1 }

        let event = InteractionObservation(
            petId: petId, source: InteractionSource.pointer,
            kind: InteractionKind.pointerNear, occurredAt: 100, expiresAt: 105,
            confidence: 0.8,
            spatial: SpatialContext(space: .screenNormalized, x: 0.5, y: 0.4))
        hub.publish(event, now: 101)
        hub.publish(event, now: 101)
        precondition(received == 1)
        precondition(hub.state(for: petId).recentKinds == [InteractionKind.pointerNear])

        let stale = InteractionObservation(
            petId: petId, source: InteractionSource.pointer,
            kind: InteractionKind.pointerNear, occurredAt: 90, expiresAt: 91)
        hub.publish(stale, now: 101)
        precondition(received == 1)
    }

    @MainActor
    private static func testInteractionHubRejectsMalformedEvents() {
        let hub = InteractionHub()
        var received = 0
        hub.addObserver { _, _ in received += 1 }
        let invalid = InteractionObservation(
            petId: UUID(), source: InteractionSource.pointer,
            kind: InteractionKind.pointerNear,
            occurredAt: 100, expiresAt: 101, confidence: 1.5,
            spatial: SpatialContext(space: .screenNormalized, x: 1.2, y: 0.5))
        hub.publish(invalid, now: 100)
        precondition(received == 0)
    }

    private static func testPointerInteractionUsesFixedBinding() {
        let now: TimeInterval = 100
        let intent = PetBehaviorPolicy.intent(
            for: InteractionObservation(
                petId: UUID(), source: InteractionSource.pointer,
                kind: InteractionKind.petTapped,
                occurredAt: now, expiresAt: now + 1,
                spatial: SpatialContext(
                    space: .petLocalNormalized, x: 0.5, y: 0.5)),
            personality: .balanced,
            now: now)
        precondition(intent?.action == .react)
        precondition(intent?.animation == .lieDown)
        precondition(PetInteractionBinding.cue(for: InteractionKind.petTapped) == .lieDown)

        let gaze = PetBehaviorPolicy.intent(
            for: InteractionObservation(
                petId: UUID(), source: InteractionSource.pointer,
                kind: InteractionKind.pointerNear,
                occurredAt: now, expiresAt: now + 1,
                spatial: SpatialContext(
                    space: .screenNormalized, x: 0.9, y: 0.1)),
            personality: .balanced,
            now: now)
        precondition(gaze?.action == .orient)
    }

    private static func testFileDropUsesFixedActionSlots() {
        let now: TimeInterval = 100
        let petId = UUID()
        let body = InteractionObservation(
            petId: petId, source: InteractionSource.pointer,
            kind: InteractionKind.fileDroppedOnBody,
            occurredAt: now, expiresAt: now + 1)
        let head = InteractionObservation(
            petId: petId, source: InteractionSource.pointer,
            kind: InteractionKind.fileDroppedOnHead,
            occurredAt: now, expiresAt: now + 1)
        let bodyIntent = PetBehaviorPolicy.intent(
            for: body, personality: .balanced, now: now)
        let headIntent = PetBehaviorPolicy.intent(
            for: head, personality: .balanced, now: now)
        precondition(bodyIntent?.animation == .paw)
        precondition(headIntent?.animation == .eat)
        precondition(PetInteractionBinding.cue(for: body.kind) == .paw)
        precondition(PetInteractionBinding.cue(for: head.kind) == .eat)
    }

    private static func testPettingGestureAndPolicy() {
        var recognizer = PettingGestureRecognizer(
            minimumDistance: 20, maximumGap: 0.5, cooldown: 1)
        precondition(!recognizer.update(x: 0, y: 0, at: 100))
        precondition(!recognizer.update(x: 14, y: 0, at: 100.1))
        precondition(recognizer.update(x: 0, y: 0, at: 100.2))

        let intent = PetBehaviorPolicy.intent(
            for: InteractionObservation(
                petId: UUID(), source: InteractionSource.pointer,
                kind: InteractionKind.petPetted,
                occurredAt: 100, expiresAt: 101),
            personality: .balanced,
            now: 100)
        precondition(intent?.animation == .cuddle)
    }

    @MainActor
    private static func testDirectorUsesInstalledActionCapabilities() {
        var now: TimeInterval = 100
        let petId = UUID()
        let hub = InteractionHub()
        var commands: [PetCommand] = []
        let director = PetBehaviorDirector(
            hub: hub,
            startTimer: false,
            now: { now }
        ) { _, command in
            commands.append(command)
        }
        director.register(
            petId: petId,
            personality: .balanced,
            capabilities: PetActionCapabilities(
                locomotion: false, reaction: true, orientation: true))
        hub.publish(InteractionObservation(
            petId: petId, source: InteractionSource.pointer,
            kind: InteractionKind.petTapped,
            occurredAt: now, expiresAt: now + 1), now: now)
        precondition(commands.last?.action == .react)
        precondition(commands.last?.animation == .lieDown)

        now += 1
        hub.publish(InteractionObservation(
            petId: petId, source: InteractionSource.pointer,
            kind: InteractionKind.pointerNear,
            occurredAt: now, expiresAt: now + 1,
            spatial: SpatialContext(space: .screenNormalized, x: 0.7, y: 0.3)), now: now)
        precondition(commands.last?.action == .faceToward)
    }

    private static func testIntentProducesVersionedCommand() throws {
        let petId = UUID()
        let target = SpatialContext(space: .screenNormalized, x: 0.2, y: 0.8)
        let intent = PetBehaviorPolicy.autonomousWanderIntent(
            petId: petId, personality: .balanced, target: target)
        let command = PetCommand.executing(intent, now: 100)

        precondition(command.schemaVersion == 1)
        precondition(command.action == .moveTo)
        precondition(command.petId == petId)
        precondition(command.target == target)
        precondition(command.expiresAt > command.issuedAt)
        _ = try JSONEncoder().encode(command)
    }
}
