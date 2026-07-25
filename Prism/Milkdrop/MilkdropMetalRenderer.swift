//
//  MilkdropMetalRenderer.swift
//  Prism
//
//  GPU replacement for the old WaveformTrailBuffer (a CGContext bitmap resized to the display
//  every frame — see the git history of MilkdropVisualizerView.swift for that version). This
//  renderer keeps the persistent "feedback" trail as two ping-ponged MTLTextures on the GPU:
//  each frame renders last frame's texture through a zoom/rotate/decay shader (Shaders.metal's
//  feedback_fragment) into the other texture, draws the new waveform/bars on top as real vertex
//  geometry, then presents that texture to the view. Nothing here scales with window/display
//  size the way the CPU version did — a fragment shader costs the same whether the render target
//  is 400x400 or 6K, so there's no need for the old CPU version's resolution cap.
//
//  Driven by MTKView's own display link (via MTKViewDelegate), not TimelineView — MTKView already
//  tracks the display's native refresh rate (including ProMotion's 120Hz) on its own.
//

import AppKit
import MetalKit
import SwiftUI
import simd

/// Same onset-detection logic as before (bass instant-energy vs. its own recently-smoothed trend,
/// both normalized against the same long-term average — see MilkdropAudioSignals.swift), just
/// relocated here since the render loop that drives it is now MTKView's draw(in:) instead of a
/// Canvas content closure.
final class MilkdropBeatState {
    private let analyzer = MilkdropSignalAnalyzer()
    private var lastFrameDate: Date?
    private var startDate: Date?
    private var lastTriggerDate: Date?
    private(set) var punch: CGFloat = 0

    private let onsetThreshold: Float = 0.55
    private let minimumBassFloor: Float = 1.05
    private let warmUpInterval: TimeInterval = 0.75
    private let refractoryInterval: TimeInterval = 0.11
    private let punchHalfLife: TimeInterval = 0.09

    /// Last frame's FPS estimate, for feeding a loaded preset's per-frame `fps` variable — see
    /// MilkdropVisualizerModel.updatePresetPerFrame.
    private(set) var lastFPS: Double = 60

    @discardableResult
    func update(left: [Float], right: [Float], sampleRate: Float, now: Date) -> MilkdropBandEnergy {
        let dt = lastFrameDate.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastFrameDate = now
        if startDate == nil { startDate = now }
        let fps = dt > 0 ? min(240.0, max(1.0, 1.0 / dt)) : 60.0
        lastFPS = fps

        let energy = analyzer.process(left: left, right: right, sampleRate: sampleRate, fps: fps)

        let warmedUp = now.timeIntervalSince(startDate!) > warmUpInterval
        let readyToRetrigger = lastTriggerDate.map { now.timeIntervalSince($0) > refractoryInterval } ?? true
        let onset = energy.bass - energy.bassAtt

        if warmedUp, readyToRetrigger, onset > onsetThreshold, energy.bass > minimumBassFloor {
            punch = 1.0
            lastTriggerDate = now
        } else if dt > 0 {
            punch *= CGFloat(pow(0.5, dt / punchHalfLife))
        }
        return energy
    }
}

final class MilkdropMetalRenderer: NSObject, MTKViewDelegate {
    private let audioEngine: CoreAudioTapEngine
    var model: MilkdropVisualizerModel
    var color: Color = .white
    var bassEnergy: CGFloat = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let solidPipeline: MTLRenderPipelineState
    private let feedbackPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState

    // Ping-pong feedback textures: textures[sourceIndex] is "what was on screen last frame" (read
    // this frame), textures[1 - sourceIndex] is this frame's render target. Swapped every frame.
    private var textures: [MTLTexture?] = [nil, nil]
    private var sourceIndex = 0
    private var textureSize: CGSize = .zero
    private var frameCounter = 0

    // First-draw timestamp, so `time` below is small and near-zero (like projectM's own
    // TimeKeeper::GetRunningTime(), elapsed seconds since the renderer started) rather than an
    // absolute epoch timestamp. That distinction matters: several wave modes cast `time` to
    // Float32, which only carries ~7.2 significant decimal digits. `Date().timeIntervalSinceReferenceDate`
    // is already ~7.9e8 in 2026, leaving Float32 only ~94 seconds of resolution at that magnitude —
    // `Float(time)` would sit frozen for a minute-plus, then jump discontinuously, instead of
    // advancing smoothly frame to frame. Modes that use `time` as a per-sample angle offset
    // (.circular/.spiral/.star/.flower/.skewedLoop) just looked like their rotation stalled and
    // snapped; .lasso uses sin(time)/cos(time) as a *global per-frame amplitude*, so the same jump
    // collapsed its entire shape toward a point for the frozen stretch, then flipped — the "short
    // line that alternates sides" symptom.
    private var renderStartDate: Date?

    private let beat = MilkdropBeatState()

    // Stabilizes the drawn waveform frame-to-frame (see MilkdropWaveformAligner.swift). Separate
    // per channel since projectM aligns L and R independently, each against its own prior frame.
    // Only feeds the point-generation/smoothing path below — beat/band-energy analysis still runs
    // on the raw, unaligned snapshot, matching how projectM keeps waveform alignment purely a
    // rendering-side concern, separate from its FFT-driven bass/mid/treb signal.
    private let waveformAlignerL = MilkdropWaveformAligner(
        bufferSampleCount: CoreAudioTapEngine.waveformSampleCount,
        visibleSampleCount: MilkdropWaveformAligner.visibleSampleCount
    )
    private let waveformAlignerR = MilkdropWaveformAligner(
        bufferSampleCount: CoreAudioTapEngine.waveformSampleCount,
        visibleSampleCount: MilkdropWaveformAligner.visibleSampleCount
    )

    init(audioEngine: CoreAudioTapEngine, model: MilkdropVisualizerModel) {
        self.audioEngine = audioEngine
        self.model = model

        // Every Mac Metal can plausibly run on has a capable GPU; there's no meaningful degraded
        // path for a GPU-rendered visualizer if this fails, so a hard failure here is honest
        // rather than limping along with a half-working renderer.
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this device")
        }
        self.device = device
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not load Shaders.metal's compiled library")
        }

        func makePipeline(vertex: String, fragment: String, additiveBlend: Bool) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            guard let attachment = descriptor.colorAttachments[0] else {
                fatalError("Missing color attachment 0 on pipeline descriptor")
            }
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = additiveBlend
            if additiveBlend {
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            // swiftlint:disable:next force_try
            return try! device.makeRenderPipelineState(descriptor: descriptor)
        }

        // Waveform/bars: additive ("plusLighter"-equivalent), matching the old CG blend mode —
        // overlapping strokes brighten instead of overpainting, giving the glowy scope look.
        self.solidPipeline = makePipeline(vertex: "solid_vertex", fragment: "solid_fragment", additiveBlend: true)
        // Feedback and present passes fully replace their target's contents (loadAction .clear
        // plus a full-screen quad), so blending would be a no-op — left off for clarity/cost.
        self.feedbackPipeline = makePipeline(vertex: "feedback_vertex", fragment: "feedback_fragment", additiveBlend: false)
        self.presentPipeline = makePipeline(vertex: "feedback_vertex", fragment: "present_fragment", additiveBlend: false)

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Textures are (re)created lazily at the top of draw(in:) instead — simpler than
        // coordinating state between two separate delegate callbacks for the same condition.
    }

    private func ensureTextures(size: CGSize) {
        guard size.width > 0, size.height > 0, size != textureSize else { return }
        textureSize = size

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(1, Int(size.width)),
            height: max(1, Int(size.height)),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        textures[0] = device.makeTexture(descriptor: descriptor)
        textures[1] = device.makeTexture(descriptor: descriptor)
        sourceIndex = 0

        // Fresh GPU-allocated textures hold undefined contents, not zeros — clear both to
        // transparent so a resize doesn't flash garbage for one frame.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        for texture in textures.compactMap({ $0 }) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        commandBuffer.commit()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let presentDescriptor = view.currentRenderPassDescriptor else { return }

        ensureTextures(size: view.drawableSize)
        guard let sourceTexture = textures[sourceIndex],
              let destTexture = textures[1 - sourceIndex] else { return }

        let pixelSize = view.drawableSize
        let now = Date()

        let (left, right) = audioEngine.snapshotWaveform()

        // Align only the copies feeding the drawn waveform; `left`/`right` themselves stay raw for
        // beat.update() below, which needs the full, unshifted buffer for its FFT bands.
        var alignedLeft = left
        var alignedRight = right
        waveformAlignerL.align(&alignedLeft)
        waveformAlignerR.align(&alignedRight)
        let visibleLeft = Array(alignedLeft.prefix(MilkdropWaveformAligner.visibleSampleCount))
        let visibleRight = Array(alignedRight.prefix(MilkdropWaveformAligner.visibleSampleCount))

        let scaledLeft = MilkdropWaveform.smoothed(visibleLeft, scale: model.params.scale, smoothing: model.params.smoothing)
        let scaledRight = MilkdropWaveform.smoothed(visibleRight, scale: model.params.scale, smoothing: model.params.smoothing)

        // CoreAudioTapEngine taps the system default output device, so 44.1kHz is the common case.
        let energy = beat.update(left: left, right: right, sampleRate: 44100, now: now)
        let punch = beat.punch

        if renderStartDate == nil { renderStartDate = now }
        let time = now.timeIntervalSince(renderStartDate!)
        frameCounter += 1
        // Drives a loaded preset's per-frame expression program (if any) before this frame's
        // points get generated below, so mode/params reflect this frame's evaluated values.
        model.updatePresetPerFrame(time: time, fps: beat.lastFPS, frame: frameCounter, energy: energy)
        let aspect = pixelSize.width > 0 ? Float(pixelSize.height / pixelSize.width) : 1
        let (rawPoints, rawBreak) = MilkdropWaveform.points(
            mode: model.mode, left: scaledLeft, right: scaledRight,
            params: model.params, time: time, aspect: aspect
        )
        let isLoop = model.mode.isLoop
        let (tessPoints, tessBreak): ([WavePoint], Int?) = isLoop
            ? (MilkdropWaveform.tessellatedLoop(rawPoints), nil)
            : MilkdropWaveform.tessellated(rawPoints, segmentBreak: rawBreak)

        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var colorVec = SIMD4<Float>(Float(nsColor.redComponent), Float(nsColor.greenComponent), Float(nsColor.blueComponent), 1)

        // Vertex data is built directly in physical-pixel (drawableSize) space, so a "points"
        // width needs the view's actual backing scale, not a hardcoded 2x.
        let backingScale = view.bounds.width > 0 ? pixelSize.width / view.bounds.width : 2.0
        let lineWidthPx = Float(1.6 + bassEnergy * 2.2 + punch * 1.4) * Float(backingScale)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // MARK: Pass 1 — feedback (decayed/zoomed/rotated previous frame) + new stroke, into destTexture

        let feedbackPass = MTLRenderPassDescriptor()
        feedbackPass.colorAttachments[0].texture = destTexture
        feedbackPass.colorAttachments[0].loadAction = .clear
        feedbackPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        feedbackPass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: feedbackPass) else { return }

        let rotation = Float(0.0025 + punch * 0.01)
        let zoom = Float(1.006 + punch * 0.035)
        var cosRot = cosf(rotation)
        var sinRot = sinf(rotation)
        var invZoom = 1.0 / zoom
        var decay: Float = 0.90

        encoder.setRenderPipelineState(feedbackPipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentBytes(&cosRot, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentBytes(&sinRot, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setFragmentBytes(&invZoom, length: MemoryLayout<Float>.stride, index: 2)
        encoder.setFragmentBytes(&decay, length: MemoryLayout<Float>.stride, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.setRenderPipelineState(solidPipeline)
        var viewport = SIMD2<Float>(Float(pixelSize.width), Float(pixelSize.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&colorVec, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        if model.mode == .spectrumBars {
            let verts = Self.barVertices(bands: audioEngine.levels, pixelSize: pixelSize)
            Self.draw(verts, as: .triangle, on: encoder, device: device)
        } else {
            let halfWidth = lineWidthPx * 0.5
            var segments: [[WavePoint]] = []
            if let tessBreak, tessBreak > 0, tessBreak < tessPoints.count {
                segments.append(Array(tessPoints[0..<tessBreak]))
                segments.append(Array(tessPoints[tessBreak...]))
            } else {
                segments.append(tessPoints)
            }
            for segment in segments {
                let verts = Self.lineStripVertices(points: segment, pixelSize: pixelSize, halfWidth: halfWidth, isLoop: isLoop)
                Self.draw(verts, as: .triangleStrip, on: encoder, device: device)
            }
        }

        encoder.endEncoding()

        // MARK: Pass 2 — present destTexture to the drawable

        guard let presentEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: presentDescriptor) else {
            commandBuffer.commit()
            return
        }
        presentEncoder.setRenderPipelineState(presentPipeline)
        presentEncoder.setFragmentTexture(destTexture, index: 0)
        presentEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        presentEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        sourceIndex = 1 - sourceIndex
    }

    // MARK: - CPU-side geometry building (cheap: a few hundred vertices, not a bottleneck)

    private static func draw(_ vertices: [SIMD2<Float>], as primitive: MTLPrimitiveType, on encoder: MTLRenderCommandEncoder, device: MTLDevice) {
        let minCount = primitive == .triangleStrip ? 2 : 3
        guard vertices.count >= minCount,
              let buffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<SIMD2<Float>>.stride * vertices.count, options: .storageModeShared)
        else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: vertices.count)
    }

    /// Triangle-strip ribbon for a polyline: two vertices per point, offset ±halfWidth along the
    /// local normal (from neighboring points). Overlapping geometry at sharp turns isn't
    /// miter-joined — with additive blending that just reads as a slightly brighter joint, which
    /// suits the glowing-scope look rather than fighting it.
    ///
    /// `isLoop` (closed-ring modes — see MilkdropWaveMode.isLoop): `points`' last entry duplicates
    /// the first (added purely so the GPU strip visually closes), so neighbor lookups wrap around
    /// that (n-1)-point cycle instead of clamping at the array's literal ends. Clamping there would
    /// give the seam a zero-length "before"/"after" vector on one side, pinching the ring's width
    /// right at the closure.
    private static func lineStripVertices(points: [WavePoint], pixelSize: CGSize, halfWidth: Float, isLoop: Bool) -> [SIMD2<Float>] {
        guard points.count > 1 else { return [] }
        let n = points.count
        let cycle = isLoop ? n - 1 : n
        func toPixel(_ p: WavePoint) -> SIMD2<Float> {
            SIMD2<Float>(p.x * 0.5 * Float(pixelSize.width), p.y * 0.5 * Float(pixelSize.height))
        }
        var verts = [SIMD2<Float>]()
        verts.reserveCapacity(n * 2)
        for i in 0..<n {
            let p = toPixel(points[i])
            let a: SIMD2<Float>
            let b: SIMD2<Float>
            if isLoop, cycle > 0 {
                let idx = i % cycle
                a = toPixel(points[(idx - 1 + cycle) % cycle])
                b = toPixel(points[(idx + 1) % cycle])
            } else {
                a = toPixel(points[max(0, i - 1)])
                b = toPixel(points[min(n - 1, i + 1)])
            }
            var tangent = b - a
            let len = simd_length(tangent)
            tangent = len > 0.0001 ? (tangent / len) : SIMD2<Float>(1, 0)
            let normal = SIMD2<Float>(-tangent.y, tangent.x)
            verts.append(p + normal * halfWidth)
            verts.append(p - normal * halfWidth)
        }
        return verts
    }

    /// Two triangles per bar, mirrored around the vertical center — same layout as the old
    /// strokeSpectrumBars, just as real triangles instead of CGRect fills.
    private static func barVertices(bands: [CGFloat], pixelSize: CGSize) -> [SIMD2<Float>] {
        guard !bands.isEmpty else { return [] }
        let barCount = bands.count
        let widthPx = Float(pixelSize.width)
        let heightPx = Float(pixelSize.height)
        let spacing = widthPx * 0.10 / Float(barCount)
        let barWidth = max(1, (widthPx - spacing * Float(barCount - 1)) / Float(barCount))

        var verts = [SIMD2<Float>]()
        verts.reserveCapacity(barCount * 6)
        for i in 0..<barCount {
            let magnitude = max(2, Float(bands[i]) * heightPx * 0.45)
            let xLeft = Float(i) * (barWidth + spacing) - widthPx / 2
            let xRight = xLeft + barWidth
            let (y0, y1): (Float, Float) = (-magnitude, magnitude)
            verts.append(SIMD2(xLeft, y0)); verts.append(SIMD2(xRight, y0)); verts.append(SIMD2(xLeft, y1))
            verts.append(SIMD2(xRight, y0)); verts.append(SIMD2(xRight, y1)); verts.append(SIMD2(xLeft, y1))
        }
        return verts
    }
}
