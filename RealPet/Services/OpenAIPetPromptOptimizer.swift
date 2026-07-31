import Foundation

enum PetPromptOptimizationError: LocalizedError, Equatable {
    case invalidAPIKey
    case missingReferenceImages
    case invalidReferenceImage
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "动作服务凭据无效"
        case .missingReferenceImages: return "请先导入至少一张宠物照片"
        case .invalidReferenceImage: return "宠物参考图无法读取"
        case .invalidResponse: return "提示词模型没有返回有效的优化结果"
        case .requestFailed(let status, let message):
            return "提示词优化失败（HTTP \(status)）：\(message)"
        }
    }
}

struct OpenAIPetPromptOptimizer {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 180
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func optimize(
        naturalLanguage: String,
        referenceImageURLs: [URL],
        remoteReferenceImageURLs: [URL] = [],
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String
    ) async throws -> PetMotionPromptOptimization {
        let request: URLRequest
        if configuration.isAgnesAPI {
            request = try Self.makeAgnesRequest(
                naturalLanguage: naturalLanguage,
                remoteReferenceImageURLs: remoteReferenceImageURLs,
                apiKey: apiKey,
                configuration: configuration,
                model: model)
        } else {
            request = try Self.makeRequest(
                naturalLanguage: naturalLanguage,
                referenceImageURLs: referenceImageURLs,
                remoteReferenceImageURLs: remoteReferenceImageURLs,
                apiKey: apiKey,
                configuration: configuration,
                model: model)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PetPromptOptimizationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw PetPromptOptimizationError.invalidAPIKey }
            throw PetPromptOptimizationError.requestFailed(
                status: http.statusCode,
                message: Self.apiErrorMessage(from: data) ?? "未知错误")
        }
        guard let responseText = Self.responseText(
            from: data, isAgnes: configuration.isAgnesAPI),
              let result = try? JSONDecoder().decode(
                PetMotionPromptOptimization.self,
                from: Data(responseText.utf8)),
              !result.optimizedPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty else {
            throw PetPromptOptimizationError.invalidResponse
        }
        return result
    }

    static func makeRequest(
        naturalLanguage: String,
        referenceImageURLs: [URL],
        remoteReferenceImageURLs: [URL] = [],
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw PetPromptOptimizationError.invalidAPIKey }
        guard !referenceImageURLs.isEmpty else {
            throw PetPromptOptimizationError.missingReferenceImages
        }
        let trimmedPrompt = naturalLanguage.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw PetPromptOptimizationError.invalidResponse
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw PetPromptOptimizationError.invalidResponse }

        var content: [[String: Any]] = [[
            "type": "input_text",
            "text": "用户的动作描述：\(trimmedPrompt)",
        ]]
        for imageURL in referenceImageURLs.prefix(6) {
            guard let image = try? PetReferenceImageData.load(from: imageURL) else {
                throw PetPromptOptimizationError.invalidReferenceImage
            }
            let dataURL = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
            content.append([
                "type": "input_image",
                "image_url": dataURL,
                "detail": "high",
            ])
        }
        for imageURL in remoteReferenceImageURLs.prefix(1) {
            guard imageURL.scheme == "https" else {
                throw PetPromptOptimizationError.invalidReferenceImage
            }
            content.append([
                "type": "input_image",
                "image_url": imageURL.absoluteString,
                "detail": "high",
            ])
        }

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "optimized_prompt": ["type": "string"],
                "pet_description": ["type": "string"],
                "warnings": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["optimized_prompt", "pet_description", "warnings"],
        ]
        let payload: [String: Any] = [
            "model": trimmedModel,
            "reasoning": ["effort": "low"],
            "instructions": Self.instructions,
            "input": [["role": "user", "content": content]],
            "text": ["format": [
                "type": "json_schema",
                "name": "pet_motion_prompt",
                "strict": true,
                "schema": schema,
            ]],
        ]
        var request = URLRequest(url: configuration.responsesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static let instructions = """
    You are the prompt director for MiniMax H3 image-to-video generation in a
    realistic desktop-pet product. Inspect every supplied owner image and infer
    one, and only one, pet identity: animal type, distinctive fur pattern and
    colors, body proportions, face, ear shape, eye color, and unique markings.
    The reference image will be the H3 first frame, so preserve that identity
    exactly and never invent another animal, breed, marking, or appearance.

    Convert the user's request into one ready-to-submit Chinese image-to-video
    prompt. Follow MiniMax's precise image-to-video structure in natural prose:
    1. Identify the same pet visible in the first frame, using only its stable
       visual traits needed to lock identity.
    2. Set the production space: a pure white seamless studio background,
       level full-body medium shot, entire pet continuously in frame.
    3. Describe one simple, physically plausible action as an ordered timeline:
       clear starting pose, one continuous main movement, then a natural ending
       pose or brief hold. Use words such as "先", "随后", and "最后" when they
       improve temporal clarity. The requested action must remain the focus.
    4. State that the camera is fixed and stable. Do not use push, pull, pan,
       tracking, zoom, rotation, cuts, or any camera movement because this video
       is converted into desktop animation frames.
    5. Finish with visual direction: photographic realism, natural anatomy and
       fur motion, soft even studio light, clean edges, and a calm natural mood.

    Keep the action feasible in a short 4 to 12 second clip. Do not introduce
    people, hands, toys, food, file icons, furniture, accessories, text,
    watermarks, extra animals, new objects, background changes, or a different
    scene. For an eating interaction, describe only the pet's mouth and head
    motion; do not invent visible food. If the user asks for a conflicting scene
    or prop, preserve the requested body action but adapt it to the white studio
    setup and explain that adaptation briefly in warnings. Do not mention owner
    photos, prompt optimization, H3, or this instruction in optimized_prompt.

    optimized_prompt must be a single polished Chinese video prompt without a
    title, list, markdown, or negative-prompt section. pet_description is a
    concise Chinese identity summary. warnings contains only concrete Chinese
    constraints or adaptations; use an empty array when none are needed. Return
    only the requested JSON schema.
    """

    static func makeAgnesRequest(
        naturalLanguage: String,
        remoteReferenceImageURLs: [URL],
        apiKey: String,
        configuration: OpenAIImageAPIConfiguration,
        model: String
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw PetPromptOptimizationError.invalidAPIKey }
        guard !remoteReferenceImageURLs.isEmpty else {
            throw PetPromptOptimizationError.missingReferenceImages
        }
        let trimmedPrompt = naturalLanguage.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw PetPromptOptimizationError.invalidResponse
        }
        var content: [[String: Any]] = [[
            "type": "text",
            "text": "用户的动作描述：\(trimmedPrompt)",
        ]]
        content += remoteReferenceImageURLs.prefix(6).map { url in
            ["type": "image_url", "image_url": ["url": url.absoluteString]]
        }
        let payload: [String: Any] = [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": Self.instructions
                    + " Return only a JSON object with optimized_prompt, pet_description, and warnings."],
                ["role": "user", "content": content],
            ],
            "temperature": 0.2,
            "max_tokens": 900,
        ]
        var request = URLRequest(url: configuration.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func responseText(from data: Data, isAgnes: Bool) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if isAgnes,
           let dictionary = object as? [String: Any],
           let choices = dictionary["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return Self.extractJSONObject(from: content) ?? content
        }
        if let dictionary = object as? [String: Any],
           let outputText = dictionary["output_text"] as? String {
            return outputText
        }
        return findText(in: object)
    }

    private static func extractJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else { return nil }
        return String(trimmed[start...end])
    }

    private static func findText(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let text = dictionary["text"] as? String,
               text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                return text
            }
            for value in dictionary.values {
                if let text = findText(in: value) { return text }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let text = findText(in: value) { return text }
            }
        }
        return nil
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        return json["message"] as? String
    }
}
