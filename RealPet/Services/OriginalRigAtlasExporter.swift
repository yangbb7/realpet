import Foundation

enum OriginalRigAtlasExportError: LocalizedError {
    case invalidArguments
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "usage: RealPet --export-original-rig-atlas <reference-image> <output-png> <template-profile>"
        case .missingCredential:
            return "image service credential is not provisioned"
        }
    }
}

struct OriginalRigAtlasExportRequest: Equatable {
    static let flag = "--export-original-rig-atlas"

    let referenceImageURL: URL
    let outputURL: URL
    let profile: PetTemplateProfile

    static func parse(arguments: [String]) throws -> OriginalRigAtlasExportRequest? {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(flagIndex + 3),
              flagIndex + 4 == arguments.endIndex,
              let profile = PetTemplateProfile(
                rawValue: arguments[flagIndex + 3]) else {
            throw OriginalRigAtlasExportError.invalidArguments
        }
        return OriginalRigAtlasExportRequest(
            referenceImageURL: URL(fileURLWithPath: arguments[flagIndex + 1]),
            outputURL: URL(fileURLWithPath: arguments[flagIndex + 2]),
            profile: profile)
    }
}

struct OriginalRigTorsoExportRequest: Equatable {
    static let flag = "--export-original-rig-torso"

    let referenceImageURL: URL
    let outputURL: URL

    static func parse(arguments: [String]) throws -> OriginalRigTorsoExportRequest? {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(flagIndex + 2),
              flagIndex + 3 == arguments.endIndex else {
            throw OriginalRigAtlasExportError.invalidArguments
        }
        return OriginalRigTorsoExportRequest(
            referenceImageURL: URL(fileURLWithPath: arguments[flagIndex + 1]),
            outputURL: URL(fileURLWithPath: arguments[flagIndex + 2]))
    }
}

enum OriginalRigAtlasExporter {
    static func export(_ request: OriginalRigAtlasExportRequest) async throws {
        guard let key = OpenAIAPIKeyStore.load()?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw OriginalRigAtlasExportError.missingCredential
        }
        let atlas = try await GPTImage2RigAssetGenerator().generateAtlas(
            referenceImageURL: request.referenceImageURL,
            apiKey: key,
            configuration: .defaultRelay,
            profile: request.profile)
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try atlas.write(to: request.outputURL, options: .atomic)
    }
}

enum OriginalRigTorsoExporter {
    static func export(_ request: OriginalRigTorsoExportRequest) async throws {
        guard let key = OpenAIAPIKeyStore.load()?.trimmingCharacters(
            in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw OriginalRigAtlasExportError.missingCredential
        }
        let torso = try await GPTImage2RigAssetGenerator().generateIsolatedTorso(
            referenceImageURL: request.referenceImageURL,
            apiKey: key,
            configuration: .defaultRelay)
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try torso.write(to: request.outputURL, options: .atomic)
    }
}
