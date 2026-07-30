import Foundation

struct InteractivePetModelManifest: Codable, Equatable, Sendable {
    enum TargetRenderer: String, Codable, Sendable {
        case live2dCubism
    }

    enum Stage: String, Codable, Sendable {
        case partsPrepared
        case cubismCompiled
    }

    struct Capabilities: Codable, Equatable, Sendable {
        let headPose: Bool
        let eyeGaze: Bool
        let breathing: Bool
        let locomotion: Bool
        let reaction: Bool

        init(
            headPose: Bool,
            eyeGaze: Bool,
            breathing: Bool,
            locomotion: Bool = false,
            reaction: Bool = false
        ) {
            self.headPose = headPose
            self.eyeGaze = eyeGaze
            self.breathing = breathing
            self.locomotion = locomotion
            self.reaction = reaction
        }

        private enum CodingKeys: String, CodingKey {
            case headPose, eyeGaze, breathing, locomotion, reaction
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            headPose = try values.decode(Bool.self, forKey: .headPose)
            eyeGaze = try values.decode(Bool.self, forKey: .eyeGaze)
            breathing = try values.decode(Bool.self, forKey: .breathing)
            locomotion = try values.decodeIfPresent(
                Bool.self, forKey: .locomotion) ?? false
            reaction = try values.decodeIfPresent(
                Bool.self, forKey: .reaction) ?? false
        }
    }

    static let currentVersion = 1

    let version: Int
    let targetRenderer: TargetRenderer
    let stage: Stage
    let sourceModel: String
    let template: String
    let atlas: String
    let parts: [String: String]
    let model: String?
    let capabilities: Capabilities

    var isRuntimeReady: Bool {
        stage == .cubismCompiled
            && capabilities.headPose
            && model?.isEmpty == false
    }

    init(
        version: Int,
        targetRenderer: TargetRenderer,
        stage: Stage,
        sourceModel: String,
        template: String,
        atlas: String,
        parts: [String: String],
        model: String? = nil,
        capabilities: Capabilities
    ) {
        self.version = version
        self.targetRenderer = targetRenderer
        self.stage = stage
        self.sourceModel = sourceModel
        self.template = template
        self.atlas = atlas
        self.parts = parts
        self.model = model
        self.capabilities = capabilities
    }

    var runtimeCapabilities: PetActionCapabilities {
        PetActionCapabilities(
            locomotion: isRuntimeReady && capabilities.locomotion,
            reaction: isRuntimeReady && capabilities.reaction,
            orientation: isRuntimeReady && capabilities.headPose)
    }

    func resolvedModelURL(manifestPath: String) -> URL? {
        guard isRuntimeReady, let model else { return nil }
        let root = URL(fileURLWithPath: manifestPath)
            .deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(model).standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    static func load(at path: String) -> Self? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let manifest = try? JSONDecoder().decode(Self.self, from: data),
              manifest.version == currentVersion else {
            return nil
        }
        return manifest
    }
}

enum CubismModelPackageError: LocalizedError, Equatable {
    case invalidModelJSON
    case missingMocReference
    case missingTextureReferences
    case invalidReference(String)
    case missingReferencedFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelJSON:
            return "Live2D .model3.json 格式无效"
        case .missingMocReference:
            return "Live2D .model3.json 未引用 .moc3 文件"
        case .missingTextureReferences:
            return "Live2D .model3.json 未引用纹理文件"
        case .invalidReference(let path):
            return "Live2D 模型包含不安全的文件引用：\(path)"
        case .missingReferencedFile(let path):
            return "Live2D 模型缺少外部文件：\(path)"
        }
    }
}

enum CubismModelPackageValidator {
    static func validate(modelURL: URL) throws {
        guard let data = try? Data(contentsOf: modelURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              root["Version"] as? Int == 3,
              let references = root["FileReferences"] as? [String: Any] else {
            throw CubismModelPackageError.invalidModelJSON
        }
        guard let moc = references["Moc"] as? String,
              !moc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CubismModelPackageError.missingMocReference
        }

        try validate(reference: moc, relativeTo: modelURL)
        guard let textures = references["Textures"] as? [String],
              !textures.isEmpty else {
            throw CubismModelPackageError.missingTextureReferences
        }
        for texture in textures {
            try validate(reference: texture, relativeTo: modelURL)
        }

        for key in ["Physics", "Pose", "DisplayInfo", "UserData"] {
            if let reference = references[key] as? String {
                try validate(reference: reference, relativeTo: modelURL)
            }
        }
        for expression in references["Expressions"] as? [[String: Any]] ?? [] {
            guard let reference = expression["File"] as? String else {
                throw CubismModelPackageError.invalidModelJSON
            }
            try validate(reference: reference, relativeTo: modelURL)
        }
        if let motionGroups = references["Motions"]
            as? [String: [[String: Any]]] {
            for entries in motionGroups.values {
                for motion in entries {
                    guard let reference = motion["File"] as? String else {
                        throw CubismModelPackageError.invalidModelJSON
                    }
                    try validate(reference: reference, relativeTo: modelURL)
                    if let sound = motion["Sound"] as? String {
                        try validate(reference: sound, relativeTo: modelURL)
                    }
                }
            }
        }
    }

    private static func validate(reference: String, relativeTo modelURL: URL) throws {
        let modelRoot = modelURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = modelRoot.appendingPathComponent(reference)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = modelRoot.path.hasSuffix("/")
            ? modelRoot.path : modelRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw CubismModelPackageError.invalidReference(reference)
        }
        guard let values = try? candidate.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            throw CubismModelPackageError.missingReferencedFile(reference)
        }
    }
}
