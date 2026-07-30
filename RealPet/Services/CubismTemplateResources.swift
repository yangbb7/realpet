import Foundation

struct CubismTemplateResources: Equatable, Sendable {
    let root: URL
    let profile: PetTemplateProfile

    var descriptor: URL {
        root.appendingPathComponent("realpet-template.json")
    }

    var provenance: URL {
        root.appendingPathComponent("realpet-provenance.json")
    }

    private static let requiredParts: Set<String> = [
        "head", "muzzle", "nose", "mouth", "tongue", "eye_left", "eye_right",
        "ear_left", "ear_right", "torso", "chest", "tail", "front_leg_left",
        "front_paw_left", "front_leg_right", "front_paw_right",
        "hind_leg_left", "hind_paw_left", "hind_leg_right", "hind_paw_right",
    ]

    private static let requiredParameters: Set<String> = [
        "ParamAngleX", "ParamAngleY", "ParamAngleZ", "ParamBodyAngleX",
        "ParamEyeBallX", "ParamEyeBallY", "ParamEyeLOpen", "ParamEyeROpen",
        "ParamMouthOpenY", "ParamBreath", "ParamBodyAngleY", "ParamBodyAngleZ",
        "ParamBodyY", "ParamTail", "ParamLegFrontL", "ParamPawFrontL",
        "ParamLegFrontR", "ParamPawFrontR", "ParamLegHindL", "ParamPawHindL",
        "ParamLegHindR", "ParamPawHindR", "ParamEarL", "ParamEarR",
    ]

    private struct Descriptor: Decodable {
        let version: Int
        let id: String
        let contract: String
        let profile: String
        let model: String
        let texture: String
        let textureSize: [Int]
        let slots: [String: Slot]
        let partDrawables: [String: String]
        let capabilities: [String: Bool]
        let parameters: [String]

        struct Slot: Decodable {
            let rect: [Int]
        }
    }

    private struct Provenance: Decodable {
        let schemaVersion: Int
        let profile: String
        let status: String
        let owner: String
        let originalWork: Bool
        let thirdPartyCharacterAssets: [String]
        let sourceProject: SourceProject

        struct SourceProject: Decodable {
            let path: String
            let sha256: String
        }
    }

    var isComplete: Bool {
        guard let data = try? Data(contentsOf: descriptor),
              let value = try? JSONDecoder().decode(Descriptor.self, from: data),
              let provenanceData = try? Data(contentsOf: provenance),
              let provenanceValue = try? JSONDecoder().decode(
                Provenance.self, from: provenanceData),
              value.version == 2,
              value.id == profile.rawValue,
              value.profile == profile.rawValue,
              value.contract == "quadruped-v2",
              value.textureSize == [2000, 1600],
              provenanceValue.schemaVersion == 1,
              provenanceValue.profile == profile.rawValue,
              provenanceValue.status == "exported-and-verified",
              !provenanceValue.owner.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty,
              provenanceValue.originalWork,
              provenanceValue.thirdPartyCharacterAssets.isEmpty,
              !provenanceValue.sourceProject.path.isEmpty,
              provenanceValue.sourceProject.sha256.count == 64,
              provenanceValue.sourceProject.sha256.allSatisfy({
                  $0.isHexDigit && !$0.isUppercase
              }),
              Set(value.slots.keys) == Self.requiredParts,
              value.slots.values.allSatisfy({
                  $0.rect.count == 4 && $0.rect.allSatisfy { $0 >= 0 }
              }),
              Set(value.partDrawables.keys) == Self.requiredParts,
              Set(value.partDrawables.values).count == Self.requiredParts.count,
              value.partDrawables.values.allSatisfy({ !$0.isEmpty }),
              ["headPose", "eyeGaze", "breathing", "locomotion", "reaction"]
                .allSatisfy({ value.capabilities[$0] == true }),
              Set(value.parameters).isSuperset(of: Self.requiredParameters),
              let modelURL = containedFile(relativePath: value.model),
              let textureURL = containedFile(relativePath: value.texture),
              textureURL.pathExtension.lowercased() == "png" else {
            return false
        }
        return (try? CubismModelPackageValidator.validate(modelURL: modelURL)) != nil
    }

    private func containedFile(relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolvedRoot.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath),
              let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else { return nil }
        return candidate
    }

    static func discover(
        profile: PetTemplateProfile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResources: URL? = Bundle.main.resourceURL,
        projectRoot: URL? = nil
    ) -> Self? {
        var candidates: [URL] = []
        let profileKey = "REALPET_CUBISM_TEMPLATE_"
            + profile.rawValue.uppercased().replacingOccurrences(of: "-", with: "_")
        if let override = environment[profileKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let override = environment["REALPET_CUBISM_TEMPLATE"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let bundleResources {
            candidates.append(bundleResources
                .appendingPathComponent("cubism-templates", isDirectory: true)
                .appendingPathComponent(profile.rawValue, isDirectory: true))
        }
        if let projectRoot {
            candidates.append(projectRoot
                .appendingPathComponent("assets/cubism-templates", isDirectory: true)
                .appendingPathComponent(profile.rawValue, isDirectory: true))
        }
        return candidates.lazy
            .map { Self(root: $0.standardizedFileURL, profile: profile) }
            .first(where: \.isComplete)
    }

    static func missingProfiles(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResources: URL? = Bundle.main.resourceURL,
        projectRoot: URL? = nil
    ) -> [PetTemplateProfile] {
        PetTemplateProfile.allCases.filter {
            discover(
                profile: $0, environment: environment,
                bundleResources: bundleResources,
                projectRoot: projectRoot) == nil
        }
    }
}
