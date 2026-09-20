import AppKit
import Metal
import QuartzCore

/// A `CAMetalLayer`-backed view. Holds no state beyond the layer; everything it
/// draws is pushed in by `EffectController`.
final class GlassView: NSView {

    private(set) var metalLayer = CAMetalLayer()
    var opaqueBackground = false

    init(device: MTLDevice, opaque: Bool) {
        opaqueBackground = opaque
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = opaque
        metalLayer.backgroundColor = NSColor.clear.cgColor
        // Present as soon as the frame is ready; the lid is a real-time input
        // and queued frames read as lag.
        metalLayer.displaySyncEnabled = true
        metalLayer.allowsNextDrawableTimeout = true
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0 && size.height > 0 { metalLayer.drawableSize = size }
    }

    var aspect: Float {
        let size = metalLayer.drawableSize
        guard size.height > 0 else { return 1.6 }
        return Float(size.width / size.height)
    }
}

/// Borderless, click-through, floats above everything including full-screen
/// apps, and excludes itself from screen capture so the pane never sees its own
/// output.
final class OverlayWindow: NSWindow {

    /// The display this overlay was built for; `NSWindow.screen` goes nil
    /// while the window is off-screen, so we keep our own reference.
    let targetScreen: NSScreen

    init(screen: NSScreen, device: MTLDevice) {
        targetScreen = screen
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .ignoresCycle]
        // Belt and braces alongside excluding our app from the capture filter.
        sharingType = .none
        isReleasedWhenClosed = false
        displaysWhenScreenProfileChanges = true

        let view = GlassView(device: device, opaque: false)
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
        setFrame(screen.frame, display: false)
    }

    var glassView: GlassView { contentView as! GlassView }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
