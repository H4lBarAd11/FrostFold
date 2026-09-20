import Foundation
import AppKit
import ScreenCaptureKit
import CoreVideo
import Metal

/// Wraps a ScreenCaptureKit stream over a single display and hands the renderer
/// the most recent frame as an `MTLTexture`.
///
/// The stream is only ever running while the lid is actually moving — see
/// `EffectController` — which is what keeps this off the battery when idle.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {

    enum CaptureError: LocalizedError {
        case noPermission
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "Screen Recording permission is required — the glass is built out of your live display."
            case .noDisplay:
                return "No capturable display was found."
            }
        }
    }

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "io.github.frostfold.capture", qos: .userInteractive)

    private let lock = NSLock()
    private var _latest: MTLTexture?
    /// Most recently captured frame, or nil if nothing has arrived yet.
    var latestTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    private func clearLatest() {
        lock.lock(); _latest = nil; lock.unlock()
    }

    private(set) var isRunning = false
    var onError: ((Error) -> Void)?

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Returns true if the user has already granted Screen Recording.
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system permission prompt. Returns immediately; macOS
    /// requires a relaunch after the user grants it.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func start(displayID: CGDirectDisplayID, fps: Int) async throws {
        guard !isRunning else { return }
        guard Self.hasPermission() else { throw CaptureError.noPermission }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noPermission
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID })
                         ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Exclude ourselves, or the pane would capture its own output and
        // spiral into a feedback loop.
        let ourApp = content.applications.first {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: ourApp.map { [$0] } ?? [],
                                     exceptingWindows: [])

        let scale = NSScreen.screens.first {
            $0.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }?.backingScaleFactor ?? 2.0

        let config = SCStreamConfiguration()
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.queueDepth = 3
        // A second cursor rendered inside the glass reads as a glitch.
        config.showsCursor = false
        config.capturesAudio = false

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await s.startCapture()

        stream = s
        isRunning = true
    }

    func stop() async {
        guard let s = stream else { isRunning = false; return }
        stream = nil
        isRunning = false
        try? await s.stopCapture()
        clearLatest()
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        // Skip frames the compositor marked as containing no new content.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                    createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)

        guard result == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        lock.lock(); _latest = texture; lock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        self.stream = nil
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
