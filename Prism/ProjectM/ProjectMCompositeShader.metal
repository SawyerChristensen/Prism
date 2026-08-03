//
//  ProjectMCompositeShader.metal
//  Prism
//
//  Real projectM (via ANGLE) already did every actual wave rendering pass - warp/feedback,
//  shapes, waveforms, comp shader - inside the IOSurface-backed FBO ProjectMEngine renders into.
//  This draws that finished texture into the MTKView's drawable, and - since the album art
//  overlay moved here from a separate SwiftUI layer - composites album art on top of it in the
//  same pass.
//
//  Album art (ContentView's "M" four-layer reveal - see ProjectMCoordinator.AlbumArtLayerCount):
//  four independent layers, always stacked bottom to top in this fixed order - backgroundColor,
//  backgroundDetail, text, subject - each a genuinely non-overlapping piece of the cover (see
//  NowPlayingManager.backgroundColorArtwork/backgroundDetailArtwork/textOnlyArtwork/
//  subjectOnlyArtwork), each sampled with a fixed set of effects that never changes, composited
//  with standard sequential "over" blending. Every layer carries the same beat-driven zoom
//  (ProjectMCoordinator.beatPulse - punches inward on a fresh bass hit, relaxes back as the pulse
//  decays), forming a parallax stack: subject (topmost, "closest") moves the most, then text, then
//  backgroundDetail, then backgroundColor (bottom, "furthest") moves the least. backgroundColor's
//  strength is fixed; the other three's strengths are resampled per track from however many of
//  subject/text/backgroundDetail this cover actually has (ProjectMCoordinator.
//  resampleBeatZoomStrengths) - a cover missing its subject, say, has text take over the
//  topmost/strongest slot instead of being stuck at its own weaker one, so the frontmost surviving
//  layer always punches the hardest regardless of which layers this particular cover has.
//  backgroundDetail alone additionally carries chromatic aberration (R/G/B split along a slowly
//  spinning axis, each channel's own offset magnitude further eased by a cosine of the same
//  spin angle so the effect continuously cycles through every hue rather than sitting fixed on a
//  static R/B split - see this file's own backgroundDetail comment below - ProjectMCoordinator.
//  backgroundColorChromaticAberrationStrength/aberrationRotationPeriod - named for the layer
//  beneath it in the stack, not the layer it's actually applied to, see below), wave-gradient UV
//  distortion, and a wave-brightness alpha fade:
//    backgroundColor  - a flat fill of the measured background color.
//                        Effects: beat zoom only, at a fixed strength - a flat fill has no internal
//                        color variation for chromatic aberration, distortion, or the brightness
//                        fade to act on (all three would be a structural no-op here regardless of
//                        strength - see this file's own backgroundColor sampling comment below), so
//                        none of them are applied.
//    backgroundDetail - the color-keyed cover, with the subject and text also punched out.
//                        Effects: beat zoom (resampled strength) + chromatic aberration +
//                        wave-gradient UV distortion (a cheap refraction/heat-haze trick - a hard
//                        edge or bright streak in the wave visibly pushes this layer around) + a
//                        wave-brightness alpha fade (ProjectMCoordinator.
//                        backgroundDetailDistortionAlphaLow/High - punches an actual hole through
//                        this layer wherever the wave itself is bright, revealing the usually far
//                        more colorful wave beneath instead of just warping over it). This is the
//                        layer with real image content, so all three of backgroundColor's would-be
//                        effects live here instead.
//    text             - the isolated OCR text.  Effect: beat zoom only (resampled strength).
//    subject          - the isolated Vision cutout, always drawn topmost.
//                        Effect: beat zoom only (resampled strength, usually the greatest of the
//                        four - see maxBeatZoomStrength below for the one case it isn't: this
//                        cover having no subject at all).
//  "M" never changes what a layer contains or how it's treated - see AlbumArtUniforms's four
//  `*Visible` flags below - it only reveals or hides layers starting from the bottom of the stack
//  (4 visible -> 3 -> 2 -> 1 (just the subject) -> 0 -> wraps back to 4).
//
//  Independent of the above: a separate, pre-existing dormant feature - the *previous* track's art
//  dissolving away on a track change, swept apart by the wave's own local gradient field (see
//  sample_wave_gradient/wave_dissolve_walk below) - composited underneath everything above.
//  outgoingActive is always 0 today (see ProjectMCoordinator.draw(in:)); this four-layer stack
//  doesn't drive or depend on it.
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
// getting brighter here" vector, used both by the backgroundDetail layer's distortion and the
// outgoing track's dissolve-walk below.
inline float2 sample_wave_gradient(texture2d<float> waveTexture, sampler s, float2 texCoord, float2 texelSize, float3 luma)
{
    float lumL = dot(waveTexture.sample(s, texCoord - float2(texelSize.x, 0)).rgb, luma);
    float lumR = dot(waveTexture.sample(s, texCoord + float2(texelSize.x, 0)).rgb, luma);
    float lumU = dot(waveTexture.sample(s, texCoord - float2(0, texelSize.y)).rgb, luma);
    float lumD = dot(waveTexture.sample(s, texCoord + float2(0, texelSize.y)).rgb, luma);
    return float2(lumR - lumL, lumD - lumU);
}

// Samples one color channel of `tex` as a soft 5-tap plus-shaped box blur (center + the four
// texelBlur-offset neighbors, averaged) rather than a single crisp point/bilinear sample - used by
// the backgroundDetail layer's chromatic aberration so each channel's offset copy fades softly
// into the unshifted image around it instead of ending in a hard, single-pixel-wide edge. That
// hard edge is what reads as "noisy" wherever the underlying art has a lot of fine contrast: this
// blurs it into a gradient instead.
inline float sample_channel_soft(texture2d<float> tex, sampler s, float2 uv, float2 texelBlur, int channel)
{
    float4 c = tex.sample(s, uv);
    c += tex.sample(s, uv + float2(texelBlur.x, 0.0));
    c += tex.sample(s, uv - float2(texelBlur.x, 0.0));
    c += tex.sample(s, uv + float2(0.0, texelBlur.y));
    c += tex.sample(s, uv - float2(0.0, texelBlur.y));
    return (c / 5.0)[channel];
}

// Inverse-mapped divide: dividing by a scale over 1 pulls every screen position in towards center,
// reading as a zoomed-in crop that visibly extends past its own square (see beatZoomBound in the
// fragment function below) - the shared "parallax punch" every album art layer applies to itself on
// a bass hit, just at a different `strength` per layer (see this file's own header). Clamped away
// from exactly 0 only to keep the division finite, since beatZoom (1 + a decaying pulse * a
// positive strength) never actually reaches it.
inline float2 beat_zoom_uv(float2 artUV, float beatPulse, float strength)
{
    float beatZoom = max(1.0 + beatPulse * strength, 0.02);
    return 0.5 + (artUV - 0.5) / beatZoom;
}

// Walks `startUV` backward, step by step, through the wave's own local gradient field, re-sampling
// the gradient at each intermediate position rather than reading it once - so the path curves
// through whatever the wave is doing along the way instead of a single straight-line push. Used by
// the outgoing track's own exit (`ease` growing 0 -> 1 over the dissolve). A pixel over a flat,
// low-contrast stretch of wave barely gets pulled by the field alone, so a small baseline step
// (independent of the field) guarantees everything still fully scatters by the extreme end of
// `ease` rather than leaving a static residue behind in the calm spots.
inline float2 wave_dissolve_walk(texture2d<float> waveTexture, sampler s, float2 startUV, float ease,
                                  float2 artCenter, float2 artHalfSize, float2 texelSize, float3 luma)
{
    const int STEPS = 6;
    float baseStep = ease * 1.1 / float(STEPS);
    // Per-pixel fallback direction for calm/flat wave regions, where the local gradient is too weak
    // to reliably steer the walk (see the dir select below) - a hash of the pixel's own starting UV,
    // not a single constant direction, so calm regions scatter in varied directions instead of the
    // whole image reading as drifting in one direction, while staying fully stable frame-to-frame.
    float fallbackAngle = fract(sin(dot(startUV, float2(12.9898, 78.233))) * 43758.5453) * 6.28318530718;
    float2 fallbackDir = float2(cos(fallbackAngle), sin(fallbackAngle));
    float2 pos = startUV;
    for (int i = 0; i < STEPS; i++) {
        float2 screenPos = artCenter + (pos - 0.5) * (artHalfSize * 2.0);
        float2 g = sample_wave_gradient(waveTexture, s, screenPos, texelSize, luma);
        float gLen = length(g);
        float2 dir = gLen > 0.0001 ? (g / gLen) : fallbackDir;
        // Busier/higher-contrast wave regions tear through faster than calm ones.
        float fieldStep = ease * gLen * 14.0 / float(STEPS);
        pos -= dir * (baseStep + fieldStep);
    }
    return pos;
}

// Smoothstep feather (~5-7%) at the true [0,1] texture boundary, for a UV that's already wandered
// off the source image via wave_dissolve_walk - a pixel fades out *because of* how far the
// wave-driven walk has carried it, not an independent dissolve mask running alongside it.
inline float wave_dissolve_edge_alpha(float2 walkedUV)
{
    float2 edgeDist = min(walkedUV, 1.0 - walkedUV);
    return smoothstep(-0.05, 0.02, min(edgeDist.x, edgeDist.y));
}

// --- Preset-transition album-art effect ---
// Ports real projectM's own built-in preset-transition shaders (Vendor/projectm/src/libprojectM/
// Renderer/TransitionShaders/*Glsl330.frag) onto the album art layer, so it visibly plays the exact
// same transition (not just the same kind of transition) as whatever real projectM is doing to the
// wave underneath - which of the 6 built-in shaders, its progress, and its per-transition random
// seeds are all read live off the engine every frame (see AlbumArtUniforms.presetTransition* below
// and ProjectMEngine's presetTransition* properties, backed by the PRISM_LOCAL_PATCH documented in
// Vendor/projectm-VERSION.md's "exposed preset-transition state" entry - that state is otherwise
// fully internal to the engine with no way to observe it from outside).
//
// Two things need to match real projectM exactly, not just approximately, for this to actually look
// like the same transition rather than a coincidentally-similar one:
//   - The seed math. Each formula below multiplies its seed by the *same* scale factor the original
//     GLSL does before its own mod() (e.g. Circle's `mod(float(iRandStatic.x) * .01, 2.)`) - these
//     aren't cosmetic; dropping or changing them computes a genuinely different parameter (a
//     different wipe angle, a different warp direction - occasionally its exact mirror) from the
//     same seed, not just a differently-distributed one. See
//     ProjectMCoordinator.reducedPresetTransitionSeed's own doc comment for the exact-reduction math
//     backing this.
//   - The coordinate convention. Real projectM's shaders compute their own spatial math from GLSL
//     fragCoord (bottom-left origin, Y up, by default absent an origin_upper_left layout qualifier -
//     which projectM's GLES-targeting shaders don't use); this file's in.texCoord is Metal's
//     top-left origin, Y down (see ProjectMPassthroughVaryings' own vertex-shader comment - that's
//     about the wave *texture's* row order, a separate concern from this independently-computed
//     rotation math). Where that difference actually changes the on-screen result (Sweep's
//     atan2-based rotation - see preset_transition_mask_sweep), Y is flipped back to match.
//
// The originals blend an "old" (outgoing) and "new" (incoming) full-screen preset render together;
// album art gets the literal same treatment here, blending whatever art was on screen the instant
// this preset transition started (ProjectMCoordinator snapshots it into the old*ArtTexture
// bindings) against the live/current art. When the track hasn't changed, old and new are the same
// image, so every effect below is naturally a no-op (mix(X,X,t) == X, a warp/blur of identical
// content still ends up back at that same content) - album art only visibly transitions when it's
// actually changing, in lockstep with whichever effect is playing over the wave that moment:
//   circle/plasma/sweep/simpleBlend - spatial reveal masks (how much of the *new* art shows through,
//     in that effect's shape) - reveal is computed once in the fragment function below (screen-space,
//     shared by all three layers) and consumed via mix(oldSample, newSample, reveal) per layer.
//   warp - a center-relative zoom blending two oppositely-scaled samples, one from the old texture,
//     one from the new - see preset_transition_warp_blend.
//   zoomBlur - a radial blur toward screen center, crossfading old into new at each tap as it blurs
//     (Exponential_easeInOut dissolve, same shape as the original) - see
//     preset_transition_zoom_blur_blend. Ported with fewer taps (8, not 20) for cost.
constant float kPresetTransitionPi = 3.14159265358979323846;
// Peak strength preset_transition_zoom_blur_blend's radial pull reaches (at progressCosine 0.5) -
// hoisted here (rather than a local inside that function) so the fragment function's own overhang
// bound for this effect (see kWarpOverhangBound's sibling comment) can derive the exact same value
// analytically instead of guessing a separate constant that could drift out of sync with it.
constant float kZoomBlurStrengthConst = 0.3;

// GLSL's mod(x,y) (== x - y*floor(x/y), always the same sign as y) rather than C/Metal's fmod
// (truncates toward zero, so a negative x gives a negative result) - the real random seeds this
// feeds (ProjectMEngine.presetTransitionRandomSeedA-D, real int32 values straight from projectM's
// std::mt19937, so routinely negative) need GLSL's always-non-negative-for-positive-y behavior to
// land in the ranges these ported formulas (originally GLSL mod() calls) expect.
inline float preset_transition_glsl_mod(float x, float y)
{
    return x - y * floor(x / y);
}

inline float preset_transition_mask_circle(float2 uv, float aspect, float progressCosine, float4 seeds)
{
    // *.01/*.001 scale factors match TransitionShaderBuiltInCircleGlsl330.frag exactly (mod(float
    // (iRandStatic.x) * .01, 2.) / mod(float(iRandStatic.y) * .001, .1)) - dropping them doesn't
    // just change the *distribution*, it computes a different parameter than real projectM did
    // from the same seed (see ProjectMCoordinator.reducedPresetTransitionSeed's own doc comment).
    float inOrOut = preset_transition_glsl_mod(seeds.x * 0.01, 2.0);
    float progress = inOrOut < 1.0 ? progressCosine : 1.0 - progressCosine;
    float blendWidth = preset_transition_glsl_mod(seeds.y * 0.001, 0.1) + 0.05;
    progress = progress * (1.0 + blendWidth) - blendWidth;

    float2 center = float2(0.5);
    float rad = sqrt(center.x / aspect * center.x / aspect + center.y * center.y) * progress;
    float rad2 = rad + blendWidth;
    float r1 = sqrt((uv.x - center.x) / aspect * (uv.x - center.x) / aspect + (uv.y - center.y) * (uv.y - center.y));

    float insideReveal = inOrOut < 1.0 ? 1.0 : 0.0;
    float outsideReveal = 1.0 - insideReveal;
    if (r1 > rad2) { return outsideReveal; }
    if (r1 <= rad) { return insideReveal; }
    return mix(insideReveal, outsideReveal, (r1 - rad) / (rad2 - rad));
}

inline float preset_transition_sin_noise(float2 uv, float seed)
{
    // *.001 matches the original's sinNoise (TransitionShaderBuiltInPlasmaGlsl330.frag) exactly.
    return fract(abs(sin(uv.x * 0.018 + uv.y * 0.3077) * (seed * 0.001)));
}

inline float preset_transition_value_noise(float2 uv, float scale, float seed)
{
    float2 luvs = smoothstep(0.0, 1.0, fract(uv * scale));
    float2 id = floor(uv * scale);
    float t = mix(preset_transition_sin_noise(id + float2(0.0, 1.0), seed),
                  preset_transition_sin_noise(id + float2(1.0, 1.0), seed), luvs.x);
    float b = mix(preset_transition_sin_noise(id + float2(0.0, 0.0), seed),
                  preset_transition_sin_noise(id + float2(1.0, 0.0), seed), luvs.x);
    return mix(b, t, luvs.y) * 2.0 - 1.0;
}

inline float preset_transition_mask_plasma(float2 uv, float aspect, float progressCosine, float4 seeds)
{
    float2 puv = uv;
    puv.y *= aspect;
    float scale = preset_transition_glsl_mod(seeds.y * 0.01, 7.0) * 4.0 + 4.0;
    float fractValue = 0.0;
    float amp = 1.0;
    for (int i = 0; i < 16; i++) {
        fractValue += preset_transition_value_noise(puv, float(i + 1) * scale, seeds.x) * amp;
        amp *= 0.5;
    }
    fractValue = fractValue * 0.25 + 0.5;
    return smoothstep(progressCosine + 0.1, progressCosine - 0.1, fractValue);
}

inline float preset_transition_mask_sweep(float2 uv, float progressCosine, float4 seeds)
{
    // currentAngle: no scale factor in the original (mod(float(iRandStatic.x), 360.)) - blendWidth
    // does (*.001) - see TransitionShaderBuiltInSweepGlsl330.frag and this file's own header on why
    // dropping either changes which parameter this computes, not just its spread.
    float currentAngle = preset_transition_glsl_mod(seeds.x, 360.0);
    float blendWidth = preset_transition_glsl_mod(seeds.y * 0.001, 0.3) + 0.1;

    float2 c = uv - 0.5;
    constexpr float kDegToRad = kPresetTransitionPi / 180.0;
    float angle = 90.0 * kDegToRad - currentAngle * kDegToRad + atan2(c.y, c.x);
    float len = length(c) / sqrt(2.0);
    float2 su = float2(cos(angle) * len, sin(angle) * len) + 0.5;

    float towardOld = smoothstep(progressCosine, progressCosine + blendWidth, (su.x / (1.0 + 2.0 * blendWidth)) + blendWidth);
    return 1.0 - towardOld;
}

// Warp: a center-relative zoom blending an oppositely-scaled sample of the old texture with one of
// the new texture - see TransitionShaderBuiltInWarpGlsl330.frag. At x=0 this is 100% oldSample
// (unwarped); at x=1, 100% newSample (also unwarped) - the zoom itself only shows up in between.
// `uv` is expected to already carry the extra overhang the caller grants specifically for this
// effect (see kWarpOverhangBound in the fragment function) - unlike every other per-layer UV in
// this file, which stays inside [0,1] on its own, this one is deliberately allowed to start
// outside it. The (uv - 0.5) * factor terms below (factor in 0...1) always pull *toward* center,
// so a big enough overhang maps back to a genuine, non-edge-clamped sample instead of needing
// `clamp_to_edge` to invent one - the exact same overhang-then-inverse-map trick beat_zoom_uv uses,
// just driven by this effect's own factor instead of beatZoom. outEdgeAlpha softly fades out (via
// wave_dissolve_edge_alpha) the sliver of the overhang where the granted margin still wasn't quite
// enough and oldUV/newUV would've needed actual clamping - so that sliver fades to transparent
// (revealing the wave beneath) instead of showing a stretched, clamp_to_edge-repeated edge.
// `sweepUV` is deliberately a *different* coordinate than `uv`: real projectM's own warp sweeps
// `coord` (and so `x`) across full screen-space UV (see this file's own header on the wave
// texture's coordinate convention), the same space the wave layer underneath is swept in - not
// the small album-local [0,1] square `uv` lives in. Feeding `uv` into the coord/x calculation
// (as this used to) made the sweep race across the album's own tiny square in the time it takes
// the wave to sweep across the whole screen, so the two visibly fell out of sync. `sweepUV` is
// screen-space (`in.texCoord` from the caller) specifically so `x` - and therefore how far the
// sweep has traveled at a given screen position, at a given instant - matches the wave exactly;
// `uv` is still what actually gets zoomed/sampled, since that part does need album-local texture
// coordinates.
inline float4 preset_transition_warp_blend(texture2d<float> oldTex, texture2d<float> newTex, sampler s, float2 uv, float2 sweepUV, float progressCosine, float4 seeds, thread float &outEdgeAlpha)
{
    // *.01 matches the original exactly (mod(float(iRandStatic.x) * .01, 4.)) - see this file's own
    // header on why dropping it picks a different (occasionally mirrored) direction branch below,
    // not just a differently-distributed one.
    float direction = preset_transition_glsl_mod(seeds.x * 0.01, 4.0);
    float coord = direction < 1.0 ? sweepUV.x : (direction < 2.0 ? 1.0 - sweepUV.x : (direction < 3.0 ? sweepUV.y : 1.0 - sweepUV.y));
    float x = smoothstep(0.0, 1.0, progressCosine * 2.0 + coord - 1.0);
    float2 oldUV = (uv - 0.5) * (1.0 - x) + 0.5;
    float2 newUV = (uv - 0.5) * x + 0.5;
    float4 oldSample = oldTex.sample(s, saturate(oldUV));
    float4 newSample = newTex.sample(s, saturate(newUV));
    outEdgeAlpha = mix(wave_dissolve_edge_alpha(oldUV), wave_dissolve_edge_alpha(newUV), x);
    return mix(oldSample, newSample, x);
}

// Exponential_easeInOut(0, 1, 1, t) from TransitionShaderBuiltInZoomBlurGlsl330.frag - the old/new
// crossfade curve zoomBlur's blur taps dissolve along.
inline float preset_transition_exponential_ease_in_out(float t)
{
    float t2 = t * 2.0;
    if (t2 < 1.0) { return 0.5 * pow(2.0, 10.0 * (t2 - 1.0)); }
    return 0.5 * (-pow(2.0, -10.0 * (t2 - 1.0)) + 2.0);
}

// ZoomBlur: radial blur toward screen center, old and new textures crossfaded at each tap as it
// blurs - see TransitionShaderBuiltInZoomBlurGlsl330.frag. Fewer taps than the original (8, not 20)
// since this runs per album-art layer, per pixel, only during a transition.
// Unlike a faithful port of the original (which stays entirely inside the album's own [0,1] square
// on its own - see this function's git history/PR discussion), `uv` here is deliberately allowed to
// arrive with some overhang (see kZoomBlurOverhangBound in the fragment function), so the blur can
// pull in genuine content from past the square's resting edge instead of just streaking within it -
// matching how warp is allowed to bulge past its own square. `rawTapUV` (== uv + toCenter*percent*
// strength, i.e. uv scaled by (1 - percent*strength) about center - the exact same "pull toward
// center" shape beat_zoom_uv/warp use, just with a much shallower factor range since strength never
// exceeds kZoomBlurStrengthConst) is what determines whether a given tap actually landed on real
// texture content; outEdgeAlpha is the same per-tap weighted average as color itself, so a tap that
// needed more overhang than was granted contributes proportionally less alpha instead of a stretched
// clamp_to_edge sample.
inline float4 preset_transition_zoom_blur_blend(texture2d<float> oldTex, texture2d<float> newTex, sampler s, float2 uv, float progressCosine, float2 seedUV, thread float &outEdgeAlpha)
{
    // Sinusoidal_easeInOut(0, kZoomBlurStrengthConst, 0.5, progressCosine) from the original - a
    // half-length duration against a full 0...1 progress gives two full humps across the transition.
    float strength = -kZoomBlurStrengthConst * 0.5 * (cos(kPresetTransitionPi * progressCosine / 0.5) - 1.0);
    float dissolve = preset_transition_exponential_ease_in_out(saturate(progressCosine));

    float2 toCenter = float2(0.5) - uv;
    float offset = fract(sin(dot(seedUV, float2(12.9898, 78.233))) * 43758.5453) * 0.5;

    float4 color = float4(0.0);
    float total = 0.0;
    float edgeAlphaAccum = 0.0;
    constexpr int kTaps = 8;
    for (int t = 0; t < kTaps; t++) {
        float percent = (float(t) + offset) / float(kTaps);
        float weight = percent - percent * percent;
        float2 rawTapUV = uv + toCenter * percent * strength;
        float2 tapUV = saturate(rawTapUV);
        color += mix(oldTex.sample(s, tapUV), newTex.sample(s, tapUV), dissolve) * weight;
        edgeAlphaAccum += wave_dissolve_edge_alpha(rawTapUV) * weight;
        total += weight;
    }
    outEdgeAlpha = total > 0.0001 ? edgeAlphaAccum / total : wave_dissolve_edge_alpha(uv);
    return total > 0.0001 ? color / total : mix(oldTex.sample(s, uv), newTex.sample(s, uv), dissolve);
}

// Dispatches to whichever of the six ported effects is active for one album-art layer, given its
// already-computed "new" (live/current) sample - see this file's own header above. `on` false (no
// transition) and mask-style effects both just consume `fallbackNewSample` (mask-style blends it
// against the old sample; warp/zoomBlur ignore it and sample old/new fresh themselves, since they
// need their own displaced UVs rather than the plain one `fallbackNewSample` was taken at).
// outEdgeAlpha is only ever <1 for warp/zoomBlur (see those two functions' own doc comments) -
// every other path leaves it at 1 and the caller's own plain-UV bounds check is what gates those
// instead.
// noiseSeedUV is screen-space (in.texCoord from every call site) - doubles as zoomBlur's per-pixel
// random-offset seed and warp's sweepUV (see preset_transition_warp_blend's own doc comment on why
// that needs to be screen-space rather than the album-local `uv`).
inline float4 preset_transition_apply(
    bool on, int effect, float reveal, float progressCosine, float4 seeds,
    texture2d<float> oldTex, texture2d<float> newTex, sampler s, float2 uv, float2 noiseSeedUV,
    float4 fallbackNewSample, thread float &outEdgeAlpha)
{
    outEdgeAlpha = 1.0;
    if (!on) { return fallbackNewSample; }
    if (effect == 4) { return preset_transition_warp_blend(oldTex, newTex, s, uv, noiseSeedUV, progressCosine, seeds, outEdgeAlpha); }
    if (effect == 5) { return preset_transition_zoom_blur_blend(oldTex, newTex, s, uv, progressCosine, noiseSeedUV, outEdgeAlpha); }
    return mix(oldTex.sample(s, saturate(uv)), fallbackNewSample, reveal);
}

// Mirrors ProjectMCoordinator's Swift-side AlbumArtUniforms struct field-for-field - keep the two
// in sync if either changes.
struct AlbumArtUniforms {
    float2 waveTexelSize;    // 1/width, 1/height of waveTexture, for neighbor sampling
    float2 artCenter;        // art square's center, in the same [0,1] space as texCoord
    float2 artHalfSize;      // art square's half-width/half-height, same space
    float globalAlpha;       // "H" hidden-toggle / no-track-loaded mute, eased 0...1
    // Which of the four stacked layers are currently on (see this file's own header) - the *only*
    // thing that changes as "M" reveals/hides layers; every layer's own effect below is a fixed
    // constant regardless of visibility.
    float backgroundColorVisible;
    float backgroundDetailVisible;
    float subjectVisible;
    float textVisible;
    // Fixed per-layer effect strengths (ProjectMCoordinator.backgroundColorChromaticAberrationStrength/
    // backgroundDetailDistortionStrength) - the backgroundColor layer's R/G/B channel split and the
    // backgroundDetail layer's wave-gradient UV nudge, respectively. Neither subject nor text
    // carries either of these.
    float chromaticAberrationStrength;
    float distortionStrength;
    // Fades backgroundDetail's alpha out where the wave itself is bright (waveLuma below) - see
    // this file's own backgroundDetail comment and ProjectMCoordinator's mirrored fields.
    float distortionAlphaLow;
    float distortionAlphaHigh;
    // Drives two things below, both in the backgroundDetail chromatic aberration: slowly rotates
    // aberrationDir independent of the wave gradient, and (reused as-is, not a second phase) sets
    // each channel's own offset magnitude via channelScaleR/G/B's cosines, so the whole effect
    // continuously cycles hue as this angle advances (see ProjectMCoordinator.
    // aberrationRotationPeriod and this file's own backgroundDetail comment).
    float aberrationAngle;
    // Audio-driven "punch" envelope (ProjectMCoordinator.beatPulse - snaps up on a fresh bass hit,
    // decays linearly otherwise) and every layer's own zoom response to it - strictly descending
    // front-to-back (primaryBeatZoomStrength > secondaryBeatZoomStrength > tertiaryBeatZoomStrength
    // > backgroundColorBeatZoomStrength) for whichever layers this cover actually has, so the
    // frontmost surviving layer always punches inward the most and backgroundColor always barely
    // moves - see this file's own header and ProjectMCoordinator.resampleBeatZoomStrengths. Which
    // named field ends up carrying the largest value depends on this cover's actual layers (e.g. a
    // subject-less cover has secondaryBeatZoomStrength, not primaryBeatZoomStrength, as the largest) -
    // don't assume primaryBeatZoomStrength is always the max (see maxBeatZoomStrength below).
    float beatPulse;
    float backgroundColorBeatZoomStrength;
    float tertiaryBeatZoomStrength;
    float secondaryBeatZoomStrength;
    float primaryBeatZoomStrength;
    // Whether the previous track's art is concurrently dissolving away underneath everything above
    // - see this file's own header. Always 0 today.
    float outgoingActive;
    float outgoingProgress;
    // Drives the preset-transition album-art effect - see this file's own header above and
    // ProjectMCoordinator.PresetTransitionEffect/presetTransitionActiveAndProgress.
    // presetTransitionRandomSeeds mirrors real projectM's iRandStatic (TransitionShaderHeaderGlsl330
    // .frag) - four values picked once per transition, held fixed for its whole duration.
    float presetTransitionActive;
    float presetTransitionProgress;
    float presetTransitionEffect;
    float4 presetTransitionRandomSeeds;
};

fragment float4 projectm_composite_fragment(ProjectMPassthroughVaryings in [[stage_in]],
                                             texture2d<float> waveTexture [[texture(0)]],
                                             texture2d<float> backgroundColorArtTexture [[texture(1)]],
                                             texture2d<float> backgroundDetailArtTexture [[texture(2)]],
                                             texture2d<float> subjectArtTexture [[texture(3)]],
                                             texture2d<float> textArtTexture [[texture(4)]],
                                             texture2d<float> outgoingArtTexture [[texture(5)]],
                                             texture2d<float> oldBackgroundDetailArtTexture [[texture(6)]],
                                             texture2d<float> oldSubjectArtTexture [[texture(7)]],
                                             texture2d<float> oldTextArtTexture [[texture(8)]],
                                             constant AlbumArtUniforms &u [[buffer(0)]])
{
    constexpr sampler waveSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    constexpr sampler artSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float4 wave = waveTexture.sample(waveSampler, in.texCoord);

    bool outgoingActive = u.outgoingActive > 0.5;
    // presetTransitionOn/transitionEffect/transitionProgressCosine are needed up front now (by
    // kWarpOverhangBound below) - see this file's own header and PresetTransitionEffect's doc
    // comment (ProjectMCoordinator.swift) for what each effect index means. transitionReveal (the
    // other half of what used to be computed together further down) still waits until after the
    // early-exit below, since it's only needed for pixels that pass it.
    bool presetTransitionOn = u.presetTransitionActive > 0.5;
    int transitionEffect = int(round(u.presetTransitionEffect));
    bool warpActive = presetTransitionOn && transitionEffect == 4;
    bool zoomBlurActive = presetTransitionOn && transitionEffect == 5;
    float transitionProgressCosine = presetTransitionOn
        ? (-cos(saturate(u.presetTransitionProgress) * kPresetTransitionPi) + 1.0) * 0.5 : 0.0;

    // Beat zoom can magnify a layer past its own fixed artCenter/artHalfSize square - grant a
    // matching overhang margin here so that doesn't get clipped right back to the square's
    // original edge (half of (scale - 1) is exactly how far past [0,1] artUV the zoomed content
    // reaches - see subjectUV below). Sized off whichever of the three per-layer strengths is
    // actually largest *this frame* - primaryBeatZoomStrength no longer always wins on its own now
    // that ProjectMCoordinator.resampleBeatZoomStrengths can hand the top-of-stack value to
    // whichever of subject/text/backgroundDetail this cover actually has (e.g. a cover with no
    // subject has secondaryBeatZoomStrength carrying it instead). backgroundColor is excluded -
    // it's disabled (see NowPlayingManager.recomputeDerivedAlbumArtLayers), never actually sampled
    // below, so its strength can't be the frame's real max regardless of what the uniform holds.
    // The outgoing track's own dissolve keeps its preexisting generous margin for its scatter.
    float maxBeatZoomStrength = max(
        u.primaryBeatZoomStrength, max(u.secondaryBeatZoomStrength, u.tertiaryBeatZoomStrength)
    );
    float beatZoomBound = u.beatPulse * maxBeatZoomStrength * 0.5;
    // warp's own center-relative zoom (preset_transition_warp_blend) is the exact same kind of
    // "can magnify past the square" effect beatZoom is (see that function's own doc comment) - but
    // its factor is spatially swept across the screen (varies with `coord`, not one scalar the way
    // beatPulse is), so there's no single tight bound to compute up front the way beatZoomBound
    // has one. kWarpOverhangBound is a generous fixed stand-in instead, big enough that only the
    // faintest (~10% weight) fringe of old/new content ever still needs more than it grants -
    // preset_transition_warp_blend's own outEdgeAlpha (see below) softly fades out that fringe
    // rather than showing a stretched clamp_to_edge repeat there. warpOverhangFade tapers this
    // margin smoothly back to 0 over the first/last 10% of the transition's own progress, so the
    // margin (and the rendering path that relies on it) is already back to baseline several frames
    // *before* the engine flips presetTransitionActive off - without it, whatever margin was still
    // in use on the last active frame would vanish in a single frame the moment the flag flips,
    // reading as the art abruptly despawning rather than finishing its zoom back to normal.
    // zoomBlur's own radial pull (preset_transition_zoom_blur_blend) is the exact same shape as
    // beatZoom/warp's - uv scaled by (1 - percent*strength) about center - just with a much
    // shallower factor range, since its strength never exceeds kZoomBlurStrengthConst (unlike
    // warp's, which can reach 0). That means, unlike warp, the exact margin it needs *can* be
    // computed analytically each frame from strength alone (0.5*(1/(1-strength) - 1), the same
    // "how far past [0,1] does this factor's magnified content reach" formula from beat_zoom_uv's
    // own doc comment) rather than needing a generous fixed stand-in - and since strength is 0 at
    // both progressCosine 0 and 1 by construction (see that function's own comment), this margin
    // already tapers to 0 smoothly at both ends on its own, with no separate fade needed the way
    // warpOverhangFade provides for warp's unrelated fixed constant.
    float zoomBlurStrength = zoomBlurActive
        ? -kZoomBlurStrengthConst * 0.5 * (cos(kPresetTransitionPi * transitionProgressCosine / 0.5) - 1.0) : 0.0;
    float zoomBlurOverhangBound = zoomBlurActive ? 0.5 * (1.0 / (1.0 - zoomBlurStrength) - 1.0) : 0.0;
    constexpr float kWarpOverhangBound = 2.5;
    float warpOverhangFade = warpActive
        ? min(smoothstep(0.0, 0.1, transitionProgressCosine), smoothstep(0.0, 0.1, 1.0 - transitionProgressCosine))
        : 0.0;
    float bound = max(outgoingActive ? 1.0 : 0.0, max(beatZoomBound, max(kWarpOverhangBound * warpOverhangFade, zoomBlurOverhangBound)));
    float2 artUV = (in.texCoord - u.artCenter) / (u.artHalfSize * 2.0) + 0.5;
    if (artUV.x < -bound || artUV.x > 1.0 + bound
        || artUV.y < -bound || artUV.y > 1.0 + bound
        || u.globalAlpha <= 0.0) {
        return wave;
    }

    float3 luma = float3(0.299, 0.587, 0.114);
    float2 waveGradient = sample_wave_gradient(waveTexture, waveSampler, in.texCoord, u.waveTexelSize, luma);

    // Preset-transition album-art effect - see this file's own header above. transitionReveal is
    // shared by all three layers below (screen-space, so the same wipe/noise/etc. shape lines up
    // across all of them at a given pixel) - only meaningful for the four mask-style effects
    // (0-3); warp/zoomBlur (4/5) compute their own per-layer blend entirely inside
    // preset_transition_apply instead. transitionProgressCosine itself was already computed above,
    // before the early-exit, since kWarpOverhangBound needs it too.
    float transitionReveal = 0.0;
    if (presetTransitionOn) {
        if (transitionEffect <= 3) {
            float screenW = 1.0 / u.waveTexelSize.x;
            float screenH = 1.0 / u.waveTexelSize.y;
            float screenAspect = screenH / screenW;
            // Index order mirrors real projectM's Renderer::TransitionShaderManager construction
            // order exactly (see PresetTransitionEffect's own doc comment in ProjectMCoordinator.
            // swift) - 0 Circle, 1 Plasma, 2 SimpleBlend, 3 Sweep - so the index read straight off
            // the engine needs no remapping here.
            if (transitionEffect == 0) {
                transitionReveal = preset_transition_mask_circle(in.texCoord, screenAspect, transitionProgressCosine, u.presetTransitionRandomSeeds);
            } else if (transitionEffect == 1) {
                transitionReveal = preset_transition_mask_plasma(in.texCoord, screenAspect, transitionProgressCosine, u.presetTransitionRandomSeeds);
            } else if (transitionEffect == 2) {
                transitionReveal = transitionProgressCosine;
            } else {
                transitionReveal = preset_transition_mask_sweep(in.texCoord, transitionProgressCosine, u.presetTransitionRandomSeeds);
            }
        }
    }

    // Outgoing layer: the previous track, still dissolving away on its own independent clock - see
    // this file's own header. Computed first (and composited underneath everything else) so it
    // reads as the art that was already there getting swept aside as new art arrives on top of it.
    float4 outArt = float4(0.0);
    float outAlpha = 0.0;
    if (outgoingActive) {
        float ease = u.outgoingProgress * u.outgoingProgress;
        float2 sourceUV = wave_dissolve_walk(waveTexture, waveSampler, artUV, ease, u.artCenter, u.artHalfSize, u.waveTexelSize, luma);
        float edgeAlpha = wave_dissolve_edge_alpha(sourceUV);
        outArt = outgoingArtTexture.sample(artSampler, saturate(sourceUV));
        // An explicit, whole-graphic fade keyed on outgoingProgress alone (not the walk), so it's
        // guaranteed to hit exactly 0 opacity the same instant the dissolve ends, regardless of
        // what any individual pixel's walk happened to do. sqrt front-loads the fade so it visibly
        // vanishes early rather than staying near-opaque for most of the exit.
        float exitOpacity = 1.0 - sqrt(saturate(u.outgoingProgress));
        outAlpha = outArt.a * edgeAlpha * exitOpacity;
    }

    // backgroundColor layer: disabled (see NowPlayingManager.recomputeDerivedAlbumArtLayers) -
    // backgroundColorArtwork is always nil now, so backgroundColorArtTexture is always the empty
    // transparent stand-in and this layer never contributes anything to the composite below.
    // backgroundDetail is the new base of the "over" chain instead - see that block below. Uncomment
    // to bring this layer back (and restore it as the compositing base, undoing that change too).
    // float2 backgroundColorZoomedUV = beat_zoom_uv(artUV, u.beatPulse, u.backgroundColorBeatZoomStrength);
    // bool backgroundColorInBounds = all(backgroundColorZoomedUV >= 0.0) && all(backgroundColorZoomedUV <= 1.0);
    // float4 backgroundColorSample = backgroundColorArtTexture.sample(artSampler, saturate(backgroundColorZoomedUV));
    // float backgroundColorA = backgroundColorInBounds ? backgroundColorSample.a * u.backgroundColorVisible : 0.0;

    // backgroundDetail layer: beat zoom (second-smallest) plus wave-gradient UV distortion (a
    // cheap refraction/heat-haze trick where a hard edge or bright streak in the wave visibly
    // pushes this layer around, so it reads as embedded in the wave rather than merely stacked on
    // top of it) plus chromatic aberration. R, G, and B are each sampled at their own offset along
    // the wave gradient's *direction* (aberrationDir below, itself further rotated by
    // aberrationAngle so it slowly spins independent of the gradient), but each channel's offset
    // *magnitude* is separately modulated by its own cosine of aberrationAngle, the three cosines
    // 120 degrees out of phase with each other (channelScaleR/G/B below). Since three cosines spaced
    // 120 degrees apart always sum to ~0, at any instant this nets out to roughly two channels
    // pushed oppositely and the third near zero - but which channel is near zero continuously drifts
    // (R -> G -> B -> R -> ...) as aberrationAngle advances, and every step of that drift is a plain
    // cosine, so the whole effect eases smoothly through every hue with no discrete jump - nothing
    // is ever permanently anchored to a fixed channel the way a hard R/B-only split (or a stepped
    // R/B -> G/R -> B/G switch) would leave one channel statically un-shifted. Alpha alone is always
    // left at the undisplaced center sample - shifting alpha too would fringe the layer's own edge
    // with ghost partial-transparency rather than just color, which reads as a glitch rather than a
    // lens effect. Both of backgroundColor's would-be effects landed here instead - see the NOTE on
    // backgroundColor above for why. Normalized (rather than scaled by the gradient's own magnitude,
    // like the distortion below) because a static color split needs a much bigger,
    // gradient-magnitude-independent offset to read as separated color at all - scaling it down in
    // calm, low-contrast regions of the wave would make it disappear almost everywhere. Falls back
    // to a fixed horizontal split (before rotation), same as wave_dissolve_walk's own fallbackDir,
    // wherever the local gradient is too weak to give a reliable direction. Aberration is sampled
    // post-distortion (offset from `backgroundDetailUV`,
    // not the undistorted `backgroundDetailZoomedUV`) so the two effects compose rather than fight
    // over the base UV.
    float gLen = length(waveGradient);
    float2 aberrationDir = gLen > 0.0001 ? (waveGradient / gLen) : float2(1.0, 0.0);
    // Rotate by aberrationAngle (see AlbumArtUniforms) so the split direction slowly spins
    // independent of the wave gradient, rather than sitting fixed on whatever direction the
    // gradient happens to pick.
    float sinA = sin(u.aberrationAngle);
    float cosA = cos(u.aberrationAngle);
    aberrationDir = float2(
        aberrationDir.x * cosA - aberrationDir.y * sinA,
        aberrationDir.x * sinA + aberrationDir.y * cosA
    );
    // See the comment above: reusing aberrationAngle again here (rather than a second, independent
    // phase) ties the hue cycle's period to the same rotation as the direction spin - one knob,
    // two coupled motions, still reads as a single coherent "spinning prism" rather than two
    // motions drifting in and out of sync.
    const float kThirdTurn = 2.0943951023931953; // 2*pi/3
    float channelScaleR = cos(u.aberrationAngle);
    float channelScaleG = cos(u.aberrationAngle - kThirdTurn);
    float channelScaleB = cos(u.aberrationAngle - 2.0 * kThirdTurn);
    float2 backgroundDetailZoomedUV = beat_zoom_uv(artUV, u.beatPulse, u.tertiaryBeatZoomStrength);
    float2 backgroundDetailUV = backgroundDetailZoomedUV + waveGradient * u.distortionStrength;
    bool backgroundDetailInBounds = all(backgroundDetailUV >= 0.0) && all(backgroundDetailUV <= 1.0);
    float4 backgroundDetailCenter = backgroundDetailArtTexture.sample(artSampler, saturate(backgroundDetailUV));
    // Softens each channel's offset copy (see sample_channel_soft above) rather than leaving it a
    // crisp point/bilinear sample - scaled off chromaticAberrationStrength itself so a bigger split
    // gets a proportionally softer edge instead of a fixed blur that's invisible at large splits or
    // mushy at small ones. Always computed (even during a warp/zoomBlur transition, which ends up
    // discarding it) - simpler than threading a second "skip aberration" path through, and the cost
    // only shows up during the occasional transition.
    float2 aberrationBlur = float2(u.chromaticAberrationStrength * 0.35);
    float backgroundDetailR = sample_channel_soft(backgroundDetailArtTexture, artSampler, saturate(backgroundDetailUV + aberrationDir * channelScaleR * u.chromaticAberrationStrength), aberrationBlur, 0);
    float backgroundDetailG = sample_channel_soft(backgroundDetailArtTexture, artSampler, saturate(backgroundDetailUV + aberrationDir * channelScaleG * u.chromaticAberrationStrength), aberrationBlur, 1);
    float backgroundDetailB = sample_channel_soft(backgroundDetailArtTexture, artSampler, saturate(backgroundDetailUV + aberrationDir * channelScaleB * u.chromaticAberrationStrength), aberrationBlur, 2);
    float4 backgroundDetailNewSample = float4(backgroundDetailR, backgroundDetailG, backgroundDetailB, backgroundDetailCenter.a);
    float backgroundDetailEdgeAlpha = 1.0;
    float4 backgroundDetailSample = preset_transition_apply(
        presetTransitionOn, transitionEffect, transitionReveal, transitionProgressCosine, u.presetTransitionRandomSeeds,
        oldBackgroundDetailArtTexture, backgroundDetailArtTexture, artSampler, backgroundDetailUV, in.texCoord, backgroundDetailNewSample,
        backgroundDetailEdgeAlpha
    );
    // Punch a hole through backgroundDetail wherever the wave itself is bright at this pixel,
    // revealing the (usually far more colorful) wave layer beneath instead of just warping this
    // layer's own content there. `wave`/`luma` already sampled/defined above for the rest of this
    // function.
    float waveLuma = dot(wave.rgb, luma);
    float distortionAlphaMul = 1.0 - smoothstep(u.distortionAlphaLow, u.distortionAlphaHigh, waveLuma);
    // warp/zoomBlur use their own softly-fading edge alpha (see those two functions' own doc
    // comments) instead of this plain UV's own [0,1] containment, which - now that the outer bound
    // above grants both real overhang - is frequently and correctly false out there (see
    // kWarpOverhangBound/zoomBlurOverhangBound and warpActive/zoomBlurActive above).
    float backgroundDetailBoundsAlpha = (warpActive || zoomBlurActive) ? backgroundDetailEdgeAlpha : (backgroundDetailInBounds ? 1.0 : 0.0);
    float backgroundDetailA = backgroundDetailBoundsAlpha * backgroundDetailSample.a * u.backgroundDetailVisible * distortionAlphaMul;

    // text layer: beat zoom only (second-largest) - no other effect, so the text itself never
    // warps or fringes, just moves with the parallax punch.
    float2 textUV = beat_zoom_uv(artUV, u.beatPulse, u.secondaryBeatZoomStrength);
    bool textInBounds = all(textUV >= 0.0) && all(textUV <= 1.0);
    float4 textNewSample = textArtTexture.sample(artSampler, saturate(textUV));
    float textEdgeAlpha = 1.0;
    float4 textSample = preset_transition_apply(
        presetTransitionOn, transitionEffect, transitionReveal, transitionProgressCosine, u.presetTransitionRandomSeeds,
        oldTextArtTexture, textArtTexture, artSampler, textUV, in.texCoord, textNewSample,
        textEdgeAlpha
    );
    float textBoundsAlpha = (warpActive || zoomBlurActive) ? textEdgeAlpha : (textInBounds ? 1.0 : 0.0);
    float textA = textBoundsAlpha * textSample.a * u.textVisible;

    // subject layer: beat zoom only, and the largest of the four when this cover actually has a
    // subject (see maxBeatZoomStrength above) - the "closest to camera" layer in the parallax
    // stack, so it punches inward the most.
    float2 subjectUV = beat_zoom_uv(artUV, u.beatPulse, u.primaryBeatZoomStrength);
    bool subjectInBounds = all(subjectUV >= 0.0) && all(subjectUV <= 1.0);
    float4 subjectNewSample = subjectArtTexture.sample(artSampler, saturate(subjectUV));
    float subjectEdgeAlpha = 1.0;
    float4 subjectSample = preset_transition_apply(
        presetTransitionOn, transitionEffect, transitionReveal, transitionProgressCosine, u.presetTransitionRandomSeeds,
        oldSubjectArtTexture, subjectArtTexture, artSampler, subjectUV, in.texCoord, subjectNewSample,
        subjectEdgeAlpha
    );
    float subjectBoundsAlpha = (warpActive || zoomBlurActive) ? subjectEdgeAlpha : (subjectInBounds ? 1.0 : 0.0);
    float subjectA = subjectBoundsAlpha * subjectSample.a * u.subjectVisible;

    // Standard sequential "over" compositing, bottom to top: backgroundDetail, text, subject - so
    // subject is always the topmost layer whenever it's visible, text just underneath it.
    // backgroundDetail is the base now, not a mix-in - backgroundColor (which used to sit beneath
    // it) is disabled, see this file's own backgroundColor-layer comment above. Correct regardless
    // of how many layers are actually on at once (see ProjectMCoordinator.displayVisibleLayerCount
    // - "M" reveals from the bottom up: backgroundDetail, +text, +subject, or peels back down to
    // nothing).
    float3 color = backgroundDetailSample.rgb;
    float alpha = backgroundDetailA;
    color = mix(color, textSample.rgb, textA);
    alpha = textA + alpha * (1.0 - textA);
    color = mix(color, subjectSample.rgb, subjectA);
    alpha = subjectA + alpha * (1.0 - subjectA);

    alpha *= saturate(u.globalAlpha);
    outAlpha *= saturate(u.globalAlpha);

    // Outgoing under everything above: the departing track shows through wherever nothing above
    // has covered it yet.
    float3 colorWithOutgoing = mix(wave.rgb, outArt.rgb, saturate(outAlpha));
    return float4(mix(colorWithOutgoing, color, saturate(alpha)), 1.0);
}
