//
//  ProjectMCompositeShader.metal
//  Prism
//
//  Real projectM (via ANGLE) already did every actual wave rendering pass - warp/feedback,
//  shapes, waveforms, comp shader - inside the IOSurface-backed FBO ProjectMEngine renders into.
//  This draws that finished texture into the MTKView's drawable, and - since the album art
//  overlay moved here from a separate SwiftUI layer - composites album art on top of it in the
//  same pass through a choreographed four-stage sequence (see ProjectMCoordinator's
//  advanceAlbumArtAnimation, which drives `stage`/`stageProgress` below):
//
//    0 scaleIn        - the new track's full cover (background and subject together) grows from
//                       nothing to its full size, centered on the art square's own center - no
//                       separate opacity fade, the zero-to-full scale itself reads as it
//                       materializing.
//    1 separate        - the subject's own scale locks at full size right where scaleIn left it,
//                       while the *background* - the raw cover with a subject-shaped hole already
//                       punched out of it, see ProjectMCoordinator.backgroundWithSubjectHole, so
//                       it never carries a copy of the subject's own pixels underneath it - keeps
//                       growing past full size and fades away in per-pixel noise order. Background
//                       and subject visibly pull apart, leaving the subject anchored in place as
//                       the background dissolves outward.
//    2 steady         - subject (or, with no detected subject, the whole cover) just sits there.
//    3 outgoingExit    - on a track change, whatever's on screen gets swept away by the wave
//                       itself: each pixel is walked backward, step by step, through the wave's
//                       own local gradient field (see sample_wave_gradient below), so both the
//                       direction it goes and how fast are entirely dictated by whatever the wave
//                       is actually doing underneath it - no independent noise or timer-driven
//                       dissolve standing in for that.
//
//  Independent of all four stages, every art sample is nudged by the wave texture's own local
//  luminance gradient - a cheap refraction/heat-haze trick where a hard edge or bright streak in
//  the wave visibly pushes the art around, so it reads as embedded in the wave rather than merely
//  stacked on top of it.
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

// Central-difference luminance gradient of the wave around `texCoord` - the "which way is the wave
// getting brighter here" vector. Factored out since the dismissal stage below re-samples this at
// several positions per pixel, marching through the field rather than reading it once.
inline float2 sample_wave_gradient(texture2d<float> waveTexture, sampler s, float2 texCoord, float2 texelSize, float3 luma)
{
    float lumL = dot(waveTexture.sample(s, texCoord - float2(texelSize.x, 0)).rgb, luma);
    float lumR = dot(waveTexture.sample(s, texCoord + float2(texelSize.x, 0)).rgb, luma);
    float lumU = dot(waveTexture.sample(s, texCoord - float2(0, texelSize.y)).rgb, luma);
    float lumD = dot(waveTexture.sample(s, texCoord + float2(0, texelSize.y)).rgb, luma);
    return float2(lumR - lumL, lumD - lumU);
}

// Mirrors ProjectMCoordinator's Swift-side AlbumArtUniforms struct field-for-field - keep the two
// in sync if either changes.
struct AlbumArtUniforms {
    float2 waveTexelSize;    // 1/width, 1/height of waveTexture, for neighbor sampling
    float2 artCenter;        // art square's center, in the same [0,1] space as texCoord
    float2 artHalfSize;      // art square's half-width/half-height, same space
    float stage;             // 0 scaleIn, 1 separate, 2 steady, 3 outgoingExit (see header above)
    float stageProgress;     // 0...1 progress through the current stage
    float hasSubjectMask;    // 0 or 1 - whether Vision found a subject on the *current* track
    float globalAlpha;       // "H" hidden-toggle / no-track-loaded mute, eased 0...1
    float distortionStrength;
    // Precomputed on the Swift side (not derived from stage/stageProgress here) so growth is one
    // continuous, constant-velocity ramp straight through the scaleIn -> separate boundary, with
    // no perceptible change in speed there - see ProjectMCoordinator.albumArtScales. subjectScale
    // locks at 1 the moment it gets there; backgroundScale just keeps going at that exact same rate.
    float subjectScale;
    float backgroundScale;
};

fragment float4 projectm_composite_fragment(ProjectMPassthroughVaryings in [[stage_in]],
                                             texture2d<float> waveTexture [[texture(0)]],
                                             texture2d<float> backgroundArtTexture [[texture(1)]],
                                             texture2d<float> subjectArtTexture [[texture(2)]],
                                             constant AlbumArtUniforms &u [[buffer(0)]])
{
    constexpr sampler waveSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    constexpr sampler artSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float4 wave = waveTexture.sample(waveSampler, in.texCoord);

    int stage = int(u.stage + 0.5);
    // Dismissal's torn-away content and separate's still-growing background both need to visibly
    // leave the art's own square - every other stage stays clipped tight to the square as before.
    float bound = (stage == 1 || stage == 3) ? 1.0 : 0.0;
    float2 artUV = (in.texCoord - u.artCenter) / (u.artHalfSize * 2.0) + 0.5;
    if (artUV.x < -bound || artUV.x > 1.0 + bound || artUV.y < -bound || artUV.y > 1.0 + bound
        || u.globalAlpha <= 0.0) {
        return wave;
    }

    float3 luma = float3(0.299, 0.587, 0.114);
    float2 waveGradient = sample_wave_gradient(waveTexture, waveSampler, in.texCoord, u.waveTexelSize, luma);

    // Cheap per-pixel hash, used as the background layer's own erosion order during separate: a
    // pixel "goes" once stageProgress passes its own noise value, smoothed by `band` so the
    // dissolving edge reads as ragged/organic rather than a hard cutoff.
    float noise = fract(sin(dot(artUV * 41.13, float2(12.9898, 78.233))) * 43758.5453);
    float band = 0.16;

    float4 art;
    float alpha;

    if (stage == 3) {
        // Dismissal: walk backward from this screen position through the wave's own gradient
        // field, a few short steps at a time, re-sampling the gradient at each intermediate
        // position rather than reading it once - so the path curves through whatever the wave is
        // doing along the way instead of a single straight-line push. Wherever that walk ends up
        // (`sourceUV`) is treated as the source pixel that would have arrived here, which is what
        // lets torn pieces land outside the original square instead of just vanishing at its edge.
        // A pixel over a flat, low-contrast stretch of wave barely gets pulled by that field, so a
        // small baseline step (independent of the field) guarantees everything still fully clears
        // by stageProgress 1 rather than leaving a static residue behind in the calm spots.
        const int STEPS = 6;
        float ease = u.stageProgress * u.stageProgress;
        float baseStep = ease * 1.1 / float(STEPS);
        float2 pos = artUV;
        for (int i = 0; i < STEPS; i++) {
            float2 screenPos = u.artCenter + (pos - 0.5) * (u.artHalfSize * 2.0);
            float2 g = sample_wave_gradient(waveTexture, waveSampler, screenPos, u.waveTexelSize, luma);
            float gLen = length(g);
            float2 dir = gLen > 0.0001 ? (g / gLen) : float2(0.0, 1.0);
            // Busier/higher-contrast wave regions tear through faster than calm ones.
            float fieldStep = ease * gLen * 14.0 / float(STEPS);
            pos -= dir * (baseStep + fieldStep);
        }
        float2 sourceUV = pos;

        // How far sourceUV falls outside the art's own true [0,1] square, per axis, then a soft
        // ~5-7% feather at that boundary rather than a hard per-pixel cutoff - this is what makes
        // a pixel disappear (or appear, out in the expanded margin) *because of* the distortion,
        // not an independent dissolve mask running alongside it.
        float2 edgeDist = min(sourceUV, 1.0 - sourceUV);
        float edgeAlpha = smoothstep(-0.05, 0.02, min(edgeDist.x, edgeDist.y));

        art = subjectArtTexture.sample(artSampler, saturate(sourceUV));
        alpha = art.a * edgeAlpha;
    } else {
        // scaleIn/separate/steady all work the same way: the subject cutout and the hole-punched
        // background are two puzzle-piece layers - together, at the same scale, they reconstitute
        // the original cover exactly - each sampled through its own scale (inverse-mapped, same
        // trick as the dismissal stage's forward warp: dividing by a scale under 1 spreads source
        // content out from the center, so at scale ~0 almost every screen position maps outside
        // the source's own [0,1] square and comes back transparent, which is exactly "shrunk to
        // nothing"), then composited subject-over-background-over-wave. subjectScale/backgroundScale
        // arrive already computed (see AlbumArtUniforms above) as one continuous, constant-velocity
        // ramp from ProjectMCoordinator - clamped away from exactly 0 here only to keep the division
        // below finite; the ramp itself never lingers there.
        float subjectScale = max(u.subjectScale, 0.02);
        float bgScale = max(u.backgroundScale, 0.02);

        float2 subjectUV = 0.5 + (artUV - 0.5) / subjectScale;
        float2 bgUV = 0.5 + (artUV - 0.5) / bgScale;
        float2 distortedSubjectUV = subjectUV + waveGradient * u.distortionStrength;
        float2 distortedBgUV = bgUV + waveGradient * u.distortionStrength;

        // Whether the *true* (pre-clamp) UV actually lands on the source image. clamp_to_edge
        // means sampling with an out-of-range UV doesn't come back transparent - it repeats the
        // nearest edge pixel outward, which is what was reading as stretched "lines" filling the
        // rest of the frame while the art is still scaling in. Anything off the source image
        // should just be transparent (shows the wave underneath) instead of edge-smeared.
        bool subjectInBounds = all(distortedSubjectUV >= 0.0) && all(distortedSubjectUV <= 1.0);
        bool bgInBounds = all(distortedBgUV >= 0.0) && all(distortedBgUV <= 1.0);

        float4 subjectSample = subjectArtTexture.sample(artSampler, saturate(distortedSubjectUV));
        float4 bgSample = backgroundArtTexture.sample(artSampler, saturate(distortedBgUV));

        float subjectA = (u.hasSubjectMask > 0.5 && subjectInBounds) ? subjectSample.a : 0.0;
        float bgA = bgInBounds ? bgSample.a : 0.0;

        // During scaleIn subjectUV == bgUV (both layers share the same growing scale), so the two
        // puzzle pieces just reconstitute the whole cover at whatever size it's currently grown
        // to - no separate handling needed here, only separate/steady change how bgA behaves.
        if (stage == 1 && u.hasSubjectMask > 0.5) {
            bgA *= 1.0 - smoothstep(noise - band, noise + band, u.stageProgress);
        } else if (stage >= 2 && u.hasSubjectMask > 0.5) {
            // Fully separated by now - only the subject remains through steady state.
            bgA = 0.0;
        }

        // Standard non-premultiplied "subject over background" - correct regardless of how
        // transparent either layer currently is.
        float3 overColor = mix(bgSample.rgb, subjectSample.rgb, subjectA);
        alpha = subjectA + bgA * (1.0 - subjectA);
        art = float4(overColor, 1.0);
    }

    alpha *= saturate(u.globalAlpha);
    return float4(mix(wave.rgb, art.rgb, saturate(alpha)), 1.0);
}
