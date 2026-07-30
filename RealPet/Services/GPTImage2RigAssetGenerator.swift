import Foundation

enum RigAssetGenerationError: LocalizedError, Equatable {
    case invalidAPIKey
    case invalidReferenceImage
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "图像服务凭据无效"
        case .invalidReferenceImage:
            return "找不到可用于建模的宠物参考图"
        case .invalidResponse:
            return "图像服务没有返回有效素材"
        case .requestFailed(let status, let message):
            return "素材生成失败（HTTP \(status)）：\(message)"
        }
    }
}

struct GPTImage2RigAssetGenerator {
    static let model = "gpt-image-2"
    static let endpoint = OpenAIImageAPIConfiguration.defaultRelay.imageEditsURL

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 900
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func generateAtlas(
        referenceImageURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration = .defaultRelay,
        profile: PetTemplateProfile
    ) async throws -> Data {
        let request = try Self.makeRequest(
            referenceImageURL: referenceImageURL,
            apiKey: apiKey,
            configuration: configuration,
            prompt: Self.atlasPrompt(for: profile))
        return try await generatedImage(for: request)
    }

    func generateIsolatedTorso(
        referenceImageURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration = .defaultRelay
    ) async throws -> Data {
        let request = try Self.makeRequest(
            referenceImageURL: referenceImageURL,
            apiKey: apiKey,
            configuration: configuration,
            prompt: Self.isolatedTorsoPrompt,
            size: "1024x1024")
        return try await generatedImage(for: request)
    }

    private func generatedImage(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RigAssetGenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.apiErrorMessage(from: data) ?? "未知错误"
            if http.statusCode == 401 {
                throw RigAssetGenerationError.invalidAPIKey
            }
            throw RigAssetGenerationError.requestFailed(
                status: http.statusCode, message: message)
        }

        struct ImageResponse: Decodable {
            struct Item: Decodable { let b64_json: String }
            let data: [Item]
        }
        guard let payload = try? JSONDecoder().decode(ImageResponse.self, from: data),
              let encoded = payload.data.first?.b64_json,
              let image = Data(base64Encoded: encoded),
              !image.isEmpty else {
            throw RigAssetGenerationError.invalidResponse
        }
        return image
    }

    static func makeRequest(
        referenceImageURL: URL,
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration = .defaultRelay,
        prompt: String = atlasPrompt,
        size: String = "2048x2048"
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw RigAssetGenerationError.invalidAPIKey
        }
        guard let reference = try? Data(contentsOf: referenceImageURL),
              !reference.isEmpty else {
            throw RigAssetGenerationError.invalidReferenceImage
        }

        var request = URLRequest(url: configuration.imageEditsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        let boundary = "RealPet-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            reference: reference,
            filename: referenceImageURL.lastPathComponent,
            prompt: prompt,
            size: size)

        return request
    }

    static let atlasPrompt = """
    Image 1 is the identity and anatomy reference for a rigged desktop pet.
    Create one square technical character-part atlas on a perfectly uniform,
    opaque #00FF00 chroma-key background. Preserve the exact pet identity, fur
    colors, eye color, nose color, proportions, and photographic realism.

    Arrange exactly twenty isolated components in a 5-column by 4-row grid with
    equal cells, generous padding, and no overlap. Row 1: front-facing head base
    without ears, eyes, muzzle, or nose; muzzle without nose or mouth; nose;
    closed mouth; tongue. Row 2: left eye; right eye; left ear; right ear; torso
    without head, legs, chest overlay, or tail. Row 3: chest fur overlay; tail;
    left front upper leg; left front lower leg with paw; right front upper leg.
    Row 4: right front lower leg with paw; left hind upper leg; left hind lower
    leg with paw; right hind upper leg; right hind lower leg with paw. Use the
    animal's anatomical left and right. Every component must be fully visible,
    centered in its cell, and reconstructed through normally occluded attachment
    areas so it can rotate and deform independently.

    The background must be one flat #00FF00 color with no shadows, gradients,
    floor, texture, reflections, or lighting variation. Do not use #00FF00 in
    any pet component. No text, labels, grid lines, accessories, duplicate
    parts, extra body parts, or watermark.
    """

    static func atlasPrompt(for profile: PetTemplateProfile) -> String {
        atlasPrompt + "\n\nTemplate morphology constraint: "
            + profile.atlasPromptGuidance
    }

    static let isolatedTorsoPrompt = """
    Image 1 is the identity and anatomy reference for a rigged desktop pet.
    Create exactly one isolated front-facing core torso body mass for this same
    dog on a perfectly uniform opaque #00FF00 chroma-key background. Preserve
    the exact white and pale-cream fur colors, density, texture, photographic
    realism, chest width, belly shape, and compact Pomeranian proportions.

    The output must contain the torso only: no head, neck ruff, eyes, ears,
    muzzle, nose, mouth, tongue, legs, leg stumps, paws, hips that resemble
    detached legs, or tail. Reconstruct the normally hidden shoulder and hip
    attachment areas beneath the fur so four independent limb layers can be
    attached later. Center the complete torso with generous empty padding.

    The background must be one flat #00FF00 color with no shadows, gradients,
    floor, texture, reflections, or lighting variation. Do not use #00FF00 in
    the dog. No text, labels, grid lines, accessories, extra objects, or
    watermark.
    """

    private static func multipartBody(
        boundary: String,
        reference: Data,
        filename: String,
        prompt: String,
        size: String
    ) -> Data {
        var body = Data()
        func append(_ value: String) {
            body.append(Data(value.utf8))
        }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        field("model", model)
        field("prompt", prompt)
        field("size", size)
        field("quality", "medium")
        field("background", "opaque")
        field("output_format", "png")

        let mime = filename.lowercased().hasSuffix(".jpg")
            || filename.lowercased().hasSuffix(".jpeg")
            ? "image/jpeg" : "image/png"
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image[]\"; filename=\"reference.\(mime == "image/jpeg" ? "jpg" : "png")\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(reference)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return nil
        }
        return error["message"] as? String
    }
}
