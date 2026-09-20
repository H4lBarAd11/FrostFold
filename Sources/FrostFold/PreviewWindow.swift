import AppKit

/// A live preview of the pane with a manual scrubber, so the effect can be
/// dialled in without opening and closing the lid a hundred times.
final class PreviewWindowController: NSWindowController {

    private let controller: EffectController
    private let glass: GlassView
    private let slider = NSSlider()
    private let readout = NSTextField(labelWithString: "")
    private let followToggle = NSButton(checkboxWithTitle: "Follow the lid", target: nil, action: nil)

    init(controller: EffectController) {
        self.controller = controller
        self.glass = GlassView(device: controller.renderer.device, opaque: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "FrostFold Preview"
        window.isReleasedWhenClosed = false
        window.center()
        // Keep the preview out of its own capture.
        window.sharingType = .none
        window.setFrameAutosaveName("FrostFoldPreview")
        super.init(window: window)

        let container = NSView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)

        let controls = NSStackView(views: [followToggle, slider, readout])
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controls)

        slider.minValue = 0
        slider.maxValue = 130
        slider.doubleValue = 130
        slider.target = self
        slider.action = #selector(scrubbed)
        slider.isContinuous = true
        slider.controlSize = .small
        followToggle.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        followToggle.state = .on
        followToggle.target = self
        followToggle.action = #selector(toggledFollow)

        // smallSystemFontSize, rather than a number picked by eye.
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                  weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        readout.setContentHuggingPriority(.required, for: .horizontal)
        readout.widthAnchor.constraint(equalToConstant: 64).isActive = true

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.delegate = self

        toggledFollow()
        startReadout()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func scrubbed() {
        followToggle.state = .off
        controller.scrubAngle = slider.doubleValue
        updateReadout()
    }

    @objc private func toggledFollow() {
        if followToggle.state == .on {
            controller.scrubAngle = nil
        } else {
            controller.scrubAngle = slider.doubleValue
        }
        updateReadout()
    }

    private var readoutTimer: Timer?

    private func startReadout() {
        readoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.followToggle.state == .on {
                self.slider.doubleValue = self.controller.angle
            }
            self.updateReadout()
        }
    }

    private func updateReadout() {
        let value = followToggle.state == .on ? controller.angle : slider.doubleValue
        readout.stringValue = String(format: "%.1f°", value)
    }

    func present() {
        controller.previewView = glass
        if readoutTimer == nil { startReadout() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension PreviewWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Stop driving the preview so capture can shut down again.
        controller.previewView = nil
        controller.scrubAngle = nil
        readoutTimer?.invalidate()
        readoutTimer = nil
    }
}
