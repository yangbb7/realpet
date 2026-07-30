import Foundation

private final class MotionMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw OpenAIVideoGenerationError.invalidResponse
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
struct MotionGenerationContractCheck {
    static func main() async throws {
        try testConfigurationAndGeneratedActionCapability()
        try testAgnesReferenceAndVideoRequests()
        try await testAgnesPipelineCreatePollAndDownload()
        try await testPromptOptimizationRequestAndResponse()
        try await testVideoCreatePollAndDownload()
        print("Motion generation contract checks passed")
    }

    private static func testConfigurationAndGeneratedActionCapability() throws {
        let configuration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://relay.example.com/openai/v1/videos")
        precondition(configuration.normalizedBaseURLString
                     == "https://relay.example.com/openai/v1")
        precondition(configuration.responsesURL.absoluteString
                     == "https://relay.example.com/openai/v1/responses")
        precondition(configuration.videosURL.absoluteString
                     == "https://relay.example.com/openai/v1/videos")
        precondition(configuration.videoContentURL(id: "video_1").absoluteString
                     == "https://relay.example.com/openai/v1/videos/video_1/content")

        let motionConfiguration = MotionServiceConfiguration.defaultValue
        precondition(motionConfiguration.baseURLString
                     == OpenAIImageAPIConfiguration.defaultBaseURLString)
        precondition(motionConfiguration.promptModel == "gpt-5.6-sol")
        precondition(motionConfiguration.resolvedAgnesBaseURLString
                     == "https://apihub.agnes-ai.com/v1")
        precondition(motionConfiguration.imageModel == "agnes-image-2.0-flash")
        precondition(motionConfiguration.videoModel == "agnes-video-v2.0")
        precondition(motionConfiguration.seconds == 4)
        let validatedMotionConfiguration = try motionConfiguration.validated()
        let promptConfiguration = try validatedMotionConfiguration
            .validatedPromptAPIConfiguration()
        let agnesConfiguration = try validatedMotionConfiguration
            .validatedAgnesAPIConfiguration()
        precondition(validatedMotionConfiguration.size == "1152x768")
        precondition(!promptConfiguration.isAgnesAPI)
        precondition(agnesConfiguration.isAgnesAPI)

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "realpet-generated-action-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: source.appendingPathComponent("frame_0000.png"))
        let manifest = try PetActionLibrary.install(
            kind: .paw,
            processedFramesDirectory: source,
            rootFramesDirectory: root,
            fps: 10,
            origin: .generated)
        precondition(manifest.actions.first(where: { $0.kind == .paw })?.effectiveOrigin
                     == .generated)
        precondition(manifest.capabilities.reaction)
        precondition(manifest.supports(animation: .paw))
    }

    private static func testAgnesReferenceAndVideoRequests() throws {
        let reference = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-agnes-reference.png")
        defer { try? FileManager.default.removeItem(at: reference) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: reference)
        let configuration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://apihub.agnes-ai.com/v1")
        precondition(configuration.isAgnesAPI)
        precondition(configuration.chatCompletionsURL.absoluteString
                     == "https://apihub.agnes-ai.com/v1/chat/completions")
        precondition(configuration.agnesVideoResultURL.absoluteString
                     == "https://apihub.agnes-ai.com/agnesapi")

        let imageRequest = try AgnesImageReferenceGenerator.makeRequest(
            referenceImageURLs: [reference, reference],
            apiKey: "agnes-key",
            configuration: configuration,
            model: "agnes-image-2.0-flash")
        precondition(imageRequest.url?.path == "/v1/images/generations")
        let imageBody = try JSONSerialization.jsonObject(
            with: imageRequest.httpBody ?? Data()) as? [String: Any]
        let extraBody = imageBody?["extra_body"] as? [String: Any]
        precondition((extraBody?["image"] as? [String])?.count == 2)
        precondition(extraBody?["response_format"] as? String == "url")

        let chatRequest = try OpenAIPetPromptOptimizer.makeAgnesRequest(
            naturalLanguage: "让它转一圈",
            remoteReferenceImageURLs: [URL(string: "https://cdn.example.com/pet.png")!],
            apiKey: "agnes-key",
            configuration: configuration,
            model: "agnes-2.0-flash")
        precondition(chatRequest.url == configuration.chatCompletionsURL)
        let videoRequest = try OpenAIVideoGenerationClient.makeAgnesCreateRequest(
            prompt: "纯白色背景，固定镜头，小狗在原地转一圈。",
            publicReferenceImageURL: URL(string: "https://cdn.example.com/pet.png")!,
            apiKey: "agnes-key",
            configuration: configuration,
            model: "agnes-video-v2.0",
            seconds: 4,
            size: "1152x768")
        let videoBody = try JSONSerialization.jsonObject(
            with: videoRequest.httpBody ?? Data()) as? [String: Any]
        precondition(videoBody?["image"] as? String == "https://cdn.example.com/pet.png")
        precondition(videoBody?["num_frames"] as? Int == 97)
        precondition(videoBody?["frame_rate"] as? Int == 24)
    }

    private static func testPromptOptimizationRequestAndResponse() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-motion-reference.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: temporary)
        let apiConfiguration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://relay.example.com/v1")
        let request = try OpenAIPetPromptOptimizer.makeRequest(
            naturalLanguage: "让它慢慢转一圈",
            referenceImageURLs: [temporary, temporary],
            apiKey: "test-key",
            configuration: apiConfiguration,
            model: "gpt-5.6-sol")
        precondition(request.url == apiConfiguration.responsesURL)
        precondition(request.value(forHTTPHeaderField: "Authorization")
                     == "Bearer test-key")
        let body = try JSONSerialization.jsonObject(
            with: request.httpBody ?? Data()) as? [String: Any]
        precondition(body?["model"] as? String == "gpt-5.6-sol")
        let input = body?["input"] as? [[String: Any]]
        let content = input?.first?["content"] as? [[String: Any]]
        precondition(content?.filter { $0["type"] as? String == "input_image" }.count == 2)
        let text = body?["text"] as? [String: Any]
        let format = text?["format"] as? [String: Any]
        precondition(format?["type"] as? String == "json_schema")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MotionMockURLProtocol.self]
        MotionMockURLProtocol.handler = { received in
            precondition(received.url == apiConfiguration.responsesURL)
            let response = HTTPURLResponse(
                url: received.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            let output = """
            {"optimized_prompt":"纯白色背景，固定镜头，同一只小狗在原地匀速转一圈。","pet_description":"白色小狗","warnings":[]}
            """
            let payload = try JSONSerialization.data(withJSONObject: [
                "output_text": output,
            ])
            return (response, payload)
        }
        let result = try await OpenAIPetPromptOptimizer(
            session: URLSession(configuration: sessionConfiguration)).optimize(
                naturalLanguage: "让它慢慢转一圈",
                referenceImageURLs: [temporary],
                apiKey: "test-key",
                configuration: apiConfiguration,
                model: "gpt-5.6-sol")
        precondition(result.petDescription == "白色小狗")
        precondition(result.optimizedPrompt.contains("固定镜头"))
    }

    private static func testAgnesPipelineCreatePollAndDownload() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-agnes-pipeline-reference.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: temporary)
        let promptAPIConfiguration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://relay.example.com/v1")
        let agnesAPIConfiguration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://apihub.agnes-ai.com/v1")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MotionMockURLProtocol.self]
        MotionMockURLProtocol.handler = { request in
            if request.url?.host == "apihub.agnes-ai.com" {
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer agnes-key")
            } else if request.url?.host == "relay.example.com" {
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer prompt-key")
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            switch (request.httpMethod, request.url?.host, request.url?.path) {
            case ("POST", "apihub.agnes-ai.com", "/v1/images/generations"):
                return (response, try JSONSerialization.data(withJSONObject: [
                    "data": [["url": "https://cdn.example.com/pet-anchor.png"]],
                ]))
            case ("POST", "relay.example.com", "/v1/responses"):
                let output = """
                {"optimized_prompt":"纯白背景，固定镜头，同一只宠物抬起前爪。","pet_description":"棕白小狗","warnings":[]}
                """
                return (response, try JSONSerialization.data(withJSONObject: [
                    "output_text": output,
                ]))
            case ("POST", "apihub.agnes-ai.com", "/v1/videos"):
                return (response, try JSONSerialization.data(withJSONObject: [
                    "result": ["task": [
                        "task_id": "task_1", "video_id": "video_1", "state": "submitted",
                    ]],
                ]))
            case ("GET", "apihub.agnes-ai.com", "/agnesapi"):
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems
                precondition(items?.first(where: { $0.name == "video_id" })?.value == "video_1")
                precondition(items?.first(where: { $0.name == "model_name" })?.value
                             == "agnes-video-v2.0")
                return (response, try JSONSerialization.data(withJSONObject: [
                    "task_id": "task_1",
                    "video_id": "video_1",
                    "status": "completed",
                    "metadata": ["url": "https://cdn.example.com/generated.mp4"],
                ]))
            case ("GET", "cdn.example.com", "/generated.mp4"):
                return (response, Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]))
            default:
                preconditionFailure("Unexpected Agnes request: \(request.url?.absoluteString ?? "nil")")
            }
        }

        let session = URLSession(configuration: sessionConfiguration)
        let prompt = try await OpenAIPetPromptOptimizer(session: session).optimize(
            naturalLanguage: "抬起前爪",
            referenceImageURLs: [temporary],
            apiKey: "prompt-key",
            configuration: promptAPIConfiguration,
            model: "gpt-5.6-sol")
        precondition(prompt.petDescription == "棕白小狗")

        let reference = try await AgnesImageReferenceGenerator(session: session).generateReference(
            referenceImageURLs: [temporary],
            apiKey: "agnes-key",
            configuration: agnesAPIConfiguration,
            model: "agnes-image-2.0-flash")
        precondition(reference.absoluteString == "https://cdn.example.com/pet-anchor.png")

        let client = OpenAIVideoGenerationClient(session: session)
        let queued = try await client.create(
            prompt: prompt.optimizedPrompt,
            referenceImageURL: reference,
            apiKey: "agnes-key",
            configuration: agnesAPIConfiguration,
            model: "agnes-video-v2.0",
            seconds: 4,
            size: "1152x768")
        precondition(queued.provider == .agnes && queued.videoID == "video_1")
        let completed = try await client.retrieve(
            job: queued, apiKey: "agnes-key", configuration: agnesAPIConfiguration)
        precondition(completed.status == .completed)
        let video = try await client.downloadContent(
            job: completed, apiKey: "agnes-key", configuration: agnesAPIConfiguration)
        precondition(video.count == 8)
    }

    private static func testVideoCreatePollAndDownload() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-motion-video-reference.jpg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data([0xff, 0xd8, 0xff]).write(to: temporary)
        let apiConfiguration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://relay.example.com/v1")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MotionMockURLProtocol.self]
        let builtRequest = try OpenAIVideoGenerationClient.makeCreateRequest(
            prompt: "纯白色背景，固定镜头，同一只小狗在原地转一圈。",
            referenceImageURL: temporary,
            apiKey: "test-key",
            configuration: apiConfiguration,
            model: "sora-2",
            seconds: 4,
            size: "1280x720")
        let builtBody = String(
            decoding: builtRequest.httpBody ?? Data(), as: UTF8.self)
        precondition(builtBody.contains("name=\"model\"\r\n\r\nsora-2"))
        precondition(builtBody.contains("name=\"input_reference\""))
        var retrieveCount = 0
        MotionMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/videos"):
                return (response, try JSONSerialization.data(withJSONObject: [
                    "id": "video_1", "status": "queued",
                ]))
            case ("GET", "/v1/videos/video_1"):
                retrieveCount += 1
                return (response, try JSONSerialization.data(withJSONObject: [
                    "id": "video_1",
                    "status": retrieveCount == 1 ? "processing" : "completed",
                    "progress": retrieveCount == 1 ? 50 : 100,
                ]))
            case ("GET", "/v1/videos/video_1/content"):
                return (response, Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]))
            default:
                preconditionFailure("Unexpected motion request: \(request.url?.absoluteString ?? "nil")")
            }
        }
        let client = OpenAIVideoGenerationClient(
            session: URLSession(configuration: sessionConfiguration))
        let queued = try await client.create(
            prompt: "纯白色背景，固定镜头，同一只小狗在原地转一圈。",
            referenceImageURL: temporary,
            apiKey: "test-key",
            configuration: apiConfiguration,
            model: "sora-2",
            seconds: 4,
            size: "1280x720")
        precondition(queued.status == .queued)
        let processing = try await client.retrieve(
            id: queued.id, apiKey: "test-key", configuration: apiConfiguration)
        precondition(processing.status == .processing && processing.progress == 50)
        let completed = try await client.retrieve(
            id: queued.id, apiKey: "test-key", configuration: apiConfiguration)
        precondition(completed.status == .completed)
        let video = try await client.downloadContent(
            id: queued.id, apiKey: "test-key", configuration: apiConfiguration)
        precondition(video.count == 8)
    }
}
