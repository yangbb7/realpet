import Foundation

enum LocalBehaviorPlannerConfigurationError: LocalizedError, Equatable {
    case missingModel
    case invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "请选择一个已安装的 Ollama 行为模型"
        case .invalidEndpoint:
            return "Ollama 地址必须是本机回环地址"
        }
    }
}

struct LocalBehaviorPlannerConfiguration: Codable, Equatable, Sendable {
    static let disabled = try! LocalBehaviorPlannerConfiguration(
        isEnabled: false,
        endpoint: LocalVLMConfiguration.defaultEndpoint,
        modelName: nil)

    let isEnabled: Bool
    let endpoint: String
    let modelName: String?

    init(isEnabled: Bool, endpoint: String, modelName: String?) throws {
        let input = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: input),
              let normalized = try? OllamaEndpoint.validated(url) else {
            throw LocalBehaviorPlannerConfigurationError.invalidEndpoint
        }
        let normalizedModel = modelName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isEnabled && normalizedModel?.isEmpty != false {
            throw LocalBehaviorPlannerConfigurationError.missingModel
        }
        self.isEnabled = isEnabled
        self.endpoint = normalized.absoluteString
        self.modelName = normalizedModel?.isEmpty == false ? normalizedModel : nil
    }

    var endpointURL: URL { URL(string: endpoint)! }
}

enum LocalBehaviorPlannerConfigurationStore {
    private static let key = "LocalBehaviorPlannerConfiguration"

    static func load(
        defaults: UserDefaults = .standard
    ) -> LocalBehaviorPlannerConfiguration {
        guard let data = defaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(
                LocalBehaviorPlannerConfiguration.self, from: data),
              let validated = try? LocalBehaviorPlannerConfiguration(
                isEnabled: configuration.isEnabled,
                endpoint: configuration.endpoint,
                modelName: configuration.modelName) else {
            return .disabled
        }
        return validated
    }

    static func save(
        _ configuration: LocalBehaviorPlannerConfiguration,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}

enum LocalBehaviorPlannerRuntimeState: Equatable, Sendable {
    case disabled
    case ready(String)
    case planning(String)
    case failed(String)
}
