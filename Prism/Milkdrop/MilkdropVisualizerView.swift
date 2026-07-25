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

/// Per-frame feedback-transform state (Milkdrop's `zoom`/`rot`/`cx`/`cy`/`dx`/`dy`/`sx`/`sy`/`warp`/
/// `decay` per-frame variables) — what drives the warped background trail, distinct from the
/// waveform's own params. Defaults match projectM's PresetState.hpp exactly (see
/// MilkdropPresetFile.swift), so an unloaded/preset-less renderer sees the same neutral transform
/// (no zoom, no rotation, no stretch) real Milkdrop would show for a preset that sets nothing.
struct MilkdropWarpParams {
    var zoom: Float = 1.0
    var zoomExponent: Float = 1.0
    var rot: Float = 0.0
    var rotCX: Float = 0.5
    var rotCY: Float = 0.5
    var xPush: Float = 0.0
    var yPush: Float = 0.0
    var warpAmount: Float = 1.0
    var stretchX: Float = 1.0
    var stretchY: Float = 1.0
    var decay: Float = 0.98
}

@Observable
final class MilkdropVisualizerModel {
    var mode: MilkdropWaveMode = .line
    var params = MilkdropWaveformParams()
    /// Read every frame by MilkdropMetalRenderer to drive the feedback pass's warp transform — see
    /// updatePresetPerFrame below.
    private(set) var warpParams = MilkdropWarpParams()
    /// Static per-preset constants (not per-frame-scriptable — see MilkdropPresetFile.swift) that
    /// shape the warp-wiggle animation's speed/scale. Read directly by MilkdropMetalRenderer.
    private(set) var warpAnimSpeed: Float = 1.0
    private(set) var warpScale: Float = 1.0
    /// Raw HLSL `comp_N=` source (see MilkdropPresetFile.swift), compiled by MilkdropMetalRenderer —
    /// the model has no Metal device, so it only carries the source text. `warpShaderSource` is
    /// parsed too but not yet compiled/used anywhere (see MilkdropShaderTranslator.swift's header
    /// for why composite shaders shipped first: they're a clean additional pass on plain screen UV,
    /// while a custom warp shader needs to duplicate the geometric zoom/rotate/stretch/wiggle math
    /// mid-shader to receive the same per-pixel UV the mesh already computes — real, but more
    /// involved, and deliberately deferred rather than shipped as a rougher approximation).
    private(set) var compositeShaderSource: String = ""
    /// Bumped on every `loadPreset(from:)` call — MilkdropMetalRenderer compares this against the
    /// generation it last compiled shaders for, recompiling only on an actual preset change rather
    /// than every frame (dynamic Metal shader compilation is not something to do 60x/sec).
    private(set) var loadGeneration = 0

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
                // Feedback warp-transform starting values — a per-frame script that only reads
                // (never assigns) one of these, e.g. `dx=dx+bass*0.001;`, needs it pre-seeded to
                // Milkdrop's real per-frame default, not the evaluator's own undeclared-variable-is-0
                // fallback (0 would break `zoom`, `sx`/`sy`, `zoomexp` particularly, whose neutral
                // value is 1, not 0).
                "zoom": file.zoom, "zoomexp": file.zoomExponent, "rot": file.rot,
                "cx": file.rotCX, "cy": file.rotCY, "dx": file.xPush, "dy": file.yPush,
                "warp": file.warpAmount, "sx": file.stretchX, "sy": file.stretchY, "decay": file.decay,
            ]
            // Runs once, immediately — seeds any custom variables (e.g. `SPEED=10;`) the per-frame
            // program below expects to already exist on its first evaluation.
            MilkdropExpressionProgram(source: file.perFrameInitProgram)?.evaluate(&presetVariables)
            perFrameProgram = MilkdropExpressionProgram(source: file.perFrameProgram)
            shapes = file.shapes.map(MilkdropShapeRuntime.init(preset:))
            warpAnimSpeed = file.warpAnimSpeed
            warpScale = file.warpScale
            compositeShaderSource = file.compositeShaderSource
            loadGeneration += 1
            presetName = url.deletingPathExtension().lastPathComponent
            presetLoadError = nil
        } catch {
            presetLoadError = "Couldn't load \(url.lastPathComponent): \(error)"
        }
    }

    /// Runs the loaded preset's per-frame program (if any) against this frame's timing/audio
    /// inputs and folds the result back into `params`/`warpParams`. Still refreshes `warpParams`
    /// from `presetVariables` even with no program loaded (or one with no per-frame code) — a
    /// preset can set `zoom`/`rot`/etc. as plain static constants with no per-frame code touching
    /// them at all, and those still need to reach the renderer. `energy` mirrors projectM's
    /// bass/mid/treb(_att) per-frame variables — see MilkdropAudioSignals.swift.
    func updatePresetPerFrame(time: Double, fps: Double, frame: Int, energy: MilkdropBandEnergy) {
        if let perFrameProgram {
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
        }

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

        if let zoom = presetVariables["zoom"] { warpParams.zoom = zoom }
        if let zoomExponent = presetVariables["zoomexp"] { warpParams.zoomExponent = zoomExponent }
        if let rot = presetVariables["rot"] { warpParams.rot = rot }
        if let cx = presetVariables["cx"] { warpParams.rotCX = cx }
        if let cy = presetVariables["cy"] { warpParams.rotCY = cy }
        if let dx = presetVariables["dx"] { warpParams.xPush = dx }
        if let dy = presetVariables["dy"] { warpParams.yPush = dy }
        if let warp = presetVariables["warp"] { warpParams.warpAmount = warp }
        if let sx = presetVariables["sx"] { warpParams.stretchX = sx }
        if let sy = presetVariables["sy"] { warpParams.stretchY = sy }
        if let decay = presetVariables["decay"] { warpParams.decay = decay }
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
