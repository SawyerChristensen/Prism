//
//  MilkdropWaveform.swift
//  Prism
//
//  Port of the waveform-building math from MilkDrop3's DrawWave() (milkdropfs.cpp) and its
//  SmoothWave() tessellator — the part of MilkDrop that turns raw PCM into the smooth,
//  curvy oscilloscope line, independent of MilkDrop's Direct3D/Windows plumbing.
//
//  Everything here works in MilkDrop's own normalized space: x/y in roughly -1...1, y-up.
//  The view layer maps that into pixels.
//

import Foundation

enum MilkdropWaveMode: Int, CaseIterable {
    case line          // MilkDrop mode 6: single channel, angle-adjustable, full-width
    case dualLine      // MilkDrop mode 7: L/R drawn as two separated lines
    case circular      // MilkDrop mode 0: wrapped into a ring
    case spiral        // MilkDrop mode 1: x/y oscilloscope spiraling over time
    case spiro         // MilkDrop mode 2/3: L vs R plotted against each other (Lissajous)
    case spectrumBars   // Classic bar-spectrum EQ display, drawn from SpectrumAnalyzer's bands
                        // rather than the point-based waveform pipeline below (see
                        // MilkdropVisualizerView, which special-cases this mode).

    // Ports of the extra hand-written modes from projectM's Milkdrop2077Wave*.cpp (not part of
    // stock Milkdrop's mode 0-7 set, but built on the same clipped-line/polar primitives).
    case crossX        // Milkdrop2077WaveX: L/R drawn as two lines clipped at mirrored angles, crossing in an X.
    case wideLine       // Milkdrop2077Wave9: single channel, wide-clip line driven entirely by the mystery param.
    case dualParallel   // Milkdrop2077Wave11: L/R as two fixed vertical lines, offset left/right.
    case skewedLoop      // Milkdrop2077WaveSkewed: polar plot with an angle skew, less symmetric than .spiral.
    case star           // Milkdrop2077WaveStar: circular radius with an eased dip near the seam.
    case flower         // Milkdrop2077WaveFlower: circular radius with a multi-lobed angle multiplier.
    case lasso          // Milkdrop2077WaveLasso: figure-eight-like parametric curve.

    var label: String {
        switch self {
        case .line: return "Line"
        case .dualLine: return "Dual"
        case .circular: return "Circular"
        case .spiral: return "Spiral"
        case .spiro: return "Spiro"
        case .spectrumBars: return "Spectrum"
        case .crossX: return "Cross"
        case .wideLine: return "Wide"
        case .dualParallel: return "Parallel"
        case .skewedLoop: return "Skewed"
        case .star: return "Star"
        case .flower: return "Flower"
        case .lasso: return "Lasso"
        }
    }
}

struct MilkdropWaveformParams {
    /// m_fWaveScale: amplitude multiplier applied before smoothing.
    var scale: Float = 1.0
    /// m_fWaveSmoothing: 0 = none, 0.9 = heavy. Same IIR filter MilkDrop runs across the sample array.
    var smoothing: Float = 0.55
    /// fWaveParam mapped to -PI/2...PI/2, used by .line/.dualLine to tilt the scope.
    var angle: Float = 0
    /// .dualLine channel separation, 0...1 (mirrors fWavePosY in mode 7).
    var separation: Float = 0.30
    /// wave_mystery: unassigned per-preset knob several projectM Milkdrop2077 modes fold into
    /// their radius/angle math (.crossX/.wideLine/.skewedLoop/.star/.flower). 0 is neutral —
    /// matches the shape those modes have with no preset driving this value.
    var mysteryParam: Float = 0
}

struct WavePoint {
    var x: Float
    var y: Float
}

enum MilkdropWaveform {

    /// mysound.fWave[] smoothing: `out[i] = raw[i]*mix1 + out[i-1]*mix2`, run once per channel per
    /// frame in milkdropfs.cpp just before DrawWave(). This spatial (not temporal) IIR filter is
    /// what gives MilkDrop's scope its characteristic smooth curve instead of a jagged PCM trace.
    static func smoothed(_ raw: [Float], scale: Float, smoothing: Float) -> [Float] {
        guard !raw.isEmpty else { return raw }
        let mix2 = min(max(smoothing, 0), 0.9)
        let mix1 = scale * (1 - mix2)
        var out = raw
        out[0] *= scale
        for i in 1..<out.count {
            out[i] = raw[i] * mix1 + out[i - 1] * mix2
        }
        return out
    }

    /// Port of SmoothWave(): a single tessellation pass that doubles the vertex count by
    /// inserting a midpoint computed from a 4-tap kernel (-0.15, 1.15, 1.15, -0.15) centered
    /// between each pair of points. MilkDrop runs this once, right before handing vertices to
    /// the line-strip draw call, to round off the smoothed-but-still-polygonal wave.
    static func tessellated(_ points: [WavePoint]) -> [WavePoint] {
        let n = points.count
        guard n >= 2 else { return points }

        let c1: Float = -0.15, c2: Float = 1.15, c3: Float = 1.15, c4: Float = -0.15
        let invSum = 1 / (c1 + c2 + c3 + c4)

        var out: [WavePoint] = []
        out.reserveCapacity(n * 2)

        var iBelow = 0
        var iAbove2 = 1
        for i in 0..<(n - 1) {
            let iAbove = iAbove2
            iAbove2 = min(n - 1, i + 2)

            out.append(points[i])
            out.append(WavePoint(
                x: (c1 * points[iBelow].x + c2 * points[i].x + c3 * points[iAbove].x + c4 * points[iAbove2].x) * invSum,
                y: (c1 * points[iBelow].y + c2 * points[i].y + c3 * points[iAbove].y + c4 * points[iAbove2].y) * invSum
            ))
            iBelow = i
        }
        out.append(points[n - 1])
        return out
    }

    /// Same as `tessellated(_:)` but respects a segment break (see `points(mode:...)`), tessellating
    /// each side independently so the midpoint kernel never blends across the gap — mirrors how
    /// DrawWave() calls SmoothWave() twice when nBreak1 != -1.
    static func tessellated(_ points: [WavePoint], segmentBreak: Int?) -> (points: [WavePoint], segmentBreak: Int?) {
        guard let segmentBreak, segmentBreak > 0, segmentBreak < points.count else {
            return (tessellated(points), nil)
        }
        let first = tessellated(Array(points[0..<segmentBreak]))
        let second = tessellated(Array(points[segmentBreak...]))
        return (first + second, first.count)
    }

    /// Slab-method line/box clip: intersects the infinite line through `center` in direction `dir`
    /// with the -halfExtent...halfExtent square. Stands in for DrawWave()'s bespoke 4-edge clipper
    /// used by modes 6/7 to stretch a line edge-to-edge across the viewport at an arbitrary angle.
    /// `halfExtent` defaults to 1 (Prism's original modes); projectM's own ClipWaveformEdges clips
    /// its extra Milkdrop2077 line modes against 1.1 instead, giving them a touch of overscan past
    /// the visible frame — passed explicitly by those modes below.
    private static func lineBoxIntersection(center: WavePoint, dir: (x: Float, y: Float), halfExtent: Float = 1) -> (WavePoint, WavePoint) {
        var tMin: Float = -.greatestFiniteMagnitude
        var tMax: Float = .greatestFiniteMagnitude

        for (c, d) in [(center.x, dir.x), (center.y, dir.y)] {
            guard abs(d) > 1e-6 else { continue }
            var t0 = (-halfExtent - c) / d
            var t1 = (halfExtent - c) / d
            if t0 > t1 { swap(&t0, &t1) }
            tMin = max(tMin, t0)
            tMax = min(tMax, t1)
        }
        guard tMin.isFinite, tMax.isFinite else { return (center, center) }
        return (
            WavePoint(x: center.x + tMin * dir.x, y: center.y + tMin * dir.y),
            WavePoint(x: center.x + tMax * dir.x, y: center.y + tMax * dir.y)
        )
    }

    /// Builds the pre-tessellation vertex list for a given mode, mirroring the per-mode branches
    /// inside DrawWave(). `left`/`right` should already be scaled+smoothed via `smoothed(_:)`.
    /// `segmentBreak`, when non-nil, is the index at which the line strip should lift the pen —
    /// mirrors DrawWave()'s nBreak1 (used by .dualLine, where two independent strips share one array).
    static func points(
        mode: MilkdropWaveMode,
        left: [Float],
        right: [Float],
        params: MilkdropWaveformParams,
        time: Double,
        aspect: Float
    ) -> (points: [WavePoint], segmentBreak: Int?) {
        let count = min(left.count, right.count)
        guard count > 32 else { return ([], nil) }

        switch mode {
        case .line:
            let dx = cos(params.angle), dy = sin(params.angle)
            let (edge0, edge1) = lineBoxIntersection(center: WavePoint(x: 0, y: 0), dir: (dx, dy))
            let n = count
            let perp = (x: -dy, y: dx)
            let stepX = (edge1.x - edge0.x) / Float(n)
            let stepY = (edge1.y - edge0.y) / Float(n)
            let pts = (0..<n).map { i in
                WavePoint(
                    x: edge0.x + stepX * Float(i) + perp.x * 0.25 * left[i],
                    y: edge0.y + stepY * Float(i) + perp.y * 0.25 * left[i]
                )
            }
            return (pts, nil)

        case .dualLine:
            let dx = cos(params.angle), dy = sin(params.angle)
            let (edge0, edge1) = lineBoxIntersection(center: WavePoint(x: 0, y: 0), dir: (dx, dy))
            let n = count
            let perp = (x: -dy, y: dx)
            let stepX = (edge1.x - edge0.x) / Float(n)
            let stepY = (edge1.y - edge0.y) / Float(n)
            let sep = params.separation * params.separation
            var pts = (0..<n).map { i -> WavePoint in
                WavePoint(
                    x: edge0.x + stepX * Float(i) + perp.x * (0.25 * left[i] + sep),
                    y: edge0.y + stepY * Float(i) + perp.y * (0.25 * left[i] + sep)
                )
            }
            pts += (0..<n).map { i -> WavePoint in
                WavePoint(
                    x: edge0.x + stepX * Float(i) + perp.x * (0.25 * right[i] - sep),
                    y: edge0.y + stepY * Float(i) + perp.y * (0.25 * right[i] - sep)
                )
            }
            return (pts, n)

        case .circular:
            let n = count
            let invNMinus1 = 1 / Float(n - 1)
            var pts = (0..<n).map { i -> WavePoint in
                let rad = 0.5 + 0.4 * right[i]
                let ang = Float(i) * invNMinus1 * 2 * .pi + Float(time) * 0.2
                return WavePoint(x: rad * cos(ang) * aspect, y: rad * sin(ang))
            }
            if let first = pts.first { pts.append(first) } // close the loop
            return (pts, nil)

        case .spiral:
            let n = count - 32
            let pts = (0..<n).map { i -> WavePoint in
                let rad = 0.53 + 0.43 * right[i]
                let ang = left[i + 32] * 1.57 + Float(time) * 2.3
                return WavePoint(x: rad * cos(ang) * aspect, y: rad * sin(ang))
            }
            return (pts, nil)

        case .spiro:
            let n = count - 32
            let pts = (0..<n).map { i in
                WavePoint(x: right[i] * aspect, y: left[i + 32])
            }
            return (pts, nil)

        case .spectrumBars:
            // Drawn separately in MilkdropVisualizerView from the FFT band levels, not from
            // point data — nothing to tessellate here.
            return ([], nil)

        case .crossX:
            // Port of Milkdrop2077WaveX::GenerateVertices: two lines, clipped at mirrored angles
            // (±0.75, nudged by the mystery param), crossing near the center like an X. Each line
            // carries one channel, same edge-clip + per-sample perpendicular offset as .line, just
            // with a slightly larger amplitude (0.35 vs .line's 0.25) and clip box (1.1 vs 1).
            let n = count
            let angle1 = -0.75 + params.mysteryParam * 3.15
            let angle2 = 0.75 + params.mysteryParam * 3.15
            func clippedLine(angle: Float, samples: [Float]) -> [WavePoint] {
                let dx = cos(angle), dy = sin(angle)
                let (edge0, edge1) = lineBoxIntersection(center: WavePoint(x: 0, y: 0), dir: (dx, dy), halfExtent: 1.1)
                let perp = (x: -dy, y: dx)
                let stepX = (edge1.x - edge0.x) / Float(n)
                let stepY = (edge1.y - edge0.y) / Float(n)
                return (0..<n).map { i in
                    WavePoint(
                        x: edge0.x + stepX * Float(i) + perp.x * 0.35 * samples[i],
                        y: edge0.y + stepY * Float(i) + perp.y * 0.35 * samples[i]
                    )
                }
            }
            let pts = clippedLine(angle: angle1, samples: left) + clippedLine(angle: angle2, samples: right)
            return (pts, n)

        case .wideLine:
            // Port of Milkdrop2077Wave9::GenerateVertices: like .line, but the angle is driven
            // entirely by the mystery param (not user-adjustable) and the clip box/amplitude match
            // .crossX's wider values instead of .line's.
            let n = count
            let angle: Float = 1.57 * params.mysteryParam
            let dx = cos(angle), dy = sin(angle)
            let (edge0, edge1) = lineBoxIntersection(center: WavePoint(x: 0, y: 0), dir: (dx, dy), halfExtent: 1.1)
            let perp = (x: -dy, y: dx)
            let stepX = (edge1.x - edge0.x) / Float(n)
            let stepY = (edge1.y - edge0.y) / Float(n)
            let pts = (0..<n).map { i in
                WavePoint(
                    x: edge0.x + stepX * Float(i) + perp.x * 0.35 * left[i],
                    y: edge0.y + stepY * Float(i) + perp.y * 0.35 * left[i]
                )
            }
            return (pts, nil)

        case .dualParallel:
            // Port of Milkdrop2077Wave11::GenerateVertices: unlike .dualLine (which separates the
            // two channels perpendicular to a user-adjustable angle), this fixes the baseline
            // vertical (angle 1.57) and shifts each channel's line by a constant ±0.45 along X,
            // giving two parallel vertical scopes side by side.
            let n = count
            let angle: Float = 1.57
            let dx = cos(angle), dy = sin(angle)
            let (edge0, edge1) = lineBoxIntersection(center: WavePoint(x: 0, y: 0), dir: (dx, dy), halfExtent: 1.1)
            let perp = (x: -dy, y: dx)
            let stepX = (edge1.x - edge0.x) / Float(n)
            let stepY = (edge1.y - edge0.y) / Float(n)
            var pts = (0..<n).map { i -> WavePoint in
                WavePoint(
                    x: edge0.x - 0.45 + stepX * Float(i) + perp.x * 0.35 * left[i],
                    y: edge0.y + stepY * Float(i) + perp.y * 0.35 * left[i]
                )
            }
            pts += (0..<n).map { i -> WavePoint in
                WavePoint(
                    x: edge0.x + 0.45 + stepX * Float(i) + perp.x * 0.35 * right[i],
                    y: edge0.y + stepY * Float(i) + perp.y * 0.35 * right[i]
                )
            }
            return (pts, n)

        case .skewedLoop:
            // Port of Milkdrop2077WaveSkewed::GenerateVertices: a polar plot like .spiral, but the
            // angle only comes from the left channel (no time-driven spin term besides the sample
            // offset) — drops the original's `wave_a`-driven alpha skew, since that's a per-preset
            // value Prism has no source for yet (see the .milk-loading note in this file's header).
            let n = count - 32
            guard n > 0 else { return ([], nil) }
            let pts = (0..<n).map { i -> WavePoint in
                let rad = 0.63 + 0.23 * right[i] + params.mysteryParam
                let ang = left[i + 32] * 0.9 + Float(time) * 3.3
                return WavePoint(x: rad * cos(ang) * aspect, y: rad * sin(ang))
            }
            return (pts, nil)

        case .star:
            // Port of Milkdrop2077WaveStar::GenerateVertices: a closed circular loop like
            // .circular, but the radius eases toward a second, differently-phased sample near the
            // seam instead of just following the raw waveform — that dip is what gives the shape
            // its points. The original re-reads the capture buffer at a fixed offset derived from
            // Milkdrop's windowed sample-count scheme; Prism doesn't use that windowing, so the
            // second phase is approximated as the sample half a buffer-length ahead (wrapped).
            let n = count
            guard n > 1 else { return ([], nil) }
            let tenth = Float(n) * 0.1
            var pts = (0..<n).map { i -> WavePoint in
                let s = Float(i)
                var radius = 0.7 + 0.4 * right[i] + params.mysteryParam
                let angle = s / Float(n - 1) * 2 * .pi + Float(time) * 0.2
                if s < Float(n) / radius {
                    var mix = s / tenth
                    mix = 0.5 - 0.5 * cos(mix * .pi)
                    let radius2 = 0.5 + 0.4 * right[(i + n / 2) % n] + params.mysteryParam
                    radius = radius2 * (1 - mix) + radius * mix
                }
                return WavePoint(x: radius * cos(angle) * aspect, y: radius * sin(angle))
            }
            if let first = pts.first { pts.append(first) }
            return (pts, nil)

        case .flower:
            // Port of Milkdrop2077WaveFlower::GenerateVertices: same eased-radius idea as .star,
            // but the angle gets multiplied by pi again in the x term, which wraps it around
            // several times over one lap — that's what turns the single dip into multiple petals.
            let n = count
            guard n > 1 else { return ([], nil) }
            let tenth = Float(n) * 0.1
            let t = Float(time)
            var pts = (0..<n).map { i -> WavePoint in
                let s = Float(i)
                var radius = 0.7 + 0.7 * right[i] + params.mysteryParam
                let angle = s / Float(n - 1) * 2 * .pi + t * 0.2
                if s < Float(n) / radius {
                    var mix = s / tenth
                    mix = 0.7 - 0.7 * cos(mix * .pi)
                    let radius2 = 0.7 + 0.7 * right[(i + n / 2) % n] + params.mysteryParam
                    radius = radius2 * (1 - mix) + radius * mix * 0.25
                }
                return WavePoint(
                    x: radius * cos(angle * .pi) * aspect / 1.5,
                    y: radius * sin(angle - t / 3) / 1.5
                )
            }
            if let first = pts.first { pts.append(first) }
            return (pts, nil)

        case .lasso:
            // Port of Milkdrop2077WaveLasso::GenerateVertices: a parametric curve driven mostly by
            // time rather than the waveform's shape — the left channel only perturbs the angle
            // slightly. `time` (timeIntervalSinceReferenceDate) has been nonzero and growing since
            // 2001, so the tan(t/angle) term's angle-near-zero case isn't reachable in practice,
            // same as the original's unguarded division.
            let n = count - 32
            guard n > 0 else { return ([], nil) }
            let t = Float(time)
            let pts = (0..<n).map { i -> WavePoint in
                let angle = left[i + 32] * 1.57 + t * 2.0
                return WavePoint(
                    x: cos(t) / 2 + cos(angle * 2 + tan(t / angle)),
                    y: sin(t) * 2 * sin(angle * 3.14) * aspect / 2.8
                )
            }
            return (pts, nil)
        }
    }
}
