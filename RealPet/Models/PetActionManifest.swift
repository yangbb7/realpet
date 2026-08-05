import Foundation

enum PetAnimationCue: String, Codable, Hashable, Sendable {
    case cry
    case angryStomp = "angry_stomp"
    case roll
    case stretch
    case sleepSnore = "sleep_snore"
    case wave
    case jumpCheer = "jump_cheer"
    case puzzledTilt = "puzzled_tilt"
    case cuddle
    case startledRetreat = "startled_retreat"
    case patrolRun = "patrol_run"
    // Legacy cues remain decodable for pets created before the fixed action kit.
    case react
    case shakeHead = "shake_head"
    case play
    case lieDown = "lie_down"
    case paw
    case eat
}

/// Single source of truth for direct desktop interactions. The behavior layer
/// emits these cues and the runtime only plays the cue it receives.
enum PetInteractionBinding {
    static let cueByInteraction: [String: PetAnimationCue] = [
        "user.pet.tap": .lieDown,
        "user.pet.file_drop.body": .paw,
        "user.pet.file_drop.head": .eat,
    ]

    static let fallbackReactionPriority: [PetAnimationCue] = [
        .cuddle, .wave, .jumpCheer, .cry, .stretch, .roll,
        .lieDown, .paw, .eat,
    ]

    static func cue(for interactionKind: String) -> PetAnimationCue? {
        cueByInteraction[interactionKind]
    }
}

struct PetActionCapabilities: Codable, Equatable, Sendable {
    var locomotion: Bool
    var reaction: Bool
    var orientation: Bool

    static let idleOnly = PetActionCapabilities(
        locomotion: false, reaction: false, orientation: false)
}

struct PetActionManifest: Codable, Equatable, Sendable {
    struct Action: Codable, Equatable, Sendable {
        enum Origin: String, Codable, CaseIterable, Hashable, Sendable {
            /// Frames extracted from footage supplied by the pet owner.
            case captured
            /// Frames created by an explicitly requested image/video generation job.
            case generated

            var displayName: String {
                switch self {
                case .captured: return "实拍"
                case .generated: return "AI 生成"
                }
            }
        }

        enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
            case idle
            case walk
            case run
            case react
            case shakeHead = "shake_head"
            case sit
            case sleep
            case play
            case lieDown = "lie_down"
            case paw
            case eat
            case gazeLeft = "gaze_left"
            case gazeRight = "gaze_right"
            case gazeUp = "gaze_up"
            case gazeDown = "gaze_down"
            case gazeOrbit = "gaze_orbit"
            case cry
            case angryStomp = "angry_stomp"
            case roll
            case stretch
            case sleepSnore = "sleep_snore"
            case wave
            case jumpCheer = "jump_cheer"
            case puzzledTilt = "puzzled_tilt"
            case cuddle
            case startledRetreat = "startled_retreat"
            case patrolRun = "patrol_run"
            case custom

            var displayName: String {
                switch self {
                case .idle: return "待机"
                case .walk: return "走路"
                case .run: return "奔跑"
                case .react: return "互动"
                case .shakeHead: return "摇头"
                case .sit: return "坐下"
                case .sleep: return "睡觉"
                case .play: return "玩耍"
                case .lieDown: return "躺倒"
                case .paw: return "扒拉"
                case .eat: return "吃下"
                case .gazeLeft: return "注视左侧"
                case .gazeRight: return "注视右侧"
                case .gazeUp: return "注视上方"
                case .gazeDown: return "注视下方"
                case .gazeOrbit: return "头眼注视帧库"
                case .cry: return "委屈哭泣"
                case .angryStomp: return "生气跺脚"
                case .roll: return "满地打滚"
                case .stretch: return "伸懒腰"
                case .sleepSnore: return "睡觉打呼噜"
                case .wave: return "招手拜拜"
                case .jumpCheer: return "跳跃欢呼"
                case .puzzledTilt: return "疑惑歪头"
                case .cuddle: return "撒娇求贴贴"
                case .startledRetreat: return "惊吓后退"
                case .patrolRun: return "奔跑巡逻"
                case .custom: return "自定义动作"
                }
            }

            var symbolName: String {
                switch self {
                case .walk: return "figure.walk.motion"
                case .run: return "figure.run"
                case .react, .play: return "sparkles"
                case .shakeHead: return "arrow.left.and.right"
                case .sleep: return "moon.zzz"
                case .sit, .idle: return "figure.stand"
                case .lieDown: return "figure.fall"
                case .paw: return "hand.draw"
                case .eat: return "mouth"
                case .gazeLeft: return "arrow.left"
                case .gazeRight: return "arrow.right"
                case .gazeUp: return "arrow.up"
                case .gazeDown: return "arrow.down"
                case .gazeOrbit: return "eye"
                case .cry: return "cloud.rain"
                case .angryStomp: return "flame"
                case .roll: return "arrow.triangle.2.circlepath"
                case .stretch: return "figure.flexibility"
                case .sleepSnore: return "moon.zzz"
                case .wave: return "hand.wave"
                case .jumpCheer: return "figure.jump"
                case .puzzledTilt: return "questionmark.circle"
                case .cuddle: return "heart"
                case .startledRetreat: return "exclamationmark.triangle"
                case .patrolRun: return "figure.run"
                case .custom: return "video"
                }
            }

            var translatesWindow: Bool {
                self == .walk || self == .run
            }

            static let gazeCapture: [Kind] = [
                .gazeLeft, .gazeRight, .gazeUp, .gazeDown,
            ]

            static let requiredResponseCapture: [Kind] = [
                .lieDown, .paw, .eat,
            ]

            static let fixedTapActions: [Kind] = [
                .lieDown, .paw, .eat, .cry, .angryStomp, .roll, .stretch,
                .sleepSnore, .wave, .jumpCheer, .cuddle,
            ]

            static let fixedActionKinds: [Kind] = [.gazeOrbit] + fixedTapActions

            var isFixedAction: Bool {
                Self.fixedActionKinds.contains(self)
            }

            static func gazeAction(
                horizontalOffset: Double,
                verticalOffset: Double,
                deadZone: Double = 0.16
            ) -> Kind? {
                let horizontal = min(1, max(-1, horizontalOffset))
                let vertical = min(1, max(-1, verticalOffset))
                guard max(abs(horizontal), abs(vertical)) >= deadZone else {
                    return nil
                }
                if abs(horizontal) >= abs(vertical) {
                    return horizontal < 0 ? .gazeLeft : .gazeRight
                }
                return vertical < 0 ? .gazeDown : .gazeUp
            }
        }

        let id: String
        let kind: Kind
        /// User-facing name for a captured custom action. Fixed actions retain
        /// their catalog names when this is absent.
        let displayNameOverride: String?
        let framesDirectory: String
        let fps: Int
        let loop: Bool
        let translatesWindow: Bool
        /// Nil is treated as `captured` so previously saved manifests remain valid.
        let origin: Origin?
        /// Present only for v2 action assets. The original media is preserved
        /// separately from runtime presentation caches.
        let sourceMedia: PetActionSourceMedia?
        /// Present only for v2 action assets. Older assets use integer FPS.
        let timelinePath: String?
        let presentationVariantVersion: Int?

        var effectiveOrigin: Origin { origin ?? .captured }

        init(
            id: String,
            kind: Kind,
            displayNameOverride: String? = nil,
            framesDirectory: String,
            fps: Int,
            loop: Bool,
            translatesWindow: Bool,
            origin: Origin? = nil,
            sourceMedia: PetActionSourceMedia? = nil,
            timelinePath: String? = nil,
            presentationVariantVersion: Int? = nil
        ) {
            self.id = id
            self.kind = kind
            self.displayNameOverride = displayNameOverride
            self.framesDirectory = framesDirectory
            self.fps = fps
            self.loop = loop
            self.translatesWindow = translatesWindow
            self.origin = origin
            self.sourceMedia = sourceMedia
            self.timelinePath = timelinePath
            self.presentationVariantVersion = presentationVariantVersion
        }

        var displayName: String {
            let name = displayNameOverride?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? kind.displayName : name
        }

        var isCustom: Bool { kind == .custom }
    }

    static let currentVersion = 2
    private static let supportedVersions: Set<Int> = [1, currentVersion]

    let version: Int
    let defaultAction: String
    let actions: [Action]

    init(
        version: Int,
        defaultAction: String,
        actions: [Action]
    ) {
        self.version = version
        self.defaultAction = defaultAction
        self.actions = actions
    }

    var capabilities: PetActionCapabilities {
        let installedKinds = Set(actions.map(\.kind))
        return PetActionCapabilities(
            locomotion: actions.contains {
                ($0.kind == .walk || $0.kind == .run)
                    && $0.translatesWindow
            },
            reaction: actions.contains {
                Action.Kind.fixedTapActions.contains($0.kind)
            },
            orientation: installedKinds.contains(.gazeOrbit)
                || Action.Kind.gazeCapture.allSatisfy(installedKinds.contains))
    }

    var missingFidelityResponseKinds: [Action.Kind] {
        let capturedKinds = Set(actions.compactMap { action -> Action.Kind? in
            action.effectiveOrigin == .captured ? action.kind : nil
        })
        return (Action.Kind.gazeCapture + Action.Kind.requiredResponseCapture)
            .filter { !capturedKinds.contains($0) }
    }

    var isFidelityResponsePackReady: Bool {
        missingFidelityResponseKinds.isEmpty
    }

    static func load(framesDirectory: String) -> PetActionManifest? {
        let url = URL(fileURLWithPath: framesDirectory)
            .appendingPathComponent("actions.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              supportedVersions.contains(manifest.version),
              manifest.actions.contains(where: { $0.id == manifest.defaultAction }) else {
            return nil
        }
        return manifest
    }

    static func registering(
        kind: Action.Kind,
        relativeFramesDirectory: String,
        fps: Int,
        origin: Action.Origin = .captured,
        actionID: String? = nil,
        displayNameOverride: String? = nil,
        sourceMedia: PetActionSourceMedia? = nil,
        timelinePath: String? = nil,
        in existing: PetActionManifest?
    ) -> PetActionManifest {
        let idle = Action(
            id: "idle", kind: .idle, framesDirectory: ".",
            fps: fps, loop: true, translatesWindow: false)
        var actions = existing?.actions ?? [idle]
        if !actions.contains(where: { $0.id == "idle" }) {
            actions.insert(idle, at: 0)
        }
        let action = Action(
            id: actionID ?? kind.rawValue,
            kind: kind,
            displayNameOverride: displayNameOverride,
            framesDirectory: relativeFramesDirectory,
            fps: fps,
            loop: kind == .idle,
            translatesWindow: kind.translatesWindow,
            origin: origin,
            sourceMedia: sourceMedia,
            timelinePath: timelinePath,
            presentationVariantVersion: sourceMedia == nil && timelinePath == nil ? nil : 1)
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        return PetActionManifest(
            version: currentVersion,
            defaultAction: existing?.defaultAction ?? "idle",
            actions: actions)
    }

    func save(framesDirectory: String) throws {
        let url = URL(fileURLWithPath: framesDirectory)
            .appendingPathComponent("actions.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
