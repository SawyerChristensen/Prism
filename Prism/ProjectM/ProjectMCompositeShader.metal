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
//    0 scaleIn        - the new track's full cover (background and subject together) animates to
//                       its full size and position, centered on the art square's own center. Picked
//                       once per track (ProjectMCoordinator.introStyle), one of three:
//                         forward      - grows from nothing to full size; no separate opacity fade,
//                           the zero-to-full scale itself reads as it materializing.
//                         reverseScale - starts zoomed in (scale > 1), fully transparent, and *pre-
//                           dissolved* - scattered by the wave's own gradient field, the same walk
//                           outgoingExit tears a track's art apart with below, just run backward
//                           (`ease` shrinking instead of growing) - then shrinks to full size,
//                           fades in (`introAlpha`), and reassembles out of the scatter all in
//                           lockstep, so it reads as condensing and cohering into place at once
//                           rather than growing into it.
//                         slideIn      - scale pinned at 1 throughout (no zoom at all); starts
//                           off-screen to the right (subjectOffsetX/backgroundOffsetX, a screen-
//                           space X shift applied to each layer's own effective art center) and
//                           otherwise identical to reverseScale - fully transparent, pre-dissolved,
//                           fading in and reassembling in lockstep - but riding that horizontal
//                           slide down to 0 (dead center) instead of a shrinking scale.
//    1 separate        - the subject's own scale/position locks right where scaleIn left it, while
//                       the *background* - the raw cover with a subject-shaped hole already punched
//                       out of it, see ProjectMCoordinator.backgroundWithSubjectHole, so it never
//                       carries a copy of the subject's own pixels underneath it - keeps growing
//                       past full size (or, for slideIn, keeps sliding further left past center)
//                       and fades away in per-pixel noise order. Background and subject visibly
//                       pull apart, leaving the subject anchored in place as the background
//                       dissolves outward.
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

// Walks `startUV` backward, step by step, through the wave's own local gradient field, re-sampling
// the gradient at each intermediate position rather than reading it once - so the path curves
// through whatever the wave is doing along the way instead of a single straight-line push. Used
// both by outgoingExit (tearing a track's art apart, `ease` growing 0 -> 1 over the stage) and the
// reverse intro's own pre-dissolved start (`ease` shrinking 1 -> 0 instead, so the same scatter
// reassembles rather than spreads). A pixel over a flat, low-contrast stretch of wave barely gets
// pulled by the field alone, so a small baseline step (independent of the field) guarantees
// everything still fully scatters/reassembles by the extreme end of `ease` rather than leaving a
// static residue behind in the calm spots.
inline float2 wave_dissolve_walk(texture2d<float> waveTexture, sampler s, float2 startUV, float ease,
                                  float2 artCenter, float2 artHalfSize, float2 texelSize, float3 luma)
{
    const int STEPS = 6;
    float baseStep = ease * 1.1 / float(STEPS);
    // Per-pixel fallback direction for calm/flat wave regions, where the local gradient is too weak
    // to reliably steer the walk (see the dir select below) - a hash of the pixel's own starting UV,
    // not a single constant direction. A constant (this used to be a flat (0, 1)) biases every calm-
    // region pixel to scatter the exact same way, which reads as the whole image drifting in that
    // direction once `ease` stays high for long enough to matter (e.g. slideIn's slower-to-resolve
    // dissolve curve) - a per-pixel hash keeps calm regions scattering in varied directions instead,
    // while staying fully stable frame-to-frame (same pixel in, same angle out - no shimmer).
    float fallbackAngle = fract(sin(dot(startUV, float2(12.9898, 78.233))) * 43758.5453) * 6.28318530718;
    float2 fallbackDir = float2(cos(fallbackAngle), sin(fallbackAngle));
    float2 pos = startUV;
    for (int i = 0; i < STEPS; i++) {
        float2 screenPos = artCenter + (pos - 0.5) * (artHalfSize * 2.0);
        float2 g = sample_wave_gradient(waveTexture, s, screenPos, texelSize, luma);
        float gLen = length(g);
        float2 dir = gLen > 0.0001 ? (g / gLen) : fallbackDir;
        // Busier/higher-contrast wave regions tear through (or reassemble) faster than calm ones.
        float fieldStep = ease * gLen * 14.0 / float(STEPS);
        pos -= dir * (baseStep + fieldStep);
    }
    return pos;
}

// Cubic ease-in: starts flat and curves up into a steep, fast finish, so equal steps in `t` produce
// ever-larger steps in the output - stronger than a plain square, staying low for longer before its
// finishing snap. Mirrors ProjectMCoordinator.easeIn - keep the two in sync. Used to curve the
// reverseScale/slideIn intros' dissolve-amount and opacity-fade progress, so both gather speed into
// place instead of ticking up at a constant rate.
inline float ease_in(float t)
{
    float clamped = saturate(t);
    return clamped * clamped * clamped;
}

// Smoothstep feather (~5-7%) at the true [0,1] texture boundary, for a UV that's already wandered
// off the source image - shared by outgoingExit and the reverse intro's dissolve, so a pixel fades
// out *because of* how far the wave-driven walk has carried it, not an independent dissolve mask
// running alongside it.
inline float wave_dissolve_edge_alpha(float2 walkedUV)
{
    float2 edgeDist = min(walkedUV, 1.0 - walkedUV);
    return smoothstep(-0.05, 0.02, min(edgeDist.x, edgeDist.y));
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
    // 0...1 fade the reverseScale/slideIn intros use to materialize while they shrink/slide in (see
    // the header above and ProjectMCoordinator.introAlpha) - pinned at 1 for the forward intro, a
    // no-op multiply.
    float introAlpha;
    // 0 forward, 1 reverseScale, 2 slideIn - which of the three intro choreographies this track got,
    // only consulted during stage 0 (see the header above and ProjectMCoordinator.introStyle).
    float introStyle;
    // Screen-space X shift (same [0,1] space as artCenter/texCoord) applied to each layer's own
    // effective art center before computing its UV - 0 for forward/reverseScale (a no-op add), and
    // slideStartOffsetX -> 0 -> negative for slideIn (see the header above and
    // ProjectMCoordinator.albumArtOffsets).
    float subjectOffsetX;
    float backgroundOffsetX;
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
    // leave the art's own square. scaleIn normally stays clipped tight to the square too - the
    // forward intro never exceeds scale 1, so it never needs the room - but reverseScale starts
    // *larger* than the square (scale > 1) *and* pre-dissolved (scattered by wave_dissolve_walk
    // below), either of which can poke well past the square's fixed edges: without matching overhang
    // here, that gets clipped down to whatever already overlapped the square before the scale/
    // dissolve math even runs, instead of shrinking and reassembling smoothly into view. Same
    // generous margin as separate/dismissal, since the dissolve scatter alone can already reach
    // about as far as those do. slideIn needs a further, much bigger allowance on top, since it
    // starts a whole slideStartOffsetX off-screen to the right rather than merely overhanging the
    // square - see slideBoundX below.
    float bound = (stage == 1 || stage == 3 || (stage == 0 && u.introStyle > 0.5)) ? 1.0 : 0.0;
    float slideBoundX = max(abs(u.subjectOffsetX), abs(u.backgroundOffsetX)) / max(u.artHalfSize.x * 2.0, 0.0001);
    float2 artUV = (in.texCoord - u.artCenter) / (u.artHalfSize * 2.0) + 0.5;
    if (artUV.x < -(bound + slideBoundX) || artUV.x > 1.0 + bound + slideBoundX
        || artUV.y < -bound || artUV.y > 1.0 + bound || u.globalAlpha <= 0.0) {
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
        // Dismissal: `ease` grows 0 -> 1 over the stage, so the walk starts at rest (sourceUV ==
        // artUV, the intact image) and scatters further with every step - see
        // wave_dissolve_walk's own doc comment. Wherever it ends up (`sourceUV`) is treated as the
        // source pixel that would have arrived here, which is what lets torn pieces land outside
        // the original square instead of just vanishing at its edge.
        float ease = u.stageProgress * u.stageProgress;
        float2 sourceUV = wave_dissolve_walk(waveTexture, waveSampler, artUV, ease, u.artCenter, u.artHalfSize, u.waveTexelSize, luma);
        float edgeAlpha = wave_dissolve_edge_alpha(sourceUV);

        art = subjectArtTexture.sample(artSampler, saturate(sourceUV));
        alpha = art.a * edgeAlpha;
    } else {
        // scaleIn/separate/steady all work the same way: the subject cutout and the hole-punched
        // background are two puzzle-piece layers - together, at the same scale, they reconstitute
        // the original cover exactly - each sampled through its own scale (inverse-mapped: dividing
        // by a scale under 1 spreads source content out from the center, so at scale ~0 almost
        // every screen position maps outside the source's own [0,1] square and comes back
        // transparent - exactly "shrunk to nothing," the forward intro's own materialize trick;
        // dividing by a scale *over* 1 instead pulls every screen position in towards the center,
        // reading as a zoomed-in crop - the reverse intro's starting point, `introAlpha` below is
        // what actually fades that one in, since being zoomed in doesn't go transparent on its
        // own), then composited subject-over-background-over-wave. subjectScale/backgroundScale
        // arrive already computed (see AlbumArtUniforms above) as one continuous, constant-velocity
        // ramp from ProjectMCoordinator, in whichever direction this track's intro is going -
        // clamped away from exactly 0 here only to keep the division below finite; the ramp itself
        // never lingers there.
        float subjectScale = max(u.subjectScale, 0.02);
        float bgScale = max(u.backgroundScale, 0.02);

        // Each layer gets its own effective art center, shifted by that layer's own slideIn offset
        // (0 for forward/reverseScale, so subjectArtCenter/bgArtCenter just collapse back to
        // u.artCenter and this is a no-op for those two styles) - this is what actually moves the
        // art horizontally, independent of the scale math right below.
        float2 subjectArtCenter = u.artCenter + float2(u.subjectOffsetX, 0.0);
        float2 bgArtCenter = u.artCenter + float2(u.backgroundOffsetX, 0.0);
        float2 subjectArtUV = (in.texCoord - subjectArtCenter) / (u.artHalfSize * 2.0) + 0.5;
        float2 bgArtUV = (in.texCoord - bgArtCenter) / (u.artHalfSize * 2.0) + 0.5;

        float2 subjectUV = 0.5 + (subjectArtUV - 0.5) / subjectScale;
        float2 bgUV = 0.5 + (bgArtUV - 0.5) / bgScale;

        // reverseScale/slideIn only: on top of the zoomed-in crop (or, for slideIn, the shifted-
        // center crop) above, additionally walk both UVs through the wave's own gradient field via
        // wave_dissolve_walk - the same trick outgoingExit tears a track's art apart with, run
        // backward (`ease` shrinking 1 -> 0 as scaleIn progresses instead of growing 0 -> 1) - so
        // these two intros start scattered/pre-dissolved and reassemble into place at the same
        // instant they shrink/slide to rest and fade in, rather than smoothly interpolating in from
        // a clean crop. Each layer's walk is centered on that same layer's own shifted center, so
        // the scatter reads as happening wherever the art currently sits on screen rather than back
        // at the square's fixed home position. `dissolveEdgeAlpha` fades each layer out exactly
        // where its own walk has carried it off the source image - same reasoning as
        // wave_dissolve_edge_alpha's own doc comment - pinned at 1 everywhere else (forward intro,
        // or once separate/steady is reached) so it's a no-op multiply then. `ease` is 1 minus
        // ease_in(stageProgress) rather than a straight 1 - stageProgress ramp, so scatter amount
        // barely drops through the early part of scaleIn (stays heavily scattered) and then falls
        // away fast right at the end - a quick, decisive snap into place rather than a gradual
        // unwind that decelerates into the finish.
        float subjectDissolveEdgeAlpha = 1.0;
        float bgDissolveEdgeAlpha = 1.0;
        if (stage == 0 && u.introStyle > 0.5) {
            float ease = 1.0 - ease_in(u.stageProgress);
            subjectUV = wave_dissolve_walk(waveTexture, waveSampler, subjectUV, ease, subjectArtCenter, u.artHalfSize, u.waveTexelSize, luma);
            bgUV = wave_dissolve_walk(waveTexture, waveSampler, bgUV, ease, bgArtCenter, u.artHalfSize, u.waveTexelSize, luma);
            subjectDissolveEdgeAlpha = wave_dissolve_edge_alpha(subjectUV);
            bgDissolveEdgeAlpha = wave_dissolve_edge_alpha(bgUV);
        }

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

        float subjectA = (u.hasSubjectMask > 0.5 && subjectInBounds) ? subjectSample.a * subjectDissolveEdgeAlpha : 0.0;
        float bgA = bgInBounds ? bgSample.a * bgDissolveEdgeAlpha : 0.0;

        // During scaleIn subjectUV == bgUV (both layers share the same growing scale/shifting
        // center), so the two puzzle pieces just reconstitute the whole cover at whatever size/
        // position it's currently at - no separate handling needed here, only separate/steady
        // change how bgA behaves.
        if (stage == 1 && u.hasSubjectMask > 0.5) {
            // noise is spread ~uniformly across [0, 1) per pixel, so the smoothstep sweep below only
            // reads as a graduated, organic dissolve if its input covers that same [0, 1) range at a
            // *constant* rate - running ease_in through it here (tried previously) squeezes nearly
            // all of that range into a sliver of real time right at the end, so almost nothing erodes
            // for most of the stage and then the entire noise population crosses its threshold at
            // once, reading as solid-then-pop rather than dissolving. dissolveSpeed instead just
            // covers that same [0, 1) sweep in less real time (clamped once it gets there) - still a
            // constant-rate wipe, just a faster and shorter one - so separate's actual pull-apart
            // *motion* (backgroundScale/backgroundOffsetX, arriving from Swift already at their own
            // constant-velocity rate) is untouched, but the background finishes dissolving/fading out
            // well before separate's motion itself is done.
            float dissolveSpeed = 6.0;
            float dissolveProgress = min(u.stageProgress * dissolveSpeed, 1.0);
            bgA *= 1.0 - smoothstep(noise - band, noise + band, dissolveProgress);
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

    alpha *= saturate(u.introAlpha);
    alpha *= saturate(u.globalAlpha);
    return float4(mix(wave.rgb, art.rgb, saturate(alpha)), 1.0);
}
