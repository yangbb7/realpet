import Foundation

enum SupabaseReferenceStorageError: LocalizedError, Equatable {
    case missingProjectURL
    case invalidProjectURL
    case invalidBucket
    case missingPublishableKey
    case missingAuthenticatedOwner
    case forbiddenServiceRoleKey
    case unreadableResponse
    case missingSignedURL
    case invalidObjectPath
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingProjectURL:
            return "应用内置的 Supabase 项目地址无效"
        case .invalidProjectURL:
            return "Supabase 项目 URL 无效，必须为 HTTPS 地址"
        case .invalidBucket:
            return "Supabase Storage Bucket 名称无效"
        case .missingPublishableKey:
            return "当前 RealPet 发布包未包含 Supabase Publishable Key"
        case .missingAuthenticatedOwner:
            return "请先使用 Google 登录，才能上传宠物原图"
        case .forbiddenServiceRoleKey:
            return "Supabase service_role 密钥不能写入桌面应用"
        case .unreadableResponse:
            return "Supabase Storage 返回了无效响应"
        case .missingSignedURL:
            return "Supabase Storage 未返回临时参考图地址"
        case .invalidObjectPath:
            return "Supabase Storage 图片路径无效"
        case .requestFailed(let status, let message):
            return "Supabase Storage 请求失败（HTTP \(status)）：\(message)"
        }
    }
}

/// Product-owned Supabase settings. They are part of the released app rather
/// than a per-owner setting: a publishable key is intentionally public, while
/// Storage RLS remains responsible for data access.
enum BundledSupabaseReferenceStorage {
    static let projectURLString = "https://opgmbtrhxrqdofbgpdbp.supabase.co"
    static let bucketName = "pet-reference-images"
    private static let publishableKeyInfoKey = "RealPetSupabasePublishableKey"

    static func configuration() throws -> SupabaseReferenceStorageConfiguration {
        try SupabaseReferenceStorageConfiguration(
            projectURLString: projectURLString,
            bucketName: bucketName).validated()
    }

    static func publishableKey(bundle: Bundle = .main) throws -> String {
        let configuredKey = bundle.object(
            forInfoDictionaryKey: publishableKeyInfoKey) as? String
        let bundledKey = configuredKey?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        return try SupabaseReferenceStorageCredentials.validatePublishableKey(bundledKey)
    }
}

/// Non-secret values persisted with the motion service configuration. The
/// product-owned publishable key is bundled in the release app. Storage uses a
/// per-user Google-authenticated JWT, never a user-configured or service-role
/// key.
struct SupabaseReferenceStorageConfiguration: Codable, Equatable, Sendable {
    static let defaultBucketName = "pet-reference-images"
    static let signingLifetime: TimeInterval = 24 * 60 * 60

    var projectURLString: String?
    var bucketName: String

    init(
        projectURLString: String? = nil,
        bucketName: String = Self.defaultBucketName
    ) {
        self.projectURLString = projectURLString
        self.bucketName = bucketName
    }

    func validated() throws -> SupabaseReferenceStorageConfiguration {
        let project = projectURLString?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
        guard !project.isEmpty else {
            throw SupabaseReferenceStorageError.missingProjectURL
        }
        guard let components = URLComponents(string: project),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw SupabaseReferenceStorageError.invalidProjectURL
        }
        let bucket = bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty,
              bucket.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw SupabaseReferenceStorageError.invalidBucket
        }
        return .init(projectURLString: components.url?.absoluteString, bucketName: bucket)
    }

    var projectURL: URL {
        get throws {
            let validated = try validated()
            guard let projectURLString = validated.projectURLString,
                  let url = URL(string: projectURLString) else {
                throw SupabaseReferenceStorageError.invalidProjectURL
            }
            return url
        }
    }

    var storageBaseURL: URL {
        get throws {
            try projectURL
                .appendingPathComponent("storage", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: false)
        }
    }
}

struct SupabaseReferenceStorageCredentials: Sendable {
    let publishableKey: String
    let accessToken: String?
    let ownerID: UUID?

    init(publishableKey: String, accessToken: String?, ownerID: UUID? = nil) throws {
        let normalizedKey = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw SupabaseReferenceStorageError.missingPublishableKey
        }
        guard !Self.isServiceRoleKey(normalizedKey) else {
            throw SupabaseReferenceStorageError.forbiddenServiceRoleKey
        }
        self.publishableKey = normalizedKey
        let normalizedToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken?.isEmpty != false || !Self.isServiceRoleKey(normalizedToken!) else {
            throw SupabaseReferenceStorageError.forbiddenServiceRoleKey
        }
        self.accessToken = normalizedToken?.isEmpty == false ? normalizedToken : nil
        self.ownerID = ownerID
    }

    static func validatePublishableKey(_ key: String) throws -> String {
        try SupabaseReferenceStorageCredentials(
            publishableKey: key, accessToken: nil).publishableKey
    }

    private static func isServiceRoleKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_secret_") { return true }
        let pieces = key.split(separator: ".")
        guard pieces.count == 3 else { return false }
        var payload = String(pieces[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["role"] as? String == "service_role"
    }
}

/// Stores original user-provided reference bytes in a private, per-user
/// gallery. The persisted `PetCloudReference` contains no URL capability;
/// signed URLs are generated only in memory for authorized server-side work.
struct SupabasePetReferenceStorageClient {
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

    func uploadReference(
        from imageURL: URL,
        petID: UUID,
        referenceID: UUID = UUID(),
        configuration: SupabaseReferenceStorageConfiguration,
        credentials: SupabaseReferenceStorageCredentials
    ) async throws -> PetCloudReference {
        let validatedConfiguration = try configuration.validated()
        let image = try PetReferenceImageData.load(from: imageURL)
        guard let ownerID = credentials.ownerID else {
            throw SupabaseReferenceStorageError.missingAuthenticatedOwner
        }
        let objectPath = Self.makeReferenceObjectPath(
            ownerID: ownerID, petID: petID, referenceID: referenceID,
            mimeType: image.mimeType)
        let uploadURL = try objectURL(
            configuration: validatedConfiguration, objectPath: objectPath,
            operation: "object")
        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        applyCredentials(credentials, to: &upload)
        upload.setValue(image.mimeType, forHTTPHeaderField: "Content-Type")
        upload.setValue("false", forHTTPHeaderField: "x-upsert")
        upload.httpBody = image.data
        _ = try await send(upload)
        return PetCloudReference(
            id: referenceID,
            objectPath: objectPath,
            mimeType: image.mimeType,
            originalFilename: imageURL.lastPathComponent)
    }

    func signedURL(
        for reference: PetCloudReference,
        configuration: SupabaseReferenceStorageConfiguration,
        credentials: SupabaseReferenceStorageCredentials
    ) async throws -> URL {
        let validatedConfiguration = try configuration.validated()
        try validateOwnedObjectPath(reference.objectPath, credentials: credentials)
        let signingURL = try objectURL(
            configuration: validatedConfiguration, objectPath: reference.objectPath,
            operation: "object/sign")
        var sign = URLRequest(url: signingURL)
        sign.httpMethod = "POST"
        applyCredentials(credentials, to: &sign)
        sign.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sign.httpBody = try JSONSerialization.data(withJSONObject: [
            "expiresIn": Int(SupabaseReferenceStorageConfiguration.signingLifetime),
        ])
        let data = try await send(sign)
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = (response["signedURL"] as? String)
                ?? (response["signedUrl"] as? String),
              let signedURL = try makeAbsoluteSignedURL(
                rawURL, configuration: validatedConfiguration) else {
            throw SupabaseReferenceStorageError.missingSignedURL
        }
        return signedURL
    }

    func download(
        _ reference: PetCloudReference,
        configuration: SupabaseReferenceStorageConfiguration,
        credentials: SupabaseReferenceStorageCredentials
    ) async throws -> PetReferenceImageData {
        let validatedConfiguration = try configuration.validated()
        try validateOwnedObjectPath(reference.objectPath, credentials: credentials)
        let url = try objectURL(
            configuration: validatedConfiguration, objectPath: reference.objectPath,
            operation: "object")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCredentials(credentials, to: &request)
        return try PetReferenceImageData(
            data: try await send(request), mimeType: reference.mimeType)
    }

    func delete(
        _ reference: PetCloudReference,
        configuration: SupabaseReferenceStorageConfiguration,
        credentials: SupabaseReferenceStorageCredentials
    ) async throws {
        try validateOwnedObjectPath(reference.objectPath, credentials: credentials)
        let url = try objectURL(
            configuration: configuration.validated(),
            objectPath: reference.objectPath, operation: "object")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyCredentials(credentials, to: &request)
        _ = try await send(request)
    }

    static func makeReferenceObjectPath(
        ownerID: UUID,
        petID: UUID,
        referenceID: UUID,
        mimeType: String
    ) -> String {
        let ext: String
        switch mimeType {
        case "image/png": ext = "png"
        case "image/webp": ext = "webp"
        default: ext = "jpg"
        }
        return "\(ownerID.uuidString.lowercased())/\(petID.uuidString.lowercased())/references/\(referenceID.uuidString.lowercased()).\(ext)"
    }

    private func validateOwnedObjectPath(
        _ objectPath: String,
        credentials: SupabaseReferenceStorageCredentials
    ) throws {
        guard let ownerID = credentials.ownerID else {
            throw SupabaseReferenceStorageError.missingAuthenticatedOwner
        }
        let components = objectPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components[0].lowercased() == ownerID.uuidString.lowercased(),
              components[2] == "references" else {
            throw SupabaseReferenceStorageError.invalidObjectPath
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseReferenceStorageError.unreadableResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseReferenceStorageError.requestFailed(
                status: http.statusCode, message: Self.apiErrorMessage(from: data))
        }
        return data
    }

    private func applyCredentials(
        _ credentials: SupabaseReferenceStorageCredentials,
        to request: inout URLRequest
    ) {
        request.setValue(credentials.publishableKey, forHTTPHeaderField: "apikey")
        if let accessToken = credentials.accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func objectURL(
        configuration: SupabaseReferenceStorageConfiguration,
        objectPath: String,
        operation: String
    ) throws -> URL {
        var url = try configuration.storageBaseURL
        for component in operation.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: true)
        }
        url.appendPathComponent(configuration.bucketName, isDirectory: true)
        for component in objectPath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }

    private func makeAbsoluteSignedURL(
        _ rawURL: String,
        configuration: SupabaseReferenceStorageConfiguration
    ) throws -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "https" {
            return url
        }
        let relativePath = trimmed.drop(while: { $0 == "/" })
        guard !relativePath.isEmpty,
              let url = URL(
                string: String(relativePath),
                relativeTo: try configuration.storageBaseURL.appendingPathComponent("", isDirectory: true)
              )?.absoluteURL,
              url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }

    private static func apiErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "未知错误"
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        return "未知错误"
    }
}
