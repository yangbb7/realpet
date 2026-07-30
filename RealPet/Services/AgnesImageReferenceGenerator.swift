import Foundation

enum AgnesImageReferenceError: LocalizedError, Equatable {
    case invalidAPIKey
    case invalidReferenceImage
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Agnes API Key 无效"
        case .invalidReferenceImage: return "宠物参考图无法读取"
        case .invalidResponse: return "Agnes Image 没有返回可用于视频的参考图"
        case .requestFailed(let status, let message):
            return "Agnes Image 参考图生成失败（HTTP \(status)）：\(message)"
        }
    }
}

struct AgnesImageReferenceGenerator {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 360
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func generateReference(
        referenceImageURLs: [URL],
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String
    ) async throws -> URL {
        let request = try Self.makeRequest(
            referenceImageURLs: referenceImageURLs,
            apiKey: apiKey,
            configuration: configuration,
            model: model)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgnesImageReferenceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AgnesImageReferenceError.invalidAPIKey }
            throw AgnesImageReferenceError.requestFailed(
                status: http.statusCode,
                message: Self.apiErrorMessage(from: data) ?? "未知错误")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let images = json["data"] as? [[String: Any]],
              let value = images.first?["url"] as? String,
              let url = URL(string: value),
              url.scheme == "https" else {
            throw AgnesImageReferenceError.invalidResponse
        }
        return url
    }

    static func makeRequest(
        referenceImageURLs: [URL],
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String
    ) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgnesImageReferenceError.invalidAPIKey }
        guard !referenceImageURLs.isEmpty else {
            throw AgnesImageReferenceError.invalidReferenceImage
        }
        let images = try referenceImageURLs.prefix(6).map { url -> String in
            let image = try PetReferenceImageData.load(from: url)
            return "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
        }
        let payload: [String: Any] = [
            "model": model,
            "prompt": Self.referencePrompt,
            "size": "1024x1024",
            "extra_body": [
                "image": images,
                "response_format": "url",
            ],
        ]
        var request = URLRequest(url: configuration.baseURL
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("generations", isDirectory: false))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static let referencePrompt = """
    Use all supplied photos as identity references for one and only one pet.
    Create a single photorealistic full-body reference image of that exact pet:
    preserve its unique coat colors, markings, anatomy, face, eye color, ear
    shape, and proportions. The pet is centered, fully visible, standing in a
    neutral natural pose, with a pure white seamless background and a fixed
    eye-level camera. No humans, hands, accessories, text, watermark, other
    animals, floor detail, or props. This image will be used as the identity
    anchor for a short motion video.
    """

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        return json["message"] as? String
    }
}
