import Foundation
import simd

/// The fold's arithmetic, with nothing from AppKit in it.
///
/// This lives apart from `EffectController` so it can be tested. Two bugs that
/// reached a running build came from this maths and neither was visible in a
/// still: the composited display flashing dark at the onset, and the pane's copy
/// sitting over a live display as a doubled image. Both are now invariants in
/// the test suite, which is the reason this is a separate type.
enum FoldGeometry {

    struct Input {
        var lidAngle: Double
        var engageAngle: Double
        var shutAngle: Double
        var hingeSensitivity: Double
        var maxFold: Double
        var perspective: Double
        var edgeSoftness: Double
        var cornerRadiusPoints: Double
        var dimming: Double
        var frostGain: Float
        var aspect: Float
        /// Height of the display in points, for converting the corner radius.
        var displayHeightPoints: Double
        var drawableSize: SIMD2<Float>
        var reduceMotion = false
        var reduceTransparency = false
        var increaseContrast = false
    }

    // MARK: - The curve

    /// Maps a lid angle onto 0...1 fold.
    ///
    /// Normalised over the span the lid actually travels through rather than
    /// down to 0°: a lid never reaches 0°, and treating it as though it might
    /// leaves the fold unfinished as the lid shuts.
    static func fold(lidAngle: Double, engage: Double, shut: Double,
                     sensitivity: Double) -> Double {
        guard engage > shut else { return 0 }
        let t = max(0, min(1, (engage - lidAngle) / (engage - shut)))
        // Weighted lazy by default: engaging linearly from the engage angle
        // reads as the effect snapping on rather than gathering.
        let gamma = 3.4 - 3.0 * sensitivity   // 3.4 (lazy) ... 0.4 (eager)
        return pow(t, gamma)
    }

    // MARK: - The projection

    /// Viewer distance for the perspective divide. Smaller converges harder.
    static func cameraDistance(perspective: Double) -> Double {
        9.0 - 6.5 * perspective          // 9 (flat) ... 2.5 (hard)
    }

    /// The fraction of the display's height that the converged pane no longer
    /// covers. Mirrors the projection the vertex shader performs, so the fill
    /// behind the pane can be driven by what is actually uncovered rather than
    /// by a fold fraction — which means something different at every setting.
    static func uncoveredFraction(tilt: Double, cameraDistance: Double) -> Double {
        let topY = 2 * cos(tilt) - 1
        let topW = (cameraDistance + 2 * sin(tilt)) / cameraDistance
        return max(0, 1 - topY / topW) / 2
    }

    // MARK: - The ramps

    /// The pane must be opaque before any fill appears behind it, or black
    /// comes through it across the whole display.
    ///
    /// Driven by the same uncovered fraction the fill is, so the ordering holds
    /// by construction rather than by the two happening to line up. Keying this
    /// to the fold instead left settings — a high engage angle with a large
    /// maximum fold and hard perspective — where the fill started while the
    /// pane was still at 0.93 and the display dimmed.
    static func paneOpacity(uncovered: Double) -> Double {
        smoothstep(0, 0.0008, uncovered)
    }

    /// ~2pt in, ~28pt fully in on a 950pt display. Has to stay well ahead of
    /// the point where the pane's copy is displaced enough to read as doubled.
    static func blackout(uncovered: Double) -> Double {
        smoothstep(0.002, 0.030, uncovered)
    }

    /// What the display composites to where the pane covers it: the pane over
    /// the fill over the live display. Anything below 1 is a visible dip in
    /// brightness, which is what the onset flash was.
    static func composedBrightness(paneOpacity a: Double, blackout b: Double) -> Double {
        a + (1 - a) * (1 - b)
    }

    /// Points of live display still showing through at the pane's edge. Large
    /// values are what made the doubled image obvious.
    static func liveDisplayShowing(uncovered: Double, blackout: Double,
                                   displayHeightPoints: Double) -> Double {
        uncovered * displayHeightPoints * (1 - blackout)
    }

    // MARK: - Assembly

    static func uniforms(_ i: Input) -> Shaders.PaneUniforms {
        let fold01 = fold(lidAngle: i.lidAngle, engage: i.engageAngle,
                          shut: i.shutAngle, sensitivity: i.hingeSensitivity)
        let maxTilt = i.maxFold * .pi / 180.0

        // Reduce Motion is the user saying this should not move. For an effect
        // that is motion, honour it by damping rather than by switching off —
        // the frost still reads, the pane barely travels.
        let motionScale = i.reduceMotion ? 0.35 : 1.0
        let tilt = fold01 * maxTilt * motionScale

        let camera = cameraDistance(perspective: i.perspective)
        let uncovered = uncoveredFraction(tilt: tilt, cameraDistance: camera)

        var u = Shaders.PaneUniforms()
        u.foldRadians = Float(tilt)
        u.cameraDistance = Float(camera)
        // Normalised so the free edge reaches the intensity's frost gain when
        // the fold is fully in, whatever the maximum tilt happens to be.
        // Reduce Transparency asks for legibility over glass, so scatter less.
        let frostScale: Float = i.reduceTransparency ? 0.5 : 1.0
        u.frostAmount = frostScale * i.frostGain / Float(max(0.05, sin(maxTilt * motionScale)))
        u.gapCurve = Float(0.75 + 1.15 * i.perspective)
        // Increase Contrast wants a defined edge, not a fade.
        u.edgeSoftness = Float(i.increaseContrast ? i.edgeSoftness * 0.25 : i.edgeSoftness)
        // Pane-local y spans [-1, 1] across the display height, so one unit is
        // half the display in points.
        let halfHeight = max(1.0, i.displayHeightPoints / 2)
        u.cornerRadius = Float(min(0.9, i.cornerRadiusPoints / halfHeight))
        u.grainAmount = 1.0
        u.aspect = i.aspect
        u.grainScale = SIMD2(max(1, i.drawableSize.x / 7), max(1, i.drawableSize.y / 7))
        u.opacity = Float(paneOpacity(uncovered: uncovered))
        u.dim = Float(i.dimming)
        u.blackout = Float(blackout(uncovered: uncovered))
        return u
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}
