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

/// Renders one preset's entire pipeline into an offscreen texture — nothing here touches a live
/// `MTKView` drawable directly (see `renderToTexture(view:)`) so that MilkdropMetalCoordinator can
/// hold two independent instances (the front-facing preset and, only during a transition, the one
/// it's fading out of) and composite their output itself.
final class MilkdropMetalRenderer: NSObject {
    private let audioEngine: CoreAudioTapEngine
    let model: MilkdropVisualizerModel
    var color: Color = .white
    var bassEnergy: CGFloat = 0

    // Every static, preset-independent GPU resource (pipelines/samplers/fixed functions/geometry)
    // now lives on `shared` — see MilkdropMetalCoordinator.swift's MilkdropSharedRenderResources —
    // so that switching presets doesn't recompile ~15 pipeline states or regenerate the noise
    // texture catalog every time. Computed passthroughs below keep every reference to e.g.
    // `device`/`solidPipeline` elsewhere in this file unchanged (still just `device`, not
    // `shared.device`), so this split touched nothing past `init` and these declarations.
    private let shared: MilkdropSharedRenderResources
    private var device: MTLDevice { shared.device }
    private var commandQueue: MTLCommandQueue { shared.commandQueue }
    private var solidPipeline: MTLRenderPipelineState { shared.solidPipeline }
    private var feedbackPipeline: MTLRenderPipelineState { shared.feedbackPipeline }
    private var presentPipeline: MTLRenderPipelineState { shared.presentPipeline }
    private var oldStyleCompositePipeline: MTLRenderPipelineState { shared.oldStyleCompositePipeline }
    private var feedbackMeshPipeline: MTLRenderPipelineState { shared.feedbackMeshPipeline }
    private var meshIndexBuffer: MTLBuffer { shared.meshIndexBuffer }
    private var shapeAdditivePipeline: MTLRenderPipelineState { shared.shapeAdditivePipeline }
    private var shapeAlphaPipeline: MTLRenderPipelineState { shared.shapeAlphaPipeline }
    private var shapeTexturedAdditivePipeline: MTLRenderPipelineState { shared.shapeTexturedAdditivePipeline }
    private var shapeTexturedAlphaPipeline: MTLRenderPipelineState { shared.shapeTexturedAlphaPipeline }
    private var feedbackVertexFunction: MTLFunction { shared.feedbackVertexFunction }
    private var feedbackMeshVertexFunction: MTLFunction { shared.feedbackMeshVertexFunction }
    private var feedbackMeshFragmentFunction: MTLFunction { shared.feedbackMeshFragmentFunction }
    private var samplerLinearRepeat: MTLSamplerState { shared.samplerLinearRepeat }
    private var samplerLinearClamp: MTLSamplerState { shared.samplerLinearClamp }
    private var samplerNearestRepeat: MTLSamplerState { shared.samplerNearestRepeat }
    private var samplerNearestClamp: MTLSamplerState { shared.samplerNearestClamp }
    private var noiseTextures: MilkdropNoiseTextures? { shared.noiseTextures }
    private var blurDownsamplePipeline: MTLRenderPipelineState { shared.blurDownsamplePipeline }
    // Preset-pack `Textures/` lookups for custom sampler names (`sampler_worms`, `sampler_rand00`,
    // etc. — see MilkdropShaderTranslator's `.custom` resource case). Deliberately kept per-instance
    // (NOT moved to MilkdropSharedRenderResources like everything above) despite looking just as
    // "not preset-specific" — its `scannedRoot`/`randomTextureDescriptors`-equivalent cache
    // (MilkdropCustomTextureManager.swift) is single, unkeyed, mutable state, not indexed by
    // preset. Sharing one instance across the active and outgoing renderer during a transition
    // would let whichever one calls `prepareForPreset` second silently stomp the other's resolved
    // root/random-slot choices if the two presets come from different packs — a real correctness
    // bug, not just a missed sharing opportunity.
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

    /// A `per_pixel_N=` script compiled directly into a GPU vertex function (Tier 3 of TO DO.md's
    /// performance-pass notes) — `nil` whenever the loaded preset has no per-pixel script, its
    /// script isn't provably safe to evaluate in parallel, or it uses an unsupported construct
    /// (see `compilePerPixelMeshVertex`'s own doc comment) — in which case the existing CPU
    /// `MilkdropPerPixelMeshRuntime.calculate()` path keeps being used, unchanged.
    private var compiledPerPixelMeshVertex: MTLFunction?
    private var compiledPerPixelMeshVertexGeneration = -1
    /// Pairs `compiledPerPixelMeshVertex` with the static `feedback_mesh_fragment` — for a preset
    /// with a GPU-compiled per-pixel script but no `warp_N=` shader of its own (the `compiledWarp`
    /// pipeline above already handles the "has both" case, since it's built with
    /// `compiledPerPixelMeshVertex` as its vertex function whenever one is available). Rebuilt
    /// alongside `compiledPerPixelMeshVertex`, `nil` under the same conditions.
    private var compiledPerPixelMeshOnlyPipeline: MTLRenderPipelineState?

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
    // GetBlur1/GetBlur2/GetBlur3 (BlurTexture.cpp) — index 0/1/2 is blur1/2/3, each a
    // progressively smaller+blurrier downsample of the previous level (level 0 downsamples
    // destTexture) — see updateBlurTextures. Only allocated/regenerated for the rare preset that
    // actually references one (see `usesBlur` in renderToTexture), so this costs nothing for the
    // 99.9%-of-corpus case that doesn't.
    private var blurTextures: [MTLTexture?] = [nil, nil, nil]
    private var blurSourceSize: CGSize = .zero
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

    init(shared: MilkdropSharedRenderResources, audioEngine: CoreAudioTapEngine, model: MilkdropVisualizerModel) {
        self.shared = shared
        self.audioEngine = audioEngine
        self.model = model
        self.customTextures = MilkdropCustomTextureManager(device: shared.device)
        super.init()
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

    /// Regenerates `blurTextures` from `source` (this frame's already-rendered `destTexture`,
    /// before the composite pass that would actually sample these) — only called when the
    /// compiled `comp_N=`/`warp_N=` shader this frame actually references a `.blur` resource (see
    /// `renderToTexture`'s `usesBlur` gating), so this costs nothing for the ~99.9% of presets that
    /// never reference `GetBlur1`/`GetBlur2`/`GetBlur3`/`sampler_blur1-3`. Three-level cascade,
    /// each level a downsample+blur of the previous (`milkdrop_blur_downsample_fragment`) — level
    /// sizes floor at 16px, matching BlurTexture.cpp's own `max(16, width/2)` floor.
    private func updateBlurTextures(source: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let sourceSize = CGSize(width: source.width, height: source.height)
        if blurSourceSize != sourceSize {
            blurSourceSize = sourceSize
            var w = source.width
            var h = source.height
            for i in 0..<3 {
                w = max(16, w / 2)
                h = max(16, h / 2)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
                )
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                blurTextures[i] = device.makeTexture(descriptor: descriptor)
            }
        }

        var previous = source
        for i in 0..<3 {
            guard let target = blurTextures[i] else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            var texelSize = SIMD2<Float>(1.0 / Float(previous.width), 1.0 / Float(previous.height))
            encoder.setRenderPipelineState(blurDownsamplePipeline)
            encoder.setFragmentTexture(previous, index: 0)
            encoder.setFragmentBytes(&texelSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            previous = target
        }
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
    /// `vertexFunction` is normally the static `feedbackMeshVertexFunction`, but becomes a
    /// GPU-compiled `per_pixel_N=` vertex function instead whenever one is available for the same
    /// preset (see `compilePerPixelMeshVertex` below and draw(in:)'s compile-gating section) —
    /// real Milkdrop always draws a warp shader through the mesh regardless of whether the mesh's
    /// own per-vertex attributes come from a script or a uniform value, so the two features
    /// compose freely; this just lets a compiled per-pixel vertex function replace whichever
    /// vertex stage a compiled warp fragment pairs with, same as it already replaces the
    /// CPU-computed `MilkdropMeshVertexAttributes` buffer for the mesh-only path.
    private func compileWarpShader(source: String, vertexFunction: MTLFunction) -> CompiledMilkdropShader? {
        guard let translated = MilkdropShaderTranslator.translate(source) else { return nil }
        let mslSource = Self.buildWarpShaderSource(translated)
        guard let dynamicLibrary = try? device.makeLibrary(source: mslSource, options: nil),
              let fragmentFunction = dynamicLibrary.makeFunction(name: "milkdrop_warp_main")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let randPreset = SIMD4<Float>(.random(in: 0...1), .random(in: 0...1), .random(in: 0...1), .random(in: 0...1))
        return CompiledMilkdropShader(pipelineState: pipelineState, textures: translated.textures, randPreset: randPreset)
    }

    // MARK: - Dynamic shader compilation (per_pixel_N= -> GPU vertex function — Tier 3 of TO DO.md's
    // performance-pass notes)

    /// `MTLCompileOptions` shared by every dynamically-compiled NS-EEL-derived library in this
    /// file (currently just `compilePerPixelMeshVertex` below) — `mathMode = .safe` (fast-math
    /// off) specifically because this feature's whole safety contract depends on GPU output
    /// matching what the CPU fallback (`MilkdropExpressionEvaluator`) would have produced for the
    /// same preset; fast-math's looser IEEE guarantees risk masking a real transpiler bug as
    /// "close enough," or genuinely diverging preset-to-preset across different GPU hardware. Not
    /// applied (yet) to `compileCompositeShader`/`compileWarpShader`'s HLSL-derived shaders above —
    /// those have no CPU-reference-equivalence contract to protect, just a visual-fidelity one.
    private static var perPixelMeshCompileOptions: MTLCompileOptions {
        let options = MTLCompileOptions()
        options.mathMode = .safe
        return options
    }

    /// Attempts to compile a preset's `per_pixel_N=` script directly into a GPU vertex function,
    /// replacing up to 825 CPU tree-interpreter evaluations/frame (`MilkdropPerPixelMeshRuntime.
    /// calculate()`) with one GPU-parallel dispatch. `nil` on any failure — the script uses a
    /// cross-vertex-unsafe pattern (`MilkdropExpressionParallelSafetyAnalyzer` rejects it — e.g. a
    /// `hue=hue+0.05;`-style accumulator that depends on evaluation order between vertices, which a
    /// parallel GPU dispatch can't reproduce), an unsupported construct (`MilkdropExpressionMSL
    /// Transpiler` rejects it — currently just `rand()`), or a genuine Metal compiler rejection —
    /// all fall back identically, to the existing CPU `MilkdropPerPixelMeshRuntime.calculate()`
    /// path, never a crash or a visual regression. Measured 7/26 against the real ~9,795-file
    /// preset pack: 86.7% of files with `per_pixel_N=` code (5,244 of 6,049) pass the safety check
    /// — see TO DO.md for the full corpus measurement.
    private func compilePerPixelMeshVertex(_ mesh: MilkdropPerPixelMeshRuntime) -> MTLFunction? {
        guard MilkdropExpressionParallelSafetyAnalyzer.isSweepParallelSafe(
            mesh.statements, builtins: MilkdropPerPixelMeshRuntime.builtinNames
        ) else { return nil }
        guard let transpiled = MilkdropExpressionMSLTranspiler.transpile(
            mesh.statements, builtins: MilkdropPerPixelMeshRuntime.builtinNames
        ) else { return nil }
        let mslSource = Self.buildPerPixelMeshVertexSource(transpiled)
        guard let dynamicLibrary = try? device.makeLibrary(source: mslSource, options: Self.perPixelMeshCompileOptions)
        else { return nil }
        return dynamicLibrary.makeFunction(name: "milkdrop_per_pixel_mesh_vertex")
    }

    /// Wraps a transpiled `per_pixel_N=` body into a complete MSL vertex function. The warp math
    /// below (`zoom2`/UV-warp/rotate/translate) is a direct, deliberate duplicate of
    /// Shaders.metal's `feedback_mesh_vertex` — separately-compiled `MTLLibrary` sources can't
    /// share a function across libraries (same constraint `shaderShimHeader`'s struct
    /// redeclarations above already document), so if that shared math ever changes,
    /// `feedback_mesh_vertex` and this generator must be updated together. Reads
    /// zoom/zoomExp/rot/warp/cx/cy/dx/dy/sx/sy from the transpiled script's own locals (seeded from
    /// `meshUniforms`, then possibly overwritten by the script) instead of a per-vertex input
    /// struct's fields, since those are exactly what a `per_pixel_N=` script differentiates
    /// per-vertex.
    // Not `private`, same reason as buildCompositeShaderSource/buildWarpShaderSource above:
    // PrismTests compiles this generated MSL through a real MTLDevice.
    static func buildPerPixelMeshVertexSource(_ transpiled: MilkdropExpressionMSLTranspiler.Result) -> String {
        // A closure literal, not a bare `Type.mslIdentifier(for:)` reference — see this file's
        // other such fixes (e.g. MilkdropVisualizerView.swift's `.map { Type(preset: $0) }`) for
        // why a first-class reference to an isolated static method doesn't type-check the same way.
        let id: (String) -> String = { MilkdropExpressionMSLTranspiler.mslIdentifier(for: $0) }
        var uniformSeeds: [String] = []
        for (i, name) in MilkdropPerPixelMeshRuntime.perFrameUniformBuiltinNames.enumerated() {
            uniformSeeds.append("    float \(id(name)) = meshUniforms[\(i)];")
        }
        var customDecls: [String] = []
        for name in transpiled.customVariableNames {
            customDecls.append("    float \(id(name)) = 0.0f;")
        }

        return """
        #include <metal_stdlib>
        using namespace metal;

        struct MeshStaticVertex {
            float2 position;
            float2 radiusAngle;
        };

        struct MeshVertexOut {
            float4 position [[position]];
            float2 uv;
            float2 uvOrig;
            float2 radiusAngle;
        };

        \(MilkdropExpressionMSLTranspiler.shimFunctions)

        vertex MeshVertexOut milkdrop_per_pixel_mesh_vertex(
            const device MeshStaticVertex *vertices [[buffer(0)]],
            constant float *meshUniforms [[buffer(1)]],
            constant float &warpTime [[buffer(2)]],
            constant float &warpScaleInverse [[buffer(3)]],
            constant float4 &warpFactors [[buffer(4)]],
            constant float2 &aspect [[buffer(5)]],
            constant float2 &invAspect [[buffer(6)]],
            uint vid [[vertex_id]]
        ) {
            MeshStaticVertex vert = vertices[vid];
            float2 pos = vert.position;

        \(uniformSeeds.joined(separator: "\n"))
            float \(id("x")) = pos.x * 0.5 * aspect.x + 0.5;
            float \(id("y")) = pos.y * 0.5 * aspect.y + 0.5;
            float \(id("rad")) = vert.radiusAngle.x;
            float \(id("ang")) = -vert.radiusAngle.y;

        \(customDecls.joined(separator: "\n"))
        \(transpiled.body)

            float zoom2 = pow(\(id("zoom")), pow(\(id("zoomexp")), vert.radiusAngle.x * 2.0 - 1.0));
            float zoom2Inverse = 1.0 / zoom2;

            float u = pos.x * aspect.x * 0.5 * zoom2Inverse + 0.5;
            float v = pos.y * aspect.y * 0.5 * zoom2Inverse + 0.5;

            u = (u - \(id("cx"))) / \(id("sx")) + \(id("cx"));
            v = (v - \(id("cy"))) / \(id("sy")) + \(id("cy"));

            u += \(id("warp")) * 0.0035 * sin(warpTime * 0.333 + warpScaleInverse * (pos.x * warpFactors.x - pos.y * warpFactors.w));
            v += \(id("warp")) * 0.0035 * cos(warpTime * 0.375 - warpScaleInverse * (pos.x * warpFactors.z + pos.y * warpFactors.y));
            u += \(id("warp")) * 0.0035 * cos(warpTime * 0.753 - warpScaleInverse * (pos.x * warpFactors.y - pos.y * warpFactors.z));
            v += \(id("warp")) * 0.0035 * sin(warpTime * 0.825 + warpScaleInverse * (pos.x * warpFactors.x + pos.y * warpFactors.w));

            float u2 = u - \(id("cx"));
            float v2 = v - \(id("cy"));
            float cosRot = cos(\(id("rot")));
            float sinRot = sin(\(id("rot")));
            u = u2 * cosRot - v2 * sinRot + \(id("cx"));
            v = u2 * sinRot + v2 * cosRot + \(id("cy"));

            u -= \(id("dx"));
            v -= \(id("dy"));

            u = (u - 0.5) * invAspect.x + 0.5;
            v = (v - 0.5) * invAspect.y + 0.5;

            MeshVertexOut out;
            out.position = float4(pos, 0.0, 1.0);
            out.uv = float2(u, v);
            out.uvOrig = pos * 0.5 + 0.5;
            out.radiusAngle = vert.radiusAngle;
            return out;
        }
        """
    }

    /// Builds the flat uniform array `buildPerPixelMeshVertexSource`'s `meshUniforms[i]` reads —
    /// index order must exactly match `MilkdropPerPixelMeshRuntime.perFrameUniformBuiltinNames`.
    private func buildPerPixelMeshUniforms(
        time: Double, fps: Double, frame: Int, energy: MilkdropBandEnergy,
        aspectX: Float, aspectY: Float, pixelWidth: Float, pixelHeight: Float, qVars: [Float],
        zoom: Float, zoomExp: Float, rot: Float, warp: Float,
        cx: Float, cy: Float, dx: Float, dy: Float, sx: Float, sy: Float
    ) -> [Float] {
        var uniforms: [Float] = [
            Float(time), Float(fps), Float(frame),
            energy.bass, energy.mid, energy.treb, energy.bassAtt, energy.midAtt, energy.trebAtt,
            Float(MilkdropPerPixelMeshRuntime.gridSizeX), Float(MilkdropPerPixelMeshRuntime.gridSizeY),
            // pixelsx/pixelsy (real viewport pixel dimensions, PerPixelContext.cpp's
            // `*pixelsx = viewportSizeX` etc — confirmed against upstream) then aspectx/aspecty
            // (the actual aspect-ratio-correction values) — these are two genuinely different
            // built-ins, previously both aliased to aspectX/aspectY here.
            pixelWidth, pixelHeight, aspectX, aspectY,
            zoom, zoomExp, rot, warp, cx, cy, dx, dy, sx, sy,
        ]
        uniforms.reserveCapacity(uniforms.count + 32)
        for i in 0..<32 {
            uniforms.append(i < qVars.count ? qVars[i] : 0)
        }
        return uniforms
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
    /// (passed in, since it changes every frame — unlike the noise catalog, generated once). `.blur`
    /// (the `GetBlur1`/`GetBlur2`/`GetBlur3` helper functions) resolves to the real downsampled/
    /// blurred texture from `updateBlurTextures` — falling back to `mainTexture` only if that level
    /// hasn't been generated yet (first frame after a resize, before `renderToTexture`'s `usesBlur`
    /// gate has had a chance to allocate it), matching this function's existing graceful-fallback
    /// contract for any other momentarily-unresolvable binding.
    private func metalTexture(for binding: MilkdropShaderTranslator.TextureBinding, mainTexture: MTLTexture) -> MTLTexture? {
        switch binding.resource {
        case .main: return mainTexture
        case .blur(let level):
            let index = level - 1
            guard blurTextures.indices.contains(index) else { return mainTexture }
            return blurTextures[index] ?? mainTexture
        case .noise(let name): return noiseTextures?.texture(named: name)
        case .custom(let name): return customTextures.texture(named: name)
        }
    }

    /// Renders this preset's whole pipeline for one frame and returns the finished texture —
    /// everything through Pass 1.5 (composite), unchanged from the old single-renderer `draw(in:)`.
    /// Does not touch `view.currentDrawable` at all; MilkdropMetalCoordinator.draw(in:) owns
    /// presenting (and, during a transition, blending two of these calls' results together).
    func renderToTexture(view: MTKView) -> MTLTexture? {
        ensureTextures(size: view.drawableSize)
        guard let sourceTexture = textures[sourceIndex],
              let destTexture = textures[1 - sourceIndex] else { return nil }

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
        // Compiled BEFORE compiledWarp below, since a compiled warp_N= fragment's own pipeline
        // needs to know whether to pair with this (when available) or the static
        // feedbackMeshVertexFunction — see compileWarpShader's doc comment.
        if compiledPerPixelMeshVertexGeneration != model.loadGeneration {
            compiledPerPixelMeshVertex = model.perPixelMesh.flatMap(compilePerPixelMeshVertex)
            compiledPerPixelMeshOnlyPipeline = compiledPerPixelMeshVertex.flatMap { vertexFunction -> MTLRenderPipelineState? in
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = feedbackMeshFragmentFunction
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try? device.makeRenderPipelineState(descriptor: descriptor)
            }
            compiledPerPixelMeshVertexGeneration = model.loadGeneration
        }
        let meshVertexFunction = compiledPerPixelMeshVertex ?? feedbackMeshVertexFunction
        if compiledWarpGeneration != model.loadGeneration {
            compiledWarp = model.warpShaderSource.isEmpty
                ? nil : compileWarpShader(source: model.warpShaderSource, vertexFunction: meshVertexFunction)
            compiledWarpGeneration = model.loadGeneration
        }
        // Same "only the longer dimension's axis compresses, the other stays 1" convention as
        // WaveformMath.cpp:62-70 (`m_aspectX`/`m_aspectY`) and this function's own `aspectXY` below
        // (computed again locally here since `aspectXY` itself isn't in scope yet at this point in
        // the function — same two formulas, `aspect` here matches `aspectXY.y`, `aspectXForWaveform`
        // matches `aspectXY.x`) — `aspect`'s old unclamped `height/width` value matched this exactly
        // in the common landscape case but was wrong (>1, never clamped to 1) in portrait.
        let waveWidthF = Float(pixelSize.width)
        let waveHeightF = Float(pixelSize.height)
        let aspect: Float = waveWidthF > waveHeightF ? waveHeightF / waveWidthF : 1.0
        let aspectXForWaveform: Float = waveHeightF > waveWidthF ? waveWidthF / waveHeightF : 1.0
        let (rawPoints, rawBreak) = MilkdropWaveform.points(
            mode: model.mode, left: scaledLeft, right: scaledRight, spectrum: magnitudeSpectrum,
            params: model.params, time: time, aspect: aspect, aspectX: aspectXForWaveform
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

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // MARK: Pass 1 — feedback (decayed/zoomed/rotated previous frame) + new stroke, into destTexture

        let feedbackPass = MTLRenderPassDescriptor()
        feedbackPass.colorAttachments[0].texture = destTexture
        feedbackPass.colorAttachments[0].loadAction = .clear
        feedbackPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        feedbackPass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: feedbackPass) else { return nil }

        // Base transform comes from the loaded preset's real per-frame zoom/rot/warp/etc. (neutral
        // defaults — zoom=1, rot=0, warp=1, decay=0.98 — when nothing's loaded, matching real
        // Milkdrop's own per-frame defaults; see MilkdropVisualizerView.swift's warpParams). The
        // existing beat-punch boost layers on top of that as a small additive/multiplicative
        // nudge — a Prism-specific touch (real Milkdrop has no "punch" concept), kept so the
        // default no-preset look stays exactly as reactive as it always has, and so a loaded
        // preset's own animation still gets a little extra life on a hit rather than being
        // replaced by it.
        //
        // The 1.006/0.0025 constants below read as tuned for a ~60fps reference (60 render calls
        // of 1.006x compounding to a plausible ~1.43x zoom/sec) but MilkdropMetalView sets
        // `preferredFramesPerSecond = 120`, and this nudge was being applied once per *rendered*
        // frame with no time-normalization at all — at the actual 120fps this runs at, it silently
        // compounded to ~2.05x zoom/sec (double the apparent reference tuning) and rotation ran 2x
        // real-world speed too, regardless of what any given preset's own per-frame script asked
        // for (those already normalize via `1/fps`, so they were unaffected — only this fixed
        // Prism-specific nudge wasn't, which is why the whole scene reads as "too fast and
        // chaotic" beyond just any one preset's own animation). `rateScale` rescales both back to
        // a true 60fps-equivalent per-second rate at whatever `beat.lastFPS` actually is this
        // frame (exponent for the multiplicative zoom rate, linear multiplier for the additive rot
        // rate — see MilkdropAudioSignals.swift's `adjustRateToFPS` for the same technique) —
        // identical output to before at exactly 60fps, half the growth per frame at 120fps for the
        // same real-world-per-second result.
        let rateScale = Float(60.0 / beat.lastFPS)
        let punchF = Float(punch)
        var zoom = model.warpParams.zoom * powf(1.006 + punchF * 0.035, rateScale)
        var zoomExponent = model.warpParams.zoomExponent
        var rot = model.warpParams.rot + (0.0025 + punchF * 0.01) * rateScale
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
        //
        // Within (1)/(2), a per_pixel_N= script that compiled to a GPU vertex function
        // (`compiledPerPixelMeshVertex` — see the compile-gating section above) runs entirely on
        // GPU instead: the CPU `MilkdropPerPixelMeshRuntime.calculate()` tree-interpreter sweep
        // (up to 825 evaluations/frame — see TO DO.md's performance-pass notes) is skipped
        // entirely, replaced by a small per-frame uniform buffer + the cached static vertex
        // geometry. `usingGPUPerPixelMesh` implies `model.perPixelMesh != nil` (the compile step
        // is itself `model.perPixelMesh.flatMap(...)`), so `model.updatePerPixelMesh` — which
        // would otherwise run that same CPU sweep for nothing — is only called when this is false.
        let usingGPUPerPixelMesh = compiledPerPixelMeshVertex != nil
        let meshVerticesFromScript = usingGPUPerPixelMesh ? nil : model.updatePerPixelMesh(
            aspectX: aspectXY.x, aspectY: aspectXY.y,
            pixelWidth: Float(pixelSize.width), pixelHeight: Float(pixelSize.height),
            time: time, fps: beat.lastFPS, frame: frameCounter, energy: energy,
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

        if usingGPUPerPixelMesh, let perPixelMesh = model.perPixelMesh,
           let staticVertexBuffer = transientBuffers.buffer(
               for: perPixelMesh.staticVertices(aspectX: aspectXY.x, aspectY: aspectXY.y), device: device
           )
        {
            // `milkdrop_per_pixel_mesh_vertex`'s buffer layout has one extra slot (`meshUniforms`,
            // buffer(1)) ahead of warpTime/warpScaleInverse/warpFactors/aspect/invAspect compared
            // to the static `feedback_mesh_vertex` — see buildPerPixelMeshVertexSource — so every
            // index below is shifted by +1 relative to the CPU-mesh branches further down.
            var meshUniforms = buildPerPixelMeshUniforms(
                time: time, fps: beat.lastFPS, frame: frameCounter, energy: energy,
                aspectX: aspectXY.x, aspectY: aspectXY.y,
                pixelWidth: Float(pixelSize.width), pixelHeight: Float(pixelSize.height), qVars: qVars,
                zoom: zoom, zoomExp: zoomExponent, rot: rot, warp: warpAmount,
                cx: cx, cy: cy, dx: dx, dy: dy, sx: sx, sy: sy
            )
            if let compiledWarp, let resolvedWarpTextures {
                // compiledWarp.pipelineState already pairs compiledPerPixelMeshVertex as its
                // vertex function (see the compile-gating section above), so this is the same
                // pipeline the CPU-mesh + compiled-warp branch below would use, just fed
                // GPU-computed per-vertex attributes instead of a CPU-built buffer.
                encoder.setRenderPipelineState(compiledWarp.pipelineState)
                encoder.setVertexBuffer(staticVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&meshUniforms, length: MemoryLayout<Float>.stride * meshUniforms.count, index: 1)
                encoder.setVertexBytes(&warpTime, length: MemoryLayout<Float>.stride, index: 2)
                encoder.setVertexBytes(&warpScaleInverse, length: MemoryLayout<Float>.stride, index: 3)
                encoder.setVertexBytes(&warpFactors, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
                encoder.setVertexBytes(&aspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 5)
                encoder.setVertexBytes(&invAspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 6)
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
            } else if let compiledPerPixelMeshOnlyPipeline {
                encoder.setRenderPipelineState(compiledPerPixelMeshOnlyPipeline)
                encoder.setFragmentTexture(sourceTexture, index: 0)
                encoder.setVertexBuffer(staticVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&meshUniforms, length: MemoryLayout<Float>.stride * meshUniforms.count, index: 1)
                encoder.setVertexBytes(&warpTime, length: MemoryLayout<Float>.stride, index: 2)
                encoder.setVertexBytes(&warpScaleInverse, length: MemoryLayout<Float>.stride, index: 3)
                encoder.setVertexBytes(&warpFactors, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
                encoder.setVertexBytes(&aspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 5)
                encoder.setVertexBytes(&invAspectXY, length: MemoryLayout<SIMD2<Float>>.stride, index: 6)
                encoder.setFragmentBytes(&decay, length: MemoryLayout<Float>.stride, index: 0)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: MilkdropPerPixelMeshRuntime.sharedIndices.count,
                    indexType: .uint16, indexBuffer: meshIndexBuffer, indexBufferOffset: 0
                )
            }
        } else if let compiledWarp, let resolvedWarpTextures {
            let meshVertices = meshVerticesFromScript ?? MilkdropPerPixelMeshRuntime.trivialVertices(
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
        // Motion vectors (MotionVectors.cpp) — drawn here, alongside border/darken-center, rather
        // than upstream's own spot (baked into the pre-warp buffer so the trail's own decay fades
        // them like everything else) — a documented simplification, see motionVectorVertices' own
        // doc comment for why. `Self.motionVectorVertices` returns empty immediately when
        // `mv_a < 0.0001` (the vast majority of presets), so this is a no-op call in the common case.
        let motionVectorVerts = Self.motionVectorVertices(
            model.motionVectorParams, warpParams: model.warpParams,
            warpTime: warpTime, warpScaleInverse: warpScaleInverse, warpFactors: warpFactors,
            aspect: aspectXY, invAspect: invAspectXY, pixelSize: pixelSize
        )
        if !motionVectorVerts.isEmpty {
            encoder.setRenderPipelineState(shapeAlphaPipeline)
            drawShape(motionVectorVerts, as: .line, on: encoder, device: device)
        }

        encoder.endEncoding()

        // Blur textures (BlurTexture.cpp) — only regenerated when the compiled composite/warp
        // shader this preset actually uses references one (`GetBlur1-3`/`sampler_blur1-3`), so
        // this is a no-op for the ~99.9% of presets that don't (measured 7/25: 0.1% of corpus).
        // Must run after Pass 1 (destTexture holds this frame's warp/shape/waveform content) and
        // before Pass 1.5 (the composite pass that would actually sample these).
        let usesBlur = (compiledComposite?.textures ?? []).contains { if case .blur = $0.resource { true } else { false } }
            || (compiledWarp?.textures ?? []).contains { if case .blur = $0.resource { true } else { false } }
        if usesBlur {
            updateBlurTextures(source: destTexture, commandBuffer: commandBuffer)
        }

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

        // Presenting `destTexture` to a live drawable (formerly "Pass 2" here) now belongs to
        // MilkdropMetalCoordinator, which owns the actual view and — during a transition — needs
        // to blend this texture with a second renderer's before anything reaches the drawable.
        commandBuffer.commit()

        sourceIndex = 1 - sourceIndex
        return destTexture
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
        let minCount = (primitive == .triangleStrip || primitive == .line) ? 2 : 3
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

    // MARK: - Motion vectors (MotionVectors.cpp — a grid of small arrows showing the warp's flow)

    /// Exact Swift port of Shaders.metal's `feedback_fragment` warp-transform math (through the
    /// aspect-ratio-undo step, before the fragment's own out-of-bounds-color early return) — gives
    /// "which texture-space point did this frame's (u, v) sample its content from in the previous
    /// frame". Real Milkdrop's own `warp_coordinates` texture (see
    /// PresetMotionVectorsVertexShaderGlsl330.vert) holds exactly this same per-pixel value,
    /// pre-rendered once by the fragment shader that draws the warp mesh; Prism has no separate
    /// render target for it (adding one, and a second color attachment to the hot per-frame warp
    /// pass, is a bigger architectural change than this decorative-overlay feature warrants), so
    /// this recomputes the identical closed-form formula directly for just the handful of grid
    /// points motion vectors actually need instead.
    /// **Documented simplification**: this is always the *fixed-formula* warp (whatever
    /// `model.warpParams` currently holds), even for a preset with its own `per_pixel_N=` script or
    /// a compiled `warp_N=` shader — those replace the per-pixel result with something no longer
    /// expressible as one closed formula. The base zoom/rot/warp parameters those still animate
    /// around are exactly what's used here, so the arrows still sweep in a directionally-correct
    /// way for the common case; a script's own point-to-point deviation from that base just isn't
    /// reflected. Motion vectors are a decorative accent (8.2% of the corpus enables them), not a
    /// primary preset element, so this trades a small amount of per-preset exactness for avoiding a
    /// second render target on the hot path.
    private static func reverseWarpedUV(
        u: Float, v: Float, zoom: Float, zoomExponent: Float, rot: Float, warp: Float,
        cx: Float, cy: Float, dx: Float, dy: Float, sx: Float, sy: Float,
        warpTime: Float, warpScaleInverse: Float, warpFactors: SIMD4<Float>,
        aspect: SIMD2<Float>, invAspect: SIMD2<Float>
    ) -> SIMD2<Float> {
        let pos = SIMD2<Float>((u - 0.5) * 2.0, (v - 0.5) * 2.0)

        let zoom2 = powf(zoom, powf(zoomExponent, simd_length(pos) * 2.0 - 1.0))
        let zoom2Inverse = 1.0 / zoom2

        var u2 = pos.x * aspect.x * 0.5 * zoom2Inverse + 0.5
        var v2 = pos.y * aspect.y * 0.5 * zoom2Inverse + 0.5

        u2 = (u2 - cx) / sx + cx
        v2 = (v2 - cy) / sy + cy

        u2 += warp * 0.0035 * sinf(warpTime * 0.333 + warpScaleInverse * (pos.x * warpFactors.x - pos.y * warpFactors.w))
        v2 += warp * 0.0035 * cosf(warpTime * 0.375 - warpScaleInverse * (pos.x * warpFactors.z + pos.y * warpFactors.y))
        u2 += warp * 0.0035 * cosf(warpTime * 0.753 - warpScaleInverse * (pos.x * warpFactors.y - pos.y * warpFactors.z))
        v2 += warp * 0.0035 * sinf(warpTime * 0.825 + warpScaleInverse * (pos.x * warpFactors.x + pos.y * warpFactors.w))

        let ru = u2 - cx
        let rv = v2 - cy
        let cosRot = cosf(rot)
        let sinRot = sinf(rot)
        u2 = ru * cosRot - rv * sinRot + cx
        v2 = ru * sinRot + rv * cosRot + cy

        u2 -= dx
        v2 -= dy

        u2 = (u2 - 0.5) * invAspect.x + 0.5
        v2 = (v2 - 0.5) * invAspect.y + 0.5

        return SIMD2<Float>(u2, v2)
    }

    /// Grid/clamping logic ported line-for-line from MotionVectors.cpp's `Draw` (the +0.25 offsets,
    /// the >64/>48 clamps forcing their diversion term to 0, the 0.0001...0.9999 visibility window)
    /// — real Milkdrop tunes these constants specifically so a line is never exactly on the screen
    /// edge, not arbitrary. Each grid point's line goes from itself to the reverse-warped point (via
    /// `reverseWarpedUV` above), length-clamped exactly as `PresetMotionVectorsVertexShaderGlsl330
    /// .vert` does (`minimum_length`, tuned there so line-smoothing/antialiasing can't shrink a
    /// short vector down to invisible).
    private static func motionVectorVertices(
        _ params: MilkdropMotionVectorParams, warpParams: MilkdropWarpParams,
        warpTime: Float, warpScaleInverse: Float, warpFactors: SIMD4<Float>,
        aspect: SIMD2<Float>, invAspect: SIMD2<Float>, pixelSize: CGSize
    ) -> [ShapeVertex] {
        guard params.a >= 0.0001 else { return [] }

        var countX = Int(params.x)
        var countY = Int(params.y)
        guard countX > 0, countY > 0 else { return [] }

        var divertX = params.x - Float(countX)
        var divertY = params.y - Float(countY)
        if countX > 64 { countX = 64; divertX = 0 }
        if countY > 48 { countY = 48; divertY = 0 }
        divertX = min(1.0, max(0.0, divertX))
        divertY = min(1.0, max(0.0, divertY))
        let divertX2 = params.dx
        let divertY2 = params.dy

        let widthF = Float(pixelSize.width)
        let heightF = Float(pixelSize.height)
        let inverseWidth = widthF > 0 ? 1.25 / widthF : 0
        let inverseHeight = heightF > 0 ? 1.25 / heightF : 0
        let minimumLength = (inverseWidth * inverseWidth + inverseHeight * inverseHeight).squareRoot()

        let color = SIMD4<Float>(params.r, params.g, params.b, params.a)

        func toPixel(_ grid: SIMD2<Float>) -> SIMD2<Float> {
            // Milkdrop's grid space is 0...1, top-down; Prism's shape vertices are -1...1
            // center-origin, y-up (see borderVertices/darkenCenterVertices above) — same
            // `pos*2-1; pos.y = -pos.y` remap PresetMotionVectorsVertexShaderGlsl330.vert applies.
            let ndc = SIMD2<Float>(grid.x * 2.0 - 1.0, -(grid.y * 2.0 - 1.0))
            return SIMD2<Float>(ndc.x * 0.5 * widthF, ndc.y * 0.5 * heightF)
        }

        var verts: [ShapeVertex] = []
        verts.reserveCapacity((countX + 1) * 2)
        for y in 0..<countY {
            let posY = (Float(y) + 0.25) / (Float(countY) + divertY + 0.25 - 1.0) - divertY2
            guard posY > 0.0001, posY < 0.9999 else { continue }

            for x in 0..<countX {
                let posX = (Float(x) + 0.25) / (Float(countX) + divertX + 0.25 - 1.0) + divertX2
                guard posX > 0.0001, posX < 0.9999 else { continue }

                let start = SIMD2<Float>(posX, posY)
                let oldUV = reverseWarpedUV(
                    u: posX, v: 1.0 - posY,
                    zoom: warpParams.zoom, zoomExponent: warpParams.zoomExponent, rot: warpParams.rot,
                    warp: warpParams.warpAmount, cx: warpParams.rotCX, cy: warpParams.rotCY,
                    dx: warpParams.xPush, dy: warpParams.yPush, sx: warpParams.stretchX, sy: warpParams.stretchY,
                    warpTime: warpTime, warpScaleInverse: warpScaleInverse, warpFactors: warpFactors,
                    aspect: aspect, invAspect: invAspect
                )

                var dist = (oldUV - start) * params.length
                let len = simd_length(dist)
                if len > minimumLength {
                    // Keep dist as-is.
                } else if len > 0.00000001 {
                    dist *= minimumLength / len
                } else {
                    dist = SIMD2<Float>(minimumLength, minimumLength)
                }

                verts.append(ShapeVertex(position: toPixel(start), color: color))
                verts.append(ShapeVertex(position: toPixel(start + dist), color: color))
            }
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
