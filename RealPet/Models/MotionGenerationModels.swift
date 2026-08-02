import Foundation

enum GeneratedMotionProcessingPolicy {
    /// White studio backgrounds are intentional for generated motion. Keep
    /// pet detection, segmentation, and identity validation, but do not apply
    /// the recorded-footage exposure gate to these clips.
    static func bypassesRecordedFootageQualityGate(
        actionOrigin: PetActionManifest.Action.Origin?,
        isInitialGeneratedPet: Bool
    ) -> Bool {
        actionOrigin == .generated || isInitialGeneratedPet
    }
}

enum PetImageLibraryPolicy {
    static let maximumImageCount = 4

    static func accepts(existingCount: Int, incomingCount: Int) -> Bool {
        incomingCount > 0
            && existingCount >= 0
            && existingCount + incomingCount <= maximumImageCount
    }

    static func normalizedReferenceCount(_ count: Int) -> Int {
        min(max(count, 1), maximumImageCount)
    }
}

enum MotionVideoProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case agnes
    case miniMaxH3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agnes: return "Agnes Video V2.0"
        case .miniMaxH3: return "MiniMax H3"
        }
    }

    var modelName: String {
        switch self {
        case .agnes: return "agnes-video-v2.0"
        case .miniMaxH3: return "MiniMax-H3"
        }
    }
}

/// Agnes is a product-owned direct integration. The release pipeline injects
/// its credential into the app bundle. It intentionally has no Keychain
/// fallback, so all installations use the same bundled China-site credential.
enum BundledAgnesVideoService {
    /// Agnes China official API gateway. The URL is product-owned and never
    /// comes from the desktop settings UI.
    static let baseURLString = "https://api.agnes-ai.cn/v1"
    static let modelName = "agnes-video-v2.0"
    static let size = "1152x768"
    private static let apiKeyInfoKey = "RealPetAgnesAPIKey"

    static func apiKey(bundle: Bundle = .main) throws -> String {
        let bundledValue = bundle.object(forInfoDictionaryKey: apiKeyInfoKey) as? String
        let bundledKey = bundledValue?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        guard !bundledKey.isEmpty else {
            throw AgnesVideoGenerationError.invalidAPIKey
        }
        return bundledKey
    }
}

/// The complete user-facing motion surface. No free-form prompts or action
/// types are accepted outside this catalog, which keeps generation, storage,
/// and desktop playback on one verifiable contract.
enum FixedPetAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case headFollow = "head_follow"
    case lieDown = "lie_down"
    case paw
    case eat
    case cry
    case angryStomp = "angry_stomp"
    case roll
    case stretch
    case sleepSnore = "sleep_snore"
    case wave
    case jumpCheer = "jump_cheer"
    case cuddle

    var id: String { rawValue }

    var kind: PetActionManifest.Action.Kind {
        switch self {
        // Preserve the existing on-disk kind so current head-gaze packs remain usable.
        case .headFollow: return .gazeOrbit
        case .lieDown: return .lieDown
        case .paw: return .paw
        case .eat: return .eat
        case .cry: return .cry
        case .angryStomp: return .angryStomp
        case .roll: return .roll
        case .stretch: return .stretch
        case .sleepSnore: return .sleepSnore
        case .wave: return .wave
        case .jumpCheer: return .jumpCheer
        case .cuddle: return .cuddle
        }
    }

    var displayName: String {
        switch self {
        case .headFollow: return "头部跟随"
        case .lieDown: return "躺倒撒娇"
        case .paw: return "爪子扒拉"
        case .eat: return "张嘴吃下"
        case .cry: return "委屈哭泣"
        case .angryStomp: return "生气跺脚"
        case .roll: return "满地打滚"
        case .stretch: return "伸懒腰"
        case .sleepSnore: return "睡觉打呼噜"
        case .wave: return "招手拜拜"
        case .jumpCheer: return "跳跃欢呼"
        case .cuddle: return "撒娇求贴贴"
        }
    }

    var symbolName: String {
        switch self {
        case .headFollow: return "eye"
        case .lieDown: return "figure.play"
        case .paw: return "pawprint"
        case .eat: return "mouth"
        case .cry: return "cloud.rain"
        case .angryStomp: return "flame"
        case .roll: return "arrow.triangle.2.circlepath"
        case .stretch: return "figure.flexibility"
        case .sleepSnore: return "moon.zzz"
        case .wave: return "hand.wave"
        case .jumpCheer: return "figure.jump"
        case .cuddle: return "heart"
        }
    }

    var requiresExistingBaseFrames: Bool { self != .headFollow }
    var minimumVideoSeconds: Int { 4 }

    static let tapActions: [FixedPetAction] = [
        .lieDown, .paw, .eat, .cry, .angryStomp, .roll, .stretch,
        .sleepSnore, .wave, .jumpCheer, .cuddle,
    ]

    static func action(for kind: PetActionManifest.Action.Kind) -> FixedPetAction? {
        allCases.first { $0.kind == kind }
    }

    var prompt: String {
        prompt(referenceImageCount: 1, provider: .miniMaxH3)
    }

    func prompt(
        referenceImageCount: Int,
        provider: MotionVideoProvider
    ) -> String {
        let count = PetImageLibraryPolicy.normalizedReferenceCount(referenceImageCount)
        let identityConstraint: String
        switch provider {
        case .agnes:
            identityConstraint = "以第一张上传的宠物照片为唯一主参考图，严格保持同一只宠物的毛色、花纹、脸型、眼睛、耳朵和体型一致。"
        case .miniMaxH3:
            switch count {
            case 1:
                identityConstraint = "仅使用这 1 张宠物素材图锁定外观，必须始终是同一只宠物。"
            case 2:
                identityConstraint = "综合这 2 张宠物素材图交叉校验毛色、花纹、脸型、眼睛、耳朵和体型，必须始终是同一只宠物。"
            case 3:
                identityConstraint = "综合这 3 张宠物素材图完整锁定毛色、花纹、脸型、眼睛、耳朵和体型，必须始终是同一只宠物。"
            default:
                identityConstraint = "综合全部 4 张宠物素材图严格锁定毛色、花纹、脸型、眼睛、耳朵和体型，必须始终是同一只宠物。"
            }
        }

        let motion: String
        switch self {
        case .headFollow:
            motion = "主体安静端坐正对镜头，身体、四肢和尾巴完全静止；只有头部和双眼极度平滑地顺时针依次注视上方、右侧、下方、左侧并回到正前方。固定机位，无身体转动、移动或镜头运动。"
        case .lieDown:
            motion = "角色正对镜头自然站立，缓慢躺倒露出放松撒娇姿态，四肢自然收拢，短暂停留后平稳回到初始站姿。固定机位，动作完整可见。"
        case .paw:
            motion = "角色正对镜头自然站立，仅抬起一只前爪在身前连续轻轻扒拉两次，头部专注看着爪子，随后回到初始站姿。固定机位。"
        case .eat:
            motion = "角色正对镜头自然站立，抬头张嘴做出吞下一小块食物的自然动作，轻微咀嚼后闭嘴并回到初始站姿。固定机位。"
        case .cry:
            motion = "角色坐在地上，双手（或前肢）揉眼睛，身体微微抽泣颤抖，头部低垂，表现出非常委屈、伤心哭泣的样子，动作惹人怜爱"
        case .angryStomp:
            motion = "角色双手叉腰（或前肢撑地），气呼呼地看着镜头，连续用力跺脚，身体微微前倾，头部快速晃动，表现出非常生气的状态"
        case .roll:
            motion = "角色躺在地上，左右来回连续翻滚，四肢在空中挥舞，动作流畅自然，带有强烈的趣味性和物理惯性"
        case .stretch:
            motion = "角色站在原地，双手（或前肢）用力向上伸展，身体向后拉伸拉长，然后伴随着深呼吸慢慢放松恢复原状，动作慵懒舒适"
        case .sleepSnore:
            motion = "角色趴在地上闭着眼睛熟睡，身体随着呼吸有节奏地平缓起伏，头部轻轻点地，呈现出香甜睡觉打呼噜的姿态"
        case .wave:
            motion = "角色面朝镜头站立，面带微笑，举起一只手（或前肢）左右欢快地摇晃挥舞，做出打招呼或说再见的连贯动作"
        case .jumpCheer:
            motion = "角色非常激动，原地连续向上蹦跳，双手（或前肢）高高举起欢呼，落地时有自然的缓冲，动作充满活力与开心"
        case .cuddle:
            motion = "角色身体向前倾靠，双手（或前肢）向前伸出做拥抱状，头部微微上仰看着镜头，左右轻轻扭动身体，表现出撒娇的姿态"
        }
        return "\(identityConstraint) \(motion)"
    }
}

enum MotionWorkflowState: Equatable {
    case idle
    case preparingReference
    case submittingVideo(provider: MotionVideoProvider)
    case waitingForVideo(provider: MotionVideoProvider, progress: Double?)
    case downloadingVideo
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparingReference, .submittingVideo, .waitingForVideo,
                .downloadingVideo, .installing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var displayName: String? {
        switch self {
        case .idle: return nil
        case .preparingReference: return "正在准备云端宠物参考图…"
        case .submittingVideo(let provider):
            return "正在提交 \(provider.displayName) 任务…"
        case .waitingForVideo(let provider, let progress):
            guard let progress else { return "\(provider.displayName) 正在生成动作…" }
            return String(format: "\(provider.displayName) 正在生成动作 %.0f%%…", progress * 100)
        case .downloadingVideo: return "正在下载生成动作…"
        case .installing: return "正在校验并安装生成动作…"
        case .failed(let message): return message
        }
    }
}

struct MotionServiceConfiguration: Codable, Equatable, Sendable {
    static let defaultValue = MotionServiceConfiguration(
        provider: .agnes,
        agnesBaseURLString: BundledAgnesVideoService.baseURLString,
        miniMaxBaseURLString: MiniMaxVideoAPIConfiguration.defaultBaseURLString,
        videoModel: BundledAgnesVideoService.modelName,
        seconds: 4,
        size: "1152x768")

    var provider: MotionVideoProvider
    var agnesBaseURLString: String? = nil
    var miniMaxBaseURLString: String? = nil
    var videoModel: String
    var seconds: Int
    var size: String

    init(
        provider: MotionVideoProvider = .agnes,
        agnesBaseURLString: String? = nil,
        miniMaxBaseURLString: String? = nil,
        videoModel: String,
        seconds: Int,
        size: String
    ) {
        self.provider = provider
        self.agnesBaseURLString = agnesBaseURLString
        self.miniMaxBaseURLString = miniMaxBaseURLString
        self.videoModel = videoModel
        self.seconds = seconds
        self.size = size
    }

    var resolvedAgnesBaseURLString: String {
        BundledAgnesVideoService.baseURLString
    }

    var resolvedMiniMaxBaseURLString: String {
        miniMaxBaseURLString ?? MiniMaxVideoAPIConfiguration.defaultBaseURLString
    }

    func validatedAgnesAPIConfiguration() throws -> OpenAIImageAPIConfiguration {
        try OpenAIImageAPIConfiguration(baseURLString: resolvedAgnesBaseURLString)
    }

    func validated() throws -> MotionServiceConfiguration {
        switch provider {
        case .agnes:
            let agnesConfiguration = try validatedAgnesAPIConfiguration()
            guard agnesConfiguration.isAgnesAPI else {
                throw MotionServiceConfigurationError.invalidAgnesAPI
            }
            guard (4...18).contains(seconds) else {
                throw MotionServiceConfigurationError.invalidAgnesDuration
            }
            guard videoModel == MotionVideoProvider.agnes.modelName else {
                throw MotionServiceConfigurationError.invalidVideoModel
            }
            guard AgnesVideoGenerationRequestSettings(size: size, seconds: seconds) != nil else {
                throw MotionServiceConfigurationError.invalidSize
            }
        case .miniMaxH3:
            let miniMaxConfiguration = try MiniMaxVideoAPIConfiguration(
                baseURLString: resolvedMiniMaxBaseURLString)
            guard miniMaxConfiguration.isOfficialAPI else {
                throw MotionServiceConfigurationError.invalidMiniMaxAPI
            }
            guard (4...15).contains(seconds) else {
                throw MotionServiceConfigurationError.invalidMiniMaxDuration
            }
            guard videoModel == MotionVideoProvider.miniMaxH3.modelName else {
                throw MotionServiceConfigurationError.invalidVideoModel
            }
        }
        return self
    }

    /// Configurations from older releases lacked an explicit provider. Infer it
    /// from their saved model rather than silently replacing MiniMax with Agnes.
    func migratedToSupportedProviders() -> MotionServiceConfiguration {
        var migrated = self
        if migrated.miniMaxBaseURLString == nil {
            migrated.miniMaxBaseURLString = MiniMaxVideoAPIConfiguration.defaultBaseURLString
        }
        if migrated.provider == .agnes {
            migrated.agnesBaseURLString = BundledAgnesVideoService.baseURLString
            migrated.videoModel = BundledAgnesVideoService.modelName
            migrated.seconds = min(max(migrated.seconds, 4), 18)
            migrated.size = BundledAgnesVideoService.size
        } else {
            migrated.videoModel = MotionVideoProvider.miniMaxH3.modelName
            migrated.seconds = min(max(migrated.seconds, 4), 15)
        }
        return migrated
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case agnesBaseURLString
        case miniMaxBaseURLString
        case videoModel
        case seconds
        case size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedModel = try container.decodeIfPresent(String.self, forKey: .videoModel)
        let savedProvider = try container.decodeIfPresent(
            MotionVideoProvider.self, forKey: .provider)
        provider = savedProvider ?? (savedModel == MotionVideoProvider.miniMaxH3.modelName
            ? .miniMaxH3 : .agnes)
        agnesBaseURLString = try container.decodeIfPresent(
            String.self, forKey: .agnesBaseURLString)
        miniMaxBaseURLString = try container.decodeIfPresent(
            String.self, forKey: .miniMaxBaseURLString)
        videoModel = savedModel ?? provider.modelName
        seconds = try container.decodeIfPresent(Int.self, forKey: .seconds) ?? 4
        size = try container.decodeIfPresent(String.self, forKey: .size) ?? "1152x768"
    }
}

enum MotionServiceConfigurationError: LocalizedError, Equatable {
    case invalidAgnesDuration
    case invalidMiniMaxDuration
    case invalidAgnesAPI
    case invalidMiniMaxAPI
    case invalidVideoModel
    case invalidSize

    var errorDescription: String? {
        switch self {
        case .invalidAgnesDuration: return "Agnes Video V2.0 视频时长仅支持 4 到 18 秒"
        case .invalidMiniMaxDuration: return "MiniMax H3 视频时长仅支持 4 到 15 秒"
        case .invalidAgnesAPI: return "视频模型必须使用 Agnes 官方 API"
        case .invalidMiniMaxAPI: return "视频模型必须使用 MiniMax 官方 API"
        case .invalidVideoModel: return "视频模型与当前提供商不匹配"
        case .invalidSize: return "视频尺寸必须为合法的宽x高，例如 1152x768"
        }
    }
}

enum MotionServiceConfigurationStore {
    private static let key = "motion-service-configuration-v1"

    static func load() -> MotionServiceConfiguration {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configuration = try? JSONDecoder().decode(
                MotionServiceConfiguration.self, from: data) else {
            return .defaultValue
        }
        let migrated = configuration.migratedToSupportedProviders()
        if migrated != configuration {
            save(migrated)
        }
        return migrated
    }

    static func save(_ configuration: MotionServiceConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
