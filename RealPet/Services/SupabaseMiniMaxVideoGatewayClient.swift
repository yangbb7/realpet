import Foundation

struct SupabaseMiniMaxVideoGatewayJob: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case queued
        case processing
        case completed
        case failed(String)
    }

    let id: String
    let status: Status
    let resultURL: URL?
    /// `nil` means the server has no configured contractual rate, never zero.
    let providerCostCents: Int?
}

enum SupabaseMiniMaxVideoGatewayError: LocalizedError, Equatable {
    case signInRequired
    case invalidResponse
    case failed(String)
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "请先使用 Google 登录，再生成 MiniMax 动作视频"
        case .invalidResponse:
            return "RealPet 视频服务没有返回有效任务"
        case .failed(let message):
            return "MiniMax H3 视频生成失败：\(message)"
        case .requestFailed(let status, let message):
            return "RealPet 视频服务请求失败（HTTP \(status)）：\(message)"
        }
    }
}

/// The desktop app never calls MiniMax directly. This client invokes the
/// authenticated Supabase Edge Function, which owns provider credentials and
/// resolves the current owner's private pet references on the server.
struct SupabaseMiniMaxVideoGatewayClient {
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
        petID: UUID,
        action: FixedPetAction,
        seconds: Int,
        configuration: SupabaseReferenceStorageConfiguration,
        credentials: SupabaseReferenceStorageCredentials
    ) async throws -> SupabaseMiniMaxVideoGatewayJob {
        guard (4...15).contains(seconds) else {
            throw SupabaseMiniMaxVideoGatewayError.failed("视频时长必须为 4 到 15 秒")
        }
        return try await send(
            payload: [
                "operation": "create",
                "petId": petID.uuidString.lowercased(),
                "actionKind": action.rawValue,
                "durationSeconds": seconds,
            ],
            configuration: configuration,
            credentials: credentials)
    }

    func retrieve(
        id: String,
        configuration: SupabaseReferenceStorageConfiguration,
        credentials: SupabaseReferenceStorageCredentials
    ) async throws -> SupabaseMiniMaxVideoGatewayJob {
        try await send(
            payload: ["operation": "status", "jobId": id],
            configuration: configuration,
            credentials: credentials)
    }

    func downloadContent(job: SupabaseMiniMaxVideoGatewayJob) async throws -> Data {
        guard let resultURL = job.resultURL else {
            throw SupabaseMiniMaxVideoGatewayError.invalidResponse
        }
        let (data, response) = try await session.data(for: URLRequest(url: resultURL))
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseMiniMaxVideoGatewayError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw SupabaseMiniMaxVideoGatewayError.requestFailed(
                status: http.statusCode, message: "无法下载 MiniMax H3 生成视频")
        }
        return data
    }

    private func send(
        payload: [String: Any],
        configuration: SupabaseReferenceStorageConfiguration,
        credentials: SupabaseReferenceStorageCredentials
    ) async throws -> SupabaseMiniMaxVideoGatewayJob {
        guard let accessToken = credentials.accessToken, !accessToken.isEmpty,
              credentials.ownerID != nil else {
            throw SupabaseMiniMaxVideoGatewayError.signInRequired
        }
        var request = URLRequest(url: try functionURL(configuration: configuration))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseMiniMaxVideoGatewayError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseMiniMaxVideoGatewayError.requestFailed(
                status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return try Self.job(from: data)
    }

    private func functionURL(
        configuration: SupabaseReferenceStorageConfiguration
    ) throws -> URL {
        try configuration.projectURL
            .appendingPathComponent("functions", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("minimax-video", isDirectory: false)
    }

    private static func job(from data: Data) throws -> SupabaseMiniMaxVideoGatewayJob {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["jobId"] as? String,
              !id.isEmpty,
              let rawStatus = root["status"] as? String else {
            throw SupabaseMiniMaxVideoGatewayError.invalidResponse
        }
        let resultURL = (root["resultUrl"] as? String).flatMap(URL.init(string:))
        let message = root["error"] as? String
        let status: SupabaseMiniMaxVideoGatewayJob.Status
        switch rawStatus.lowercased() {
        case "submitting", "queued":
            status = .queued
        case "running":
            status = .processing
        case "succeeded":
            guard resultURL != nil else {
                throw SupabaseMiniMaxVideoGatewayError.invalidResponse
            }
            status = .completed
        case "failed", "expired":
            status = .failed(message ?? "任务状态：\(rawStatus)")
        default:
            throw SupabaseMiniMaxVideoGatewayError.failed(
                "RealPet 视频服务返回未知任务状态：\(rawStatus)")
        }
        return .init(
            id: id,
            status: status,
            resultURL: resultURL,
            providerCostCents: root["providerCostCents"] as? Int)
    }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "未知错误"
        }
        return (root["error"] as? String) ?? (root["message"] as? String) ?? "未知错误"
    }
}
