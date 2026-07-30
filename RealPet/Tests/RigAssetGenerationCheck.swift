import Foundation

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw RigAssetGenerationError.invalidResponse
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
struct RigAssetGenerationCheck {
    static func main() async throws {
        try testEndpointConfiguration()
        try await testImageRequestAndResponse()
        try testOriginalRigAtlasExportArguments()
        try testPreparedManifestDoesNotUnlockHeadPose()
        print("Rig asset generation checks passed")
    }

    private static func testOriginalRigAtlasExportArguments() throws {
        let missing = try OriginalRigAtlasExportRequest.parse(
            arguments: ["RealPet"])
        precondition(missing == nil)
        let request = try OriginalRigAtlasExportRequest.parse(arguments: [
            "RealPet", OriginalRigAtlasExportRequest.flag,
            "/tmp/reference.png", "/tmp/original-atlas.png", "cat-v1",
        ])
        precondition(request?.referenceImageURL.path == "/tmp/reference.png")
        precondition(request?.outputURL.path == "/tmp/original-atlas.png")
        precondition(request?.profile == .cat)
        let torsoRequest = try OriginalRigTorsoExportRequest.parse(arguments: [
            "RealPet", OriginalRigTorsoExportRequest.flag,
            "/tmp/reference.png", "/tmp/original-torso.png",
        ])
        precondition(torsoRequest?.referenceImageURL.path == "/tmp/reference.png")
        precondition(torsoRequest?.outputURL.path == "/tmp/original-torso.png")

        do {
            _ = try OriginalRigAtlasExportRequest.parse(arguments: [
                "RealPet", OriginalRigAtlasExportRequest.flag,
                "/tmp/reference.png",
            ])
            preconditionFailure("missing output path must be rejected")
        } catch OriginalRigAtlasExportError.invalidArguments {
            // Expected.
        }
    }

    private static func testEndpointConfiguration() throws {
        let official = OpenAIImageAPIConfiguration.official
        precondition(official.normalizedBaseURLString == "https://api.openai.com/v1")
        precondition(
            official.imageEditsURL.absoluteString
                == "https://api.openai.com/v1/images/edits")
        precondition(
            OpenAIImageAPIConfiguration.defaultRelay.imageEditsURL.absoluteString
                == "https://api.braintech.icu/v1/images/edits")
        precondition(
            GPTImage2RigAssetGenerator.endpoint
                == OpenAIImageAPIConfiguration.defaultRelay.imageEditsURL)

        let relay = try OpenAIImageAPIConfiguration(
            baseURLString: "  https://Relay.Example.com/openai/v1/  ")
        precondition(
            relay.normalizedBaseURLString
                == "https://relay.example.com/openai/v1")
        precondition(
            relay.imageEditsURL.absoluteString
                == "https://relay.example.com/openai/v1/images/edits")

        let fullEndpoint = try OpenAIImageAPIConfiguration(
            baseURLString: "https://relay.example.com/v1/images/edits")
        precondition(
            fullEndpoint.normalizedBaseURLString
                == "https://relay.example.com/v1")

        let localRelay = try OpenAIImageAPIConfiguration(
            baseURLString: "http://127.0.0.1:8080/v1")
        precondition(
            localRelay.imageEditsURL.absoluteString
                == "http://127.0.0.1:8080/v1/images/edits")

        assertConfigurationError(
            "http://relay.example.com/v1", expected: .insecureURL)
        assertConfigurationError(
            "https://user:password@relay.example.com/v1", expected: .invalidURL)
        assertConfigurationError(
            "https://relay.example.com/v1?token=secret", expected: .invalidURL)
    }

    private static func assertConfigurationError(
        _ baseURL: String,
        expected: OpenAIImageAPIConfigurationError
    ) {
        do {
            _ = try OpenAIImageAPIConfiguration(baseURLString: baseURL)
            preconditionFailure("Expected configuration error for \(baseURL)")
        } catch let error as OpenAIImageAPIConfigurationError {
            precondition(error == expected)
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }
    }

    private static func testImageRequestAndResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let reference = FileManager.default.temporaryDirectory
            .appendingPathComponent("realpet-rig-reference.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: reference)
        defer { try? FileManager.default.removeItem(at: reference) }

        let expected = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a])
        let relay = try OpenAIImageAPIConfiguration(
            baseURLString: "https://relay.example.com/openai/v1")
        let builtRequest = try GPTImage2RigAssetGenerator.makeRequest(
            referenceImageURL: reference,
            apiKey: "relay-token",
            configuration: relay)
        let builtBody = String(
            decoding: builtRequest.httpBody ?? Data(), as: UTF8.self)
        precondition(builtBody.contains("name=\"model\"\r\n\r\ngpt-image-2"))
        precondition(builtBody.contains("name=\"quality\"\r\n\r\nmedium"))
        precondition(builtBody.contains("name=\"background\"\r\n\r\nopaque"))
        precondition(builtBody.contains("name=\"image[]\""))
        precondition(builtBody.contains("5-column by 4-row grid"))
        precondition(builtBody.contains("exactly twenty isolated components"))
        precondition(builtBody.contains("muzzle without nose or mouth; nose"))
        precondition(
            PetTemplateSelection.select(
                detectedClass: "cat", classificationIdentifiers: []) == .cat)
        precondition(
            PetTemplateSelection.select(
                detectedClass: "dog", classificationIdentifiers: ["pug"])
                == .dogShortSnout)
        precondition(
            PetTemplateSelection.select(
                detectedClass: "dog",
                classificationIdentifiers: ["golden retriever"])
                == .dogLongSnout)
        precondition(
            PetTemplateSelection.select(
                detectedClass: "dog", classificationIdentifiers: ["pomeranian"])
                == .dogLongSnout)
        precondition(
            PetTemplateSelection.select(
                detectedClass: "horse", classificationIdentifiers: []) == nil)

        let torsoRequest = try GPTImage2RigAssetGenerator.makeRequest(
            referenceImageURL: reference,
            apiKey: "relay-token",
            configuration: relay,
            prompt: GPTImage2RigAssetGenerator.isolatedTorsoPrompt,
            size: "1024x1024")
        let torsoBody = String(
            decoding: torsoRequest.httpBody ?? Data(), as: UTF8.self)
        precondition(torsoBody.contains("name=\"size\"\r\n\r\n1024x1024"))
        precondition(torsoBody.contains("no head, neck ruff"))

        MockURLProtocol.handler = { request in
            precondition(request.url == relay.imageEditsURL)
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "Authorization")
                         == "Bearer relay-token")
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            precondition(contentType.contains("multipart/form-data; boundary="))
            let json = try JSONSerialization.data(withJSONObject: [
                "data": [["b64_json": expected.base64EncodedString()]],
            ])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!
            return (response, json)
        }

        let generated = try await GPTImage2RigAssetGenerator(session: session)
            .generateAtlas(
                referenceImageURL: reference,
                apiKey: "relay-token",
                configuration: relay,
                profile: .dogLongSnout)
        precondition(generated == expected)
    }

    private static func testPreparedManifestDoesNotUnlockHeadPose() throws {
        let manifest = InteractivePetModelManifest(
            version: 1,
            targetRenderer: .live2dCubism,
            stage: .partsPrepared,
            sourceModel: "gpt-image-2",
            template: "quadruped-v2",
            atlas: "atlas.png",
            parts: ["head": "parts/head.png"],
            capabilities: .init(
                headPose: false, eyeGaze: false, breathing: false))
        precondition(!manifest.isRuntimeReady)
    }
}
