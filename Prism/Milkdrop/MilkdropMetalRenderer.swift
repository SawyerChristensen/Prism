//
//  MilkdropMetalRenderer.swift
//  Prism
//
//  GPU replacement for the old WaveformTrailBuffer (a CGContext bitmap resized to the display
//  every frame — see the git history of MilkdropVisualizerView.swift for that version). This
//  renderer keeps the persistent "feedback" trail as two ping-ponged MTLTextures on the GPU:
//  each frame renders last frame's texture through the preset's real per-frame warp transform
//  (zoom/rotate/stretch/wiggle — Shaders.metal's feedback_fragment) into the other texture, draws
//  the new waveform/bars/shapes on top as real vertex geometry, optionally runs the preset's own
//  `comp_N=` HLSL composite shader (dynamically translated and compiled — see
//  MilkdropShaderTranslator.swift/compileCompositeShader below) as an extra pass, then presents
//  that texture to the view. Nothing here scales with window/display size the way the CPU version
//  did — a fragment shader costs the same whether the render target is 400x400 or 6K, so there's
//  no need for the old CPU version's resolution cap.
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
    // Custom shapes (shapecode_N_*) use their own pipelines: per-vertex color (for the fill
    // gradient, unlike solidPipeline's uniform color) and blend factors that don't match
    // solidPipeline's fixed (One,One) — Milkdrop's shape blend is (SourceAlpha,One) when additive,
    // (SourceAlpha,OneMinusSourceAlpha — standard "over" alpha) otherwise. See CustomShape.cpp:
    // 101-105 in projectM, and MilkdropShapeState.swift for the rest of the port.
    private let shapeAdditivePipeline: MTLRenderPipelineState
    private let shapeAlphaPipeline: MTLRenderPipelineState

    // Paired with a dynamically-compiled composite fragment function at draw time (see
    // compileCompositeShader below) — MTLRenderPipelineDescriptor doesn't require its vertex and
    // fragment functions to come from the same MTLLibrary, so the static full-screen-quad vertex
    // shader is reused as-is rather than duplicated into every generated shader source.
    private let feedbackVertexFunction: MTLFunction
    // The four filter/wrap combinations MilkdropShaderTranslator's qualifier-prefix parsing can
    // resolve a texture to (TextureManager.cpp:355-401) — created once and picked per texture
    // binding at draw time, rather than one MTLSamplerState per compiled shader.
    private let samplerLinearRepeat: MTLSamplerState
    private let samplerLinearClamp: MTLSamplerState
    private let samplerNearestRepeat: MTLSamplerState
    private let samplerNearestClamp: MTLSamplerState
    // Milkdrop's built-in noise textures (sampler_noise_lq, etc.) — generated once here, not
    // per-preset, since their content isn't preset-specific (see MilkdropNoiseTextures.swift).
    private let noiseTextures: MilkdropNoiseTextures?

    /// A dynamically-translated-and-compiled `comp_N=` composite shader, ready to draw with.
    private struct CompiledMilkdropShader {
        var pipelineState: MTLRenderPipelineState
        var textures: [MilkdropShaderTranslator.TextureBinding]
        /// Generated once at compile time (real Milkdrop's `rand_preset` is fixed for the life of
        /// the preset, unlike `rand_frame` which is fresh every frame — see draw(in:)).
        var randPreset: SIMD4<Float>
    }
    private var compiledComposite: CompiledMilkdropShader?
    /// The `model.loadGeneration` compiledComposite was last built for — recompiled only when this
    /// is stale, never every frame (see MilkdropVisualizerModel.loadGeneration).
    private var compiledCompositeGeneration = -1

    // Ping-pong feedback textures: textures[sourceIndex] is "what was on screen last frame" (read
    // this frame), textures[1 - sourceIndex] is this frame's render target. Swapped every frame.
    private var textures: [MTLTexture?] = [nil, nil]
    private var sourceIndex = 0
    // Scratch render target for the optional composite pass — always ends up copied back into
    // destTexture before present (see draw(in:)), so it never needs to participate in the
    // source/dest ping-pong itself; kept separate mainly so a composite-less frame (the common
    // case) doesn't pay for an extra texture bind/copy it doesn't need.
    private var scratchTexture: MTLTexture?
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

        guard let feedbackVertexFunction = library.makeFunction(name: "feedback_vertex") else {
            fatalError("Could not load Shaders.metal's feedback_vertex function")
        }
        self.feedbackVertexFunction = feedbackVertexFunction

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
        scratchTexture = device.makeTexture(descriptor: descriptor)
        sourceIndex = 0

        // Fresh GPU-allocated textures hold undefined contents, not zeros — clear both to
        // transparent so a resize doesn't flash garbage for one frame.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        for texture in (textures + [scratchTexture]).compactMap({ $0 }) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        commandBuffer.commit()
    }

    // MARK: - Dynamic shader compilation (comp_N= composite shaders — see MilkdropShaderTranslator.swift)

    /// Uniform layout shared between the generated MSL `#define` header (`uniformDefines()`) and
    /// draw(in:)'s flat uniform-array construction — a single source of truth for both sides'
    /// indices, so they can't drift apart. `q1`-`q32` are always 0 for now: Prism's per-frame
    /// expression evaluator can already store them (a script writing `q1=bass;` just becomes a
    /// dict entry, same as any other variable), but that value isn't threaded through to here yet
    /// — a shader reading a q-var the main preset script sets just sees 0, not a crash.
    private static let uniformLayout: [(name: String, count: Int)] =
        [("time", 1), ("fps", 1), ("frame", 1), ("progress", 1),
         ("bass", 1), ("mid", 1), ("treb", 1),
         ("bass_att", 1), ("mid_att", 1), ("treb_att", 1),
         ("rand_preset", 4), ("rand_frame", 4), ("texsize", 4)]
        + (1...32).map { ("q\($0)", 1) }

    private static var totalUniformCount: Int { uniformLayout.reduce(0) { $0 + $1.count } }

    private static func uniformDefines() -> String {
        var lines: [String] = []
        var index = 0
        for (name, count) in uniformLayout {
            if count == 1 {
                lines.append("#define \(name) uniforms[\(index)]")
            } else {
                let components = (0..<count).map { "uniforms[\(index + $0)]" }.joined(separator: ", ")
                lines.append("#define \(name) float\(count)(\(components))")
            }
            index += count
        }
        return lines.joined(separator: "\n")
    }

    /// Shim functions resolving the identifiers MilkdropShaderTranslator renamed `mul`/`saturate`/
    /// `lerp` to, plus a `FullscreenVertexOut` redeclaration matching Shaders.metal's layout
    /// (separately-compiled MTLLibrary sources don't share declarations, only ABI-compatible
    /// layouts — see MilkdropShaderTranslator.swift's header on why this whole approach is
    /// text-substitution rather than a shared compilation unit).
    private static let shaderShimHeader = """
    #include <metal_stdlib>
    using namespace metal;

    struct FullscreenVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    float2 milkdrop_mul(float2x2 m, float2 v) { return m * v; }
    float3 milkdrop_mul(float3x3 m, float3 v) { return m * v; }
    float4 milkdrop_mul(float4x4 m, float4 v) { return m * v; }
    float milkdrop_saturate(float x) { return clamp(x, 0.0, 1.0); }
    float2 milkdrop_saturate(float2 x) { return clamp(x, float2(0.0), float2(1.0)); }
    float3 milkdrop_saturate(float3 x) { return clamp(x, float3(0.0), float3(1.0)); }
    float4 milkdrop_saturate(float4 x) { return clamp(x, float4(0.0), float4(1.0)); }
    float milkdrop_lerp(float a, float b, float t) { return mix(a, b, t); }
    float2 milkdrop_lerp(float2 a, float2 b, float t) { return mix(a, b, t); }
    float2 milkdrop_lerp(float2 a, float2 b, float2 t) { return mix(a, b, t); }
    float3 milkdrop_lerp(float3 a, float3 b, float t) { return mix(a, b, t); }
    float3 milkdrop_lerp(float3 a, float3 b, float3 t) { return mix(a, b, t); }
    float4 milkdrop_lerp(float4 a, float4 b, float t) { return mix(a, b, t); }
    float4 milkdrop_lerp(float4 a, float4 b, float4 t) { return mix(a, b, t); }
    """

    /// Wraps a translated shader body into a complete MSL fragment function. Composite shaders run
    /// on plain screen UV (`uv == uv_orig`) — real Milkdrop's composite pass reads the already
    /// warped-and-drawn frame, not a re-warped one, so this matches upstream exactly for composite
    /// (unlike a hypothetical warp-shader port, which would need the geometric zoom/rotate/stretch/
    /// wiggle math duplicated here too — not yet implemented, see MilkdropVisualizerModel's
    /// `compositeShaderSource` doc comment).
    // Not `private`: PrismTests compiles this generated MSL through a real MTLDevice to catch
    // syntax mistakes the pure-Swift MilkdropShaderTranslator tests can't see (they only check the
    // string transformation, not whether the result is valid MSL) — see MilkdropMetalRendererShaderTests.
    static func buildCompositeShaderSource(_ translated: MilkdropShaderTranslator.Result) -> String {
        var params = ["constant float *uniforms [[buffer(0)]]"]
        for (i, texture) in translated.textures.enumerated() {
            let textureType = texture.isVolume ? "texture3d<float>" : "texture2d<float>"
            params.append("\(textureType) \(texture.declaredName) [[texture(\(i))]]")
            params.append("sampler \(texture.declaredName)_smp [[sampler(\(i))]]")
        }
        let signature = params.joined(separator: ",\n    ")

        return """
        \(shaderShimHeader)

        \(uniformDefines())

        fragment float4 milkdrop_composite_main(
            FullscreenVertexOut in [[stage_in]],
            \(signature)
        ) {
            float2 uv = in.uv;
            float2 uv_orig = in.uv;
            float2 pos = (in.uv - float2(0.5, 0.5)) * float2(2.0, -2.0);
            float rad = length(pos);
            float ang = atan2(pos.y, pos.x);
            float3 ret = float3(0.0);
        \(translated.body)
            return float4(ret, 1.0);
        }
        """
    }

    /// Translates, compiles, and links a preset's `comp_N=` source into a ready-to-draw pipeline.
    /// `nil` on any failure — unsupported textures (MilkdropShaderTranslator.translate returning
    /// `nil`), an MSL syntax construct this port's substitution rules don't handle, or a genuine
    /// Metal compiler rejection — all fall back identically, to the plain warp transform with no
    /// composite pass, never a crash or a refused preset load.
    private func compileCompositeShader(source: String) -> CompiledMilkdropShader? {
        guard let translated = MilkdropShaderTranslator.translate(source) else { return nil }
        let mslSource = Self.buildCompositeShaderSource(translated)
        guard let dynamicLibrary = try? device.makeLibrary(source: mslSource, options: nil),
              let fragmentFunction = dynamicLibrary.makeFunction(name: "milkdrop_composite_main")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = feedbackVertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let randPreset = SIMD4<Float>(.random(in: 0...1), .random(in: 0...1), .random(in: 0...1), .random(in: 0...1))
        return CompiledMilkdropShader(pipelineState: pipelineState, textures: translated.textures, randPreset: randPreset)
    }

    private func samplerState(for binding: MilkdropShaderTranslator.TextureBinding) -> MTLSamplerState {
        switch (binding.filter, binding.wrap) {
        case (.linear, .repeatWrap): return samplerLinearRepeat
        case (.linear, .clampToEdge): return samplerLinearClamp
        case (.nearest, .repeatWrap): return samplerNearestRepeat
        case (.nearest, .clampToEdge): return samplerNearestClamp
        }
    }

    /// Resolves one binding's actual Metal texture: `.main` is *this frame's* pre-composite result
    /// (passed in, since it changes every frame — unlike the noise catalog, generated once).
    private func metalTexture(for binding: MilkdropShaderTranslator.TextureBinding, mainTexture: MTLTexture) -> MTLTexture? {
        switch binding.resource {
        case .main: return mainTexture
        case .noise(let name): return noiseTextures?.texture(named: name)
        }
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
        let shapeInstancesByShape = model.updateShapesPerFrame(time: time, fps: beat.lastFPS, frame: frameCounter, energy: energy)

        // Recompile only on an actual preset change (model.loadGeneration bumps once per
        // loadPreset(from:) call), never every frame — dynamic Metal shader compilation is a
        // load-time cost, not something to pay 60x/sec.
        if compiledCompositeGeneration != model.loadGeneration {
            compiledComposite = model.compositeShaderSource.isEmpty ? nil : compileCompositeShader(source: model.compositeShaderSource)
            compiledCompositeGeneration = model.loadGeneration
        }
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

        // Base transform comes from the loaded preset's real per-frame zoom/rot/warp/etc. (neutral
        // defaults — zoom=1, rot=0, warp=1, decay=0.98 — when nothing's loaded, matching real
        // Milkdrop's own per-frame defaults; see MilkdropVisualizerView.swift's warpParams). The
        // existing beat-punch boost layers on top of that as a small additive/multiplicative
        // nudge — a Prism-specific touch (real Milkdrop has no "punch" concept), kept so the
        // default no-preset look stays exactly as reactive as it always has, and so a loaded
        // preset's own animation still gets a little extra life on a hit rather than being
        // replaced by it.
        var zoom = model.warpParams.zoom * Float(1.006 + punch * 0.035)
        var zoomExponent = model.warpParams.zoomExponent
        var rot = model.warpParams.rot + Float(0.0025 + punch * 0.01)
        var warpAmount = model.warpParams.warpAmount
        var cx = model.warpParams.rotCX
        var cy = model.warpParams.rotCY
        var dx = model.warpParams.xPush
        var dy = model.warpParams.yPush
        var sx = model.warpParams.stretchX
        var sy = model.warpParams.stretchY
        var decay = model.warpParams.decay

        // Deterministic per-frame ripple driving the warp-wiggle sine terms (see
        // feedback_fragment) — an exact port of PerPixelMesh.cpp's warpTime/warpFactors, not
        // random: same four slowly-drifting cosines every preset with the same warpAnimSpeed/
        // warpScale/time sees, matching what a real Milkdrop instance would compute.
        var warpTime = Float(time) * model.warpAnimSpeed
        var warpScaleInverse = model.warpScale != 0 ? 1.0 / model.warpScale : 1.0
        var warpFactors = SIMD4<Float>(
            11.68 + 4.0 * cosf(warpTime * 1.413 + 10),
            8.77 + 3.0 * cosf(warpTime * 1.113 + 7),
            10.54 + 3.0 * cosf(warpTime * 1.233 + 3),
            11.49 + 4.0 * cosf(warpTime * 0.933 + 5)
        )

        // Aspect-ratio correction so zoom/rotate/stretch stay circular instead of skewing with a
        // non-square viewport — exact formula confirmed against projectM's ProjectM.cpp.
        let widthF = Float(pixelSize.width)
        let heightF = Float(pixelSize.height)
        var aspectXY = SIMD2<Float>(heightF > widthF ? widthF / heightF : 1.0, widthF > heightF ? heightF / widthF : 1.0)
        var invAspectXY = SIMD2<Float>(1.0 / aspectXY.x, 1.0 / aspectXY.y)

        encoder.setRenderPipelineState(feedbackPipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentBytes(&zoom, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentBytes(&zoomExponent, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setFragmentBytes(&rot, length: MemoryLayout<Float>.stride, index: 2)
        encoder.setFragmentBytes(&warpAmount, length: MemoryLayout<Float>.stride, index: 3)
        encoder.setFragmentBytes(&cx, length: MemoryLayout<Float>.stride, index: 4)
        encoder.setFragmentBytes(&cy, length: MemoryLayout<Float>.stride, index: 5)
        encoder.setFragmentBytes(&dx, length: MemoryLayout<Float>.stride, index: 6)
        encoder.setFragmentBytes(&dy, length: MemoryLayout<Float>.stride, index: 7)
        encoder.setFragmentBytes(&sx, length: MemoryLayout<Float>.stride, index: 8)
        encoder.setFragmentBytes(&sy, length: MemoryLayout<Float>.stride, index: 9)
        encoder.setFragmentBytes(&decay, length: MemoryLayout<Float>.stride, index: 10)
        encoder.setFragmentBytes(&warpTime, length: MemoryLayout<Float>.stride, index: 11)
        encoder.setFragmentBytes(&warpScaleInverse, length: MemoryLayout<Float>.stride, index: 12)
        encoder.setFragmentBytes(&warpFactors, length: MemoryLayout<SIMD4<Float>>.stride, index: 13)
        encoder.setFragmentBytes(&aspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 14)
        encoder.setFragmentBytes(&invAspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 15)
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

        for shapeInstances in shapeInstancesByShape {
            for instance in shapeInstances {
                let pipeline = instance.additive ? shapeAdditivePipeline : shapeAlphaPipeline
                encoder.setRenderPipelineState(pipeline)
                let fillVerts = Self.shapeFillVertices(instance, pixelSize: pixelSize, aspect: aspect)
                Self.drawShape(fillVerts, as: .triangle, on: encoder, device: device)

                if instance.borderA > 0 {
                    let outlineHalfWidth = Float(instance.thickOutline ? 3.0 : 1.5) * Float(backingScale)
                    let outlineVerts = Self.shapeOutlineVertices(
                        instance, pixelSize: pixelSize, aspect: aspect, halfWidth: outlineHalfWidth
                    )
                    Self.drawShape(outlineVerts, as: .triangleStrip, on: encoder, device: device)
                }
            }
        }

        encoder.endEncoding()

        // MARK: Pass 1.5 — optional composite shader (comp_N=), destTexture -> scratchTexture -> back

        if let compiledComposite, let scratchTexture {
            let compositePass = MTLRenderPassDescriptor()
            compositePass.colorAttachments[0].texture = scratchTexture
            compositePass.colorAttachments[0].loadAction = .dontCare
            compositePass.colorAttachments[0].storeAction = .store

            if let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositePass) {
                var uniforms = [Float](repeating: 0, count: Self.totalUniformCount)
                uniforms[0] = Float(time)
                uniforms[1] = Float(beat.lastFPS)
                uniforms[2] = Float(frameCounter)
                uniforms[3] = 0 // progress: no preset-to-preset blend/fade in Prism yet.
                uniforms[4] = energy.bass
                uniforms[5] = energy.mid
                uniforms[6] = energy.treb
                uniforms[7] = energy.bassAtt
                uniforms[8] = energy.midAtt
                uniforms[9] = energy.trebAtt
                uniforms[10] = compiledComposite.randPreset.x
                uniforms[11] = compiledComposite.randPreset.y
                uniforms[12] = compiledComposite.randPreset.z
                uniforms[13] = compiledComposite.randPreset.w
                uniforms[14] = .random(in: 0...1) // rand_frame: fresh every frame, unlike rand_preset.
                uniforms[15] = .random(in: 0...1)
                uniforms[16] = .random(in: 0...1)
                uniforms[17] = .random(in: 0...1)
                uniforms[18] = Float(pixelSize.width)
                uniforms[19] = Float(pixelSize.height)
                uniforms[20] = pixelSize.width > 0 ? 1 / Float(pixelSize.width) : 0
                uniforms[21] = pixelSize.height > 0 ? 1 / Float(pixelSize.height) : 0

                // A texture this preset needed (e.g. a noise texture) failing to resolve here would
                // be a Prism bug, not a bad preset — MilkdropShaderTranslator already rejected
                // anything outside main/the noise catalog before this shader compiled at all — but
                // skip the draw (leaving destTexture as Pass 1 left it, still a fully valid frame)
                // rather than issue a call with a missing binding Metal would render as undefined.
                let resolvedTextures = compiledComposite.textures.map { ($0, metalTexture(for: $0, mainTexture: destTexture)) }
                if resolvedTextures.allSatisfy({ $0.1 != nil }) {
                    compositeEncoder.setRenderPipelineState(compiledComposite.pipelineState)
                    compositeEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Float>.stride * uniforms.count, index: 0)
                    for (i, (binding, texture)) in resolvedTextures.enumerated() {
                        compositeEncoder.setFragmentTexture(texture, index: i)
                        compositeEncoder.setFragmentSamplerState(samplerState(for: binding), index: i)
                    }
                    compositeEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    compositeEncoder.endEncoding()

                    // destTexture must hold the true final frame result afterward — it's what gets
                    // presented below AND what next frame's feedback pass reads as "previous
                    // frame" — so copy the composite output back rather than threading a third
                    // texture through the rest of this function's ping-pong bookkeeping.
                    if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                        blitEncoder.copy(from: scratchTexture, to: destTexture)
                        blitEncoder.endEncoding()
                    }
                } else {
                    compositeEncoder.endEncoding()
                }
            }
        }

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

    // MARK: - Custom shape geometry (shapecode_N_* — see MilkdropShapeState.swift)

    /// CPU-side mirror of Shaders.metal's `ShapeVertex` struct. Field order/types must match
    /// exactly — Metal's `float2`/`float4` alignment already lines up with
    /// SIMD2<Float>/SIMD4<Float>'s, so no explicit padding is needed.
    private struct ShapeVertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private static func drawShape(_ vertices: [ShapeVertex], as primitive: MTLPrimitiveType, on encoder: MTLRenderCommandEncoder, device: MTLDevice) {
        let minCount = primitive == .triangleStrip ? 2 : 3
        guard vertices.count >= minCount,
              let buffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<ShapeVertex>.stride * vertices.count, options: .storageModeShared)
        else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: vertices.count)
    }

    /// Center + `sides` rim points in NDC space, an exact port of CustomShape.cpp's vertex math:
    /// center = `(x*2-1, y*-2+1)`; rim point i = center + `rad*cos(angle)*aspectY` (x), `+
    /// rad*sin(angle)` (y), where `angle = 2π·i/sides + ang + π/4`. Shared by the fill and outline
    /// builders below so the two stay geometrically identical (same polygon, different mesh).
    private static func shapeRimPointsNDC(_ instance: MilkdropShapeInstance, aspect: Float) -> (center: SIMD2<Float>, rim: [SIMD2<Float>]) {
        let center = SIMD2<Float>(instance.x * 2 - 1, instance.y * -2 + 1)
        guard instance.sides >= 3 else { return (center, []) }
        let pi: Float = .pi
        var rim: [SIMD2<Float>] = []
        rim.reserveCapacity(instance.sides)
        for i in 0..<instance.sides {
            let cornerProgress = Float(i) / Float(instance.sides)
            let angle = cornerProgress * pi * 2 + instance.ang + pi * 0.25
            rim.append(center + SIMD2<Float>(instance.rad * cosf(angle) * aspect, instance.rad * sinf(angle)))
        }
        return (center, rim)
    }

    /// Explicit triangles (not a GPU triangle-fan primitive — Metal has none) forming the same
    /// center-to-rim gradient fan as CustomShape.cpp's fill mesh: center vertex colored
    /// `(r,g,b,a)`, every rim vertex colored `(r2,g2,b2,a2)` — a real per-vertex gradient.
    private static func shapeFillVertices(_ instance: MilkdropShapeInstance, pixelSize: CGSize, aspect: Float) -> [ShapeVertex] {
        let (centerNDC, rim) = shapeRimPointsNDC(instance, aspect: aspect)
        guard rim.count >= 3 else { return [] }

        func toPixel(_ ndc: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(ndc.x * 0.5 * Float(pixelSize.width), ndc.y * 0.5 * Float(pixelSize.height))
        }

        let center = ShapeVertex(position: toPixel(centerNDC), color: SIMD4<Float>(instance.r, instance.g, instance.b, instance.a))
        let rimColor = SIMD4<Float>(instance.r2, instance.g2, instance.b2, instance.a2)
        let rimPixels = rim.map(toPixel)

        var verts: [ShapeVertex] = []
        verts.reserveCapacity(rim.count * 3)
        for i in 0..<rim.count {
            let next = rimPixels[(i + 1) % rim.count]
            verts.append(center)
            verts.append(ShapeVertex(position: rimPixels[i], color: rimColor))
            verts.append(ShapeVertex(position: next, color: rimColor))
        }
        return verts
    }

    /// Outline ribbon around the same rim used above, reusing `lineStripVertices`' ribbon-extrusion
    /// math (identical to how `.circular` wave mode closes its loop) instead of duplicating it,
    /// then tinting every vertex with the shape's uniform border color to fit the shape pipeline's
    /// per-vertex-color format. `thickOutline` widens the ribbon rather than redrawing it 3x with
    /// pixel offsets like upstream's "poor-man's" hack — same thicker-outline result, simpler code.
    private static func shapeOutlineVertices(_ instance: MilkdropShapeInstance, pixelSize: CGSize, aspect: Float, halfWidth: Float) -> [ShapeVertex] {
        let (_, rim) = shapeRimPointsNDC(instance, aspect: aspect)
        guard rim.count >= 3 else { return [] }

        var points = rim.map { WavePoint(x: $0.x, y: $0.y) }
        if let first = points.first { points.append(first) }

        let borderColor = SIMD4<Float>(instance.borderR, instance.borderG, instance.borderB, instance.borderA)
        return Self.lineStripVertices(points: points, pixelSize: pixelSize, halfWidth: halfWidth, isLoop: true)
            .map { ShapeVertex(position: $0, color: borderColor) }
    }
}
