import AppKit
import Combine
import SwiftUI

@main
struct RealPetMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        ApplicationMenu.install(on: app)
        app.run()
    }

}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var vm: PetListViewModel!
    var daemon: PythonDaemon!

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A missing venv must not keep the account console from opening.
        // SetupWizard is requested by the first media-processing operation.
        startServicesAndUI()
    }

    @MainActor
    private func startServicesAndUI() {
        vm = PetListViewModel()
        RuntimeMetrics.recordStartup()

        // The detector daemon starts only when an import needs it.
        daemon = PythonDaemon()
        vm.pythonBridge.daemon = daemon
        vm.requestPipelineSetup = { completion in
            SetupWizard.runIfNeeded { outcome in
                switch outcome {
                case .ready:
                    completion(nil)
                case .aborted(let message):
                    completion(message)
                }
            }
        }
        daemon.onCrash = {
            // Do not retain a large detector process after a crash; a later
            // import will create it again on demand.
            PythonBridge.log("PythonDaemon crashed; waiting for next import")
        }

        // 创建主窗口
        let contentView = NSHostingController(
            rootView: RealPetRootView(bridge: vm.pythonBridge)
                .environmentObject(vm)
        )

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
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
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.setContentSize(NSSize(width: 560, height: 540))
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

        // The four-column action grid fits in a compact default window. A
        // processing state gets a little extra vertical space for its status.
        vm.pythonBridge.$isProcessing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resizeActionConsole()
            }
            .store(in: &cancellables)
        vm.$pets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeActionConsole() }
            .store(in: &cancellables)
        vm.$motionComposerPet
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeActionConsole() }
            .store(in: &cancellables)
        SupabaseGoogleLoginCoordinator.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeActionConsole() }
            .store(in: &cancellables)
        resizeActionConsole()

        #if DEBUG
        if ProcessInfo.processInfo.environment["REALPET_UI_TEST_SHOW_FIRST_PET"] == "1",
           let pet = vm.pets.first {
            DispatchQueue.main.async { [weak self] in
                self?.vm.showPet(pet)
            }
        }
        if ProcessInfo.processInfo.environment["REALPET_UI_TEST_MOTION_STUDIO"] == "1",
           let pet = vm.pets.first {
            DispatchQueue.main.async { [weak self] in
                // Screenshot automation exercises the inline action composer
                // without issuing a network request or changing owner data.
                self?.vm.presentMotionComposer(for: pet)
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
    private func resizeActionConsole() {
        guard let window, let vm else { return }
        // Pet visibility and scale updates publish through `vm.$pets`. Keep
        // the console where the owner put it while its content height changes.
        let origin = window.frame.origin
        let visibleHeight = window.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height ?? 820
        let desiredHeight: CGFloat
        if !SupabaseGoogleLoginCoordinator.shared.state.isSignedIn {
            desiredHeight = 360
        } else if vm.motionComposerPet != nil {
            desiredHeight = 720
        } else if vm.pet != nil {
            desiredHeight = vm.pythonBridge.isProcessing ? 600 : 540
        } else {
            desiredHeight = vm.pythonBridge.isProcessing ? 460 : 390
        }
        let height = min(desiredHeight, max(360, visibleHeight - 80))
        window.setContentSize(NSSize(width: 560, height: height))
        window.setFrameOrigin(origin)
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
