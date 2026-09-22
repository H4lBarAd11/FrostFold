import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: EffectController
    var openPreview: () -> Void = {}

    // Not a stored preference: the source of truth is what macOS has
    // registered, which the user can change in System Settings behind our back.
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemNeedsApproval = LoginItem.isBlockedByUser

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                // Two columns: the window is far wider than it is tall, so it
                // fits on a laptop display without running off the bottom.
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 20) {
                        group("Effect") {
                            Picker("", selection: $settings.intensity) {
                                ForEach(Intensity.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        group("Material") {
                            percent("Perspective", $settings.perspective,
                                    "How hard the pane converges as it folds away.")
                            percent("Edge softness", $settings.edgeSoftness,
                                    "Fall-off at the free edges. The hinge never fades.")
                            percent("Dimming", $settings.dimming,
                                    "How far the glass darkens as the gap opens.")
                            measured("Corner radius", $settings.cornerRadius, 0...60, "%.0f pt",
                                     "Rounding on the free corners, to match your display.")
                            measured("Maximum fold", $settings.maxFold, 10...85, "%.0f°",
                                     "How far the pane lifts once the fold is fully in.")
                        }
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        group("Feel") {
                            measured("Engages at", $settings.restAngle, 45...170, "%.0f°",
                                     "The lid angle where the fold starts.")
                            percent("Hinge sensitivity", $settings.hingeSensitivity,
                                    "Low holds off until the lid is well down; high rises at once.")
                            percent("Responsiveness", $settings.responsiveness,
                                    "How tightly the fold tracks your hand.")
                            measured("Minimum movement", $settings.movementThreshold, 0.1...5, "%.1f°",
                                     "How far the lid must move from rest before anything happens.")
                        }
                        group("Performance") {
                            Picker("", selection: $settings.stationaryFPS) {
                                ForEach(StationaryFPS.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text("Frame rate while the lid is still. Capture stops when settled.")
                                .font(.footnote)
                                .foregroundStyle(Palette.inkSoftColor)
                        }
                        group("Startup") {
                            Toggle("Start FrostFold at login", isOn: $launchAtLogin)
                                .onChange(of: launchAtLogin) { _, wanted in
                                    LoginItem.set(wanted)
                                    launchAtLogin = LoginItem.isEnabled
                                    loginItemNeedsApproval = LoginItem.isBlockedByUser
                                }
                            if loginItemNeedsApproval {
                                Button("Approve in System Settings…") {
                                    LoginItem.openSystemSettings()
                                }
                                .font(.footnote)
                                Text("macOS is holding this until you allow it.")
                                    .font(.footnote)
                                    .foregroundStyle(Palette.caramelColor)
                            } else {
                                Text("It runs in the background and waits for the lid.")
                                    .font(.footnote)
                                    .foregroundStyle(Palette.inkSoftColor)
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Toggle("Enabled", isOn: $settings.enabled)
                        .toggleStyle(.switch)
                    statusLine
                    Spacer()
                    Button("Reset") { settings.resetToDefaults() }
                    Button("Preview…") { openPreview() }
                    // There is no menu bar item, so this is the way out.
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .modifier(GlassButtons())

                Text("FrostFold runs in the background. Launch it again to reopen these settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            // The title bar runs over the content so the glass is unbroken
            // from the top edge down; leave room for it.
            .padding(.top, 28)
            .frame(width: 780, alignment: .leading)
        }
        // Tint once at the root; controls inherit rather than being painted
        // individually. A dense utility panel takes .small throughout, and the
        // system decides each control's height from that.
        //
        // Sage here is a deliberate departure from the house rule that reserves
        // the magenta accent for controls a person acts on. FrostFold has no
        // writes/refuses distinction for sage and caramel to carry, so they are
        // free to be the app's own colours. Decided, not overlooked.
        .tint(Palette.sageColor)
        .controlSize(.small)
        // The house ground is ivory, and it stays ivory — but as a wash over
        // the blurred desktop behind the window rather than a solid plate.
        // The window's own material (see the controller) does the blurring;
        // this keeps the hue so the glass reads warm rather than grey. Under
        // Reduce Transparency the material goes opaque and the wash sits on
        // that, so nothing here needs to change.
        .background(Palette.backgroundColor.opacity(0.55))
        // A ScrollView has no intrinsic size, so without an explicit frame the
        // hosting controller collapses it to nothing. Fixed height keeps the
        // panel wide and short, and lets it scroll if it ever outgrows this.
        .frame(width: 780, height: 600)
    }

    // MARK: - Pieces

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.footnote.weight(.bold))
                .foregroundStyle(Palette.caramelColor)
                .tracking(0.9)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .modifier(GlassPane())
    }

    @ViewBuilder
    private var statusLine: some View {
        if let message = controller.statusMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.caramelColor)
                .lineLimit(2)
        } else if controller.sensorAvailable {
            Text(String(format: "Lid %.1f°", controller.displayAngle))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func percent(_ title: String, _ value: Binding<Double>, _ note: String) -> some View {
        slider(title, value, 0...1, { String(format: "%.0f%%", $0 * 100) }, note)
    }

    private func measured(_ title: String, _ value: Binding<Double>,
                          _ range: ClosedRange<Double>, _ format: String,
                          _ note: String) -> some View {
        slider(title, value, range, { String(format: format, $0) }, note)
    }

    private func slider(_ title: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>,
                        _ readout: @escaping (Double) -> String,
                        _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(title).font(.callout)
                Spacer()
                Text(readout(value.wrappedValue))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.sageDeepColor)
            }
            Slider(value: value, in: range)
            Text(note)
                .font(.footnote)
                .foregroundStyle(Palette.inkSoftColor)
                .lineLimit(1)
        }
    }
}

/// A section drawn as a pane of glass: the desktop shows through it, blurred,
/// with the house sage as a faint wash. A solid tinted plate with a hairline
/// border read as cardboard in an app whose whole point is glass.
///
/// On macOS 26 this is the system's own glass, which refracts and catches
/// light at the edge; earlier systems get a thin material with a highlight
/// stroke standing in for that edge. Both go opaque on their own under
/// Reduce Transparency.
private struct GlassPane: ViewModifier {
    // Continuous corners, and larger than a control's: a pane, not a button.
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(Palette.sageTintColor.opacity(0.45)), in: shape)
        } else {
            content
                .background(.thinMaterial, in: shape)
                .background(Palette.sageTintColor.opacity(0.35), in: shape)
                // The lit edge of a sheet of glass, not a drawn border.
                .overlay(shape.strokeBorder(.white.opacity(0.45), lineWidth: 1))
        }
    }
}

/// The row of buttons, in glass to match the panes above them.
private struct GlassButtons: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

final class SettingsWindowController: NSWindowController {
    init(controller: EffectController, openPreview: @escaping () -> Void) {
        let root = SettingsView(settings: .shared, controller: controller, openPreview: openPreview)

        // Deliberately an NSHostingView set as the content view, rather than an
        // NSHostingController used as the content view controller. The
        // controller negotiates its own sizing and safe-area insets with the
        // window, and that negotiation invalidates constraints from inside the
        // constraint engine's own layout pass — which throws, and which AppKit
        // turns into a hard crash for a bundled app. A plain hosting view in a
        // window with a fixed content size never enters that negotiation.
        let size = NSSize(width: 780, height: 600)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        // The view pads for the title bar itself; don't let the safe area add
        // a second helping.
        hosting.safeAreaRegions = []

        // The whole window is one sheet of glass over the desktop: blurred
        // behind, the ivory wash on top, and the title bar drawn on the same
        // sheet rather than as its own strip. The house rule keeps materials
        // off a settings window's body; this is the stated exception, because
        // the app is glass and a solid panel for its settings looked like a
        // different app. Under Reduce Transparency the material renders
        // opaque, which is the solid panel back again — as it should be.
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]
        material.addSubview(hosting)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "FrostFold Settings"
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = material
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.center()
        // Reopen where the user left it.
        window.setFrameAutosaveName("FrostFoldSettings")

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
