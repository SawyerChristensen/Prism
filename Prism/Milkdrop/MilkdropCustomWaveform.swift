//
//  MilkdropCustomWaveform.swift
//  Prism
//
//  Runtime for Milkdrop's "custom waveforms" (`wavecode_N_*` in the .milk format) — up to 4
//  independently-scripted per-point line/dot traces per preset, distinct from the built-in
//  `nWaveMode` oscilloscope (see MilkdropWaveMode.swift). Ported from projectM's
//  CustomWaveform.cpp/WaveformPerFrameContext.cpp/WaveformPerPointContext.cpp as a spec, not
//  copied — see MilkdropPresetFile.swift's header for why. Measured 7/25 against the full
//  9,795-preset corpus: 4,672 files (47.7%) enable at least one custom waveform, 98% of those have
//  actual per-point code (not just static constants), and 21% run in spectrum mode.
//

import Foundation

/// One resolved waveform vertex — NDC-ish position (matches MilkdropWaveform's own -1...1, y-up
/// space) plus a real per-vertex color, since a per-point script can set r/g/b/a independently at
/// every point (unlike the built-in waveform, which is a single flat album-art-derived color).
struct MilkdropCustomWaveformPoint {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// A `time`/`fps`/`frame`/`progress`/`bass`/`mid`/`treb`/`*_att`/`q1`-`q32`/`t1`-`t8` slot bundle,
/// resolved once against a given `MilkdropVariableSlots` store — the same built-in set every
/// per-frame/per-point/per-vertex/per-instance environment in this codebase seeds, factored out
/// here since `MilkdropCustomWaveformRuntime` below needs it twice (once for `frameVariables`,
/// once for the separate `pointVariables` store — two distinct environments, per upstream's own
/// WaveformPerFrameContext/WaveformPerPointContext split, so two distinct slot sets even though
/// the names overlap).
private struct MilkdropTimingSlots {
    let time: Int
    let fps: Int
    let frame: Int
    let progress: Int
    let bass: Int
    let mid: Int
    let treb: Int
    let bassAtt: Int
    let midAtt: Int
    let trebAtt: Int
    let q: [Int]
    let t: [Int]

    init(_ store: MilkdropVariableSlots) {
        time = store.slot(for: "time")
        fps = store.slot(for: "fps")
        frame = store.slot(for: "frame")
        progress = store.slot(for: "progress")
        bass = store.slot(for: "bass")
        mid = store.slot(for: "mid")
        treb = store.slot(for: "treb")
        bassAtt = store.slot(for: "bass_att")
        midAtt = store.slot(for: "mid_att")
        trebAtt = store.slot(for: "treb_att")
        q = (1...32).map { store.slot(for: "q\($0)") }
        t = (1...8).map { store.slot(for: "t\($0)") }
    }
}

final class MilkdropCustomWaveformRuntime {
    let preset: MilkdropCustomWavePreset
    /// Resolved once against `frameVariables`/`pointVariables` respectively, right after both
    /// exist — `perPointProgram` in particular runs once per rendered sample point (commonly in
    /// the hundreds, up to 4 waveform slots, every frame), so avoiding a `[String: Float]`
    /// dictionary hash/lookup per read/write matters there (see
    /// MilkdropExpressionEvaluator.swift's perf note).
    private let perFrameProgram: MilkdropResolvedProgram?
    private let perPointProgram: MilkdropResolvedProgram?

    /// Persistent per-frame environment, reused every frame — shares its variable space with the
    /// (once-only) init code, matching upstream's single WaveformPerFrameContext object.
    private let frameVariables = MilkdropVariableSlots()
    private let frameTiming: MilkdropTimingSlots
    private let rSlot: Int
    private let gSlot: Int
    private let bSlot: Int
    private let aSlot: Int
    private let samplesSlot: Int

    /// `t1`-`t8` as they stood immediately after the init code ran once at load — re-seeded into
    /// `frameVariables` at the top of *every* frame, undoing whatever last frame's per-frame script
    /// did to them. This isn't a bug in this port: ported verbatim from
    /// WaveformPerFrameContext::LoadStateVariables (`*t_vars[t] = waveform.m_tValuesAfterInitCode[t]`),
    /// i.e. real Milkdrop's custom-waveform t-vars are a "reset every frame to the post-init
    /// snapshot" scratch space, not a persistent-across-frames accumulator like the main preset's
    /// per-frame variables or a custom shape's per-instance ones are.
    private var tValuesAfterInit: [Float]

    /// Persistent per-point environment, reused across every point *and* every frame — a script's
    /// own custom (non-built-in) variable accumulates across the whole sweep, matching
    /// MilkdropPerPixelMeshRuntime's/MilkdropShapeRuntime's established pattern in this codebase
    /// (and upstream's own single shared WaveformPerPointContext object).
    private let pointVariables = MilkdropVariableSlots()
    private let pointTiming: MilkdropTimingSlots
    private let sampleSlot: Int
    private let value1Slot: Int
    private let value2Slot: Int
    private let pointXSlot: Int
    private let pointYSlot: Int
    private let pointRSlot: Int
    private let pointGSlot: Int
    private let pointBSlot: Int
    private let pointASlot: Int

    init(preset: MilkdropCustomWavePreset) {
        self.preset = preset

        frameTiming = MilkdropTimingSlots(frameVariables)
        rSlot = frameVariables.slot(for: "r")
        gSlot = frameVariables.slot(for: "g")
        bSlot = frameVariables.slot(for: "b")
        aSlot = frameVariables.slot(for: "a")
        samplesSlot = frameVariables.slot(for: "samples")

        pointTiming = MilkdropTimingSlots(pointVariables)
        sampleSlot = pointVariables.slot(for: "sample")
        value1Slot = pointVariables.slot(for: "value1")
        value2Slot = pointVariables.slot(for: "value2")
        pointXSlot = pointVariables.slot(for: "x")
        pointYSlot = pointVariables.slot(for: "y")
        pointRSlot = pointVariables.slot(for: "r")
        pointGSlot = pointVariables.slot(for: "g")
        pointBSlot = pointVariables.slot(for: "b")
        pointASlot = pointVariables.slot(for: "a")

        frameVariables.load(["r": preset.r, "g": preset.g, "b": preset.b, "a": preset.a, "samples": Float(preset.samples)])
        // Runs once, immediately — same role as the main preset's perFrameInitProgram. Uses the
        // string-keyed path (not resolved): this program never runs again after this line.
        MilkdropExpressionProgram(source: preset.initProgram)?.evaluate(frameVariables)
        let tSlots = frameTiming.t
        let seededFrameVariables = frameVariables
        tValuesAfterInit = tSlots.map { seededFrameVariables.value(at: $0) }
        perFrameProgram = MilkdropExpressionProgram(source: preset.perFrameProgram)?.resolved(against: frameVariables)
        perPointProgram = MilkdropExpressionProgram(source: preset.perPointProgram)?.resolved(against: pointVariables)
    }

    /// Resolves this frame's waveform points from raw audio sample data — PCM waveform data if
    /// `preset.spectrum == false`, FFT magnitude spectrum data if `true` (see
    /// MilkdropMetalRenderer's `magnitudeSpectrum`). Returns an empty array if disabled or there
    /// aren't enough samples to draw anything (matching upstream's own early-return).
    ///
    /// `waveScale` is the *main* preset's `fWaveScale` (MilkdropVisualizerModel.params.scale) —
    /// confirmed against CustomWaveform::Draw's `mult = m_scaling * m_presetState.waveScale * ...`,
    /// a second, preset-global scale factor layered on top of this waveform's own `scaling`.
    func resolvePoints(
        left: [Float], right: [Float],
        waveScale: Float,
        time: Float, fps: Float, frame: Float, energy: MilkdropBandEnergy, qVars: [Float]
    ) -> [MilkdropCustomWaveformPoint] {
        guard preset.enabled else { return [] }
        let maxSampleCount = min(left.count, right.count)
        guard maxSampleCount > 0 else { return [] }

        frameVariables.setValue(time, at: frameTiming.time)
        frameVariables.setValue(fps, at: frameTiming.fps)
        frameVariables.setValue(frame, at: frameTiming.frame)
        frameVariables.setValue(0, at: frameTiming.progress)
        frameVariables.setValue(energy.bass, at: frameTiming.bass)
        frameVariables.setValue(energy.mid, at: frameTiming.mid)
        frameVariables.setValue(energy.treb, at: frameTiming.treb)
        frameVariables.setValue(energy.bassAtt, at: frameTiming.bassAtt)
        frameVariables.setValue(energy.midAtt, at: frameTiming.midAtt)
        frameVariables.setValue(energy.trebAtt, at: frameTiming.trebAtt)
        for i in 0..<min(32, qVars.count) { frameVariables.setValue(qVars[i], at: frameTiming.q[i]) }
        for i in 0..<8 { frameVariables.setValue(tValuesAfterInit[i], at: frameTiming.t[i]) }

        perFrameProgram?.evaluate(frameVariables)

        // Confirmed against CustomWaveform::Draw: an *earlier* `sampleCount -= m_sep` in that
        // function is immediately overwritten by this same `min(maxSampleCount, samples)`
        // computation run again right after the per-frame script executes — the sep-subtracted
        // value never survives to be used. `sep` still matters below, for the L/R channel window
        // *offset*, just not the point count.
        //
        // `samples` came out of an arbitrary per-frame script (e.g. `samples = 1/0;` — which this
        // evaluator maps to 0, but `samples = exp(1000);` maps to `Float.infinity` just fine) —
        // `Int(aFloat)` traps fatally on a non-finite or out-of-Int-range value, so this can't be a
        // direct `Int(...)` conversion the way the constructor-time default is.
        let rawSamples = frameVariables.value(at: samplesSlot)
        let clampedSamples = rawSamples.isFinite ? Int(max(0, min(Float(maxSampleCount), rawSamples))) : preset.samples
        let sampleCount = min(maxSampleCount, clampedSamples)
        guard sampleCount >= 2 else { return [] }

        let mult = preset.scaling * waveScale * (preset.spectrum ? 0.15 : 0.004)
        let offset1 = preset.spectrum ? 0 : (maxSampleCount - sampleCount) / 2 - preset.sep / 2
        let offset2 = preset.spectrum ? 0 : (maxSampleCount - sampleCount) / 2 + preset.sep / 2
        let resampleStep = preset.spectrum ? Float(maxSampleCount - preset.sep) / Float(sampleCount) : 1.0
        let mix1 = pow(preset.smoothing * 0.98, 0.5)
        let mix2 = 1 - mix1

        // Real Milkdrop trusts sampleCount/offsets to stay in-bounds given its own fixed buffer
        // sizes; clamped here too since an out-of-range Swift array access crashes rather than
        // reading (harmless) adjacent memory like the C++ would.
        func clampedIndex(_ i: Int, offset: Int) -> Int {
            min(maxSampleCount - 1, max(0, i + offset))
        }

        var sampleL = [Float](repeating: 0, count: sampleCount)
        var sampleR = [Float](repeating: 0, count: sampleCount)
        sampleL[0] = left[clampedIndex(0, offset: offset1)]
        sampleR[0] = right[clampedIndex(0, offset: offset2)]
        for s in 1..<sampleCount {
            let resampled: Int = Int(Float(s) * resampleStep)
            let li: Int = clampedIndex(resampled, offset: offset1)
            let ri: Int = clampedIndex(resampled, offset: offset2)
            let prevL: Float = sampleL[s - 1]
            let prevR: Float = sampleR[s - 1]
            sampleL[s] = left[li] * mix2 + prevL * mix1
            sampleR[s] = right[ri] * mix2 + prevR * mix1
        }
        // Smooth backwards too (fixes the asymmetry of the beginning & end) — matches upstream.
        for s in stride(from: sampleCount - 2, through: 0, by: -1) {
            sampleL[s] = sampleL[s] * mix2 + sampleL[s + 1] * mix1
            sampleR[s] = sampleR[s] * mix2 + sampleR[s + 1] * mix1
        }
        for s in 0..<sampleCount {
            sampleL[s] *= mult
            sampleR[s] *= mult
        }

        // Read-only per-point globals, loaded once (not re-read per point) — matches
        // WaveformPerPointContext::LoadReadOnlyStateVariables.
        pointVariables.setValue(time, at: pointTiming.time)
        pointVariables.setValue(fps, at: pointTiming.fps)
        pointVariables.setValue(frame, at: pointTiming.frame)
        pointVariables.setValue(0, at: pointTiming.progress)
        pointVariables.setValue(energy.bass, at: pointTiming.bass)
        pointVariables.setValue(energy.mid, at: pointTiming.mid)
        pointVariables.setValue(energy.treb, at: pointTiming.treb)
        pointVariables.setValue(energy.bassAtt, at: pointTiming.bassAtt)
        pointVariables.setValue(energy.midAtt, at: pointTiming.midAtt)
        pointVariables.setValue(energy.trebAtt, at: pointTiming.trebAtt)

        func colorWrapped(_ slot: Int, _ fallback: Float) -> Float {
            let value = pointVariables.value(at: slot)
            guard value.isFinite else { return fallback }
            var wrapped = (value * 255).truncatingRemainder(dividingBy: 256)
            if wrapped < 0 { wrapped += 256 }
            return wrapped / 255
        }

        let sampleMultiplicator = sampleCount > 1 ? 1 / Float(sampleCount - 1) : 0
        var points: [MilkdropCustomWaveformPoint] = []
        points.reserveCapacity(sampleCount)

        // q1-32/t1-8 are reset every point (a per-point script's own mutation of one shouldn't
        // leak into the next point's evaluation — Milkdrop's "read-only per-point" contract), but
        // the *values* being reset to are fixed for the whole sweep (qVars/frameVariables' t-vars
        // don't change once perFrameProgram above has already run) — precomputed once here rather
        // than re-read from frameVariables every point.
        let qCount = min(32, qVars.count)
        let frameTValues: [Float] = frameTiming.t.map { frameVariables.value(at: $0) }
        let baseR = frameVariables.value(at: rSlot)
        let baseG = frameVariables.value(at: gSlot)
        let baseB = frameVariables.value(at: bSlot)
        let baseA = frameVariables.value(at: aSlot)

        for s in 0..<sampleCount {
            for i in 0..<qCount { pointVariables.setValue(qVars[i], at: pointTiming.q[i]) }
            for i in 0..<8 { pointVariables.setValue(frameTValues[i], at: pointTiming.t[i]) }
            pointVariables.setValue(Float(s) * sampleMultiplicator, at: sampleSlot)
            pointVariables.setValue(sampleL[s], at: value1Slot)
            pointVariables.setValue(sampleR[s], at: value2Slot)
            pointVariables.setValue(0.5 + sampleL[s], at: pointXSlot)
            pointVariables.setValue(0.5 + sampleR[s], at: pointYSlot)
            pointVariables.setValue(baseR, at: pointRSlot)
            pointVariables.setValue(baseG, at: pointGSlot)
            pointVariables.setValue(baseB, at: pointBSlot)
            pointVariables.setValue(baseA, at: pointASlot)

            perPointProgram?.evaluate(pointVariables)

            let ndcX = pointVariables.value(at: pointXSlot) * 2 - 1
            let ndcY = pointVariables.value(at: pointYSlot) * -2 + 1
            points.append(MilkdropCustomWaveformPoint(
                position: SIMD2(ndcX, ndcY),
                color: SIMD4(
                    colorWrapped(pointRSlot, preset.r), colorWrapped(pointGSlot, preset.g),
                    colorWrapped(pointBSlot, preset.b), colorWrapped(pointASlot, preset.a)
                )
            ))
        }
        return points
    }
}
