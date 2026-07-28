//
//  ProjectMCompositeShader.metal
//  Prism
//
//  Real projectM (via ANGLE) already did every actual wave rendering pass - warp/feedback,
//  shapes, waveforms, comp shader - inside the IOSurface-backed FBO ProjectMEngine renders into.
//  This draws that finished texture into the MTKView's drawable, and - since the album art
//  overlay moved here from a separate SwiftUI layer - composites album art on top of it in the
//  same pass as two independent, concurrently-running layers (see ProjectMCoordinator's
//  advanceAlbumArtAnimation, which drives the uniforms below): the *incoming* track, walking
//  through a three-stage sequence (`stage`/`stageProgress`), and - only while a previous track's
//  art is still dissolving away, on a track change - the *outgoing* track's own independent exit
//  (`outgoingActive`/`outgoingProgress`). The two run on separate clocks and are composited
//  outgoing-under-incoming, so an entrance and the exit it interrupted are visibly on screen at the
//  same time rather than one waiting for the other to finish first.
//
//  Incoming track (`stage`):
//    0 scaleIn        - the new track's full cover (background and subject together) animates to
//                       its full size and position, centered on the art square's own center. Every
//                       introStyle plays the *exact same* dissolve/opacity/distortion treatment here
//                       - fully transparent and pre-dissolved (scattered by the wave's own gradient
//                       field, the same walk the outgoing layer's own exit tears a track's art apart
//                       with below, just run backward: `ease` shrinking instead of growing), fading
//                       in (`introAlpha`) and reassembling out of the scatter all in lockstep, nudged
//                       by the same wave-gradient distortion as everything else - so every entrance
//                       reads as condensing and cohering into place at once, equally, regardless of
//                       which style it got. Picked once per track (ProjectMCoordinator.introStyle),
//                       the *only* thing that differs between the four is the geometric motion
//                       layered on top of that shared dissolve:
//                         forward      - scale ramps 0 -> 1 (materializes by growing from a point);
//                           no offset.
//                         reverseScale - scale ramps down from a zoomed-in crop (> 1) to full size;
//                           no offset.
//                         slideRight   - scale pinned at 1 throughout (no zoom at all); starts
//                           off-screen to the right (subjectOffset/backgroundOffset, a screen-space
//                           shift applied to each layer's own effective art center) and slides in to
//                           dead center.
//                         slideDown    - same as slideRight, rotated 90 degrees onto the vertical
//                           axis: starts off-screen above instead of to the right, and slides down
//                           to center.
//    1 separate        - the subject's own scale/position locks right where scaleIn left it, while
//                       the *background* - the raw cover with a subject-shaped hole already punched
//                       out of it, see ProjectMCoordinator.backgroundWithSubjectHole, so it never
//                       carries a copy of the subject's own pixels underneath it - keeps growing
//                       past full size (or, for slideRight/slideDown, keeps sliding further past
//                       center in the same direction it came from), gets torn apart by the same
//                       wave_dissolve_walk scatter scaleIn's entrance reassembles out of (run in
//                       reverse - growing instead of shrinking), and fades away in per-pixel noise
//                       order on top of that, sped up relative to the motion (see dissolveSpeed
//                       below, one shared rate for every introStyle) so it finishes disappearing
//                       well before the motion itself is done. Background and subject visibly pull
//                       apart, leaving the subject anchored in place as the background
//                       scatters/dissolves outward - identically regardless of introStyle.
//    2 steady         - subject (or, with no detected subject, the whole cover) just sits there.
//
//  Outgoing track (`outgoingActive`/`outgoingProgress`, independent of `stage` above) - on a track
//  change, whatever was on screen a moment ago gets swept away by the wave itself: each pixel is
//  walked backward, step by step, through the wave's own local gradient field (see
//  sample_wave_gradient below), so both the direction it goes and how fast are entirely dictated by
//  whatever the wave is actually doing underneath it - no independent noise or timer-driven
//  dissolve standing in for that.
//
//  Independent of both layers, every art sample is nudged by the wave texture's own local
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
    // direction once `ease` stays high for long enough to matter (e.g. the slide intros' slower-to-
    // resolve dissolve curve) - a per-pixel hash keeps calm regions scattering in varied directions instead,
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
// finishing snap. Mirrors ProjectMCoordinator.easeIn - keep the two in sync. No longer used by
// scaleIn's own dissolve/opacity (see ease_out below) - kept for whichever callers still want a
// slow-start/fast-finish curve.
inline float ease_in(float t)
{
    float clamped = saturate(t);
    return clamped * clamped * clamped;
}

// Cubic ease-out: ease_in's mirror image - starts with a fast, steep rise and flattens into the
// finish, so equal steps in `t` produce ever-smaller steps in the output. Mirrors
// ProjectMCoordinator.easeOut - keep the two in sync. Used to curve scaleIn's dissolve-amount and
// opacity-fade progress (every introStyle, see the header above) - a fast-starting fade-in is what
// closes the gap with the outgoing layer's own fast-starting fade-out (exitOpacity below), so the
// two are both clearly on screen at once instead of the outgoing finishing while the incoming is
// still nearly invisible. (ease_in's slow start read as a real gap here even though the two layers'
// clocks start on the exact same frame - see advanceAlbumArtAnimation.)
inline float ease_out(float t)
{
    float clamped = saturate(t);
    float inv = 1.0 - clamped;
    return 1.0 - inv * inv * inv;
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
    float stage;             // 0 scaleIn, 1 separate, 2 steady - the *incoming* track (see header above)
    float stageProgress;     // 0...1 progress through the incoming track's current stage
    float hasSubjectMask;    // 0 or 1 - whether Vision found a subject on the *incoming* track
    float globalAlpha;       // "H" hidden-toggle / no-track-loaded mute, eased 0...1
    float distortionStrength;
    // Precomputed on the Swift side (not derived from stage/stageProgress here) so growth is one
    // continuous, constant-velocity ramp straight through the scaleIn -> separate boundary, with
    // no perceptible change in speed there - see ProjectMCoordinator.albumArtScales. subjectScale
    // locks at 1 the moment it gets there; backgroundScale just keeps going at that exact same rate.
    float subjectScale;
    float backgroundScale;
    // 0...1 fade every introStyle uses to materialize, shared identically across all four (see the
    // header above and ProjectMCoordinator.introAlpha) - only the scale/offset each style layers on
    // top differs; this fade itself doesn't. Which of the four choreographies a track got is
    // resolved into that scale/offset math entirely on the Swift side (see
    // ProjectMCoordinator.introStyle/albumArtScales/albumArtOffsets) - the shader never sees
    // introStyle itself, since it no longer needs to branch on it for anything.
    float introAlpha;
    // Screen-space shift (same [0,1] space as artCenter/texCoord) applied to each layer's own
    // effective art center before computing its UV - (0, 0) for forward/reverseScale (a no-op add);
    // for slideRight, x runs slideStartOffset -> 0 -> negative (y stays 0); for slideDown, y runs
    // -slideStartOffset -> 0 -> positive (x stays 0) - see the header above and
    // ProjectMCoordinator.albumArtOffsets.
    float2 subjectOffset;
    float2 backgroundOffset;
    // Whether the *outgoing* (previous) track is concurrently dissolving away underneath the
    // incoming track described by the rest of this struct - and, if so, how far through its own
    // exit (0...1). Independent clock from stage/stageProgress above - see the header's "Outgoing
    // track" section and ProjectMCoordinator.outgoingActiveAndProgress.
    float outgoingActive;
    float outgoingProgress;
};

fragment float4 projectm_composite_fragment(ProjectMPassthroughVaryings in [[stage_in]],
                                             texture2d<float> waveTexture [[texture(0)]],
                                             texture2d<float> backgroundArtTexture [[texture(1)]],
                                             texture2d<float> subjectArtTexture [[texture(2)]],
                                             texture2d<float> outgoingArtTexture [[texture(3)]],
                                             constant AlbumArtUniforms &u [[buffer(0)]])
{
    constexpr sampler waveSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    constexpr sampler artSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float4 wave = waveTexture.sample(waveSampler, in.texCoord);

    int stage = int(u.stage + 0.5);
    // Dismissal's torn-away content and separate's still-growing background both need to visibly
    // leave the art's own square. scaleIn needs the same room for every introStyle now that they
    // all share the same pre-dissolved (scattered by wave_dissolve_walk below) start - forward's
    // scale never exceeds 1, but the dissolve scatter alone can already poke well past the square's
    // fixed edges without matching overhang here, which would otherwise clip torn pieces down to
    // whatever already overlapped the square before the scale/dissolve math even runs, instead of
    // shrinking and reassembling smoothly into view. Same generous margin as separate/dismissal,
    // since the dissolve scatter alone can already reach about as far as those do. slideRight/
    // slideDown need a further, much bigger allowance on top, since they start a whole
    // slideStartOffset off-screen (to the right, or above) rather than merely overhanging the
    // square - see slideBound below.
    bool outgoingActive = u.outgoingActive > 0.5;
    float bound = (stage == 0 || stage == 1 || outgoingActive) ? 1.0 : 0.0;
    float2 slideBound = max(abs(u.subjectOffset), abs(u.backgroundOffset)) / max(u.artHalfSize * 2.0, 0.0001);
    float2 artUV = (in.texCoord - u.artCenter) / (u.artHalfSize * 2.0) + 0.5;
    if (artUV.x < -(bound + slideBound.x) || artUV.x > 1.0 + bound + slideBound.x
        || artUV.y < -(bound + slideBound.y) || artUV.y > 1.0 + bound + slideBound.y
        || u.globalAlpha <= 0.0) {
        return wave;
    }

    float3 luma = float3(0.299, 0.587, 0.114);
    float2 waveGradient = sample_wave_gradient(waveTexture, waveSampler, in.texCoord, u.waveTexelSize, luma);

    // Cheap per-pixel hash, used as the background layer's own erosion order during separate: a
    // pixel "goes" once stageProgress passes its own noise value, smoothed by `band` so the
    // dissolving edge reads as ragged/organic rather than a hard cutoff. Narrow rather than wide, so
    // each pixel's own opaque -> transparent transition is a quick snap rather than a soft blend -
    // that per-pixel sharpness is what reads as "intensity" here, separately from dissolveSpeed below
    // (which controls how much of the stage's real time the whole population's sweep takes).
    float noise = fract(sin(dot(artUV * 41.13, float2(12.9898, 78.233))) * 43758.5453);
    float band = 0.08;

    // Outgoing layer: the previous track, still dissolving away on its own independent clock while
    // the incoming layer below plays its entrance concurrently - see the header's "Outgoing track"
    // section. Computed first (and composited underneath) so it reads as the art that was already
    // there getting swept aside as the new art arrives on top of it.
    float4 outArt = float4(0.0);
    float outAlpha = 0.0;
    if (outgoingActive) {
        // `ease` grows 0 -> 1 over the exit, so the walk starts at rest (sourceUV == artUV, the
        // intact image) and scatters further with every step - see wave_dissolve_walk's own doc
        // comment. Wherever it ends up (`sourceUV`) is treated as the source pixel that would have
        // arrived here, which is what lets torn pieces land outside the original square instead of
        // just vanishing at its edge.
        float ease = u.outgoingProgress * u.outgoingProgress;
        float2 sourceUV = wave_dissolve_walk(waveTexture, waveSampler, artUV, ease, u.artCenter, u.artHalfSize, u.waveTexelSize, luma);
        float edgeAlpha = wave_dissolve_edge_alpha(sourceUV);

        outArt = outgoingArtTexture.sample(artSampler, saturate(sourceUV));
        // edgeAlpha alone only fades a pixel once its own walked position has wandered far enough
        // off the source image - purely spatial, no guarantee every pixel gets there by the time
        // `ease` (and outgoingProgress) hits 1, since a busy/high-contrast patch of wave can curl a
        // pixel's path back on itself almost as often as it pushes it outward. That left some
        // pixels still partly opaque right when advanceAlbumArtAnimation hard-despawns this whole
        // texture at the end of the exit - a one-frame pop. exitOpacity is an explicit, whole-
        // graphic fade keyed on outgoingProgress alone (not the walk), so it's guaranteed to hit
        // exactly 0 the same instant outgoingProgress does - the same instant ease maxes out and the
        // exit ends - regardless of what any individual pixel's walk happened to do. sqrt (rather
        // than a straight 1 - outgoingProgress ramp) front-loads the fade so it visibly vanishes
        // early rather than staying near-opaque for most of the exit and only dropping off at the
        // end.
        float exitOpacity = 1.0 - sqrt(saturate(u.outgoingProgress));
        outAlpha = outArt.a * edgeAlpha * exitOpacity;
    }

    float4 art;
    float alpha;

    {
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

        // Each layer gets its own effective art center, shifted by that layer's own slide offset
        // ((0, 0) for forward/reverseScale, so subjectArtCenter/bgArtCenter just collapse back to
        // u.artCenter and this is a no-op for those two styles) - this is what actually moves the
        // art, independent of the scale math right below.
        float2 subjectArtCenter = u.artCenter + u.subjectOffset;
        float2 bgArtCenter = u.artCenter + u.backgroundOffset;
        float2 subjectArtUV = (in.texCoord - subjectArtCenter) / (u.artHalfSize * 2.0) + 0.5;
        float2 bgArtUV = (in.texCoord - bgArtCenter) / (u.artHalfSize * 2.0) + 0.5;

        float2 subjectUV = 0.5 + (subjectArtUV - 0.5) / subjectScale;
        float2 bgUV = 0.5 + (bgArtUV - 0.5) / bgScale;

        // Every introStyle, including forward, walks both UVs through the wave's own gradient field
        // via wave_dissolve_walk - the same trick the outgoing layer's own exit tears a track's art
        // apart with, run backward (`ease` shrinking 1 -> 0 as scaleIn progresses instead of growing
        // 0 -> 1) - on top of whichever scale/offset crop this style computed above, so every
        // entrance starts scattered/pre-dissolved and reassembles into place at the same instant it
        // finishes its own scale/slide-to-rest and fades in, rather than smoothly interpolating in
        // from a clean crop. Each layer's walk is centered on that same layer's own shifted center,
        // so the scatter reads as happening wherever the art currently sits on screen rather than
        // back at the square's fixed home position. `dissolveEdgeAlpha` fades each layer out exactly
        // where its own walk has carried it off the source image - same reasoning as
        // wave_dissolve_edge_alpha's own doc comment - pinned at 1 once separate/steady is reached,
        // so it's a no-op multiply then. `ease` is 1 minus ease_out(stageProgress) rather than a
        // straight 1 - stageProgress ramp, so scatter amount drops fast through the early part of
        // scaleIn (coheres quickly) and then only inches the rest of the way through the tail -
        // reassembling right away rather than lingering scattered/nearly-invisible while the
        // outgoing layer alongside it (see outgoingActive above) is already fading fast itself; see
        // ease_out's own doc comment for why that's the one that closes the gap.
        // separate's own dissolve sweep - hoisted up here (rather than just above its one other use
        // below) so the background's *walk/distortion* can ramp up in lockstep with its fade-out:
        // the further stageProgress has swept through separate, the harder the wave shoves the
        // background around, so it reads as getting dragged apart/melted into the wave on its way
        // out rather than just uniformly fading in place at a fixed distortion. Subject is
        // unaffected - it's anchored and staying, only the departing background accelerates.
        // One shared rate for every introStyle now (previously 1.4 for the scale-driven pair and 9.0
        // for the slide-driven pair, tuned separately since scale motion and slide motion cover real
        // screen distance at different rates) - unified so the background dissolves identically
        // regardless of which entrance the track got; if a given style's background pops before its
        // own motion reads as finished (or lingers after), retune this one number rather than
        // reintroducing a per-style split.
        float dissolveSpeed = 3.0;
        float dissolveProgress = (stage == 1 && u.hasSubjectMask > 0.5) ? min(u.stageProgress * dissolveSpeed, 1.0) : 0.0;
        const float bgDissolveDistortionBoost = 0.6;

        float subjectDissolveEdgeAlpha = 1.0;
        float bgDissolveEdgeAlpha = 1.0;
        if (stage == 0) {
            float ease = 1.0 - ease_out(u.stageProgress);
            subjectUV = wave_dissolve_walk(waveTexture, waveSampler, subjectUV, ease, subjectArtCenter, u.artHalfSize, u.waveTexelSize, luma);
            bgUV = wave_dissolve_walk(waveTexture, waveSampler, bgUV, ease, bgArtCenter, u.artHalfSize, u.waveTexelSize, luma);
            subjectDissolveEdgeAlpha = wave_dissolve_edge_alpha(subjectUV);
            bgDissolveEdgeAlpha = wave_dissolve_edge_alpha(bgUV);
        } else if (stage == 1 && u.hasSubjectMask > 0.5) {
            // The departing background's counterpart to the block above - the exact same
            // wave_dissolve_walk scatter scaleIn's entrance reassembles out of, just run in reverse:
            // `ease` grows 0 -> 1 (riding dissolveProgress, so the scatter and the fade-out below
            // stay in lockstep) instead of shrinking 1 -> 0, so the background visibly tears apart
            // into the wave on its way out the same way it would cohere on its way in, rather than
            // just fading and drifting in place. Subject stays anchored/untouched - only the
            // departing background scatters.
            bgUV = wave_dissolve_walk(waveTexture, waveSampler, bgUV, dissolveProgress, bgArtCenter, u.artHalfSize, u.waveTexelSize, luma);
            bgDissolveEdgeAlpha = wave_dissolve_edge_alpha(bgUV);
        }

        float2 distortedSubjectUV = subjectUV + waveGradient * u.distortionStrength;
        float2 distortedBgUV = bgUV + waveGradient * (u.distortionStrength + dissolveProgress * bgDissolveDistortionBoost);

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
            // *motion* (backgroundScale/backgroundOffset, arriving from Swift already at their own
            // constant-velocity rate) is untouched, but the background finishes dissolving/fading out
            // well before separate's motion itself is done. Upper edge clamped to 1 (rather than the
            // raw noise + band, which reaches past 1 for noise close to 1) so every pixel - not just
            // the ones with lower noise values - is guaranteed fully transparent once dissolveProgress
            // itself hits 1, landing exactly on 0 opacity right as distortedBgUV's boost above (driven
            // by that same dissolveProgress) tops out at its own maximum - full distortion and zero
            // opacity arrive together, rather than a few stray high-noise pixels lingering until
            // stage >= 2 above snaps them to 0 a moment later.
            bgA *= 1.0 - smoothstep(noise - band, min(noise + band, 1.0), dissolveProgress);
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
    outAlpha *= saturate(u.globalAlpha);

    // Outgoing under incoming: the departing track shows through wherever the arriving one hasn't
    // covered it yet, so the two visibly overlap - the arriving track's entrance and the departing
    // track's exit play out on screen at the same time - instead of the wave being the only thing
    // visible in between one finishing and the other starting.
    float3 colorWithOutgoing = mix(wave.rgb, outArt.rgb, saturate(outAlpha));
    return float4(mix(colorWithOutgoing, art.rgb, saturate(alpha)), 1.0);
}
