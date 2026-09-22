import AppKit
import Metal
import Combine
import simd

private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// Owns the lid sensor, the capture stream, the overlay window and the render
/// timer, and decides when any of it needs to be running.
final class EffectController: ObservableObject {

    let renderer: MetalRenderer
    let capturer: ScreenCapturer
    private var sensor: LidAngleSensor?
    private var overlay: OverlayWindow?

    private var timer: DispatchSourceTimer?
    private var timerHz: Double = 0

    /// Live sensor reading. Deliberately *not* published: it is reassigned on
    /// every sample, and driving SwiftUI at sensor rate invalidates layout from
    /// inside AppKit's display cycle, which throws.
    private(set) var angle: Double = 0
    private(set) var isMoving = false

    /// The same reading, throttled to something an eye can follow, for the
    /// settings panel to observe.
    @Published private(set) var displayAngle: Double = 0
    private var lastDisplayAngleUpdate: CFAbsoluteTime = 0
    @Published private(set) var sensorAvailable = false
    @Published var statusMessage: String?

    /// When the preview window drives the scrubber manually, this overrides the
    /// sensor for *preview rendering only* — the live overlay keeps following
    /// the real lid.
    var scrubAngle: Double?
    weak var previewView: GlassView?

    private var cancellables = Set<AnyCancellable>()
    private var idleSince: CFAbsoluteTime?

    /// The display accessibility settings the user has already expressed a
    /// preference through. Re-read on change rather than sampled once at launch.
    private var reduceMotion = false
    private var reduceTransparency = false
    private var increaseContrast = false
    private var capturePending = false

    /// Capture failures are retried quietly, with a growing pause between
    /// attempts: waking up or unplugging a display leaves ScreenCaptureKit
    /// without the display for a moment, and that isn't worth telling anyone.
    /// Only a failure that outlasts `failureGrace` is reported.
    private var captureRetryAt: CFAbsoluteTime = 0
    private var captureBackoff: Double = 0
    private var captureFailingSince: CFAbsoluteTime?
    private static let failureGrace: Double = 10

    init?() {
        guard let renderer = MetalRenderer() else { return nil }
        self.renderer = renderer
        self.capturer = ScreenCapturer(device: renderer.device)

        capturer.onError = { [weak self] error in
            self?.captureFailed(error)
        }

        sensor = LidAngleSensor()
        sensorAvailable = sensor != nil
        if sensor == nil {
            statusMessage = "No lid-angle sensor found. This Mac's display hinge doesn't report a continuous angle."
        }

        sensor?.onSample = { [weak self] sample in
            guard let self else { return }
            self.angle = sample.angle
            self.isMoving = sample.isMoving

            // Ten times a second is plenty for a readout, and keeps SwiftUI out
            // of the sensor's update rate.
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastDisplayAngleUpdate >= 0.1 {
                self.lastDisplayAngleUpdate = now
                self.displayAngle = sample.angle
            }
        }

        readAccessibilitySettings()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.readAccessibilitySettings()
            }

        // Rebuild the overlay if the display arrangement changes.
        NotificationCenter.default
            .addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                         object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.rebuildOverlay()
                // A stream on a display that changed size or went away is no
                // use; the next tick that needs one starts it afresh.
                self.teardownCapture()
                self.captureRetryAt = 0
                self.captureBackoff = 0
            }

        Settings.shared.$enabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                if !on { self?.teardownCapture() }
                self?.overlay?.orderOut(nil)
                if on { self?.rebuildOverlay() }
            }
            .store(in: &cancellables)
    }

    private func readAccessibilitySettings() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }

    // MARK: - Lifecycle

    func start() {
        rebuildOverlay()
        sensor?.start()
        scheduleTimer(hz: Double(Settings.shared.stationaryFPS.rawValue))
    }

    func stop() {
        sensor?.stop()
        timer?.cancel(); timer = nil
        teardownCapture()
        overlay?.orderOut(nil)
    }

    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main
    }

    private var displayID: CGDirectDisplayID? {
        Self.builtInScreen()?.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func rebuildOverlay() {
        guard Settings.shared.enabled, let screen = Self.builtInScreen() else { return }
        if let overlay, overlay.targetScreen === screen {
            overlay.setFrame(screen.frame, display: false)
            overlay.orderFrontRegardless()
            return
        }
        overlay?.orderOut(nil)
        let window = OverlayWindow(screen: screen, device: renderer.device)
        window.orderFrontRegardless()
        overlay = window
    }

    // MARK: - Capture gating

    /// True while the pane has anything to show. Capture runs only in this
    /// window of time, which is what keeps the effect off the battery.
    private var effectActive: Bool {
        guard Settings.shared.enabled else { return false }
        if previewView != nil { return true }
        return Settings.shared.fold(forLidAngle: angle) > 0.002 || isMoving
    }

    private func ensureCapture() {
        guard !capturer.isRunning, !capturePending,
              CFAbsoluteTimeGetCurrent() >= captureRetryAt,
              let displayID else { return }
        capturePending = true
        let fps = max(60, Settings.shared.stationaryFPS.rawValue)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.capturer.start(displayID: displayID, fps: fps)
                self.captureBackoff = 0
                self.captureFailingSince = nil
                self.statusMessage = nil
            } catch {
                self.captureFailed(error)
            }
            self.capturePending = false
        }
    }

    private func captureFailed(_ error: Error) {
        let now = CFAbsoluteTimeGetCurrent()
        captureBackoff = min(4, max(0.25, captureBackoff * 2))
        captureRetryAt = now + captureBackoff

        // Nothing a retry can fix, so say so straight away.
        if case ScreenCapturer.CaptureError.noPermission = error {
            statusMessage = error.localizedDescription
            return
        }
        let since = captureFailingSince ?? now
        captureFailingSince = since
        if now - since >= Self.failureGrace {
            statusMessage = error.localizedDescription
        }
    }

    private func teardownCapture() {
        guard capturer.isRunning else { return }
        Task { await capturer.stop() }
    }

    // MARK: - Render loop

    private func scheduleTimer(hz: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / hz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        timerHz = hz
    }

    private func tick() {
        let settings = Settings.shared
        let active = effectActive

        if active {
            ensureCapture()
            idleSince = nil
        } else {
            // A failure from the last time the lid moved says nothing about
            // the next; start the grace period over.
            captureFailingSince = nil
        }
        if !active, capturer.isRunning {
            // Linger briefly so a lid that pauses and resumes doesn't pay the
            // stream start-up cost twice.
            let now = CFAbsoluteTimeGetCurrent()
            if let since = idleSince {
                if now - since > 1.5 { teardownCapture(); idleSince = nil }
            } else {
                idleSince = now
            }
        }

        let wantedHz = (isMoving || previewView != nil)
            ? 120.0 : Double(settings.stationaryFPS.rawValue)
        if abs(wantedHz - timerHz) > 0.5 { scheduleTimer(hz: wantedHz) }

        let source = capturer.latestTexture

        if let view = overlay?.glassView {
            let u = makeUniforms(angle: angle, view: view)
            renderer.render(to: view.metalLayer, source: active ? source : nil, uniforms: u)
        }

        if let preview = previewView {
            let a = scrubAngle ?? angle
            let u = makeUniforms(angle: a, view: preview)
            renderer.render(to: preview.metalLayer, source: source, uniforms: u,
                            opaqueBackground: true)
        }
    }

    func makeUniforms(angle: Double, view: GlassView) -> Shaders.PaneUniforms {
        let s = Settings.shared
        let size = view.metalLayer.drawableSize
        return FoldGeometry.uniforms(.init(
            lidAngle: angle,
            engageAngle: s.restAngle,
            shutAngle: s.shutAngle,
            hingeSensitivity: s.hingeSensitivity,
            maxFold: s.maxFold,
            perspective: s.perspective,
            edgeSoftness: s.edgeSoftness,
            cornerRadiusPoints: s.cornerRadius,
            dimming: s.dimming,
            frostGain: s.intensity.frostGain,
            aspect: view.aspect,
            displayHeightPoints: Double(view.window?.frame.height ?? 800),
            drawableSize: SIMD2(Float(size.width), Float(size.height)),
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast))
    }
}
