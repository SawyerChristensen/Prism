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

/// Mirrors ProjectMCompositeShader.metal's AlbumArtUniforms struct field-for-field.
private struct AlbumArtUniforms {
    var waveTexelSize: SIMD2<Float>
    var artCenter: SIMD2<Float>
    var artHalfSize: SIMD2<Float>
    var stage: Float
    var stageProgress: Float
    var hasSubjectMask: Float
    var globalAlpha: Float
    var distortionStrength: Float
    // Precomputed here (not derived from stage/stageProgress in the shader) so the growth rate is
    // one continuous, constant-velocity ramp straight through the scaleIn -> separate boundary -
    // see albumArtScales(). subjectScale locks at 1 the moment it gets there; backgroundScale just
    // keeps going at that exact same rate.
    var subjectScale: Float
    var backgroundScale: Float
    // 0...1 fade used by the reverse (scale-down) and slide intros - see introStyle. The forward
    // intro's own materialize effect comes entirely from scale (see AlbumArtStage.scaleIn's own
    // doc comment), so this stays pinned at 1 the whole time for that variant; a no-op multiply.
    var introAlpha: Float
    // Which of the four intro choreographies this track got (see AlbumArtIntroStyle) - only
    // consulted by the shader during stage 0.
    var introStyle: Float
    // Screen-space translation (same [0,1] space as artCenter/texCoord) applied to each layer's own
    // effective art center - (0, 0) for forward/reverseScale (no movement at all); for slideRight,
    // x runs slideStartOffset -> 0 -> negative (y stays 0); for slideDown, y runs -slideStartOffset
    // -> 0 -> positive (x stays 0) - see albumArtOffsets().
    var subjectOffset: SIMD2<Float>
    var backgroundOffset: SIMD2<Float>
}

/// The four stages of the album-art choreography (see ProjectMCompositeShader.metal's own header)
/// - raw Float, not an enum, since it's written straight into AlbumArtUniforms.stage.
private enum AlbumArtStage {
    static let scaleIn: Float = 0
    static let separate: Float = 1
    static let steady: Float = 2
    static let outgoingExit: Float = 3
}

/// The four intro choreographies stage 0 can play - raw Float, not an enum, for the same reason
/// as AlbumArtStage above (written straight into AlbumArtUniforms.introStyle).
private enum AlbumArtIntroStyle {
    static let forward: Float = 0
    static let reverseScale: Float = 1
    static let slideRight: Float = 2
    static let slideDown: Float = 3
    // In this fixed order, cycled through one-per-track by promoteToCurrentTrack (TEMP TESTING) so
    // every style gets a turn in a predictable sequence rather than a random draw.
    static let all: [Float] = [forward, reverseScale, slideRight, slideDown]
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

    // Album art choreography - see ProjectMCompositeShader.metal's header for the four stages and
    // advanceAlbumArtAnimation below for the state machine that drives them. emptyAlbumArtTexture
    // stands in for any texture slot with nothing real to show, so the shader always runs the same
    // code path rather than branching per-frame on "has art or not."
    private static let scaleInDuration: Float = 8.0
    private static let separateDuration: Float = 8.0
    private static let subjectExitDuration: Float = 8.0
    private static let albumArtSizePixels: Float = 640
    private static let globalAlphaEaseSpeed: Float = 8
    // How zoomed-in the reverse intro starts (see introStyle) - the ramp runs
    // reverseIntroStartScale -> 1 over scaleIn, then keeps going at that same rate through
    // separate, same "one continuous ramp" shape as the forward intro's 0 -> 1 -> beyond.
    // introAlpha's cubic ease-in (shared with the slide intros - do not change to "fix" this) stays
    // under ~50% opacity until t > ~0.79 of scaleIn, so only the last ~20% of this ramp is ever seen
    // at any meaningful opacity. 2.2 left that visible tail shrinking from only ~1.25x -> 1x - too
    // subtle to read as motion at all. 4.0 leaves a ~1.6x -> 1x shrink still happening as opacity
    // climbs through that same tail, so the zoom is actually visible once the art materializes.
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
    private var currentRawImage: NSImage?
    private var trackAnimationClock: Float = 0
    // Which of the four intro choreographies this track got, picked once per track in
    // promoteToCurrentTrack:
    //   forward      - scale 0 -> 1, materializes via the shrink-to-a-point UV trick (see
    //                  AlbumArtStage.scaleIn).
    //   reverseScale - starts at reverseIntroStartScale - zoomed in, fully transparent, and pre-
    //                  dissolved/scattered by the wave's own gradient field, same as outgoingExit's
    //                  own tear-apart but run backward - then shrinks to 1, fades in, and
    //                  reassembles all in lockstep.
    //   slideRight   - scale pinned at 1 throughout (no zoom at all); instead starts
    //                  slideStartOffset off to the right, fully transparent and pre-dissolved just
    //                  like reverseScale, and slides in to center while fading in and reassembling.
    //   slideDown    - same as slideRight, just rotated 90 degrees: starts slideStartOffset off the
    //                  top of the screen and slides down to center instead.
    // See albumArtScales/albumArtOffsets/introAlpha and the shader's own wave_dissolve_walk. Only
    // affects how scaleIn plays out; separate/steady/outgoingExit are identical across all three.
    private var introStyle: Float = AlbumArtIntroStyle.forward
    // TEMP TESTING: advances by one every promoteToCurrentTrack call, indexing into
    // AlbumArtIntroStyle.all round-robin - see that call site.
    private var introStyleCycleIndex = 0

    // Next track's assets, queued the moment NowPlayingManager hands over new artwork but held
    // back from becoming "current" until the outgoing subject below has finished dissolving away -
    // so the two tracks' art never overlaps on screen.
    private var pendingRawImage: NSImage?
    private var pendingColorKeyedImage: NSImage?
    private var pendingSubjectImage: NSImage?

    // Previous track's subject (or, if Vision found no subject, its whole raw cover) dissolving
    // away before `pending` is promoted to `current` - see advanceAlbumArtAnimation.
    private var outgoingTexture: MTLTexture?
    private var outgoingExitClock: Float = 0
    private var isOutgoingExitActive = false

    private var latestRawImage: NSImage?
    private var latestColorKeyedImage: NSImage?
    private var latestSubjectImage: NSImage?
    private var albumArtHidden = false
    // "H" hidden-toggle / nothing-loaded-yet mute, eased quickly (not the stage choreography's own
    // pacing) toward 0 or 1 each frame - independent of, and multiplied on top of, whichever stage
    // is currently driving the animation.
    private var globalAlpha: Float = 0
    private var lastAlbumArtTimestamp: CFTimeInterval?

    private var lastLoadedPresetURL: URL?
    private weak var model: ProjectMVisualizerModel?

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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Called from ProjectMMetalView.updateNSView every SwiftUI update tick (cheap: just stored
    /// properties) - the real work (texture uploads, stage transitions) happens lazily in
    /// draw(in:)'s advanceAlbumArtAnimation, since that's where a live MTLDevice is on hand.
    func updateAlbumArt(rawImage: NSImage?, colorKeyedImage: NSImage?, subjectImage: NSImage?, hidden: Bool) {
        latestRawImage = rawImage
        latestColorKeyedImage = colorKeyedImage
        latestSubjectImage = subjectImage
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

        // Art square is a fixed 640x640 device pixels (Spotify's own artwork resolution),
        // centered - the same spot SwiftUI's ZStack centered it by default before this moved
        // into the shader.
        let (stage, stageProgress) = albumArtStageAndProgress()
        let hasSubjectMask = !isOutgoingExitActive && currentSubjectTexture != nil
        let (subjectScale, backgroundScale) = albumArtScales(hasSubjectMask: hasSubjectMask)
        let (subjectOffset, backgroundOffset) = albumArtOffsets(hasSubjectMask: hasSubjectMask)
        var uniforms = AlbumArtUniforms(
            waveTexelSize: SIMD2(1.0 / Float(width), 1.0 / Float(height)),
            artCenter: SIMD2(0.5, 0.5),
            artHalfSize: SIMD2(
                Self.albumArtSizePixels / 2.0 / Float(width), Self.albumArtSizePixels / 2.0 / Float(height)
            ),
            stage: stage,
            stageProgress: stageProgress,
            hasSubjectMask: hasSubjectMask ? 1 : 0,
            globalAlpha: globalAlpha,
            distortionStrength: 0.06,
            subjectScale: subjectScale,
            backgroundScale: backgroundScale,
            introAlpha: introAlpha(),
            introStyle: introStyle,
            subjectOffset: subjectOffset,
            backgroundOffset: backgroundOffset
        )

        // scaleIn shows the genuinely full cover (no hole) as its background layer; separate/steady
        // switch to the hole-punched version the instant the subject locks and the rest starts
        // pulling away - see currentFullBackgroundTexture/currentBackgroundTexture's own doc comment.
        let backgroundTex = (stage == AlbumArtStage.scaleIn ? currentFullBackgroundTexture : currentBackgroundTexture)
            ?? emptyAlbumArtTexture
        let subjectTex = (isOutgoingExitActive ? outgoingTexture : currentSubjectTexture) ?? emptyAlbumArtTexture

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(backgroundTex, index: 1)
        encoder.setFragmentTexture(subjectTex, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AlbumArtUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Drives the scaleIn -> separate -> steady -> (on a track change) outgoingExit state machine:
    /// detects a new track's artwork, uploads its textures, advances whichever clock is currently
    /// active, and promotes `pending` to `current` once an outgoing subject has fully dissolved
    /// away. Cheap when nothing's changing - the common case is just two clock increments.
    private func advanceAlbumArtAnimation(device: MTLDevice, now: CFTimeInterval) {
        if emptyAlbumArtTexture == nil {
            emptyAlbumArtTexture = Self.makeEmptyTexture(device: device)
        }

        if latestRawImage !== currentRawImage, latestRawImage !== pendingRawImage {
            if currentRawImage == nil {
                // First track this launch - nothing on screen yet to dissolve away first.
                promoteToCurrentTrack(
                    device: device, rawImage: latestRawImage, colorKeyedImage: latestColorKeyedImage,
                    subjectImage: latestSubjectImage
                )
            } else {
                pendingRawImage = latestRawImage
                pendingColorKeyedImage = latestColorKeyedImage
                pendingSubjectImage = latestSubjectImage
                if !isOutgoingExitActive {
                    // Vision may have found no subject for the outgoing track either - erode the
                    // whole cover in that case rather than nothing at all.
                    outgoingTexture = currentSubjectTexture ?? currentBackgroundTexture
                    isOutgoingExitActive = true
                    outgoingExitClock = 0
                }
            }
        }

        defer { lastAlbumArtTimestamp = now }
        let dt = lastAlbumArtTimestamp.map { Float(now - $0) } ?? 0

        if isOutgoingExitActive {
            outgoingExitClock += dt
            if outgoingExitClock >= Self.subjectExitDuration {
                isOutgoingExitActive = false
                outgoingTexture = nil
                promoteToCurrentTrack(
                    device: device, rawImage: pendingRawImage, colorKeyedImage: pendingColorKeyedImage,
                    subjectImage: pendingSubjectImage
                )
                pendingRawImage = nil
                pendingColorKeyedImage = nil
                pendingSubjectImage = nil
            }
        } else {
            trackAnimationClock += dt
        }

        let hasContent = currentBackgroundTexture != nil || currentSubjectTexture != nil || isOutgoingExitActive
        let target: Float = (hasContent && !albumArtHidden) ? 1 : 0
        globalAlpha += (target - globalAlpha) * min(1, max(0, dt) * Self.globalAlphaEaseSpeed)
    }

    private func albumArtStageAndProgress() -> (stage: Float, progress: Float) {
        if isOutgoingExitActive {
            return (AlbumArtStage.outgoingExit, min(1, outgoingExitClock / Self.subjectExitDuration))
        }
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

    /// 0...1 fade the reverseScale and slideIn intros use to materialize (the forward intro doesn't
    /// need this - see AlbumArtUniforms.introAlpha). Driven by the same clock as albumArtScales/
    /// albumArtOffsets, so the fade and the shrink/slide-to-rest both land at the same instant;
    /// freezes wherever it was (rather than snapping) if a track change interrupts scaleIn, since
    /// trackAnimationClock itself stops advancing once isOutgoingExitActive - see
    /// advanceAlbumArtAnimation. Cubic ease-in rather than a straight ramp, so the fade starts nearly
    /// imperceptible and snaps up to full opacity right at the end instead of ticking up at a
    /// constant rate - see easeIn's own doc comment.
    private func introAlpha() -> Float {
        guard introStyle != AlbumArtIntroStyle.forward else { return 1 }
        return Self.easeIn(min(trackAnimationClock / Self.scaleInDuration, 1))
    }

    /// Cubic ease-in: 0...1 in, 0...1 out, starting flat and curving up into a steep, fast finish -
    /// unlike a straight `t` ramp, equal steps in `t` produce ever-larger steps in the output, and
    /// unlike a plain square this stays low for longer before its finishing snap. Shared by
    /// introAlpha here and the shader's own dissolve-amount curve (ProjectMCompositeShader.metal's
    /// ease_in), so the opacity fade and the wave-dissolve reassembly accelerate in lockstep.
    private static func easeIn(_ t: Float) -> Float {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * clamped
    }

    private func promoteToCurrentTrack(device: MTLDevice, rawImage: NSImage?, colorKeyedImage: NSImage?, subjectImage: NSImage?) {
        currentRawImage = rawImage
        // TEMP TESTING: step through all four intro styles in a fixed round-robin, one per track,
        // instead of a random pick, so every style can be previewed in turn.
        introStyle = AlbumArtIntroStyle.all[introStyleCycleIndex % AlbumArtIntroStyle.all.count]
        introStyleCycleIndex += 1

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
        trackAnimationClock = 0
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
