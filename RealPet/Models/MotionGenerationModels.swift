import Foundation

struct DefaultMotionActionPlan: Equatable, Sendable {
    let kind: PetActionManifest.Action.Kind
    let prompt: String
}

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

/// These prompt packages follow MiniMax H3's image-to-video formula: the
/// first-frame subject, one ordered motion, fixed camera, and visual direction.
/// They are read-only because their output is installed into runtime-owned slots.
enum DefaultMouseInteractionScenario: String, CaseIterable, Identifiable, Sendable {
    case pointerTracking
    case clickBounce

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pointerTracking: return "鼠标注视跟随"
        case .clickBounce: return "点击原地蹦跳"
        }
    }

    var symbolName: String {
        switch self {
        case .pointerTracking: return "eye"
        case .clickBounce: return "hand.tap"
        }
    }

    /// A full visual orbit needs enough time for usable intermediate frames.
    var minimumVideoSeconds: Int {
        switch self {
        case .pointerTracking: return 12
        case .clickBounce: return 4
        }
    }

    /// The 360-degree orbit can become the first source-frame pet. A bounce
    /// needs an existing base pet to play against.
    var canCreatePetFromPhotos: Bool {
        self == .pointerTracking
    }

    var actionPlans: [DefaultMotionActionPlan] {
        switch self {
        case .pointerTracking:
            return [
                .init(kind: .gazeOrbit, prompt: Self.gazeOrbitPrompt),
            ]
        case .clickBounce:
            return [
                .init(kind: .play, prompt: """
                首帧中的同一只宠物位于纯白无缝背景的平视全身中景中。先以自然站姿稳定停留，随后四肢协调地在原地轻快蹦跳两次，每次落点保持原位，耳朵、尾巴和毛发随身体产生自然惯性摆动，最后平稳落回初始站姿并短暂停留。镜头固定稳定，无推拉摇移、缩放或剪辑。真实摄影质感，自然动物解剖，柔和均匀的棚拍光线，轮廓干净，画面安静自然。
                """.trimmingCharacters(in: .whitespacesAndNewlines)),
            ]
        }
    }

    var debugPrompt: String {
        actionPlans.map { plan in
            "[\(plan.kind.displayName)]\n\(plan.prompt)"
        }.joined(separator: "\n\n")
    }

    private static let gazeOrbitPrompt = """
    首帧中的同一只宠物位于纯白无缝背景的平视全身中景中，身体完整可见。先以面向镜头的自然站姿稳定停留，随后四爪始终保持在原地，以匀速、连续、自然的方式顺时针完整旋转 360 度，依次清晰经过正面、左前 45 度、左侧、左后 45 度、背面、右后 45 度、右侧、右前 45 度；每个方位短暂停留，耳朵、尾巴和毛发产生符合惯性的细微运动。最后回到面向镜头的初始方向，恢复与首帧一致的自然站姿并稳定停留。全程无跳帧、无姿态突变、无遮挡，所有方位身体完整且清晰可见。镜头固定稳定，无推拉、摇移、缩放、剪辑或视角变化。真实摄影质感，自然动物解剖，柔和均匀的棚拍光线，轮廓干净，画面安静自然。
    """.trimmingCharacters(in: .whitespacesAndNewlines)
}

enum MotionWorkflowState: Equatable {
    case idle
    case preparingReference
    case submittingVideo
    case waitingForVideo(progress: Double?)
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
        case .preparingReference: return "正在使用 Agnes Image 2.0 统一宠物参考图…"
        case .submittingVideo: return "正在提交 MiniMax H3 视频任务…"
        case .waitingForVideo(let progress):
            guard let progress else { return "MiniMax H3 正在生成动作…" }
            return String(format: "MiniMax H3 正在生成动作 %.0f%%…", progress * 100)
        case .downloadingVideo: return "正在下载生成动作…"
        case .installing: return "正在校验并安装生成动作…"
        case .failed(let message): return message
        }
    }
}

struct MotionServiceConfiguration: Codable, Equatable, Sendable {
    static let defaultValue = MotionServiceConfiguration(
        agnesBaseURLString: "https://apihub.agnes-ai.com/v1",
        imageModel: "agnes-image-2.0-flash",
        miniMaxBaseURLString: MiniMaxVideoAPIConfiguration.defaultBaseURLString,
        videoModel: "MiniMax-H3",
        seconds: 4,
        size: "1152x768")

    /// Optional so configurations saved before the direct-provider workflow
    /// remain decodable. New configurations always use the official endpoint.
    var agnesBaseURLString: String? = nil
    /// Optional so configurations saved before the Agnes reference stage remain
    /// decodable. Agnes generation requires this model.
    var imageModel: String? = nil
    /// Optional so saved Agnes-video configurations remain decodable. New
    /// configurations use the official MiniMax H3 video endpoint.
    var miniMaxBaseURLString: String? = nil
    var videoModel: String
    var seconds: Int
    var size: String

    init(
        agnesBaseURLString: String? = nil,
        imageModel: String? = nil,
        miniMaxBaseURLString: String? = nil,
        videoModel: String,
        seconds: Int,
        size: String
    ) {
        self.agnesBaseURLString = agnesBaseURLString
        self.imageModel = imageModel
        self.miniMaxBaseURLString = miniMaxBaseURLString
        self.videoModel = videoModel
        self.seconds = seconds
        self.size = size
    }

    var resolvedAgnesBaseURLString: String {
        agnesBaseURLString ?? "https://apihub.agnes-ai.com/v1"
    }

    var resolvedMiniMaxBaseURLString: String {
        miniMaxBaseURLString ?? MiniMaxVideoAPIConfiguration.defaultBaseURLString
    }

    func validatedAgnesAPIConfiguration() throws -> OpenAIImageAPIConfiguration {
        try OpenAIImageAPIConfiguration(baseURLString: resolvedAgnesBaseURLString)
    }

    func validatedMiniMaxAPIConfiguration() throws -> MiniMaxVideoAPIConfiguration {
        try MiniMaxVideoAPIConfiguration(baseURLString: resolvedMiniMaxBaseURLString)
    }

    func validated() throws -> MotionServiceConfiguration {
        let agnesConfiguration = try validatedAgnesAPIConfiguration()
        let miniMaxConfiguration = try validatedMiniMaxAPIConfiguration()
        guard imageModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              !videoModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MotionServiceConfigurationError.missingModel
        }
        guard (4...15).contains(seconds) else {
            throw MotionServiceConfigurationError.invalidDuration
        }
        guard agnesConfiguration.isAgnesAPI else {
            throw MotionServiceConfigurationError.invalidAgnesAPI
        }
        guard miniMaxConfiguration.isOfficialAPI else {
            throw MotionServiceConfigurationError.invalidMiniMaxAPI
        }
        guard videoModel == "MiniMax-H3" else {
            throw MotionServiceConfigurationError.invalidVideoModel
        }
        return self
    }

    func migratedToMiniMaxH3() -> MotionServiceConfiguration {
        var migrated = self
        if migrated.miniMaxBaseURLString == nil {
            migrated.miniMaxBaseURLString = MiniMaxVideoAPIConfiguration.defaultBaseURLString
        }
        migrated.videoModel = "MiniMax-H3"
        return migrated
    }
}

enum MotionServiceConfigurationError: LocalizedError, Equatable {
    case missingModel
    case missingImageModel
    case invalidDuration
    case invalidAgnesAPI
    case invalidMiniMaxAPI
    case invalidVideoModel

    var errorDescription: String? {
        switch self {
        case .missingModel: return "请填写参考图和视频模型名称"
        case .missingImageModel: return "Agnes 图像链路需要填写参考图模型"
        case .invalidDuration: return "MiniMax H3 视频时长仅支持 4 到 15 秒"
        case .invalidAgnesAPI: return "参考图必须使用 Agnes 官方 API"
        case .invalidMiniMaxAPI: return "视频必须使用 MiniMax 官方 API"
        case .invalidVideoModel: return "视频模型必须为 MiniMax-H3"
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
        let migrated = configuration.migratedToMiniMaxH3()
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
