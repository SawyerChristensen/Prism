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

    // Custom shapes (`shapecode_N_*`) loaded alongside the waveform program above — see
    // MilkdropShapeState.swift. Always 4 slots (disabled ones resolve to zero instances, so
    // MilkdropMetalRenderer never needs to check `enabled` itself).
    private var shapes: [MilkdropShapeRuntime] = []

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
            params.waveX = 2 * file.waveX - 1
            params.waveY = 2 * file.waveY - 1

            presetVariables = [
                "wave_x": file.waveX, "wave_y": file.waveY, "wave_mystery": file.waveParam,
                "wave_r": file.waveR, "wave_g": file.waveG, "wave_b": file.waveB, "wave_a": file.waveAlpha,
                "wave_mode": Float(file.waveMode),
            ]
            // Runs once, immediately — seeds any custom variables (e.g. `SPEED=10;`) the per-frame
            // program below expects to already exist on its first evaluation.
            MilkdropExpressionProgram(source: file.perFrameInitProgram)?.evaluate(&presetVariables)
            perFrameProgram = MilkdropExpressionProgram(source: file.perFrameProgram)
            shapes = file.shapes.map(MilkdropShapeRuntime.init(preset:))
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
        // wave_x/wave_y stay in presetVariables in Milkdrop's raw 0...1 space (matching the
        // upstream per-frame variable a script like `wave_x=wave_x+0.001;` reads/writes) — convert
        // to Prism's -1...1 space only here, at the point of handing off to params.
        if let x = presetVariables["wave_x"] {
            params.waveX = 2 * x - 1
        }
        if let y = presetVariables["wave_y"] {
            params.waveY = 2 * y - 1
        }
        // wave_r/g/b land in presetVariables too, for a future preset-color pass — not consumed
        // yet since color is currently driven by album art (see AlbumColors.swift).
    }

    /// Resolves every loaded shape's per-frame script for this frame, one instance array per shape
    /// slot (disabled/instance-less shapes contribute an empty array). Called from
    /// MilkdropMetalRenderer.draw(in:) alongside updatePresetPerFrame, with the same per-frame
    /// timing/audio inputs.
    func updateShapesPerFrame(time: Double, fps: Double, frame: Int, energy: MilkdropBandEnergy) -> [[MilkdropShapeInstance]] {
        shapes.map { $0.resolveInstances(time: Float(time), fps: Float(fps), frame: Float(frame), energy: energy) }
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
