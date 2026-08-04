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
                throw SupabaseMiniMaxVideoGatewayError.invalidResponse
            }
            let (response, data) = try handler(Self.requestWithMaterializedBody(request))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func requestWithMaterializedBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        var body = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            body.append(contentsOf: bytes[0..<count])
        }
        var materialized = request
        materialized.httpBody = body
        return materialized
    }
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
        let motionConfiguration = MotionServiceConfiguration.defaultValue
        precondition(motionConfiguration.provider == .miniMaxH3)
        precondition(motionConfiguration.videoModel == "MiniMax-H3")
        precondition(motionConfiguration.seconds == 4)
        precondition(motionConfiguration.resolution == .native2K)
        _ = try motionConfiguration.validated()
        let migrated = MotionServiceConfiguration(seconds: 99)
            .migratedToSupportedProviders()
        precondition(migrated.provider == .miniMaxH3)
        precondition(migrated.seconds == 15)
        precondition(migrated.resolution == .native2K)

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

        let deduplicationRoot = root.appendingPathComponent("deduplication")
        let deduplicationSource = deduplicationRoot.appendingPathComponent("source")
        try fm.createDirectory(at: deduplicationSource, withIntermediateDirectories: true)
        let copiedFrame = Data("identical-generated-frame".utf8)
        try copiedFrame.write(to: deduplicationRoot.appendingPathComponent("frame_0000.png"))
        try copiedFrame.write(to: deduplicationSource.appendingPathComponent("frame_0000.png"))
        let dedupManifest = try PetActionLibrary.install(
            kind: .gazeOrbit,
            processedFramesDirectory: deduplicationSource,
            rootFramesDirectory: deduplicationRoot,
            fps: 10,
            origin: .generated)
        let idleDirectory = deduplicationRoot.appendingPathComponent("actions/idle")
        try fm.createDirectory(at: idleDirectory, withIntermediateDirectories: true)
        try copiedFrame.write(to: idleDirectory.appendingPathComponent("frame_0000.png"))
        try PetActionManifest(
            version: dedupManifest.version,
            defaultAction: dedupManifest.defaultAction,
            actions: dedupManifest.actions.map { action in
                guard action.kind == .idle else { return action }
                return .init(
                    id: action.id,
                    kind: action.kind,
                    displayNameOverride: action.displayNameOverride,
                    framesDirectory: "actions/idle",
                    fps: action.fps,
                    loop: action.loop,
                    translatesWindow: action.translatesWindow,
                    origin: .generated)
            }).save(framesDirectory: deduplicationRoot.path)
        precondition(PetActionLibrary.identityReferenceDirectory(
            rootFramesDirectory: deduplicationRoot).lastPathComponent == "gaze_orbit")
        let deduplicated = try PetActionLibrary.deduplicateGeneratedOrbitFrames(
            rootFramesDirectory: deduplicationRoot)
        precondition(deduplicated)
        precondition(!fm.fileExists(atPath: deduplicationRoot
            .appendingPathComponent("frame_0000.png").path))

        let mismatchRoot = root.appendingPathComponent("deduplication-mismatch")
        let mismatchSource = mismatchRoot.appendingPathComponent("source")
        try fm.createDirectory(at: mismatchSource, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: mismatchRoot.appendingPathComponent("frame_0000.png"))
        try Data("different".utf8).write(to: mismatchSource.appendingPathComponent("frame_0000.png"))
        let mismatchManifest = try PetActionLibrary.install(
            kind: .gazeOrbit,
            processedFramesDirectory: mismatchSource,
            rootFramesDirectory: mismatchRoot,
            fps: 10,
            origin: .generated)
        try fm.createDirectory(
            at: mismatchRoot.appendingPathComponent("actions/idle"),
            withIntermediateDirectories: true)
        try PetActionManifest(
            version: mismatchManifest.version,
            defaultAction: mismatchManifest.defaultAction,
            actions: mismatchManifest.actions.map { action in
                guard action.kind == .idle else { return action }
                return .init(
                    id: action.id,
                    kind: action.kind,
                    displayNameOverride: action.displayNameOverride,
                    framesDirectory: "actions/idle",
                    fps: action.fps,
                    loop: action.loop,
                    translatesWindow: action.translatesWindow,
                    origin: .generated)
            }).save(framesDirectory: mismatchRoot.path)
        let mismatchDeduplicated = try PetActionLibrary.deduplicateGeneratedOrbitFrames(
            rootFramesDirectory: mismatchRoot)
        precondition(!mismatchDeduplicated)
        precondition(fm.fileExists(atPath: mismatchRoot
            .appendingPathComponent("frame_0000.png").path))

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
        precondition(FixedPetAction.missingActions(installedKinds: []).first == .headFollow)
        precondition(FixedPetAction.missingActions(installedKinds: [.gazeOrbit]).first
                     == .lieDown)
        precondition(FixedPetAction.missingActions(
            installedKinds: Set(PetActionManifest.Action.Kind.fixedActionKinds)).isEmpty)
        precondition(FixedPetAction.allCases.allSatisfy { $0.minimumVideoSeconds == 4 })
        precondition(FixedPetAction.headFollow.prompt(referenceImageCount: 1)
                     .contains("这 1 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(referenceImageCount: 2)
                     .contains("这 2 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(referenceImageCount: 3)
                     .contains("这 3 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(referenceImageCount: 4)
                     .contains("全部 4 张宠物素材图"))
        precondition(FixedPetAction.headFollow.prompt(referenceImageCount: 8)
                     .contains("全部 4 张宠物素材图"))
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
            skipsQualityCheck: true,
            preservesSourceVideo: true)
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
        precondition(capturedArguments.contains("--fps"))
        precondition(capturedArguments.contains("--max-output-dimension"))
        let spaceSavingArguments = TrackMatteCommand.arguments(
            scriptPath: "/app/scripts/track_then_matte.py",
            videoPath: "/pet/captured.mp4",
            outputDir: "/pet",
            clickX: 100,
            clickY: 200,
            assetProfile: .spaceSaver)
        precondition(spaceSavingArguments.contains("640"))
        precondition(spaceSavingArguments.contains("12"))
    }

    private static func testSupabaseOriginalReferenceAndVideoRequests() throws {
        do {
            _ = try SupabaseReferenceStorageCredentials(
                publishableKey: "publishable-key", accessToken: "sb_secret_never-use-this")
            preconditionFailure("a Supabase secret key must be rejected")
        } catch SupabaseReferenceStorageError.forbiddenServiceRoleKey {}

    }

    private static func testProviderPipelinesCreatePollAndDownload() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-original-pipeline-reference.png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: temporary)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MotionMockURLProtocol.self]
        var miniMaxGatewayRequestCount = 0
        MotionMockURLProtocol.handler = { request in
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
            case ("POST", "project.supabase.co", "/functions/v1/minimax-video"):
                precondition(request.value(forHTTPHeaderField: "apikey") == "publishable-key")
                precondition(request.value(forHTTPHeaderField: "Authorization")
                             == "Bearer anonymous-session")
                miniMaxGatewayRequestCount += 1
                switch miniMaxGatewayRequestCount {
                case 1:
                    let requestBody = try JSONSerialization.jsonObject(
                        with: request.httpBody ?? Data()) as? [String: Any]
                    precondition(requestBody?["operation"] as? String == "create")
                    precondition(requestBody?["resolution"] as? String == "2K")
                    return (response, try JSONSerialization.data(withJSONObject: [
                        "jobId": "11111111-1111-4111-8111-111111111111",
                        "status": "queued",
                        "durationSeconds": 4,
                        "providerResolution": "2K",
                        "providerCostCents": NSNull(),
                        "resultUrl": NSNull(),
                        "error": NSNull(),
                    ]))
                case 2:
                    return (response, try JSONSerialization.data(withJSONObject: [
                        "jobId": "11111111-1111-4111-8111-111111111111",
                        "status": "succeeded",
                        "durationSeconds": 4,
                        "providerResolution": "2K",
                        "providerCostCents": 24,
                        "resultUrl": "https://cdn.example.com/minimax.mp4",
                        "error": NSNull(),
                    ]))
                default:
                    preconditionFailure("Unexpected MiniMax gateway request count")
                }
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
        let miniMax = SupabaseMiniMaxVideoGatewayClient(session: session)
        let miniMaxQueued = try await miniMax.create(
            petID: UUID(),
            action: .headFollow,
            seconds: 4,
            resolution: .native2K,
            configuration: storageConfiguration,
            credentials: storageCredentials)
        precondition(miniMaxQueued.status == .queued)
        let miniMaxCompleted = try await miniMax.retrieve(
            id: miniMaxQueued.id,
            configuration: storageConfiguration,
            credentials: storageCredentials)
        precondition(miniMaxCompleted.status == .completed)
        precondition(miniMaxCompleted.providerCostCents == 24)
        precondition(miniMaxCompleted.providerResolution == .native2K)
        let miniMaxVideo = try await miniMax.downloadContent(job: miniMaxCompleted)
        precondition(miniMaxVideo.count == 8)
        precondition(miniMaxGatewayRequestCount == 2)
        try await storage.delete(
            uploadedReference, configuration: storageConfiguration,
            credentials: storageCredentials)
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
