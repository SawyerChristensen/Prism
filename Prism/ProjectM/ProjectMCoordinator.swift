//
//  ProjectMCoordinator.swift
//  Prism
//
//  Replaces MilkdropMetalCoordinator for the new engine. Deliberately simpler than the old one:
//  MilkdropMetalCoordinator kept two full parallel MilkdropMetalRenderer instances
//  (activeRenderer/outgoingRenderer) and cross-faded them in Swift, because the old hand-rolled
//  engine had no concept of blending two presets itself. Real projectM does preset transitions
//  internally on a single persistent instance (smooth_transition, per ProjectMEngine.loadPreset) -
//  so one ProjectMEngine, created once, lives for this coordinator's whole lifetime, and "loading a
//  new preset" is just a call on that same engine, not constructing a new renderer object.
//

import AppKit
import MetalKit
import IOSurface
import QuartzCore

/// Mirrors ProjectMCompositeShader.metal's AlbumArtUniforms struct field-for-field. The four-style
/// cycle's own four layers (backgroundColor/backgroundDetail/subject/text - see
/// AlbumArtLayerCount) are always sampled, always with the same fixed per-layer effect(s); only the
/// four `*Visible` flags below change with the current reveal count.
private struct AlbumArtUniforms {
    var waveTexelSize: SIMD2<Float>
    var artCenter: SIMD2<Float>
    var artHalfSize: SIMD2<Float>
    var globalAlpha: Float
    var backgroundColorVisible: Float
    var backgroundDetailVisible: Float
    var subjectVisible: Float
    var textVisible: Float
    // Fixed effect strengths (ProjectMCoordinator.backgroundColorChromaticAberrationStrength/
    // backgroundDetailDistortionStrength - both named for historical reasons, not where they're
    // actually applied) - the R/B channel split (normalized wave-gradient direction) and the
    // wave-gradient UV nudge, both applied to backgroundDetail only. backgroundColor carries
    // neither: it's a flat fill with no internal color variation for either to act on (see the
    // shader's own backgroundColor sampling comment). Subject and text carry neither either - but
    // every layer carries its own beat-zoom strength below.
    var chromaticAberrationStrength: Float
    var distortionStrength: Float
    // Fades backgroundDetail's own alpha out wherever the wave itself is bright at that pixel, so a
    // bright streak/bloom in the wave punches a hole straight through the artwork there instead of
    // just warping it - revealing the (usually much more colorful) wave layer beneath.
    // smoothstep(distortionAlphaLow, distortionAlphaHigh, waveLuma) - see
    // ProjectMCoordinator.backgroundDetailDistortionAlphaLow/High.
    var distortionAlphaLow: Float
    var distortionAlphaHigh: Float
    // Slowly rotates the aberration's R/B split direction independent of the wave gradient (see
    // ProjectMCoordinator.aberrationRotationPeriod) - a "spinning prism" feel layered on top of the
    // gradient-driven direction, computed fresh from CACurrentMediaTime each frame in draw(in:).
    var aberrationAngle: Float
    // Audio-driven "punch" envelope (see beatPulse's own doc comment) and every layer's own zoom
    // response to it - a parallax stack where the layer closest to the "camera" punches inward the
    // most on a fresh bass hit and each layer underneath it moves less, down to backgroundColor
    // (bottom of the stack) barely moving at all. backgroundColorBeatZoomStrength is a fixed
    // constant, but the other three are resampled per track (see
    // ProjectMCoordinator.resampleBeatZoomStrengths) from this cover's actual subject/text/
    // backgroundDetail layer count, not tied to those specific named layers - always strictly
    // descending and always <= ProjectMCoordinator.primaryBeatZoomStrength, so the depth ordering
    // always reads correctly regardless of how many layers this cover actually has or how hard a
    // given track hits.
    var beatPulse: Float
    var backgroundColorBeatZoomStrength: Float
    var tertiaryBeatZoomStrength: Float
    var secondaryBeatZoomStrength: Float
    var primaryBeatZoomStrength: Float
    // Whether the previous track's art is concurrently dissolving away underneath everything above
    // - a separate, pre-existing dormant feature (see ProjectMCompositeShader.metal's own header)
    // this four-style cycle doesn't touch; outgoingActive is always 0 today (see draw(in:)).
    var outgoingActive: Float
    var outgoingProgress: Float
    // Drives the album-art preset-transition effect - see PresetTransitionEffect and
    // presetTransitionActiveAndProgress. presetTransitionRandomSeeds mirrors real projectM's own
    // iRandStatic (Renderer/TransitionShaders/TransitionShaderHeaderGlsl330.frag) - four values
    // picked once per transition, held fixed for its whole duration, used by the ported effects to
    // pick a random angle/direction/blend-width the same way the real shaders do.
    var presetTransitionActive: Float
    var presetTransitionProgress: Float
    var presetTransitionEffect: Float
    var presetTransitionRandomSeeds: SIMD4<Float>
}

/// The three stages of the *incoming* track's own choreography (see ProjectMCompositeShader.metal's
/// own header) - raw Float, not an enum, since it's written straight into AlbumArtUniforms.stage.
/// The previous track's exit is no longer one of these - it runs concurrently as its own layer, see
/// AlbumArtUniforms.outgoingActive.
private enum AlbumArtStage {
    static let scaleIn: Float = 0
    static let separate: Float = 1
    static let steady: Float = 2
}

/// The four intro choreographies stage 0 can play - raw Float, not an enum, for consistency with
/// AlbumArtStage above. Resolved into subjectScale/backgroundScale/subjectOffset/backgroundOffset
/// on the Swift side (see albumArtScales/albumArtOffsets) before crossing into AlbumArtUniforms -
/// the shader itself no longer branches on which style this is, since all four now share the same
/// dissolve/opacity/distortion treatment and differ only in that resolved scale/offset math.
private enum AlbumArtIntroStyle {
    static let forward: Float = 0
    static let reverseScale: Float = 1
    static let slideRight: Float = 2
    static let slideDown: Float = 3
    static let all: [Float] = [forward, reverseScale, slideRight, slideDown]
}

/// Which of real projectM's 6 built-in preset-transition effects (Vendor/projectm/src/libprojectM/
/// Renderer/TransitionShaders/*.frag) the *current* preset transition is actually using - raw
/// Float, same convention as AlbumArtStage/AlbumArtIntroStyle above, since it crosses straight into
/// AlbumArtUniforms.presetTransitionEffect. Read live from the engine every frame (see
/// ProjectMEngine.presetTransitionShaderIndex, backed by the PRISM_LOCAL_PATCH documented in
/// Vendor/projectm-VERSION.md's "exposed preset-transition state" entry) rather than picked
/// independently here - this constant ordering mirrors Renderer::TransitionShaderManager's own
/// construction order exactly (TransitionShaderManager.cpp), so the raw index read off the engine
/// lines up with these names with no remapping. circle/plasma/simpleBlend/sweep are spatial reveal
/// masks - how much of the *new* album art shows through the old, at a given pixel, in that
/// effect's own shape; warp/zoomBlur are geometric distortions applied to the album art's own
/// texture sampling instead - see the shader's own header for the full breakdown.
private enum PresetTransitionEffect {
    static let circle: Float = 0
    static let plasma: Float = 1
    static let simpleBlend: Float = 2
    static let sweep: Float = 3
    static let warp: Float = 4
    static let zoomBlur: Float = 5
}

/// ContentView's four-style manual preview cycle ("M") — four independent layers, permanently
/// stacked in this fixed order, top to bottom: subject, text, backgroundDetail, backgroundColor
/// (see ProjectMCompositeShader.metal's compositing, and NowPlayingManager.subjectOnlyArtwork/
/// textOnlyArtwork/backgroundDetailArtwork/backgroundColorArtwork for what each one actually
/// shows — all four are fully separated, non-overlapping pieces of the cover, not the whole photo
/// repeated across layers). backgroundColor always carries the same fixed beat-zoom "movement"
/// strength (backgroundColorBeatZoomStrength); the other three (subject/text/backgroundDetail)
/// share a per-track *resampled* strength instead of each having its own fixed one - see
/// resampleBeatZoomStrengths's own doc comment. A cover missing one of those three (no Vision
/// subject, no OCR text) doesn't leave a gap: whichever of the three actually exist for this cover
/// are re-ranked top-to-bottom starting from 1, and share out the same top-to-bottom strength
/// falloff (primaryBeatZoomStrength -> secondaryBeatZoomStrength -> tertiaryBeatZoomStrength)
/// as if the stack only ever had that many layers - so a cover with only backgroundDetail (no
/// subject or text) has it moving at the full primaryBeatZoomStrength, not the small
/// tertiaryBeatZoomStrength it'd get if all three existed. This is independent of "M"'s
/// own reveal count below - resampling is about how hard each layer *punches when visible*, not
/// whether it's currently revealed. Separately, backgroundDetail specifically also carries two
/// further fixed effects on top of its movement (ProjectMCoordinator's
/// backgroundColorChromaticAberrationStrength/backgroundDetailDistortionStrength - both named for
/// historical reasons; backgroundColor is a flat fill with nothing for either to visibly act on).
/// "M" doesn't pick a named style or swap any layer's
/// content/effect - it just reveals or hides layers starting from the *bottom* of the stack: press
/// it and the bottom-most currently-visible layer drops out (4 visible -> 3 -> 2 -> 1 -> 0 -> back
/// to all 4), so pressing through the whole cycle peels the flat background color away first, then
/// the color-keyed background detail under the subject, then the static text, leaving just the
/// beat-zooming subject alone, then nothing, then wraps back to everything. `displayVisibleLayerCount`
/// (below) is that count, 0...4; a layer's on/off state is just "is my position in the stack
/// (backgroundColor=1, backgroundDetail=2, text=3, subject=4, counting from the bottom) at or below
/// the current count."
enum AlbumArtLayerCount {
    static let all = 4
}

final class ProjectMCoordinator: NSObject, MTKViewDelegate {
    private let engine: ProjectMEngine?
    private let audioEngine: CoreAudioTapEngine
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    // Cached Metal wrap of the engine's current IOSurface render target - only needs rebuilding
    // when the size changes or the engine hands back a different underlying surface (a resize),
    // not every frame (see ProjectMEGLContext.framebufferForWidth:height:'s matching cache).
    private var cachedTexture: MTLTexture?
    private var cachedIOSurface: IOSurface?
    private var cachedWidth = 0
    private var cachedHeight = 0

    // Album art choreography - see ProjectMCompositeShader.metal's header for the incoming track's
    // three stages plus the outgoing track's independent, concurrent exit layer, and
    // advanceAlbumArtAnimation below for the state machine that drives them. emptyAlbumArtTexture
    // stands in for any texture slot with nothing real to show, so the shader always runs the same
    // code path rather than branching per-frame on "has art or not."
    private static let scaleInDuration: Float = 2.0
    private static let separateDuration: Float = 2.0
    private static let subjectExitDuration: Float = 2.0
    private static let albumArtSizePixels: Float = 480
    private static let globalAlphaEaseSpeed: Float = 8
    // The four-style cycle's own fixed per-layer effect strengths (see AlbumArtLayerCount) -
    // always applied at these same values whether or not that layer is currently visible; only
    // visibility itself is what "M" actually toggles.
    private static let backgroundColorChromaticAberrationStrength: Float = 0.005
    private static let backgroundDetailDistortionStrength: Float = 0.05
    // Seconds for aberrationAngle (see AlbumArtUniforms) to complete one full rotation.
    private static let aberrationRotationPeriod: Double = 8.0
    // smoothstep bounds for backgroundDetail's wave-brightness-driven alpha fade (see
    // AlbumArtUniforms.distortionAlphaLow/High) - waveLuma sits in 0...1.
    private static let backgroundDetailDistortionAlphaLow: Float = 0.2
    private static let backgroundDetailDistortionAlphaHigh: Float = 0.7
    // Per-layer beat-zoom "movement" strength - a parallax stack, strictly descending from the top
    // of the stack (subject) to the bottom (backgroundColor), so subject punches inward the most on
    // a bass hit and each layer underneath it moves less, in proportion to how far back in the
    // stack it sits. Keep these in strictly descending order (subject > text > backgroundDetail >
    // backgroundColor) - the shader's own overhang margin (see ProjectMCompositeShader.metal's
    // beatZoomBound) is sized off primaryBeatZoomStrength alone on the assumption it's always the
    // largest of the four - still true after resampling (see resampleBeatZoomStrengths), since the
    // top-ranked present layer always gets exactly primaryBeatZoomStrength, never more.
    // backgroundColorBeatZoomStrength is applied as-is, always; the other three are this cover's
    // *base* full-stack values - what actually reaches the shader for subject/text/backgroundDetail
    // is resampleBeatZoomStrengths's per-track output (see currentPrimaryBeatZoomStrength etc.),
    // not these constants directly, except when all three layers exist for a given cover (the
    // common case), where resampling is the identity and these values pass straight through.
    private static let backgroundColorBeatZoomStrength: Float = 0.05 //disabled for now
    private static let tertiaryBeatZoomStrength: Float = 0.2
    private static let secondaryBeatZoomStrength: Float = 0.3
    private static let primaryBeatZoomStrength: Float = 0.45
    // How zoomed-in the reverse intro starts (see introStyle) - the ramp runs
    // reverseIntroStartScale -> 1 over scaleIn, then keeps going at that same rate through
    // separate, same "one continuous ramp" shape as the forward intro's 0 -> 1 -> beyond.
    // introAlpha's cubic ease-*out* (shared with every introStyle - see introAlpha's own doc
    // comment) crosses 50% opacity early, around t ~ 0.21 of scaleIn, so most of this ramp is
    // visible at meaningful opacity rather than just a brief tail - retune this if the shrink reads
    // as too subtle or too extreme once it's visible for that much longer.
    private static let reverseIntroStartScale: Float = 4.0
    // How far off-screen (screen-normalized, same space as artCenter) the slide intros start -
    // shared by slideRight (starts to the right) and slideDown (starts above) - the ramp runs
    // slideStartOffset -> 0 over scaleIn, then keeps going past 0 (further off in the same
    // direction it came from) at that same rate through separate - see albumArtOffsets().
    // Comfortably bigger than 1.0 (a whole screen width/height) so the art starts fully off-screen
    // regardless of where the art square itself sits or how wide/tall the window is.
    private static let slideStartOffset: Float = 1.4

    private var textureLoader: MTKTextureLoader?
    private var emptyAlbumArtTexture: MTLTexture?

    // Snapshots of currentBackgroundDetailTexture/currentSubjectOnlyTexture/currentTextOnlyTexture
    // (below) taken the instant a preset transition starts (see updateModelIfNeeded) and held fixed
    // for that transition's whole duration - the "old" side of the old->new blend
    // ProjectMCompositeShader.metal's preset-transition effect plays per layer. The "new" side is
    // just whatever those three current*Texture fields are *now*, live - if the track hasn't
    // changed, old and new are the same content and every ported effect is a no-op; if it has,
    // they'll differ (once the async artwork fetch resolves - see NowPlayingManager.loadArtwork)
    // and the layer visibly transitions from one to the other in lockstep with the preset.
    private var transitionOldBackgroundDetailTexture: MTLTexture?
    private var transitionOldSubjectTexture: MTLTexture?
    private var transitionOldTextTexture: MTLTexture?

    // "Current" track's puzzle pieces - NowPlayingManager.subjectArtwork (Vision's subject cutout
    // with any OCR'd text drawn back on top - the "end graphic," same as NowPlayingManager's
    // `.combined` masking mode produces before its own recentering step), and two versions of the
    // color-keyed (or, absent a clean key, raw) cover:
    //   currentFullBackgroundTexture - the cover completely untouched, no hole - used as the
    //     background layer for the whole of scaleIn, so entrance always shows the genuinely full
    //     album art regardless of how subject/background happen to line up frame to frame (no
    //     reliance on two cutout layers reconstituting each other pixel-perfectly).
    //   currentBackgroundTexture - the same cover with an end-graphic-shaped hole already punched
    //     out of it (see backgroundWithSubjectHole) - swapped in starting at `separate`, once the
    //     subject has locked in place and "everything else" is what pulls away; without the hole,
    //     the background growing past the locked end graphic during separate would show a faint
    //     enlarging "ghost" of it bleeding out from behind, since the background would otherwise
    //     still be carrying those same pixels underneath. nil-mask-safe: backgroundWithSubjectHole
    //     just returns its input untouched when there's no subject to cut, so this degrades to the
    //     same single full-cover background as currentFullBackgroundTexture automatically.
    private var currentFullBackgroundTexture: MTLTexture?
    private var currentBackgroundTexture: MTLTexture?
    private var currentSubjectTexture: MTLTexture?
    // The four-layer stack's own dedicated textures (see AlbumArtLayerCount) - uploaded
    // unconditionally in promoteToCurrentTrack alongside the three above, straight from
    // NowPlayingManager's backgroundColorArtwork/backgroundDetailArtwork/subjectOnlyArtwork/
    // textOnlyArtwork - all four genuinely non-overlapping pieces of the cover, unlike
    // currentBackgroundTexture/currentFullBackgroundTexture above (which still carry the whole
    // photo). All four are always bound and sampled every frame regardless of the current reveal
    // count - only each one's *Visible uniform flag changes (see draw(in:)).
    private var currentBackgroundColorTexture: MTLTexture?
    private var currentBackgroundDetailTexture: MTLTexture?
    private var currentSubjectOnlyTexture: MTLTexture?
    private var currentTextOnlyTexture: MTLTexture?
    // This cover's actual beat-zoom strengths for subject/text/backgroundDetail, resolved once per
    // track in promoteToCurrentTrack by resampleBeatZoomStrengths - see that function's own doc
    // comment. Default to the full-stack constants so nothing looks wrong before the first track
    // ever loads. backgroundColor isn't here since its strength never varies - draw(in:) reads
    // Self.backgroundColorBeatZoomStrength directly for it, same as before.
    private var currentPrimaryBeatZoomStrength = ProjectMCoordinator.primaryBeatZoomStrength
    private var currentSecondaryBeatZoomStrength = ProjectMCoordinator.secondaryBeatZoomStrength
    private var currentTertiaryBeatZoomStrength = ProjectMCoordinator.tertiaryBeatZoomStrength
    private var currentRawImage: NSImage?
    private var trackAnimationClock: Float = 0
    // Which of the four intro choreographies this track got, picked once per track in
    // promoteToCurrentTrack. All four now share the exact same dissolve/opacity/distortion
    // treatment (introAlpha's fade plus the shader's wave_dissolve_walk scatter-and-reassemble,
    // `stage == 0` in ProjectMCompositeShader.metal) - every entrance starts equally scattered,
    // equally transparent, and equally pushed around by the wave before it lands solid at center.
    // The *only* thing that differs between them is the geometric motion layered on top:
    //   forward      - scale ramps 0 -> 1 (materializes by growing from a point); no offset.
    //   reverseScale - scale ramps reverseIntroStartScale -> 1 (materializes by shrinking down to
    //                  size from a zoomed-in crop); no offset.
    //   slideRight   - scale pinned at 1 throughout (no zoom at all); instead starts
    //                  slideStartOffset off to the right and slides in to center.
    //   slideDown    - same as slideRight, just rotated 90 degrees: starts slideStartOffset off the
    //                  top of the screen and slides down to center instead.
    // See albumArtScales/albumArtOffsets for the per-style scale/offset math, and introAlpha/the
    // shader's own wave_dissolve_walk for the shared dissolve. Only affects how scaleIn plays out;
    // separate/steady/outgoingExit are identical across all four.
    private var introStyle: Float = AlbumArtIntroStyle.forward

    // Previous track's subject (or, if Vision found no subject, its whole raw cover), captured the
    // instant a track change is detected and left to dissolve away on its own clock while the new
    // track is promoted to `current` immediately and starts its own entrance in the very same frame
    // - see advanceAlbumArtAnimation. The two tracks' art deliberately *does* overlap on screen now:
    // one is still tearing apart while the other is already scaling/fading in over it.
    private var outgoingTexture: MTLTexture?
    private var outgoingExitClock: Float = 0
    private var isOutgoingExitActive = false

    private var latestRawImage: NSImage?
    private var latestColorKeyedImage: NSImage?
    private var latestSubjectImage: NSImage?
    private var latestSubjectOnlyImage: NSImage?
    private var latestTextOnlyImage: NSImage?
    private var latestBackgroundDetailImage: NSImage?
    private var latestBackgroundColorImage: NSImage?
    // How many layers, counting from the bottom of the stack, draw(in:) shows right now - see
    // AlbumArtLayerCount's own doc comment. Driven by ContentView's "M" hotkey via updateAlbumArt
    // below. Starts at `all` (4) - the full stack - matching AlbumArtLayerCount's own cycle order.
    private var displayVisibleLayerCount = AlbumArtLayerCount.all
    private var albumArtHidden = false
    // "H" hidden-toggle / nothing-loaded-yet mute, eased quickly (not the stage choreography's own
    // pacing) toward 0 or 1 each frame - independent of, and multiplied on top of, whichever stage
    // is currently driving the animation.
    private var globalAlpha: Float = 0
    private var lastAlbumArtTimestamp: CFTimeInterval?
    // Beat-driven "punch" envelope for the zoom applied in ProjectMCompositeShader.metal (see
    // primaryBeatZoomStrength) - a simple peak-and-decay follower over
    // audioEngine.levels' lowest bands (~60-130Hz, the kick-drum/bass range), not real tempo/
    // onset detection: snaps straight up to match a fresh, louder bass hit (the per-band
    // smoothing SpectrumAnalyzer already does gives that snap its fast attack), then decays
    // linearly at beatPulseDecayPerSecond between hits, which is what actually reads as a "pulse"
    // rather than the zoom just continuously tracking bass loudness.
    private var beatPulse: Float = 0
    private static let beatPulseBassBandCount = 6
    private static let beatPulseDecayPerSecond: Float = 2.0

    private var lastLoadedPresetURL: URL?
    private weak var model: ProjectMVisualizerModel?

    // Identifies a specific real-projectM PresetTransition instance - its shader index plus random
    // seeds, which are re-picked fresh every time ProjectM::StartPresetTransition constructs a new
    // one. Used by updatePresetTransitionSnapshotIfNeeded to detect a *new* transition starting -
    // see that function's own doc comment for why presetTransitionActive alone (true -> false ->
    // true) isn't a reliable signal for this: skipping to another preset while a transition is
    // still playing (e.g. rapidly skipping songs) makes real projectM force-complete the old
    // transition and start a new one in the same call, with presetTransitionActive staying
    // continuously true across the switch - no false edge to detect at all.
    private struct PresetTransitionIdentity: Equatable {
        var shaderIndex: Int32
        var seedA: Int32
        var seedB: Int32
        var seedC: Int32
        var seedD: Int32
    }
    private var lastPresetTransitionIdentity: PresetTransitionIdentity?

    // Smoothed FPS for ContentView's on-screen counter - exponential moving average (not raw
    // per-frame 1/dt) so the displayed number doesn't jitter every single frame.
    private var lastFrameTimestamp: CFTimeInterval?
    private var smoothedFPS: Double = 60

    init(audioEngine: CoreAudioTapEngine) {
        engine = ProjectMEngine()
        self.audioEngine = audioEngine
        super.init()
        if engine == nil {
            NSLog("ProjectMCoordinator: ProjectMEngine failed to initialize")
        }
        engine?.presetLoadFailureHandler = { [weak self] filename, message in
            NSLog("ProjectMCoordinator: preset load failed for \(filename): \(message)")
            DispatchQueue.main.async {
                self?.model?.presetLoadError = "Couldn't load \((filename as NSString).lastPathComponent): \(message)"
            }
        }
    }

    /// Diffs against the last preset this coordinator actually loaded, same pattern
    /// MilkdropMetalCoordinator used for its own model - called every SwiftUI update, but only
    /// triggers an actual engine call when the requested preset URL has changed.
    func updateModelIfNeeded(_ model: ProjectMVisualizerModel) {
        self.model = model
        guard let url = model.presetURL, url != lastLoadedPresetURL else { return }
        lastLoadedPresetURL = url
        engine?.loadPreset(at: url, smoothTransition: true)
    }

    /// Polls the engine for whether a preset transition is running right now and, whenever it's a
    /// *different* transition than the one already snapshotted (see PresetTransitionIdentity's own
    /// doc comment - not just "wasn't active last frame", since a rapid skip mid-transition never
    /// clears presetTransitionActive), snapshots the "old" side of the album-art blend - see
    /// transitionOldBackgroundDetailTexture's own doc comment. Everything else about the transition
    /// (its progress) is read fresh into the uniforms every frame in draw(in:) directly from the
    /// engine - see PresetTransitionEffect and ProjectMEngine's presetTransition* properties.
    private func updatePresetTransitionSnapshotIfNeeded() {
        guard let engine, engine.presetTransitionActive else {
            lastPresetTransitionIdentity = nil
            return
        }
        let identity = PresetTransitionIdentity(
            shaderIndex: engine.presetTransitionShaderIndex,
            seedA: engine.presetTransitionRandomSeedA, seedB: engine.presetTransitionRandomSeedB,
            seedC: engine.presetTransitionRandomSeedC, seedD: engine.presetTransitionRandomSeedD
        )
        guard identity != lastPresetTransitionIdentity else { return }
        lastPresetTransitionIdentity = identity
        transitionOldBackgroundDetailTexture = currentBackgroundDetailTexture
        transitionOldSubjectTexture = currentSubjectOnlyTexture
        transitionOldTextTexture = currentTextOnlyTexture
    }

    /// Real projectM's own iRandStatic values are raw std::mt19937 output reinterpreted as signed
    /// int32 (Renderer/PresetTransition.cpp) - routinely in the hundreds of millions to billions,
    /// either sign. The ported effects (ProjectMCompositeShader.metal) need these reduced down to a
    /// small range before use (a random *angle*/*blend width*, not the raw seed, is what the actual
    /// math wants) via a mod-style operation - doing that reduction in Float, as the original GLSL
    /// shaders themselves do (`mod(float(iRandStatic.x) * .001, .3)` etc.), loses catastrophic
    /// precision at this magnitude: float32 only represents integers exactly up to 2^24 (~16.7M), so
    /// `x - y*floor(x/y)` for x in the billions computes as the difference of two nearly-equal huge
    /// floats, each already off by roughly x's own ULP (~128 near 2 billion) - the "reduced" result
    /// can land wildly outside the intended [0, y) range, even negative, which is exactly what
    /// turned smoothstep's edges degenerate and made transitions flip instead of wipe. Reducing here
    /// first, in Int32 (exact, no precision loss at any magnitude) down to a small range comfortably
    /// inside float32's exact-integer window, then handing that small value to the shader, sidesteps
    /// the problem entirely - the shader's own further mod-by-2/mod-by-360/etc. then operates on
    /// numbers with no precision to lose.
    private static func reducedPresetTransitionSeed(_ raw: Int32) -> Float {
        let range: Int32 = 1_000_000
        let reduced = ((raw % range) + range) % range
        return Float(reduced)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Called from ProjectMMetalView.updateNSView every SwiftUI update tick (cheap: just stored
    /// properties) - the real work (texture uploads, stage transitions) happens lazily in
    /// draw(in:)'s advanceAlbumArtAnimation, since that's where a live MTLDevice is on hand.
    func updateAlbumArt(
        rawImage: NSImage?, colorKeyedImage: NSImage?, subjectImage: NSImage?, subjectOnlyImage: NSImage?,
        textOnlyImage: NSImage?, backgroundDetailImage: NSImage?, backgroundColorImage: NSImage?,
        visibleLayerCount: Int, hidden: Bool
    ) {
        latestRawImage = rawImage
        latestColorKeyedImage = colorKeyedImage
        latestSubjectImage = subjectImage
        latestSubjectOnlyImage = subjectOnlyImage
        latestTextOnlyImage = textOnlyImage
        latestBackgroundDetailImage = backgroundDetailImage
        latestBackgroundColorImage = backgroundColorImage
        displayVisibleLayerCount = visibleLayerCount
        albumArtHidden = hidden
    }

    func draw(in view: MTKView) {
        guard let engine,
              let device = view.device,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor
        else {
            return
        }

        if commandQueue == nil {
            commandQueue = device.makeCommandQueue()
        }
        if pipelineState == nil {
            pipelineState = Self.buildPipelineState(device: device, pixelFormat: view.colorPixelFormat)
        }
        guard let commandQueue, let pipelineState else { return }

        ProjectMAudioBridge.feed(engine, from: audioEngine)
        let now = CACurrentMediaTime()
        updateDisplayFPS(now: now)
        engine.setWarpAnimSpeedMultiplier(Float(model?.warpAnimSpeedMultiplier ?? 1.0))
        advanceAlbumArtAnimation(device: device, now: now)
        updatePresetTransitionSnapshotIfNeeded()

        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        guard width > 0, height > 0 else { return }

        guard let ioSurface = engine.renderFrame(width: width, height: height) else { return }

        let texture: MTLTexture
        if let cachedTexture, cachedWidth == width, cachedHeight == height, cachedIOSurface === ioSurface {
            texture = cachedTexture
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let newTexture = device.makeTexture(descriptor: descriptor, iosurface: ioSurface, plane: 0) else {
                return
            }
            texture = newTexture
            cachedTexture = newTexture
            cachedIOSurface = ioSurface
            cachedWidth = width
            cachedHeight = height
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }

        // Art square is a fixed 480x480 device pixels (Spotify's own artwork resolution), centered
        // - the same spot SwiftUI's ZStack centered it by default before this moved into the
        // shader. outgoingActive/outgoingProgress stay hardcoded off - that's the separate,
        // pre-existing track-transition-dissolve feature (see ProjectMCompositeShader.metal's own
        // header), disabled before this four-style cycle existed and untouched by it.
        let outgoingActive: Float = 0
        let outgoingProgress: Float = 0
        // Read live from the engine every frame - see PresetTransitionEffect and
        // ProjectMEngine.presetTransitionActive's own doc comment for why (that blend, and which
        // of the 6 built-in effects/what random parameters it's using, is otherwise fully internal
        // to projectM with nothing else here to derive it from).
        let presetTransitionActive: Float = (engine.presetTransitionActive) ? 1 : 0
        let presetTransitionProgress = Float(engine.presetTransitionProgress)
        let presetTransitionEffect = Float(engine.presetTransitionShaderIndex)
        let presetTransitionRandomSeeds = SIMD4<Float>(
            Self.reducedPresetTransitionSeed(engine.presetTransitionRandomSeedA),
            Self.reducedPresetTransitionSeed(engine.presetTransitionRandomSeedB),
            Self.reducedPresetTransitionSeed(engine.presetTransitionRandomSeedC),
            Self.reducedPresetTransitionSeed(engine.presetTransitionRandomSeedD)
        )
        var uniforms = AlbumArtUniforms(
            waveTexelSize: SIMD2(1.0 / Float(width), 1.0 / Float(height)),
            artCenter: SIMD2(0.5, 0.5),
            artHalfSize: SIMD2(
                Self.albumArtSizePixels / 2.0 / Float(width), Self.albumArtSizePixels / 2.0 / Float(height)
            ),
            globalAlpha: globalAlpha,
            // Bottom of the stack disappears first as the count drops from 4 (see
            // AlbumArtLayerCount's own doc comment): backgroundColor needs the full count to show,
            // subject only needs at least 1 - it's the last one left before the stack hits 0 and
            // wraps.
            backgroundColorVisible: displayVisibleLayerCount >= 4 ? 1 : 0,
            backgroundDetailVisible: displayVisibleLayerCount >= 3 ? 1 : 0,
            subjectVisible: displayVisibleLayerCount >= 1 ? 1 : 0,
            textVisible: displayVisibleLayerCount >= 2 ? 1 : 0,
            chromaticAberrationStrength: Self.backgroundColorChromaticAberrationStrength,
            distortionStrength: Self.backgroundDetailDistortionStrength,
            distortionAlphaLow: Self.backgroundDetailDistortionAlphaLow,
            distortionAlphaHigh: Self.backgroundDetailDistortionAlphaHigh,
            aberrationAngle: Float(
                now.truncatingRemainder(dividingBy: Self.aberrationRotationPeriod)
                    / Self.aberrationRotationPeriod * 2.0 * Double.pi
            ),
            beatPulse: beatPulse,
            backgroundColorBeatZoomStrength: Self.backgroundColorBeatZoomStrength,
            tertiaryBeatZoomStrength: currentTertiaryBeatZoomStrength,
            secondaryBeatZoomStrength: currentSecondaryBeatZoomStrength,
            primaryBeatZoomStrength: currentPrimaryBeatZoomStrength,
            outgoingActive: outgoingActive,
            outgoingProgress: outgoingProgress,
            presetTransitionActive: presetTransitionActive,
            presetTransitionProgress: presetTransitionProgress,
            presetTransitionEffect: presetTransitionEffect,
            presetTransitionRandomSeeds: presetTransitionRandomSeeds
        )

        // The four-layer stack's own layers - always bound the same way regardless of the current
        // reveal count; only the uniforms' *Visible flags above change with it. Falls back to
        // emptyAlbumArtTexture (fully transparent) per layer when this track has nothing for it
        // (e.g. no clean color key, or Vision found no subject).
        let backgroundColorTex = currentBackgroundColorTexture ?? emptyAlbumArtTexture
        let backgroundDetailTex = currentBackgroundDetailTexture ?? emptyAlbumArtTexture
        let subjectTex = currentSubjectOnlyTexture ?? emptyAlbumArtTexture
        let textTex = currentTextOnlyTexture ?? emptyAlbumArtTexture
        // Previous track's snapshot, dissolving away as its own layer underneath everything above
        // - see outgoingTexture's own doc comment.
        let outgoingTex = outgoingTexture ?? emptyAlbumArtTexture
        // "Old" side of the preset-transition blend - see transitionOldBackgroundDetailTexture's
        // own doc comment. Falls back to the *live* current texture (not emptyAlbumArtTexture) when
        // there's no snapshot yet, so a transition starting before any track has ever loaded blends
        // from itself (a no-op) rather than from nothing.
        let oldBackgroundDetailTex = transitionOldBackgroundDetailTexture ?? backgroundDetailTex
        let oldSubjectTex = transitionOldSubjectTexture ?? subjectTex
        let oldTextTex = transitionOldTextTexture ?? textTex

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(backgroundColorTex, index: 1)
        encoder.setFragmentTexture(backgroundDetailTex, index: 2)
        encoder.setFragmentTexture(subjectTex, index: 3)
        encoder.setFragmentTexture(textTex, index: 4)
        encoder.setFragmentTexture(outgoingTex, index: 5)
        encoder.setFragmentTexture(oldBackgroundDetailTex, index: 6)
        encoder.setFragmentTexture(oldSubjectTex, index: 7)
        encoder.setFragmentTexture(oldTextTex, index: 8)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AlbumArtUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Drives the scaleIn -> separate -> steady state machine for the incoming track, running
    /// concurrently alongside the previous track's own independent outgoingExit dissolve (see
    /// outgoingActiveAndProgress) rather than waiting for it to finish first: detects a new track's
    /// artwork, snapshots whatever was on screen as the new `outgoing` layer, and promotes the new
    /// track to `current` immediately, in the same frame, so its entrance starts the instant the
    /// old art starts dissolving away. Cheap when nothing's changing - the common case is just two
    /// clock increments.
    private func advanceAlbumArtAnimation(device: MTLDevice, now: CFTimeInterval) {
        if emptyAlbumArtTexture == nil {
            emptyAlbumArtTexture = Self.makeEmptyTexture(device: device)
        }

        if latestRawImage !== currentRawImage {
            if currentRawImage == nil {
                // First track this launch - nothing on screen yet to dissolve away first.
                promoteToCurrentTrack(
                    device: device, rawImage: latestRawImage, colorKeyedImage: latestColorKeyedImage,
                    subjectImage: latestSubjectImage, subjectOnlyImage: latestSubjectOnlyImage,
                    textOnlyImage: latestTextOnlyImage, backgroundDetailImage: latestBackgroundDetailImage,
                    backgroundColorImage: latestBackgroundColorImage
                )
            } else {
                // --- Album transition code temporarily disabled: no outgoing dissolve layer, just
                // promote straight to the new track. ---
                // outgoingTexture = currentSubjectTexture ?? currentBackgroundTexture
                // isOutgoingExitActive = true
                // outgoingExitClock = 0
                // --- end disabled ---
                promoteToCurrentTrack(
                    device: device, rawImage: latestRawImage, colorKeyedImage: latestColorKeyedImage,
                    subjectImage: latestSubjectImage, subjectOnlyImage: latestSubjectOnlyImage,
                    textOnlyImage: latestTextOnlyImage, backgroundDetailImage: latestBackgroundDetailImage,
                    backgroundColorImage: latestBackgroundColorImage
                )
            }
        }

        defer { lastAlbumArtTimestamp = now }
        let dt = lastAlbumArtTimestamp.map { Float(now - $0) } ?? 0
        updateBeatPulse(dt: dt)

        // --- Album transition code temporarily disabled ---
        // if isOutgoingExitActive {
        //     outgoingExitClock += dt
        //     if outgoingExitClock >= Self.subjectExitDuration {
        //         isOutgoingExitActive = false
        //         outgoingTexture = nil
        //     }
        // }
        // trackAnimationClock += dt
        // --- end disabled ---

        let hasContent = currentBackgroundTexture != nil || currentSubjectTexture != nil || isOutgoingExitActive
        let target: Float = (hasContent && !albumArtHidden) ? 1 : 0
        globalAlpha += (target - globalAlpha) * min(1, max(0, dt) * Self.globalAlphaEaseSpeed)
    }

    /// Peak-and-decay follower over the lowest bands of audioEngine.levels (SpectrumAnalyzer's
    /// 40-band log-spaced spectrum, 60Hz-10kHz - see beatPulse's own doc comment for why the
    /// first `beatPulseBassBandCount` bands land squarely in kick-drum/bass territory).
    /// Deliberately not real onset/tempo detection - just tracks the loudest recent bass hit and
    /// lets it decay, which reads as a satisfying "punch" on transients without the false-positive
    /// risk a proper beat tracker would carry for comparatively little visual difference here.
    private func updateBeatPulse(dt: Float) {
        let bassBandCount = min(Self.beatPulseBassBandCount, audioEngine.levels.count)
        guard bassBandCount > 0 else { return }
        let bassEnergy = Float(audioEngine.levels[0..<bassBandCount].reduce(0, +)) / Float(bassBandCount)
        if bassEnergy > beatPulse {
            beatPulse = bassEnergy
        } else {
            beatPulse = max(0, beatPulse - Self.beatPulseDecayPerSecond * max(0, dt))
        }
    }

    // --- Album transition code temporarily disabled ---
    /*
    private func outgoingActiveAndProgress() -> (active: Float, progress: Float) {
        guard isOutgoingExitActive else { return (0, 0) }
        return (1, min(1, outgoingExitClock / Self.subjectExitDuration))
    }

    private func albumArtStageAndProgress() -> (stage: Float, progress: Float) {
        if trackAnimationClock < Self.scaleInDuration {
            return (AlbumArtStage.scaleIn, min(1, trackAnimationClock / Self.scaleInDuration))
        }
        if trackAnimationClock < Self.scaleInDuration + Self.separateDuration {
            let progress = (trackAnimationClock - Self.scaleInDuration) / Self.separateDuration
            return (AlbumArtStage.separate, min(1, progress))
        }
        return (AlbumArtStage.steady, 1)
    }

    /// One constant-velocity ramp spanning scaleIn and separate both, so there's no perceptible
    /// speed change at the boundary between them - only what stops moving there changes.
    /// `subjectScale` follows that ramp until it reaches 1 (i.e. for the whole of scaleIn) then
    /// holds there for good; `backgroundScale` keeps following the exact same ramp past that point
    /// for as long as there's a subject to leave behind, or holds at 1 too if there's no subject to
    /// separate from (see AlbumArtStage.separate in ProjectMCompositeShader.metal's header for why
    /// that case skips moving at all).
    ///
    /// `introStyle` flips which direction that ramp runs: forward goes 0 -> 1 (rate 1 full size per
    /// scaleInDuration) then keeps growing past 1 through separate; reverseScale starts at
    /// `reverseIntroStartScale` and shrinks down to 1 at the same rate, then keeps shrinking past 1
    /// (towards, and eventually past, 0 - see the shader's own `max(scale, 0.02)` floor) through
    /// separate. Neither slideRight nor slideDown scale at all - see albumArtOffsets() instead - so
    /// both scales just pin at 1 for those styles. Either way `subjectScale` locks at exactly 1 the
    /// instant the ramp crosses it.
    private func albumArtScales(hasSubjectMask: Bool) -> (subject: Float, background: Float) {
        guard introStyle == AlbumArtIntroStyle.forward || introStyle == AlbumArtIntroStyle.reverseScale
        else { return (1, 1) }
        let t = trackAnimationClock / Self.scaleInDuration
        let ramp: Float
        let subjectScale: Float
        if introStyle == AlbumArtIntroStyle.reverseScale {
            ramp = Self.reverseIntroStartScale - t * (Self.reverseIntroStartScale - 1)
            subjectScale = t < 1 ? ramp : 1
        } else {
            ramp = t
            subjectScale = min(ramp, 1)
        }
        let backgroundScale = hasSubjectMask ? ramp : subjectScale
        return (subjectScale, backgroundScale)
    }

    /// The slideRight/slideDown counterpart to albumArtScales - same "one continuous ramp, subject
    /// locks, background keeps going" shape (see that function's doc comment), just moving position
    /// instead of size. slideRight rides its ramp along x: starts at `slideStartOffset` (off-screen
    /// right) down to 0 (dead center) over scaleIn, where `subjectOffset` locks for good;
    /// `backgroundOffset` keeps riding the same ramp past that point, going negative - i.e. still
    /// moving left, off past center - for as long as there's a subject to leave behind. slideDown is
    /// the same shape rotated onto y: starts at `-slideStartOffset` (off-screen above) and rides up
    /// to 0, then keeps going positive (down, past center) in separate. Pinned at (0, 0) for forward/
    /// reverseScale, so this is a no-op add in the shader for those styles.
    private func albumArtOffsets(hasSubjectMask: Bool) -> (subject: SIMD2<Float>, background: SIMD2<Float>) {
        let t = trackAnimationClock / Self.scaleInDuration
        let ramp: Float
        switch introStyle {
        case AlbumArtIntroStyle.slideRight:
            ramp = Self.slideStartOffset * (1 - t)
        case AlbumArtIntroStyle.slideDown:
            ramp = Self.slideStartOffset * (t - 1)
        default:
            return (SIMD2(0, 0), SIMD2(0, 0))
        }
        let subjectRamp: Float = t < 1 ? ramp : 0
        let backgroundRamp = hasSubjectMask ? ramp : subjectRamp
        if introStyle == AlbumArtIntroStyle.slideRight {
            return (SIMD2(subjectRamp, 0), SIMD2(backgroundRamp, 0))
        } else {
            return (SIMD2(0, subjectRamp), SIMD2(0, backgroundRamp))
        }
    }

    /// 0...1 fade all four intros use to materialize, in lockstep with the shader's own
    /// wave-dissolve reassembly (ProjectMCompositeShader.metal's `stage == 0` block) - shared by
    /// every introStyle now, so every track's entrance starts equally dissolved/transparent
    /// regardless of which one it got; only the scale ramp (albumArtScales) or slide offset
    /// (albumArtOffsets) differs by style on top of this same fade. Driven by the same clock as
    /// those, so the fade and the scale/slide-to-rest both land at the same instant.
    /// trackAnimationClock now always advances regardless of whether a previous track is
    /// concurrently dissolving away in its own outgoingExit layer - see advanceAlbumArtAnimation -
    /// so a track change never pauses this. Cubic ease-*out* (not ease-in) - the fade rises fast
    /// right away and only tapers at the end - see easeOut's own doc comment for why: with the
    /// outgoing layer (see outgoingActiveAndProgress) dissolving away on the exact same clock, an
    /// entrance that stayed nearly invisible until late in its own duration read as a dead gap
    /// between the old art disappearing and the new art showing up, even though both clocks start
    /// on the same frame - ease-out closes that gap by making the incoming layer visible almost
    /// immediately, while still tapering into a clean finish rather than a linear ramp.
    private func introAlpha() -> Float {
        return Self.easeOut(min(trackAnimationClock / Self.scaleInDuration, 1))
    }

    /// Cubic ease-out: 0...1 in, 0...1 out, starting with a fast, steep rise and flattening into the
    /// finish - unlike a straight `t` ramp, equal steps in `t` produce ever-smaller steps in the
    /// output. Shared by introAlpha here and the shader's own dissolve-amount curve
    /// (ProjectMCompositeShader.metal's ease_out), so the opacity fade and the wave-dissolve
    /// reassembly both rise together right from the start of scaleIn.
    private static func easeOut(_ t: Float) -> Float {
        let clamped = min(max(t, 0), 1)
        let inv = 1 - clamped
        return 1 - inv * inv * inv
    }
    */
    // --- end disabled ---

    private func promoteToCurrentTrack(
        device: MTLDevice, rawImage: NSImage?, colorKeyedImage: NSImage?, subjectImage: NSImage?,
        subjectOnlyImage: NSImage?, textOnlyImage: NSImage?, backgroundDetailImage: NSImage?,
        backgroundColorImage: NSImage?
    ) {
        currentRawImage = rawImage
        // Random pick each track, excluded from repeating the style just used so back-to-back
        // tracks never play the same intro choreography twice in a row.
        introStyle = AlbumArtIntroStyle.all.filter { $0 != introStyle }.randomElement() ?? introStyle

        // The background layer always shows the *full* cover - color-keyed wherever a clean solid
        // background color was confidently detected (colorKeyedArtwork requires backgroundTone
        // .black/.white - most covers, having some other color or a gradient, don't qualify), and
        // the plain raw cover otherwise. Unlike compositeArtwork's `.combined` mode (which, with no
        // clean key to apply, shows *only* the subject on transparent - fine for that mode's
        // original single-flattened-image use, but here it meant most tracks never showed a
        // background layer at all, just the bare subject cutout scaling in against nothing), this
        // always has something to reconstitute the full cover with the subject/text hole punched
        // out of it below, so "the full album art" is what's actually on screen at scaleIn, not
        // just an isolated cutout.
        let backgroundSource = colorKeyedImage ?? rawImage

        currentFullBackgroundTexture = backgroundSource.flatMap {
            Self.uploadTexture(device: device, loader: &textureLoader, image: $0)
        }
        let backgroundImage = backgroundSource.map { Self.backgroundWithSubjectHole(raw: $0, subjectMask: subjectImage) }
        currentBackgroundTexture = backgroundImage.flatMap {
            Self.uploadTexture(device: device, loader: &textureLoader, image: $0)
        }
        currentSubjectTexture = subjectImage.flatMap {
            Self.uploadTexture(device: device, loader: &textureLoader, image: $0)
        }
        // The four-layer stack's own textures - see AlbumArtLayerCount. backgroundColorImage/
        // backgroundDetailImage are genuinely separate ingredients from rawImage/colorKeyedImage
        // above (see NowPlayingManager.backgroundColorArtwork/backgroundDetailArtwork's own doc
        // comments) - a flat color fill and a subject/text-hole-punched color key, respectively,
        // rather than the whole cover repeated across layers.
        currentBackgroundColorTexture = backgroundColorImage.flatMap {
            Self.uploadTexture(device: device, loader: &textureLoader, image: $0)
        }
        currentBackgroundDetailTexture = backgroundDetailImage.flatMap {
            Self.uploadTexture(device: device, loader: &textureLoader, image: $0)
        }
        currentSubjectOnlyTexture = subjectOnlyImage.flatMap {
            Self.uploadTexture(device: device, loader: &textureLoader, image: $0)
        }
        currentTextOnlyTexture = textOnlyImage.flatMap {
            Self.uploadTexture(device: device, loader: &textureLoader, image: $0)
        }

        // Resolve this cover's actual beat-zoom strengths - see resampleBeatZoomStrengths's own doc
        // comment. Order matters: this must match the fixed top-to-bottom depth stack (subject,
        // text, backgroundDetail) that Self.fullBeatZoomStrengths is itself ordered in.
        let layersPresent = [subjectOnlyImage != nil, textOnlyImage != nil, backgroundDetailImage != nil]
        let resampled = Self.resampleBeatZoomStrengths(
            Self.fullBeatZoomStrengths, to: layersPresent.filter { $0 }.count
        )
        var resampledStrengths = resampled.makeIterator()
        currentPrimaryBeatZoomStrength = layersPresent[0] ? (resampledStrengths.next() ?? 0) : 0
        currentSecondaryBeatZoomStrength = layersPresent[1] ? (resampledStrengths.next() ?? 0) : 0
        currentTertiaryBeatZoomStrength = layersPresent[2] ? (resampledStrengths.next() ?? 0) : 0

        trackAnimationClock = 0
    }

    /// This cover's actual full-stack beat-zoom strengths, top-to-bottom (subject, text,
    /// backgroundDetail) - backgroundColor is deliberately excluded, since its strength never
    /// varies regardless of what the other three layers look like.
    private static let fullBeatZoomStrengths: [Float] = [
        primaryBeatZoomStrength, secondaryBeatZoomStrength, tertiaryBeatZoomStrength,
    ]

    /// Resamples `base` (a strictly descending, top-to-bottom "if every layer existed" strength
    /// list) down to `count` values, so a cover missing some of those layers still gets a smooth
    /// top-to-bottom falloff scaled to however many it actually has, rather than either reusing
    /// `base`'s values verbatim (which would leave whatever layer happens to survive stuck with
    /// whatever weak strength its *original* named slot had) or - worse - concentrating all the
    /// punch on `base.first` regardless of stack depth. The first output always exactly equals
    /// `base.first` (the strongest value) - so a cover with only one of these three layers has it
    /// moving at the full top-of-stack strength, not some smaller one - and the rest are
    /// linearly interpolated between `base`'s neighboring entries at evenly-spaced positions, so
    /// e.g. resampling [0.15, 0.10, 0.06] to 2 values gives [0.15, 0.125]: the first entry
    /// untouched, the second roughly splitting the difference between `base`'s middle and last
    /// entries rather than jumping straight to either one.
    private static func resampleBeatZoomStrengths(_ base: [Float], to count: Int) -> [Float] {
        guard count > 0, !base.isEmpty else { return [] }
        return (0..<count).map { i in
            let position = Float(i) * Float(base.count) / Float(count)
            let lowerIndex = min(Int(position), base.count - 1)
            let upperIndex = min(lowerIndex + 1, base.count - 1)
            let fraction = position - Float(lowerIndex)
            return base[lowerIndex] + (base[upperIndex] - base[lowerIndex]) * fraction
        }
    }

    /// Punches a subject-shaped hole out of `raw`, using `subjectMask`'s own alpha as the stencil
    /// (`.destinationOut`: draw raw, then erase wherever the mask just drawn on top was opaque),
    /// so the result and `subjectMask` fit together like two puzzle pieces that reconstitute the
    /// original cover exactly, with nothing double-covered by both layers - see
    /// currentBackgroundTexture's own doc comment for why that matters during `separate`. Returns
    /// `raw` completely untouched when there's no mask to cut with (Vision found no subject),
    /// which is exactly the existing "just show the whole cover" fallback.
    private static func backgroundWithSubjectHole(raw: NSImage, subjectMask: NSImage?) -> NSImage {
        guard let subjectMask,
              let rawCGImage = raw.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let maskCGImage = subjectMask.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return raw
        }
        let width = rawCGImage.width, height = rawCGImage.height
        guard width > 0, height > 0 else { return raw }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return raw }

        // Matches NSImage.overlaying's own handling (SubjectMasking.swift) of the mask potentially
        // having different pixel dimensions than raw - CGContext.draw scales each to fill this
        // same destination rect regardless of its own source size.
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(rawCGImage, in: rect)
        context.setBlendMode(.destinationOut)
        context.draw(maskCGImage, in: rect)

        guard let outCGImage = context.makeImage() else { return raw }
        return outCGImage.asPixelExactNSImage()
    }

    private static func uploadTexture(device: MTLDevice, loader: inout MTKTextureLoader?, image: NSImage) -> MTLTexture? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        if loader == nil {
            loader = MTKTextureLoader(device: device)
        }
        return try? loader?.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ])
    }

    private func updateDisplayFPS(now: CFTimeInterval) {
        defer { lastFrameTimestamp = now }
        guard let lastFrameTimestamp else { return }
        let dt = now - lastFrameTimestamp
        guard dt > 0 else { return }
        let instantaneousFPS = 1.0 / dt
        smoothedFPS = smoothedFPS * 0.9 + instantaneousFPS * 0.1
        model?.displayFPS = smoothedFPS
        // Presets whose per-frame code normalizes against the `fps` builtin (rate/fps) need this
        // to match reality - projectM's own default (35) is otherwise never updated, so those
        // presets would still animate ~3x too fast on a 120Hz display. See PerFrameContext.cpp's
        // `fps`/`frame` builtins for why this only fixes presets that actually use `fps`.
        engine?.setTargetFPS(Int32(max(1, min(1000, smoothedFPS.rounded()))))
    }

    private static func buildPipelineState(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "projectm_passthrough_vertex"),
              let fragmentFunction = library.makeFunction(name: "projectm_composite_fragment")
        else {
            NSLog("ProjectMCoordinator: failed to load ProjectMCompositeShader.metal functions")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("ProjectMCoordinator: makeRenderPipelineState failed: \(error)")
            return nil
        }
    }

    /// 1x1 fully-transparent stand-in for texture(1) whenever there's no real album art loaded,
    /// so the composite fragment shader always runs the same code path instead of branching on
    /// "has art or not" every frame.
    private static func makeEmptyTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let zero: [UInt8] = [0, 0, 0, 0]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: zero, bytesPerRow: 4
        )
        return texture
    }
}
