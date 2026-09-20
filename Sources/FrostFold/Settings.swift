import Foundation
import Combine

enum Intensity: Int, CaseIterable, Identifiable {
    case low = 0, medium = 1, high = 2
    var id: Int { rawValue }
    var label: String { ["Low", "Medium", "High"][rawValue] }

    /// Frost reached at the top edge when the fold is fully in. Values above 1
    /// let the top saturate into milk while the bottom is still clear.
    var frostGain: Float { [1.15, 1.75, 2.45][rawValue] }
}

/// Frame rate used while the lid is *not* moving. Capture is suspended when
/// settled, so this only governs how quickly we notice motion starting.
enum StationaryFPS: Int, CaseIterable, Identifiable {
    case f15 = 15, f30 = 30, f60 = 60, f90 = 90, f120 = 120
    var id: Int { rawValue }
    var label: String { "\(rawValue)" }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var enabled: Bool                 { didSet { persist(enabled, "enabled") } }
    @Published var intensity: Intensity          { didSet { persist(intensity.rawValue, "intensity") } }
    @Published var perspective: Double           { didSet { persist(perspective, "perspective") } }
    @Published var edgeSoftness: Double          { didSet { persist(edgeSoftness, "edgeSoftness") } }
    /// How much the glass darkens as the gap opens.
    @Published var dimming: Double               { didSet { persist(dimming, "dimming") } }
    /// In points, so it can be matched to the display's own corner rounding.
    @Published var cornerRadius: Double          { didSet { persist(cornerRadius, "cornerRadiusPt") } }
    @Published var responsiveness: Double        { didSet { persist(responsiveness, "responsiveness") } }
    @Published var hingeSensitivity: Double      { didSet { persist(hingeSensitivity, "hingeSensitivity") } }
    @Published var movementThreshold: Double     { didSet { persist(movementThreshold, "movementThreshold") } }
    @Published var stationaryFPS: StationaryFPS  { didSet { persist(stationaryFPS.rawValue, "stationaryFPS") } }
    /// The lid angle at which the fold engages. Above it nothing renders.
    @Published var restAngle: Double             { didSet { persist(restAngle, "engageAngle") } }
    /// How far the pane tilts off the display once the fold is fully in.
    @Published var maxFold: Double               { didSet { persist(maxFold, "maxFold") } }

    /// The lid is effectively shut here; the display sleeps around this point.
    let shutAngle: Double = 6

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
        perspective        = dbl("perspective", 0.5)
        edgeSoftness       = dbl("edgeSoftness", 0.4)
        dimming            = dbl("dimming", 0.45)
        cornerRadius       = dbl("cornerRadiusPt", 33)
        responsiveness     = dbl("responsiveness", 0.3)
        hingeSensitivity   = dbl("hingeSensitivity", 0.7)
        movementThreshold  = dbl("movementThreshold", 1.0)
        stationaryFPS      = StationaryFPS(rawValue: store.object(forKey: "stationaryFPS") as? Int ?? 30) ?? .f30
        restAngle          = dbl("engageAngle", 85)
        maxFold            = dbl("maxFold", 68)
        loading = false
    }

    private func persist(_ v: Any, _ key: String) {
        guard !loading else { return }
        d.set(v, forKey: key)
    }

    func resetToDefaults() {
        for k in ["intensity", "perspective", "edgeSoftness", "dimming", "cornerRadiusPt", "responsiveness",
                  "hingeSensitivity", "movementThreshold", "stationaryFPS", "engageAngle", "maxFold"] {
            d.removeObject(forKey: k)
        }
        intensity = .medium;        perspective = 0.5
        edgeSoftness = 0.4;         dimming = 0.45
        cornerRadius = 33
        responsiveness = 0.3;       hingeSensitivity = 0.7
        movementThreshold = 1.0;    stationaryFPS = .f30
        restAngle = 85;             maxFold = 68
    }

    /// Maps a raw lid angle onto 0...1 fold, applying the hinge-sensitivity curve.
    /// 0 = pane flat against the display, nothing to see; 1 = fully lifted.
    func fold(forLidAngle angle: Double) -> Double {
        guard restAngle > shutAngle else { return 0 }
        // Normalised over the span the lid actually travels through, not over
        // the whole 0...engage range: a lid never reaches 0°, and treating it
        // as though it might leaves the fold unfinished as the lid shuts.
        let t = max(0, min(1, (restAngle - angle) / (restAngle - shutAngle)))
        // Sensitivity biases the curve: low means most of the travel happens
        // near shut, high means the fold rises as soon as the lid moves.
        let gamma = 2.6 - 2.2 * hingeSensitivity   // 2.6 (lazy) ... 0.4 (eager)
        return pow(t, gamma)
    }
}
