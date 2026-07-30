import Foundation

struct CubismWebRuntimeResources: Equatable, Sendable {
    let root: URL

    var coreScript: URL { root.appendingPathComponent("live2dcubismcore.min.js") }
    var runtimeScript: URL { root.appendingPathComponent("realpet-cubism.bundle.js") }
    var shaders: URL { root.appendingPathComponent("shaders", isDirectory: true) }
    var license: URL { root.appendingPathComponent("CUBISM_SDK_LICENSE.md") }
    var openSoftwareLicense: URL {
        root.appendingPathComponent("LIVE2D_OPEN_SOFTWARE_LICENSE.md")
    }

    var isComplete: Bool {
        let fm = FileManager.default
        guard isRegularNonemptyFile(coreScript, minimumSize: 10_000),
              isRegularNonemptyFile(runtimeScript, minimumSize: 10_000),
              isRegularNonemptyFile(license, minimumSize: 20),
              isRegularNonemptyFile(
                openSoftwareLicense, minimumSize: 20) else { return false }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: shaders.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        else { return false }
        let shaderFiles = (try? fm.contentsOfDirectory(
            at: shaders, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return shaderFiles.contains { url in
            ["vert", "frag"].contains(url.pathExtension.lowercased())
                && isRegularNonemptyFile(url, minimumSize: 20)
        }
    }

    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResources: URL? = Bundle.main.resourceURL,
        projectRoot: URL? = nil,
        applicationSupport: URL? = defaultApplicationSupportDirectory()
    ) -> Self? {
        var candidates: [URL] = []
        if let override = environment["REALPET_CUBISM_WEB_RUNTIME"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let bundleResources {
            candidates.append(bundleResources.appendingPathComponent(
                "cubism-web", isDirectory: true))
        }
        if let projectRoot {
            candidates.append(projectRoot.appendingPathComponent(
                "web/cubism-runtime/dist", isDirectory: true))
        }
        if let applicationSupport {
            candidates.append(applicationSupport
                .appendingPathComponent("RealPet", isDirectory: true)
                .appendingPathComponent("cubism-web", isDirectory: true))
        }
        return candidates.lazy
            .map { Self(root: $0.standardizedFileURL) }
            .first(where: \.isComplete)
    }

    private static func defaultApplicationSupportDirectory() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private func isRegularNonemptyFile(
        _ url: URL,
        minimumSize: Int
    ) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) >= minimumSize
    }
}
