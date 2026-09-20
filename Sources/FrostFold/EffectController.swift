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

    /// Live sensor reading, published for the menu bar and settings UI.
    @Published private(set) var angle: Double = 0
    @Published private(set) var isMoving = false
    @Published private(set) var sensorAvailable = false
    @Published var statusMessage: String?

    /// When the preview window drives the scrubber manually, this overrides the
    /// sensor for *preview rendering only* — the live overlay keeps following
    /// the real lid.
    var scrubAngle: Double?
    weak var previewView: GlassView?

    private var cancellables = Set<AnyCancellable>()
    private var idleSince: CFAbsoluteTime?
    private var capturePending = false

    init?() {
        guard let renderer = MetalRenderer() else { return nil }
        self.renderer = renderer
        self.capturer = ScreenCapturer(device: renderer.device)

        capturer.onError = { [weak self] error in
            self?.statusMessage = error.localizedDescription
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
        }

        // Rebuild the overlay if the display arrangement changes.
        NotificationCenter.default
            .addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                         object: nil, queue: .main) { [weak self] _ in
                self?.rebuildOverlay()
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
        guard !capturer.isRunning, !capturePending, let displayID else { return }
        capturePending = true
        let fps = max(60, Settings.shared.stationaryFPS.rawValue)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.capturer.start(displayID: displayID, fps: fps)
                self.statusMessage = nil
            } catch {
                self.statusMessage = error.localizedDescription
            }
            self.capturePending = false
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
        } else if capturer.isRunning {
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
            var u = makeUniforms(angle: a, view: preview)
            // The preview should read clearly even at rest, so never fully fade.
            u.opacity = max(u.opacity, settings.intensity.opacity * 0.04)
            renderer.render(to: preview.metalLayer, source: source, uniforms: u,
                            opaqueBackground: true)
        }
    }

    func makeUniforms(angle: Double, view: GlassView) -> Shaders.PaneUniforms {
        let s = Settings.shared
        let fold01 = s.fold(forLidAngle: angle)
        let size = view.metalLayer.drawableSize

        var u = Shaders.PaneUniforms()
        u.foldRadians = Float(fold01 * s.maxFold * .pi / 180.0)
        u.cameraDistance = Float(12.0 - 8.5 * s.perspective)   // 12 (flat) ... 3.5 (strong)
        u.scatter = s.intensity.scatter
        u.opacity = s.intensity.opacity * Float(smoothstep(0, 0.08, fold01))
        u.edgeSoftness = Float(s.edgeSoftness)
        u.cornerRadius = Float(s.cornerRadius)
        u.grainAmount = 1.0
        u.aspect = view.aspect
        u.grainScale = SIMD2(Float(max(1, size.width / 14)), Float(max(1, size.height / 14)))
        u.viewportSize = SIMD2(Float(max(1, size.width)), Float(max(1, size.height)))
        u.mode = Int32(s.glassMode.rawValue)
        return u
    }
}
