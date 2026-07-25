//
//  MilkdropAudioSignals.swift
//  Prism
//
//  Port of MilkDrop3's CPluginShell::ProcessData (pluginshell.cpp) — the code that turns raw
//  waveform samples into the `bass`/`mid`/`treb` and `bass_att`/`mid_att`/`treb_att` values every
//  MilkDrop preset equation reads. Presets aren't implemented (see MilkdropWaveform.swift's header
//  for why), but the underlying signal is small, self-contained, and worth having authentically:
//  it's what makes preset-driven zoom/hue/warp pulse with the beat instead of just the raw level.
//
//  Pipeline (unchanged from the original): downmix to mono -> 2-tap damp -> Hann-ish envelope ->
//  zero-padded FFT -> sum into 3 octave-equal bands (200Hz-11025Hz) -> divide by empirically-tuned
//  per-band constants -> exponential smoothing at three time constants (imm/avg/long_avg) -> take
//  ratios. `imm_rel` (exposed as `bass`/`mid`/`treb`) is spiky and instantaneous; `avg_rel` (exposed
//  as `bass_att`/`mid_att`/`treb_att`) is the smoothed, "attenuated" version presets use for anything
//  that shouldn't jitter frame to frame.
//

import Accelerate
import Foundation

struct MilkdropBandEnergy {
    /// imm_rel: instantaneous band level relative to its long-term average. ~1.0 is "normal";
    /// spikes well above 1 on a hit. Good for one-shot flashes/onset detection.
    var bass: Float = 1
    var mid: Float = 1
    var treb: Float = 1
    /// avg_rel: same idea but smoothed (med/long-term blend), MilkDrop's "_att" variables. Good
    /// for continuous modulation (zoom, hue, scale) that shouldn't jitter.
    var bassAtt: Float = 1
    var midAtt: Float = 1
    var trebAtt: Float = 1
}

final class MilkdropSignalAnalyzer {
    // Mirrors MilkDrop's NUM_WAVEFORM_SAMPLES / NUM_FREQUENCIES relationship: 576 raw samples in,
    // a power-of-2 FFT out. CoreAudioTapEngine's ring buffer is sized to match (576) for exactly
    // this reason.
    private let sampleCount = 576
    private let log2n: vDSP_Length = 10 // 1024-point FFT, matches NFREQ = NUM_FREQUENCIES*2
    private let fftSize: Int
    private let fftSetup: FFTSetup?
    private let envelope: [Float]

    // MilkDrop's octave-equal 3-band split, 200Hz-11025Hz (see pluginshell.cpp ProcessData).
    private let minFreq: Float = 200.0
    private let maxFreqRef: Float = 11025.0
    // Empirically-determined long-term averages MilkDrop divides out (from a 244-song trial).
    private let bandNormalization: [Float] = [0.326781557, 0.380873770, 0.199888934]

    // Temporal state, one triplet [bass, mid, treb] each — persists across calls like m_sound does.
    private var imm: [Float] = [0, 0, 0]
    private var avg: [Float] = [1, 1, 1]
    private var longAvg: [Float] = [1, 1, 1]

    // Scratch buffers, reused every call instead of allocated fresh. `process` runs on the main
    // thread inside Canvas's content closure — up to 120x/sec on a ProMotion display — so the ~9
    // heap allocations this used to do per call were pure avoidable churn. `fftBuffer` is sized to
    // the full FFT length but only its first `sampleCount` entries are ever written (the windowed
    // signal); the zero-padded tail is zeroed once at init and, since nothing else ever touches it,
    // stays zero for the object's whole lifetime — that's what makes the zero-padding "free".
    private var lastMono: [Float]
    private var monoBuf: [Float]
    private var dampedBuf: [Float]
    private var fftBuffer: [Float]
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var magBuf: [Float]

    init() {
        self.fftSize = 1 << Int(log2n)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        var win = [Float](repeating: 0, count: sampleCount)
        vDSP_hann_window(&win, vDSP_Length(sampleCount), Int32(vDSP_HANN_NORM))
        self.envelope = win
        self.lastMono = [Float](repeating: 0, count: sampleCount)
        self.monoBuf = [Float](repeating: 0, count: sampleCount)
        self.dampedBuf = [Float](repeating: 0, count: sampleCount)
        self.fftBuffer = [Float](repeating: 0, count: fftSize)
        self.realBuf = [Float](repeating: 0, count: fftSize / 2)
        self.imagBuf = [Float](repeating: 0, count: fftSize / 2)
        self.magBuf = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// `sampleRate` should match the capture engine's actual rate (CoreAudioTapEngine taps the
    /// system default output device, so this is normally 44.1/48kHz). `fps` drives the frame-rate
    /// independent smoothing exactly as MilkDrop's AdjustRateToFPS does.
    func process(left: [Float], right: [Float], sampleRate: Float, fps: Double) -> MilkdropBandEnergy {
        guard let fftSetup, left.count >= sampleCount, right.count >= sampleCount else {
            return MilkdropBandEnergy(bass: bass_rel(0), mid: bass_rel(1), treb: bass_rel(2),
                                       bassAtt: avg_rel(0), midAtt: avg_rel(1), trebAtt: avg_rel(2))
        }

        // Downmix to mono, matching the (left+right)/2 spirit MilkDrop's preset engine expects
        // for a single bass/mid/treb signal (the original keeps L/R separate only for waveform
        // drawing, not for the preset-facing bands). Indexed directly off the tail of left/right
        // rather than via `.suffix(...)` + `Array(...)`, which would allocate two throwaway arrays.
        let lOffset = left.count - sampleCount
        let rOffset = right.count - sampleCount
        for i in 0..<sampleCount {
            monoBuf[i] = 0.5 * (left[lOffset + i] + right[rOffset + i])
        }

        // 2-tap damp: temp[i] = 0.5*(mono[i] + mono[i-1]), continuous across calls via lastMono.
        dampedBuf[0] = 0.5 * (monoBuf[0] + lastMono[sampleCount - 1])
        for i in 1..<sampleCount {
            dampedBuf[i] = 0.5 * (monoBuf[i] + monoBuf[i - 1])
        }
        for i in 0..<sampleCount { lastMono[i] = monoBuf[i] }

        // Window straight into fftBuffer's first `sampleCount` slots; its zero-padded tail was
        // zeroed once at init and is never written anywhere else, so it's already correct here.
        vDSP_vmul(dampedBuf, 1, envelope, 1, &fftBuffer, 1, vDSP_Length(sampleCount))

        realBuf.withUnsafeMutableBufferPointer { realPtr in
            imagBuf.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                fftBuffer.withUnsafeMutableBufferPointer { fftPtr in
                    fftPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magBuf, 1, vDSP_Length(fftSize / 2))
            }
        }

        let n = magBuf.count
        let nyquist = sampleRate / 2.0
        let maxFreq = min(maxFreqRef, nyquist)
        let netOctaves = log2(maxFreq / minFreq)
        let octavesPerBand = netOctaves / 3.0
        let mult = powf(2.0, octavesPerBand)

        for band in 0..<3 {
            let startFreq = minFreq * powf(mult, Float(band))
            let endFreq = minFreq * powf(mult, Float(band + 1))
            let start = max(0, min(n - 1, Int(Float(n) * startFreq / maxFreqRef)))
            let end = max(start + 1, min(n, Int(Float(n) * endFreq / maxFreqRef)))

            var sum: Float = 0
            for i in start..<end { sum += magBuf[i] }
            var level = sum / Float(end - start)
            level /= bandNormalization[band]
            imm[band] = level

            let attackRate = adjustRateToFPS(0.2, fps1: 14.0, actualFPS: fps)
            let releaseRate = adjustRateToFPS(0.5, fps1: 14.0, actualFPS: fps)
            let avgMix = level > avg[band] ? attackRate : releaseRate
            avg[band] = avg[band] * avgMix + level * (1 - avgMix)

            let longMix = adjustRateToFPS(0.96, fps1: 14.0, actualFPS: fps)
            longAvg[band] = longAvg[band] * longMix + level * (1 - longMix)
        }

        return MilkdropBandEnergy(
            bass: bass_rel(0), mid: bass_rel(1), treb: bass_rel(2),
            bassAtt: avg_rel(0), midAtt: avg_rel(1), trebAtt: avg_rel(2)
        )
    }

    private func bass_rel(_ i: Int) -> Float {
        abs(longAvg[i]) < 0.001 ? 1.0 : imm[i] / longAvg[i]
    }

    private func avg_rel(_ i: Int) -> Float {
        abs(longAvg[i]) < 0.001 ? 1.0 : avg[i] / longAvg[i]
    }

    /// Port of utility.cpp's AdjustRateToFPS: converts a decay rate tuned at `fps1` into the
    /// equivalent per-frame rate at `actualFPS`, so smoothing feels the same regardless of the
    /// display's refresh rate.
    private func adjustRateToFPS(_ perFrameDecayAtFPS1: Float, fps1: Float, actualFPS: Double) -> Float {
        guard actualFPS > 0 else { return perFrameDecayAtFPS1 }
        let perSecondDecay = powf(perFrameDecayAtFPS1, fps1)
        return powf(perSecondDecay, 1.0 / Float(actualFPS))
    }
}
