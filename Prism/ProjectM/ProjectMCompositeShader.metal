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
};

fragment float4 projectm_composite_fragment(ProjectMPassthroughVaryings in [[stage_in]],
                                             texture2d<float> waveTexture [[texture(0)]],
                                             texture2d<float> backgroundColorArtTexture [[texture(1)]],
                                             texture2d<float> backgroundDetailArtTexture [[texture(2)]],
                                             texture2d<float> subjectArtTexture [[texture(3)]],
                                             texture2d<float> textArtTexture [[texture(4)]],
                                             texture2d<float> outgoingArtTexture [[texture(5)]],
                                             constant AlbumArtUniforms &u [[buffer(0)]])
{
    constexpr sampler waveSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    constexpr sampler artSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float4 wave = waveTexture.sample(waveSampler, in.texCoord);

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
    bool outgoingActive = u.outgoingActive > 0.5;
    float maxBeatZoomStrength = max(
        u.primaryBeatZoomStrength, max(u.secondaryBeatZoomStrength, u.tertiaryBeatZoomStrength)
    );
    float beatZoomBound = u.beatPulse * maxBeatZoomStrength * 0.5;
    float bound = max(outgoingActive ? 1.0 : 0.0, beatZoomBound);
    float2 artUV = (in.texCoord - u.artCenter) / (u.artHalfSize * 2.0) + 0.5;
    if (artUV.x < -bound || artUV.x > 1.0 + bound
        || artUV.y < -bound || artUV.y > 1.0 + bound
        || u.globalAlpha <= 0.0) {
        return wave;
    }

    float3 luma = float3(0.299, 0.587, 0.114);
    float2 waveGradient = sample_wave_gradient(waveTexture, waveSampler, in.texCoord, u.waveTexelSize, luma);

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
    // mushy at small ones.
    float2 aberrationBlur = float2(u.chromaticAberrationStrength * 0.35);
    float backgroundDetailR = sample_channel_soft(backgroundDetailArtTexture, artSampler, saturate(backgroundDetailUV + aberrationDir * channelScaleR * u.chromaticAberrationStrength), aberrationBlur, 0);
    float backgroundDetailG = sample_channel_soft(backgroundDetailArtTexture, artSampler, saturate(backgroundDetailUV + aberrationDir * channelScaleG * u.chromaticAberrationStrength), aberrationBlur, 1);
    float backgroundDetailB = sample_channel_soft(backgroundDetailArtTexture, artSampler, saturate(backgroundDetailUV + aberrationDir * channelScaleB * u.chromaticAberrationStrength), aberrationBlur, 2);
    float4 backgroundDetailSample = float4(backgroundDetailR, backgroundDetailG, backgroundDetailB, backgroundDetailCenter.a);
    // Punch a hole through backgroundDetail wherever the wave itself is bright at this pixel,
    // revealing the (usually far more colorful) wave layer beneath instead of just warping this
    // layer's own content there. `wave`/`luma` already sampled/defined above for the rest of this
    // function.
    float waveLuma = dot(wave.rgb, luma);
    float distortionAlphaMul = 1.0 - smoothstep(u.distortionAlphaLow, u.distortionAlphaHigh, waveLuma);
    float backgroundDetailA = backgroundDetailInBounds ? backgroundDetailSample.a * u.backgroundDetailVisible * distortionAlphaMul : 0.0;

    // text layer: beat zoom only (second-largest) - no other effect, so the text itself never
    // warps or fringes, just moves with the parallax punch.
    float2 textUV = beat_zoom_uv(artUV, u.beatPulse, u.secondaryBeatZoomStrength);
    bool textInBounds = all(textUV >= 0.0) && all(textUV <= 1.0);
    float4 textSample = textArtTexture.sample(artSampler, saturate(textUV));
    float textA = textInBounds ? textSample.a * u.textVisible : 0.0;

    // subject layer: beat zoom only, and the largest of the four when this cover actually has a
    // subject (see maxBeatZoomStrength above) - the "closest to camera" layer in the parallax
    // stack, so it punches inward the most.
    float2 subjectUV = beat_zoom_uv(artUV, u.beatPulse, u.primaryBeatZoomStrength);
    bool subjectInBounds = all(subjectUV >= 0.0) && all(subjectUV <= 1.0);
    float4 subjectSample = subjectArtTexture.sample(artSampler, saturate(subjectUV));
    float subjectA = subjectInBounds ? subjectSample.a * u.subjectVisible : 0.0;

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
