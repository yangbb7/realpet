import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

enum CubismWebRuntimeError: LocalizedError {
    case missingRuntimeResources
    case missingModel
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .missingRuntimeResources:
            return "缺少已授权的 Live2D Cubism Web Core/Runtime/Shaders"
        case .missingModel:
            return "Cubism 模型文件不存在"
        case .failedToStart:
            return "无法启动 Cubism WebGL 运行时"
        }
    }
}

enum CubismResourcePathResolver {
    static func resolve(url: URL, beneath root: URL) -> URL? {
        let relative = url.path.removingPercentEncoding?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        guard !relative.isEmpty else { return nil }

        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolvedRoot.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path : resolvedRoot.path + "/"
        return candidate.path.hasPrefix(rootPath) ? candidate : nil
    }
}

struct CubismWindowMotionPlan: Equatable {
    let targetOrigin: NSPoint
    let duration: TimeInterval
}

enum CubismWindowMotionPlanner {
    static func plan(
        action: PetCommand.Action,
        target: SpatialContext,
        windowFrame: NSRect,
        visibleFrame: NSRect,
        duration: TimeInterval,
        intensity: Double
    ) -> CubismWindowMotionPlan? {
        let targetPoint: NSPoint
        switch target.space {
        case .screenNormalized:
            targetPoint = NSPoint(
                x: visibleFrame.minX + target.x * visibleFrame.width,
                y: visibleFrame.minY + target.y * visibleFrame.height)
        case .petLocalNormalized:
            targetPoint = NSPoint(
                x: windowFrame.minX + target.x * windowFrame.width,
                y: windowFrame.minY + target.y * windowFrame.height)
        case .cameraNormalized:
            return nil
        }

        let center = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        let dx = targetPoint.x - center.x
        let dy = targetPoint.y - center.y
        let distance = max(0.001, hypot(dx, dy))
        let unit = NSPoint(x: dx / distance, y: dy / distance)
        let strength = min(1, max(0, intensity))
        let destinationCenter: NSPoint
        switch action {
        case .moveToward:
            let stopDistance = max(90, min(windowFrame.width, windowFrame.height) * 0.3)
            let travel = min(max(0, distance - stopDistance), 100 + strength * 260)
            destinationCenter = NSPoint(
                x: center.x + unit.x * travel,
                y: center.y + unit.y * travel)
        case .moveAway:
            let travel = 120 + strength * 260
            destinationCenter = NSPoint(
                x: center.x - unit.x * travel,
                y: center.y - unit.y * travel)
        case .moveTo:
            destinationCenter = targetPoint
        default:
            return nil
        }

        var origin = NSPoint(
            x: destinationCenter.x - windowFrame.width / 2,
            y: destinationCenter.y - windowFrame.height / 2)
        origin.x = min(
            visibleFrame.maxX - windowFrame.width,
            max(visibleFrame.minX, origin.x))
        origin.y = min(
            visibleFrame.maxY - windowFrame.height,
            max(visibleFrame.minY, origin.y))
        return CubismWindowMotionPlan(
            targetOrigin: origin,
            duration: min(10, max(0.2, duration)))
    }
}

private final class CubismURLSchemeHandler: NSObject, WKURLSchemeHandler {
    private let roots: [String: URL]

    init(sdkRoot: URL, modelRoot: URL) {
        roots = [
            "sdk": sdkRoot.standardizedFileURL,
            "model": modelRoot.standardizedFileURL,
        ]
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let host = url.host,
              let root = roots[host],
              let candidate = CubismResourcePathResolver.resolve(
                url: url, beneath: root),
              let data = try? Data(contentsOf: candidate) else {
            urlSchemeTask.didFailWithError(CubismWebRuntimeError.missingModel)
            return
        }
        let mimeType = UTType(filenameExtension: candidate.pathExtension)?
            .preferredMIMEType ?? "application/octet-stream"
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/")
                || mimeType.contains("javascript") ? "utf-8" : nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
final class CubismWebPetRuntime: NSObject, PetRuntimeController,
    WKScriptMessageHandler, NSWindowDelegate {

    let petId: UUID
    private let rendererKind = PetRendererKind.live2dCubism
    var onObservation: ((InteractionObservation) -> Void)?
    var onTermination: (() -> Void)?
    private(set) var isRunning = false

    private let modelURL: URL
    private let resources: CubismWebRuntimeResources
    private var window: NSWindow?
    private var webView: WKWebView?
    private var pointerTimer: Timer?
    private var schemeHandler: CubismURLSchemeHandler?
    private var ready = false
    private var terminated = false
    private var dragOrigin: NSPoint?
    private var pointerWasNear = false
    private var lastNearEmit: TimeInterval = 0
    private var lastPointerGazeParameters: [String: Double]?
    private var runtimePaused = false
    private var windowMotion: WindowMotion?
    private var pettingRecognizer = PettingGestureRecognizer()
    private var isPresentationActive: Bool

    private struct WindowMotion {
        let startOrigin: NSPoint
        let targetOrigin: NSPoint
        let startedAt: TimeInterval
        let duration: TimeInterval
    }

    init(
        petId: UUID,
        modelURL: URL,
        resources: CubismWebRuntimeResources,
        startHidden: Bool = false
    ) {
        self.petId = petId
        self.modelURL = modelURL.standardizedFileURL
        self.resources = resources
        isPresentationActive = !startHidden
    }

    func start() throws {
        guard resources.isComplete else {
            throw CubismWebRuntimeError.missingRuntimeResources
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw CubismWebRuntimeError.missingModel
        }

        let configuration = WKWebViewConfiguration()
        let schemeHandler = CubismURLSchemeHandler(
            sdkRoot: resources.root,
            modelRoot: modelURL.deletingLastPathComponent())
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "realpet")
        configuration.userContentController.add(self, name: "realpet")

        let size = NSSize(width: 420, height: 520)
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height)
        let window = NSWindow(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self

        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: size),
            configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = webView

        self.window = window
        self.webView = webView
        self.schemeHandler = schemeHandler
        isRunning = true
        terminated = false
        webView.loadHTMLString(hostHTML(), baseURL: URL(string: "realpet://sdk/"))
        if isPresentationActive {
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
        startPointerObservation()
    }

    func send(_ command: PetCommand) {
        guard isRunning,
              command.petId == petId,
              command.schemaVersion == PetCommand.currentSchemaVersion,
              command.expiresAt >= Date().timeIntervalSince1970 else { return }
        guard ready else {
            emitCommandResult(command, applied: false, reason: "runtime_not_ready")
            return
        }

        switch command.action {
        case .faceToward:
            guard let target = command.target,
                  let parameters = CubismParameterMapper.parameters(
                    target: target,
                    windowCenter: normalizedWindowCenter(),
                    intensity: command.intensity) else {
                emitCommandResult(command, applied: false, reason: "invalid_orientation_target")
                return
            }
            evaluate(function: "setParameters", argument: parameters)
            emitCommandResult(command, applied: true)
        case .pause:
            runtimePaused = true
            windowMotion = nil
            evaluate(function: "setPaused", argument: true)
            evaluate(function: "triggerAction", argument: actionPayload(
                action: .idle, duration: nil, intensity: 0))
            emitCommandResult(command, applied: true)
        case .resume:
            runtimePaused = false
            evaluate(function: "setPaused", argument: false)
            evaluate(function: "triggerAction", argument: actionPayload(
                action: .idle, duration: nil, intensity: 0.55))
            emitCommandResult(command, applied: true)
        case .react:
            let action: CubismSemanticAction
            switch command.animation {
            case .shakeHead: action = .shakeHead
            case .play: action = .play
            case .react, .lieDown, .paw, .eat, .none: action = .react
            }
            evaluate(function: "triggerAction", argument: actionPayload(
                action: action,
                duration: command.duration,
                intensity: command.intensity))
            emitCommandResult(command, applied: true)
        case .moveToward, .moveAway, .moveTo:
            guard startWindowMotion(command) else {
                emitCommandResult(command, applied: false, reason: "invalid_movement_target")
                return
            }
            emitCommandResult(command, applied: true)
        }
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        isRunning = false
        ready = false
        pointerTimer?.invalidate()
        pointerTimer = nil
        lastPointerGazeParameters = nil
        webView?.evaluateJavaScript("window.RealPetCubism?.release?.()")
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: "realpet")
        window?.orderOut(nil)
        window?.close()
        window = nil
        webView = nil
        schemeHandler = nil
        onTermination?()
    }

    func stop() {
        terminate()
    }

    func windowWillClose(_ notification: Notification) {
        terminate()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handleScriptMessage(message.body)
    }

    private func handleScriptMessage(_ body: Any) {
        guard let payload = body as? [String: Any],
              let type = payload["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            evaluate(function: "triggerAction", argument: actionPayload(
                action: .idle, duration: nil, intensity: 0.55))
            onObservation?(InteractionObservation(
                petId: petId,
                source: InteractionSource.system,
                kind: "runtime.ready",
                expiresAt: Date().timeIntervalSince1970 + 2,
                attributes: ["renderer": rendererKind.rawValue]))
        case "error":
            let detail = payload["message"] as? String ?? "unknown"
            onObservation?(InteractionObservation(
                petId: petId,
                source: InteractionSource.system,
                kind: "runtime.failed",
                expiresAt: Date().timeIntervalSince1970 + 3,
                attributes: ["renderer": "live2dCubism", "message": detail]))
            terminate()
        case "close":
            terminate()
        case "pointerEnter":
            pettingRecognizer.reset()
            emitPointer(kind: InteractionKind.pointerEntered, payload: payload)
        case "pointerLeave":
            pettingRecognizer.reset()
            emitPointer(kind: InteractionKind.pointerExited, payload: payload)
        case "pointerMove":
            recognizePetting(payload)
        case "dragStart":
            pettingRecognizer.reset()
            dragOrigin = window?.frame.origin
            emitPointer(kind: InteractionKind.dragStarted, payload: payload)
        case "dragMove":
            guard let origin = dragOrigin,
                  let dx = payload["dx"] as? Double,
                  let dy = payload["dy"] as? Double else { return }
            window?.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y - dy))
        case "dragEnd":
            dragOrigin = nil
            emitPointer(kind: InteractionKind.dragEnded, payload: payload)
        case "tap":
            emitPointer(kind: InteractionKind.petTapped, payload: payload)
        case "doubleTap":
            emitPointer(kind: InteractionKind.petDoubleTapped, payload: payload)
        default:
            break
        }
    }

    private func recognizePetting(_ payload: [String: Any]) {
        guard dragOrigin == nil,
              let webView,
              let x = payload["x"] as? Double,
              let y = payload["y"] as? Double else { return }
        let localX = min(1, max(0, x)) * webView.bounds.width
        let localY = min(1, max(0, y)) * webView.bounds.height
        guard pettingRecognizer.update(
            x: localX,
            y: localY,
            at: Date().timeIntervalSince1970
        ) else { return }
        showAffectionFeedback(x: x, y: y, intensity: 1)
        emitPointer(
            kind: InteractionKind.petPetted,
            payload: payload,
            expiresAfter: 1.2,
            attributes: ["gesture": "back_and_forth"])
    }

    private func emitPointer(
        kind: String,
        payload: [String: Any],
        expiresAfter: TimeInterval = 1,
        attributes: [String: String] = [:]
    ) {
        let x = min(1, max(0, payload["x"] as? Double ?? 0.5))
        let browserY = min(1, max(0, payload["y"] as? Double ?? 0.5))
        onObservation?(InteractionObservation(
            petId: petId,
            source: InteractionSource.pointer,
            kind: kind,
            expiresAt: Date().timeIntervalSince1970 + expiresAfter,
            spatial: SpatialContext(
                space: .petLocalNormalized, x: x, y: 1 - browserY),
            attributes: attributes))
    }

    private func startPointerObservation() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.observePointer() }
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observePointer() {
        guard let window, isRunning, isPresentationActive,
              dragOrigin == nil else { return }
        updateWindowMotion()
        let pointer = NSEvent.mouseLocation
        let frame = window.frame
        updatePointerGaze(pointer: pointer, windowFrame: frame)
        let distance = hypot(pointer.x - frame.midX, pointer.y - frame.midY)
        let nearLimit = max(frame.width, frame.height) * 0.65 + 70
        let isNear = distance <= nearLimit
        let now = Date().timeIntervalSince1970
        if isNear && (!pointerWasNear || now - lastNearEmit >= 0.45),
           let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let spatial = SpatialContext(
                space: .screenNormalized,
                x: min(1, max(0, (pointer.x - visible.minX) / visible.width)),
                y: min(1, max(0, (pointer.y - visible.minY) / visible.height)))
            onObservation?(InteractionObservation(
                petId: petId,
                source: InteractionSource.pointer,
                kind: InteractionKind.pointerNear,
                expiresAt: now + 0.8,
                spatial: spatial,
                attributes: ["distance": String(format: "%.1f", distance)]))
            lastNearEmit = now
        }
        pointerWasNear = isNear
    }

    private func updatePointerGaze(pointer: NSPoint, windowFrame: NSRect) {
        guard ready, !runtimePaused else { return }
        let horizontalReach = max(180, windowFrame.width * 1.15)
        let verticalReach = max(220, windowFrame.height * 0.90)
        let parameters = CubismParameterMapper.parameters(
            normalizedDeltaX: (pointer.x - windowFrame.midX) / horizontalReach,
            normalizedDeltaY: (pointer.y - windowFrame.midY) / verticalReach,
            intensity: 0.9)
        if let previous = lastPointerGazeParameters,
           parameters.allSatisfy({ entry in
               abs(entry.value - (previous[entry.key] ?? 0)) < 0.002
           }) { return }
        lastPointerGazeParameters = parameters
        evaluate(function: "setParameters", argument: parameters)
    }

    private func startWindowMotion(_ command: PetCommand) -> Bool {
        guard !runtimePaused,
              let window,
              let screen = window.screen ?? NSScreen.main,
              let target = command.target,
              let plan = CubismWindowMotionPlanner.plan(
                action: command.action,
                target: target,
                windowFrame: window.frame,
                visibleFrame: screen.visibleFrame,
                duration: command.duration,
                intensity: command.intensity) else { return false }
        windowMotion = WindowMotion(
            startOrigin: window.frame.origin,
            targetOrigin: plan.targetOrigin,
            startedAt: Date().timeIntervalSince1970,
            duration: plan.duration)
        evaluate(function: "triggerAction", argument: actionPayload(
            action: .walk,
            duration: plan.duration,
            intensity: command.intensity))
        return true
    }

    private func updateWindowMotion() {
        guard !runtimePaused, let window, let motion = windowMotion else { return }
        let elapsed = Date().timeIntervalSince1970 - motion.startedAt
        let progress = min(1, max(0, elapsed / motion.duration))
        let eased = progress * progress * (3 - 2 * progress)
        window.setFrameOrigin(NSPoint(
            x: motion.startOrigin.x
                + (motion.targetOrigin.x - motion.startOrigin.x) * eased,
            y: motion.startOrigin.y
                + (motion.targetOrigin.y - motion.startOrigin.y) * eased))
        if progress >= 1 {
            windowMotion = nil
            evaluate(function: "triggerAction", argument: actionPayload(
                action: .idle, duration: nil, intensity: 0.55))
        }
    }

    private func actionPayload(
        action: CubismSemanticAction,
        duration: TimeInterval?,
        intensity: Double
    ) -> [String: Any] {
        let clip = CubismProceduralMotionSynthesizer.clip(
            action: action,
            duration: action.loops ? action.defaultDuration : duration,
            intensity: intensity)
        return [
            "action": action.rawValue,
            "duration": max(0.2, duration ?? clip.duration),
            "intensity": min(1, max(0, intensity)),
            "clip": clip.jsonObject,
        ]
    }

    private func normalizedWindowCenter() -> (x: Double, y: Double)? {
        guard let window,
              let screen = window.screen ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        return (
            (window.frame.midX - visible.minX) / visible.width,
            (window.frame.midY - visible.minY) / visible.height)
    }

    private func evaluate(function: String, argument: Any) {
        guard JSONSerialization.isValidJSONObject(["value": argument]),
              let data = try? JSONSerialization.data(
                withJSONObject: argument, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript(
            "window.RealPetCubism?.\(function)?.(\(json))")
    }

    private func showAffectionFeedback(
        x: Double,
        y: Double,
        intensity: Double
    ) {
        let argument: [String: Double] = [
            "x": min(1, max(0, x)),
            "y": min(1, max(0, y)),
            "intensity": min(1, max(0, intensity)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: argument),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.RealPetFeedback?.show?.(\(json))")
    }

    private func emitCommandResult(
        _ command: PetCommand,
        applied: Bool,
        reason: String? = nil
    ) {
        var attributes = [
            "commandId": command.id.uuidString,
            "action": command.action.rawValue,
            "renderer": "live2dCubism",
        ]
        if let reason { attributes["reason"] = reason }
        onObservation?(InteractionObservation(
            petId: petId,
            source: InteractionSource.system,
            kind: applied ? "runtime.command_applied" : "runtime.command_rejected",
            expiresAt: Date().timeIntervalSince1970 + 2,
            attributes: attributes))
    }

    private func hostHTML() -> String {
        let modelName = modelURL.lastPathComponent
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? modelURL.lastPathComponent
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        html,body,canvas{width:100%;height:100%;margin:0;background:transparent;overflow:hidden}
        canvas{display:block;cursor:grab} canvas:active{cursor:grabbing}
        #affection{position:fixed;inset:0;pointer-events:none;overflow:hidden;z-index:1}
        .heart{position:absolute;width:12px;height:12px;background:#ff385f;
          opacity:0;transform:translate(-50%,-20%) rotate(45deg);
          animation:heart-rise 900ms ease-out forwards;animation-delay:var(--delay)}
        .heart:before,.heart:after{content:'';position:absolute;width:100%;height:100%;
          border-radius:50%;background:inherit}
        .heart:before{left:-50%;top:0}.heart:after{left:0;top:-50%}
        @keyframes heart-rise{0%{opacity:0;transform:translate(-50%,-20%) scale(.65) rotate(45deg)}
          14%{opacity:.96}100%{opacity:0;
          transform:translate(calc(-50% + var(--drift)),-70px) scale(1.15) rotate(45deg)}}
        #close{position:fixed;right:8px;top:8px;width:24px;height:24px;border:0;
          border-radius:50%;background:rgba(20,20,20,.42);color:white;font-size:18px;
          line-height:22px;padding:0;z-index:2}
        </style></head><body><canvas id="pet"></canvas><div id="affection"></div>
        <button id="close" title="Close">×</button>
        <script src="realpet://sdk/live2dcubismcore.min.js"></script>
        <script src="realpet://sdk/realpet-cubism.bundle.js"></script>
        <script>
        const post = value => window.webkit.messageHandlers.realpet.postMessage(value);
        const canvas = document.getElementById('pet');
        const affection = document.getElementById('affection');
        const point = e => { const rect=canvas.getBoundingClientRect(); return {
          x:Math.max(0,Math.min(1,(e.clientX-rect.left)/Math.max(1,rect.width))),
          y:Math.max(0,Math.min(1,(e.clientY-rect.top)/Math.max(1,rect.height)))}; };
        window.RealPetFeedback={show:({x,y,intensity=1})=>{
          for(let i=0;i<3;i++){const heart=document.createElement('i');
            heart.className='heart';heart.style.left=`${Math.max(0,Math.min(1,x))*100}%`;
            heart.style.top=`${Math.max(0,Math.min(1,y))*100}%`;
            heart.style.setProperty('--delay',`${i*85}ms`);
            heart.style.setProperty('--drift',`${(i-1)*(10+intensity*5)}px`);
            const size=9+Math.max(0,Math.min(1,intensity))*5+i;
            heart.style.width=`${size}px`;heart.style.height=`${size}px`;
            affection.appendChild(heart);heart.addEventListener('animationend',()=>heart.remove());
          }} };
        document.getElementById('close').onclick = () => post({type:'close'});
        let drag = null, moved = false;
        canvas.onpointerenter=e=>post({type:'pointerEnter',...point(e)});
        canvas.onpointerleave=e=>{if(!drag)post({type:'pointerLeave',...point(e)});};
        canvas.onpointerdown = e => { const p=point(e); drag={x:e.screenX,y:e.screenY}; moved=false;
          canvas.setPointerCapture(e.pointerId); post({type:'dragStart',...p}); };
        canvas.onpointermove = e => { const p=point(e); if(!drag){post({type:'pointerMove',...p});return;}
          const dx=e.screenX-drag.x,dy=e.screenY-drag.y;
          moved=moved||Math.abs(dx)+Math.abs(dy)>3; post({type:'dragMove',dx,dy}); };
        canvas.onpointerup = e => { if(!drag)return; const p=point(e);
          post({type:'dragEnd',...p}); if(!moved){window.RealPetFeedback.show({...p,intensity:.65});
          post({type:'tap',...p});} drag=null; };
        canvas.onpointercancel = e => {if(!drag)return;post({type:'dragEnd',...point(e)});
          drag=null;moved=false;};
        canvas.ondblclick = e => {const p=point(e);window.RealPetFeedback.show({...p,intensity:1});
          post({type:'doubleTap',...p});};
        window.RealPetCubism.boot({canvas,
          modelUrl:'realpet://model/\(modelName)', shaderPath:'realpet://sdk/shaders/',
          templateUrl:'realpet://model/realpet-template.json',
          onReady:()=>post({type:'ready'}), onError:m=>post({type:'error',message:m})
        }).catch(e=>post({type:'error',message:String(e)}));
        </script></body></html>
        """
    }
}
