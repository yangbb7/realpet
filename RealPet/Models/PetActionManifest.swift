import Foundation

enum PetAnimationCue: String, Codable, Hashable, Sendable {
    case react
    case shakeHead = "shake_head"
    case play
    case lieDown = "lie_down"
    case paw
    case eat
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

            static let defaultMouseInteraction: [Kind] = gazeCapture + [.play]

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
        let framesDirectory: String
        let fps: Int
        let loop: Bool
        let translatesWindow: Bool
        /// Nil is treated as `captured` so previously saved manifests remain valid.
        let origin: Origin?

        var effectiveOrigin: Origin { origin ?? .captured }

        init(
            id: String,
            kind: Kind,
            framesDirectory: String,
            fps: Int,
            loop: Bool,
            translatesWindow: Bool,
            origin: Origin? = nil
        ) {
            self.id = id
            self.kind = kind
            self.framesDirectory = framesDirectory
            self.fps = fps
            self.loop = loop
            self.translatesWindow = translatesWindow
            self.origin = origin
        }
    }

    static let currentVersion = 1

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
                ($0.kind == .react || $0.kind == .shakeHead || $0.kind == .play
                    || $0.kind == .lieDown || $0.kind == .paw || $0.kind == .eat)
            },
            orientation: Action.Kind.gazeCapture.allSatisfy(installedKinds.contains))
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

    func supports(animation: PetAnimationCue?) -> Bool {
        guard let animation else { return capabilities.reaction }
        let kind: Action.Kind
        switch animation {
        case .react: kind = .react
        case .shakeHead: kind = .shakeHead
        case .play: kind = .play
        case .lieDown: kind = .lieDown
        case .paw: kind = .paw
        case .eat: kind = .eat
        }
        return actions.contains {
            $0.kind == kind
        }
    }

    static func load(framesDirectory: String) -> PetActionManifest? {
        let url = URL(fileURLWithPath: framesDirectory)
            .appendingPathComponent("actions.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              manifest.version == currentVersion,
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
            id: kind.rawValue,
            kind: kind,
            framesDirectory: relativeFramesDirectory,
            fps: fps,
            loop: !([.react, .shakeHead, .play, .lieDown, .paw, .eat]
                + Action.Kind.gazeCapture).contains(kind),
            translatesWindow: kind.translatesWindow,
            origin: origin)
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
