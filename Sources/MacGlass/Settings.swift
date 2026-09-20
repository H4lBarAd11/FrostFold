import Foundation
import Combine

enum Intensity: Int, CaseIterable, Identifiable {
    case low = 0, medium = 1, high = 2
    var id: Int { rawValue }
    var label: String { ["Low", "Medium", "High"][rawValue] }
    /// How much the material scatters light, and how far it displaces.
    var scatter: Float { [0.45, 0.75, 1.0][rawValue] }
    /// Base opacity of the pane at full fold.
    var opacity: Float { [0.72, 0.85, 0.94][rawValue] }
}

/// How the pane relates to what is on screen behind it.
enum GlassMode: Int, CaseIterable, Identifiable {
    /// The pane carries a copy of the display, so the image lifts and leans
    /// with the glass.
    case lift = 0
    /// The pane is empty glass; you see the real display through it, blurred
    /// and refracted by the tilt.
    case seeThrough = 1

    var id: Int { rawValue }
    var label: String { self == .lift ? "Lift the image" : "See through" }
}

/// Frame rate used while the lid is *not* moving. Capture is suspended when
/// settled, so this only governs how quickly we notice motion starting.
enum StationaryFPS: Int, CaseIterable, Identifiable {
    case f15 = 15, f30 = 30, f60 = 60, f90 = 90, f120 = 120
    var id: Int { rawValue }
    var label: String { "\(rawValue) FPS" }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var enabled: Bool                 { didSet { persist(enabled, "enabled") } }
    @Published var intensity: Intensity          { didSet { persist(intensity.rawValue, "intensity") } }
    @Published var glassMode: GlassMode          { didSet { persist(glassMode.rawValue, "glassMode") } }
    @Published var perspective: Double           { didSet { persist(perspective, "perspective") } }
    @Published var edgeSoftness: Double          { didSet { persist(edgeSoftness, "edgeSoftness") } }
    @Published var cornerRadius: Double          { didSet { persist(cornerRadius, "cornerRadius") } }
    @Published var responsiveness: Double        { didSet { persist(responsiveness, "responsiveness") } }
    @Published var hingeSensitivity: Double      { didSet { persist(hingeSensitivity, "hingeSensitivity") } }
    @Published var movementThreshold: Double     { didSet { persist(movementThreshold, "movementThreshold") } }
    @Published var stationaryFPS: StationaryFPS  { didSet { persist(stationaryFPS.rawValue, "stationaryFPS") } }
    @Published var showAngleInMenuBar: Bool      { didSet { persist(showAngleInMenuBar, "showAngleInMenuBar") } }
    /// Lid angle (degrees) at or above which the pane lies flat and is invisible.
    @Published var restAngle: Double             { didSet { persist(restAngle, "restAngle") } }
    /// Maximum tilt of the pane, in degrees, reached as the lid approaches shut.
    @Published var maxFold: Double               { didSet { persist(maxFold, "maxFold") } }

    private var loading = true
    private let d = UserDefaults.standard

    private init() {
        let store = UserDefaults.standard
        func dbl(_ k: String, _ fallback: Double) -> Double {
            store.object(forKey: k) as? Double ?? fallback
        }
        func bool(_ k: String, _ fallback: Bool) -> Bool {
            store.object(forKey: k) as? Bool ?? fallback
        }
        enabled            = bool("enabled", true)
        intensity          = Intensity(rawValue: store.object(forKey: "intensity") as? Int ?? 1) ?? .medium
        glassMode          = GlassMode(rawValue: store.object(forKey: "glassMode") as? Int ?? 0) ?? .lift
        perspective        = dbl("perspective", 0.55)
        edgeSoftness       = dbl("edgeSoftness", 0.35)
        cornerRadius       = dbl("cornerRadius", 0.22)
        responsiveness     = dbl("responsiveness", 0.75)
        hingeSensitivity   = dbl("hingeSensitivity", 0.5)
        movementThreshold  = dbl("movementThreshold", 0.15)
        stationaryFPS      = StationaryFPS(rawValue: store.object(forKey: "stationaryFPS") as? Int ?? 30) ?? .f30
        showAngleInMenuBar = bool("showAngleInMenuBar", false)
        restAngle          = dbl("restAngle", 115)
        maxFold            = dbl("maxFold", 68)
        loading = false
    }

    private func persist(_ v: Any, _ key: String) {
        guard !loading else { return }
        d.set(v, forKey: key)
    }

    func resetToDefaults() {
        for k in ["intensity", "glassMode", "perspective", "edgeSoftness", "cornerRadius", "responsiveness",
                  "hingeSensitivity", "movementThreshold", "stationaryFPS", "restAngle", "maxFold"] {
            d.removeObject(forKey: k)
        }
        intensity = .medium;        glassMode = .lift
        perspective = 0.55
        edgeSoftness = 0.35;        cornerRadius = 0.22
        responsiveness = 0.75;      hingeSensitivity = 0.5
        movementThreshold = 0.15;   stationaryFPS = .f30
        restAngle = 115;            maxFold = 68
    }

    /// Maps a raw lid angle onto 0...1 fold, applying the hinge-sensitivity curve.
    /// 0 = pane flat against the display (invisible); 1 = fully lifted.
    func fold(forLidAngle angle: Double) -> Double {
        guard restAngle > 1 else { return 0 }
        let t = max(0, min(1, (restAngle - angle) / restAngle))
        // Sensitivity biases the curve: low = most of the travel happens near shut,
        // high = the pane reacts as soon as the lid leaves its resting angle.
        let gamma = 2.6 - 2.2 * hingeSensitivity   // 2.6 (lazy) ... 0.4 (eager)
        return pow(t, gamma)
    }
}
