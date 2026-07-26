//
//  MilkdropPerPixelMesh.swift
//  Prism
//
//  Runtime for Milkdrop's "per-pixel" warp mesh (`per_pixel_N=` in the .milk format) — the
//  scripted counterpart to the fixed per-frame zoom/rot/warp transform MilkdropMetalRenderer's
//  `feedback_fragment` already applies per screen pixel (see Shaders.metal's header for why that
//  existing path is already *more* precise than upstream's own default, for presets that don't use
//  per_pixel_N at all). A preset with per-pixel code wants each mesh vertex's zoom/rot/warp/etc to
//  differ across the screen (driven by that vertex's own x/y/rad/ang) — something only a real
//  coarse grid, GPU-interpolated between vertices, can express, since Prism's NS-EEL evaluator is a
//  tree-walking interpreter (too slow to run per actual screen pixel, same reason real Milkdrop's
//  compiled-bytecode evaluator still only runs this on a coarse grid, not per pixel, either). Ported
//  from projectM's PerPixelMesh.cpp/PerPixelContext.cpp; the actual warp math (zoom2/stretch/wiggle/
//  rotate/translate) lives in Shaders.metal's feedback_mesh_vertex, computed per mesh vertex and
//  bilinearly interpolated by the rasterizer — this file only produces that function's inputs.
//
//  Grid size (32x24, i.e. 33x25 vertices) matches projectM's ProjectM.hpp default (`m_meshX{32}`/
//  `m_meshY{24}`) — not a preset-configurable value in the stock Milkdrop format, just an app-level
//  quality knob upstream exposes and Prism hardcodes to the same default.
//

import Foundation
import simd

/// One mesh vertex's fully-resolved attributes, handed to Shaders.metal's `feedback_mesh_vertex` —
/// field order matters (must exactly match the Metal-side `MeshVertex` struct byte-for-byte, since
/// the renderer uploads this array as raw bytes). `transforms` (a SIMD4, 16-byte aligned) comes
/// first specifically so no interior padding gets inserted before the SIMD2 fields that follow —
/// see MilkdropMetalRenderer.swift's ShapeVertex for the same convention with a simpler layout.
struct MilkdropMeshVertexAttributes {
    var transforms: SIMD4<Float>  // zoom, zoomExp, rot, warp
    var position: SIMD2<Float>    // static NDC (-1...1) grid position
    var radiusAngle: SIMD2<Float> // static; radius/angle derived from `position` and the aspect ratio
    var center: SIMD2<Float>      // cx, cy
    var distance: SIMD2<Float>    // dx, dy
    var stretch: SIMD2<Float>     // sx, sy
}

final class MilkdropPerPixelMeshRuntime {
    static let gridSizeX = 32
    static let gridSizeY = 24

    /// Shared by every instance (and by MilkdropMetalRenderer, which builds the one static index
    /// buffer from it) — the grid's triangle connectivity never depends on anything preset-specific.
    static let sharedIndices: [UInt16] = {
        var idx: [UInt16] = []
        idx.reserveCapacity(gridSizeX * gridSizeY * 6)
        let stride = gridSizeX + 1
        for gy in 0..<gridSizeY {
            for gx in 0..<gridSizeX {
                let v0 = UInt16(gx + gy * stride)
                let v1 = UInt16(gx + 1 + gy * stride)
                let v2 = UInt16(gx + (gy + 1) * stride)
                let v3 = UInt16(gx + 1 + (gy + 1) * stride)
                // 0 - 1        Same two-triangle-per-cell split as projectM's PerPixelMesh.cpp
                //   \ |        (that file's own quadrant-mirrored index generation is just a
                //     2 - 3    historical draw-order artifact, not a connectivity difference —
                //              this is the same mesh, built in plain row-major order instead).
                idx.append(contentsOf: [v0, v1, v2, v1, v3, v2])
            }
        }
        return idx
    }()

    private let program: MilkdropResolvedProgram
    // One persistent environment reused across every vertex *and* every frame — matching
    // upstream's single shared PerPixelContext (its own comment: "Can't make this multithreaded as
    // per-pixel code may use gmegabuf or regXX vars"). Every built-in key (x/y/rad/ang/zoom/etc,
    // listed in `calculate` below) is overwritten before each vertex's evaluation, so a script that
    // only reads those still differentiates every vertex correctly; a script that mutates a custom
    // variable of its own sees that value accumulate across the whole mesh sweep, then again next
    // frame — same as real Milkdrop. Slot-indexed (not `[String: Float]`) since `program` runs once
    // per mesh vertex (825x/frame) — see MilkdropExpressionEvaluator.swift's perf note.
    private let variables: MilkdropVariableSlots

    // Slot indices for every built-in name seeded/read every vertex — resolved once below, not
    // re-hashed 825 times/frame.
    private let timeSlot: Int
    private let fpsSlot: Int
    private let frameSlot: Int
    private let bassSlot: Int
    private let midSlot: Int
    private let trebSlot: Int
    private let bassAttSlot: Int
    private let midAttSlot: Int
    private let trebAttSlot: Int
    private let meshxSlot: Int
    private let meshySlot: Int
    private let pixelsxSlot: Int
    private let pixelsySlot: Int
    private let aspectxSlot: Int
    private let aspectySlot: Int
    private let qSlots: [Int]
    private let xSlot: Int
    private let ySlot: Int
    private let radSlot: Int
    private let angSlot: Int
    private let zoomSlot: Int
    private let zoomExpSlot: Int
    private let rotSlot: Int
    private let warpSlot: Int
    private let cxSlot: Int
    private let cySlot: Int
    private let dxSlot: Int
    private let dySlot: Int
    private let sxSlot: Int
    private let sySlot: Int

    // Static per-vertex geometry (NDC position/radius/angle) — rebuilt only when the aspect ratio
    // changes (see MilkdropMetalRenderer's own aspectXY), not every frame like `variables` above.
    private var lastAspectX: Float = -1
    private var lastAspectY: Float = -1
    private var baseVertices: [(position: SIMD2<Float>, radius: Float, angle: Float)] = []

    /// `nil` if the preset has no usable `per_pixel_N=` code at all — callers should keep using the
    /// existing full-screen fragment-shader warp path in that case (see Shaders.metal's header).
    init?(source: String) {
        guard let parsed = MilkdropExpressionProgram(source: source) else { return nil }

        let variables = MilkdropVariableSlots()
        self.variables = variables
        timeSlot = variables.slot(for: "time")
        fpsSlot = variables.slot(for: "fps")
        frameSlot = variables.slot(for: "frame")
        bassSlot = variables.slot(for: "bass")
        midSlot = variables.slot(for: "mid")
        trebSlot = variables.slot(for: "treb")
        bassAttSlot = variables.slot(for: "bass_att")
        midAttSlot = variables.slot(for: "mid_att")
        trebAttSlot = variables.slot(for: "treb_att")
        meshxSlot = variables.slot(for: "meshx")
        meshySlot = variables.slot(for: "meshy")
        pixelsxSlot = variables.slot(for: "pixelsx")
        pixelsySlot = variables.slot(for: "pixelsy")
        aspectxSlot = variables.slot(for: "aspectx")
        aspectySlot = variables.slot(for: "aspecty")
        qSlots = (1...32).map { variables.slot(for: "q\($0)") }
        xSlot = variables.slot(for: "x")
        ySlot = variables.slot(for: "y")
        radSlot = variables.slot(for: "rad")
        angSlot = variables.slot(for: "ang")
        zoomSlot = variables.slot(for: "zoom")
        zoomExpSlot = variables.slot(for: "zoomexp")
        rotSlot = variables.slot(for: "rot")
        warpSlot = variables.slot(for: "warp")
        cxSlot = variables.slot(for: "cx")
        cySlot = variables.slot(for: "cy")
        dxSlot = variables.slot(for: "dx")
        dySlot = variables.slot(for: "dy")
        sxSlot = variables.slot(for: "sx")
        sySlot = variables.slot(for: "sy")

        program = parsed.resolved(against: variables)
    }

    /// Static per-vertex NDC position/radius/angle for the whole grid — shared by the scripted
    /// runtime below (cached, only recomputed when the aspect ratio changes) and `trivialVertices`
    /// (which needs the same geometry for presets with a `warp_N=` shader but no `per_pixel_N=`
    /// script — see that function's header for why a mesh is still needed there).
    static func gridPositions(aspectX: Float, aspectY: Float) -> [(position: SIMD2<Float>, radius: Float, angle: Float)] {
        let gx = gridSizeX, gy = gridSizeY
        var result: [(position: SIMD2<Float>, radius: Float, angle: Float)] = []
        result.reserveCapacity((gx + 1) * (gy + 1))
        for row in 0...gy {
            for col in 0...gx {
                let x = Float(col) / Float(gx) * 2 - 1
                let y = Float(row) / Float(gy) * 2 - 1
                // Milkdrop uses sqrtf on the sum of squares; hypotf is the same result, safer
                // against overflow — matches projectM's own comment in PerPixelMesh.cpp verbatim.
                let radius = hypotf(x * aspectX, y * aspectY)
                // atan2(0, 0) is well-defined (0) in both Swift and C, but real Milkdrop special-
                // cases the center vertex explicitly rather than rely on that, so this does too.
                let angle: Float = (col == gx / 2 && row == gy / 2) ? 0 : atan2f(y * aspectY, x * aspectX)
                result.append((SIMD2(x, y), radius, angle))
            }
        }
        return result
    }

    /// Builds a mesh with every vertex sharing the *same* zoom/rot/warp/etc (only the static
    /// radius/angle geometry varies per vertex) — for presets with a `warp_N=` shader but no
    /// `per_pixel_N=` script (measured 7/25: 32.5% of the corpus). A compiled `warp_N=` shader
    /// needs `uv`/`uv_orig`/`rad`/`ang` as *interpolated mesh varyings* (see
    /// MilkdropMetalRenderer.buildWarpShaderSource), which only a mesh draw call can provide — even
    /// though there's no per-vertex *script* to run, uniform values interpolated bilinearly across
    /// a 33x25 grid are visually indistinguishable from the true per-pixel formula for the smooth
    /// zoom/rotate/stretch transforms real presets use, so reusing the mesh path here (rather than
    /// building a second, fullscreen-quad-based warp-shader variant) is a deliberate simplification,
    /// not a quality compromise worth the added complexity.
    static func trivialVertices(
        aspectX: Float, aspectY: Float,
        zoom: Float, zoomExp: Float, rot: Float, warp: Float,
        cx: Float, cy: Float, dx: Float, dy: Float, sx: Float, sy: Float
    ) -> [MilkdropMeshVertexAttributes] {
        let transforms = SIMD4<Float>(zoom, zoomExp, rot, warp)
        let center = SIMD2<Float>(cx, cy)
        let distance = SIMD2<Float>(dx, dy)
        let stretch = SIMD2<Float>(sx, sy)
        return gridPositions(aspectX: aspectX, aspectY: aspectY).map { base in
            MilkdropMeshVertexAttributes(
                transforms: transforms, position: base.position,
                radiusAngle: SIMD2(base.radius, base.angle),
                center: center, distance: distance, stretch: stretch
            )
        }
    }

    private func rebuildBaseVertices(aspectX: Float, aspectY: Float) {
        lastAspectX = aspectX
        lastAspectY = aspectY
        baseVertices = Self.gridPositions(aspectX: aspectX, aspectY: aspectY)
    }

    /// Evaluates the per-pixel script at every mesh vertex for this frame, seeded with the current
    /// per-frame globals as each vertex's starting zoom/rot/etc — a script that only reads, never
    /// assigns, one of these sees the same value the non-scripted warp path would have used for
    /// every vertex.
    func calculate(
        aspectX: Float, aspectY: Float,
        time: Float, fps: Float, frame: Float, energy: MilkdropBandEnergy, qVars: [Float],
        zoom: Float, zoomExp: Float, rot: Float, warp: Float,
        cx: Float, cy: Float, dx: Float, dy: Float, sx: Float, sy: Float
    ) -> [MilkdropMeshVertexAttributes] {
        if aspectX != lastAspectX || aspectY != lastAspectY {
            rebuildBaseVertices(aspectX: aspectX, aspectY: aspectY)
        }

        variables.setValue(time, at: timeSlot)
        variables.setValue(fps, at: fpsSlot)
        variables.setValue(frame, at: frameSlot)
        variables.setValue(energy.bass, at: bassSlot)
        variables.setValue(energy.mid, at: midSlot)
        variables.setValue(energy.treb, at: trebSlot)
        variables.setValue(energy.bassAtt, at: bassAttSlot)
        variables.setValue(energy.midAtt, at: midAttSlot)
        variables.setValue(energy.trebAtt, at: trebAttSlot)
        variables.setValue(Float(Self.gridSizeX), at: meshxSlot)
        variables.setValue(Float(Self.gridSizeY), at: meshySlot)
        // Prism has no separate pixel-resolution plumbing reaching this runtime; aspect ratio is
        // the closest available proxy.
        variables.setValue(aspectX, at: pixelsxSlot)
        variables.setValue(aspectY, at: pixelsySlot)
        variables.setValue(aspectX, at: aspectxSlot)
        variables.setValue(aspectY, at: aspectySlot)
        for i in 0..<min(32, qVars.count) {
            variables.setValue(qVars[i], at: qSlots[i])
        }

        var out: [MilkdropMeshVertexAttributes] = []
        out.reserveCapacity(baseVertices.count)
        for base in baseVertices {
            variables.setValue(base.position.x * 0.5 * aspectX + 0.5, at: xSlot)
            variables.setValue(base.position.y * 0.5 * aspectY + 0.5, at: ySlot)
            variables.setValue(base.radius, at: radSlot)
            // Negated to match projectM's PerPixelMesh.cpp (`*perPixelContext.ang =
            // -curRadiusAngle.angle`) — not a typo to "fix"; scripts are written against this sign.
            variables.setValue(-base.angle, at: angSlot)
            variables.setValue(zoom, at: zoomSlot)
            variables.setValue(zoomExp, at: zoomExpSlot)
            variables.setValue(rot, at: rotSlot)
            variables.setValue(warp, at: warpSlot)
            variables.setValue(cx, at: cxSlot)
            variables.setValue(cy, at: cySlot)
            variables.setValue(dx, at: dxSlot)
            variables.setValue(dy, at: dySlot)
            variables.setValue(sx, at: sxSlot)
            variables.setValue(sy, at: sySlot)

            program.evaluate(variables)

            out.append(MilkdropMeshVertexAttributes(
                transforms: SIMD4(
                    variables.value(at: zoomSlot),
                    variables.value(at: zoomExpSlot),
                    variables.value(at: rotSlot),
                    variables.value(at: warpSlot)
                ),
                position: base.position,
                // Always the static grid-derived radius/angle, never the (possibly
                // script-overridden) evaluated `rad`/`ang` — matches upstream: the vertex shader's
                // zoom2 exponent always reads the static `m_radiusAngleBuffer`, not a per-pixel-code
                // override, even though the script's own `rad`/`ang` variables are read/write.
                radiusAngle: SIMD2(base.radius, base.angle),
                center: SIMD2(variables.value(at: cxSlot), variables.value(at: cySlot)),
                distance: SIMD2(variables.value(at: dxSlot), variables.value(at: dySlot)),
                stretch: SIMD2(variables.value(at: sxSlot), variables.value(at: sySlot))
            ))
        }
        return out
    }
}
