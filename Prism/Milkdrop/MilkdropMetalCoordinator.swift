//
//  MilkdropMetalCoordinator.swift
//  Prism
//
//  Preset-to-preset crossfade (TO DO.md Phase 3 — "Preset blending/crossfade transitions"). Real
//  Milkdrop/projectM renders the outgoing and incoming preset's ENTIRE pipelines simultaneously
//  (each with its own feedback-texture history, NS-EEL state, shapes/waveforms) and alpha-blends
//  their live output — not a freeze-frame dissolve. `MilkdropMetalRenderer` already is, in
//  isolation, exactly "render one preset's whole pipeline into a texture" (see its
//  `renderToTexture(view:)`), so this coordinator gets a faithful dual-live-render blend for free
//  by simply holding *two* renderer instances during a transition and compositing their outputs,
//  rather than needing a parallel single-renderer-does-everything rewrite.
//
//  `MTKView`'s delegate used to be `MilkdropMetalRenderer` itself; this coordinator now takes that
//  role, so a genuinely per-preset renderer instance can be created/discarded per preset load
//  without ever needing more than one MTKViewDelegate installed on the view.
//

import MetalKit
import SwiftUI

/// GPU resources that don't vary per preset — pipelines/samplers/static functions/fixed geometry,
/// all created once and shared by every `MilkdropMetalRenderer` instance (including the outgoing
/// one kept alive for a transition's duration), so switching presets (now potentially every few
/// seconds, with auto-cycle on) never re-compiles ~15 pipeline states or regenerates the noise
/// texture catalog. `MilkdropCustomTextureManager` is deliberately *not* here — see
/// `MilkdropMetalRenderer`'s own `customTextures` doc comment for why that one has to stay
/// per-instance despite looking just as "static" as everything else in this class.
final class MilkdropSharedRenderResources {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let solidPipeline: MTLRenderPipelineState
    let feedbackPipeline: MTLRenderPipelineState
    let presentPipeline: MTLRenderPipelineState
    let oldStyleCompositePipeline: MTLRenderPipelineState
    let feedbackMeshPipeline: MTLRenderPipelineState
    let meshIndexBuffer: MTLBuffer
    let shapeAdditivePipeline: MTLRenderPipelineState
    let shapeAlphaPipeline: MTLRenderPipelineState
    let shapeTexturedAdditivePipeline: MTLRenderPipelineState
    let shapeTexturedAlphaPipeline: MTLRenderPipelineState
    let feedbackVertexFunction: MTLFunction
    let feedbackMeshVertexFunction: MTLFunction
    let feedbackMeshFragmentFunction: MTLFunction
    let samplerLinearRepeat: MTLSamplerState
    let samplerLinearClamp: MTLSamplerState
    let samplerNearestRepeat: MTLSamplerState
    let samplerNearestClamp: MTLSamplerState
    let noiseTextures: MilkdropNoiseTextures?
    /// Vertex: `feedback_vertex` (the same static full-screen-quad vertex function every other
    /// fixed pipeline here reuses), fragment: `milkdrop_crossfade_fragment` — see
    /// MilkdropMetalCoordinator.presentCrossfade(...).
    let crossfadePipeline: MTLRenderPipelineState

    init() {
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
        self.oldStyleCompositePipeline = makePipeline(vertex: "feedback_vertex", fragment: "milkdrop_old_style_final_composite", additiveBlend: false)
        self.crossfadePipeline = makePipeline(vertex: "feedback_vertex", fragment: "milkdrop_crossfade_fragment", additiveBlend: false)

        func makeBlendedPipeline(vertex: String, fragment: String, sourceFactor: MTLBlendFactor, destFactor: MTLBlendFactor) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            guard let attachment = descriptor.colorAttachments[0] else {
                fatalError("Missing color attachment 0 on pipeline descriptor")
            }
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = sourceFactor
            attachment.sourceAlphaBlendFactor = sourceFactor
            attachment.destinationRGBBlendFactor = destFactor
            attachment.destinationAlphaBlendFactor = destFactor
            // swiftlint:disable:next force_try
            return try! device.makeRenderPipelineState(descriptor: descriptor)
        }

        self.shapeAdditivePipeline = makeBlendedPipeline(
            vertex: "shape_vertex", fragment: "shape_fragment", sourceFactor: .sourceAlpha, destFactor: .one
        )
        self.shapeAlphaPipeline = makeBlendedPipeline(
            vertex: "shape_vertex", fragment: "shape_fragment", sourceFactor: .sourceAlpha, destFactor: .oneMinusSourceAlpha
        )
        self.shapeTexturedAdditivePipeline = makeBlendedPipeline(
            vertex: "shape_textured_vertex", fragment: "shape_textured_fragment", sourceFactor: .sourceAlpha, destFactor: .one
        )
        self.shapeTexturedAlphaPipeline = makeBlendedPipeline(
            vertex: "shape_textured_vertex", fragment: "shape_textured_fragment", sourceFactor: .sourceAlpha, destFactor: .oneMinusSourceAlpha
        )

        guard let feedbackVertexFunction = library.makeFunction(name: "feedback_vertex") else {
            fatalError("Could not load Shaders.metal's feedback_vertex function")
        }
        self.feedbackVertexFunction = feedbackVertexFunction

        self.feedbackMeshPipeline = makePipeline(vertex: "feedback_mesh_vertex", fragment: "feedback_mesh_fragment", additiveBlend: false)

        guard let feedbackMeshVertexFunction = library.makeFunction(name: "feedback_mesh_vertex") else {
            fatalError("Could not load Shaders.metal's feedback_mesh_vertex function")
        }
        self.feedbackMeshVertexFunction = feedbackMeshVertexFunction

        guard let feedbackMeshFragmentFunction = library.makeFunction(name: "feedback_mesh_fragment") else {
            fatalError("Could not load Shaders.metal's feedback_mesh_fragment function")
        }
        self.feedbackMeshFragmentFunction = feedbackMeshFragmentFunction

        let meshIndices = MilkdropPerPixelMeshRuntime.sharedIndices
        guard let meshIndexBuffer = device.makeBuffer(
            bytes: meshIndices, length: MemoryLayout<UInt16>.stride * meshIndices.count, options: .storageModeShared
        ) else {
            fatalError("Could not allocate the per-pixel warp mesh's index buffer")
        }
        self.meshIndexBuffer = meshIndexBuffer

        func makeSampler(filter: MTLSamplerMinMagFilter, address: MTLSamplerAddressMode) -> MTLSamplerState {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = address
            descriptor.tAddressMode = address
            descriptor.rAddressMode = address
            // swiftlint:disable:next force_unwrapping
            return device.makeSamplerState(descriptor: descriptor)!
        }
        self.samplerLinearRepeat = makeSampler(filter: .linear, address: .repeat)
        self.samplerLinearClamp = makeSampler(filter: .linear, address: .clampToEdge)
        self.samplerNearestRepeat = makeSampler(filter: .nearest, address: .repeat)
        self.samplerNearestClamp = makeSampler(filter: .nearest, address: .clampToEdge)

        self.noiseTextures = MilkdropNoiseTextures(device: device)
    }
}

/// Installed as the `MTKView`'s actual delegate (replacing `MilkdropMetalRenderer` in that role —
/// see this file's header). Owns whichever preset is currently front-facing (`activeRenderer`)
/// plus, only for a transition's duration, the preset it's fading out of (`outgoingRenderer`).
final class MilkdropMetalCoordinator: NSObject, MTKViewDelegate {
    private let shared = MilkdropSharedRenderResources()
    private let audioEngine: CoreAudioTapEngine
    private var activeRenderer: MilkdropMetalRenderer
    private var outgoingRenderer: MilkdropMetalRenderer?
    private var transitionStartDate: Date?
    /// Real projectM's own default (`ProjectM.hpp`'s `m_softCutDuration{3.0}`) — not a guess.
    private let transitionDuration: TimeInterval = 3.0

    var color: Color = .white {
        didSet {
            activeRenderer.color = color
            outgoingRenderer?.color = color
        }
    }
    var bassEnergy: CGFloat = 0 {
        didSet {
            activeRenderer.bassEnergy = bassEnergy
            outgoingRenderer?.bassEnergy = bassEnergy
        }
    }

    init(audioEngine: CoreAudioTapEngine, model: MilkdropVisualizerModel) {
        self.audioEngine = audioEngine
        self.activeRenderer = MilkdropMetalRenderer(shared: shared, audioEngine: audioEngine, model: model)
        super.init()
    }

    /// Called from `MilkdropMetalView.updateNSView` whenever SwiftUI hands down a `model` that
    /// isn't the same instance as last time — i.e. `ContentView.loadPresetAndTrack` just swapped in
    /// a freshly-loaded preset (see its own doc comment on why that's a *new* `MilkdropVisualizerModel`
    /// instance rather than a mutation of the existing one). Starts a new transition; any
    /// already-in-flight one is dropped in favor of the new one, matching real projectM's own
    /// `StartPresetTransition` behavior ("if already in a transition, force immediate completion").
    func updateModelIfNeeded(_ newModel: MilkdropVisualizerModel) {
        guard newModel !== activeRenderer.model else { return }
        outgoingRenderer = activeRenderer
        let renderer = MilkdropMetalRenderer(shared: shared, audioEngine: audioEngine, model: newModel)
        renderer.color = color
        renderer.bassEnergy = bassEnergy
        activeRenderer = renderer
        transitionStartDate = Date()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Textures are (re)created lazily at the top of renderToTexture(view:) instead — simpler
        // than coordinating state between two separate delegate callbacks for the same condition
        // (see MilkdropMetalRenderer.ensureTextures).
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let presentDescriptor = view.currentRenderPassDescriptor else { return }

        guard let activeTexture = activeRenderer.renderToTexture(view: view) else { return }

        guard let outgoingRenderer else {
            present(activeTexture, drawable: drawable, descriptor: presentDescriptor)
            return
        }

        // The outgoing preset keeps rendering its own full live pipeline (own feedback-texture
        // history, own per-frame script evaluation, own audio-reactive shapes/waveforms) for the
        // whole transition — not a frozen last-frame snapshot. If it fails to produce a frame this
        // particular draw (e.g. a zero-size drawable mid-resize), just show the active preset alone
        // rather than block presenting anything.
        guard let outgoingTexture = outgoingRenderer.renderToTexture(view: view) else {
            present(activeTexture, drawable: drawable, descriptor: presentDescriptor)
            return
        }

        let elapsed = transitionStartDate.map { Date().timeIntervalSince($0) } ?? transitionDuration
        let linearProgress = min(max(elapsed / transitionDuration, 0.0), 1.0)

        if linearProgress >= 1.0 {
            self.outgoingRenderer = nil
            transitionStartDate = nil
            present(activeTexture, drawable: drawable, descriptor: presentDescriptor)
            return
        }

        // Cosine ease, exact port of real projectM's `iProgressCosine`
        // (Renderer/PresetTransition.cpp's `Draw`: `(-cos(linearProgress * PI) + 1.0) * 0.5`) — see
        // Shaders.metal's milkdrop_crossfade_fragment doc comment.
        let eased = Float((-cos(linearProgress * .pi) + 1.0) * 0.5)
        presentCrossfade(outgoing: outgoingTexture, incoming: activeTexture, progress: eased, drawable: drawable, descriptor: presentDescriptor)
    }

    private func present(_ texture: MTLTexture, drawable: MTLDrawable, descriptor: MTLRenderPassDescriptor) {
        guard let commandBuffer = shared.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(shared.presentPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func presentCrossfade(
        outgoing: MTLTexture, incoming: MTLTexture, progress: Float,
        drawable: MTLDrawable, descriptor: MTLRenderPassDescriptor
    ) {
        guard let commandBuffer = shared.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        var progress = progress
        encoder.setRenderPipelineState(shared.crossfadePipeline)
        encoder.setFragmentTexture(outgoing, index: 0)
        encoder.setFragmentTexture(incoming, index: 1)
        encoder.setFragmentBytes(&progress, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
