import Foundation
import Combine

class PythonBridge: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var phaseLabel = ""
    @Published var error: String?

    private var process: Process?
    private var buffer = ""
    private var isShuttingDown = false
    private var isCancelling = false

    /// Resident daemon for QC / detect.  Set by AppDelegate after
    /// creating both objects.  When nil or not ready, callers fall back to
    /// subprocess.
    weak var daemon: PythonDaemon?

    static let projectRoot: URL = {
        let bundleURL = Bundle.main.bundleURL
        let fm = FileManager.default

        // Allow explicit override via environment variable
        if let override = ProcessInfo.processInfo.environment["REALPET_PROJECT_ROOT"],
           fm.fileExists(atPath: URL(fileURLWithPath: override).appendingPathComponent("pipeline").path) {
            return URL(fileURLWithPath: override)
        }

        if let resourcePath = Bundle.main.resourcePath {
            let candidate = URL(fileURLWithPath: resourcePath)
            if fm.fileExists(atPath: candidate.appendingPathComponent("pipeline").path) {
                return candidate
            }
        }

        var url = bundleURL
        for _ in 0..<5 {
            let candidate = url.appendingPathComponent("pipeline")
            if fm.fileExists(atPath: candidate.path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }

        // If we can't find the project root, try the current working directory
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        if fm.fileExists(atPath: cwd.appendingPathComponent("pipeline").path) {
            return cwd
        }

        fputs("ERROR: Could not locate project root (pipeline/ directory). "
              + "Set REALPET_PROJECT_ROOT env var or run from the project directory.\n", stderr)
        return bundleURL
    }()

    /// Resolve the venv directory.
    ///
    /// Order:
    ///   1. REALPET_VENV env var (CI / developer override)
    ///   2. SetupWizard marker file (user .app path)
    ///   3. <projectRoot>/.venv (dev `swift run` path)
    ///   4. legacy ~/.venvs/sam2
    static var venvDir: String {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        // 1. Explicit env var
        if let venv = env["REALPET_VENV"], fm.fileExists(atPath: venv) {
            return venv
        }

        // 2. SetupWizard marker (user .app path)
        if let marker = try? String(contentsOf: markerURL(), encoding: .utf8),
           !marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           fm.fileExists(atPath: marker) {
            return marker
        }

        // 3. Project-local .venv
        let localVenv = projectRoot.appendingPathComponent(".venv").path
        if fm.fileExists(atPath: localVenv) {
            return localVenv
        }

        // 4. Legacy default
        return NSHomeDirectory() + "/.venvs/sam2"
    }

    private static func markerURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("RealPet/venv_path.txt")
    }

    /// Find the actual site-packages directory inside the venv.
    ///
    /// Avoids hardcoding "python3.10" so the SetupWizard-created venv works
    /// regardless of which Python version the user installed.
    private static var venvSitePackages: String {
        let fm = FileManager.default
        let libDir = URL(fileURLWithPath: venvDir).appendingPathComponent("lib")
        guard fm.fileExists(atPath: libDir.path),
              let entries = try? fm.contentsOfDirectory(atPath: libDir.path),
              let pythonDir = entries.first(where: { $0.hasPrefix("python") }),
              fm.fileExists(atPath: libDir.appendingPathComponent("\(pythonDir)/site-packages").path) else {
            return venvDir + "/lib/python3.10/site-packages"
        }
        return libDir.appendingPathComponent("\(pythonDir)/site-packages").path
    }

    /// Environment for Python subprocesses.
    ///
    /// Critically augments PATH with common tool locations. When the app is
    /// launched from Finder / a .app bundle it inherits launchd's minimal PATH
    /// (/usr/bin:/bin:/usr/sbin:/sbin), which omits /opt/homebrew/bin — so the
    /// pipeline's bare `ffmpeg` calls die with FileNotFoundError and the import
    /// shows up as "failed". Running via `swift run` masked this because it
    /// inherited the shell's full PATH.
    ///
    /// Also sets PYTHONPATH for the project root + venv site-packages.
    static func subprocessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // A signed app bundle must remain immutable at runtime. Without this,
        // Python writes __pycache__ files into Contents/Resources and invalidates
        // the code signature after the first launch.
        env["PYTHONDONTWRITEBYTECODE"] = "1"

        // (a) Resources/bin first: bundled static ffmpeg lives here.
        let resourcesBin = Bundle.main.resourceURL?
            .appendingPathComponent("bin").path
        let toolPaths = [
            resourcesBin,                                   // dev swift run: nil
            "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].compactMap { $0 }
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged: [String] = []
        for p in toolPaths + existing where !merged.contains(p) { merged.append(p) }
        env["PATH"] = merged.joined(separator: ":")

        // (b) HF_HUB_CACHE / HF_HOME / TORCH_HOME default to available weights.
        //
        // huggingface_hub stores the actual repo cache under HF_HUB_CACHE.
        // Release builds use Resources/weights/birefnet-fp16 directly. The HF
        // cache variables remain useful for development trees with full weights.
        let bundledHF = Bundle.main.resourceURL?
            .appendingPathComponent("weights/hf").path
        if let bundledHF, env["HF_HUB_CACHE"] == nil,
           FileManager.default.fileExists(atPath: bundledHF) {
            env["HF_HUB_CACHE"] = bundledHF
        }
        if let bundledHF, env["HF_HOME"] == nil,
           FileManager.default.fileExists(atPath: bundledHF) {
            env["HF_HOME"] = bundledHF
        }
        let bundledTorch = Bundle.main.resourceURL?
            .appendingPathComponent("weights/torch").path
        if let bundledTorch, env["TORCH_HOME"] == nil,
           FileManager.default.fileExists(atPath: bundledTorch) {
            env["TORCH_HOME"] = bundledTorch
        }
        // HF_ENDPOINT is inherited as-is; never hardcoded.

        let existingPythonPath = env["PYTHONPATH"] ?? ""
        env["PYTHONPATH"] = "\(projectRoot.path):\(Self.venvSitePackages):\(existingPythonPath)"
        return env
    }

    /// Find Python for the Track-then-Matte pipeline (SAM2 venv with Python 3.10+)
    static func findTrackMattePython() -> URL? {
        let venvPython = venvDir + "/bin/python"
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            return URL(fileURLWithPath: venvPython)
        }
        return nil
    }

    private func runJSONScript(
        _ scriptName: String,
        arguments: [String],
        responseType: String,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let python = Self.findTrackMattePython() else {
            completion(nil)
            return
        }
        let script = Self.projectRoot.appendingPathComponent("scripts/\(scriptName)")
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path] + arguments
        process.environment = Self.subprocessEnvironment()
        process.currentDirectoryURL = Self.projectRoot
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String: Any]?
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                for line in text.split(separator: "\n").reversed() {
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(
                            with: lineData) as? [String: Any],
                          json["type"] as? String == responseType else {
                        continue
                    }
                    result = json
                    break
                }
                if result == nil {
                    let stderr = String(data: errorData, encoding: .utf8) ?? ""
                    let detail = stderr
                        .split(separator: "\n")
                        .last
                        .flatMap { line -> String? in
                            let value = String(line)
                            return value.isEmpty ? nil : value
                        }
                    let message: String
                    if let detail {
                        message = "脚本校验失败：\(detail.prefix(240))"
                    } else {
                        message = "脚本校验失败（退出码 \(process.terminationStatus)）"
                    }
                    Self.log("\(scriptName) failed exit=\(process.terminationStatus) stderr=\(stderr)")
                    result = ["type": responseType, "passed": false, "message": message]
                }
            } catch {
                Self.log("\(scriptName) threw: \(error)")
                result = [
                    "type": responseType,
                    "passed": false,
                    "message": "无法启动校验脚本：\(error.localizedDescription)",
                ]
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Analyze a video for clip-selection candidates (long videos). Returns the
    /// parsed `clips` payload (candidates + filmstrip + needs_selection) or nil.
    func analyzeClips(videoPath: String, outputDir: String,
                      maxSeconds: Double = 15,
                      completion: @escaping ([String: Any]?) -> Void) {
        runJSONScript(
            "analyze_clips.py",
            arguments: ["--video", videoPath, "--output-dir", outputDir,
                        "--max-seconds", "\(maxSeconds)"],
            responseType: "clips",
            completion: completion)
    }

    /// Validate frame integrity, motion evidence, and appearance continuity.
    /// The owner then confirms action semantics in the required preview.
    func validateAction(
        framesDirectory: String,
        kind: String,
        referenceFramesDirectory: String,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        runJSONScript(
            "validate_action.py",
            arguments: [
            "--frames-dir", framesDirectory,
            "--reference-frames-dir", referenceFramesDirectory,
            "--kind", kind,
            ],
            responseType: "action_validation",
            completion: completion)
    }

    /// Extract a short motion-focused sequence for a one-shot reaction before
    /// semantic validation and atomic installation.
    func prepareAction(
        framesDirectory: String,
        outputDirectory: String,
        kind: String,
        fps: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        runJSONScript(
            "prepare_action.py",
            arguments: [
            "--frames-dir", framesDirectory,
            "--output-dir", outputDirectory,
            "--kind", kind,
            "--fps", "\(fps)",
            ],
            responseType: "action_prepared",
            completion: completion)
    }

    /// Run quality gate (resolution / brightness / blur / pet detection).
    /// Returns `{"type":"qc", "passed": true/false, "reason":..., "message":...}` or nil on error.
    /// Routes through the resident daemon when available, falls back to subprocess.
    @MainActor
    func qualityCheck(videoPath: String, outputDir: String,
                      completion: @escaping ([String: Any]?) -> Void) {
        // Try daemon first.
        if let daemon, daemon.isReady {
            Self.log("qualityCheck via daemon video=\(videoPath)")
            var settled = false
            daemon.send(cmd: "qc",
                        args: ["video": videoPath, "output_dir": outputDir]) { [weak self] msg in
                guard !settled else { return }
                // Daemon died / errored → fall back to subprocess.
                if msg["type"] as? String == "error" {
                    settled = true
                    Self.log("qualityCheck daemon error → subprocess fallback")
                    Task { @MainActor in
                        self?.qualityCheckSubprocess(videoPath: videoPath, outputDir: outputDir,
                                                     completion: completion)
                    }
                    return
                }
                // The terminal "done" line carries the result.
                if msg["done"] as? Bool == true {
                    settled = true
                    let result = msg["result"] as? [String: Any]
                    DispatchQueue.main.async { completion(result) }
                }
            }
            return
        }

        // Fallback: subprocess (legacy path).
        qualityCheckSubprocess(videoPath: videoPath, outputDir: outputDir, completion: completion)
    }

    /// Subprocess QC path (daemon-unavailable fallback).
    private func qualityCheckSubprocess(videoPath: String, outputDir: String,
                                        completion: @escaping ([String: Any]?) -> Void) {
        Self.log("qualityCheck via subprocess (daemon unavailable)")
        guard let python = Self.findTrackMattePython() else {
            completion(nil); return
        }
        let script = Self.projectRoot.appendingPathComponent("scripts/quality_check.py")
        let proc = Process()
        proc.executableURL = python
        proc.arguments = [script.path, "--video", videoPath, "--output-dir", outputDir]
        proc.environment = Self.subprocessEnvironment()
        proc.currentDirectoryURL = Self.projectRoot

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        Self.log("qualityCheck START python=\(python.path) script=\(script.path) video=\(videoPath)")
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String: Any]? = nil
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                Self.log("qualityCheck DONE exit=\(proc.terminationStatus)\nSTDOUT:\n\(text)\nSTDERR:\n\(err)")
                for line in text.split(separator: "\n").reversed() {
                    if let d = line.data(using: .utf8),
                       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       j["type"] as? String == "qc" {
                        result = j; break
                    }
                }
            } catch {
                Self.log("qualityCheck THREW: \(error)")
                result = nil
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Append a line to /tmp/realpet_pybridge.log for debugging the .app
    /// (where stdout/stderr aren't visible).
    static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let path = "/tmp/realpet_pybridge.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Run quick pet detection and return result via callback.
    /// Routes through the resident daemon when available, falls back to subprocess.
    @MainActor
    func detectPet(videoPath: String, outputDir: String, startTime: Double = 0,
                   completion: @escaping ([String: Any]?) -> Void) {
        // Try daemon first.
        if let daemon, daemon.isReady {
            Self.log("detectPet via daemon video=\(videoPath) start=\(startTime)")
            var args: [String: Any] = ["video": videoPath, "output_dir": outputDir]
            if startTime > 0 { args["start"] = startTime }
            var settled = false
            daemon.send(cmd: "detect", args: args) { [weak self] msg in
                guard !settled else { return }
                // Daemon died / errored mid-request → fall back to subprocess
                // instead of leaving the caller hanging on "detecting".
                if msg["type"] as? String == "error" {
                    settled = true
                    Self.log("detectPet daemon error → subprocess fallback")
                    Task { @MainActor in
                        self?.detectPetSubprocess(videoPath: videoPath, outputDir: outputDir,
                                                  startTime: startTime, completion: completion)
                    }
                    return
                }
                if msg["done"] as? Bool == true {
                    settled = true
                    let result = msg["result"] as? [String: Any]
                    DispatchQueue.main.async { completion(result) }
                }
            }
            return
        }

        // Fallback: subprocess (legacy path).
        detectPetSubprocess(videoPath: videoPath, outputDir: outputDir,
                            startTime: startTime, completion: completion)
    }

    /// Subprocess detect path (daemon-unavailable fallback).
    private func detectPetSubprocess(videoPath: String, outputDir: String, startTime: Double,
                                     completion: @escaping ([String: Any]?) -> Void) {
        Self.log("detectPet via subprocess (daemon unavailable)")
        guard let python = Self.findTrackMattePython() else {
            completion(nil)
            return
        }

        let script = Self.projectRoot.appendingPathComponent("scripts/detect_pet.py")
        let proc = Process()
        proc.executableURL = python
        var detectArgs = [script.path, "--video", videoPath, "--output-dir", outputDir]
        if startTime > 0 { detectArgs += ["--start", "\(startTime)"] }
        proc.arguments = detectArgs
        proc.environment = Self.subprocessEnvironment()
        proc.currentDirectoryURL = Self.projectRoot

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        DispatchQueue.global(qos: .userInitiated).async {
            var parsed: [String: Any]? = nil
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    parsed = json
                } else {
                    let out = String(data: data, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    let log = "[detectPet] exit=\(proc.terminationStatus)\nSTDOUT:\n\(out)\nSTDERR:\n\(err)\n"
                    try? log.write(toFile: "/tmp/realpet_pybridge.log", atomically: true, encoding: .utf8)
                }
            } catch {
                try? "[detectPet] proc.run() threw: \(error)\n".write(
                    toFile: "/tmp/realpet_pybridge.log", atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async { completion(parsed) }
        }
    }

    @MainActor
    func startWithClick(videoPath: String, outputDir: String, clickX: Int, clickY: Int,
                        bbox: [Double]? = nil,
                        startTime: Double = -1, duration: Double = -1,
                        skipQualityCheck: Bool = false) {
        guard !isProcessing, let python = Self.findTrackMattePython() else { return }

        let script = Self.projectRoot.appendingPathComponent("scripts/track_then_matte.py")
        let proc = Process()
        proc.executableURL = python
        proc.arguments = TrackMatteCommand.arguments(
            scriptPath: script.path,
            videoPath: videoPath,
            outputDir: outputDir,
            clickX: clickX,
            clickY: clickY,
            bbox: bbox,
            startTime: startTime,
            duration: duration,
            skipsQualityCheck: skipQualityCheck)
        proc.environment = Self.subprocessEnvironment()

        startProcess(proc)
    }

    @MainActor
    private func startProcess(_ proc: Process) {
        // Run from the project root so the scripts' relative pipeline imports
        // resolve correctly. When launched from a .app the default
        // CWD is "/" — the scripts can't find modules there,
        // and the import shows up as "failed".
        proc.currentDirectoryURL = Self.projectRoot

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        // The eager Faster R-CNN daemon retains about 1 GB after detection but
        // is idle during SAM2/BiRefNet. Release it before the heavy model process;
        // `models_released` starts it again before the user can import another pet.
        daemon?.terminate()

        buffer = ""
        isShuttingDown = false
        isCancelling = false
        isProcessing = true
        progress = 0
        error = nil
        statusText = "Starting..."

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let errStr = String(data: data, encoding: .utf8) {
                fputs("PYTHON STDERR: \(errStr)", stderr)
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            self?.handleOutput(chunk)
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasCurrentProcess = self.process === p
                let wasCancelled = self.isCancelling
                if self.process === p {
                    self.process = nil
                }
                self.isProcessing = false
                self.isCancelling = false
                if p.terminationStatus != 0 && self.error == nil && !wasCancelled {
                    self.error = "Process exited with code \(p.terminationStatus)"
                }
                if wasCurrentProcess && !self.isShuttingDown
                    && (wasCancelled || p.terminationStatus != 0) {
                    NotificationCenter.default.post(
                        name: .processingFailed,
                        object: nil,
                        userInfo: ["cancelled": wasCancelled]
                    )
                }
                if !self.isShuttingDown {
                    self.daemon?.start()
                }
            }
        }

        self.process = proc
        do {
            try proc.run()
        } catch {
            self.process = nil
            isProcessing = false
            self.error = "Failed to start processing: \(error.localizedDescription)"
            NotificationCenter.default.post(
                name: .processingFailed,
                object: nil,
                userInfo: ["cancelled": false]
            )
            if !isShuttingDown {
                daemon?.start()
            }
        }
    }

    @MainActor
    func shutdown() {
        isShuttingDown = true
        process?.terminate()
        process = nil
        daemon?.terminate()
    }

    func cancelProcessing() {
        isCancelling = true
        process?.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.process?.isRunning == true {
                self?.process?.terminate()
            }
        }
    }

    private func handleOutput(_ chunk: String) {
        buffer += chunk
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case "phase":
                if let name = msg["name"] as? String {
                    self.phaseLabel = self.phaseDisplayName(name)
                }

            case "progress":
                if let phase = msg["phase"] as? String,
                   let current = msg["current"] as? Int,
                   let total = msg["total"] as? Int, total > 0 {
                    self.progress = Double(current) / Double(total)
                    self.statusText = "\(self.phaseLabel) \(current)/\(total)"

                    // Emit preview-ready when SAM2 tracking completes first N frames
                    if phase == "sam2_track" && current == total {
                        // SAM2 done — preview video should be available soon
                    }
                }

            case "quality_failed":
                if let result = msg["result"] as? [String: Any],
                   let issues = result["issues"] as? [[String: Any]] {
                    let messages = issues.compactMap { $0["message"] as? String }
                    self.error = messages.joined(separator: "\n")
                    self.statusText = "Quality check failed"
                }
                self.isProcessing = false

            case "segmentation_poor":
                let message = msg["message"] as? String ?? "分割质量不达标"
                self.error = message
                self.statusText = "分割质量不达标"
                self.isProcessing = false
                // Tell the VM to retract any preview pet already on the desktop
                // and mark the pet failed (no "complete" will follow — the
                // pipeline hard-returns after this event).
                NotificationCenter.default.post(
                    name: .segmentationPoor, object: nil, userInfo: msg)

            case "complete":
                self.progress = 1.0
                self.statusText = "Done!"
                self.isProcessing = false
                NotificationCenter.default.post(
                    name: .processingComplete,
                    object: nil,
                    userInfo: msg
                )

            case "models_released":
                // Heavy model allocations are gone. Re-warm the eager detector
                // while lightweight quality/encoding work finishes.
                if !self.isShuttingDown {
                    self.daemon?.start()
                }

            case "error":
                if let message = msg["message"] as? String {
                    self.error = message
                    self.statusText = "Error: \(message)"
                }
                self.isProcessing = false
                NotificationCenter.default.post(
                    name: .processingFailed,
                    object: nil,
                    userInfo: ["cancelled": false]
                )

            default:
                break
            }
        }
    }

    private func phaseDisplayName(_ name: String) -> String {
        switch name {
        case "extract": return "Extracting frames"
        case "quality_check": return "Checking quality"
        case "detect": return "Detecting pet"
        case "sam2_track": return "Tracking pet"
        case "birefnet_refine": return "Refining edges"
        case "segment": return "Segmenting"
        case "normalize": return "Normalizing"
        default: return name
        }
    }
}

extension Notification.Name {
    static let processingComplete = Notification.Name("processingComplete")
    static let segmentationPoor = Notification.Name("segmentationPoor")
    static let processingFailed = Notification.Name("processingFailed")
}
