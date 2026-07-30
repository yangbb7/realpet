import Foundation

struct OpenAIVideoGenerationJob: Equatable, Sendable {
    enum Provider: Equatable, Sendable {
        case openAICompatible
        case agnes
    }
    enum Status: Equatable, Sendable {
        case queued
        case processing
        case completed
        case failed(String)
    }

    let id: String
    let status: Status
    let progress: Double?
    let provider: Provider
    let videoID: String?
    let resultURL: URL?
}

enum OpenAIVideoGenerationError: LocalizedError, Equatable {
    case invalidAPIKey
    case invalidReferenceImage
    case invalidResponse
    case failed(String)
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "动作服务凭据无效"
        case .invalidReferenceImage: return "主参考图无法读取"
        case .invalidResponse: return "视频服务没有返回有效任务"
        case .failed(let message): return "视频生成失败：\(message)"
        case .requestFailed(let status, let message):
            return "视频服务请求失败（HTTP \(status)）：\(message)"
        }
    }
}

struct OpenAIVideoGenerationClient {
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
        referenceImageURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String,
        seconds: Int,
        size: String
    ) async throws -> OpenAIVideoGenerationJob {
        if configuration.isAgnesAPI, model == "agnes-video-v2.0" {
            return try await createAgnes(
                prompt: prompt,
                publicReferenceImageURL: referenceImageURL,
                apiKey: apiKey,
                configuration: configuration,
                model: model,
                seconds: seconds,
                size: size)
        }
        let request = try Self.makeCreateRequest(
            prompt: prompt, referenceImageURL: referenceImageURL, apiKey: apiKey,
            configuration: configuration, model: model, seconds: seconds, size: size)
        return try await sendJobRequest(request)
    }

    func createAgnes(
        prompt: String,
        publicReferenceImageURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String,
        seconds: Int,
        size: String
    ) async throws -> OpenAIVideoGenerationJob {
        let request = try Self.makeAgnesCreateRequest(
            prompt: prompt,
            publicReferenceImageURL: publicReferenceImageURL,
            apiKey: apiKey,
            configuration: configuration,
            model: model,
            seconds: seconds,
            size: size)
        return try await sendJobRequest(request, provider: .agnes)
    }

    func retrieve(
        id: String,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration
    ) async throws -> OpenAIVideoGenerationJob {
        var request = URLRequest(url: configuration.videoURL(id: id))
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(try Self.validatedKey(apiKey))",
            forHTTPHeaderField: "Authorization")
        return try await sendJobRequest(request)
    }

    func retrieve(
        job: OpenAIVideoGenerationJob,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration
    ) async throws -> OpenAIVideoGenerationJob {
        guard job.provider == .agnes else {
            return try await retrieve(id: job.id, apiKey: apiKey, configuration: configuration)
        }
        guard let videoID = job.videoID else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        var components = URLComponents(url: configuration.agnesVideoResultURL,
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "video_id", value: videoID),
            URLQueryItem(name: "model_name", value: "agnes-video-v2.0"),
        ]
        guard let url = components?.url else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(try Self.validatedKey(apiKey))",
            forHTTPHeaderField: "Authorization")
        return try await sendJobRequest(request, provider: .agnes)
    }

    func downloadContent(
        id: String,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration
    ) async throws -> Data {
        var request = URLRequest(url: configuration.videoContentURL(id: id))
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(try Self.validatedKey(apiKey))",
            forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            if http.statusCode == 401 { throw OpenAIVideoGenerationError.invalidAPIKey }
            throw OpenAIVideoGenerationError.requestFailed(
                status: http.statusCode, message: Self.apiErrorMessage(from: data) ?? "未知错误")
        }
        return data
    }

    func downloadContent(
        job: OpenAIVideoGenerationJob,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration
    ) async throws -> Data {
        guard job.provider == .agnes else {
            return try await downloadContent(
                id: job.id, apiKey: apiKey, configuration: configuration)
        }
        guard let resultURL = job.resultURL else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        var request = URLRequest(url: resultURL)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        return data
    }

    static func makeCreateRequest(
        prompt: String,
        referenceImageURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String,
        seconds: Int,
        size: String
    ) throws -> URLRequest {
        let key = try validatedKey(apiKey)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        guard let reference = try? PetReferenceImageData.load(
            from: referenceImageURL) else {
            throw OpenAIVideoGenerationError.invalidReferenceImage
        }
        let boundary = "RealPet-Video-\(UUID().uuidString)"
        var request = URLRequest(url: configuration.videosURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary, prompt: trimmedPrompt, model: model,
            seconds: seconds, size: size, reference: reference)
        return request
    }

    static func makeAgnesCreateRequest(
        prompt: String,
        publicReferenceImageURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String,
        seconds: Int,
        size: String
    ) throws -> URLRequest {
        let key = try validatedKey(apiKey)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, publicReferenceImageURL.scheme == "https" else {
            throw OpenAIVideoGenerationError.invalidReferenceImage
        }
        let dimensions = try agnesDimensions(for: size)
        let frames = agnesFrameCount(seconds: seconds, frameRate: 24)
        let payload: [String: Any] = [
            "model": model,
            "prompt": trimmedPrompt,
            "image": publicReferenceImageURL.absoluteString,
            "width": dimensions.width,
            "height": dimensions.height,
            "num_frames": frames,
            "frame_rate": 24,
            "negative_prompt": "people, hands, text, watermark, extra animals, props, camera movement, cropped body",
        ]
        var request = URLRequest(url: configuration.videosURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func sendJobRequest(
        _ request: URLRequest,
        provider: OpenAIVideoGenerationJob.Provider = .openAICompatible
    ) async throws -> OpenAIVideoGenerationJob {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw OpenAIVideoGenerationError.invalidAPIKey }
            throw OpenAIVideoGenerationError.requestFailed(
                status: http.statusCode, message: Self.apiErrorMessage(from: data) ?? "未知错误")
        }
        return try Self.job(from: data, provider: provider)
    }

    private static func job(
        from data: Data,
        provider: OpenAIVideoGenerationJob.Provider
    ) throws -> OpenAIVideoGenerationJob {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        // Agnes gateways may wrap the task in `data`, `result`, or `task`,
        // while the documented endpoint returns it at the top level.
        let json = taskPayload(in: root)
        let id = stringValue(json["task_id"])
            ?? stringValue(json["id"])
            ?? stringValue(root["task_id"])
            ?? stringValue(root["id"])
        let videoID = stringValue(json["video_id"])
            ?? stringValue(root["video_id"])
        guard let id else {
            if let message = apiErrorMessage(from: data) {
                throw OpenAIVideoGenerationError.failed(message)
            }
            throw OpenAIVideoGenerationError.failed(
                "Agnes Video 创建响应未包含任务标识（字段：\(root.keys.sorted().joined(separator: ", "))）")
        }
        let rawStatus = (json["status"] as? String)
            ?? (json["task_status"] as? String)
            ?? (json["state"] as? String)
            ?? (root["status"] as? String)
            ?? (root["task_status"] as? String)
            ?? (root["state"] as? String)
        let progress = ((json["progress"] as? NSNumber)
            ?? (root["progress"] as? NSNumber))?.doubleValue
        let status: OpenAIVideoGenerationJob.Status
        if let rawStatus {
            switch rawStatus.lowercased() {
            case "queued", "pending", "submitted", "created", "accepted", "waiting", "in_queue":
                status = .queued
            case "in_progress", "processing", "running", "generating", "rendering":
                status = .processing
            case "completed", "succeeded": status = .completed
            case "failed", "cancelled", "canceled":
                status = .failed(apiErrorMessage(from: data) ?? "任务未完成")
            default:
                throw OpenAIVideoGenerationError.failed(
                    "Agnes Video 返回了未知任务状态：\(rawStatus)")
            }
        } else if provider == .agnes, videoID != nil {
            // Some successful creation responses omit the initial state; a
            // video_id is sufficient to begin the documented polling flow.
            status = .queued
        } else {
            throw OpenAIVideoGenerationError.invalidResponse
        }
        let resultURL: URL?
        if let metadata = json["metadata"] as? [String: Any],
           let value = metadata["url"] as? String {
            resultURL = URL(string: value)
        } else if let metadata = root["metadata"] as? [String: Any],
                  let value = metadata["url"] as? String {
            resultURL = URL(string: value)
        } else {
            resultURL = nil
        }
        return OpenAIVideoGenerationJob(
            id: id,
            status: status,
            progress: progress,
            provider: provider,
            videoID: videoID,
            resultURL: resultURL)
    }

    private static func taskPayload(in root: [String: Any]) -> [String: Any] {
        var candidates = [root]
        var index = 0
        while index < candidates.count {
            let candidate = candidates[index]
            index += 1
            if candidate["task_id"] != nil || candidate["video_id"] != nil {
                return candidate
            }
            for key in ["data", "result", "task", "job", "payload", "response"] {
                if let nested = candidate[key] as? [String: Any] {
                    candidates.append(nested)
                }
            }
        }
        return root
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String where !value.isEmpty:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func multipartBody(
        boundary: String,
        prompt: String,
        model: String,
        seconds: Int,
        size: String,
        reference: PetReferenceImageData
    ) -> Data {
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("model", model.trimmingCharacters(in: .whitespacesAndNewlines))
        field("prompt", prompt)
        field("seconds", String(seconds))
        field("size", size)
        let extensionName: String
        switch reference.mimeType {
        case "image/jpeg": extensionName = "jpg"
        case "image/webp": extensionName = "webp"
        default: extensionName = "png"
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"input_reference\"; filename=\"reference.\(extensionName)\"\r\n")
        append("Content-Type: \(reference.mimeType)\r\n\r\n")
        body.append(reference.data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func validatedKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAIVideoGenerationError.invalidAPIKey }
        return key
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        if let nested = json["data"] as? [String: Any],
           let message = nested["message"] as? String { return message }
        return json["message"] as? String
    }

    private static func agnesDimensions(for size: String) throws -> (width: Int, height: Int) {
        switch size {
        case "1152x768": return (1152, 768)
        case "768x1152": return (768, 1152)
        case "1280x720": return (1280, 720)
        case "720x1280": return (720, 1280)
        case "1024x1792": return (1024, 1792)
        case "1792x1024": return (1792, 1024)
        default: throw OpenAIVideoGenerationError.invalidResponse
        }
    }

    private static func agnesFrameCount(seconds: Int, frameRate: Int) -> Int {
        let desired = max(1, seconds * frameRate)
        let units = (desired - 1 + 7) / 8
        return min(441, max(9, units * 8 + 1))
    }
}
