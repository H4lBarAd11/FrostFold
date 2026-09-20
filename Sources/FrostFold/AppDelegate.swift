import AppKit
import Combine

/// A second launch asks the running copy for a window by leaving a note, then
/// reopening the app. Distributed notifications looked tidier but are not
/// reliably delivered to a background-only process; a reopen always lands.
enum PendingWindow {
    private static let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("io.github.frostfold.pending")

    static func request(_ value: String) {
        try? value.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads and clears the note, so it is acted on exactly once.
    static func take() -> String? {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: EffectController?
    private var settingsWindow: SettingsWindowController?
    private var previewWindow: PreviewWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var requestTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock icon (LSUIElement) and no status item: FrostFold runs in the
        // background and is reached by launching it again.
        NSApp.setActivationPolicy(.accessory)

        guard let controller = EffectController() else {
            fatal("FrostFold couldn't start Metal on this Mac.")
            return
        }
        self.controller = controller

        guard requireScreenRecording() else { return }

        controller.start()

        // Anything left over from a previous run is stale; don't act on it.
        _ = PendingWindow.take()
        watchForRequests()

        controller.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                // A problem the user cannot otherwise see, because there is no
                // menu bar item to show it in.
                if let message { self?.report(message) }
            }
            .store(in: &cancellables)

        // First run has nothing on screen to discover, so show the settings
        // once and let the user find everything from there.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        requestTimer?.invalidate()
        controller?.stop()
    }

    /// A second launch leaves a note rather than talking to us directly, so we
    /// look for one. A stat twice a second costs nothing next to the renderer.
    private func watchForRequests() {
        requestTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            switch PendingWindow.take() {
            case "preview":  self?.openPreview()
            case "settings": self?.openSettings()
            default: break
            }
        }
    }

    /// Launching FrostFold while it is already running brings up a window
    /// rather than starting a second copy.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if PendingWindow.take() == "preview" { openPreview() } else { openSettings() }
        return true
    }

    // MARK: - Permission

    /// Screen Recording isn't optional — the pane is built out of the live
    /// display, so there is nothing to render without it.
    private func requireScreenRecording() -> Bool {
        if ScreenCapturer.hasPermission() { return true }

        // This call *is* the system prompt. Putting our own dialog in front of
        // it only makes the user dismiss the same question twice.
        if ScreenCapturer.requestPermission() { return true }

        // We get here either because they declined, or because macOS already
        // had an answer on file and showed nothing at all — and that second
        // case is the only one where a word from us actually helps.
        let alert = NSAlert()
        alert.messageText = "FrostFold needs Screen Recording"
        alert.informativeText = """
            The frosted pane is built out of your live display, so there is \
            nothing to render without it.

            Turn FrostFold on under Privacy & Security → Screen Recording, \
            then start it again.
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

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "FrostFold"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func fatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Windows

    func openSettings() {
        guard let controller else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(controller: controller,
                                                      openPreview: { [weak self] in self?.openPreview() })
        }
        settingsWindow?.present()
    }

    func openPreview() {
        guard let controller else { return }
        if previewWindow == nil {
            previewWindow = PreviewWindowController(controller: controller)
        }
        previewWindow?.present()
    }
}
