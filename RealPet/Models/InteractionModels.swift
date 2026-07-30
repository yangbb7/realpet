import Foundation

enum InteractionSource {
    static let pointer = "pointer"
    static let cameraVision = "camera.vision"
    static let cameraVLM = "camera.vlm"
    static let speech = "speech"
    static let system = "system"
}

enum InteractionKind {
    static let pointerEntered = "pointer.entered"
    static let pointerExited = "pointer.exited"
    static let pointerNear = "pointer.near_pet"
    static let pointerApproachingFast = "pointer.approaching_fast"
    static let petTapped = "user.pet.tap"
    static let petDoubleTapped = "user.pet.double_tap"
    static let petPetted = "user.pet.petted"
    static let dragStarted = "user.pet.drag_start"
    static let dragEnded = "user.pet.drag_end"
    static let fileDroppedOnBody = "user.pet.file_drop.body"
    static let fileDroppedOnHead = "user.pet.file_drop.head"
    static let userWaves = "user.waves"
    static let userOffersObject = "user.offers_object"
    static let userLooksAtPet = "user.looks_at_pet"
    static let userApproachesPet = "user.approaches_pet"
    static let userAppears = "user.appears"
    static let userCallsPet = "user.calls_pet"
    static let userPraisesPet = "user.praises_pet"
    static let userInvitesPlay = "user.invites_play"
    static let userRequestsPause = "user.requests_pause"
    static let userRequestsResume = "user.requests_resume"

    static let multimodalAllowed: Set<String> = [
        userWaves,
        userOffersObject,
        userLooksAtPet,
        userApproachesPet,
        userAppears,
    ]

    static let speechAllowed: Set<String> = [
        userCallsPet,
        userPraisesPet,
        userInvitesPlay,
        userRequestsPause,
        userRequestsResume,
    ]

    static let behaviorPlanningAllowed: Set<String> = multimodalAllowed
        .union(speechAllowed)
        .union([
            pointerEntered,
            pointerExited,
            pointerNear,
            pointerApproachingFast,
            petTapped,
            petDoubleTapped,
            petPetted,
            dragStarted,
            dragEnded,
            fileDroppedOnBody,
            fileDroppedOnHead,
        ])
}

/// Recognizes a short horizontal back-and-forth stroke over a pet surface.
/// Renderers feed local pointer coordinates into this type, then publish the
/// shared `user.pet.petted` observation when it returns true.
struct PettingGestureRecognizer {
    let minimumDistance: Double
    let maximumGap: TimeInterval
    let cooldown: TimeInterval

    private var lastPoint: (x: Double, y: Double)?
    private var lastTime: TimeInterval?
    private var lastHorizontalDirection = 0
    private var distance = 0.0
    private var reversals = 0
    private var lastEmission = -Double.infinity

    init(
        minimumDistance: Double = 70,
        maximumGap: TimeInterval = 0.35,
        cooldown: TimeInterval = 1.2
    ) {
        self.minimumDistance = minimumDistance
        self.maximumGap = maximumGap
        self.cooldown = cooldown
    }

    mutating func reset() {
        lastPoint = nil
        lastTime = nil
        lastHorizontalDirection = 0
        distance = 0
        reversals = 0
    }

    mutating func update(
        x: Double,
        y: Double,
        at timestamp: TimeInterval
    ) -> Bool {
        let point = (x: x, y: y)
        guard let previousPoint = lastPoint,
              let previousTime = lastTime,
              timestamp >= previousTime,
              timestamp - previousTime <= maximumGap else {
            reset()
            lastPoint = point
            lastTime = timestamp
            return false
        }

        let dx = point.x - previousPoint.x
        let dy = point.y - previousPoint.y
        let segment = hypot(dx, dy)
        lastPoint = point
        lastTime = timestamp
        guard segment >= 1.5 else { return false }

        distance += segment
        if abs(dx) >= 3, abs(dx) >= abs(dy) * 0.65 {
            let direction = dx > 0 ? 1 : -1
            if lastHorizontalDirection != 0,
               direction != lastHorizontalDirection {
                reversals += 1
            }
            lastHorizontalDirection = direction
        }

        guard distance >= minimumDistance, reversals >= 1 else { return false }
        let canEmit = timestamp - lastEmission >= cooldown
        reset()
        lastPoint = point
        lastTime = timestamp
        if canEmit {
            lastEmission = timestamp
            return true
        }
        return false
    }
}

struct SpatialContext: Codable, Equatable, Sendable {
    enum Space: String, Codable, Sendable {
        case screenNormalized
        case petLocalNormalized
        case cameraNormalized
    }

    let space: Space
    let x: Double
    let y: Double
}

/// A short-lived reference to media retained by a sensor adapter. The protocol
/// carries a token and time range, never raw video bytes or an arbitrary path.
struct ObservationEvidence: Codable, Equatable, Sendable {
    let reference: String
    let mimeType: String
    let startedAt: TimeInterval
    let endedAt: TimeInterval
    let ephemeral: Bool
}

struct InteractionObservation: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let petId: UUID
    let source: String
    let kind: String
    let occurredAt: TimeInterval
    let expiresAt: TimeInterval
    let confidence: Double
    let actor: String?
    let target: String?
    let spatial: SpatialContext?
    let evidence: ObservationEvidence?
    let attributes: [String: String]

    init(
        id: UUID = UUID(),
        petId: UUID,
        source: String,
        kind: String,
        occurredAt: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval,
        confidence: Double = 1,
        actor: String? = "local_user",
        target: String? = "pet",
        spatial: SpatialContext? = nil,
        evidence: ObservationEvidence? = nil,
        attributes: [String: String] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.petId = petId
        self.source = source
        self.kind = kind
        self.occurredAt = occurredAt
        self.expiresAt = expiresAt
        self.confidence = confidence
        self.actor = actor
        self.target = target
        self.spatial = spatial
        self.evidence = evidence
        self.attributes = attributes
    }

    func isFresh(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        isValid
            && expiresAt >= now
    }

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              !source.isEmpty,
              !kind.isEmpty,
              occurredAt.isFinite,
              expiresAt.isFinite,
              expiresAt >= occurredAt,
              confidence.isFinite,
              confidence > 0,
              confidence <= 1 else { return false }
        if let spatial {
            guard spatial.x.isFinite,
                  spatial.y.isFinite,
                  (0...1).contains(spatial.x),
                  (0...1).contains(spatial.y) else { return false }
        }
        if let evidence {
            guard !evidence.reference.isEmpty,
                  !evidence.mimeType.isEmpty,
                  evidence.startedAt.isFinite,
                  evidence.endedAt.isFinite,
                  evidence.startedAt <= evidence.endedAt else { return false }
        }
        return true
    }
}

struct PetIntent: Equatable, Sendable {
    typealias Animation = PetAnimationCue

    enum Action: String, Sendable {
        case orient
        case approach
        case retreat
        case react
        case pause
        case resume
        case wander
    }

    enum InterruptPolicy: String, Sendable {
        case replace
        case queue
        case preserve
    }

    let petId: UUID
    let action: Action
    let target: SpatialContext?
    let emotion: String
    let priority: Int
    let duration: Double
    let intensity: Double
    let interruptPolicy: InterruptPolicy
    let animation: Animation?

    init(
        petId: UUID,
        action: Action,
        target: SpatialContext?,
        emotion: String,
        priority: Int,
        duration: Double,
        intensity: Double,
        interruptPolicy: InterruptPolicy,
        animation: Animation? = nil
    ) {
        self.petId = petId
        self.action = action
        self.target = target
        self.emotion = emotion
        self.priority = priority
        self.duration = duration
        self.intensity = intensity
        self.interruptPolicy = interruptPolicy
        self.animation = animation
    }
}

struct PetCommand: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    enum Action: String, Codable, Hashable, Sendable {
        case faceToward = "face_toward"
        case moveToward = "move_toward"
        case moveAway = "move_away"
        case moveTo = "move_to"
        case react
        case pause
        case resume
    }

    let schemaVersion: Int
    let id: UUID
    let petId: UUID
    let action: Action
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval
    let target: SpatialContext?
    let duration: Double
    let intensity: Double
    let animation: PetIntent.Animation?

    init(
        id: UUID = UUID(),
        petId: UUID,
        action: Action,
        issuedAt: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval,
        target: SpatialContext? = nil,
        duration: Double = 0,
        intensity: Double = 0.5,
        animation: PetIntent.Animation? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.petId = petId
        self.action = action
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.target = target
        self.duration = duration
        self.intensity = intensity
        self.animation = animation
    }

    static func executing(
        _ intent: PetIntent,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> PetCommand {
        let action: Action
        switch intent.action {
        case .orient: action = .faceToward
        case .approach: action = .moveToward
        case .retreat: action = .moveAway
        case .react: action = .react
        case .pause: action = .pause
        case .resume: action = .resume
        case .wander: action = .moveTo
        }
        return PetCommand(
            petId: intent.petId,
            action: action,
            issuedAt: now,
            expiresAt: now + max(1, intent.duration),
            target: intent.target,
            duration: intent.duration,
            intensity: intent.intensity,
            animation: intent.animation)
    }
}
