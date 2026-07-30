import Foundation

enum LocalVLMConfigurationError: LocalizedError, Equatable {
    case missingModel
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "请选择一个已安装的 Ollama 视觉模型"
        case .invalidEndpoint:
            return "Ollama 地址必须是本机回环地址"
        }
    }
}

struct LocalVLMConfiguration: Codable, Equatable, Sendable {
    static let defaultEndpoint = "http://127.0.0.1:11434"
    static let disabled = try! LocalVLMConfiguration(
        isEnabled: false,
        endpoint: defaultEndpoint,
        modelName: nil)

    let isEnabled: Bool
    let endpoint: String
    let modelName: String?

    init(isEnabled: Bool, endpoint: String, modelName: String?) throws {
        let input = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: input),
              let normalized = try? OllamaEndpoint.validated(url) else {
            throw LocalVLMConfigurationError.invalidEndpoint
        }
        let normalizedModel = modelName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isEnabled && normalizedModel?.isEmpty != false {
            throw LocalVLMConfigurationError.missingModel
        }
        self.isEnabled = isEnabled
        self.endpoint = normalized.absoluteString
        self.modelName = normalizedModel?.isEmpty == false ? normalizedModel : nil
    }

    var endpointURL: URL {
        URL(string: endpoint)!
    }
}

enum LocalVLMConfigurationStore {
    private static let key = "LocalVLMConfiguration"

    static func load(defaults: UserDefaults = .standard) -> LocalVLMConfiguration {
        guard let data = defaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(
                LocalVLMConfiguration.self, from: data),
              let validated = try? LocalVLMConfiguration(
                isEnabled: configuration.isEnabled,
                endpoint: configuration.endpoint,
                modelName: configuration.modelName) else {
            return .disabled
        }
        return validated
    }

    static func save(
        _ configuration: LocalVLMConfiguration,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}

enum LocalVLMRuntimeState: Equatable, Sendable {
    case disabled
    case ready(String)
    case inferencing(String)
    case failed(String)
}
