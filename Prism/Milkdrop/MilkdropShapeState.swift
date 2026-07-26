//
//  MilkdropShapeState.swift
//  Prism
//
//  Runtime state for Milkdrop's "custom shapes" (`shapecode_N_*` in the .milk format) — up to 4
//  independently-scripted polygon/circle overlays per preset, distinct from the built-in
//  oscilloscope waveform (see MilkdropWaveMode.swift). Ported from projectM's CustomShape.cpp /
//  ShapePerFrameContext.cpp as a spec, not copied — see MilkdropPresetFile.swift's header for why.
//
//  Textured shapes (`textured=1`, CustomShape.cpp:145-201) sample a texture instead of the flat
//  gradient fill; per real Milkdrop's own behavior, the per-vertex color above still applies as a
//  multiplicative tint on top of the sampled texel. See MilkdropMetalRenderer.swift's
//  shapeTextured* pipelines for the actual sampling/UV math.
//

import Foundation

/// One shape instance's fully-resolved draw parameters for the current frame — what
/// MilkdropMetalRenderer actually turns into geometry. Color channels are always in 0...1, but
/// via wraparound (see `colorWrapped` below), matching real Milkdrop's behavior for scripts that
/// intentionally push a channel out of range (`r=r+0.01;`-style "flash"/color-cycling presets).
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
    var textured: Bool
    var texAng: Float
    var texZoom: Float
}

/// Load-time state for one `shapecode_N` slot: the parsed preset constants, compiled expression
/// programs, and the single persistent variable environment `resolveInstances` reuses across every
/// instance and every frame.
final class MilkdropShapeRuntime {
    let preset: MilkdropShapePreset
    /// Resolved once against `variables` right after both exist (see `init` below) — evaluation
    /// runs once per *instance* (`num_inst`, genuinely unbounded in real presets: measured 1024+
    /// as a common literal value against the real corpus — see TO DO.md's performance-pass notes),
    /// so avoiding a `[String: Float]` dictionary hash/lookup per read/write here matters.
    private let perFrameProgram: MilkdropResolvedProgram?

    /// One environment per shape (not per instance) — matching projectM's ShapePerFrameContext,
    /// which is a single reused context stepped through the instance loop each frame. A script
    /// that only sets `x`/`y`/etc. from `instance` still differentiates instances correctly; a
    /// script that mutates a persistent custom variable (or `t1`-`t8`) sees that mutation carry
    /// over between instances and frames, same as upstream.
    private let variables = MilkdropVariableSlots()

    // Slot indices for every built-in name this runtime seeds/reads every instance — resolved
    // once in `init`, not re-hashed on every one of `num_inst` iterations of the per-instance loop.
    private let sidesSlot: Int
    private let xSlot: Int
    private let ySlot: Int
    private let radSlot: Int
    private let angSlot: Int
    private let rSlot: Int
    private let gSlot: Int
    private let bSlot: Int
    private let aSlot: Int
    private let r2Slot: Int
    private let g2Slot: Int
    private let b2Slot: Int
    private let a2Slot: Int
    private let borderRSlot: Int
    private let borderGSlot: Int
    private let borderBSlot: Int
    private let borderASlot: Int
    private let additiveSlot: Int
    private let thickSlot: Int
    private let numInstSlot: Int
    private let texturedSlot: Int
    private let texAngSlot: Int
    private let texZoomSlot: Int
    private let timeSlot: Int
    private let fpsSlot: Int
    private let frameSlot: Int
    private let bassSlot: Int
    private let midSlot: Int
    private let trebSlot: Int
    private let bassAttSlot: Int
    private let midAttSlot: Int
    private let trebAttSlot: Int
    private let instanceSlot: Int

    init(preset: MilkdropShapePreset) {
        self.preset = preset

        sidesSlot = variables.slot(for: "sides")
        xSlot = variables.slot(for: "x")
        ySlot = variables.slot(for: "y")
        radSlot = variables.slot(for: "rad")
        angSlot = variables.slot(for: "ang")
        rSlot = variables.slot(for: "r")
        gSlot = variables.slot(for: "g")
        bSlot = variables.slot(for: "b")
        aSlot = variables.slot(for: "a")
        r2Slot = variables.slot(for: "r2")
        g2Slot = variables.slot(for: "g2")
        b2Slot = variables.slot(for: "b2")
        a2Slot = variables.slot(for: "a2")
        borderRSlot = variables.slot(for: "border_r")
        borderGSlot = variables.slot(for: "border_g")
        borderBSlot = variables.slot(for: "border_b")
        borderASlot = variables.slot(for: "border_a")
        additiveSlot = variables.slot(for: "additive")
        thickSlot = variables.slot(for: "thick")
        numInstSlot = variables.slot(for: "num_inst")
        texturedSlot = variables.slot(for: "textured")
        texAngSlot = variables.slot(for: "tex_ang")
        texZoomSlot = variables.slot(for: "tex_zoom")
        timeSlot = variables.slot(for: "time")
        fpsSlot = variables.slot(for: "fps")
        frameSlot = variables.slot(for: "frame")
        bassSlot = variables.slot(for: "bass")
        midSlot = variables.slot(for: "mid")
        trebSlot = variables.slot(for: "treb")
        bassAttSlot = variables.slot(for: "bass_att")
        midAttSlot = variables.slot(for: "mid_att")
        trebAttSlot = variables.slot(for: "treb_att")
        instanceSlot = variables.slot(for: "instance")

        variables.load([
            "sides": Float(preset.sides),
            "x": preset.x, "y": preset.y, "rad": preset.rad, "ang": preset.ang,
            "r": preset.r, "g": preset.g, "b": preset.b, "a": preset.a,
            "r2": preset.r2, "g2": preset.g2, "b2": preset.b2, "a2": preset.a2,
            "border_r": preset.borderR, "border_g": preset.borderG,
            "border_b": preset.borderB, "border_a": preset.borderA,
            "additive": preset.additive ? 1 : 0,
            "thick": preset.thickOutline ? 1 : 0,
            "num_inst": Float(preset.numInst),
            "textured": preset.textured ? 1 : 0,
            "tex_ang": preset.texAng,
            "tex_zoom": preset.texZoom,
        ])
        // Runs once, immediately — same role as the main preset's perFrameInitProgram (see
        // MilkdropVisualizerView.swift's loadPreset). Uses the string-keyed path (not resolved):
        // this program never runs again after this line, so resolving it isn't worth the ceremony.
        MilkdropExpressionProgram(source: preset.initProgram)?.evaluate(variables)
        perFrameProgram = MilkdropExpressionProgram(source: preset.perFrameProgram)?.resolved(against: variables)
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
            variables.setValue(time, at: timeSlot)
            variables.setValue(fps, at: fpsSlot)
            variables.setValue(frame, at: frameSlot)
            variables.setValue(energy.bass, at: bassSlot)
            variables.setValue(energy.mid, at: midSlot)
            variables.setValue(energy.treb, at: trebSlot)
            variables.setValue(energy.bassAtt, at: bassAttSlot)
            variables.setValue(energy.midAtt, at: midAttSlot)
            variables.setValue(energy.trebAtt, at: trebAttSlot)
            variables.setValue(Float(instance), at: instanceSlot)
            variables.setValue(Float(numInst), at: numInstSlot)

            perFrameProgram?.evaluate(variables)

            // Real Milkdrop wraps out-of-range color channels via `(int)(f*255) & 0xFF` back to
            // 0...1, not a clamp — a script that overshoots (deliberately, for a color-cycling
            // "flash" effect, or by accident) cycles through the color wheel instead of pinning at
            // white/black. Implemented in floating point (rather than mirroring the C++ integer
            // cast+bitmask directly) so a runaway per-frame accumulation can't trap on Int32
            // overflow; a non-finite result (e.g. from a malformed expression) falls back instead
            // of propagating NaN into the render.
            func colorWrapped(_ slot: Int, _ fallback: Float) -> Float {
                let value = variables.value(at: slot)
                guard value.isFinite else { return fallback }
                var wrapped = (value * 255).truncatingRemainder(dividingBy: 256)
                if wrapped < 0 { wrapped += 256 }
                return wrapped / 255
            }

            results.append(MilkdropShapeInstance(
                sides: min(100, max(3, Int(variables.value(at: sidesSlot)))),
                x: variables.value(at: xSlot),
                y: variables.value(at: ySlot),
                rad: variables.value(at: radSlot),
                ang: variables.value(at: angSlot),
                r: colorWrapped(rSlot, preset.r), g: colorWrapped(gSlot, preset.g),
                b: colorWrapped(bSlot, preset.b), a: colorWrapped(aSlot, preset.a),
                r2: colorWrapped(r2Slot, preset.r2), g2: colorWrapped(g2Slot, preset.g2),
                b2: colorWrapped(b2Slot, preset.b2), a2: colorWrapped(a2Slot, preset.a2),
                borderR: colorWrapped(borderRSlot, preset.borderR), borderG: colorWrapped(borderGSlot, preset.borderG),
                borderB: colorWrapped(borderBSlot, preset.borderB), borderA: colorWrapped(borderASlot, preset.borderA),
                additive: variables.value(at: additiveSlot) != 0,
                thickOutline: variables.value(at: thickSlot) != 0,
                textured: variables.value(at: texturedSlot) != 0,
                texAng: variables.value(at: texAngSlot),
                // A script-driven tex_zoom of exactly 0 (or non-finite) would divide-by-zero into
                // the UV math below — fall back to 1 (no zoom) rather than propagate Inf/NaN UVs.
                texZoom: {
                    let z = variables.value(at: texZoomSlot)
                    return z.isFinite && z != 0 ? z : 1
                }()
            ))
        }
        return results
    }
}
