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
}

/// The four stages of the album-art choreography (see ProjectMCompositeShader.metal's own header)
/// - raw Float, not an enum, since it's written straight into AlbumArtUniforms.stage.
private enum AlbumArtStage {
    static let scaleIn: Float = 0
    static let separate: Float = 1
    static let steady: Float = 2
    static let outgoingExit: Float = 3
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
    private static let scaleInDuration: Float = 6.0
    private static let separateDuration: Float = 6.0
    private static let subjectExitDuration: Float = 6.0
    private static let albumArtSizePixels: Float = 640
    private static let globalAlphaEaseSpeed: Float = 8

    private var textureLoader: MTKTextureLoader?
    private var emptyAlbumArtTexture: MTLTexture?

    // "Current" track's two puzzle pieces - the Vision subject cutout, and the raw cover with a
    // subject-shaped hole punched out of it (see backgroundWithSubjectHole) so the two together
    // reconstitute the full cover with no pixel double-covered by both layers at once. Without the
    // hole, the background layer growing past the locked subject during separate would show a
    // faint enlarging "ghost" of the subject bleeding out from behind it, since the background
    // would otherwise still be carrying the subject's own pixels underneath. currentBackgroundTexture
    // is nil-mask-safe: backgroundWithSubjectHole just returns the raw cover untouched when there's
    // no subject to cut, so this degrades to the original single-layer behavior automatically.
    private var currentBackgroundTexture: MTLTexture?
    private var currentSubjectTexture: MTLTexture?
    private var currentRawImage: NSImage?
    private var trackAnimationClock: Float = 0

    // Next track's assets, queued the moment NowPlayingManager hands over new artwork but held
    // back from becoming "current" until the outgoing subject below has finished dissolving away -
    // so the two tracks' art never overlaps on screen.
    private var pendingRawImage: NSImage?
    private var pendingSubjectImage: NSImage?

    // Previous track's subject (or, if Vision found no subject, its whole raw cover) dissolving
    // away before `pending` is promoted to `current` - see advanceAlbumArtAnimation.
    private var outgoingTexture: MTLTexture?
    private var outgoingExitClock: Float = 0
    private var isOutgoingExitActive = false

    private var latestRawImage: NSImage?
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
    func updateAlbumArt(rawImage: NSImage?, subjectImage: NSImage?, hidden: Bool) {
        latestRawImage = rawImage
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
            backgroundScale: backgroundScale
        )

        let backgroundTex = currentBackgroundTexture ?? emptyAlbumArtTexture
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
                promoteToCurrentTrack(device: device, rawImage: latestRawImage, subjectImage: latestSubjectImage)
            } else {
                pendingRawImage = latestRawImage
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
                promoteToCurrentTrack(device: device, rawImage: pendingRawImage, subjectImage: pendingSubjectImage)
                pendingRawImage = nil
                pendingSubjectImage = nil
            }
        } else {
            trackAnimationClock += dt
        }

        let hasContent = currentBackgroundTexture != nil || isOutgoingExitActive
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

    /// One constant-velocity ramp (rate = 1 full size per scaleInDuration seconds) spanning
    /// scaleIn and separate both, so there's no perceptible speed change at the boundary between
    /// them - only what stops moving there changes. `subjectScale` follows that ramp until it
    /// hits 1 (i.e. for the whole of scaleIn) then holds there for good; `backgroundScale` keeps
    /// following the exact same ramp past that point for as long as there's a subject to leave
    /// behind, or holds at 1 too if there's no subject to separate from (see AlbumArtStage.separate
    /// in ProjectMCompositeShader.metal's header for why that case skips growing at all).
    private func albumArtScales(hasSubjectMask: Bool) -> (subject: Float, background: Float) {
        let subjectScale = min(trackAnimationClock / Self.scaleInDuration, 1)
        let backgroundScale = hasSubjectMask ? (trackAnimationClock / Self.scaleInDuration) : subjectScale
        return (subjectScale, backgroundScale)
    }

    private func promoteToCurrentTrack(device: MTLDevice, rawImage: NSImage?, subjectImage: NSImage?) {
        currentRawImage = rawImage
        let backgroundImage = rawImage.map { Self.backgroundWithSubjectHole(raw: $0, subjectMask: subjectImage) }
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
