import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var controller: EffectController?
    private var settingsWindow: SettingsWindowController?
    private var previewWindow: PreviewWindowController?
    private var cancellables = Set<AnyCancellable>()

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let angleItem = NSMenuItem(title: "Lid angle: —", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard let controller = EffectController() else {
            fatal("Clamshell couldn't start Metal on this Mac.")
            return
        }
        self.controller = controller

        buildStatusItem()

        guard requireScreenRecording() else { return }

        controller.start()
        observe(controller)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    // MARK: - Permission

    /// Screen Recording isn't optional — the pane is built out of the live
    /// display, so there is nothing to render without it.
    private func requireScreenRecording() -> Bool {
        if ScreenCapturer.hasPermission() { return true }

        ScreenCapturer.requestPermission()

        let alert = NSAlert()
        alert.messageText = "Clamshell needs Screen Recording"
        alert.informativeText = """
            The frosted pane is built out of your live display, so macOS \
            requires Screen Recording permission.

            Enable Clamshell under Privacy & Security → Screen Recording, \
            then launch it again.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
        return false
    }

    private func fatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer",
                                   accessibilityDescription: "Clamshell")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }

        let menu = NSMenu()
        enabledItem.target = self
        enabledItem.state = Settings.shared.enabled ? .on : .off
        menu.addItem(enabledItem)

        angleItem.isEnabled = false
        menu.addItem(angleItem)

        statusLine.isEnabled = false
        statusLine.isHidden = true
        menu.addItem(statusLine)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Preview…", action: #selector(openPreview), keyEquivalent: "p").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clamshell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func observe(_ controller: EffectController) {
        // Menu bar text only needs to keep up with the eye, not the sensor.
        controller.$angle
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] angle in
                guard let self else { return }
                self.angleItem.title = String(format: "Lid angle: %.1f°", angle)
                if Settings.shared.showAngleInMenuBar {
                    self.statusItem.button?.title = String(format: " %.0f°", angle)
                }
            }
            .store(in: &cancellables)

        controller.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.statusLine.title = message ?? ""
                self?.statusLine.isHidden = (message == nil)
            }
            .store(in: &cancellables)

        Settings.shared.$showAngleInMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if !show { self?.statusItem.button?.title = "" }
            }
            .store(in: &cancellables)

        if !controller.sensorAvailable {
            angleItem.title = "No lid-angle sensor"
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        enabledItem.state = Settings.shared.enabled ? .on : .off
    }

    @objc private func openSettings() {
        guard let controller else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(controller: controller)
        }
        settingsWindow?.present()
    }

    @objc private func openPreview() {
        guard let controller else { return }
        if previewWindow == nil {
            previewWindow = PreviewWindowController(controller: controller)
        }
        previewWindow?.present()
    }
}
