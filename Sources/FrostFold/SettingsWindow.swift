import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: EffectController
    var openPreview: () -> Void = {}

    var body: some View {
        Form {
            Section("Effect") {
                Picker("Intensity", selection: $settings.intensity) {
                    ForEach(Intensity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Material") {
                percent("Perspective", $settings.perspective,
                        note: "How hard the gap opens toward the top.")
                percent("Edge softness", $settings.edgeSoftness,
                        note: "Fall-off at the pane's edges.")
                percent("Dimming", $settings.dimming,
                        note: "How far the glass darkens as the gap opens.")
                measured("Corner radius", $settings.cornerRadius, 0...60, "%.0f pt",
                         note: "Rounding on the free corners, to match your display.")
            }

            Section("Feel") {
                percent("Responsiveness", $settings.responsiveness,
                        note: "How tightly the fold tracks your hand.")
                percent("Hinge sensitivity", $settings.hingeSensitivity,
                        note: "How quickly the fold rises once the lid moves.")
                measured("Minimum movement", $settings.movementThreshold, 0.1...5, "%.1f°",
                         note: "How far the lid must move from rest before the fold starts.")
                measured("Engages at", $settings.restAngle, 60...170, "%.0f°",
                         note: "Above this angle the pane lies flat and nothing renders.")
                measured("Maximum fold", $settings.maxFold, 10...85, "%.0f°",
                         note: "How far the pane lifts off the display when fully folded.")
            }

            Section("Performance") {
                Picker("Stationary frame rate", selection: $settings.stationaryFPS) {
                    ForEach(StationaryFPS.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        statusLine
                        Spacer()
                        Button("Reset") { settings.resetToDefaults() }
                    }
                    Divider()
                    HStack {
                        Toggle("Enabled", isOn: $settings.enabled)
                            .toggleStyle(.switch)
                        Spacer()
                        Button("Preview…") { openPreview() }
                        // FrostFold has no menu bar item, so this is the way out.
                        Button("Quit FrostFold") { NSApp.terminate(nil) }
                    }
                    Text("FrostFold runs in the background. Launch it again to reopen these settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let message = controller.statusMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if controller.sensorAvailable {
            Text(String(format: "Lid %.1f° · engages at %.0f°",
                        controller.angle, settings.restAngle))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func percent(_ title: String, _ value: Binding<Double>, note: String) -> some View {
        slider(title, value, 0...1, { String(format: "%.0f%%", $0 * 100) }, note)
    }

    private func measured(_ title: String, _ value: Binding<Double>,
                          _ range: ClosedRange<Double>, _ format: String,
                          note: String) -> some View {
        slider(title, value, range, { String(format: format, $0) }, note)
    }

    private func slider(_ title: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>,
                        _ readout: @escaping (Double) -> String,
                        _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(readout(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

final class SettingsWindowController: NSWindowController {
    init(controller: EffectController, openPreview: @escaping () -> Void) {
        let root = SettingsView(settings: .shared, controller: controller, openPreview: openPreview)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "FrostFold Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
