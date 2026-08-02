import Foundation

struct AgnesVideoGenerationRequestSettings: Equatable, Sendable {
    let width: Int
    let height: Int
    let numFrames: Int
    let frameRate: Int

    /// Agnes Video V2.0 requires an 8n + 1 frame count. At 24 fps this maps
    /// the app's four-second default to 97 frames (about 4.04 seconds).
    init?(size: String, seconds: Int, frameRate: Int = 24) {
        let components = size.lowercased().split(separator: "x")
        guard components.count == 2,
              let width = Int(components[0]), let height = Int(components[1]),
              width > 0, height > 0,
              (1...60).contains(frameRate) else { return nil }
        let requestedFrames = max(9, seconds * frameRate)
        let numFrames = ((requestedFrames - 1 + 7) / 8) * 8 + 1
        guard numFrames <= 441 else { return nil }
        self.width = width
        self.height = height
        self.numFrames = numFrames
        self.frameRate = frameRate
    }
}

struct AgnesVideoGenerationJob: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case queued
        case processing
        case completed
        case failed(String)
    }

    let id: String
    let status: Status
    let resultURL: URL?
    let progress: Double?
}

enum AgnesVideoGenerationError: LocalizedError, Equatable {
    case invalidAPIKey
    case invalidReferenceImage
    case invalidResponse
    case failed(String)
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Agnes API Key 无效"
        case .invalidReferenceImage: return "Agnes Video 需要可公开访问的 HTTPS 首帧参考图"
        case .invalidResponse: return "Agnes Video 没有返回有效任务"
        case .failed(let message): return "Agnes Video 视频生成失败：\(message)"
        case .requestFailed(let status, let message):
            return "Agnes Video 请求失败（HTTP \(status)）：\(message)"
        }
    }
}

struct AgnesVideoGenerationClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 900
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func create(
        prompt: String,
        firstFrameURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        settings: AgnesVideoGenerationRequestSettings
    ) async throws -> AgnesVideoGenerationJob {
        try await sendJobRequest(Self.makeCreateRequest(
            prompt: prompt,
            firstFrameURL: firstFrameURL,
            apiKey: apiKey,
            configuration: configuration,
            settings: settings))
    }

    func retrieve(
        id: String,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration
    ) async throws -> AgnesVideoGenerationJob {
        let key = try Self.validatedKey(apiKey)
        var components = URLComponents(url: configuration.agnesVideoResultURL,
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "video_id", value: id),
            URLQueryItem(name: "model_name", value: "agnes-video-v2.0"),
        ]
        guard let url = components?.url else {
            throw AgnesVideoGenerationError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return try await sendJobRequest(request)
    }

    func downloadContent(job: AgnesVideoGenerationJob) async throws -> Data {
        guard let resultURL = job.resultURL else {
            throw AgnesVideoGenerationError.invalidResponse
        }
        let (data, response) = try await session.data(for: URLRequest(url: resultURL))
        guard let http = response as? HTTPURLResponse else {
            throw AgnesVideoGenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw AgnesVideoGenerationError.requestFailed(
                status: http.statusCode, message: "无法下载 Agnes Video 生成视频")
        }
        return data
    }

    static func makeCreateRequest(
        prompt: String,
        firstFrameURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        settings: AgnesVideoGenerationRequestSettings
    ) throws -> URLRequest {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty,
              firstFrameURL.scheme?.lowercased() == "https",
              configuration.isAgnesAPI else {
            throw AgnesVideoGenerationError.invalidReferenceImage
        }
        let payload: [String: Any] = [
            "model": "agnes-video-v2.0",
            "prompt": trimmedPrompt,
            "image": firstFrameURL.absoluteString,
            "width": settings.width,
            "height": settings.height,
            "num_frames": settings.numFrames,
            "frame_rate": settings.frameRate,
            "negative_prompt": "camera movement, zoom, pan, crop, cut, scene change, identity change, extra limbs, text, watermark",
        ]
        var request = URLRequest(url: configuration.videosURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try validatedKey(apiKey))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func sendJobRequest(_ request: URLRequest) async throws -> AgnesVideoGenerationJob {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgnesVideoGenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AgnesVideoGenerationError.invalidAPIKey }
            throw AgnesVideoGenerationError.requestFailed(
                status: http.statusCode,
                message: Self.apiErrorMessage(from: data) ?? "未知错误")
        }
        return try Self.job(from: data)
    }

    private static func job(from data: Data) throws -> AgnesVideoGenerationJob {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            throw AgnesVideoGenerationError.invalidResponse
        }
        let responseObjects = nestedResponseObjects(in: json)
        if let message = apiErrorMessage(from: data, responseObjects: responseObjects),
           isExplicitFailure(responseObjects) {
            throw AgnesVideoGenerationError.failed(message)
        }

        // Agnes currently returns both snake_case and camelCase envelope
        // variants. Always prefer the video ID because /agnesapi polls by
        // video_id; a task ID is only a legacy fallback.
        let id = firstString(
            for: ["video_id", "videoId"], in: responseObjects)
            ?? firstString(for: ["task_id", "taskId", "id"], in: responseObjects)
        guard let id, !id.isEmpty else {
            throw AgnesVideoGenerationError.invalidResponse
        }
        let rawStatus = firstString(for: ["status", "state"], in: responseObjects)?
            .lowercased() ?? "queued"
        let message = apiErrorMessage(from: data, responseObjects: responseObjects)
            ?? "任务失败"
        let resultURL = firstString(
            for: [
                "video_url", "videoUrl", "remixed_from_video_id",
                "remixedFromVideoId", "output_url", "outputUrl", "url",
            ],
            in: responseObjects).flatMap(URL.init(string:))
        let status: AgnesVideoGenerationJob.Status
        switch rawStatus {
        case "queued", "pending", "submitted": status = .queued
        case "in_progress", "processing", "running": status = .processing
        case "completed", "succeeded", "success":
            guard resultURL?.scheme?.lowercased() == "https" else {
                throw AgnesVideoGenerationError.invalidResponse
            }
            status = .completed
        case "failed", "failure", "error", "cancelled": status = .failed(message)
        default: throw AgnesVideoGenerationError.failed("Agnes Video 返回未知任务状态：\(rawStatus)")
        }
        let progress = firstNumber(for: ["progress", "percentage"], in: responseObjects)
            .map { $0 > 1 ? $0 / 100 : $0 }
        return AgnesVideoGenerationJob(
            id: id, status: status, resultURL: resultURL, progress: progress)
    }

    private static func validatedKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgnesVideoGenerationError.invalidAPIKey }
        return key
    }

    private static func apiErrorMessage(
        from data: Data,
        responseObjects: [[String: Any]]? = nil
    ) -> String? {
        let objects: [[String: Any]]
        if let responseObjects {
            objects = responseObjects
        } else if let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any] {
            objects = nestedResponseObjects(in: json)
        } else {
            return nil
        }
        for object in objects {
            if let error = object["error"] as? [String: Any],
               let message = (error["message"] as? String)
                ?? (error["detail"] as? String) {
                return message
            }
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if let message = (object["message"] as? String)
                ?? (object["detail"] as? String), !message.isEmpty {
                return message
            }
        }
        return nil
    }

    private static func nestedResponseObjects(
        in root: [String: Any]
    ) -> [[String: Any]] {
        var objects: [[String: Any]] = []

        func append(_ value: Any) {
            guard objects.count < 24 else { return }
            if let object = value as? [String: Any] {
                objects.append(object)
                for key in ["data", "result", "task", "video", "metadata", "output"] {
                    if let nested = object[key] { append(nested) }
                }
            } else if let array = value as? [Any] {
                for nested in array { append(nested) }
            }
        }

        append(root)
        return objects
    }

    private static func firstString(
        for keys: [String],
        in objects: [[String: Any]]
    ) -> String? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func firstNumber(
        for keys: [String],
        in objects: [[String: Any]]
    ) -> Double? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? NSNumber { return value.doubleValue }
                if let value = object[key] as? String, let number = Double(value) {
                    return number
                }
            }
        }
        return nil
    }

    private static func isExplicitFailure(_ objects: [[String: Any]]) -> Bool {
        for object in objects {
            if object["success"] as? Bool == false { return true }
            if let code = object["code"] as? NSNumber, code.intValue >= 400 {
                return true
            }
            if let status = (object["status"] as? String)?.lowercased(),
               ["failed", "failure", "error", "cancelled"].contains(status) {
                return true
            }
        }
        return false
    }
}
