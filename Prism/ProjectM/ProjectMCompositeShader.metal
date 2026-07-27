//
//  ProjectMCompositeShader.metal
//  Prism
//
//  Just a textured full-screen blit: real projectM (via ANGLE) already did every actual rendering
//  pass - warp/feedback, shapes, waveforms, comp shader - inside the IOSurface-backed FBO
//  ProjectMEngine renders into. This only needs to draw that finished texture into the MTKView's
//  drawable, unlike the old Shaders.metal which implemented the whole pipeline itself.
//

#include <metal_stdlib>
using namespace metal;

struct ProjectMPassthroughVaryings {
    float4 position [[position]];
    float2 texCoord;
};

// Standard vertex-id fullscreen-triangle trick (covers the viewport with one triangle, no vertex
// buffer needed). Texture v=0 maps to the top of the screen without a flip: empirically, the
// IOSurface ProjectMEngine renders into already has row 0 = top of image (verified visually via
// Vendor/angle-gles-probe.mm's PNG dumps, which needed no flip to look correct), matching Metal's
// own top-left texture-origin convention.
vertex ProjectMPassthroughVaryings projectm_passthrough_vertex(uint vertexID [[vertex_id]])
{
    float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    float2 texCoords[3] = {float2(0, 1), float2(2, 1), float2(0, -1)};

    ProjectMPassthroughVaryings out;
    out.position = float4(positions[vertexID], 0, 1);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 projectm_passthrough_fragment(ProjectMPassthroughVaryings in [[stage_in]],
                                              texture2d<float> projectMTexture [[texture(0)]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return projectMTexture.sample(s, in.texCoord);
}
