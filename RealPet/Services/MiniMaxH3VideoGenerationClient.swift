import Foundation

struct MiniMaxH3VideoGenerationJob: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case queued
        case processing
        case completed
        case failed(String)
    }

    let id: String
    let status: Status
    let resultURL: URL?
}

enum MiniMaxH3VideoGenerationError: LocalizedError, Equatable {
    case invalidAPIKey
    case invalidReferenceImage
    case invalidResponse
    case failed(String)
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "MiniMax API Key 无效"
        case .invalidReferenceImage: return "Agnes Image 没有返回可用于 MiniMax H3 的公开参考图"
        case .invalidResponse: return "MiniMax H3 没有返回有效任务"
        case .failed(let message): return "MiniMax H3 视频生成失败：\(message)"
        case .requestFailed(let status, let message):
            return "MiniMax H3 请求失败（HTTP \(status)）：\(message)"
        }
    }
}

struct MiniMaxH3VideoGenerationClient {
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
        configuration: MiniMaxVideoAPIConfiguration,
        seconds: Int
    ) async throws -> MiniMaxH3VideoGenerationJob {
        try await sendJobRequest(Self.makeCreateRequest(
            prompt: prompt,
            firstFrameURL: firstFrameURL,
            apiKey: apiKey,
            configuration: configuration,
            seconds: seconds), isCreate: true)
    }

    func retrieve(
        id: String,
        apiKey: String,
        configuration: MiniMaxVideoAPIConfiguration
    ) async throws -> MiniMaxH3VideoGenerationJob {
        var request = URLRequest(url: configuration.queryURL(taskID: id))
        request.httpMethod = "GET"
        request.setValue("Bearer \(try Self.validatedKey(apiKey))", forHTTPHeaderField: "Authorization")
        return try await sendJobRequest(request, isCreate: false)
    }

    func downloadContent(job: MiniMaxH3VideoGenerationJob) async throws -> Data {
        guard let resultURL = job.resultURL else {
            throw MiniMaxH3VideoGenerationError.invalidResponse
        }
        let (data, response) = try await session.data(for: URLRequest(url: resultURL))
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxH3VideoGenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw MiniMaxH3VideoGenerationError.requestFailed(
                status: http.statusCode,
                message: "无法下载 MiniMax H3 生成视频")
        }
        return data
    }

    static func makeCreateRequest(
        prompt: String,
        firstFrameURL: URL,
        apiKey: String,
        configuration: MiniMaxVideoAPIConfiguration,
        seconds: Int
    ) throws -> URLRequest {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty,
              firstFrameURL.scheme?.lowercased() == "https" else {
            throw MiniMaxH3VideoGenerationError.invalidReferenceImage
        }
        guard (4...15).contains(seconds) else {
            throw MiniMaxH3VideoGenerationError.invalidResponse
        }
        let payload: [String: Any] = [
            "model": "MiniMax-H3",
            "content": [
                ["type": "text", "text": trimmedPrompt],
                [
                    "type": "image_url",
                    "image_url": ["url": firstFrameURL.absoluteString],
                    "role": "first_frame",
                ],
            ],
            "resolution": "2K",
            "duration": seconds,
            "ratio": "adaptive",
            "aigc_watermark": false,
        ]
        var request = URLRequest(url: configuration.createURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try validatedKey(apiKey))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func sendJobRequest(
        _ request: URLRequest,
        isCreate: Bool
    ) async throws -> MiniMaxH3VideoGenerationJob {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxH3VideoGenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MiniMaxH3VideoGenerationError.invalidAPIKey }
            throw MiniMaxH3VideoGenerationError.requestFailed(
                status: http.statusCode,
                message: Self.apiErrorMessage(from: data) ?? "未知错误")
        }
        return try Self.job(from: data, isCreate: isCreate)
    }

    private static func job(from data: Data, isCreate: Bool) throws -> MiniMaxH3VideoGenerationJob {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw MiniMaxH3VideoGenerationError.invalidResponse
        }
        if isCreate {
            guard let id = stringValue(root["task_id"]) else {
                throw MiniMaxH3VideoGenerationError.failed(
                    apiErrorMessage(from: data) ?? "创建响应未包含 task_id")
            }
            return MiniMaxH3VideoGenerationJob(id: id, status: .queued, resultURL: nil)
        }
        guard let task = root["task"] as? [String: Any],
              let id = stringValue(task["id"]),
              let rawStatus = task["status"] as? String else {
            throw MiniMaxH3VideoGenerationError.failed(
                apiErrorMessage(from: data) ?? "查询响应未包含 task")
        }
        let resultURL: URL?
        if let content = task["content"] as? [String: Any],
           let urlString = content["url"] as? String {
            resultURL = URL(string: urlString)
        } else {
            resultURL = nil
        }
        let status: MiniMaxH3VideoGenerationJob.Status
        switch rawStatus.lowercased() {
        case "queued": status = .queued
        case "running": status = .processing
        case "succeeded":
            guard resultURL != nil else {
                throw MiniMaxH3VideoGenerationError.invalidResponse
            }
            status = .completed
        case "failed", "cancelled", "expired":
            let message = (task["error"] as? [String: Any])?["message"] as? String
            status = .failed(message ?? "任务状态：\(rawStatus)")
        default:
            throw MiniMaxH3VideoGenerationError.failed("MiniMax H3 返回未知任务状态：\(rawStatus)")
        }
        return MiniMaxH3VideoGenerationJob(id: id, status: status, resultURL: resultURL)
    }

    private static func validatedKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MiniMaxH3VideoGenerationError.invalidAPIKey }
        return key
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String where !value.isEmpty: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return root["message"] as? String
    }
}
