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
                throw MiniMaxH3VideoGenerationError.invalidResponse
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
        try testAgnesReferenceAndMiniMaxRequests()
        try await testAgnesReferenceAndMiniMaxPipelineCreatePollAndDownload()
        try await testPromptOptimizationRequestAndResponse()
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
        precondition(motionConfiguration.resolvedMiniMaxBaseURLString
                     == "https://api.minimaxi.com")
        precondition(motionConfiguration.videoModel == "MiniMax-H3")
        precondition(motionConfiguration.seconds == 4)
        let validatedMotionConfiguration = try motionConfiguration.validated()
        let promptConfiguration = try validatedMotionConfiguration
            .validatedPromptAPIConfiguration()
        let agnesConfiguration = try validatedMotionConfiguration
            .validatedAgnesAPIConfiguration()
        let miniMaxConfiguration = try validatedMotionConfiguration
            .validatedMiniMaxAPIConfiguration()
        precondition(validatedMotionConfiguration.size == "1152x768")
        precondition(!promptConfiguration.isAgnesAPI)
        precondition(agnesConfiguration.isAgnesAPI)
        precondition(miniMaxConfiguration.isOfficialAPI)

        let savedAgnesVideoConfiguration = MotionServiceConfiguration(
            baseURLString: OpenAIImageAPIConfiguration.defaultBaseURLString,
            promptModel: "gpt-5.6-sol",
            agnesBaseURLString: "https://apihub.agnes-ai.com/v1",
            imageModel: "agnes-image-2.0-flash",
            videoModel: "agnes-video-v2.0",
            seconds: 4,
            size: "1152x768")
        precondition(savedAgnesVideoConfiguration.migratedToMiniMaxH3().videoModel
                     == "MiniMax-H3")

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

    private static func testAgnesReferenceAndMiniMaxRequests() throws {
        let reference = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-agnes-reference.png")
        defer { try? FileManager.default.removeItem(at: reference) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: reference)
        let configuration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://apihub.agnes-ai.com/v1")
        precondition(configuration.isAgnesAPI)
        precondition(configuration.chatCompletionsURL.absoluteString
                     == "https://apihub.agnes-ai.com/v1/chat/completions")

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
        let miniMaxConfiguration = try MiniMaxVideoAPIConfiguration(
            baseURLString: "https://api.minimaxi.com")
        precondition(miniMaxConfiguration.createURL.absoluteString
                     == "https://api.minimaxi.com/v2/video_generation")
        precondition(miniMaxConfiguration.queryURL(taskID: "task_1").absoluteString
                     == "https://api.minimaxi.com/v2/query/video_generation/task_1")
        let videoRequest = try MiniMaxH3VideoGenerationClient.makeCreateRequest(
            prompt: "纯白色背景，固定镜头，小狗在原地转一圈。",
            firstFrameURL: URL(string: "https://cdn.example.com/pet.png")!,
            apiKey: "minimax-key",
            configuration: miniMaxConfiguration,
            seconds: 4)
        let videoBody = try JSONSerialization.jsonObject(
            with: videoRequest.httpBody ?? Data()) as? [String: Any]
        precondition(videoRequest.value(forHTTPHeaderField: "Authorization")
                     == "Bearer minimax-key")
        precondition(videoBody?["model"] as? String == "MiniMax-H3")
        precondition(videoBody?["resolution"] as? String == "2K")
        precondition(videoBody?["duration"] as? Int == 4)
        precondition(videoBody?["ratio"] as? String == "adaptive")
        let content = videoBody?["content"] as? [[String: Any]]
        precondition(content?.first?["type"] as? String == "text")
        precondition(content?.last?["type"] as? String == "image_url")
        precondition((content?.last?["image_url"] as? [String: Any])?["url"] as? String
                     == "https://cdn.example.com/pet.png")
        precondition(content?.last?["role"] as? String == "first_frame")
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
        let instructions = body?["instructions"] as? String
        precondition(instructions?.contains("MiniMax H3 image-to-video") == true)
        precondition(instructions?.contains("ordered timeline") == true)
        precondition(instructions?.contains("camera is fixed and stable") == true)
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
            {"optimized_prompt":"首帧中的同一只白色小狗位于纯白无缝背景的全身中景中，先自然站稳，随后在原地平稳转一圈，最后回到面向镜头的站姿并短暂停留。镜头固定稳定，柔和均匀的棚拍光线，毛发和身体运动自然写实。","pet_description":"白色小狗","warnings":[]}
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
        precondition(result.optimizedPrompt.contains("镜头固定稳定"))
    }

    private static func testAgnesReferenceAndMiniMaxPipelineCreatePollAndDownload() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-agnes-pipeline-reference.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: temporary)
        let promptAPIConfiguration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://relay.example.com/v1")
        let agnesAPIConfiguration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://apihub.agnes-ai.com/v1")
        let miniMaxAPIConfiguration = try MiniMaxVideoAPIConfiguration(
            baseURLString: "https://api.minimaxi.com")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MotionMockURLProtocol.self]
        MotionMockURLProtocol.handler = { request in
            if request.url?.host == "apihub.agnes-ai.com" {
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer agnes-key")
            } else if request.url?.host == "relay.example.com" {
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer prompt-key")
            } else if request.url?.host == "api.minimaxi.com" {
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer minimax-key")
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
            case ("POST", "api.minimaxi.com", "/v2/video_generation"):
                return (response, try JSONSerialization.data(withJSONObject: [
                    "task_id": "task_1",
                ]))
            case ("GET", "api.minimaxi.com", "/v2/query/video_generation/task_1"):
                return (response, try JSONSerialization.data(withJSONObject: [
                    "task": [
                        "id": "task_1",
                        "status": "succeeded",
                        "content": ["url": "https://cdn.example.com/generated.mp4"],
                    ],
                ]))
            case ("GET", "cdn.example.com", "/generated.mp4"):
                return (response, Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]))
            default:
                preconditionFailure("Unexpected motion request: \(request.url?.absoluteString ?? "nil")")
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

        let client = MiniMaxH3VideoGenerationClient(session: session)
        let queued = try await client.create(
            prompt: prompt.optimizedPrompt,
            firstFrameURL: reference,
            apiKey: "minimax-key",
            configuration: miniMaxAPIConfiguration,
            seconds: 4)
        precondition(queued.status == .queued)
        let completed = try await client.retrieve(
            id: queued.id, apiKey: "minimax-key", configuration: miniMaxAPIConfiguration)
        precondition(completed.status == .completed)
        let video = try await client.downloadContent(job: completed)
        precondition(video.count == 8)
    }

}
