//
//  Shaders.metal
//  Prism
//
//  GPU replacement for the old CPU CGContext trail buffer (see MilkdropMetalRenderer.swift for
//  the full picture). Three shader pairs:
//   - feedback_vertex/feedback_fragment: samples last frame's texture through Milkdrop's real
//     per-frame warp transform (zoom/rotate/stretch/translate/warp-wiggle, driven by a loaded
//     preset's zoom/rot/cx/cy/dx/dy/sx/sy/warp/decay per-frame variables — see
//     MilkdropVisualizerView.swift's warpParams and MilkdropMetalRenderer.swift for the uniforms).
//   - solid_vertex/solid_fragment: flat-colored, additively-blended geometry for the waveform
//     line and spectrum bars, built fresh each frame on the CPU (cheap — a few hundred vertices)
//     and rasterized on the GPU instead of stroked via Core Graphics.
//   - present_fragment (reuses feedback_vertex's full-screen quad): copies the composited texture
//     to the drawable.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Solid-color geometry (waveform line / spectrum bars)

struct SolidVertexOut {
    float4 position [[position]];
};

// Pixel-space input (center-origin, y-up — matches MilkdropWaveform's normalized math space
// scaled to pixels), converted straight to NDC since Metal's clip space is also center-origin,
// y-up: no flip needed here, unlike the feedback quad below.
vertex SolidVertexOut solid_vertex(
    const device float2 *positions [[buffer(0)]],
    constant float2 &viewportSize [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    float2 pixelPos = positions[vid];
    float2 ndc = pixelPos / (viewportSize * 0.5);
    SolidVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    return out;
}

fragment float4 solid_fragment(
    SolidVertexOut in [[stage_in]],
    constant float4 &color [[buffer(0)]]
) {
    return color;
}

// MARK: - Custom shapes (shapecode_N_* — see MilkdropShapeState.swift)

// Unlike solid_vertex's uniform fragment color, Milkdrop's shape fill is a genuine per-vertex
// gradient (center color -> rim color), so color travels with the vertex instead of as a constant.
struct ShapeVertex {
    float2 position; // Same pixel-space, center-origin, y-up convention as solid_vertex's input.
    float4 color;
};

struct ShapeVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex ShapeVertexOut shape_vertex(
    const device ShapeVertex *vertices [[buffer(0)]],
    constant float2 &viewportSize [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    ShapeVertex v = vertices[vid];
    float2 ndc = v.position / (viewportSize * 0.5);
    ShapeVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 shape_fragment(ShapeVertexOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Full-screen quad (shared by the feedback pass and the present pass)

// NDC (-1,-1) is the bottom-left of clip space, but texture UV (0,0) samples the top-left texel —
// pairing them directly would render everything upside down. This corner/UV pairing corrects for
// that (standard full-screen-triangle-strip convention), so both feedback sampling and the final
// present pass come out right-side up.
constant float2 kFullscreenCorners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
constant float2 kFullscreenUVs[4]     = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0)  };

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertexOut feedback_vertex(uint vid [[vertex_id]]) {
    FullscreenVertexOut out;
    out.position = float4(kFullscreenCorners[vid], 0.0, 1.0);
    out.uv = kFullscreenUVs[vid];
    return out;
}

// Milkdrop's real per-frame feedback transform (zoom/zoomExponent/stretch/warp-wiggle/rotate/
// translate), ported from projectM's PresetWarpVertexShaderGlsl330.vert — see
// MilkdropMetalRenderer.swift for where each uniform below is computed. That reference shader
// evaluates this per *mesh vertex* (a coarse 65x49 grid, bilinearly interpolated by the
// rasterizer); doing it here per screen pixel instead is strictly more precise, not an
// approximation of it, since Prism has no vertex mesh to begin with — it's always drawn a
// full-screen quad. Each uniform is its own buffer binding (rather than one packed struct) so
// there's no risk of the Swift-side and Metal-side struct layouts silently drifting apart —
// scalars and vector types each have unambiguous, independently-matching sizes this way.
//
// Anything that lands outside the source texture (which zooming/warping naturally does, near the
// edges) samples as transparent rather than clamping, so the trail fades to nothing at the border
// instead of smearing edge pixels inward forever — same edge behavior the old fixed transform had.
fragment float4 feedback_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> previousTexture [[texture(0)]],
    constant float &zoom [[buffer(0)]],
    constant float &zoomExponent [[buffer(1)]],
    constant float &rot [[buffer(2)]],
    constant float &warp [[buffer(3)]],
    constant float &cx [[buffer(4)]],
    constant float &cy [[buffer(5)]],
    constant float &dx [[buffer(6)]],
    constant float &dy [[buffer(7)]],
    constant float &sx [[buffer(8)]],
    constant float &sy [[buffer(9)]],
    constant float &decay [[buffer(10)]],
    constant float &warpTime [[buffer(11)]],
    constant float &warpScaleInverse [[buffer(12)]],
    constant float4 &warpFactors [[buffer(13)]],
    constant float2 &aspect [[buffer(14)]],
    constant float2 &invAspect [[buffer(15)]]
) {
    constexpr sampler s(address::clamp_to_zero, filter::linear);

    // -1...1, matching the reference shader's quad-corner vertex_position space (kFullscreenCorners
    // is already in that range; UV here is its 0...1 remap, so this just undoes that remap).
    float2 pos = (in.uv - float2(0.5, 0.5)) * 2.0;

    float zoom2 = pow(zoom, pow(zoomExponent, length(pos) * 2.0 - 1.0));
    float zoom2Inverse = 1.0 / zoom2;

    float u = pos.x * aspect.x * 0.5 * zoom2Inverse + 0.5;
    float v = pos.y * aspect.y * 0.5 * zoom2Inverse + 0.5;

    // Stretch on X, Y, about (cx, cy).
    u = (u - cx) / sx + cx;
    v = (v - cy) / sy + cy;

    // Warping: four sine/cosine ripples, amplitude scaled by the preset's `warp` value (0 = none).
    u += warp * 0.0035 * sin(warpTime * 0.333 + warpScaleInverse * (pos.x * warpFactors.x - pos.y * warpFactors.w));
    v += warp * 0.0035 * cos(warpTime * 0.375 - warpScaleInverse * (pos.x * warpFactors.z + pos.y * warpFactors.y));
    u += warp * 0.0035 * cos(warpTime * 0.753 - warpScaleInverse * (pos.x * warpFactors.y - pos.y * warpFactors.z));
    v += warp * 0.0035 * sin(warpTime * 0.825 + warpScaleInverse * (pos.x * warpFactors.x + pos.y * warpFactors.w));

    // Rotation about (cx, cy).
    float u2 = u - cx;
    float v2 = v - cy;
    float cosRot = cos(rot);
    float sinRot = sin(rot);
    u = u2 * cosRot - v2 * sinRot + cx;
    v = u2 * sinRot + v2 * cosRot + cy;

    // Translation.
    u -= dx;
    v -= dy;

    // Undo the aspect-ratio correction applied above, back to plain 0...1 texture space.
    u = (u - 0.5) * invAspect.x + 0.5;
    v = (v - 0.5) * invAspect.y + 0.5;

    if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) {
        return float4(0.0);
    }
    return previousTexture.sample(s, float2(u, v)) * decay;
}

fragment float4 present_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.uv);
}
