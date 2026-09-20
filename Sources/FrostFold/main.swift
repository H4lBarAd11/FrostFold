import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    SelfTest.run()
}

if arguments.contains("--help") {
    print("""
    FrostFold — a pane of frosted glass, hinged along the bottom of your display

      (no arguments)  start in the background, or open settings if already running
      --settings      open the settings window
      --preview       open the preview window
      --quit          stop a running FrostFold
      --selftest      headless diagnostics
    """)
    exit(0)
}

/// Another copy already running? Hand it the request and get out of the way.
/// There is no menu bar item, so this is how the app is reached.
let others = NSRunningApplication
    .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.frostfold")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

if !others.isEmpty {
    if arguments.contains("--quit") {
        for instance in others { instance.terminate() }
        // terminate() posts a quit event and returns. Exiting straight away can
        // cut delivery off, so wait for them to actually go, then insist.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for instance in others where !instance.isTerminated { instance.forceTerminate() }
        exit(0)
    }
    // Leave the note and get out. Shelling out to `open` would start another
    // process for a bundle LaunchServices has not registered, and that process
    // would land right back here — a loop, not a reopen.
    PendingWindow.request(arguments.contains("--preview") ? "preview" : "settings")
    exit(0)
}

if arguments.contains("--quit") {
    // Nothing was running.
    exit(0)
}

// AppKit turns an uncaught exception into an immediate trap, and the crash
// report keeps the backtrace but drops the reason. Log it before we go.
NSSetUncaughtExceptionHandler { exception in
    NSLog("FrostFold uncaught exception: %@ — %@\n%@",
          exception.name.rawValue,
          exception.reason ?? "(no reason)",
          exception.callStackSymbols.prefix(12).joined(separator: "\n"))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

if arguments.contains("--settings") || arguments.contains("--preview") {
    // Start normally, then surface the requested window once we are up.
    DispatchQueue.main.async {
        if arguments.contains("--preview") { delegate.openPreview() } else { delegate.openSettings() }
    }
}

app.run()
