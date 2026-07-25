//
//  Shaders.metal
//  Prism
//
//  GPU replacement for the old CPU CGContext trail buffer (see MilkdropMetalRenderer.swift for
//  the full picture). Three shader pairs:
//   - feedback_vertex/feedback_fragment: samples last frame's texture with a zoom/rotate/decay
//     transform baked into the UV lookup — the GPU equivalent of the old ctx.rotate/scaleBy/
//     setAlpha dance, but as a single texture sample per pixel instead of a full CPU raster pass.
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

// Samples last frame's texture through the inverse of (rotate then scale, about the center),
// i.e. what the CPU version got from `ctx.rotate(rotation); ctx.scaleBy(zoom)` applied to the
// *drawn* image — sampling with the inverse is what makes the *destination* appear to zoom in /
// rotate forward each frame. Anything that lands outside the source texture (which zooming in
// naturally does, near the very edges) samples as transparent rather than clamping, so the trail
// fades to nothing at the border instead of smearing edge pixels inward forever.
fragment float4 feedback_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> previousTexture [[texture(0)]],
    constant float &cosRot [[buffer(0)]],
    constant float &sinRot [[buffer(1)]],
    constant float &invZoom [[buffer(2)]],
    constant float &decay [[buffer(3)]]
) {
    constexpr sampler s(address::clamp_to_zero, filter::linear);
    float2 centered = in.uv - float2(0.5, 0.5);
    float2 rotated = float2(
        cosRot * centered.x + sinRot * centered.y,
        -sinRot * centered.x + cosRot * centered.y
    );
    float2 sourceUV = rotated * invZoom + float2(0.5, 0.5);
    if (sourceUV.x < 0.0 || sourceUV.x > 1.0 || sourceUV.y < 0.0 || sourceUV.y > 1.0) {
        return float4(0.0);
    }
    return previousTexture.sample(s, sourceUV) * decay;
}

fragment float4 present_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, in.uv);
}
