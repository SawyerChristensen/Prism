//
//  MilkdropWaveMode.swift
//  Prism
//
//  The waveform's mode/config model, split out of MilkdropWaveform.swift (which stays focused on
//  the point-generation math itself). See that file's header for the DrawWave()/SmoothWave() port
//  this all feeds into.
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

    /// Maps Milkdrop's `nWaveMode` preset constant (0-15, wrapped mod 16 by the original engine)
    /// onto the closest mode Prism has. Stock Milkdrop modes 4 (DerivativeLine), 5 (ExplosiveHash)
    /// and 8 (SpectrumLine, unfinished upstream too) have no Prism equivalent yet and fall back to
    /// .line rather than failing preset load over an unsupported wave mode.
    init(presetWaveMode raw: Int) {
        let wrapped = ((raw % 16) + 16) % 16
        switch wrapped {
        case 0: self = .circular
        case 1: self = .spiral
        case 2, 3: self = .spiro
        case 7: self = .dualLine
        case 9: self = .wideLine
        case 10: self = .crossX
        case 11: self = .dualParallel
        case 12: self = .skewedLoop
        case 13: self = .star
        case 14: self = .flower
        case 15: self = .lasso
        default: self = .line // 4, 5, 6, 8
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
