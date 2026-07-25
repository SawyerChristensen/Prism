//
//  MilkdropVisualizerView.swift
//  Prism
//
//  Public-facing wrapper: owns the mode/params model, forwards a tap gesture to cycle modes, and
//  hosts the actual GPU renderer (MilkdropMetalView / MilkdropMetalRenderer). The old CPU
//  CGContext-based Canvas renderer lived here — see MilkdropMetalRenderer.swift's header for why
//  it moved to Metal (fullscreen on a large/high-refresh display was CPU-bound and couldn't hold
//  120fps; a GPU-based feedback buffer also gives real headroom for future 3D/warp effects, which
//  a CPU bitmap never would have).
//

import SwiftUI

@Observable
final class MilkdropVisualizerModel {
    var mode: MilkdropWaveMode = .line
    var params = MilkdropWaveformParams()

    /// File name of the currently loaded .milk preset, or nil if none was ever loaded (Prism runs
    /// fine with just the built-in modes/params above — a preset is an optional override).
    private(set) var presetName: String?
    /// Not private(set): the view clears this once the user dismisses the load-failure alert.
    var presetLoadError: String?

    // Live per-frame state for the loaded preset's expression program, if any (see
    // MilkdropExpressionEvaluator.swift/MilkdropPresetFile.swift). `presetVariables` persists
    // across frames — presets read back their own previous values (`wave_x=wave_x+0.001;`) same
    // as projectM's per-frame context does.
    private var perFrameProgram: MilkdropExpressionProgram?
    private var presetVariables: [String: Float] = [:]

    func cycleMode() {
        let all = MilkdropWaveMode.allCases
        let idx = all.firstIndex(of: mode) ?? 0
        mode = all[(idx + 1) % all.count]
    }

    /// Loads a .milk preset's wave-related constants into `mode`/`params` and, if the preset has a
    /// per-frame program, prepares it for `updatePresetPerFrame` to drive each frame. Only the
    /// waveform layer is affected — warp/composite/shape/shader state in the file is ignored (see
    /// MilkdropPresetFile.swift's header for why).
    func loadPreset(from url: URL) {
        do {
            let file = try MilkdropPresetFile(contentsOf: url)
            mode = MilkdropWaveMode(presetWaveMode: file.waveMode)
            params.scale = file.waveScale
            params.smoothing = min(max(file.waveSmoothing, 0), 0.9)
            params.mysteryParam = file.waveParam

            presetVariables = [
                "wave_x": file.waveX, "wave_y": file.waveY, "wave_mystery": file.waveParam,
                "wave_r": file.waveR, "wave_g": file.waveG, "wave_b": file.waveB, "wave_a": file.waveAlpha,
                "wave_mode": Float(file.waveMode),
            ]
            // Runs once, immediately — seeds any custom variables (e.g. `SPEED=10;`) the per-frame
            // program below expects to already exist on its first evaluation.
            MilkdropExpressionProgram(source: file.perFrameInitProgram)?.evaluate(&presetVariables)
            perFrameProgram = MilkdropExpressionProgram(source: file.perFrameProgram)
            presetName = url.deletingPathExtension().lastPathComponent
            presetLoadError = nil
        } catch {
            presetLoadError = "Couldn't load \(url.lastPathComponent): \(error)"
        }
    }

    /// Runs the loaded preset's per-frame program (if any) against this frame's timing/audio
    /// inputs and folds the result back into `params`. No-op if no preset (or one with no
    /// per-frame code) is loaded. `energy` mirrors projectM's bass/mid/treb(_att) per-frame
    /// variables — see MilkdropAudioSignals.swift.
    func updatePresetPerFrame(time: Double, fps: Double, frame: Int, energy: MilkdropBandEnergy) {
        guard let perFrameProgram else { return }

        presetVariables["time"] = Float(time)
        presetVariables["fps"] = Float(fps)
        presetVariables["frame"] = Float(frame)
        presetVariables["progress"] = 0 // No preset-to-preset blend/fade in Prism yet.
        presetVariables["bass"] = energy.bass
        presetVariables["mid"] = energy.mid
        presetVariables["treb"] = energy.treb
        presetVariables["bass_att"] = energy.bassAtt
        presetVariables["mid_att"] = energy.midAtt
        presetVariables["treb_att"] = energy.trebAtt

        perFrameProgram.evaluate(&presetVariables)

        if let mystery = presetVariables["wave_mystery"] {
            params.mysteryParam = mystery
        }
        // wave_x/wave_y/wave_r/g/b land in presetVariables too, for a future waveform-centering/
        // preset-color pass — not consumed yet since no current mode reads a center offset.
    }
}

struct MilkdropVisualizerView: View {
    let audioEngine: CoreAudioTapEngine
    var color: Color
    /// 0...1 bass energy, used to thicken the line the way MilkDrop's mod-alpha-by-volume does.
    var bassEnergy: CGFloat = 0
    /// Owned by the caller (ContentView) so a keyboard shortcut can drive mode-cycling too, not
    /// just the tap gesture below.
    var model: MilkdropVisualizerModel

    var body: some View {
        MilkdropMetalView(audioEngine: audioEngine, color: color, bassEnergy: bassEnergy, model: model)
            .contentShape(Rectangle())
            .onTapGesture { model.cycleMode() }
    }
}
