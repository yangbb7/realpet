import Foundation

enum MiniMaxVideoAPIConfigurationError: LocalizedError, Equatable {
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "MiniMax API Base URL 无效"
        }
    }
}

struct MiniMaxVideoAPIConfiguration: Equatable, Sendable {
    static let defaultBaseURLString = "https://api.minimaxi.com"

    let baseURL: URL

    init(baseURLString: String) throws {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host != nil else {
            throw MiniMaxVideoAPIConfigurationError.invalidBaseURL
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        // The documented server is the API origin. Accepting a copied endpoint
        // URL is useful in the settings UI, but requests must still start at
        // that origin rather than duplicate the V2 path.
        components.path = ""
        guard let normalized = components.url else {
            throw MiniMaxVideoAPIConfigurationError.invalidBaseURL
        }
        baseURL = normalized
    }

    var normalizedBaseURLString: String { baseURL.absoluteString }

    var isOfficialAPI: Bool {
        baseURL.host?.lowercased() == "api.minimaxi.com"
    }

    var createURL: URL {
        baseURL.appendingPathComponent("v2/video_generation")
    }

    func queryURL(taskID: String) -> URL {
        baseURL
            .appendingPathComponent("v2/query/video_generation")
            .appendingPathComponent(taskID)
    }
}
