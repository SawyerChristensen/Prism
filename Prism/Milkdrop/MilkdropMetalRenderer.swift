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

    /// Passthrough to the analyzer's raw magnitude spectrum — see MilkdropCustomWaveform.swift's
    /// spectrum-mode path.
    var magnitudeSpectrum: [Float] { analyzer.lastMagnitudeSpectrum }

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
    // VideoEcho.cpp/Filters.cpp's "old-school" final-composite path (see MilkdropPresetFile.swift's
    // usesOldStyleFinalComposite) — a fixed Metal shader, not dynamically compiled per preset like
    // compiledComposite/compiledWarp, since it's the same closed-form function for every old-style
    // preset regardless of which of its knobs are set.
    private let oldStyleCompositePipeline: MTLRenderPipelineState
    // The scripted warp-mesh path (per_pixel_N= — see MilkdropPerPixelMesh.swift), used instead of
    // feedbackPipeline's full-screen quad only when the loaded preset actually has per-pixel code.
    // The mesh's triangle connectivity never changes (fixed 32x24 grid), so its index buffer is
    // built once here rather than every frame like the (per-preset-varying) vertex buffer.
    private let feedbackMeshPipeline: MTLRenderPipelineState
    private let meshIndexBuffer: MTLBuffer
    // Custom shapes (shapecode_N_*) use their own pipelines: per-vertex color (for the fill
    // gradient, unlike solidPipeline's uniform color) and blend factors that don't match
    // solidPipeline's fixed (One,One) — Milkdrop's shape blend is (SourceAlpha,One) when additive,
    // (SourceAlpha,OneMinusSourceAlpha — standard "over" alpha) otherwise. See CustomShape.cpp:
    // 101-105 in projectM, and MilkdropShapeState.swift for the rest of the port.
    private let shapeAdditivePipeline: MTLRenderPipelineState
    private let shapeAlphaPipeline: MTLRenderPipelineState
    // `textured=1` shapes (CustomShape.cpp:145-201) — same blend factors as the pair above, just a
    // different vertex/fragment pair that samples a texture instead of the flat gradient fill.
    private let shapeTexturedAdditivePipeline: MTLRenderPipelineState
    private let shapeTexturedAlphaPipeline: MTLRenderPipelineState

    // Paired with a dynamically-compiled composite fragment function at draw time (see
    // compileCompositeShader below) — MTLRenderPipelineDescriptor doesn't require its vertex and
    // fragment functions to come from the same MTLLibrary, so the static full-screen-quad vertex
    // shader is reused as-is rather than duplicated into every generated shader source.
    private let feedbackVertexFunction: MTLFunction
    // Reused when dynamically compiling a `warp_N=` shader's fragment function (see
    // compileWarpShader below) — same reasoning as feedbackVertexFunction above, just for the mesh
    // vertex stage instead of the full-screen quad.
    private let feedbackMeshVertexFunction: MTLFunction
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
    // Preset-pack `Textures/` lookups for custom sampler names (`sampler_worms`, `sampler_rand00`,
    // etc. — see MilkdropShaderTranslator's `.custom` resource case). One instance for the
    // renderer's lifetime (not per-preset) since it internally caches by scanned root already.
    private let customTextures: MilkdropCustomTextureManager
    /// The `model.loadGeneration` `customTextures` last (re)scanned for — same gating pattern as
    /// `compiledCompositeGeneration`/`compiledWarpGeneration`, so a folder walk + directory scan
    /// happens on an actual preset change, never every frame.
    private var customTextureGeneration = -1

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

    /// Same idea as `compiledComposite`, for `warp_N=` — a dynamically-compiled shader that
    /// *replaces* the feedback pass's default warp fragment entirely (not an extra pass like
    /// composite), always drawn via the mesh path (see MilkdropPerPixelMeshRuntime.trivialVertices'
    /// doc comment on why, even for presets with no `per_pixel_N=` script of their own).
    private var compiledWarp: CompiledMilkdropShader?
    private var compiledWarpGeneration = -1

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
    /// Exponential moving average of `beat.lastFPS` (itself instantaneous, `1/dt` per frame) —
    /// pushed into `model.displayFPS` once per frame for the on-screen performance counter. EMA
    /// rather than raw so the displayed number is stable enough to actually read.
    private var smoothedFPS: Double = 60

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
        self.oldStyleCompositePipeline = makePipeline(vertex: "feedback_vertex", fragment: "milkdrop_old_style_final_composite", additiveBlend: false)

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
        self.customTextures = MilkdropCustomTextureManager(device: device)

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
    /// indices, so they can't drift apart. `q1`-`q32` come from the per-frame script's own
    /// variables (see MilkdropVisualizerModel.qVariables) — a script that never touches a given
    /// q-var just leaves it at 0, same as an unset NS-EEL variable would.
    private static let uniformLayout: [(name: String, count: Int)] =
        [("time", 1), ("fps", 1), ("frame", 1), ("progress", 1),
         ("bass", 1), ("mid", 1), ("treb", 1),
         ("bass_att", 1), ("mid_att", 1), ("treb_att", 1),
         ("rand_preset", 4), ("rand_frame", 4), ("texsize", 4),
         // `_c0` in projectM's PresetShaderHeaderGlsl330.inc — aspect ratio + its inverse, exactly
         // MilkdropMetalRenderer's own aspectXY/invAspectXY (see draw(in:)'s aspect-ratio-correction
         // comment) already computed for the vertex stage, just also exposed to the fragment here.
         ("aspect", 4),
         // Four slowly/quickly-drifting cosine/sine quadruplets — real Milkdrop uniforms
         // (`_c8`-`_c11` in projectM's PresetShaderHeaderGlsl330.inc), exact formula confirmed
         // against MilkdropShader::LoadVariables and reproduced verbatim in
         // `buildDynamicShaderUniforms` below.
         ("roam_cos", 4), ("roam_sin", 4), ("slow_roam_cos", 4), ("slow_roam_sin", 4)]
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

    /// Fixed pixel dimensions for MilkdropNoiseTextures' catalog — generated once at startup, never
    /// resized, so these are safe to bake in as compile-time constants (unlike `main`/`blur`, whose
    /// size changes on window resize — see below).
    private static let noiseTextureSizes: [String: (width: Float, height: Float)] = [
        "noise_lq": (256, 256), "noise_mq": (256, 256), "noise_hq": (256, 256),
        "noisevol_lq": (32, 32), "noisevol_hq": (32, 32),
    ]

    private static func textureResourceBaseName(_ resource: MilkdropShaderTranslator.TextureBinding.Resource) -> String {
        switch resource {
        case .main: return "main"
        case .noise(let name): return name
        case .blur(let level): return "blur\(level)"
        case .custom(let name): return name
        }
    }

    /// Per-texture `texsize_<baseName>` defines (measured 7/25: referenced by 62% of remaining
    /// real warp-shader compile failures after the GetPixel/GetBlurN and float4->float3 fixes
    /// landed — clearly the next-biggest lever, not a minor gap). `main`/`blurN` alias the
    /// existing generic `texsize` uniform rather than a fixed literal — their pixel size changes on
    /// window resize, and `texsize` is already a genuine per-frame uniform (not a compile-time
    /// constant) for exactly that reason; only the noise catalog's fixed, never-resized textures
    /// get baked-in literal values. `.custom` (MilkdropCustomTextureManager) textures fall into
    /// this same generic-`texsize` branch too — their real on-disk dimensions aren't threaded
    /// through as a uniform, a documented approximation in the same spirit as `.blur`'s.
    private static func textureSizeDefines(_ textures: [MilkdropShaderTranslator.TextureBinding]) -> String {
        var lines: [String] = []
        var seen: Set<String> = []
        for texture in textures {
            let base = textureResourceBaseName(texture.resource)
            guard !seen.contains(base) else { continue }
            seen.insert(base)
            if let size = noiseTextureSizes[base] {
                lines.append("#define texsize_\(base) float4(\(size.width), \(size.height), \(1.0 / size.width), \(1.0 / size.height))")
            } else {
                lines.append("#define texsize_\(base) texsize")
            }
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
    // Real Milkdrop's exact luminance-weighting formula — confirmed against projectM's
    // PresetShaderHeaderGlsl330.inc (`#define lum(x) (dot(x,float3(0.32,0.49,0.29)))`). A pure
    // math macro (no texture involved), unlike GetPixel/GetBlurN, so a plain #define here is safe.
    #define lum(x) (dot(x, float3(0.32, 0.49, 0.29)))
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
        \(textureSizeDefines(translated.textures))

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

    /// Wraps a translated `warp_N=` shader body into a complete MSL fragment function, drawn via
    /// the mesh path (`feedback_mesh_vertex` — see MilkdropPerPixelMeshRuntime.trivialVertices' doc
    /// comment on why even a script-less preset still goes through the mesh when a warp shader is
    /// present). Confirmed against projectM's MilkdropShader.cpp: unlike `comp_N=`, `uv`/`uv_orig`
    /// are genuinely different here (`uv` is the *already-warped* mesh UV, `uv_orig` the plain
    /// pre-warp one), and `rad`/`ang` come from the mesh's static per-vertex buffer rather than
    /// being re-derived from `uv_orig` like the composite wrapper above does. There's also no
    /// automatic decay multiplication: real Milkdrop hands the shader body a raw `ret` with no
    /// built-in fade, so a preset relying on decay must (and often does — e.g. `ret = ret - 0.002;`
    /// in a real corpus sample) apply its own; multiplying by `decay` here on top would double it.
    // Not `private`, same reason as buildCompositeShaderSource above.
    static func buildWarpShaderSource(_ translated: MilkdropShaderTranslator.Result) -> String {
        var params = ["constant float *uniforms [[buffer(0)]]"]
        for (i, texture) in translated.textures.enumerated() {
            let textureType = texture.isVolume ? "texture3d<float>" : "texture2d<float>"
            params.append("\(textureType) \(texture.declaredName) [[texture(\(i))]]")
            params.append("sampler \(texture.declaredName)_smp [[sampler(\(i))]]")
        }
        let signature = params.joined(separator: ",\n    ")

        return """
        \(shaderShimHeader)

        // Mirrors Shaders.metal's real MeshVertexOut layout — separately-compiled MTLLibrary
        // sources don't share declarations, only ABI-compatible ones (same reasoning as
        // FullscreenVertexOut in shaderShimHeader above).
        struct MeshVertexOut {
            float4 position [[position]];
            float2 uv;
            float2 uvOrig;
            float2 radiusAngle;
        };

        \(uniformDefines())
        \(textureSizeDefines(translated.textures))

        fragment float4 milkdrop_warp_main(
            MeshVertexOut in [[stage_in]],
            \(signature)
        ) {
            float2 uv = in.uv;
            float2 uv_orig = in.uvOrig;
            float rad = in.radiusAngle.x;
            float ang = in.radiusAngle.y;
            float3 ret = float3(0.0);
        \(translated.body)
            return float4(ret, 1.0);
        }
        """
    }

    /// Translates, compiles, and links a preset's `warp_N=` source into a ready-to-draw pipeline —
    /// same fallback contract as `compileCompositeShader` (`nil` on any failure, never a crash).
    private func compileWarpShader(source: String) -> CompiledMilkdropShader? {
        guard let translated = MilkdropShaderTranslator.translate(source) else { return nil }
        let mslSource = Self.buildWarpShaderSource(translated)
        guard let dynamicLibrary = try? device.makeLibrary(source: mslSource, options: nil),
              let fragmentFunction = dynamicLibrary.makeFunction(name: "milkdrop_warp_main")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = feedbackMeshVertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let randPreset = SIMD4<Float>(.random(in: 0...1), .random(in: 0...1), .random(in: 0...1), .random(in: 0...1))
        return CompiledMilkdropShader(pipelineState: pipelineState, textures: translated.textures, randPreset: randPreset)
    }

    /// Shared by both dynamically-compiled shader draws (composite and warp) — the flat uniform
    /// array `uniformDefines()`'s `#define`s index into, built fresh each frame/draw since
    /// `rand_frame` (indices 14-17) must be freshly random every call, not just every frame (warp
    /// and composite each get their own independent draw, same as upstream's MilkdropShader
    /// instances each calling their own `floatRand()`).
    private func buildDynamicShaderUniforms(
        time: Double, frame: Int, energy: MilkdropBandEnergy, randPreset: SIMD4<Float>, pixelSize: CGSize,
        aspect: SIMD2<Float>, invAspect: SIMD2<Float>, qVars: [Float]
    ) -> [Float] {
        var uniforms = [Float](repeating: 0, count: Self.totalUniformCount)
        uniforms[0] = Float(time)
        uniforms[1] = Float(beat.lastFPS)
        uniforms[2] = Float(frame)
        uniforms[3] = 0 // progress: no preset-to-preset blend/fade in Prism yet.
        uniforms[4] = energy.bass
        uniforms[5] = energy.mid
        uniforms[6] = energy.treb
        uniforms[7] = energy.bassAtt
        uniforms[8] = energy.midAtt
        uniforms[9] = energy.trebAtt
        uniforms[10] = randPreset.x
        uniforms[11] = randPreset.y
        uniforms[12] = randPreset.z
        uniforms[13] = randPreset.w
        uniforms[14] = .random(in: 0...1)
        uniforms[15] = .random(in: 0...1)
        uniforms[16] = .random(in: 0...1)
        uniforms[17] = .random(in: 0...1)
        uniforms[18] = Float(pixelSize.width)
        uniforms[19] = Float(pixelSize.height)
        uniforms[20] = pixelSize.width > 0 ? 1 / Float(pixelSize.width) : 0
        uniforms[21] = pixelSize.height > 0 ? 1 / Float(pixelSize.height) : 0
        uniforms[22] = aspect.x
        uniforms[23] = aspect.y
        uniforms[24] = invAspect.x
        uniforms[25] = invAspect.y

        // roam_cos/roam_sin/slow_roam_cos/slow_roam_sin — exact frequencies/phases ported verbatim
        // from MilkdropShader::LoadVariables (`_c8`-`_c11`), not the header comment's rounded
        // "~0.3, ~1.3, ~5, ~20" documentation values.
        let t = Float(time)
        let roamFreqs: [Float] = [0.329, 1.293, 5.070, 20.051]
        let roamPhases: [Float] = [1.2, 3.9, 2.5, 5.4]
        let slowRoamFreqs: [Float] = [0.0050, 0.0085, 0.0133, 0.0217]
        let slowRoamPhases: [Float] = [2.7, 5.3, 4.5, 3.8]
        for i in 0..<4 {
            uniforms[26 + i] = 0.5 + 0.5 * cosf(t * roamFreqs[i] + roamPhases[i])
            uniforms[30 + i] = 0.5 + 0.5 * sinf(t * roamFreqs[i] + roamPhases[i])
            uniforms[34 + i] = 0.5 + 0.5 * cosf(t * slowRoamFreqs[i] + slowRoamPhases[i])
            uniforms[38 + i] = 0.5 + 0.5 * sinf(t * slowRoamFreqs[i] + slowRoamPhases[i])
        }

        for i in 0..<qVars.count { uniforms[42 + i] = qVars[i] }
        return uniforms
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
    /// `.blur` (the `GetBlur1`/`GetBlur2`/`GetBlur3` helper functions) resolves to that same
    /// unblurred texture too — see MilkdropShaderTranslator.TextureBinding's doc comment on why
    /// that's a deliberate, documented approximation rather than a real blur pipeline.
    private func metalTexture(for binding: MilkdropShaderTranslator.TextureBinding, mainTexture: MTLTexture) -> MTLTexture? {
        switch binding.resource {
        case .main, .blur: return mainTexture
        case .noise(let name): return noiseTextures?.texture(named: name)
        case .custom(let name): return customTextures.texture(named: name)
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

        smoothedFPS = smoothedFPS * 0.9 + beat.lastFPS * 0.1
        model.displayFPS = smoothedFPS

        if renderStartDate == nil { renderStartDate = now }
        let time = now.timeIntervalSince(renderStartDate!)
        frameCounter += 1
        transientBuffers.beginFrame(generation: frameCounter)
        // Drives a loaded preset's per-frame expression program (if any) before this frame's
        // points get generated below, so mode/params reflect this frame's evaluated values.
        model.updatePresetPerFrame(time: time, fps: beat.lastFPS, frame: frameCounter, energy: energy)
        // Resolved once here — model.qVariables re-derives a 32-entry array from presetVariables on
        // every call (a real, if small, cost — see its own doc comment), and this frame has up to
        // four call sites that all want the identical result (per-pixel mesh, custom waveforms, and
        // both dynamic-shader-uniform builds below).
        let qVars = model.qVariables
        let shapeInstancesByShape = model.updateShapesPerFrame(time: time, fps: beat.lastFPS, frame: frameCounter, energy: energy)
        // Mono spectrum reused for both channels (see MilkdropAudioSignals.swift's
        // lastMagnitudeSpectrum doc comment on why there's no true stereo spectrum here).
        let magnitudeSpectrum = beat.magnitudeSpectrum
        let customWavePointsByWave = model.updateCustomWaveforms(
            pcmLeft: left, pcmRight: right, spectrumLeft: magnitudeSpectrum, spectrumRight: magnitudeSpectrum,
            time: time, fps: beat.lastFPS, frame: frameCounter, energy: energy, qVars: qVars
        )

        // Re-scan for a Textures/ folder only on an actual preset change too — same reasoning as
        // the shader recompilation below, and `customTextures` internally no-ops anyway if the
        // resolved root hasn't actually changed (e.g. two presets from the same pack in a row).
        if customTextureGeneration != model.loadGeneration {
            customTextures.prepareForPreset(at: model.presetURL)
            customTextureGeneration = model.loadGeneration
        }

        // Recompile only on an actual preset change (model.loadGeneration bumps once per
        // loadPreset(from:) call), never every frame — dynamic Metal shader compilation is a
        // load-time cost, not something to pay 60x/sec.
        if compiledCompositeGeneration != model.loadGeneration {
            compiledComposite = model.compositeShaderSource.isEmpty ? nil : compileCompositeShader(source: model.compositeShaderSource)
            compiledCompositeGeneration = model.loadGeneration
        }
        if compiledWarpGeneration != model.loadGeneration {
            compiledWarp = model.warpShaderSource.isEmpty ? nil : compileWarpShader(source: model.warpShaderSource)
            compiledWarpGeneration = model.loadGeneration
        }
        let aspect = pixelSize.width > 0 ? Float(pixelSize.height / pixelSize.width) : 1
        let (rawPoints, rawBreak) = MilkdropWaveform.points(
            mode: model.mode, left: scaledLeft, right: scaledRight, spectrum: magnitudeSpectrum,
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

        // Scripted warp mesh (per_pixel_N=) and/or a compiled warp_N= shader. Priority, matching
        // real Milkdrop's own architecture (PerPixelMesh::WarpedBlit always draws the mesh; a
        // custom warp shader only ever replaces *which fragment shader* processes it):
        //  1. A compiled warp_N= shader — ALWAYS drawn via the mesh path, even for the 32.5% of
        //     the corpus with warp_N= but no per_pixel_N= of their own (see
        //     MilkdropPerPixelMeshRuntime.trivialVertices' doc comment on why that's a deliberate
        //     simplification, not a quality compromise).
        //  2. A per_pixel_N= script with no warp shader — the existing scripted-mesh path.
        //  3. Neither — the existing per-pixel-exact fixed-formula path.
        let meshVerticesFromScript = model.updatePerPixelMesh(
            aspectX: aspectXY.x, aspectY: aspectXY.y, time: time, fps: beat.lastFPS, frame: frameCounter, energy: energy,
            qVars: qVars
        )

        // Resolved before committing to the warp-shader branch: if a texture genuinely fails to
        // resolve (shouldn't happen — MilkdropShaderTranslator already validated every reference
        // before this shader compiled at all), fall through to the default paths below rather than
        // issue a draw call with a missing binding Metal would render as undefined.
        let resolvedWarpTextures: [(MilkdropShaderTranslator.TextureBinding, MTLTexture)]? = compiledWarp.flatMap { warp in
            let resolved = warp.textures.map { ($0, metalTexture(for: $0, mainTexture: sourceTexture)) }
            guard resolved.allSatisfy({ $0.1 != nil }) else { return nil }
            return resolved.map { ($0.0, $0.1!) }
        }

        if let compiledWarp, let resolvedWarpTextures {
            var meshVertices = meshVerticesFromScript ?? MilkdropPerPixelMeshRuntime.trivialVertices(
                aspectX: aspectXY.x, aspectY: aspectXY.y,
                zoom: zoom, zoomExp: zoomExponent, rot: rot, warp: warpAmount,
                cx: cx, cy: cy, dx: dx, dy: dy, sx: sx, sy: sy
            )
            if let meshVertexBuffer = transientBuffers.buffer(for: meshVertices, device: device) {
                encoder.setRenderPipelineState(compiledWarp.pipelineState)
                encoder.setVertexBuffer(meshVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&warpTime, length: MemoryLayout<Float>.stride, index: 1)
                encoder.setVertexBytes(&warpScaleInverse, length: MemoryLayout<Float>.stride, index: 2)
                encoder.setVertexBytes(&warpFactors, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
                encoder.setVertexBytes(&aspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
                encoder.setVertexBytes(&invAspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 5)
                var warpUniforms = buildDynamicShaderUniforms(
                    time: time, frame: frameCounter, energy: energy, randPreset: compiledWarp.randPreset, pixelSize: pixelSize,
                    aspect: aspectXY, invAspect: invAspectXY, qVars: qVars
                )
                encoder.setFragmentBytes(&warpUniforms, length: MemoryLayout<Float>.stride * warpUniforms.count, index: 0)
                for (i, (binding, texture)) in resolvedWarpTextures.enumerated() {
                    encoder.setFragmentTexture(texture, index: i)
                    encoder.setFragmentSamplerState(samplerState(for: binding), index: i)
                }
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: MilkdropPerPixelMeshRuntime.sharedIndices.count,
                    indexType: .uint16, indexBuffer: meshIndexBuffer, indexBufferOffset: 0
                )
            }
        } else if let meshVerticesFromScript, !meshVerticesFromScript.isEmpty,
           let meshVertexBuffer = transientBuffers.buffer(for: meshVerticesFromScript, device: device)
        {
            encoder.setRenderPipelineState(feedbackMeshPipeline)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setVertexBuffer(meshVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&warpTime, length: MemoryLayout<Float>.stride, index: 1)
            encoder.setVertexBytes(&warpScaleInverse, length: MemoryLayout<Float>.stride, index: 2)
            encoder.setVertexBytes(&warpFactors, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.setVertexBytes(&aspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
            encoder.setVertexBytes(&invAspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 5)
            encoder.setFragmentBytes(&decay, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: MilkdropPerPixelMeshRuntime.sharedIndices.count,
                indexType: .uint16, indexBuffer: meshIndexBuffer, indexBufferOffset: 0
            )
        } else {
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
        }

        encoder.setRenderPipelineState(solidPipeline)
        var viewport = SIMD2<Float>(Float(pixelSize.width), Float(pixelSize.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&colorVec, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)

        if model.mode == .spectrumBars {
            let verts = Self.barVertices(bands: audioEngine.levels, pixelSize: pixelSize)
            draw(verts, as: .triangle, on: encoder, device: device)
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
                draw(verts, as: .triangleStrip, on: encoder, device: device)
            }
        }

        for shapeInstances in shapeInstancesByShape {
            // Fill draws are batched: consecutive instances sharing the same (textured, additive)
            // pipeline choice get merged into one combined vertex buffer + one draw call instead of
            // one call per instance. This matters because `num_inst` is genuinely unbounded in real
            // presets — measured against the real ~9,795-file corpus on this machine: literal
            // values like 1024, 817, 800, 512 each appear hundreds of times (particle/swarm-style
            // presets are a real genre, not a pathological edge case) — and every fill-mesh's
            // vertices are independent triangles (`.triangle`, not a strip), so concatenating
            // several instances' vertex arrays is trivially safe: no connecting geometry needed
            // between one instance's triangles and the next, unlike a triangle-strip. Falls back to
            // one draw call per instance automatically whenever additive/textured actually differs
            // instance-to-instance (uncommon in practice — these are structural draw-mode flags, not
            // typically per-instance-animated the way color/position are), so this is never worse
            // than the previous behavior, only better.
            var i = 0
            while i < shapeInstances.count {
                let textured = shapeInstances[i].textured
                let additive = shapeInstances[i].additive
                var j = i + 1
                while j < shapeInstances.count, shapeInstances[j].textured == textured, shapeInstances[j].additive == additive {
                    j += 1
                }
                let run = shapeInstances[i..<j]

                if textured {
                    // Real Milkdrop textures a shape from its own `image=` key or, since that's
                    // effectively unused across the real corpus (see TO DO.md's Phase 2 notes),
                    // from the "main texture" — the same last-frame content `sourceTexture` already
                    // is here (this pass reads it as the feedback source, exactly the role
                    // CustomShape.cpp's mainTexture plays upstream).
                    let pipeline = additive ? shapeTexturedAdditivePipeline : shapeTexturedAlphaPipeline
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(sourceTexture, index: 0)
                    encoder.setFragmentSamplerState(samplerLinearRepeat, index: 0)
                    var combined: [ShapeTexturedVertex] = []
                    for instance in run {
                        combined.append(contentsOf: Self.shapeTexturedFillVertices(instance, pixelSize: pixelSize, aspect: aspect))
                    }
                    drawShape(combined, as: .triangle, on: encoder, device: device)
                } else {
                    let pipeline = additive ? shapeAdditivePipeline : shapeAlphaPipeline
                    encoder.setRenderPipelineState(pipeline)
                    var combined: [ShapeVertex] = []
                    for instance in run {
                        combined.append(contentsOf: Self.shapeFillVertices(instance, pixelSize: pixelSize, aspect: aspect))
                    }
                    drawShape(combined, as: .triangle, on: encoder, device: device)
                }

                // Border/outline pass — still per-instance (a triangle *strip*, unlike the fill
                // mesh above, so safely batching it would need degenerate-triangle stitching
                // between instances; not attempted this pass — see TO DO.md). Only actually runs
                // for instances with a visible border, which is the common case's exception, not
                // its rule.
                for instance in run where instance.borderA > 0 {
                    // The border always draws through the plain (untextured) shape pipeline, even
                    // when the fill above was textured — CustomShape.cpp's outline pass always
                    // binds untexturedShader regardless of m_textured. Re-bind explicitly rather
                    // than relying on whatever pipeline the fill above happened to leave current:
                    // the textured fill's pipeline expects ShapeTexturedVertex's stride, and
                    // shapeOutlineVertices below produces plain ShapeVertex data.
                    encoder.setRenderPipelineState(instance.additive ? shapeAdditivePipeline : shapeAlphaPipeline)
                    let outlineHalfWidth = Float(instance.thickOutline ? 3.0 : 1.5) * Float(backingScale)
                    let outlineVerts = Self.shapeOutlineVertices(
                        instance, pixelSize: pixelSize, aspect: aspect, halfWidth: outlineHalfWidth
                    )
                    drawShape(outlineVerts, as: .triangleStrip, on: encoder, device: device)
                }

                i = j
            }
        }

        // Custom waveforms (wavecode_N_* — see MilkdropCustomWaveform.swift), drawn on top of the
        // shapes and built-in waveform, reusing the shape pipelines (per-vertex color, same
        // additive/alpha blend choice) since a custom waveform is likewise a colored line/dot trace.
        for waveData in customWavePointsByWave {
            let minPoints = waveData.useDots ? 1 : 2
            guard waveData.points.count >= minPoints else { continue }
            let pipeline = waveData.additive ? shapeAdditivePipeline : shapeAlphaPipeline
            encoder.setRenderPipelineState(pipeline)
            if waveData.useDots {
                let dotHalfSize = Float(waveData.drawThick ? 2.5 : 1.5) * Float(backingScale)
                let verts = Self.customWaveformDotVertices(waveData.points, pixelSize: pixelSize, halfSize: dotHalfSize)
                drawShape(verts, as: .triangle, on: encoder, device: device)
            } else {
                let halfWidth = Float(waveData.drawThick ? 2.0 : 1.0) * Float(backingScale)
                let verts = Self.customWaveformRibbonVertices(waveData.points, pixelSize: pixelSize, halfWidth: halfWidth)
                drawShape(verts, as: .triangleStrip, on: encoder, device: device)
            }
        }

        // Darken-center (DarkenCenter.cpp) + border (Border.cpp), drawn last in this pass — same
        // ordering as real Milkdrop's per-frame draw loop (shapes/waveforms, then darken-center,
        // then border, all before the final composite pass). Both are always-alpha-blend, never
        // additive, matching upstream's own fixed blend mode for these two.
        if model.borderParams.darkenCenter > 0 {
            encoder.setRenderPipelineState(shapeAlphaPipeline)
            let verts = Self.darkenCenterVertices(aspect: aspectXY.y, pixelSize: pixelSize)
            drawShape(verts, as: .triangle, on: encoder, device: device)
        }
        let borderVerts = Self.borderVertices(model.borderParams, pixelSize: pixelSize)
        if !borderVerts.isEmpty {
            encoder.setRenderPipelineState(shapeAlphaPipeline)
            drawShape(borderVerts, as: .triangle, on: encoder, device: device)
        }

        encoder.endEncoding()

        // MARK: Pass 1.5 — optional composite shader (comp_N=), destTexture -> scratchTexture -> back

        if let compiledComposite, let scratchTexture {
            let compositePass = MTLRenderPassDescriptor()
            compositePass.colorAttachments[0].texture = scratchTexture
            compositePass.colorAttachments[0].loadAction = .dontCare
            compositePass.colorAttachments[0].storeAction = .store

            if let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositePass) {
                var uniforms = buildDynamicShaderUniforms(
                    time: time, frame: frameCounter, energy: energy,
                    randPreset: compiledComposite.randPreset, pixelSize: pixelSize,
                    aspect: aspectXY, invAspect: invAspectXY, qVars: qVars
                )

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
        } else if model.usesOldStyleFinalComposite, let scratchTexture {
            // Real Milkdrop's "old-school" (no comp_N= shader at all) final-composite path — see
            // Shaders.metal's milkdrop_old_style_final_composite and MilkdropPresetFile.swift's
            // usesOldStyleFinalComposite. Mutually exclusive with compiledComposite above (a preset
            // is either modern-shader-based or old-style, never both), so this can't double-apply.
            let oldStylePass = MTLRenderPassDescriptor()
            oldStylePass.colorAttachments[0].texture = scratchTexture
            oldStylePass.colorAttachments[0].loadAction = .dontCare
            oldStylePass.colorAttachments[0].storeAction = .store

            if let oldStyleEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: oldStylePass) {
                let params = model.oldStyleCompositeParams
                var timeF = Float(time)
                var hueOffsets = model.hueRandomOffsets
                var echoZoom = params.videoEchoZoom != 0 ? params.videoEchoZoom : 1
                var echoAlpha = params.videoEchoAlpha
                var flipUV = SIMD2<Float>(
                    Int(params.videoEchoOrientation) % 2 == 1 ? 1 : 0,
                    Int(params.videoEchoOrientation) >= 2 ? 1 : 0
                )
                var gammaAdj = params.gammaAdj
                var filterFlags = SIMD4<Float>(params.brighten, params.darken, params.solarize, params.invert)

                oldStyleEncoder.setRenderPipelineState(oldStyleCompositePipeline)
                oldStyleEncoder.setFragmentTexture(destTexture, index: 0)
                oldStyleEncoder.setFragmentBytes(&timeF, length: MemoryLayout<Float>.stride, index: 0)
                oldStyleEncoder.setFragmentBytes(&hueOffsets, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                oldStyleEncoder.setFragmentBytes(&echoZoom, length: MemoryLayout<Float>.stride, index: 2)
                oldStyleEncoder.setFragmentBytes(&echoAlpha, length: MemoryLayout<Float>.stride, index: 3)
                oldStyleEncoder.setFragmentBytes(&flipUV, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
                oldStyleEncoder.setFragmentBytes(&gammaAdj, length: MemoryLayout<Float>.stride, index: 5)
                oldStyleEncoder.setFragmentBytes(&filterFlags, length: MemoryLayout<SIMD4<Float>>.stride, index: 6)
                oldStyleEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                oldStyleEncoder.endEncoding()

                // Same reasoning as the compiledComposite branch above: destTexture must hold the
                // true final frame afterward, both for presenting below and for next frame's
                // feedback pass to read as "previous frame".
                if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                    blitEncoder.copy(from: scratchTexture, to: destTexture)
                    blitEncoder.endEncoding()
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

    // MARK: - Transient vertex buffer pool (waveform/shape/custom-waveform geometry, rebuilt every frame)

    /// Replaces a fresh `device.makeBuffer` call on *every single draw call, every frame* (a real,
    /// measured cost — easily 5-20+ allocations/frame for a preset with several shapes and custom
    /// waveforms) with reused, grow-only-when-needed buffers — the same pattern projectM's own
    /// Renderer/VertexBuffer.cpp uses (`glBufferSubData` when the size hasn't changed, `glBufferData`
    /// only when it has — see `VertexBuffer<VT>::Update()`), just via a direct `.contents()` memcpy
    /// instead of a driver call, since Metal's `.storageModeShared` buffers are already CPU-writable.
    ///
    /// Triple-buffered (3 rotating generations, indexed by `frameCounter % 3`), not just one reused
    /// buffer per draw-call slot: a `.storageModeShared` `MTLBuffer` is plain shared memory with no
    /// automatic protection against the CPU overwriting a buffer the GPU hasn't finished reading yet
    /// from an *earlier* frame's draw call — rotating across 3 generations gives the GPU two frames'
    /// worth of headroom before the same underlying buffer is reused, the standard "triple buffering"
    /// hazard-avoidance pattern for exactly this situation. Within one frame, each draw call still
    /// gets its own distinct buffer (never aliased with another draw call's data, which a single
    /// shared "current" buffer could not guarantee) via a per-frame, per-generation slot counter.
    private final class TransientBufferPool {
        private final class Slot {
            var buffer: MTLBuffer?
            var capacity = 0
        }
        private var generations: [[Slot]] = [[], [], []]
        private var generationIndex = 0
        private var nextSlotIndex = 0

        /// Call once at the top of each frame, before any draw calls that will request a buffer.
        func beginFrame(generation: Int) {
            generationIndex = generation % generations.count
            nextSlotIndex = 0
        }

        /// Copies `values` into the next available buffer for this frame's generation, growing that
        /// slot only if it isn't already big enough (mirrors `VertexBuffer::Update`'s size check).
        /// `nil` for empty input, matching the draw helpers' own empty-input guards.
        func buffer<T>(for values: [T], device: MTLDevice) -> MTLBuffer? {
            guard !values.isEmpty else { return nil }
            if nextSlotIndex >= generations[generationIndex].count {
                generations[generationIndex].append(Slot())
            }
            let slot = generations[generationIndex][nextSlotIndex]
            nextSlotIndex += 1

            let byteCount = MemoryLayout<T>.stride * values.count
            if slot.buffer == nil || slot.capacity < byteCount {
                slot.buffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
                slot.capacity = byteCount
            }
            guard let buffer = slot.buffer else { return nil }
            values.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            return buffer
        }
    }

    private let transientBuffers = TransientBufferPool()

    // MARK: - CPU-side geometry building (cheap: a few hundred vertices, not a bottleneck)

    private func draw(_ vertices: [SIMD2<Float>], as primitive: MTLPrimitiveType, on encoder: MTLRenderCommandEncoder, device: MTLDevice) {
        let minCount = primitive == .triangleStrip ? 2 : 3
        guard vertices.count >= minCount,
              let buffer = transientBuffers.buffer(for: vertices, device: device)
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

    /// CPU-side mirror of Shaders.metal's `ShapeTexturedVertex` — same layout as `ShapeVertex` plus
    /// a UV pair.
    private struct ShapeTexturedVertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
        var uv: SIMD2<Float>
    }

    private func drawShape(_ vertices: [ShapeVertex], as primitive: MTLPrimitiveType, on encoder: MTLRenderCommandEncoder, device: MTLDevice) {
        let minCount = primitive == .triangleStrip ? 2 : 3
        guard vertices.count >= minCount,
              let buffer = transientBuffers.buffer(for: vertices, device: device)
        else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: vertices.count)
    }

    private func drawShape(_ vertices: [ShapeTexturedVertex], as primitive: MTLPrimitiveType, on encoder: MTLRenderCommandEncoder, device: MTLDevice) {
        let minCount = primitive == .triangleStrip ? 2 : 3
        guard vertices.count >= minCount,
              let buffer = transientBuffers.buffer(for: vertices, device: device)
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

    /// Textured counterpart of `shapeFillVertices`: same center/rim geometry and per-vertex color
    /// gradient, plus a UV per vertex — an exact port of CustomShape.cpp:180-193's UV math. The
    /// fill's own polygon angle (`ang`) drives vertex *position*; the UV's angle uses the shape's
    /// independent `tex_ang`/`tex_zoom`, so the texture can be rotated/scaled across the polygon
    /// without moving the polygon itself. Note the vertical flip (`1 - (...)`) — required because
    /// Metal's UV origin convention is flipped relative to Milkdrop's, same as upstream's own
    /// comment on this exact line.
    private static func shapeTexturedFillVertices(_ instance: MilkdropShapeInstance, pixelSize: CGSize, aspect: Float) -> [ShapeTexturedVertex] {
        let (centerNDC, rim) = shapeRimPointsNDC(instance, aspect: aspect)
        guard rim.count >= 3, instance.sides >= 3 else { return [] }

        func toPixel(_ ndc: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(ndc.x * 0.5 * Float(pixelSize.width), ndc.y * 0.5 * Float(pixelSize.height))
        }

        let pi: Float = .pi
        var rimUVs: [SIMD2<Float>] = []
        rimUVs.reserveCapacity(instance.sides)
        for i in 0..<instance.sides {
            let cornerProgress = Float(i) / Float(instance.sides)
            let angle = cornerProgress * pi * 2 + instance.texAng + pi * 0.25
            rimUVs.append(SIMD2<Float>(
                0.5 + 0.5 * cosf(angle) / instance.texZoom * aspect,
                1 - (0.5 - 0.5 * sinf(angle) / instance.texZoom)
            ))
        }

        let center = ShapeTexturedVertex(
            position: toPixel(centerNDC), color: SIMD4<Float>(instance.r, instance.g, instance.b, instance.a),
            uv: SIMD2<Float>(0.5, 0.5)
        )
        let rimColor = SIMD4<Float>(instance.r2, instance.g2, instance.b2, instance.a2)
        let rimPixels = rim.map(toPixel)

        var verts: [ShapeTexturedVertex] = []
        verts.reserveCapacity(rim.count * 3)
        for i in 0..<rim.count {
            let next = (i + 1) % rim.count
            verts.append(center)
            verts.append(ShapeTexturedVertex(position: rimPixels[i], color: rimColor, uv: rimUVs[i]))
            verts.append(ShapeTexturedVertex(position: rimPixels[next], color: rimColor, uv: rimUVs[next]))
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

    // MARK: - Border / darken-center (Border.cpp / DarkenCenter.cpp — no Prism equivalent before this)

    /// Exact port of Border.cpp's two nested-square-outline meshes: an outer ring flush with the
    /// screen edge and an inner ring just inside it, each a flat (not gradient) color, each only
    /// drawn if its own alpha exceeds Milkdrop's own `0.001` visibility threshold. Unlike the shape
    /// polygons above, upstream applies no aspect correction to these squares at all (plain ±1 NDC
    /// coordinates) — ported faithfully, not "fixed", since a border is meant to hug the actual
    /// screen edges regardless of aspect ratio. Builds both rings' triangles as one array (rather
    /// than two separate draw calls) since they share a pipeline/blend mode and neither depends on
    /// the other's vertex count.
    private static func borderVertices(_ params: MilkdropBorderParams, pixelSize: CGSize) -> [ShapeVertex] {
        func toPixel(_ ndc: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(ndc.x * 0.5 * Float(pixelSize.width), ndc.y * 0.5 * Float(pixelSize.height))
        }

        // Same 8-vertex/8-triangle "picture frame" ring topology Border.cpp builds once and reuses
        // for both the outer and inner border (only the radii and color differ between the two).
        func ringTriangles(outerRadius: Float, innerRadius: Float, color: SIMD4<Float>) -> [ShapeVertex] {
            let corners: [SIMD2<Float>] = [
                SIMD2(outerRadius, outerRadius), SIMD2(outerRadius, -outerRadius),
                SIMD2(-outerRadius, outerRadius), SIMD2(-outerRadius, -outerRadius),
                SIMD2(innerRadius, innerRadius), SIMD2(innerRadius, -innerRadius),
                SIMD2(-innerRadius, innerRadius), SIMD2(-innerRadius, -innerRadius),
            ].map(toPixel)
            let indices = [0, 1, 4, 1, 4, 5, 2, 3, 6, 3, 7, 6, 2, 0, 6, 0, 4, 6, 3, 7, 5, 1, 3, 5]
            return indices.map { ShapeVertex(position: corners[$0], color: color) }
        }

        var verts: [ShapeVertex] = []
        if params.outerA > 0.001 {
            verts += ringTriangles(
                outerRadius: 1.0, innerRadius: 1.0 - params.outerSize,
                color: SIMD4<Float>(params.outerR, params.outerG, params.outerB, params.outerA)
            )
        }
        if params.innerA > 0.001 {
            verts += ringTriangles(
                outerRadius: 1.0 - params.outerSize, innerRadius: 1.0 - params.outerSize - params.innerSize,
                color: SIMD4<Float>(params.innerR, params.innerG, params.innerB, params.innerA)
            )
        }
        return verts
    }

    /// Exact port of DarkenCenter.cpp's fixed-size diamond: a center vertex at alpha `3/32`
    /// fading to fully transparent at 4 points `halfSize` away (aspect-corrected on X only, same
    /// convention as the shape/waveform code above), all black. Drawn as 4 explicit triangles
    /// (Metal has no native triangle-fan primitive) rather than the fan connectivity upstream uses.
    private static func darkenCenterVertices(aspect: Float, pixelSize: CGSize) -> [ShapeVertex] {
        func toPixel(_ ndc: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(ndc.x * 0.5 * Float(pixelSize.width), ndc.y * 0.5 * Float(pixelSize.height))
        }
        let halfSize: Float = 0.05
        let center = ShapeVertex(position: toPixel(.zero), color: SIMD4<Float>(0, 0, 0, 3.0 / 32.0))
        let rim: [SIMD2<Float>] = [
            SIMD2(-halfSize * aspect, 0), SIMD2(0, -halfSize), SIMD2(halfSize * aspect, 0), SIMD2(0, halfSize),
        ].map(toPixel)
        let rimColor = SIMD4<Float>(0, 0, 0, 0)

        var verts: [ShapeVertex] = []
        verts.reserveCapacity(4 * 3)
        for i in 0..<4 {
            let next = rim[(i + 1) % 4]
            verts.append(center)
            verts.append(ShapeVertex(position: rim[i], color: rimColor))
            verts.append(ShapeVertex(position: next, color: rimColor))
        }
        return verts
    }

    // MARK: - Custom waveform geometry (wavecode_N_* — see MilkdropCustomWaveform.swift)

    /// Ribbon extrusion for a custom waveform's line-strip trace — same normal-based two-
    /// vertices-per-point technique as `lineStripVertices`, but carrying each point's own color
    /// (a custom waveform's per-point script can set r/g/b/a independently at every vertex, unlike
    /// the built-in waveform's single flat color) instead of mapping to one uniform color
    /// afterward like `shapeOutlineVertices` does.
    private static func customWaveformRibbonVertices(_ points: [MilkdropCustomWaveformPoint], pixelSize: CGSize, halfWidth: Float) -> [ShapeVertex] {
        guard points.count > 1 else { return [] }
        let n = points.count
        func toPixel(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(p.x * 0.5 * Float(pixelSize.width), p.y * 0.5 * Float(pixelSize.height))
        }
        var verts: [ShapeVertex] = []
        verts.reserveCapacity(n * 2)
        for i in 0..<n {
            let p = toPixel(points[i].position)
            let a = toPixel(points[max(0, i - 1)].position)
            let b = toPixel(points[min(n - 1, i + 1)].position)
            var tangent = b - a
            let len = simd_length(tangent)
            tangent = len > 0.0001 ? (tangent / len) : SIMD2<Float>(1, 0)
            let normal = SIMD2<Float>(-tangent.y, tangent.x)
            verts.append(ShapeVertex(position: p + normal * halfWidth, color: points[i].color))
            verts.append(ShapeVertex(position: p - normal * halfWidth, color: points[i].color))
        }
        return verts
    }

    /// Small filled square per point (two triangles), for `bUseDots` custom waveforms — Milkdrop's
    /// own dot mode draws GL_POINTS with a settable point size; a tiny quad is the closest
    /// equivalent in Metal without a dedicated point-sprite pipeline.
    private static func customWaveformDotVertices(_ points: [MilkdropCustomWaveformPoint], pixelSize: CGSize, halfSize: Float) -> [ShapeVertex] {
        guard !points.isEmpty else { return [] }
        func toPixel(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(p.x * 0.5 * Float(pixelSize.width), p.y * 0.5 * Float(pixelSize.height))
        }
        var verts: [ShapeVertex] = []
        verts.reserveCapacity(points.count * 6)
        for point in points {
            let center = toPixel(point.position)
            let corners = [
                center + SIMD2(-halfSize, -halfSize), center + SIMD2(halfSize, -halfSize),
                center + SIMD2(-halfSize, halfSize), center + SIMD2(halfSize, halfSize),
            ]
            verts.append(ShapeVertex(position: corners[0], color: point.color))
            verts.append(ShapeVertex(position: corners[1], color: point.color))
            verts.append(ShapeVertex(position: corners[2], color: point.color))
            verts.append(ShapeVertex(position: corners[1], color: point.color))
            verts.append(ShapeVertex(position: corners[3], color: point.color))
            verts.append(ShapeVertex(position: corners[2], color: point.color))
        }
        return verts
    }
}
