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

/// Which of real projectM's 6 built-in preset-transition effects (Vendor/projectm/src/libprojectM/
/// Renderer/TransitionShaders/*.frag) the *current* preset transition is actually using - raw
/// Float, since it crosses straight into
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

    // Album art choreography - see ProjectMCompositeShader.metal's header. emptyAlbumArtTexture
    // stands in for any texture slot with nothing real to show, so the shader always runs the same
    // code path rather than branching per-frame on "has art or not."
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
    // When latestRawImage first started differing from currentRawImage while no preset transition
    // was active yet to reveal it - see advanceAlbumArtAnimation's own doc comment. nil whenever
    // there's nothing pending (art already promoted, or hasn't changed).
    private var awaitingTransitionSince: CFTimeInterval?
    private static let albumArtPromotionFallbackDelay: CFTimeInterval = 1.5
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

    // Runtime slow-preset watchdog state - see updateSlowPresetWatchdog.
    private var watchdogPresetURL: URL?
    private var slowFrameAccumulatedSeconds: Double = 0
    private var reportedSlowPresetURL: URL?
    private static let slowFPSThreshold: Double = 15
    private static let slowPresetGracePeriodSeconds: Double = 2.5

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
    /// engine - see PresetTransitionEffect and ProjectMEngine's presetTransition* properties - so the
    /// album art's own reveal always stays in lockstep with the wave's, start to finish, with no
    /// separate clock of its own.
    ///
    /// Must run before advanceAlbumArtAnimation in draw(in:) - see that call site's own comment.
    /// ContentView only ever triggers the auto-advance-on-track-change preset load
    /// (loadNextSequentialPreset/loadBestMatchedPreset, from the trackReadySettledToken onChange -
    /// see NowPlayingManager.trackReadySettledToken's own doc comment) once the new track's artwork has
    /// already finished loading, so by the time this function sees a *new* identity here, the new
    /// art is already sitting in NowPlayingManager's public artwork properties, about to be fed into
    /// `latest*Image` this same SwiftUI update and promoted by advanceAlbumArtAnimation - possibly
    /// this same frame. Snapshotting "old" here first is what keeps that promotion from clobbering it
    /// before it's captured.
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
        // Logging only, to verify in practice (see ContentView's trackReadySettledToken-gated preset
        // advance) whether album art is actually ready by the time a transition starts: if
        // latestRawImage already differs from currentRawImage here, this frame's advanceAlbumArtAnimation
        // (which runs right after this function returns) is about to promote *during* this transition
        // rather than having already settled before it - i.e. a real old-vs-new wipe either way, but
        // worth distinguishing "already current" from "changing right on the first frame" while
        // confirming this fix actually closes the race.
        let artAlreadyCurrent = latestRawImage === currentRawImage
        let artStatus = artAlreadyCurrent
            ? "already matches current track (no-op or already settled)"
            : "about to promote new art THIS transition (racing)"
        NSLog("ProjectMCoordinator: new preset transition (shader=\(identity.shaderIndex)) - album art \(artStatus)")
    }

    /// Real projectM's own iRandStatic values are raw std::mt19937 output reinterpreted as signed
    /// int32 (Renderer/PresetTransition.cpp) - routinely in the hundreds of millions to billions,
    /// either sign - and its own GLSL transition shaders compute directly on that raw magnitude
    /// (`mod(float(iRandStatic.x) * .001, .3)` etc.), in float32, with whatever precision loss that
    /// entails. That imprecision is baked into what real projectM actually renders - two IEEE754
    /// float32 environments (Metal, GLSL) computing the *identical* sequence of operations on the
    /// *identical* input are deterministic and agree, so replicating that same raw-value computation
    /// here (this function does nothing but the int32->float32 cast) reproduces the same on-screen
    /// result real projectM's own shader draws from this seed - matching it exactly, imprecision
    /// included, rather than computing a mathematically "cleaner" value that happens to diverge from
    /// what's actually on screen. (An earlier version of this function pre-reduced raw into a small
    /// range with exact Int32 arithmetic specifically to *avoid* that imprecision - which fixed a
    /// real, separate bug (smoothstep edges going degenerate from mod() returning the wrong *sign*
    /// for a negative raw - see preset_transition_glsl_mod for that fix, which is still needed) but
    /// also meant computing a different, cleaner number than what real projectM's own imprecise
    /// arithmetic actually produces - matching only by chance, not by construction, which is exactly
    /// the "matches sometimes, not others" behavior that gave this away.)
    private static func reducedPresetTransitionSeed(_ raw: Int32) -> Float {
        Float(raw)
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
        // Must run before advanceAlbumArtAnimation: a new transition's "old" snapshot has to be
        // taken from whatever current*Texture still is *before* this same frame's art promotion (if
        // any) could overwrite it - see updatePresetTransitionSnapshotIfNeeded's own doc comment.
        updatePresetTransitionSnapshotIfNeeded()
        advanceAlbumArtAnimation(device: device, now: now)

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
        // shader.
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
        encoder.setFragmentTexture(oldBackgroundDetailTex, index: 5)
        encoder.setFragmentTexture(oldSubjectTex, index: 6)
        encoder.setFragmentTexture(oldTextTex, index: 7)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AlbumArtUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Detects a new track's artwork and promotes it to `current` - but only once a preset
    /// transition is actually active to reveal it (see `awaitingTransitionSince`), not the instant
    /// `latestRawImage`'s identity changes. `updateAlbumArt` and `updateModelIfNeeded` (which is
    /// what actually calls `engine.loadPreset`, starting the transition) are always called together
    /// from the same `ProjectMMetalView.updateNSView` tick, fed by the same SwiftUI update - but
    /// SwiftUI doesn't guarantee `nowPlaying`'s artwork mutation and `visualizerModel.presetURL`'s
    /// mutation (set from ContentView's `trackReadySettledToken` `onChange`, a separate side effect
    /// that runs *after* the view update, not synchronously inside it) land in the same `body`
    /// evaluation - if they land a tick apart, `updateNSView` can run once with the new art but the
    /// still-old presetURL, and `latestRawImage` would already differ from `currentRawImage` with no
    /// transition active yet to gate against. Reading `engine.presetTransitionActive` fresh here -
    /// the exact same ground truth draw(in:)'s own uniforms read every frame for the crossfade - is
    /// what makes this deterministic instead of a timing race: the previous track's art stays the
    /// `current*` texture, genuinely on screen, until the wave that's supposed to carry it away has
    /// actually started.
    private func advanceAlbumArtAnimation(device: MTLDevice, now: CFTimeInterval) {
        if emptyAlbumArtTexture == nil {
            emptyAlbumArtTexture = Self.makeEmptyTexture(device: device)
        }

        if latestRawImage !== currentRawImage {
            // currentRawImage == nil - nothing on screen yet (this launch's very first track) -
            // there's nothing to crossfade away from, so promote immediately rather than waiting on
            // a transition that this app-launch preset restore never necessarily triggers.
            if currentRawImage == nil || engine?.presetTransitionActive == true {
                promoteToCurrentTrack(
                    device: device, rawImage: latestRawImage, colorKeyedImage: latestColorKeyedImage,
                    subjectImage: latestSubjectImage, subjectOnlyImage: latestSubjectOnlyImage,
                    textOnlyImage: latestTextOnlyImage, backgroundDetailImage: latestBackgroundDetailImage,
                    backgroundColorImage: latestBackgroundColorImage
                )
                awaitingTransitionSince = nil
            } else {
                // Waiting on the paired transition to start - see this function's own doc comment.
                // Bounded so a track change whose picked preset happens to already be the one
                // loaded (updateModelIfNeeded's URL-diff guard then never calls engine.loadPreset,
                // so presetTransitionActive never flips true for this art) can't leave the previous
                // track's art on screen forever - a rare, hard-cut fallback rather than a stuck UI.
                let waitStart = awaitingTransitionSince ?? now
                awaitingTransitionSince = waitStart
                if now - waitStart > Self.albumArtPromotionFallbackDelay {
                    promoteToCurrentTrack(
                        device: device, rawImage: latestRawImage, colorKeyedImage: latestColorKeyedImage,
                        subjectImage: latestSubjectImage, subjectOnlyImage: latestSubjectOnlyImage,
                        textOnlyImage: latestTextOnlyImage, backgroundDetailImage: latestBackgroundDetailImage,
                        backgroundColorImage: latestBackgroundColorImage
                    )
                    awaitingTransitionSince = nil
                }
            }
        } else {
            awaitingTransitionSince = nil
        }

        defer { lastAlbumArtTimestamp = now }
        let dt = lastAlbumArtTimestamp.map { Float(now - $0) } ?? 0
        updateBeatPulse(dt: dt)

        let hasContent = currentBackgroundTexture != nil || currentSubjectTexture != nil
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

    private func promoteToCurrentTrack(
        device: MTLDevice, rawImage: NSImage?, colorKeyedImage: NSImage?, subjectImage: NSImage?,
        subjectOnlyImage: NSImage?, textOnlyImage: NSImage?, backgroundDetailImage: NSImage?,
        backgroundColorImage: NSImage?
    ) {
        currentRawImage = rawImage

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
        updateSlowPresetWatchdog(dt: dt)
    }

    /// Empirical backstop for the curated-corpus guarantee that ships in Resources/Presets (see
    /// dev-notes/preset-fps-benchmark-2026-08-04): every bundled preset already measured 60fps+ in
    /// an offline headless benchmark, but that measurement is specific to one machine/resolution/
    /// synthetic-audio-signal, and explicit ⌘O/drag-and-drop/history/launch-restore loads can reach
    /// presets outside the curated corpus entirely. This reacts to what's actually being measured
    /// every frame, live, regardless of why a preset turned out slow: if smoothedFPS stays under
    /// slowFPSThreshold for
    /// slowPresetGracePeriodSeconds straight, the current preset is unwatchable regardless of why
    /// or how it was loaded, and gets reported once via model.slowPresetDetected so ContentView
    /// can step past it. The grace period absorbs the transient dip every fresh preset load causes
    /// (shader compile, transition ramp-up) without needing to special-case it here.
    private func updateSlowPresetWatchdog(dt: Double) {
        guard let currentURL = lastLoadedPresetURL else { return }
        if currentURL != watchdogPresetURL {
            watchdogPresetURL = currentURL
            slowFrameAccumulatedSeconds = 0
        }
        guard smoothedFPS < Self.slowFPSThreshold else {
            slowFrameAccumulatedSeconds = 0
            return
        }
        slowFrameAccumulatedSeconds += dt
        guard slowFrameAccumulatedSeconds >= Self.slowPresetGracePeriodSeconds else { return }
        guard reportedSlowPresetURL != currentURL else { return }
        reportedSlowPresetURL = currentURL
        NSLog("ProjectMCoordinator: preset stuck at ~\(Int(smoothedFPS.rounded()))fps for \(String(format: "%.1f", slowFrameAccumulatedSeconds))s, flagging as slow: \(currentURL.lastPathComponent)")
        model?.slowPresetDetected = currentURL
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
