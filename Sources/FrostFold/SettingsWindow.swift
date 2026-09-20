import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var controller: EffectController

    var body: some View {
        Form {
            Section("Material") {
                Picker("Intensity", selection: $settings.intensity) {
                    ForEach(Intensity.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Glass", selection: $settings.glassMode) {
                    ForEach(GlassMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Whether the pane carries a copy of the display, or is empty glass you see through.")

                labelled("Perspective", $settings.perspective, 0...1,
                         help: "How strongly the pane foreshortens as it leans away.")
                labelled("Edge softness", $settings.edgeSoftness, 0...1,
                         help: "Feathering where the glass meets the display.")
                labelled("Corner radius", $settings.cornerRadius, 0...1,
                         help: "Rounding of the pane's corners.")
            }

            Section("Motion") {
                labelled("Responsiveness", $settings.responsiveness, 0...1,
                         help: "Low trails the lid; high tracks it immediately.")
                labelled("Hinge sensitivity", $settings.hingeSensitivity, 0...1,
                         help: "Where in the lid's travel the fold does most of its work.")
                LabeledContent("Minimum movement") {
                    HStack {
                        Slider(value: $settings.movementThreshold, in: 0.05...2.0)
                        Text(String(format: "%.2f°", settings.movementThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Resting angle") {
                    HStack {
                        Slider(value: $settings.restAngle, in: 60...170)
                        Text(String(format: "%.0f°", settings.restAngle))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Maximum fold") {
                    HStack {
                        Slider(value: $settings.maxFold, in: 10...85)
                        Text(String(format: "%.0f°", settings.maxFold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Picker("Stationary frame rate", selection: $settings.stationaryFPS) {
                    ForEach(StationaryFPS.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Menu bar") {
                Toggle("Show lid angle", isOn: $settings.showAngleInMenuBar)
            }

            Section {
                HStack {
                    statusLine
                    Spacer()
                    Button("Reset") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
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
            Text(String(format: "Lid angle: %.1f°", controller.angle))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func labelled(_ title: String, _ value: Binding<Double>,
                          _ range: ClosedRange<Double>, help: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .help(help)
    }
}

final class SettingsWindowController: NSWindowController {
    init(controller: EffectController) {
        let root = SettingsView(settings: .shared, controller: controller)
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
