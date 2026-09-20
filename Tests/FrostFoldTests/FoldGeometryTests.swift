import XCTest
import simd
@testable import FrostFold

/// The fold's arithmetic. Two of these are regressions for bugs that reached a
/// running build and were invisible in a still image — the onset flashing dark,
/// and the pane's copy sitting over a live display as a doubled image. Both came
/// from ramps that were individually reasonable and wrong together, so they are
/// checked against each other across the whole settings space rather than at a
/// handful of chosen points.
final class FoldGeometryTests: XCTestCase {

    /// The settings that vary enough to break these invariants.
    private struct Case {
        var engage: Double, sensitivity: Double, maxFold: Double, perspective: Double
        var label: String {
            "engage \(Int(engage))°, sensitivity \(sensitivity), maxFold \(Int(maxFold))°, perspective \(perspective)"
        }
    }

    private let cases: [Case] = {
        var out: [Case] = []
        for engage in [45.0, 85.0, 110.0, 170.0] {
            for sensitivity in [0.0, 0.35, 0.6, 1.0] {
                for maxFold in [10.0, 45.0, 68.0, 85.0] {
                    for perspective in [0.0, 0.5, 1.0] {
                        out.append(Case(engage: engage, sensitivity: sensitivity,
                                        maxFold: maxFold, perspective: perspective))
                    }
                }
            }
        }
        return out
    }()

    private func sweep(_ c: Case, _ body: (Double, Double, Double, Double) -> Void) {
        // lid angle, fold, uncovered, tilt
        var lid = c.engage + 10
        while lid >= 4 {
            let fold = FoldGeometry.fold(lidAngle: lid, engage: c.engage,
                                         shut: 6, sensitivity: c.sensitivity)
            let tilt = fold * c.maxFold * .pi / 180
            let uncovered = FoldGeometry.uncoveredFraction(
                tilt: tilt, cameraDistance: FoldGeometry.cameraDistance(perspective: c.perspective))
            body(lid, fold, uncovered, tilt)
            lid -= 0.25
        }
    }

    // MARK: - The curve

    func testFoldIsZeroAtAndAboveTheEngageAngle() {
        for c in cases {
            for lid in [c.engage, c.engage + 1, c.engage + 30] {
                let f = FoldGeometry.fold(lidAngle: lid, engage: c.engage,
                                          shut: 6, sensitivity: c.sensitivity)
                XCTAssertEqual(f, 0, accuracy: 1e-12, "\(c.label) at \(lid)°")
            }
        }
    }

    func testFoldCompletesAsTheLidShuts() {
        for c in cases {
            let f = FoldGeometry.fold(lidAngle: 6, engage: c.engage,
                                      shut: 6, sensitivity: c.sensitivity)
            XCTAssertEqual(f, 1, accuracy: 1e-9,
                           "the fold must finish before the display sleeps — \(c.label)")
        }
    }

    func testFoldNeverGoesBackwardsAsTheLidCloses() {
        for c in cases {
            var previous = -1.0
            sweep(c) { lid, fold, _, _ in
                XCTAssertGreaterThanOrEqual(fold, previous - 1e-12,
                                            "fold decreased at \(lid)° — \(c.label)")
                previous = fold
            }
        }
    }

    func testLowerSensitivityHoldsTheFoldBackLonger() {
        // The slider's whole purpose: lower means less has happened by mid-travel.
        for engage in [45.0, 85.0, 110.0] {
            let mid = (engage + 6) / 2
            let lazy = FoldGeometry.fold(lidAngle: mid, engage: engage, shut: 6, sensitivity: 0.0)
            let eager = FoldGeometry.fold(lidAngle: mid, engage: engage, shut: 6, sensitivity: 1.0)
            XCTAssertLessThan(lazy, eager, "engage \(engage)°")
        }
    }

    // MARK: - The projection

    func testNothingIsUncoveredBeforeThePaneTilts() {
        for p in [0.0, 0.5, 1.0] {
            let u = FoldGeometry.uncoveredFraction(
                tilt: 0, cameraDistance: FoldGeometry.cameraDistance(perspective: p))
            XCTAssertEqual(u, 0, accuracy: 1e-12)
        }
    }

    func testMoreTiltUncoversMore() {
        for p in [0.0, 0.5, 1.0] {
            let d = FoldGeometry.cameraDistance(perspective: p)
            var previous = -1.0
            for degrees in stride(from: 0.0, through: 85.0, by: 0.25) {
                let u = FoldGeometry.uncoveredFraction(tilt: degrees * .pi / 180, cameraDistance: d)
                XCTAssertGreaterThanOrEqual(u, previous - 1e-12, "at \(degrees)°, perspective \(p)")
                previous = u
            }
        }
    }

    // MARK: - Regressions

    /// The pane once faded in over the first 14% of the fold while the fill
    /// behind it was already opaque, so black came through it across the whole
    /// display and the screen dimmed to 29% before recovering. A flash.
    func testTheDisplayNeverDimsDuringTheOnset() {
        for c in cases {
            sweep(c) { lid, fold, uncovered, _ in
                let brightness = FoldGeometry.composedBrightness(
                    paneOpacity: FoldGeometry.paneOpacity(uncovered: uncovered),
                    blackout: FoldGeometry.blackout(uncovered: uncovered))
                XCTAssertGreaterThan(brightness, 0.995,
                    String(format: "screen dimmed to %.0f%% at %.2f° — %@",
                           brightness * 100, lid, c.label))
            }
        }
    }

    /// Holding the fill back over a fixed fold range left the converged pane
    /// sitting over a fully visible live display: 62pt showing at once, which
    /// read unmistakably as a doubled image.
    func testTheLiveDisplayIsNeverVisibleEnoughToLookDoubled() {
        let budget = 15.0   // points, against the 62 that was obvious
        for c in cases {
            sweep(c) { lid, _, uncovered, _ in
                let showing = FoldGeometry.liveDisplayShowing(
                    uncovered: uncovered,
                    blackout: FoldGeometry.blackout(uncovered: uncovered),
                    displayHeightPoints: 950)
                XCTAssertLessThan(showing, budget,
                    String(format: "%.1fpt of live display showing at %.2f° — %@",
                           showing, lid, c.label))
            }
        }
    }

    /// The pane has to be opaque before any fill appears behind it. This is the
    /// ordering the flash violated, stated directly.
    func testThePaneIsOpaqueBeforeAnyFillAppears() {
        for c in cases {
            sweep(c) { lid, _, uncovered, _ in
                if FoldGeometry.blackout(uncovered: uncovered) > 0.001 {
                    XCTAssertGreaterThan(FoldGeometry.paneOpacity(uncovered: uncovered), 0.999,
                        "fill started while the pane was still translucent at \(lid)° — \(c.label)")
                }
            }
        }
    }

    // MARK: - Uniform layout

    /// `PaneUniforms` is mirrored by hand in the Metal source. If the Swift side
    /// changes size or alignment the shader reads garbage, and nothing about
    /// that failure points at the cause.
    func testUniformLayoutMatchesTheShader() {
        XCTAssertEqual(MemoryLayout<Shaders.PaneUniforms>.size, 56)
        XCTAssertEqual(MemoryLayout<Shaders.PaneUniforms>.stride, 56)
        XCTAssertEqual(MemoryLayout<Shaders.PaneUniforms>.alignment, 8)
        XCTAssertEqual(MemoryLayout<Shaders.BlurUniforms>.stride, 8)
    }

    func testUniformsAreFiniteAcrossTheSettingsSpace() {
        for c in cases {
            sweep(c) { lid, _, _, _ in
                let u = FoldGeometry.uniforms(.init(
                    lidAngle: lid, engageAngle: c.engage, shutAngle: 6,
                    hingeSensitivity: c.sensitivity, maxFold: c.maxFold,
                    perspective: c.perspective, edgeSoftness: 0.4,
                    cornerRadiusPoints: 33, dimming: 0.45, frostGain: 1.75,
                    aspect: 1.55, displayHeightPoints: 950,
                    drawableSize: SIMD2(2940, 1912)))
                for (name, value) in [("foldRadians", u.foldRadians), ("cameraDistance", u.cameraDistance),
                                      ("frostAmount", u.frostAmount), ("gapCurve", u.gapCurve),
                                      ("opacity", u.opacity), ("blackout", u.blackout),
                                      ("cornerRadius", u.cornerRadius), ("aspect", u.aspect)] {
                    XCTAssertTrue(value.isFinite, "\(name) was \(value) at \(lid)° — \(c.label)")
                }
                XCTAssertGreaterThan(u.cameraDistance, 2.0,
                    "camera must stay clear of the pane or the projection blows up — \(c.label)")
            }
        }
    }
}
