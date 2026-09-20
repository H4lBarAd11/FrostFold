import Foundation
import Metal

/// `Clamshell --selftest` — headless diagnostics. Verifies the pieces that can
/// fail on an unfamiliar machine (runtime shader compilation, the lid sensor,
/// the capture permission) without putting anything on screen.
enum SelfTest {

    static func run() -> Never {
        var failures = 0

        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            let mark = ok ? "ok  " : "FAIL"
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }

        print("Clamshell self-test\n")

        // Metal + runtime shader compilation
        if let device = MTLCreateSystemDefaultDevice() {
            check("Metal device", true, device.name)
            let renderer = MetalRenderer()
            check("Shader compilation and pipelines", renderer != nil,
                  renderer == nil ? "see Console for the compiler diagnostic" : "4 pipelines")
        } else {
            check("Metal device", false, "no system default device")
            check("Shader compilation and pipelines", false, "skipped")
        }

        // Lid angle sensor
        if let sensor = LidAngleSensor() {
            if let angle = sensor.currentAngle {
                check("Lid-angle sensor", true, String(format: "reading %.2f°", angle))
            } else {
                check("Lid-angle sensor", false, "device found but no readable report")
            }
        } else {
            check("Lid-angle sensor", false,
                  "not present — this Mac's hinge doesn't report a continuous angle")
        }

        // Capture permission (a missing grant is a setup step, not a failure)
        let granted = ScreenCapturer.hasPermission()
        print("[\(granted ? "ok  " : "todo")] Screen Recording permission"
              + (granted ? "" : "  — grant it in Privacy & Security, then relaunch"))

        // Built-in display
        let screen = EffectController.builtInScreen()
        check("Built-in display", screen != nil,
              screen.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\(Int($0.backingScaleFactor))x" } ?? "")

        print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")")
        exit(failures == 0 ? 0 : 1)
    }
}
