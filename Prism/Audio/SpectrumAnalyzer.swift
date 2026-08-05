//
//  SpectrumAnalyzer.swift
//  Prism
//
//  Shared FFT/banding pipeline fed by CoreAudioTapEngine's captured audio.
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
    
    // Configurable audio parameters
    private let sampleRate: Float = 44100.0 // Change this if your audio session differs
    private let minFrequency: Float = 60.0  // Skip sub-bass rumble
    private let maxFrequency: Float = 10000.0 // Skip inaudible high-end hiss
    
    // Dynamic range in decibels (dB)
    private let minDB: Float = -65.0
    private let maxDB: Float = 0.0
    
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
                
                // FIXED: Use zvabs for linear magnitudes instead of squared magnitudes
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // FIXED: Normalize the magnitudes so a full-volume wave equals 1.0
        var scalingFactor = Float(2.0 / Float(fftSize))
        magnitudes.withUnsafeMutableBufferPointer { magPtr in
            vDSP_vsmul(magPtr.baseAddress!, 1, &scalingFactor, magPtr.baseAddress!, 1, vDSP_Length(fftSize / 2))
        }

        let nyquist = sampleRate / 2.0
        let binSize = nyquist / Float(magnitudes.count)
        
        let minBin = max(1, Int(minFrequency / binSize))
        let maxBin = min(magnitudes.count - 1, Int(maxFrequency / binSize))
        
        let logMin = log2(Double(minBin))
        let logMax = log2(Double(maxBin))
        let logRange = logMax - logMin

        var bars = [CGFloat](repeating: 0.02, count: bandCount)

        for i in 0..<bandCount {
            let startLog = logMin + (Double(i) / Double(bandCount)) * logRange
            let endLog = logMin + (Double(i + 1) / Double(bandCount)) * logRange

            let actualStart = Int(pow(2, startLog))
            let actualEnd = max(actualStart + 1, Int(pow(2, endLog)))
            
            let safeStart = min(magnitudes.count - 1, max(1, actualStart))
            let safeEnd = min(magnitudes.count, max(safeStart + 1, actualEnd))

            let slice = magnitudes[safeStart..<safeEnd]
            
            let amplitude = slice.max() ?? 0.0

            // FIXED: Use 20 * log10 for linear amplitude to dBFS
            let decibels = amplitude > 0 ? 20.0 * log10(amplitude) : -100.0

            var target = (decibels - minDB) / (maxDB - minDB)
            target = max(0.0, min(1.0, target))

            let highFreqBoost = 1.0 + (Float(i) / Float(bandCount)) * 0.5
            target = min(1.0, target * highFreqBoost)

            if target > smoothedLevels[i] {
                smoothedLevels[i] = target
            } else {
                smoothedLevels[i] = smoothedLevels[i] * 0.85 + target * 0.15
            }

            bars[i] = CGFloat(max(0.02, smoothedLevels[i]))
        }
        
        return bars
    }
}
