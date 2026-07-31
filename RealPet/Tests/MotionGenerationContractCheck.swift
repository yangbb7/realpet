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
        try testDefaultMouseInteractionPrompts()
        try testAgnesReferenceAndMiniMaxRequests()
        try await testAgnesReferenceAndMiniMaxPipelineCreatePollAndDownload()
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
        precondition(motionConfiguration.resolvedAgnesBaseURLString
                     == "https://apihub.agnes-ai.com/v1")
        precondition(motionConfiguration.imageModel == "agnes-image-2.0-flash")
        precondition(motionConfiguration.resolvedMiniMaxBaseURLString
                     == "https://api.minimaxi.com")
        precondition(motionConfiguration.videoModel == "MiniMax-H3")
        precondition(motionConfiguration.seconds == 4)
        let validatedMotionConfiguration = try motionConfiguration.validated()
        let agnesConfiguration = try validatedMotionConfiguration
            .validatedAgnesAPIConfiguration()
        let miniMaxConfiguration = try validatedMotionConfiguration
            .validatedMiniMaxAPIConfiguration()
        precondition(validatedMotionConfiguration.size == "1152x768")
        precondition(agnesConfiguration.isAgnesAPI)
        precondition(miniMaxConfiguration.isOfficialAPI)

        let savedAgnesVideoConfiguration = MotionServiceConfiguration(
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

        var gazeManifest = manifest
        for kind in PetActionManifest.Action.Kind.gazeCapture {
            let gazeSource = root.appendingPathComponent("source-\(kind.rawValue)")
            try fm.createDirectory(at: gazeSource, withIntermediateDirectories: true)
            try Data("frame".utf8).write(
                to: gazeSource.appendingPathComponent("frame_0000.png"))
            gazeManifest = try PetActionLibrary.install(
                kind: kind,
                processedFramesDirectory: gazeSource,
                rootFramesDirectory: root,
                fps: 10,
                origin: .generated)
            let generatedGaze = gazeManifest.actions.first(where: { $0.kind == kind })
            precondition(generatedGaze?.effectiveOrigin == .generated)
            precondition(generatedGaze?.loop == false)
        }
        precondition(gazeManifest.capabilities.orientation)
    }

    private static func testDefaultMouseInteractionPrompts() throws {
        let tracking = DefaultMouseInteractionScenario.pointerTracking
        precondition(tracking.actionPlans.map(\.kind) == [
            .gazeLeft, .gazeRight, .gazeUp, .gazeDown,
        ])
        precondition(tracking.actionPlans.allSatisfy { plan in
            plan.prompt.contains("首帧中的同一只宠物")
                && plan.prompt.contains("先")
                && plan.prompt.contains("随后")
                && plan.prompt.contains("最后")
                && plan.prompt.contains("镜头固定稳定")
                && plan.prompt.contains("真实摄影质感")
        })
        let bounce = DefaultMouseInteractionScenario.clickBounce
        precondition(bounce.actionPlans.map(\.kind) == [.play])
        precondition(bounce.debugPrompt.contains("原地轻快蹦跳两次"))
        precondition(bounce.debugPrompt.contains("首帧中的同一只宠物"))
        precondition(PetActionManifest.Action.Kind.defaultMouseInteraction == [
            .gazeLeft, .gazeRight, .gazeUp, .gazeDown, .play,
        ])
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

    private static func testAgnesReferenceAndMiniMaxPipelineCreatePollAndDownload() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-agnes-pipeline-reference.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: temporary)
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
        let reference = try await AgnesImageReferenceGenerator(session: session).generateReference(
            referenceImageURLs: [temporary],
            apiKey: "agnes-key",
            configuration: agnesAPIConfiguration,
            model: "agnes-image-2.0-flash")
        precondition(reference.absoluteString == "https://cdn.example.com/pet-anchor.png")

        let client = MiniMaxH3VideoGenerationClient(session: session)
        let queued = try await client.create(
            prompt: DefaultMouseInteractionScenario.clickBounce.actionPlans[0].prompt,
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
