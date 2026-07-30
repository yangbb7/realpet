import AppKit
import Combine
import SwiftUI

@main
struct RealPetMain {
    static func main() {
        if provisionImageServiceCredentialFromStandardInput() { return }
        if provisionPromptServiceCredentialFromStandardInput() { return }
        if provisionAgnesServiceCredentialFromStandardInput() { return }
        if provisionMotionServiceCredentialFromStandardInput() { return }
        if configureMotionServiceFromCommandLine() { return }
        if configureAgnesMotionServiceFromCommandLine() { return }
        if exportOriginalRigAtlasFromCommandLine() { return }
        if exportOriginalRigTorsoFromCommandLine() { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        ApplicationMenu.install(on: app)
        app.run()
    }

    private static func provisionImageServiceCredentialFromStandardInput() -> Bool {
        guard CommandLine.arguments.contains(
            "--provision-image-service-credential") else { return false }
        guard let input = readLine(strippingNewline: true) else {
            fputs("RealPet: missing image service credential on stdin\n", stderr)
            exit(EXIT_FAILURE)
        }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            fputs("RealPet: image service credential is empty\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            try OpenAIAPIKeyStore.save(key)
        } catch {
            fputs("RealPet: failed to provision image service credential\n", stderr)
            exit(EXIT_FAILURE)
        }
        return true
    }

    private static func provisionMotionServiceCredentialFromStandardInput() -> Bool {
        guard CommandLine.arguments.contains(
            "--provision-motion-service-credential") else { return false }
        guard let input = readLine(strippingNewline: true) else {
            fputs("RealPet: missing motion service credential on stdin\n", stderr)
            exit(EXIT_FAILURE)
        }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            fputs("RealPet: motion service credential is empty\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            try OpenAIAPIKeyStore.saveMotionService(key)
        } catch {
            fputs("RealPet: failed to provision motion service credential\n", stderr)
            exit(EXIT_FAILURE)
        }
        return true
    }

    private static func provisionPromptServiceCredentialFromStandardInput() -> Bool {
        guard CommandLine.arguments.contains(
            "--provision-prompt-service-credential") else { return false }
        guard let input = readLine(strippingNewline: true) else {
            fputs("RealPet: missing prompt service credential on stdin\n", stderr)
            exit(EXIT_FAILURE)
        }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            fputs("RealPet: prompt service credential is empty\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            try OpenAIAPIKeyStore.savePromptMotionService(key)
        } catch {
            fputs("RealPet: failed to provision prompt service credential\n", stderr)
            exit(EXIT_FAILURE)
        }
        return true
    }

    private static func provisionAgnesServiceCredentialFromStandardInput() -> Bool {
        guard CommandLine.arguments.contains(
            "--provision-agnes-service-credential") else { return false }
        guard let input = readLine(strippingNewline: true) else {
            fputs("RealPet: missing Agnes service credential on stdin\n", stderr)
            exit(EXIT_FAILURE)
        }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            fputs("RealPet: Agnes service credential is empty\n", stderr)
            exit(EXIT_FAILURE)
        }
        do {
            try OpenAIAPIKeyStore.saveAgnesMotionService(key)
        } catch {
            fputs("RealPet: failed to provision Agnes service credential\n", stderr)
            exit(EXIT_FAILURE)
        }
        return true
    }

    private static func configureMotionServiceFromCommandLine() -> Bool {
        guard let flagIndex = CommandLine.arguments.firstIndex(
            of: "--configure-motion-service") else { return false }
        let values = Array(CommandLine.arguments.dropFirst(flagIndex + 1))
        guard values.count == 7, let seconds = Int(values[5]) else {
            fputs(
                "RealPet: expected prompt Base URL, prompt model, Agnes Base URL, image model, video model, seconds, and size\n",
                stderr)
            exit(EXIT_FAILURE)
        }
        do {
            let configuration = try MotionServiceConfiguration(
                baseURLString: values[0],
                promptModel: values[1],
                agnesBaseURLString: values[2],
                imageModel: values[3],
                videoModel: values[4],
                seconds: seconds,
                size: values[6]).validated()
            MotionServiceConfigurationStore.save(configuration)
        } catch {
            fputs("RealPet: invalid motion service configuration\n", stderr)
            exit(EXIT_FAILURE)
        }
        return true
    }

    private static func configureAgnesMotionServiceFromCommandLine() -> Bool {
        guard let flagIndex = CommandLine.arguments.firstIndex(
            of: "--configure-agnes-motion-service") else { return false }
        let values = Array(CommandLine.arguments.dropFirst(flagIndex + 1))
        guard values.count == 5, let seconds = Int(values[3]) else {
            fputs(
                "RealPet: expected Agnes Base URL, image model, video model, seconds, and size\n",
                stderr)
            exit(EXIT_FAILURE)
        }
        let current = MotionServiceConfigurationStore.load()
        do {
            let configuration = try MotionServiceConfiguration(
                baseURLString: current.baseURLString,
                promptModel: current.promptModel,
                agnesBaseURLString: values[0],
                imageModel: values[1],
                videoModel: values[2],
                seconds: seconds,
                size: values[4]).validated()
            MotionServiceConfigurationStore.save(configuration)
        } catch {
            fputs("RealPet: invalid Agnes motion service configuration\n", stderr)
            exit(EXIT_FAILURE)
        }
        return true
    }

    private static func exportOriginalRigAtlasFromCommandLine() -> Bool {
        let request: OriginalRigAtlasExportRequest
        do {
            guard let parsed = try OriginalRigAtlasExportRequest.parse(
                arguments: CommandLine.arguments) else { return false }
            request = parsed
        } catch {
            fputs("RealPet: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        Task {
            do {
                try await OriginalRigAtlasExporter.export(request)
                fputs("RealPet: original rig atlas exported\n", stdout)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("RealPet: original rig atlas export failed: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }

    private static func exportOriginalRigTorsoFromCommandLine() -> Bool {
        let request: OriginalRigTorsoExportRequest
        do {
            guard let parsed = try OriginalRigTorsoExportRequest.parse(
                arguments: CommandLine.arguments) else { return false }
            request = parsed
        } catch {
            fputs("RealPet: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        Task {
            do {
                try await OriginalRigTorsoExporter.export(request)
                fputs("RealPet: original rig torso exported\n", stdout)
                exit(EXIT_SUCCESS)
            } catch {
                fputs("RealPet: original rig torso export failed: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var vm: PetListViewModel!
    var daemon: PythonDaemon!

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // v0.2.0: first launch may need Python+venv setup. Run the wizard
        // before starting the pipeline; otherwise jump straight to the UI.
        SetupWizard.runIfNeeded { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .ready:
                self.startServicesAndUI()
            case .aborted(let message):
                self.showSetupFailure(message)
            }
        }
    }

    @MainActor
    private func startServicesAndUI() {
        vm = PetListViewModel()

        // Start resident Python daemon (Phase 1: detector for QC + detect).
        daemon = PythonDaemon()
        vm.pythonBridge.daemon = daemon
        daemon.onCrash = { [weak self] in
            // Auto-restart on crash (best-effort; next call will use
            // subprocess fallback if restart fails).
            self?.daemon.start()
        }
        daemon.start()

        // 创建主窗口
        let contentView = NSHostingController(
            rootView: MainPanelView(bridge: vm.pythonBridge)
                .environmentObject(vm)
        )

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Manually-created NSWindows default to isReleasedWhenClosed = true,
        // which DEALLOCATES the window when the user clicks the red close
        // button — after that the menu-bar icon can no longer bring it back.
        // Keep the object alive so closing just hides it and the menu-bar icon
        // reopens it.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = contentView
        window.contentMinSize = NSSize(width: 320, height: 260)
        window.setContentSize(NSSize(width: 320, height: 300))
        window.title = "RealPet"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.level = .floating  // 置顶
        NSApp.activate(ignoringOtherApps: true)

        // 菜单栏图标：关掉窗口后从这里重新打开
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pawprint.fill",
                                   accessibilityDescription: "RealPet")
            button.toolTip = "RealPet — 点击显示/隐藏窗口"
            button.action = #selector(toggleWindow)
            button.target = self
        }

        // Size the window for each interactive state. The ScrollView remains as
        // a fallback on smaller screens or when many pets are listed.
        vm.pythonBridge.$isProcessing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isProcessing in
                guard let self = self else { return }
                let visibleHeight = self.window.screen?.visibleFrame.height
                    ?? NSScreen.main?.visibleFrame.height ?? 730
                let size = MainWindowLayout.contentSize(
                    hasClipSelection: false,
                    hasDetection: false,
                    isProcessing: isProcessing,
                    visibleHeight: visibleHeight)
                self.window.setContentSize(size)
                self.window.center()  // re-center after resize
            }
            .store(in: &cancellables)

        #if DEBUG
        if ProcessInfo.processInfo.environment["REALPET_UI_TEST_VLM_SETUP"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.vm.showVisionModelSetup = true
            }
        }
        if ProcessInfo.processInfo.environment[
            "REALPET_UI_TEST_PERSONALITY_SETUP"] == "1",
           let pet = vm.pets.first {
            DispatchQueue.main.async { [weak self] in
                self?.vm.presentPersonalityEditor(for: pet)
            }
        }
        if ProcessInfo.processInfo.environment["REALPET_UI_TEST_SHOW_FIRST_PET"] == "1",
           let pet = vm.pets.first {
            DispatchQueue.main.async { [weak self] in
                self?.vm.showPet(pet)
            }
        }
        if ProcessInfo.processInfo.environment["REALPET_UI_TEST_MOTION_STUDIO"] == "1",
           let pet = vm.pets.first {
            DispatchQueue.main.async { [weak self] in
                // Screenshot automation exercises the sheet layout without
                // issuing a network request or changing owner data.
                self?.vm.motionStudioPet = pet
            }
        }
        if let screenshotPath = ProcessInfo.processInfo.environment[
            "REALPET_UI_TEST_SCREENSHOT_PATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self,
                      let sheet = NSApp.windows.first(where: {
                          $0 !== self.window
                              && $0.isVisible
                              && ($0.contentView?.bounds.width ?? 0) >= 400
                      }),
                      let view = sheet.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(
                        in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: screenshotPath))
            }
        }
        if let screenshotPath = ProcessInfo.processInfo.environment[
            "REALPET_UI_TEST_MAIN_SCREENSHOT_PATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let view = self?.window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(
                        in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: screenshotPath))
            }
        }
        #endif
    }

    @MainActor
    private func showSetupFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "RealPet Setup Required"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Window delegate

    // Main window: hide instead of destroy.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }

    // Double-clicking the app in Finder / clicking its Dock icon when it's
    // already running (window hidden) fires this. Without it, re-launching a
    // running instance does nothing visible — which reads as "the app won't
    // open". Bring the main window back to the front.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    @objc func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        vm?.pythonBridge.shutdown()
        vm?.petLauncher.stopAll()
        return .terminateNow
    }
}
