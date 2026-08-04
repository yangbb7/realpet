import Foundation

/// Manages an on-demand Python daemon that keeps the Faster R-CNN detector
/// warm across closely spaced QC / detect calls without retaining it for the
/// entire desktop session.
///
/// Phase 1: Only `qc` and `detect` go through the daemon.  `process`
/// (SAM2 + BiRefNet) still runs as a separate subprocess.
@MainActor
final class PythonDaemon: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isRunning = false

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Registered per-request callbacks, keyed by request ID.
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private struct QueuedRequest {
        let command: String
        let arguments: [String: Any]
        let callback: ([String: Any]) -> Void
    }
    private var queued: [Int: QueuedRequest] = [:]
    private var nextId: Int = 1
    private var stdoutBuffer = ""
    private var intentionallyStoppedPIDs: Set<Int32> = []
    private var idleTermination: DispatchWorkItem?

    // Keep the interpreter warm across a short editing session, then release
    // its model memory instead of holding it for the whole app lifetime.
    private static let idleTimeout: TimeInterval = 120

    /// Callback invoked when the daemon dies unexpectedly.
    var onCrash: (() -> Void)?

    // MARK: - Lifecycle

    /// Start the daemon process.  No-op if already running.
    func start() {
        guard process == nil else { return }
        cancelIdleTermination()

        guard let python = PythonBridge.findTrackMattePython() else {
            PythonBridge.log("PythonDaemon: no Python found")
            failQueuedRequests(message: "detector Python is unavailable")
            return
        }

        let script = PythonBridge.projectRoot.appendingPathComponent("scripts/daemon.py")
        let proc = Process()
        proc.executableURL = python
        proc.arguments = [script.path]
        proc.environment = PythonBridge.subprocessEnvironment()
        proc.currentDirectoryURL = PythonBridge.projectRoot

        let inp = Pipe()   // stdin → daemon
        let out = Pipe()   // daemon → stdout
        let err = Pipe()   // daemon → stderr (log only)
        proc.standardInput = inp
        proc.standardOutput = out
        proc.standardError = err

        // Read stdout in background — parse NDJSON lines.
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleStdoutChunk(chunk)
            }
        }

        // Log stderr for debugging.
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.isEmpty {
                PythonBridge.log("PythonDaemon stderr: \(s)")
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let intentional = self.intentionallyStoppedPIDs.remove(
                    p.processIdentifier) != nil
                PythonBridge.log("PythonDaemon exited with code \(p.terminationStatus)")
                // An intentionally-stopped old process may finish after a new
                // daemon was started. Never let its callback clear the new one.
                if self.process === p {
                    self.process = nil
                    self.isRunning = false
                    self.isReady = false
                    self.stdinPipe = nil
                    self.stdoutPipe = nil
                    self.stderrPipe = nil
                    for (_, cb) in self.pending {
                        cb(["type": "error", "message": "daemon exited unexpectedly"])
                    }
                    self.pending.removeAll()
                    self.failQueuedRequests(message: "daemon exited unexpectedly")
                }
                if !intentional {
                    self.onCrash?()
                }
            }
        }

        do {
            try proc.run()
        } catch {
            PythonBridge.log("PythonDaemon failed to start: \(error)")
            failQueuedRequests(message: "detector daemon failed to start")
            return
        }

        process = proc
        stdinPipe = inp
        stdoutPipe = out
        stderrPipe = err
        isRunning = true
        PythonBridge.log("PythonDaemon started pid=\(proc.processIdentifier)")
    }

    /// Terminate the daemon cleanly.
    func terminate() {
        guard let proc = process else { return }
        cancelIdleTermination()
        intentionallyStoppedPIDs.insert(proc.processIdentifier)
        // Close stdin → daemon's for-loop exits → clean sys.exit(0)
        stdinPipe?.fileHandleForWriting.closeFile()
        // Give it a moment, then hard-kill if stuck.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning {
                proc.terminate()
            }
        }
        process = nil
        isRunning = false
        isReady = false
        pending.removeAll()
        queued.removeAll()
        PythonBridge.log("PythonDaemon terminated")
    }

    // MARK: - Send

    /// Sends a request once the detector is ready. Requests issued while the
    /// daemon is starting are queued so the caller never starts a duplicate
    /// subprocess just because model warm-up is still in progress.
    @discardableResult
    func send(cmd: String, args: [String: Any],
              onLine: @escaping ([String: Any]) -> Void) -> Int {
        let id = nextId
        nextId += 1
        cancelIdleTermination()
        let request = QueuedRequest(
            command: cmd, arguments: args, callback: onLine)
        guard let proc = process, proc.isRunning, isReady else {
            queued[id] = request
            start()
            return id
        }
        sendReadyRequest(id: id, request: request)
        return id
    }

    /// Starts detector warm-up without requiring a request. It is used at the
    /// beginning of an import so video analysis can overlap model loading.
    func warm() {
        cancelIdleTermination()
        start()
    }

    private func sendReadyRequest(id: Int, request: QueuedRequest) {
        guard let proc = process, proc.isRunning,
              let handle = stdinPipe?.fileHandleForWriting else {
            isReady = false
            request.callback(["type": "error", "message": "daemon not running"])
            return
        }

        var payload = request.arguments
        payload["id"] = id
        payload["cmd"] = request.command

        let line: String
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: data, encoding: .utf8) {
            line = s + "\n"
        } else {
            request.callback(["type": "error", "message": "failed to encode request"])
            return
        }

        // Writing to a broken pipe raises SIGPIPE/throws — catch it, mark the
        // daemon dead, and fail this request so the caller can retry via
        // subprocess instead of hanging.
        pending[id] = request.callback
        do {
            try handle.write(contentsOf: line.data(using: .utf8)!)
        } catch {
            pending.removeValue(forKey: id)
            isReady = false
            PythonBridge.log("PythonDaemon: write failed (\(error)), marking dead")
            request.callback(["type": "error", "message": "daemon write failed"])
        }
    }

    /// Cancel a pending request by ID (best-effort — daemon may already be
    /// processing it; Phase 1 does not support mid-request cancellation).
    func cancel(id: Int) {
        pending.removeValue(forKey: id)
        queued.removeValue(forKey: id)
        scheduleIdleTerminationIfNeeded()
    }

    // MARK: - stdout parsing

    private func handleStdoutChunk(_ chunk: String) {
        stdoutBuffer += chunk
        while let range = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<range.lowerBound])
            stdoutBuffer = String(stdoutBuffer[range.upperBound...])
            parseLine(line)
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            PythonBridge.log("PythonDaemon: unparseable line: \(line)")
            return
        }

        // Ready signal (id=0, type=ready) — mark daemon as ready.
        if msg["type"] as? String == "ready" {
            isReady = true
            PythonBridge.log("PythonDaemon: ready")
            drainQueuedRequests()
            scheduleIdleTerminationIfNeeded()
            return
        }

        // Route by request ID.
        guard let id = msg["id"] as? Int else { return }

        if let cb = pending[id] {
            cb(msg)
            // Remove callback when the terminal "done" line arrives.
            if msg["done"] as? Bool == true {
                pending.removeValue(forKey: id)
                scheduleIdleTerminationIfNeeded()
            }
        }
    }

    private func drainQueuedRequests() {
        let requests = queued
        queued.removeAll()
        for (id, request) in requests.sorted(by: { $0.key < $1.key }) {
            sendReadyRequest(id: id, request: request)
        }
    }

    private func failQueuedRequests(message: String) {
        let requests = queued
        queued.removeAll()
        for (_, request) in requests {
            request.callback(["type": "error", "message": message])
        }
    }

    private func scheduleIdleTerminationIfNeeded() {
        guard pending.isEmpty, queued.isEmpty, process != nil else { return }
        cancelIdleTermination()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.pending.isEmpty,
                      self.queued.isEmpty else { return }
                self.terminate()
            }
        }
        idleTermination = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.idleTimeout,
            execute: work)
    }

    private func cancelIdleTermination() {
        idleTermination?.cancel()
        idleTermination = nil
    }
}
