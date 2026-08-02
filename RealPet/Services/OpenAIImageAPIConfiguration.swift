import Foundation

enum OpenAIImageAPIConfigurationError: LocalizedError, Equatable {
    case emptyURL
    case invalidURL
    case insecureURL

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "请输入 API Base URL"
        case .invalidURL:
            return "API Base URL 无效，请填写类似 https://api.openai.com/v1 的地址"
        case .insecureURL:
            return "中转站必须使用 HTTPS；仅 localhost 允许 HTTP"
        }
    }
}

struct OpenAIImageAPIConfiguration: Equatable, Sendable {
    static let officialBaseURLString = "https://api.openai.com/v1"
    static let defaultBaseURLString = "https://api.braintech.icu/v1"
    static let official = try! OpenAIImageAPIConfiguration(
        baseURLString: officialBaseURLString)
    static let defaultRelay = try! OpenAIImageAPIConfiguration(
        baseURLString: defaultBaseURLString)

    let baseURL: URL

    init(baseURLString: String) throws {
        let input = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw OpenAIImageAPIConfigurationError.emptyURL
        }
        guard var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw OpenAIImageAPIConfigurationError.invalidURL
        }

        let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || localHosts.contains(host) else {
            throw OpenAIImageAPIConfigurationError.insecureURL
        }

        var pathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !pathComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            throw OpenAIImageAPIConfigurationError.invalidURL
        }

        // Accept a base URL or one of the OpenAI-compatible endpoints we use.
        if pathComponents.count >= 2,
           pathComponents[pathComponents.count - 2].lowercased() == "images",
           pathComponents[pathComponents.count - 1].lowercased() == "edits" {
            pathComponents.removeLast(2)
        } else if pathComponents.last?.lowercased() == "responses"
                    || pathComponents.last?.lowercased() == "videos" {
            pathComponents.removeLast()
        }

        components.scheme = scheme
        components.host = host
        components.path = pathComponents.isEmpty
            ? "" : "/" + pathComponents.joined(separator: "/")
        guard let normalizedURL = components.url else {
            throw OpenAIImageAPIConfigurationError.invalidURL
        }
        baseURL = normalizedURL
    }

    var imageEditsURL: URL {
        baseURL
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("edits", isDirectory: false)
    }

    var responsesURL: URL {
        baseURL.appendingPathComponent("responses", isDirectory: false)
    }

    var chatCompletionsURL: URL {
        baseURL
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("completions", isDirectory: false)
    }

    var videosURL: URL {
        baseURL.appendingPathComponent("videos", isDirectory: false)
    }

    var agnesVideoResultURL: URL {
        baseURL.deletingLastPathComponent().appendingPathComponent(
            "agnesapi", isDirectory: false)
    }

    var isAgnesAPI: Bool {
        baseURL.host?.lowercased() == "api.agnes-ai.cn"
    }

    var normalizedBaseURLString: String {
        baseURL.absoluteString
    }

    var isOfficial: Bool {
        self == Self.official
    }
}
