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

// Textured shapes (`textured=1` — CustomShape.cpp:145-201): same per-vertex color as above, but
// multiplied against a sampled texel instead of being the final color outright (matches
// TexturedDrawFragmentShaderGlsl330.frag upstream: `fragment_color * texture(sampler, uv)`).
struct ShapeTexturedVertex {
    float2 position;
    float4 color;
    float2 uv;
};

struct ShapeTexturedVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

vertex ShapeTexturedVertexOut shape_textured_vertex(
    const device ShapeTexturedVertex *vertices [[buffer(0)]],
    constant float2 &viewportSize [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    ShapeTexturedVertex v = vertices[vid];
    float2 ndc = v.position / (viewportSize * 0.5);
    ShapeTexturedVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = v.color;
    out.uv = v.uv;
    return out;
}

fragment float4 shape_textured_fragment(
    ShapeTexturedVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler texSampler [[sampler(0)]]
) {
    return in.color * tex.sample(texSampler, in.uv);
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

// MARK: - Old-style final composite (VideoEcho.cpp/Filters.cpp — no comp_N= shader at all)

// Real Milkdrop's "old-school" (Milkdrop 1.x-format, pre-shader) final-composite path — see
// MilkdropPresetFile.swift's `usesOldStyleFinalComposite` and MilkdropMetalRenderer.swift's
// `compileOldStyleCompositeShader` for how the two multi-pass, blend-equation-driven upstream
// classes (VideoEcho draws a base + optional zoomed "echo" copy, each further brightened by
// `redrawCount` additive redraws for `fGammaAdj`; Filters chains brighten/darken/solarize/invert as
// separate blend-trick passes atop that) collapse into one closed-form pass here: every one of
// those operations is pure per-pixel math with no neighbor sampling, so there's no need to actually
// replay Milkdrop's original multi-draw-call sequence to get the same final pixel value.
// VideoEcho.cpp's four screen-corner tint colors: three independent slowly-drifting sine waves per
// corner (frequency/phase/offset values copied verbatim from VideoEcho::Draw, not approximated),
// each corner's own 3 channels then normalized so its brightest channel hits exactly 1.0 (keeps the
// tint saturated instead of washing toward gray) before remapping into 0.5...1.0 (upstream's own
// `0.5 + 0.5*x` — never lets the tint go fully dark). Milkdrop computes this once per vertex and
// lets the rasterizer interpolate the result across the quad; doing the same 4-corner computation
// per-fragment instead (cheap — it's just trig) avoids needing a dedicated vertex format here.
static float3 videoEchoCornerTint(float cornerIndex, float time, float4 hueOffsets) {
    float3 s;
    s.r = 0.6 + 0.3 * sin(time * 30.0 * 0.0143 + 3.0 + cornerIndex * 21.0 + hueOffsets[3]);
    s.g = 0.6 + 0.3 * sin(time * 30.0 * 0.0107 + 1.0 + cornerIndex * 13.0 + hueOffsets[1]);
    s.b = 0.6 + 0.3 * sin(time * 30.0 * 0.0129 + 6.0 + cornerIndex * 9.0 + hueOffsets[2]);
    float m = max(s.r, max(s.g, s.b));
    s = s / m;
    return 0.5 + 0.5 * s;
}

// One buffer index per uniform (rather than a single packed struct) — matches feedback_fragment's
// own convention elsewhere in this file, and sidesteps having to hand-verify Swift/Metal struct
// layout agreement (float4's 16-byte alignment would otherwise insert padding after a leading
// plain float that's easy to get wrong on the Swift side).
fragment float4 milkdrop_old_style_final_composite(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> sourceTex [[texture(0)]],
    constant float &time [[buffer(0)]],
    constant float4 &hueOffsets [[buffer(1)]],
    constant float &echoZoom [[buffer(2)]],
    constant float &echoAlpha [[buffer(3)]],
    constant float2 &flipUV [[buffer(4)]],
    constant float &gammaAdj [[buffer(5)]],
    constant float4 &filterFlags [[buffer(6)]] // brighten, darken, solarize, invert
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // in.uv: (0,0) is the top-left texel (see kFullscreenUVs above), matching corner index
    // 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right below — an arbitrary but internally
    // consistent labeling (upstream's own index<->corner correspondence is likewise just whatever
    // its vertex array order happens to be, not something scripts can observe or rely on).
    float3 topLeft = videoEchoCornerTint(0.0, time, hueOffsets);
    float3 topRight = videoEchoCornerTint(1.0, time, hueOffsets);
    float3 bottomLeft = videoEchoCornerTint(2.0, time, hueOffsets);
    float3 bottomRight = videoEchoCornerTint(3.0, time, hueOffsets);
    float3 shade = mix(mix(topLeft, topRight, in.uv.x), mix(bottomLeft, bottomRight, in.uv.x), in.uv.y);

    float3 color;
    if (echoAlpha > 0.001) {
        float2 echoUV = float2(0.5) + (in.uv - float2(0.5)) / echoZoom;
        if (flipUV.x != 0.0) { echoUV.x = 1.0 - echoUV.x; }
        if (flipUV.y != 0.0) { echoUV.y = 1.0 - echoUV.y; }
        float3 base = sourceTex.sample(s, in.uv).rgb;
        float3 echo = sourceTex.sample(s, echoUV).rgb;
        // Milkdrop's own per-pass redraw-count algebra for VideoEcho::DrawVideoEcho reduces to a
        // flat max(1, gammaAdj) multiplier applied to the whole blended result (unlike the
        // no-echo branch below, where the equivalent reduction is exactly `gammaAdj`, not
        // clamped — DrawVideoEcho's redraw loop, unlike DrawGammaAdjustment's, has no "+1" and so
        // never actually draws for gammaAdj <= 1, leaving the single un-redrawn base weight of 1).
        color = shade * ((1.0 - echoAlpha) * base + echoAlpha * echo) * max(1.0, gammaAdj);
    } else {
        color = gammaAdj * shade * sourceTex.sample(s, in.uv).rgb;
    }

    // Filters.cpp's brighten/darken/solarize/invert, in this fixed order — each is a closed form of
    // a fixed-function blend-equation trick against a full-screen white quad (derived from the
    // actual (srcFactor,dstFactor) pairs in Filters.cpp): brighten = 1-(1-x)^2 = 2x-x^2 (3-pass
    // screen blend), darken = x^2 (multiply blend), solarize = 2x(1-x) (two-pass parabola), invert
    // = 1-x. Each operates on whatever the previous one produced, same as upstream's sequential
    // Draw() calls against the same framebuffer.
    if (filterFlags[0] != 0.0) { color = 2.0 * color - color * color; }
    if (filterFlags[1] != 0.0) { color = color * color; }
    if (filterFlags[2] != 0.0) { color = 2.0 * color - 2.0 * color * color; }
    if (filterFlags[3] != 0.0) { color = 1.0 - color; }

    return float4(saturate(color), 1.0);
}

// MARK: - Per-pixel warp mesh (per_pixel_N= — see MilkdropPerPixelMesh.swift)

// CPU-side mirror of MilkdropPerPixelMesh.swift's MilkdropMeshVertexAttributes — field order and
// types must match exactly (same reasoning as ShapeVertex above): `transforms` (a float4, 16-byte
// aligned) first so no interior padding gets inserted before the float2 fields that follow.
struct MeshVertex {
    float4 transforms;  // zoom, zoomExp, rot, warp
    float2 position;    // static NDC (-1...1) grid position
    float2 radiusAngle; // static radius, angle
    float2 center;      // cx, cy
    float2 distance;    // dx, dy
    float2 stretch;     // sx, sy
};

struct MeshVertexOut {
    float4 position [[position]];
    float2 uv;         // warped uv (this vertex's computed sample location)
    float2 uvOrig;     // plain screen uv, pre-warp — real Milkdrop's `uv_orig`
    float2 radiusAngle; // passed through from the static per-vertex buffer — real Milkdrop's `rad`/`ang`
};

// Per-vertex counterpart of feedback_fragment's warp math (see that function's header comment) —
// ported from projectM's PresetWarpVertexShaderGlsl330.vert line-for-line, just reading
// zoom/zoomExp/rot/warp/cx/cy/dx/dy/sx/sy from this vertex's own attributes instead of one uniform
// value shared by the whole screen. The GPU rasterizer bilinearly interpolates the resulting `uv`
// across each mesh triangle — that coarse-grid interpolation (not a per-pixel-exact evaluation) is
// the actual visual effect a scripted Milkdrop warp mesh is supposed to have.
vertex MeshVertexOut feedback_mesh_vertex(
    const device MeshVertex *vertices [[buffer(0)]],
    constant float &warpTime [[buffer(1)]],
    constant float &warpScaleInverse [[buffer(2)]],
    constant float4 &warpFactors [[buffer(3)]],
    constant float2 &aspect [[buffer(4)]],
    constant float2 &invAspect [[buffer(5)]],
    uint vid [[vertex_id]]
) {
    MeshVertex vert = vertices[vid];
    float2 pos = vert.position;
    float radius = vert.radiusAngle.x;
    float zoom = vert.transforms.x;
    float zoomExponent = vert.transforms.y;
    float rot = vert.transforms.z;
    float warp = vert.transforms.w;
    float cx = vert.center.x, cy = vert.center.y;
    float dx = vert.distance.x, dy = vert.distance.y;
    float sx = vert.stretch.x, sy = vert.stretch.y;

    float zoom2 = pow(zoom, pow(zoomExponent, radius * 2.0 - 1.0));
    float zoom2Inverse = 1.0 / zoom2;

    float u = pos.x * aspect.x * 0.5 * zoom2Inverse + 0.5;
    float v = pos.y * aspect.y * 0.5 * zoom2Inverse + 0.5;

    u = (u - cx) / sx + cx;
    v = (v - cy) / sy + cy;

    u += warp * 0.0035 * sin(warpTime * 0.333 + warpScaleInverse * (pos.x * warpFactors.x - pos.y * warpFactors.w));
    v += warp * 0.0035 * cos(warpTime * 0.375 - warpScaleInverse * (pos.x * warpFactors.z + pos.y * warpFactors.y));
    u += warp * 0.0035 * cos(warpTime * 0.753 - warpScaleInverse * (pos.x * warpFactors.y - pos.y * warpFactors.z));
    v += warp * 0.0035 * sin(warpTime * 0.825 + warpScaleInverse * (pos.x * warpFactors.x + pos.y * warpFactors.w));

    float u2 = u - cx;
    float v2 = v - cy;
    float cosRot = cos(rot);
    float sinRot = sin(rot);
    u = u2 * cosRot - v2 * sinRot + cx;
    v = u2 * sinRot + v2 * cosRot + cy;

    u -= dx;
    v -= dy;

    u = (u - 0.5) * invAspect.x + 0.5;
    v = (v - 0.5) * invAspect.y + 0.5;

    MeshVertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = float2(u, v);
    out.uvOrig = pos * 0.5 + 0.5;
    out.radiusAngle = vert.radiusAngle;
    return out;
}

// Same "outside 0...1 -> transparent" edge behavior as feedback_fragment, applied to the
// rasterizer-interpolated UV instead of a per-pixel-computed one.
fragment float4 feedback_mesh_fragment(
    MeshVertexOut in [[stage_in]],
    texture2d<float> previousTexture [[texture(0)]],
    constant float &decay [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_zero, filter::linear);
    if (in.uv.x < 0.0 || in.uv.x > 1.0 || in.uv.y < 0.0 || in.uv.y > 1.0) {
        return float4(0.0);
    }
    return previousTexture.sample(s, in.uv) * decay;
}
