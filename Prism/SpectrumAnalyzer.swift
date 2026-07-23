//
//  SpectrumAnalyzer.swift
//  Prism
//
//  Shared FFT/banding pipeline used by both audio capture engines (ScreenCaptureKit and
//  Core Audio Taps), so comparing the two only varies the capture mechanism, not the analysis.
//

import Accelerate
import CoreGraphics
import os

private let logger = Logger(subsystem: "com.prism.app", category: "SpectrumAnalyzer")

final class SpectrumAnalyzer {
    let bandCount: Int
    private let log2n: vDSP_Length
    private let fftSize: Int
    private let fftSetup: FFTSetup?
    private let hannWindow: [Float]

    // Adaptive normalization state: since vDSP's FFT output is unnormalized (its absolute
    // scale isn't a fixed, known constant), we track a slowly-decaying peak and normalize
    // each band relative to it, rather than mapping onto a hand-picked dB range that would
    // either clip everything to the ceiling or amplify silence into visual noise.
    private var runningPeak: Float = 0.001
    private var smoothedLevels: [Float]

    init(bandCount: Int = 40, log2n: vDSP_Length = 11) {
        self.bandCount = bandCount
        self.log2n = log2n
        self.fftSize = 1 << Int(log2n)
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.hannWindow = window
        self.smoothedLevels = Array(repeating: 0, count: bandCount)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func process(_ samples: [Float], shouldLog: Bool = false) -> [CGFloat] {
        guard let fftSetup else { return smoothedLevels.map { CGFloat($0) } }

        var window = samples.count >= fftSize
            ? Array(samples.prefix(fftSize))
            : samples + Array(repeating: 0, count: fftSize - samples.count)

        // Taper the edges of the chunk so it isn't treated as periodic, which otherwise
        // smears energy across unrelated bins (spectral leakage) and reads as noise.
        vDSP_vmul(window, 1, hannWindow, 1, &window, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                window.withUnsafeMutableBufferPointer { windowPtr in
                    windowPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let usableBins = magnitudes.count / 2 // ignore the top half, mostly inaudible/noise-dominated
        let binsPerBand = max(1, usableBins / bandCount)

        var rawBands = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let start = i * binsPerBand
            let end = min(start + binsPerBand, usableBins)
            guard start < end else { continue }
            let slice = magnitudes[start..<end]
            rawBands[i] = slice.reduce(0, +) / Float(slice.count)
        }

        // Normalize against a slowly-decaying peak so bars track relative loudness regardless
        // of the FFT's absolute scale, then apply an attack/decay envelope: snap up instantly
        // on transients, ease down otherwise, so it reads as music rather than raw per-frame jitter.
        let framePeak = rawBands.max() ?? 0
        runningPeak = max(framePeak, runningPeak * 0.985)
        runningPeak = max(runningPeak, 0.001)

        if shouldLog {
            logger.debug("framePeak=\(framePeak, privacy: .public), runningPeak=\(self.runningPeak, privacy: .public)")
        }

        var bars = [CGFloat](repeating: 0.02, count: bandCount)
        for i in 0..<bandCount {
            let target = sqrt(min(1, rawBands[i] / runningPeak))
            smoothedLevels[i] = target > smoothedLevels[i]
                ? target
                : smoothedLevels[i] * 0.75 + target * 0.25
            bars[i] = CGFloat(max(0.02, min(1, smoothedLevels[i])))
        }
        return bars
    }
}
