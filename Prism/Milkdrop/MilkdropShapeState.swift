//
//  MilkdropShapeState.swift
//  Prism
//
//  Runtime state for Milkdrop's "custom shapes" (`shapecode_N_*` in the .milk format) — up to 4
//  independently-scripted polygon/circle overlays per preset, distinct from the built-in
//  oscilloscope waveform (see MilkdropWaveMode.swift). Ported from projectM's CustomShape.cpp /
//  ShapePerFrameContext.cpp as a spec, not copied — see MilkdropPresetFile.swift's header for why.
//
//  Untextured shapes only for now: `textured=true` swaps in a second shader and a UV pass in real
//  Milkdrop, which Prism has no texture-sampling path for yet (see CustomShape.cpp:145-201 for
//  that split — it's cleanly separable from the untextured gradient-fill path ported here).
//

import Foundation

/// One shape instance's fully-resolved draw parameters for the current frame — what
/// MilkdropMetalRenderer actually turns into geometry. Colors are clamped to 0...1 here (real
/// Milkdrop instead wraps out-of-range values via a modulo, letting `r=r+0.01;`-style scripts
/// intentionally cycle color — an accepted simplification for this port).
struct MilkdropShapeInstance {
    var sides: Int
    var x: Float
    var y: Float
    var rad: Float
    var ang: Float
    var r: Float
    var g: Float
    var b: Float
    var a: Float
    var r2: Float
    var g2: Float
    var b2: Float
    var a2: Float
    var borderR: Float
    var borderG: Float
    var borderB: Float
    var borderA: Float
    var additive: Bool
    var thickOutline: Bool
}

/// Load-time state for one `shapecode_N` slot: the parsed preset constants, compiled expression
/// programs, and the single persistent variable environment `resolveInstances` reuses across every
/// instance and every frame.
final class MilkdropShapeRuntime {
    let preset: MilkdropShapePreset
    private let perFrameProgram: MilkdropExpressionProgram?

    /// One environment per shape (not per instance) — matching projectM's ShapePerFrameContext,
    /// which is a single reused context stepped through the instance loop each frame. A script
    /// that only sets `x`/`y`/etc. from `instance` still differentiates instances correctly; a
    /// script that mutates a persistent custom variable (or `t1`-`t8`) sees that mutation carry
    /// over between instances and frames, same as upstream.
    private var variables: [String: Float]

    init(preset: MilkdropShapePreset) {
        self.preset = preset
        variables = [
            "sides": Float(preset.sides),
            "x": preset.x, "y": preset.y, "rad": preset.rad, "ang": preset.ang,
            "r": preset.r, "g": preset.g, "b": preset.b, "a": preset.a,
            "r2": preset.r2, "g2": preset.g2, "b2": preset.b2, "a2": preset.a2,
            "border_r": preset.borderR, "border_g": preset.borderG,
            "border_b": preset.borderB, "border_a": preset.borderA,
            "additive": preset.additive ? 1 : 0,
            "thick": preset.thickOutline ? 1 : 0,
            "num_inst": Float(preset.numInst),
        ]
        // Runs once, immediately — same role as the main preset's perFrameInitProgram (see
        // MilkdropVisualizerView.swift's loadPreset).
        MilkdropExpressionProgram(source: preset.initProgram)?.evaluate(&variables)
        perFrameProgram = MilkdropExpressionProgram(source: preset.perFrameProgram)
    }

    /// Re-evaluates the per-frame script once per instance (`0..<numInst`), folding this frame's
    /// timing/audio globals in first. Returns an empty array if the shape is disabled or has zero
    /// instances, so callers can iterate the result directly with no `enabled` check of their own.
    func resolveInstances(time: Float, fps: Float, frame: Float, energy: MilkdropBandEnergy) -> [MilkdropShapeInstance] {
        guard preset.enabled else { return [] }
        let numInst = max(1, preset.numInst)

        var results: [MilkdropShapeInstance] = []
        results.reserveCapacity(numInst)

        for instance in 0..<numInst {
            variables["time"] = time
            variables["fps"] = fps
            variables["frame"] = frame
            variables["bass"] = energy.bass
            variables["mid"] = energy.mid
            variables["treb"] = energy.treb
            variables["bass_att"] = energy.bassAtt
            variables["mid_att"] = energy.midAtt
            variables["treb_att"] = energy.trebAtt
            variables["instance"] = Float(instance)
            variables["num_inst"] = Float(numInst)

            perFrameProgram?.evaluate(&variables)

            func clamped01(_ key: String, _ fallback: Float) -> Float {
                min(1, max(0, variables[key] ?? fallback))
            }

            results.append(MilkdropShapeInstance(
                sides: min(100, max(3, Int(variables["sides"] ?? Float(preset.sides)))),
                x: variables["x"] ?? preset.x,
                y: variables["y"] ?? preset.y,
                rad: variables["rad"] ?? preset.rad,
                ang: variables["ang"] ?? preset.ang,
                r: clamped01("r", preset.r), g: clamped01("g", preset.g),
                b: clamped01("b", preset.b), a: clamped01("a", preset.a),
                r2: clamped01("r2", preset.r2), g2: clamped01("g2", preset.g2),
                b2: clamped01("b2", preset.b2), a2: clamped01("a2", preset.a2),
                borderR: clamped01("border_r", preset.borderR), borderG: clamped01("border_g", preset.borderG),
                borderB: clamped01("border_b", preset.borderB), borderA: clamped01("border_a", preset.borderA),
                additive: (variables["additive"] ?? (preset.additive ? 1 : 0)) != 0,
                thickOutline: (variables["thick"] ?? (preset.thickOutline ? 1 : 0)) != 0
            ))
        }
        return results
    }
}
