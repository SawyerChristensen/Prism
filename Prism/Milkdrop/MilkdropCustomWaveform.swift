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

final class MilkdropCustomWaveformRuntime {
    let preset: MilkdropCustomWavePreset
    private let perFrameProgram: MilkdropExpressionProgram?
    private let perPointProgram: MilkdropExpressionProgram?

    /// Precomputed "q1".."q32"/"t1".."t8" dictionary keys — `resolvePoints`'s per-point loop below
    /// used to rebuild these via fresh string interpolation on *every point*, up to 4 waveform
    /// slots, every frame; a real, measured cost (40 String allocations + dictionary hashes per
    /// point for no reason, since the key set never changes). Read-only after init.
    private static let qKeys: [String] = (1...32).map { "q\($0)" }
    private static let tKeys: [String] = (1...8).map { "t\($0)" }

    /// Persistent per-frame environment, reused every frame — shares its variable space with the
    /// (once-only) init code, matching upstream's single WaveformPerFrameContext object.
    private var frameVariables: [String: Float]
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
    private var pointVariables: [String: Float] = [:]

    init(preset: MilkdropCustomWavePreset) {
        self.preset = preset
        // Built up in a local first (not `self.frameVariables`) — referencing an instance property
        // from the closure `tValuesAfterInit`'s map literal would use would capture `self` before
        // every stored property is initialized, which Swift rejects.
        var initialFrameVariables: [String: Float] = [
            "r": preset.r, "g": preset.g, "b": preset.b, "a": preset.a,
            "samples": Float(preset.samples),
        ]
        // Runs once, immediately — same role as the main preset's perFrameInitProgram.
        MilkdropExpressionProgram(source: preset.initProgram)?.evaluate(&initialFrameVariables)
        tValuesAfterInit = (1...8).map { initialFrameVariables["t\($0)"] ?? 0 }
        frameVariables = initialFrameVariables
        perFrameProgram = MilkdropExpressionProgram(source: preset.perFrameProgram)
        perPointProgram = MilkdropExpressionProgram(source: preset.perPointProgram)
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

        frameVariables["time"] = time
        frameVariables["fps"] = fps
        frameVariables["frame"] = frame
        frameVariables["progress"] = 0
        frameVariables["bass"] = energy.bass
        frameVariables["mid"] = energy.mid
        frameVariables["treb"] = energy.treb
        frameVariables["bass_att"] = energy.bassAtt
        frameVariables["mid_att"] = energy.midAtt
        frameVariables["treb_att"] = energy.trebAtt
        for i in 0..<min(32, qVars.count) { frameVariables[Self.qKeys[i]] = qVars[i] }
        for i in 0..<8 { frameVariables[Self.tKeys[i]] = tValuesAfterInit[i] }

        perFrameProgram?.evaluate(&frameVariables)

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
        let rawSamples = frameVariables["samples"] ?? Float(preset.samples)
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
        pointVariables["time"] = time
        pointVariables["fps"] = fps
        pointVariables["frame"] = frame
        pointVariables["progress"] = 0
        pointVariables["bass"] = energy.bass
        pointVariables["mid"] = energy.mid
        pointVariables["treb"] = energy.treb
        pointVariables["bass_att"] = energy.bassAtt
        pointVariables["mid_att"] = energy.midAtt
        pointVariables["treb_att"] = energy.trebAtt

        func colorWrapped(_ vars: [String: Float], _ key: String, _ fallback: Float) -> Float {
            let value = vars[key] ?? fallback
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
        // than re-read from frameVariables/re-interpolated into a fresh key string every point.
        let qCount = min(32, qVars.count)
        let frameTValues: [Float] = Self.tKeys.map { frameVariables[$0] ?? 0 }
        let baseR = frameVariables["r"] ?? preset.r
        let baseG = frameVariables["g"] ?? preset.g
        let baseB = frameVariables["b"] ?? preset.b
        let baseA = frameVariables["a"] ?? preset.a

        for s in 0..<sampleCount {
            for i in 0..<qCount { pointVariables[Self.qKeys[i]] = qVars[i] }
            for i in 0..<8 { pointVariables[Self.tKeys[i]] = frameTValues[i] }
            pointVariables["sample"] = Float(s) * sampleMultiplicator
            pointVariables["value1"] = sampleL[s]
            pointVariables["value2"] = sampleR[s]
            pointVariables["x"] = 0.5 + sampleL[s]
            pointVariables["y"] = 0.5 + sampleR[s]
            pointVariables["r"] = baseR
            pointVariables["g"] = baseG
            pointVariables["b"] = baseB
            pointVariables["a"] = baseA

            perPointProgram?.evaluate(&pointVariables)

            let ndcX = (pointVariables["x"] ?? 0.5) * 2 - 1
            let ndcY = (pointVariables["y"] ?? 0.5) * -2 + 1
            points.append(MilkdropCustomWaveformPoint(
                position: SIMD2(ndcX, ndcY),
                color: SIMD4(
                    colorWrapped(pointVariables, "r", preset.r), colorWrapped(pointVariables, "g", preset.g),
                    colorWrapped(pointVariables, "b", preset.b), colorWrapped(pointVariables, "a", preset.a)
                )
            ))
        }
        return points
    }
}
