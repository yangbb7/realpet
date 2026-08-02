import Foundation

enum SupabaseGoogleSessionError: LocalizedError, Equatable {
    case signInRequired
    case invalidCallback
    case missingOAuthToken
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "请先使用 Google 登录，再生成 Agnes 动作视频"
        case .invalidCallback:
            return "Google 登录回调无效，请重新登录"
        case .missingOAuthToken:
            return "Google 登录没有返回 Supabase 会话，请重新登录"
        case .invalidResponse:
            return "Supabase Google 登录响应无效"
        case .requestFailed(let status, let message):
            return "Supabase Google 登录请求失败（HTTP \(status)）：\(message)"
        }
    }
}

struct SupabaseGoogleAccount: Codable, Equatable, Sendable {
    let userID: UUID
    let email: String?

    var displayName: String {
        guard let email, !email.isEmpty else { return "Google 账户" }
        return email
    }
}

/// The Supabase session issued after a Google OAuth redirect. This is not an
/// application API key: it is a revocable account session scoped by Storage
/// RLS to this signed-in owner.
struct SupabaseGoogleSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let account: SupabaseGoogleAccount
    let expiresAt: Date
}

/// Authenticates the desktop app through Supabase's Google provider. Supabase
/// owns the Google client secret; the app contains only the publishable key.
actor SupabaseGoogleSessionStore {
    static let shared = SupabaseGoogleSessionStore()

    static let callbackURL = URL(string: "realpet-auth://auth/callback")!

    private let session: URLSession
    private let fileURL: URL

    init(session: URLSession = .shared, fileURL: URL? = nil) {
        self.session = session
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base.appendingPathComponent("RealPet", isDirectory: true)
                .appendingPathComponent("supabase-google-session.json")
        }
    }

    static func authorizationURL(
        configuration: SupabaseReferenceStorageConfiguration
    ) throws -> URL {
        var components = URLComponents(
            url: try configuration.validated().projectURL
                .appendingPathComponent("auth/v1/authorize"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: callbackURL.absoluteString),
        ]
        guard let url = components?.url else {
            throw SupabaseGoogleSessionError.invalidResponse
        }
        return url
    }

    func account() -> SupabaseGoogleAccount? {
        try? load()?.account
    }

    func credentials(
        configuration: SupabaseReferenceStorageConfiguration,
        publishableKey: String
    ) async throws -> SupabaseReferenceStorageCredentials {
        let configured = try configuration.validated()
        guard let current = try load() else {
            throw SupabaseGoogleSessionError.signInRequired
        }
        let active: SupabaseGoogleSession
        if current.expiresAt > Date().addingTimeInterval(90) {
            active = current
        } else {
            do {
                active = try await refresh(
                    current, configuration: configured, publishableKey: publishableKey)
            } catch let error as SupabaseGoogleSessionError {
                guard case .requestFailed(let status, _) = error,
                      status == 400 || status == 401 else {
                    throw error
                }
                removePersistedSession()
                throw SupabaseGoogleSessionError.signInRequired
            }
        }
        return try SupabaseReferenceStorageCredentials(
            publishableKey: publishableKey,
            accessToken: active.accessToken,
            ownerID: active.account.userID)
    }

    func completeAuthorization(
        callbackURL: URL,
        configuration: SupabaseReferenceStorageConfiguration,
        publishableKey: String
    ) async throws -> SupabaseGoogleAccount {
        let callback = try Self.parseCallback(callbackURL)
        let account = try await fetchAccount(
            accessToken: callback.accessToken,
            configuration: configuration.validated(),
            publishableKey: publishableKey)
        let stored = SupabaseGoogleSession(
            accessToken: callback.accessToken,
            refreshToken: callback.refreshToken,
            account: account,
            expiresAt: Date().addingTimeInterval(max(60, callback.expiresIn)))
        try persist(stored)
        return account
    }

    /// Revokes the refresh token remotely when possible, and always removes it
    /// from this Mac even if the device is offline.
    func signOut(
        configuration: SupabaseReferenceStorageConfiguration,
        publishableKey: String
    ) async {
        defer { removePersistedSession() }
        guard let current = try? load(),
              let projectURL = try? configuration.validated().projectURL else { return }
        var request = URLRequest(url: projectURL.appendingPathComponent("auth/v1/logout"))
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private func load() throws -> SupabaseGoogleSession? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(
            SupabaseGoogleSession.self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ value: SupabaseGoogleSession) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func removePersistedSession() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func refresh(
        _ previous: SupabaseGoogleSession,
        configuration: SupabaseReferenceStorageConfiguration,
        publishableKey: String
    ) async throws -> SupabaseGoogleSession {
        var components = URLComponents(url: try configuration.projectURL
            .appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = components?.url else {
            throw SupabaseGoogleSessionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": previous.refreshToken,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseGoogleSessionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseGoogleSessionError.requestFailed(
                http.statusCode, Self.apiErrorMessage(from: data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty else {
            throw SupabaseGoogleSessionError.invalidResponse
        }
        let refreshToken = (object["refresh_token"] as? String) ?? previous.refreshToken
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let refreshed = SupabaseGoogleSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            account: previous.account,
            expiresAt: Date().addingTimeInterval(max(60, expiresIn)))
        try persist(refreshed)
        return refreshed
    }

    private func fetchAccount(
        accessToken: String,
        configuration: SupabaseReferenceStorageConfiguration,
        publishableKey: String
    ) async throws -> SupabaseGoogleAccount {
        var request = URLRequest(url: try configuration.projectURL
            .appendingPathComponent("auth/v1/user"))
        request.httpMethod = "GET"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseGoogleSessionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseGoogleSessionError.requestFailed(
                http.statusCode, Self.apiErrorMessage(from: data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userIDString = object["id"] as? String,
              let userID = UUID(uuidString: userIDString) else {
            throw SupabaseGoogleSessionError.invalidResponse
        }
        return .init(userID: userID, email: object["email"] as? String)
    }

    private struct OAuthCallback {
        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
    }

    private static func parseCallback(_ url: URL) throws -> OAuthCallback {
        guard url.scheme?.lowercased() == callbackURL.scheme,
              url.host == callbackURL.host,
              url.path == callbackURL.path else {
            throw SupabaseGoogleSessionError.invalidCallback
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        if let fragment = components?.fragment,
           let fragmentItems = URLComponents(
                string: "https://realpet.invalid/?\(fragment)")?.queryItems {
            for item in fragmentItems {
                values[item.name] = item.value ?? ""
            }
        }
        if let message = values["error_description"] ?? values["error"], !message.isEmpty {
            throw SupabaseGoogleSessionError.requestFailed(400, message)
        }
        guard let accessToken = values["access_token"], !accessToken.isEmpty,
              let refreshToken = values["refresh_token"], !refreshToken.isEmpty else {
            throw SupabaseGoogleSessionError.missingOAuthToken
        }
        let expiresIn = TimeInterval(values["expires_in"] ?? "") ?? 3600
        return .init(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn)
    }

    private static func apiErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "未知错误"
        }
        if let message = object["msg"] as? String, !message.isEmpty { return message }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let error = object["error_description"] as? String, !error.isEmpty { return error }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        return "未知错误"
    }
}
