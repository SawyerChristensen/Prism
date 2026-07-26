//
//  MilkdropWaveform.swift
//  Prism
//
//  Port of the waveform-building math from MilkDrop3's DrawWave() (milkdropfs.cpp) and its
//  SmoothWave() tessellator — the part of MilkDrop that turns raw PCM into the smooth,
//  curvy oscilloscope line, independent of MilkDrop's Direct3D/Windows plumbing. See
//  MilkdropWaveMode.swift for the mode enum and tunable params this operates on.
//
//  Everything here works in MilkDrop's own normalized space: x/y in roughly -1...1, y-up.
//  The view layer maps that into pixels.
//

import Foundation

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

    /// Loop-aware variant of `tessellated(_:)` for closed-ring modes (.circular/.star/.flower —
    /// see MilkdropWaveMode.isLoop). `points` must be a closed ring: `points.count - 1` unique
    /// samples plus a final point equal to the first (how points(mode:...) builds those modes).
    /// Unlike `tessellated(_:)`, neighbor lookups wrap around the ring instead of clamping at the
    /// array's ends — since index 0 and the last unique index are adjacent on the ring, clamping
    /// there (treating them as a strip's two disconnected ends) produces a visible kink right at
    /// the seam, meaning the shape's rotation carried it around as a visible stray dot.
    static func tessellatedLoop(_ points: [WavePoint]) -> [WavePoint] {
        let m = points.count - 1 // unique sample count; points[m] == points[0]
        guard m >= 3 else { return points }

        let c1: Float = -0.15, c2: Float = 1.15, c3: Float = 1.15, c4: Float = -0.15
        let invSum = 1 / (c1 + c2 + c3 + c4)

        var out: [WavePoint] = []
        out.reserveCapacity(m * 2 + 1)

        for i in 0..<m {
            let iBelow = (i - 1 + m) % m
            let iAbove = (i + 1) % m
            let iAbove2 = (i + 2) % m
            out.append(points[i])
            out.append(WavePoint(
                x: (c1 * points[iBelow].x + c2 * points[i].x + c3 * points[iAbove].x + c4 * points[iAbove2].x) * invSum,
                y: (c1 * points[iBelow].y + c2 * points[i].y + c3 * points[iAbove].y + c4 * points[iAbove2].y) * invSum
            ))
        }
        out.append(points[0]) // re-close the (now finer) ring for the line-strip draw call.
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

    /// Shared shape behind .line/.dualLine/.crossX/.wideLine/.dualParallel: a straight line,
    /// clipped edge-to-edge at `angle`, with each sample offset perpendicular to the line by
    /// `amplitude * samples[i] + perpendicularOffset` — that offset term is what turns a flat
    /// clipped line into the actual oscilloscope trace. `centerShiftX` (used only by
    /// .dualParallel's fixed ±0.45 split) shifts the whole line along the X axis directly, after
    /// clipping, rather than through the line's own perpendicular.
    ///
    /// `waveCenter` is params.waveX (Milkdrop's preset-driven "where to put the waveform" knob):
    /// for a straight line, moving "along" it doesn't do anything (it's clipped edge-to-edge
    /// regardless), so upstream's ClipWaveformEdges reuses wave_x as the single degree of freedom
    /// that *does* mean something here — how far to shift the line perpendicular to itself, off
    /// center. Defaults to 0 (dead center), matching every mode's look before preset loading
    /// existed.
    private static func clippedLinePoints(
        angle: Float,
        halfExtent: Float,
        amplitude: Float,
        perpendicularOffset: Float = 0,
        centerShiftX: Float = 0,
        waveCenter: Float = 0,
        samples: [Float],
        count n: Int
    ) -> [WavePoint] {
        let dx = cos(angle), dy = sin(angle)
        let perp = (x: -dy, y: dx)
        let center = WavePoint(x: perp.x * waveCenter, y: perp.y * waveCenter)
        let (edge0, edge1) = lineBoxIntersection(center: center, dir: (dx, dy), halfExtent: halfExtent)
        let stepX = (edge1.x - edge0.x) / Float(n)
        let stepY = (edge1.y - edge0.y) / Float(n)
        return (0..<n).map { i in
            WavePoint(
                x: edge0.x + centerShiftX + stepX * Float(i) + perp.x * (amplitude * samples[i] + perpendicularOffset),
                y: edge0.y + stepY * Float(i) + perp.y * (amplitude * samples[i] + perpendicularOffset)
            )
        }
    }

    /// Wraps an out-of-`-1...1` mystery param back into that range via the same fold Milkdrop's
    /// own DerivativeLine/Circle modes apply (WaveformMath::GetVertices' UsesNormalizedMysteryParam
    /// branch) — a defensive re-fold for presets that push `wave_mystery` outside its normal range;
    /// left untouched when it's already in range, matching upstream's own early-out.
    private static func normalizedMysteryParam(_ raw: Float) -> Float {
        guard raw < -1 || raw > 1 else { return raw }
        var v = raw * 0.5 + 0.5
        v -= floor(v)
        v = abs(v)
        return v * 2 - 1
    }

    /// Builds the pre-tessellation vertex list for a given mode, mirroring the per-mode branches
    /// inside DrawWave(). `left`/`right` should already be scaled+smoothed via `smoothed(_:)`.
    /// `spectrum` is the FFT magnitude spectrum (mono, reused for both channels — see
    /// MilkdropAudioSignals.swift's lastMagnitudeSpectrum), only read by `.spectrumLine`.
    /// `segmentBreak`, when non-nil, is the index at which the line strip should lift the pen —
    /// mirrors DrawWave()'s nBreak1 (used by .dualLine, where two independent strips share one array).
    static func points(
        mode: MilkdropWaveMode,
        left: [Float],
        right: [Float],
        spectrum: [Float] = [],
        params: MilkdropWaveformParams,
        time: Double,
        aspect: Float,
        /// The *other* axis's aspect multiplier (upstream's `m_aspectX` — WaveformMath.cpp:69,
        /// always 1.0 unless the viewport is taller than wide) — only `.explosiveHash` below needs
        /// it (every other mode here only ever scales X by `aspect`/upstream's `m_aspectY`, matching
        /// upstream's own per-mode formulas, confirmed for those against the real corpus 7/26).
        /// Defaults to 1.0 (a no-op, matching the common landscape case) so this doesn't ripple
        /// into every other call site.
        aspectX: Float = 1.0
    ) -> (points: [WavePoint], segmentBreak: Int?) {
        let count = min(left.count, right.count)
        guard count > 32 else { return ([], nil) }

        switch mode {
        case .line:
            let pts = clippedLinePoints(angle: params.angle, halfExtent: 1, amplitude: 0.25, waveCenter: params.waveX, samples: left, count: count)
            return (pts, nil)

        case .dualLine:
            let sep = params.separation * params.separation
            let pts = clippedLinePoints(angle: params.angle, halfExtent: 1, amplitude: 0.25, perpendicularOffset: sep, waveCenter: params.waveX, samples: left, count: count)
                + clippedLinePoints(angle: params.angle, halfExtent: 1, amplitude: 0.25, perpendicularOffset: -sep, waveCenter: params.waveX, samples: right, count: count)
            return (pts, count)

        case .circular:
            let n = count
            // Divides by n, not n-1: with n-1, sample n-1 lands at angle exactly 2*pi — the same
            // position as sample 0, which (manually appended below) closes the loop. Dividing by n
            // spaces all n samples evenly with no duplicate angle.
            let invN = 1 / Float(n)
            // .circular has no per-sample smoothing/blending of its own (unlike .star/.flower,
            // whose eased radius2-blend incidentally also smooths their own seam) — it plots raw
            // samples directly, so it's fully exposed to the fact that a snippet of live audio
            // essentially never has the same amplitude at both ends. Bending a non-periodic
            // snippet into a ring always leaves *some* seam unless something closes the gap, so
            // crossfade the last 10% of the ring's radius toward sample 0's radius — same eased
            // (raised-cosine) blend shape .star/.flower already use for their own blending — so
            // the ring closes smoothly instead of jumping between two unrelated samples.
            let radius0 = 0.5 + 0.4 * right[0]
            let fadeWindow = max(1, n / 10)
            var pts = (0..<n).map { i -> WavePoint in
                var rad = 0.5 + 0.4 * right[i]
                if i >= n - fadeWindow {
                    let t = Float(i - (n - fadeWindow)) / Float(fadeWindow)
                    let ease = 0.5 - 0.5 * cos(t * .pi)
                    rad = rad * (1 - ease) + radius0 * ease
                }
                let ang = Float(i) * invN * 2 * .pi + Float(time) * 0.2
                return WavePoint(x: rad * cos(ang) * aspect + params.waveX, y: rad * sin(ang) + params.waveY)
            }
            if let first = pts.first { pts.append(first) } // close the loop
            return (pts, nil)

        case .spiral:
            let n = count - 32
            let pts = (0..<n).map { i -> WavePoint in
                let rad = 0.53 + 0.43 * right[i]
                let ang = left[i + 32] * 1.57 + Float(time) * 2.3
                return WavePoint(x: rad * cos(ang) * aspect + params.waveX, y: rad * sin(ang) + params.waveY)
            }
            return (pts, nil)

        case .spiro:
            let n = count - 32
            let pts = (0..<n).map { i in
                WavePoint(x: right[i] * aspect + params.waveX, y: left[i + 32] + params.waveY)
            }
            return (pts, nil)

        case .spectrumBars:
            // Drawn separately in MilkdropVisualizerView from the FFT band levels, not from
            // point data — nothing to tessellate here.
            return ([], nil)

        case .crossX:
            // Port of Milkdrop2077WaveX::GenerateVertices: two lines, clipped at mirrored angles
            // (±0.75, nudged by the mystery param), crossing near the center like an X.
            let angle1 = -0.75 + params.mysteryParam * 3.15
            let angle2 = 0.75 + params.mysteryParam * 3.15
            let pts = clippedLinePoints(angle: angle1, halfExtent: 1.1, amplitude: 0.35, waveCenter: params.waveX, samples: left, count: count)
                + clippedLinePoints(angle: angle2, halfExtent: 1.1, amplitude: 0.35, waveCenter: params.waveX, samples: right, count: count)
            return (pts, count)

        case .wideLine:
            // Port of Milkdrop2077Wave9::GenerateVertices: like .line, but the angle is driven
            // entirely by the mystery param (not user-adjustable) and the clip box/amplitude match
            // .crossX's wider values instead of .line's.
            let angle: Float = 1.57 * params.mysteryParam
            let pts = clippedLinePoints(angle: angle, halfExtent: 1.1, amplitude: 0.35, waveCenter: params.waveX, samples: left, count: count)
            return (pts, nil)

        case .dualParallel:
            // Port of Milkdrop2077Wave11::GenerateVertices: unlike .dualLine (which separates the
            // two channels perpendicular to a user-adjustable angle), this fixes the baseline
            // vertical (angle 1.57) and shifts each channel's line by a constant ±0.45 along X,
            // giving two parallel vertical scopes side by side.
            let pts = clippedLinePoints(angle: 1.57, halfExtent: 1.1, amplitude: 0.35, centerShiftX: -0.45, waveCenter: params.waveX, samples: left, count: count)
                + clippedLinePoints(angle: 1.57, halfExtent: 1.1, amplitude: 0.35, centerShiftX: 0.45, waveCenter: params.waveX, samples: right, count: count)
            return (pts, count)

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
                return WavePoint(x: rad * cos(ang) * aspect + params.waveX, y: rad * sin(ang) + params.waveY)
            }
            return (pts, nil)

        case .star:
            // Port of Milkdrop2077WaveStar::GenerateVertices: a closed circular loop like
            // .circular, but the radius eases toward a second, differently-phased sample near the
            // seam instead of just following the raw waveform — that dip is what gives the shape
            // its points. The original re-reads the capture buffer at a fixed offset derived from
            // Milkdrop's windowed sample-count scheme; Prism doesn't use that windowing, so the
            // second phase is approximated as the sample half a buffer-length ahead (wrapped).
            // Deviates from upstream here: projectM's own C++ also divides by (samples-1), which
            // puts the last raw sample at angle exactly 2*pi — the same angle as sample 0, used
            // again to close the loop. Two different audio samples sharing one angle means a real
            // radius jump baked into the ring at the seam (see .circular's longer note on this same
            // issue) — visible and reported as a stray line orbiting the shape, so fixed here rather
            // than ported faithfully.
            let n = count
            guard n > 1 else { return ([], nil) }
            let tenth = Float(n) * 0.1
            var pts = (0..<n).map { i -> WavePoint in
                let s = Float(i)
                var radius = 0.7 + 0.4 * right[i] + params.mysteryParam
                let angle = s / Float(n) * 2 * .pi + Float(time) * 0.2
                if s < Float(n) / radius {
                    var mix = s / tenth
                    mix = 0.5 - 0.5 * cos(mix * .pi)
                    let radius2 = 0.5 + 0.4 * right[(i + n / 2) % n] + params.mysteryParam
                    radius = radius2 * (1 - mix) + radius * mix
                }
                return WavePoint(x: radius * cos(angle) * aspect + params.waveX, y: radius * sin(angle) + params.waveY)
            }
            if let first = pts.first { pts.append(first) }
            return (pts, nil)

        case .flower:
            // Port of Milkdrop2077WaveFlower::GenerateVertices: same eased-radius idea as .star,
            // but the angle gets multiplied by pi again in the x term, which wraps it around
            // several times over one lap — that's what turns the single dip into multiple petals.
            // The original also multiplies its wave_x/wave_y offset by cos(pi) == -1 (presumably
            // an artifact of how this mode's author wrote it, not a typo we should "fix") — ported
            // faithfully as a negation rather than dropped, since it's what the shape actually does
            // upstream.
            // Same (samples-1) -> samples deviation as .star, for the same reason — see that case's
            // note.
            let n = count
            guard n > 1 else { return ([], nil) }
            let tenth = Float(n) * 0.1
            let t = Float(time)
            var pts = (0..<n).map { i -> WavePoint in
                let s = Float(i)
                var radius = 0.7 + 0.7 * right[i] + params.mysteryParam
                let angle = s / Float(n) * 2 * .pi + t * 0.2
                if s < Float(n) / radius {
                    var mix = s / tenth
                    mix = 0.7 - 0.7 * cos(mix * .pi)
                    let radius2 = 0.7 + 0.7 * right[(i + n / 2) % n] + params.mysteryParam
                    radius = radius2 * (1 - mix) + radius * mix * 0.25
                }
                return WavePoint(
                    x: radius * cos(angle * .pi) * aspect / 1.5 - params.waveX,
                    y: radius * sin(angle - t / 3) / 1.5 - params.waveY
                )
            }
            if let first = pts.first { pts.append(first) }
            return (pts, nil)

        case .lasso:
            // Port of Milkdrop2077WaveLasso::GenerateVertices: a parametric curve driven mostly by
            // time rather than the waveform's shape — the left channel only perturbs the angle
            // slightly. `time` (timeIntervalSinceReferenceDate) has been nonzero and growing since
            // 2001, so the tan(t/angle) term's angle-near-zero case isn't reachable in practice,
            // same as the original's unguarded division. Only wave_y offsets this mode upstream —
            // there's no wave_x term in the original's x expression, so none is added here either.
            let n = count - 32
            guard n > 0 else { return ([], nil) }
            let t = Float(time)
            let pts = (0..<n).map { i -> WavePoint in
                let angle = left[i + 32] * 1.57 + t * 2.0
                return WavePoint(
                    x: cos(t) / 2 + cos(angle * 2 + tan(t / angle)),
                    y: sin(t) * 2 * sin(angle * 3.14) * aspect / 2.8 + params.waveY
                )
            }
            return (pts, nil)

        case .derivativeLine:
            // Port of DerivativeLine::GenerateVertices: an x/y "script" trace built from R[i+25]
            // and L[i], with each point pulled toward the linear extrapolation of the previous two
            // *already-blended* points (a momentum/feedback term, not independent per-sample
            // smoothing) — this is the one stock mode that needs the mystery param's out-of-range
            // wraparound (UsesNormalizedMysteryParam), unlike every other mode here. `n` trims the
            // tail by 25 (rather than centering the window the way upstream's viewport-based
            // `m_samples` reduction does) to stay in-bounds, matching how .spiral/.spiro/etc.
            // already handle their own fixed index offsets against Prism's fixed 480-sample buffer.
            let n = count - 25
            guard n > 2 else { return ([], nil) }
            let invN = 1 / Float(n)
            let mystery = normalizedMysteryParam(params.mysteryParam)
            let w1 = 0.45 + 0.5 * (mystery * 0.5 + 0.5)
            let w2 = 1 - w1
            var pts = [WavePoint](repeating: WavePoint(x: 0, y: 0), count: n)
            for i in 0..<n {
                let baseX: Float = -1 + 2 * (Float(i) * invN)
                var x: Float = baseX + params.waveX + right[i + 25] * 0.44
                var y: Float = left[i] * 0.47 + params.waveY
                if i > 1 {
                    x = x * w2 + w1 * (pts[i - 1].x * 2 - pts[i - 2].x)
                    y = y * w2 + w1 * (pts[i - 1].y * 2 - pts[i - 2].y)
                }
                pts[i] = WavePoint(x: x, y: y)
            }
            return (pts, nil)

        case .explosiveHash:
            // Port of ExplosiveHash::GenerateVertices: an (L,R) sample pair 32 apart combined into
            // a complex-product-like x0/y0, then rotated by an angle driven by wall-clock time
            // (not audio) — hence the "explosive" churn even over quiet audio. Unlike every other
            // mode in this file, upstream applies an aspect multiplier to *both* axes here, cross-
            // applied (ExplosiveHash.cpp:24-26: X scaled by `m_aspectY`, Y scaled by `m_aspectX`) —
            // confirmed 7/26 against the real source rather than assumed; `aspect`/`aspectX` here
            // are exactly those two (only one is ever != 1 at a time, whichever axis is longer).
            // MaximizeColors() upstream also dims this mode's alpha heavily (down to exactly 0.07/
            // 0.09/0.11/0.13/0.15 depending on `max(viewportSizeX, viewportSizeY)` vs. 256/512/1024/
            // 2048 — Waveform.cpp:146-177, confirmed 7/26) since its raw magnitude runs much hotter
            // than a normal scope trace; Prism has no equivalent alpha stage in this file, so that
            // dimming still isn't reproduced here — a separate, scoped follow-up (needs an alpha
            // channel threaded through WavePoint/the render path, not just this formula).
            let n = count - 32
            guard n > 0 else { return ([], nil) }
            let t = Float(time) * 0.3
            let cosR = cos(t), sinR = sin(t)
            let pts = (0..<n).map { i -> WavePoint in
                let x0 = right[i] * left[i + 32] + left[i] * right[i + 32]
                let y0 = right[i] * right[i] - left[i + 32] * left[i + 32]
                return WavePoint(
                    x: (x0 * cosR - y0 * sinR) * aspect + params.waveX,
                    y: (x0 * sinR + y0 * cosR) * aspectX + params.waveY
                )
            }
            return (pts, nil)

        case .spectrumLine:
            // Port of SpectrumLine::GenerateVertices: the same clipped-line shape as .line/
            // .wideLine, but each point's perpendicular offset comes from a log-combined pair of
            // FFT magnitude bins instead of the raw waveform. Real Milkdrop's own header calls this
            // mode UNFINISHED, so this is a direct port rather than a polished feature. A tiny
            // floor under the log avoids -infinity on an exactly-silent bin (upstream's unguarded
            // `logf` doesn't bother, since real hardware noise floors rarely hit exact zero).
            guard spectrum.count >= 512 else { return ([], nil) }
            let n = 256
            var spectrumSamples = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let sum = max(spectrum[i * 2] + spectrum[i * 2 + 1], .leastNormalMagnitude)
                spectrumSamples[i] = 0.1 * log(sum)
            }
            let angle: Float = 1.57 * params.mysteryParam
            let pts = clippedLinePoints(angle: angle, halfExtent: 1, amplitude: 1, waveCenter: params.waveX, samples: spectrumSamples, count: n)
            return (pts, nil)
        }
    }
}
