import Foundation

struct PetMotionPromptOptimization: Codable, Equatable, Sendable {
    let optimizedPrompt: String
    let petDescription: String
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case optimizedPrompt = "optimized_prompt"
        case petDescription = "pet_description"
        case warnings
    }
}

enum MotionWorkflowState: Equatable {
    case idle
    case preparingReference
    case optimizing
    case optimized
    case submittingVideo
    case waitingForVideo(progress: Double?)
    case downloadingVideo
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparingReference, .optimizing, .submittingVideo, .waitingForVideo,
                .downloadingVideo, .installing:
            return true
        case .idle, .optimized, .failed:
            return false
        }
    }

    var displayName: String? {
        switch self {
        case .idle: return nil
        case .preparingReference: return "正在使用 Agnes Image 2.0 统一宠物参考图…"
        case .optimizing: return "正在识别宠物并优化提示词…"
        case .optimized: return "提示词已优化"
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
        baseURLString: OpenAIImageAPIConfiguration.defaultBaseURLString,
        promptModel: "gpt-5.6-sol",
        agnesBaseURLString: "https://apihub.agnes-ai.com/v1",
        imageModel: "agnes-image-2.0-flash",
        miniMaxBaseURLString: MiniMaxVideoAPIConfiguration.defaultBaseURLString,
        videoModel: "MiniMax-H3",
        seconds: 4,
        size: "1152x768")

    var baseURLString: String
    var promptModel: String
    /// Optional so configurations saved before the Agnes media stage remain
    /// decodable. New configurations always use the official Agnes endpoint.
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
        baseURLString: String,
        promptModel: String,
        agnesBaseURLString: String? = nil,
        imageModel: String? = nil,
        miniMaxBaseURLString: String? = nil,
        videoModel: String,
        seconds: Int,
        size: String
    ) {
        self.baseURLString = baseURLString
        self.promptModel = promptModel
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

    func validatedPromptAPIConfiguration() throws -> OpenAIImageAPIConfiguration {
        try OpenAIImageAPIConfiguration(baseURLString: baseURLString)
    }

    func validatedAgnesAPIConfiguration() throws -> OpenAIImageAPIConfiguration {
        try OpenAIImageAPIConfiguration(baseURLString: resolvedAgnesBaseURLString)
    }

    func validatedMiniMaxAPIConfiguration() throws -> MiniMaxVideoAPIConfiguration {
        try MiniMaxVideoAPIConfiguration(baseURLString: resolvedMiniMaxBaseURLString)
    }

    func validated() throws -> MotionServiceConfiguration {
        _ = try validatedPromptAPIConfiguration()
        let agnesConfiguration = try validatedAgnesAPIConfiguration()
        let miniMaxConfiguration = try validatedMiniMaxAPIConfiguration()
        guard !promptModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              imageModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
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
        case .missingModel: return "请填写提示词、参考图和视频模型名称"
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
