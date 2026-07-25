//
//  MilkdropWaveformAligner.swift
//  Prism
//
//  Port of projectM's Audio/WaveformAligner.{hpp,cpp} — a mip-based cross-correlation alignment
//  pass that shifts each frame's raw waveform buffer to best match the previous frame's, so scope
//  features hold roughly still instead of sliding around under raw PCM jitter. This is the piece
//  MilkDrop's oscilloscope has that a plain "draw the latest samples" scope doesn't; without it,
//  .line/.dualLine/.circular etc. visibly crawl even on a steady tone.
//
//  Runs on a buffer larger than what actually gets drawn: the tail beyond `visibleSampleCount`
//  is search margin, not rendered data (CoreAudioTapEngine's 576-sample ring buffer against
//  projectM's own 480-sample visible window — see AudioConstants.hpp's AudioBufferSamples/
//  WaveformSamples split). Purely CPU: a handful of ~576-sample arrays and a bounded search over
//  6-ish octaves, all fixed-size and tiny — no GPU dispatch would pay for itself here.
//

import Foundation

final class MilkdropWaveformAligner {
    /// projectM's own WaveformSamples: how many samples of a larger capture buffer are actually
    /// rendered, with the remainder held back purely as alignment search margin.
    static let visibleSampleCount = 480

    private let bufferSampleCount: Int
    private let visibleSampleCount: Int
    private let octaves: Int

    private var alignmentWeights: [[Float]] = []
    private var octaveSamples: [Int] = []
    private var octaveSampleSpacing: [Int] = []
    private var oldWaveformMips: [[Float]] = []
    private var firstNonzeroWeights: [Int] = []
    private var lastNonzeroWeights: [Int] = []
    private var weightsReady = false

    /// `bufferSampleCount` must exceed `visibleSampleCount` by enough margin to search (projectM
    /// uses 576 vs 480, a 96-sample margin -> 6 octaves). Below 4 octaves of margin, `align(_:)`
    /// becomes a no-op, matching the original's own bailout.
    init(bufferSampleCount: Int, visibleSampleCount: Int) {
        self.bufferSampleCount = bufferSampleCount
        self.visibleSampleCount = visibleSampleCount

        let maxOctaves = 10
        let margin = bufferSampleCount - visibleSampleCount
        let numOctaves = margin > 0 ? Int(floor(log2(Float(margin)))) : 0
        octaves = min(numOctaves, maxOctaves)

        guard octaves > 0 else { return }

        octaveSamples = Array(repeating: 0, count: octaves)
        octaveSampleSpacing = Array(repeating: 0, count: octaves)
        octaveSamples[0] = bufferSampleCount
        octaveSampleSpacing[0] = margin
        for octave in 1..<octaves {
            octaveSamples[octave] = octaveSamples[octave - 1] / 2
            octaveSampleSpacing[octave] = octaveSampleSpacing[octave - 1] / 2
        }

        alignmentWeights = octaveSamples.map { Array(repeating: 0, count: $0) }
        oldWaveformMips = octaveSamples.map { Array(repeating: 0, count: $0) }
        firstNonzeroWeights = Array(repeating: 0, count: octaves)
        lastNonzeroWeights = Array(repeating: 0, count: octaves)
    }

    /// Shifts `waveform` (must have at least `bufferSampleCount` elements) in place so its first
    /// `visibleSampleCount` samples best match the previous call's aligned buffer. Everything past
    /// that is zeroed — callers should only read the first `visibleSampleCount` samples afterward.
    func align(_ waveform: inout [Float]) {
        guard octaves >= 4, waveform.count >= bufferSampleCount else { return }

        let newMips = resampleOctaves(waveform)

        if !weightsReady {
            generateWeights()
            weightsReady = true
        }

        let offset = calculateOffset(newMips)

        if offset > 0 {
            for i in 0..<visibleSampleCount {
                waveform[i] = waveform[i + offset]
            }
            for i in visibleSampleCount..<bufferSampleCount {
                waveform[i] = 0
            }
        }

        // Mips for next frame's comparison must be of the *shifted* buffer, not reused from above.
        oldWaveformMips = resampleOctaves(waveform)
    }

    /// Octave 0 is the raw buffer; each further octave halves the sample count by averaging pairs
    /// — a simple box-filter mip chain, same as ResampleOctaves in the original.
    private func resampleOctaves(_ waveform: [Float]) -> [[Float]] {
        var mips = [[Float]]()
        mips.reserveCapacity(octaves)
        mips.append(Array(waveform.prefix(bufferSampleCount)))
        for octave in 1..<octaves {
            let previous = mips[octave - 1]
            let n = octaveSamples[octave]
            var level = [Float](repeating: 0, count: n)
            for sample in 0..<n {
                level[sample] = 0.5 * (previous[sample * 2] + previous[sample * 2 + 1])
            }
            mips.append(level)
        }
        return mips
    }

    /// Builds a per-octave, per-sample weighting for the cross-correlation error sum: a
    /// pyramid shape (0 at the edges, 1 at the center) squeezed by an empirical tweak that zeroes
    /// out ~64% of samples on either side, so the search focuses on the middle of each octave's
    /// comparison window. Computed once, since it depends only on buffer geometry, not audio data.
    private func generateWeights() {
        for octave in 0..<octaves {
            let compareSamples = octaveSamples[octave] - octaveSampleSpacing[octave]
            guard compareSamples > 0 else { continue }

            for sample in 0..<compareSamples {
                var weight: Float
                if sample < compareSamples / 2 {
                    weight = Float(sample * 2) / Float(compareSamples)
                } else {
                    weight = Float((compareSamples - 1 - sample) * 2) / Float(compareSamples)
                }
                weight = (weight - 0.8) * 5.0 + 0.8
                alignmentWeights[octave][sample] = min(1, max(0, weight))
            }

            var first = 0
            while first < compareSamples, alignmentWeights[octave][first] == 0 {
                first += 1
            }
            firstNonzeroWeights[octave] = min(first, compareSamples - 1)

            var last = compareSamples - 1
            while last > 0, alignmentWeights[octave][last] == 0 {
                last -= 1
            }
            lastNonzeroWeights[octave] = last
        }
    }

    /// Coarse-to-fine search: starts at the lowest-resolution octave (cheapest, widest search
    /// range), finds the offset with the lowest weighted absolute error against last frame's mip,
    /// then narrows the search window for the next (higher-resolution) octave around that result.
    /// The final, finest-octave offset is what actually gets applied to the real buffer.
    private func calculateOffset(_ newMips: [[Float]]) -> Int {
        var alignOffset = 0
        var offsetStart = 0
        var offsetEnd = octaveSampleSpacing[octaves - 1]

        var octave = octaves - 1
        while octave >= 0 {
            var lowestErrorOffset = -1
            var lowestErrorAmount: Float = 0

            var sample = offsetStart
            while sample < offsetEnd {
                var errorSum: Float = 0
                var i = firstNonzeroWeights[octave]
                while i <= lastNonzeroWeights[octave] {
                    errorSum += abs((newMips[octave][i + sample] - oldWaveformMips[octave][i]) * alignmentWeights[octave][i])
                    i += 1
                }

                if lowestErrorOffset == -1 || errorSum < lowestErrorAmount {
                    lowestErrorOffset = sample
                    lowestErrorAmount = errorSum
                }
                sample += 1
            }

            // First pass through an all-zero-margin octave (offsetStart == offsetEnd) never enters
            // the loop above, so lowestErrorOffset stays -1 — fall back to "no shift" rather than
            // propagate a sentinel into the next octave's search bounds.
            let resolvedOffset = max(0, lowestErrorOffset)

            if octave > 0 {
                offsetStart = max(0, resolvedOffset * 2 - 1)
                offsetEnd = min(octaveSampleSpacing[octave - 1], resolvedOffset * 2 + 2 + 1)
            } else {
                alignOffset = resolvedOffset
            }
            octave -= 1
        }

        return alignOffset
    }
}
