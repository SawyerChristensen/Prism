//
//  MilkdropWaveformTests.swift
//  PrismTests
//
//  Regression coverage for MilkdropWaveform.points(): default-params behavior for every mode, and
//  the wave_x/wave_y centering wired in from preset loading (see MilkdropWaveformParams.waveX/Y).
//

import Foundation
import Testing
@testable import Prism

struct MilkdropWaveformTests {
    static let sampleCount = 200
    static let left = (0..<sampleCount).map { i in Float(sin(Double(i) * 0.1)) * 0.5 }
    static let right = (0..<sampleCount).map { i in Float(cos(Double(i) * 0.13)) * 0.5 }

    /// Regression for a real reported bug: .circular/.star/.flower swept angle across
    /// `i/(n-1)*2*pi`, so the last raw sample landed at angle exactly 2*pi — the same angle as
    /// sample 0, reused to close the loop. Two different audio samples at the same angle bakes a
    /// real radius jump into the ring at the seam, which appeared as a line orbiting the shape as
    /// it rotated. Fixed by sweeping across `i/n` instead, so no two samples share an angle.
    @Test func loopModesDontDuplicateAngleAtTheSeam() {
        let n = 300
        let left = (0..<n).map { i in Float(sin(Double(i) * 0.07)) * 0.6 }
        let right = (0..<n).map { i in Float(cos(Double(i) * 0.11) + sin(Double(i) * 0.02)) * 0.4 }
        #expect(abs(right[0] - right[n - 1]) > 0.01, "test fixture needs distinct first/last samples")

        let params = MilkdropWaveformParams()
        for mode in [MilkdropWaveMode.circular, .star, .flower] {
            let (pts, _) = MilkdropWaveform.points(mode: mode, left: left, right: right, params: params, time: 0, aspect: 1.0)
            #expect(pts.count == n + 1)

            func angleOf(_ p: WavePoint) -> Float { atan2(p.y, p.x) }
            var diff = abs(angleOf(pts[n - 1]) - angleOf(pts[0]))
            if diff > .pi { diff = 2 * .pi - diff }

            #expect(diff > 0.001, "\(mode): last sample shares an angle with the closing point")
            #expect(abs(diff - 2 * Float.pi / Float(n)) < 0.01, "\(mode): seam gap isn't one ordinary sample-spacing")
        }
    }

    /// Regression for a second, .circular-specific bug found after the angle-duplication fix
    /// above: unlike .star/.flower (whose eased radius2-blend incidentally smooths their own
    /// seam), .circular plots raw samples directly with no such blending, so it stayed fully
    /// exposed to the fact that a snippet of live (non-periodic) audio essentially never has the
    /// same amplitude at both ends — bending it into a ring always leaves *some* seam otherwise.
    /// Fixed by crossfading the last 10% of the ring's radius toward sample 0's radius.
    @Test func circularSeamHasNoDiscontinuity() {
        let n = 480
        let left = (0..<n).map { i -> Float in
            let t = Double(i) / Double(n)
            return Float(sin(t * 2 * .pi * 5) * 0.4 + sin(t * 2 * .pi * 13) * 0.15)
        }
        let right = (0..<n).map { i -> Float in
            let t = Double(i) / Double(n)
            return Float(sin(t * 2 * .pi * 5 + 0.3) * 0.4 + sin(t * 2 * .pi * 17) * 0.1)
        }
        #expect(abs(right[0] - right[n - 1]) > 0.01, "test fixture needs a genuine seam mismatch")

        let (pts, _) = MilkdropWaveform.points(mode: .circular, left: left, right: right, params: MilkdropWaveformParams(), time: 3.7, aspect: 1.0)
        let distances: [Float] = (0..<(pts.count - 1)).map { i in
            let dx = pts[i + 1].x - pts[i].x
            let dy = pts[i + 1].y - pts[i].y
            return sqrt(dx * dx + dy * dy)
        }
        let median = distances.sorted()[distances.count / 2]
        let maxStep = distances.max() ?? 0
        #expect(maxStep < median * 3, "a step near the seam is a lot bigger than the ring's typical step — seam not smoothed")
    }

    @Test func everyModeProducesPointsWithDefaultParams() {
        let params = MilkdropWaveformParams()
        #expect(params.waveX == 0 && params.waveY == 0)
        for mode in MilkdropWaveMode.allCases where mode != .spectrumBars {
            let (points, _) = MilkdropWaveform.points(mode: mode, left: Self.left, right: Self.right, params: params, time: 12.34, aspect: 0.8)
            #expect(!points.isEmpty, "\(mode) produced no points")
        }
    }

    @Test func circularShiftsEveryPointByWaveXWaveY() {
        var offsetParams = MilkdropWaveformParams()
        offsetParams.waveX = 0.3
        offsetParams.waveY = -0.2
        let (basePts, _) = MilkdropWaveform.points(mode: .circular, left: Self.left, right: Self.right, params: MilkdropWaveformParams(), time: 1.0, aspect: 1.0)
        let (offsetPts, _) = MilkdropWaveform.points(mode: .circular, left: Self.left, right: Self.right, params: offsetParams, time: 1.0, aspect: 1.0)
        #expect(basePts.count == offsetPts.count)
        let allShifted = zip(basePts, offsetPts).allSatisfy { b, o in
            abs((o.x - b.x) - 0.3) < 1e-5 && abs((o.y - b.y) - (-0.2)) < 1e-5
        }
        #expect(allShifted)
    }

    @Test func flowerShiftIsNegated() {
        // Upstream WaveFlower multiplies its wave_x/wave_y offset by cos(pi) == -1 — a faithfully
        // ported quirk, not a bug — so a positive waveX/waveY should move .flower's points the
        // *opposite* direction from every other mode.
        var offsetParams = MilkdropWaveformParams()
        offsetParams.waveX = 0.3
        offsetParams.waveY = -0.2
        let (basePts, _) = MilkdropWaveform.points(mode: .flower, left: Self.left, right: Self.right, params: MilkdropWaveformParams(), time: 1.0, aspect: 1.0)
        let (offsetPts, _) = MilkdropWaveform.points(mode: .flower, left: Self.left, right: Self.right, params: offsetParams, time: 1.0, aspect: 1.0)
        let allNegated = zip(basePts, offsetPts).allSatisfy { b, o in
            abs((o.x - b.x) - (-0.3)) < 1e-5 && abs((o.y - b.y) - 0.2) < 1e-5
        }
        #expect(allNegated)
    }

    @Test func lassoOnlyShiftsAlongY() {
        // Upstream Milkdrop2077WaveLasso has no wave_x term in its x expression at all.
        var offsetParams = MilkdropWaveformParams()
        offsetParams.waveX = 0.3
        offsetParams.waveY = -0.2
        let (basePts, _) = MilkdropWaveform.points(mode: .lasso, left: Self.left, right: Self.right, params: MilkdropWaveformParams(), time: 1.0, aspect: 1.0)
        let (offsetPts, _) = MilkdropWaveform.points(mode: .lasso, left: Self.left, right: Self.right, params: offsetParams, time: 1.0, aspect: 1.0)
        #expect(zip(basePts, offsetPts).allSatisfy { b, o in abs(o.x - b.x) < 1e-5 })
        #expect(zip(basePts, offsetPts).allSatisfy { b, o in abs((o.y - b.y) - (-0.2)) < 1e-5 })
    }

    @Test func lineShiftsPerpendicularWithoutChangingDirection() throws {
        var offsetParams = MilkdropWaveformParams()
        offsetParams.waveX = 0.3
        let (basePts, _) = MilkdropWaveform.points(mode: .line, left: Self.left, right: Self.right, params: MilkdropWaveformParams(), time: 1.0, aspect: 1.0)
        let (offsetPts, _) = MilkdropWaveform.points(mode: .line, left: Self.left, right: Self.right, params: offsetParams, time: 1.0, aspect: 1.0)
        let baseFirst = try #require(basePts.first)
        let baseLast = try #require(basePts.last)
        let offsetFirst = try #require(offsetPts.first)
        let offsetLast = try #require(offsetPts.last)

        let baseDir = (x: baseLast.x - baseFirst.x, y: baseLast.y - baseFirst.y)
        let offsetDir = (x: offsetLast.x - offsetFirst.x, y: offsetLast.y - offsetFirst.y)
        #expect(abs(baseDir.x - offsetDir.x) < 1e-4)
        #expect(abs(baseDir.y - offsetDir.y) < 1e-4)

        let moved = abs(baseFirst.x - offsetFirst.x) > 1e-4 || abs(baseFirst.y - offsetFirst.y) > 1e-4
        #expect(moved)
    }
}
