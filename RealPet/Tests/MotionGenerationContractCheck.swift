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
                throw AgnesVideoGenerationError.invalidResponse
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
        try testFixedActionCatalog()
        testGeneratedMotionTrackMatteInvocation()
        try testSupabaseOriginalReferenceAndVideoRequests()
        try await testSupabaseGoogleSessionAuthorization()
        try await testProviderPipelinesCreatePollAndDownload()
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

        let motionConfiguration = MotionServiceConfiguration.defaultValue
        precondition(motionConfiguration.provider == .agnes)
        precondition(motionConfiguration.resolvedAgnesBaseURLString
                     == "https://api.agnes-ai.cn/v1")
        precondition(motionConfiguration.videoModel == "agnes-video-v2.0")
        precondition(motionConfiguration.seconds == 4)
        let ignoredAgnesEndpoint = MotionServiceConfiguration(
            provider: .agnes,
            agnesBaseURLString: "https://not-agnes.example.com/v1",
            videoModel: "agnes-video-v2.0",
            seconds: 4,
            size: "1152x768").migratedToSupportedProviders()
        precondition(ignoredAgnesEndpoint.resolvedAgnesBaseURLString
                     == "https://api.agnes-ai.cn/v1")
        let validatedMotionConfiguration = try motionConfiguration.validated()
        let agnesConfiguration = try validatedMotionConfiguration
            .validatedAgnesAPIConfiguration()
        precondition(validatedMotionConfiguration.size == "1152x768")
        precondition(agnesConfiguration.isAgnesAPI)
        let requestSettings = AgnesVideoGenerationRequestSettings(
            size: validatedMotionConfiguration.size,
            seconds: validatedMotionConfiguration.seconds)
        precondition(requestSettings?.numFrames == 97)
        precondition(requestSettings?.frameRate == 24)

        let savedMiniMaxConfiguration = MotionServiceConfiguration(
            provider: .miniMaxH3,
            agnesBaseURLString: "https://api.agnes-ai.cn/v1",
            miniMaxBaseURLString: "https://api.minimaxi.com",
            videoModel: "MiniMax-H3",
            seconds: 4,
            size: "1152x768")
        let migratedMiniMax = savedMiniMaxConfiguration.migratedToSupportedProviders()
        precondition(migratedMiniMax.provider == .miniMaxH3)
        precondition(migratedMiniMax.videoModel == "MiniMax-H3")
        _ = try migratedMiniMax.validated()

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "realpet-generated-action-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: source.appendingPathComponent("frame_0000.png"))
        let manifest = try PetActionLibrary.install(
            kind: .cry,
            processedFramesDirectory: source,
            rootFramesDirectory: root,
            fps: 10,
            origin: .generated)
        precondition(manifest.actions.first(where: { $0.kind == .cry })?.effectiveOrigin
                     == .generated)
        precondition(manifest.capabilities.reaction)

        let customSource = root.appendingPathComponent("source-custom")
        try fm.createDirectory(at: customSource, withIntermediateDirectories: true)
        try Data("custom-frame".utf8).write(
            to: customSource.appendingPathComponent("frame_0000.png"))
        let customID = "custom-tail-wag"
        let customManifest = try PetActionLibrary.install(
            kind: .custom,
            processedFramesDirectory: customSource,
            rootFramesDirectory: root,
            fps: 12,
            origin: .captured,
            actionID: customID,
            displayNameOverride: "开心摇尾巴")
        let customAction = customManifest.actions.first(where: { $0.id == customID })
        precondition(customAction?.isCustom == true)
        precondition(customAction?.displayName == "开心摇尾巴")
        precondition(customAction?.framesDirectory == "actions/\(customID)")
        precondition(fm.fileExists(atPath: root
            .appendingPathComponent("actions/\(customID)/frame_0000.png").path))
        let afterCustomDeletion = try PetActionLibrary.removeCustomAction(
            id: customID, rootFramesDirectory: root)
        precondition(!afterCustomDeletion.actions.contains(where: { $0.id == customID }))
        precondition(afterCustomDeletion.actions.contains(where: { $0.kind == .cry }))
        precondition(!fm.fileExists(atPath: root
            .appendingPathComponent("actions/\(customID)").path))

        let orbitSource = root.appendingPathComponent("source-gaze-orbit")
        try fm.createDirectory(at: orbitSource, withIntermediateDirectories: true)
        try Data("frame".utf8).write(
            to: orbitSource.appendingPathComponent("frame_0000.png"))
        let orbitManifest = try PetActionLibrary.install(
            kind: .gazeOrbit,
            processedFramesDirectory: orbitSource,
            rootFramesDirectory: root,
            fps: 10,
            origin: .generated)
        let generatedOrbit = orbitManifest.actions.first(where: { $0.kind == .gazeOrbit })
        precondition(generatedOrbit?.effectiveOrigin == .generated)
        precondition(generatedOrbit?.loop == false)
        precondition(orbitManifest.capabilities.orientation)

        let pawSource = root.appendingPathComponent("source-paw")
        try fm.createDirectory(at: pawSource, withIntermediateDirectories: true)
        try Data("frame".utf8).write(
            to: pawSource.appendingPathComponent("frame_0000.png"))
        let pawManifest = try PetActionLibrary.install(
            kind: .paw, processedFramesDirectory: pawSource,
            rootFramesDirectory: root, fps: 10, origin: .generated)
        precondition(pawManifest.actions.first(where: { $0.kind == .paw })?.effectiveOrigin
                     == .generated)
        precondition(pawManifest.capabilities.reaction)

        let recoveryRoot = root.appendingPathComponent("transaction-recovery")
        let recoveryActions = recoveryRoot.appendingPathComponent("actions")
        let recoveryDestination = recoveryActions.appendingPathComponent("paw")
        let recoveryBackup = recoveryActions.appendingPathComponent(".paw-backup-test")
        try fm.createDirectory(at: recoveryDestination, withIntermediateDirectories: true)
        try fm.createDirectory(at: recoveryBackup, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: recoveryDestination.appendingPathComponent("frame_0000.png"))
        try Data("old".utf8).write(to: recoveryBackup.appendingPathComponent("frame_0000.png"))
        try PetActionManifest(
            version: PetActionManifest.currentVersion,
            defaultAction: "idle",
            actions: [.init(
                id: "idle", kind: .idle, framesDirectory: ".", fps: 10,
                loop: true, translatesWindow: false)]).save(framesDirectory: recoveryRoot.path)
        let journal = recoveryActions.appendingPathComponent(".install-transaction.json")
        try JSONSerialization.data(withJSONObject: [
            "actionID": "paw",
            "destinationName": "paw",
            "backupName": ".paw-backup-test",
            "hadExistingDestination": true,
            "phase": "destinationMoved",
        ]).write(to: journal, options: .atomic)
        try PetActionLibrary.recoverInterruptedInstall(rootFramesDirectory: recoveryRoot)
        let restoredFrame = try Data(contentsOf: recoveryDestination
            .appendingPathComponent("frame_0000.png"))
        precondition(restoredFrame == Data("old".utf8))
        precondition(!fm.fileExists(atPath: journal.path))

        try fm.removeItem(at: recoveryDestination)
        try fm.createDirectory(at: recoveryDestination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: recoveryDestination.appendingPathComponent("frame_0000.png"))
        try PetActionManifest(
            version: PetActionManifest.currentVersion,
            defaultAction: "idle",
            actions: [
                .init(id: "idle", kind: .idle, framesDirectory: ".", fps: 10,
                      loop: true, translatesWindow: false),
                .init(id: "paw", kind: .paw, framesDirectory: "actions/paw", fps: 10,
                      loop: false, translatesWindow: false),
            ]).save(framesDirectory: recoveryRoot.path)
        try JSONSerialization.data(withJSONObject: [
            "actionID": "paw",
            "destinationName": "paw",
            "backupName": ".paw-backup-test",
            "hadExistingDestination": true,
            "phase": "destinationMoved",
        ]).write(to: journal, options: .atomic)
        try PetActionLibrary.recoverInterruptedInstall(rootFramesDirectory: recoveryRoot)
        let committedFrame = try Data(contentsOf: recoveryDestination
            .appendingPathComponent("frame_0000.png"))
        precondition(committedFrame == Data("new".utf8))
        precondition(!fm.fileExists(atPath: recoveryBackup.path))

    }

    private static func testFixedActionCatalog() throws {
        precondition(GeneratedMotionProcessingPolicy
            .bypassesRecordedFootageQualityGate(
                actionOrigin: .generated, isInitialGeneratedPet: false))
        precondition(GeneratedMotionProcessingPolicy
            .bypassesRecordedFootageQualityGate(
                actionOrigin: nil, isInitialGeneratedPet: true))
        precondition(!GeneratedMotionProcessingPolicy
            .bypassesRecordedFootageQualityGate(
                actionOrigin: .captured, isInitialGeneratedPet: false))
        precondition(FixedPetAction.allCases.count == 12)
        precondition(PetImageLibraryPolicy.accepts(existingCount: 0, incomingCount: 1))
        precondition(PetImageLibraryPolicy.accepts(existingCount: 2, incomingCount: 2))
        precondition(!PetImageLibraryPolicy.accepts(existingCount: 4, incomingCount: 1))
        precondition(!PetImageLibraryPolicy.accepts(existingCount: 3, incomingCount: 2))
        precondition(FixedPetAction.headFollow.kind == .gazeOrbit)
        precondition(!FixedPetAction.headFollow.requiresExistingBaseFrames)
        precondition(FixedPetAction.tapActions.count == 11)
        precondition(FixedPetAction.tapActions.allSatisfy { $0.requiresExistingBaseFrames })
        precondition(FixedPetAction.allCases.allSatisfy { $0.minimumVideoSeconds == 4 })
        precondition(FixedPetAction.headFollow.prompt(
            referenceImageCount: 1, provider: .miniMaxH3)
                     .contains("这 1 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(
            referenceImageCount: 2, provider: .miniMaxH3)
                     .contains("这 2 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(
            referenceImageCount: 3, provider: .miniMaxH3)
                     .contains("这 3 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(
            referenceImageCount: 4, provider: .miniMaxH3)
                     .contains("全部 4 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(
            referenceImageCount: 8, provider: .miniMaxH3)
                     .contains("全部 4 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(
            referenceImageCount: 4, provider: .agnes)
                     .contains("第一张上传的宠物照片"))
        precondition(PetActionManifest.Action.Kind.fixedActionKinds
            == [.gazeOrbit] + PetActionManifest.Action.Kind.fixedTapActions)
    }

    private static func testGeneratedMotionTrackMatteInvocation() {
        let generatedArguments = TrackMatteCommand.arguments(
            scriptPath: "/app/scripts/track_then_matte.py",
            videoPath: "/pet/generated.mp4",
            outputDir: "/pet",
            clickX: 100,
            clickY: 200,
            bbox: [1, 2, 3, 4],
            startTime: 0,
            duration: 12,
            skipsQualityCheck: true)
        precondition(generatedArguments == [
            "/app/scripts/track_then_matte.py",
            "--video", "/pet/generated.mp4",
            "--output-dir", "/pet",
            "--preview-seconds", "5",
            "--max-seconds", "15",
            "--click", "100,200",
            "--skip-qa",
            "--bbox", "1.0,2.0,3.0,4.0",
            "--start", "0.0",
            "--duration", "12.0",
        ])

        let capturedArguments = TrackMatteCommand.arguments(
            scriptPath: "/app/scripts/track_then_matte.py",
            videoPath: "/pet/captured.mp4",
            outputDir: "/pet",
            clickX: 100,
            clickY: 200)
        precondition(!capturedArguments.contains("--skip-qa"))
        precondition(!capturedArguments.contains("--fps"))
    }

    private static func testSupabaseOriginalReferenceAndVideoRequests() throws {
        do {
            _ = try SupabaseReferenceStorageCredentials(
                publishableKey: "publishable-key", accessToken: "sb_secret_never-use-this")
            preconditionFailure("a Supabase secret key must be rejected")
        } catch SupabaseReferenceStorageError.forbiddenServiceRoleKey {}

        let reference = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-original-reference.png")
        defer { try? FileManager.default.removeItem(at: reference) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: reference)
        let configuration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://api.agnes-ai.cn/v1")
        precondition(configuration.isAgnesAPI)
        precondition(configuration.chatCompletionsURL.absoluteString
                     == "https://api.agnes-ai.cn/v1/chat/completions")

        let settings = AgnesVideoGenerationRequestSettings(
            size: "1152x768", seconds: 4)!
        let videoRequest = try AgnesVideoGenerationClient.makeCreateRequest(
            prompt: "纯白色背景，固定镜头，小狗在原地转一圈。",
            firstFrameURL: URL(string:
                "https://project.supabase.co/storage/v1/object/sign/pet-reference-images/pet.png?token=temporary")!,
            apiKey: "agnes-key",
            configuration: configuration,
            settings: settings)
        let videoBody = try JSONSerialization.jsonObject(
            with: videoRequest.httpBody ?? Data()) as? [String: Any]
        precondition(videoRequest.value(forHTTPHeaderField: "Authorization")
                     == "Bearer agnes-key")
        precondition(videoRequest.url?.absoluteString
                     == "https://api.agnes-ai.cn/v1/videos")
        precondition(videoBody?["model"] as? String == "agnes-video-v2.0")
        precondition((videoBody?["image"] as? String)?.hasPrefix(
            "https://project.supabase.co/storage/v1/object/sign/pet-reference-images/") == true)
        precondition(videoBody?["width"] as? Int == 1152)
        precondition(videoBody?["height"] as? Int == 768)
        precondition(videoBody?["num_frames"] as? Int == 97)
        precondition(videoBody?["frame_rate"] as? Int == 24)

        let miniMaxConfiguration = try MiniMaxVideoAPIConfiguration(
            baseURLString: "https://api.minimaxi.com")
        let originalImage = try PetReferenceImageData.load(from: reference)
        let miniMaxRequest = try MiniMaxH3VideoGenerationClient.makeReferenceCreateRequest(
            prompt: FixedPetAction.headFollow.prompt(
                referenceImageCount: 4, provider: .miniMaxH3),
            referenceImages: Array(repeating: originalImage, count: 4),
            apiKey: "minimax-key",
            configuration: miniMaxConfiguration,
            seconds: 4)
        let miniMaxBody = try JSONSerialization.jsonObject(
            with: miniMaxRequest.httpBody ?? Data()) as? [String: Any]
        let content = miniMaxBody?["content"] as? [[String: Any]]
        let imageEntries = content?.dropFirst() ?? []
        precondition(imageEntries.count == 4)
        precondition(imageEntries.allSatisfy {
            ($0["role"] as? String) == "reference_image"
                && (($0["image_url"] as? [String: String])?["url"]?.hasPrefix(
                    "data:image/png;base64,") == true)
        })
    }

    private static func testProviderPipelinesCreatePollAndDownload() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-original-pipeline-reference.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: temporary)
        let agnesAPIConfiguration = try OpenAIImageAPIConfiguration(
            baseURLString: "https://api.agnes-ai.cn/v1")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MotionMockURLProtocol.self]
        MotionMockURLProtocol.handler = { request in
            if request.url?.host == "api.agnes-ai.cn" {
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer agnes-key")
            }
            if request.url?.host == "api.minimaxi.com" {
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer minimax-key")
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            switch (request.httpMethod, request.url?.host, request.url?.path) {
            case ("POST", "project.supabase.co", let path)
                where path?.hasPrefix("/storage/v1/object/pet-reference-images/") == true:
                precondition(request.value(forHTTPHeaderField: "apikey") == "publishable-key")
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer anonymous-session")
                precondition(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
                precondition(path?.contains("/references/") == true)
                return (response, Data("{}".utf8))
            case ("GET", "project.supabase.co", let path)
                where path?.hasPrefix("/storage/v1/object/pet-reference-images/") == true:
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer anonymous-session")
                return (response, Data([0x89, 0x50, 0x4e, 0x47]))
            case ("DELETE", "project.supabase.co", let path)
                where path?.hasPrefix("/storage/v1/object/pet-reference-images/") == true:
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer anonymous-session")
                return (response, Data("{}".utf8))
            case ("POST", "project.supabase.co", let path)
                where path?.hasPrefix("/storage/v1/object/sign/pet-reference-images/") == true:
                return (response, try JSONSerialization.data(withJSONObject: [
                    "signedURL": "/object/sign/pet-reference-images/pet/action.png?token=temporary",
                ]))
            case ("POST", "api.agnes-ai.cn", "/v1/videos"):
                return (response, try JSONSerialization.data(withJSONObject: [
                    "code": 0,
                    "data": [
                        "taskId": "task_1",
                        "videoId": "video_1",
                        "state": "submitted",
                    ],
                ]))
            case ("GET", "api.agnes-ai.cn", "/agnesapi"):
                precondition(URLComponents(
                    url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(URLQueryItem(name: "video_id", value: "video_1")) == true)
                return (response, try JSONSerialization.data(withJSONObject: [
                    "data": [
                        "videoId": "video_1",
                        "state": "succeeded",
                        "percentage": "100",
                        "output": ["videoUrl": "https://cdn.example.com/generated.mp4"],
                    ],
                ]))
            case ("GET", "cdn.example.com", "/generated.mp4"):
                return (response, Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]))
            case ("POST", "api.minimaxi.com", "/v2/video_generation"):
                return (response, try JSONSerialization.data(withJSONObject: [
                    "task_id": "minimax_task_1",
                ]))
            case ("GET", "api.minimaxi.com", "/v2/query/video_generation/minimax_task_1"):
                return (response, try JSONSerialization.data(withJSONObject: [
                    "task": [
                        "id": "minimax_task_1",
                        "status": "succeeded",
                        "content": ["url": "https://cdn.example.com/minimax.mp4"],
                    ],
                ]))
            case ("GET", "cdn.example.com", "/minimax.mp4"):
                return (response, Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]))
            default:
                preconditionFailure("Unexpected motion request: \(request.url?.absoluteString ?? "nil")")
            }
        }

        let session = URLSession(configuration: sessionConfiguration)
        let storageConfiguration = try SupabaseReferenceStorageConfiguration(
            projectURLString: "https://project.supabase.co",
            bucketName: "pet-reference-images").validated()
        let ownerID = UUID()
        let storageCredentials = try SupabaseReferenceStorageCredentials(
            publishableKey: "publishable-key", accessToken: "anonymous-session", ownerID: ownerID)
        let storage = SupabasePetReferenceStorageClient(session: session)
        let uploadedReference = try await storage.uploadReference(
                from: temporary,
                petID: UUID(),
                configuration: storageConfiguration,
                credentials: storageCredentials)
        precondition(uploadedReference.objectPath.hasPrefix(
            "\(ownerID.uuidString.lowercased())/"))
        precondition(uploadedReference.objectPath.contains("/references/"))
        let downloadedReference = try await storage.download(
            uploadedReference, configuration: storageConfiguration,
            credentials: storageCredentials)
        precondition(downloadedReference.mimeType == "image/png")
        let signedReferenceURL = try await storage.signedURL(
            for: uploadedReference, configuration: storageConfiguration,
            credentials: storageCredentials)
        precondition(signedReferenceURL.absoluteString.hasPrefix(
            "https://project.supabase.co/storage/v1/object/sign/"))

        // Agnes receives a signed URL from a pre-existing gallery item. The
        // action request itself never has access to a local image file.
        let client = AgnesVideoGenerationClient(session: session)
        let queued = try await client.create(
            prompt: FixedPetAction.cry.prompt,
            firstFrameURL: signedReferenceURL,
            apiKey: "agnes-key",
            configuration: agnesAPIConfiguration,
            settings: AgnesVideoGenerationRequestSettings(size: "1152x768", seconds: 4)!)
        precondition(queued.status == .queued)
        let completed = try await client.retrieve(
            id: queued.id, apiKey: "agnes-key", configuration: agnesAPIConfiguration)
        precondition(completed.status == .completed)
        let video = try await client.downloadContent(job: completed)
        precondition(video.count == 8)
        try await storage.delete(
            uploadedReference, configuration: storageConfiguration,
            credentials: storageCredentials)

        let miniMaxConfiguration = try MiniMaxVideoAPIConfiguration(
            baseURLString: "https://api.minimaxi.com")
        let originalReference = try PetReferenceImageData.load(from: temporary)
        let miniMax = MiniMaxH3VideoGenerationClient(session: session)
        let miniMaxQueued = try await miniMax.create(
            prompt: FixedPetAction.headFollow.prompt(
                referenceImageCount: 2, provider: .miniMaxH3),
            referenceImages: [originalReference, originalReference],
            apiKey: "minimax-key",
            configuration: miniMaxConfiguration,
            seconds: 4)
        precondition(miniMaxQueued.status == .queued)
        let miniMaxCompleted = try await miniMax.retrieve(
            id: miniMaxQueued.id,
            apiKey: "minimax-key",
            configuration: miniMaxConfiguration)
        precondition(miniMaxCompleted.status == .completed)
        let miniMaxVideo = try await miniMax.downloadContent(job: miniMaxCompleted)
        precondition(miniMaxVideo.count == 8)
    }

    private static func testSupabaseGoogleSessionAuthorization() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-google-session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MotionMockURLProtocol.self]
        var userRequests = 0
        MotionMockURLProtocol.handler = { request in
            guard request.httpMethod == "GET",
                  request.url?.host == "project.supabase.co",
                  request.url?.path == "/auth/v1/user" else {
                preconditionFailure("Unexpected Google auth request")
            }
            userRequests += 1
            precondition(request.value(forHTTPHeaderField: "apikey") == "publishable-key")
            precondition(request.value(forHTTPHeaderField: "Authorization")
                == "Bearer google-access-token")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, try JSONSerialization.data(withJSONObject: [
                "id": "11111111-1111-1111-1111-111111111111",
                "email": "owner@example.com",
            ]))
        }
        let configuration = try SupabaseReferenceStorageConfiguration(
            projectURLString: "https://project.supabase.co",
            bucketName: "pet-reference-images").validated()
        let authorizationURL = try SupabaseGoogleSessionStore.authorizationURL(
            configuration: configuration)
        let authorizationItems = URLComponents(
            url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
        precondition(authorizationURL.path == "/auth/v1/authorize")
        precondition(authorizationItems?.contains(
            URLQueryItem(name: "provider", value: "google")) == true)
        precondition(authorizationItems?.contains(
            URLQueryItem(
                name: "redirect_to",
                value: SupabaseGoogleSessionStore.callbackURL.absoluteString)) == true)

        let store = SupabaseGoogleSessionStore(
            session: URLSession(configuration: sessionConfiguration), fileURL: temporary)
        let account = try await store.completeAuthorization(
            callbackURL: URL(string: "realpet-auth://auth/callback#access_token=google-access-token&refresh_token=google-refresh-token&expires_in=3600")!,
            configuration: configuration,
            publishableKey: "publishable-key")
        let first = try await store.credentials(
            configuration: configuration, publishableKey: "publishable-key")
        let second = try await store.credentials(
            configuration: configuration, publishableKey: "publishable-key")
        precondition(account.email == "owner@example.com")
        precondition(first.accessToken == "google-access-token")
        precondition(first.ownerID?.uuidString == "11111111-1111-1111-1111-111111111111")
        precondition(second.ownerID == first.ownerID)
        precondition(userRequests == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
    }

}
