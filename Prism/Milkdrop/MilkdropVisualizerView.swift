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
import simd

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

/// Per-frame Border.cpp/DarkenCenter.cpp state — the two nested-square border outlines and the
/// small dark center smudge, both drawn on top of the shape/waveform layer (see
/// MilkdropMetalRenderer.swift's border/darken-center draw call). Defaults match PresetState.hpp
/// exactly, same as MilkdropWarpParams above.
struct MilkdropBorderParams {
    var outerSize: Float = 0.01
    var outerR: Float = 0.0
    var outerG: Float = 0.0
    var outerB: Float = 0.0
    var outerA: Float = 0.0
    var innerSize: Float = 0.01
    var innerR: Float = 0.25
    var innerG: Float = 0.25
    var innerB: Float = 0.25
    var innerA: Float = 0.0
    /// `darken_center` upstream — a plain per-frame float gated on `> 0`, not a bool, since a
    /// script can toggle it frame-to-frame (see PerFrameContext.cpp's REG_VAR(darken_center)).
    var darkenCenter: Float = 0.0
}

/// Per-frame VideoEcho.cpp/Filters.cpp state — real Milkdrop's "old-school" final-composite path,
/// used instead of a `comp_N=` shader for presets with no composite shader at all (see
/// MilkdropPresetFile.swift's `usesOldStyleFinalComposite`). Defaults match PresetState.hpp exactly:
/// note `gammaAdj` defaults to 2.0, not 1.0 — every old-style preset's output is brightness-doubled
/// by default, not just optionally adjusted.
struct MilkdropOldStyleCompositeParams {
    var gammaAdj: Float = 2.0
    var videoEchoZoom: Float = 2.0
    var videoEchoAlpha: Float = 0.0
    var videoEchoOrientation: Float = 0.0
    var brighten: Float = 0.0
    var darken: Float = 0.0
    var solarize: Float = 0.0
    var invert: Float = 0.0
}

@Observable
final class MilkdropVisualizerModel {
    /// Precomputed "q1".."q32" dictionary keys — see MilkdropCustomWaveform.swift's identical
    /// `qKeys` for why (avoids re-interpolating the same 32 strings every time `qVariables` reads
    /// them back out of `presetVariables`).
    private static let qKeys: [String] = (1...32).map { "q\($0)" }

    var mode: MilkdropWaveMode = .line
    var params = MilkdropWaveformParams()
    /// Smoothed (exponential moving average, not instantaneous) frames-per-second, written by
    /// MilkdropMetalRenderer once per frame — read by ContentView's on-screen performance counter.
    /// Smoothed rather than raw 1/dt so the displayed number doesn't jitter every single frame.
    var displayFPS: Double = 60
    /// Read every frame by MilkdropMetalRenderer to drive the feedback pass's warp transform — see
    /// updatePresetPerFrame below.
    private(set) var warpParams = MilkdropWarpParams()
    /// Read every frame by MilkdropMetalRenderer to draw the border/darken-center overlay — see
    /// updatePresetPerFrame below.
    private(set) var borderParams = MilkdropBorderParams()
    /// Read every frame by MilkdropMetalRenderer to draw the old-style final-composite pass — see
    /// updatePresetPerFrame below. Only actually used when `usesOldStyleFinalComposite` is true.
    private(set) var oldStyleCompositeParams = MilkdropOldStyleCompositeParams()
    /// Set once per `loadPreset(from:)` call (not per-frame-scriptable — it's a structural fact
    /// about the preset's format, not a tunable). Gates whether MilkdropMetalRenderer runs the
    /// VideoEcho/Filters pass at all.
    private(set) var usesOldStyleFinalComposite = false
    /// `hueRandomOffsets` upstream (PresetState.cpp) — 4 random phase offsets for VideoEcho's
    /// per-corner hue-cycling tint, freshly rolled once per preset load and fixed for its lifetime
    /// (same role as `MilkdropMetalRenderer`'s own `randPreset` for compiled shaders).
    private(set) var hueRandomOffsets = SIMD4<Float>(0, 0, 0, 0)
    /// Static per-preset constants (not per-frame-scriptable — see MilkdropPresetFile.swift) that
    /// shape the warp-wiggle animation's speed/scale. Read directly by MilkdropMetalRenderer.
    private(set) var warpAnimSpeed: Float = 1.0
    private(set) var warpScale: Float = 1.0
    /// Raw HLSL `comp_N=`/`warp_N=` source (see MilkdropPresetFile.swift), compiled by
    /// MilkdropMetalRenderer — the model has no Metal device, so it only carries the source text.
    private(set) var compositeShaderSource: String = ""
    /// See `compositeShaderSource` above. A compiled `warp_N=` shader replaces the feedback pass's
    /// default warp transform entirely (unlike `comp_N=`, which is an additional pass on top) — see
    /// MilkdropMetalRenderer.buildWarpShaderSource.
    private(set) var warpShaderSource: String = ""
    /// Bumped on every `loadPreset(from:)` call — MilkdropMetalRenderer compares this against the
    /// generation it last compiled shaders for, recompiling only on an actual preset change rather
    /// than every frame (dynamic Metal shader compilation is not something to do 60x/sec).
    private(set) var loadGeneration = 0

    /// File name of the currently loaded .milk preset, or nil if none was ever loaded (Prism runs
    /// fine with just the built-in modes/params above — a preset is an optional override).
    private(set) var presetName: String?
    /// Full URL of the currently loaded .milk preset — read by MilkdropCustomTextureManager to find
    /// the pack's `Textures/` folder relative to wherever this file actually lives.
    private(set) var presetURL: URL?
    /// Not private(set): the view clears this once the user dismisses the load-failure alert.
    var presetLoadError: String?

    // Live per-frame state for the loaded preset's expression program, if any (see
    // MilkdropExpressionEvaluator.swift/MilkdropPresetFile.swift). `presetVariables` persists
    // across frames — presets read back their own previous values (`wave_x=wave_x+0.001;`) same
    // as projectM's per-frame context does.
    private var perFrameProgram: MilkdropResolvedProgram?
    private var presetVariables = MilkdropVariableSlots()

    // Custom shapes (`shapecode_N_*`) loaded alongside the waveform program above — see
    // MilkdropShapeState.swift. Always 4 slots (disabled ones resolve to zero instances, so
    // MilkdropMetalRenderer never needs to check `enabled` itself).
    private var shapes: [MilkdropShapeRuntime] = []

    // The scripted warp mesh (`per_pixel_N=`) for the loaded preset, if it has any — see
    // MilkdropPerPixelMesh.swift. `nil` for the majority of presets (no per_pixel code at all),
    // in which case MilkdropMetalRenderer keeps using its existing per-pixel-exact fixed-formula
    // warp path rather than downgrading to a coarse mesh for no reason.
    private var perPixelMesh: MilkdropPerPixelMeshRuntime?

    // Custom waveforms (`wavecode_N_*`) loaded alongside the built-in waveform above — see
    // MilkdropCustomWaveform.swift. Always 4 slots, same disabled-by-default pattern as `shapes`.
    private var customWaves: [MilkdropCustomWaveformRuntime] = []

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

            // Fresh instance every load (not a reset of the existing one) so a prior preset's
            // slots/accumulated state never leaks into the next — matches the old dictionary
            // literal's full-replacement semantics exactly.
            presetVariables = MilkdropVariableSlots()
            presetVariables.load([
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
                "ob_size": file.outerBorderSize, "ob_r": file.outerBorderR, "ob_g": file.outerBorderG,
                "ob_b": file.outerBorderB, "ob_a": file.outerBorderA,
                "ib_size": file.innerBorderSize, "ib_r": file.innerBorderR, "ib_g": file.innerBorderG,
                "ib_b": file.innerBorderB, "ib_a": file.innerBorderA,
                "darken_center": file.darkenCenter ? 1 : 0,
                "gamma": file.gammaAdj, "echo_zoom": file.videoEchoZoom, "echo_alpha": file.videoEchoAlpha,
                "echo_orient": Float(file.videoEchoOrientation),
                "brighten": file.brighten ? 1 : 0, "darken": file.darken ? 1 : 0,
                "solarize": file.solarize ? 1 : 0, "invert": file.invert ? 1 : 0,
            ])
            // Runs once, immediately — seeds any custom variables (e.g. `SPEED=10;`) the per-frame
            // program below expects to already exist on its first evaluation. Uses the string-keyed
            // path (not resolved): this program never runs again after this line.
            MilkdropExpressionProgram(source: file.perFrameInitProgram)?.evaluate(presetVariables)
            // Resolved once here (not re-hashed every frame) — see
            // MilkdropExpressionEvaluator.swift's perf note. Runs once/frame (not in a per-vertex/
            // per-point/per-instance loop the way the mesh/waveform/shape programs do), so this is
            // a smaller win in isolation, but keeps this file's evaluation path consistent with the
            // rest of the codebase after this change rather than being the one holdout still on the
            // string-keyed path.
            perFrameProgram = MilkdropExpressionProgram(source: file.perFrameProgram)?.resolved(against: presetVariables)
            shapes = file.shapes.map(MilkdropShapeRuntime.init(preset:))
            perPixelMesh = MilkdropPerPixelMeshRuntime(source: file.perPixelProgram)
            customWaves = file.customWaves.map(MilkdropCustomWaveformRuntime.init(preset:))
            warpAnimSpeed = file.warpAnimSpeed
            warpScale = file.warpScale
            compositeShaderSource = file.compositeShaderSource
            warpShaderSource = file.warpShaderSource
            usesOldStyleFinalComposite = file.usesOldStyleFinalComposite
            hueRandomOffsets = SIMD4<Float>(.random(in: 0...648.41), .random(in: 0...537.51), .random(in: 0...426.61), .random(in: 0...315.71))
            loadGeneration += 1
            presetName = url.deletingPathExtension().lastPathComponent
            presetURL = url
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

            perFrameProgram.evaluate(presetVariables)
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

        if let obSize = presetVariables["ob_size"] { borderParams.outerSize = obSize }
        if let obR = presetVariables["ob_r"] { borderParams.outerR = obR }
        if let obG = presetVariables["ob_g"] { borderParams.outerG = obG }
        if let obB = presetVariables["ob_b"] { borderParams.outerB = obB }
        if let obA = presetVariables["ob_a"] { borderParams.outerA = obA }
        if let ibSize = presetVariables["ib_size"] { borderParams.innerSize = ibSize }
        if let ibR = presetVariables["ib_r"] { borderParams.innerR = ibR }
        if let ibG = presetVariables["ib_g"] { borderParams.innerG = ibG }
        if let ibB = presetVariables["ib_b"] { borderParams.innerB = ibB }
        if let ibA = presetVariables["ib_a"] { borderParams.innerA = ibA }
        if let darkenCenter = presetVariables["darken_center"] { borderParams.darkenCenter = darkenCenter }

        if let gamma = presetVariables["gamma"] { oldStyleCompositeParams.gammaAdj = gamma }
        if let echoZoom = presetVariables["echo_zoom"] { oldStyleCompositeParams.videoEchoZoom = echoZoom }
        if let echoAlpha = presetVariables["echo_alpha"] { oldStyleCompositeParams.videoEchoAlpha = echoAlpha }
        if let echoOrient = presetVariables["echo_orient"] { oldStyleCompositeParams.videoEchoOrientation = echoOrient }
        if let brighten = presetVariables["brighten"] { oldStyleCompositeParams.brighten = brighten }
        if let darken = presetVariables["darken"] { oldStyleCompositeParams.darken = darken }
        if let solarize = presetVariables["solarize"] { oldStyleCompositeParams.solarize = solarize }
        if let invert = presetVariables["invert"] { oldStyleCompositeParams.invert = invert }
    }

    /// Resolves every loaded shape's per-frame script for this frame, one instance array per shape
    /// slot (disabled/instance-less shapes contribute an empty array). Called from
    /// MilkdropMetalRenderer.draw(in:) alongside updatePresetPerFrame, with the same per-frame
    /// timing/audio inputs.
    func updateShapesPerFrame(time: Double, fps: Double, frame: Int, energy: MilkdropBandEnergy) -> [[MilkdropShapeInstance]] {
        shapes.map { $0.resolveInstances(time: Float(time), fps: Float(fps), frame: Float(frame), energy: energy) }
    }

    /// The per-frame script's `q1`-`q32` values (e.g. a script that does `q1=bass;`), read back for
    /// anything downstream that needs them — composite-shader uniforms and the per-pixel mesh below.
    /// These are plain named variables in `presetVariables` like any other (see
    /// MilkdropExpressionEvaluator.swift's header on NS-EEL's "undeclared = 0" semantics), not a
    /// distinct storage mechanism, so a preset that never touches q-vars just reads back all zeros.
    var qVariables: [Float] {
        Self.qKeys.map { presetVariables[$0] ?? 0 }
    }

    /// Resolves this frame's warp mesh vertices, or `nil` if the loaded preset has no `per_pixel_N=`
    /// code (the common case — see `perPixelMesh`'s doc comment). `aspectX`/`aspectY` match
    /// MilkdropMetalRenderer's own aspect-ratio correction (see its `aspectXY`), so the mesh's
    /// static radius/angle geometry lines up with the fixed-formula path's.
    /// `qVars` is `qVariables`, resolved once per frame by the caller (MilkdropMetalRenderer.draw)
    /// and threaded through here rather than each of this/updateCustomWaveforms/
    /// buildDynamicShaderUniforms independently recomputing the same 32-entry array from
    /// `presetVariables` — that used to happen 2-4x/frame for an identical result.
    func updatePerPixelMesh(
        aspectX: Float, aspectY: Float, time: Double, fps: Double, frame: Int, energy: MilkdropBandEnergy,
        qVars: [Float]
    ) -> [MilkdropMeshVertexAttributes]? {
        perPixelMesh?.calculate(
            aspectX: aspectX, aspectY: aspectY,
            time: Float(time), fps: Float(fps), frame: Float(frame), energy: energy, qVars: qVars,
            zoom: warpParams.zoom, zoomExp: warpParams.zoomExponent, rot: warpParams.rot, warp: warpParams.warpAmount,
            cx: warpParams.rotCX, cy: warpParams.rotCY, dx: warpParams.xPush, dy: warpParams.yPush,
            sx: warpParams.stretchX, sy: warpParams.stretchY
        )
    }

    /// Resolves every loaded custom waveform's points for this frame, one array per slot (disabled
    /// slots contribute an empty array — see MilkdropCustomWaveform.swift). `pcmLeft`/`pcmRight`
    /// and `spectrumLeft`/`spectrumRight` are raw audio sample data, not yet scaled/smoothed by
    /// anything (each custom waveform does its own scaling/smoothing, separate from the built-in
    /// waveform's — see MilkdropCustomWaveformRuntime.resolvePoints). `qVars` — see
    /// updatePerPixelMesh's doc comment above.
    func updateCustomWaveforms(
        pcmLeft: [Float], pcmRight: [Float], spectrumLeft: [Float], spectrumRight: [Float],
        time: Double, fps: Double, frame: Int, energy: MilkdropBandEnergy, qVars: [Float]
    ) -> [MilkdropCustomWaveformDrawData] {
        return customWaves.map { wave in
            let (left, right) = wave.preset.spectrum ? (spectrumLeft, spectrumRight) : (pcmLeft, pcmRight)
            let points = wave.resolvePoints(
                left: left, right: right, waveScale: params.scale,
                time: Float(time), fps: Float(fps), frame: Float(frame), energy: energy, qVars: qVars
            )
            return MilkdropCustomWaveformDrawData(
                points: points, additive: wave.preset.additive,
                useDots: wave.preset.useDots, drawThick: wave.preset.drawThick
            )
        }
    }
}

/// A resolved custom waveform's points plus the rendering flags MilkdropMetalRenderer needs to
/// pick the right pipeline/geometry — `MilkdropCustomWaveformRuntime` itself only knows about
/// per-frame/per-point evaluation, not how Metal ends up drawing the result.
struct MilkdropCustomWaveformDrawData {
    var points: [MilkdropCustomWaveformPoint]
    var additive: Bool
    var useDots: Bool
    var drawThick: Bool
}

struct MilkdropVisualizerView: View {
    let audioEngine: CoreAudioTapEngine
    var color: Color
    /// 0...1 bass energy, used to thicken the line the way MilkDrop's mod-alpha-by-volume does.
    var bassEnergy: CGFloat = 0
    var model: MilkdropVisualizerModel
    /// Called on tap — owned by the caller (ContentView), which also drives the same action from
    /// the spacebar shortcut. Used to cycle to a random preset from the loaded library; see
    /// MilkdropPresetLibrary.swift.
    var onTap: () -> Void

    var body: some View {
        MilkdropMetalView(audioEngine: audioEngine, color: color, bassEnergy: bassEnergy, model: model)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}
