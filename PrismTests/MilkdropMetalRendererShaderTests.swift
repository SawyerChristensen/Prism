//
//  MilkdropMetalRendererShaderTests.swift
//  PrismTests
//
//  Compiles MilkdropMetalRenderer.buildCompositeShaderSource's output through a real MTLDevice —
//  MilkdropShaderTranslatorTests only verifies the Swift-level string transformation, not that the
//  result is actually valid MSL. This is the test that would have caught a typo in the shim header
//  or a malformed generated function signature before it ever reached a running preset load.
//

import Metal
import Testing
@testable import Prism

struct MilkdropMetalRendererShaderTests {

    private func compiledLibrary(for hlsl: String) throws -> MTLLibrary {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device available in this test environment")
        let translated = try #require(MilkdropShaderTranslator.translate(hlsl))
        let mslSource = MilkdropMetalRenderer.buildCompositeShaderSource(translated)
        return try device.makeLibrary(source: mslSource, options: nil)
    }

    @Test func minimalSamplerMainShaderCompiles() throws {
        let library = try compiledLibrary(for: """
        shader_body
        {
            ret = tex2D(sampler_main, uv).xyz;
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func realCorpusCompositeShaderCompiles() throws {
        // Verbatim (backtick-stripped) comp_ shader from a real preset in the survey corpus — see
        // MilkdropShaderTranslatorTests.realCompositeShaderFromCorpusTranslates for provenance.
        let library = try compiledLibrary(for: """
        shader_body
        {
            uv *= 0.5;
            ret = tex2D(sampler_main, uv).xyz;
            ret = max(ret, tex2D(sampler_main,uv + float2(0.5,0)).xyz);
            ret = max(ret, tex2D(sampler_main,uv + float2(0,0.5)).xyz);
            ret = max(ret, tex2D(sampler_main,uv + float2(0.5,0.5)).xyz);
            ret *= 1.666;
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func noiseTextureShaderCompilesWithTexture3DParameter() throws {
        let library = try compiledLibrary(for: """
        shader_body
        {
            float3 n = tex3D(sampler_noisevol_hq, float3(uv, time)).xyz;
            ret = tex2D(sampler_main, uv).xyz * n;
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func shaderUsingIntrinsicsAndAudioUniformsCompiles() throws {
        // Exercises the frac/lerp/saturate/mul shims and the #define'd scalar uniforms together —
        // the combination most likely to reveal a mismatch between the shim header and generated
        // #define block if either drifted.
        let library = try compiledLibrary(for: """
        shader_body
        {
            float3 a = tex2D(sampler_main, uv).xyz;
            float3 b = milkdrop_saturate(a * bass);
            float3 c = frac(a + time * 0.1);
            ret = lerp(b, c, treb) * mul(float2x2(1,0,0,1), uv).x;
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func mulAcceptsBothMatrixFirstAndVectorFirstArgumentOrder() throws {
        // Real HLSL's `mul(a,b)` intrinsic overloads on argument *order*: `mul(matrix, vector)` is
        // the usual M*v, but `mul(vector, matrix)` does row-vector v*M instead — confirmed against a
        // real corpus preset ("suksma - bonnie self.milk"'s comp_, `mul(uv-0.5,rot)`) that calls it
        // vector-first. 171x "no matching function for call to 'milkdrop_mul'" in the 7/26 corpus
        // scan before the vector-first overloads existed.
        let library = try compiledLibrary(for: """
        shader_body
        {
            float2x2 rot = { 1, 0, 0, 1 };
            float2 a = mul(rot, uv);
            float2 b = mul(uv, rot);
            ret = float3(a + b, 0.0);
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func mPiConstantsAndQBankAliasesCompile() throws {
        // M_PI/M_PI_2/M_INV_PI_2 (268x "undeclared identifier 'M_INV_PI_2'" in the 7/26 scan) and
        // the raw `_qa`-`_qh` float4 banks `q1`-`q32` individually alias into (a real corpus preset,
        // "propre hypno.milk", uses `_qa` directly as a whole: `mul(uv,float2x2(_qa))`).
        let library = try compiledLibrary(for: """
        shader_body
        {
            float a = M_PI * M_PI_2 * M_INV_PI_2;
            float2 b = mul(uv, float2x2(_qa)) * a;
            ret = float3(b + _qh.xy, q32);
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func hueShaderCompilesAndUsesRandPresetAndTime() throws {
        // Real Milkdrop's per-vertex "hue shader" grid overlay (confirmed against projectM's
        // FinalComposite::ApplyHueShaderColors) — 95-110x "undeclared identifier 'hue_shader'" in
        // 1,500-file corpus samples before this existed, the single largest remaining named gap
        // after the 7/26 corpus scan's original priority list was addressed.
        let library = try compiledLibrary(for: """
        shader_body
        {
            ret = pow(tex2D(sampler_main, uv).xyz, hue_shader);
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func volAndVolAttCompileAsOverallAudioLevelUniforms() throws {
        // `vol`/`vol_att` (`_c3.w`/`_c4.w` in projectM's PresetShaderHeaderGlsl330.inc, real formula
        // confirmed against projectM's PCM.cpp: `vol = (bass+mid+treb)*0.333`) — 52x "undeclared
        // identifier 'vol'" in the 7/26 corpus scan.
        let library = try compiledLibrary(for: """
        shader_body
        {
            float dec = milkdrop_saturate(vol / vol_att - 1.1) * 0.5 + 0.004;
            ret = float3(dec);
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func float2x2FromASingleVectorArgumentCompiles() throws {
        // Real HLSL supports constructing a matrix from a single vector, packing its components
        // row-major (`float2x2(_qa)`) — MSL's own float2x2 constructor has no equivalent
        // single-vector overload. Confirmed as a real, common pattern: 397 real corpus presets
        // build a rotation matrix straight from a `_qa`/`_qb` q-var bank this way (e.g.
        // "martin - neon space ps2 (ati fix).milk"'s comp_, `mul(uv, float2x2(_qb))`).
        let library = try compiledLibrary(for: """
        shader_body
        {
            uv = mul(uv, float2x2(_qa));
            ret = float3(uv, 0.0);
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    @Test func noiseTexsizeDefinesCompileEvenWithoutATextureCallSiteForThem() throws {
        // Real corpus pattern ("LuxXx - All That I Am.milk"'s warp_): a preset reads
        // `texsize_noise_lq` for a pure size calculation without ever sampling `sampler_noise_lq` in
        // that same shader, so `discoverTextures` (which only walks tex2D/tex3D call sites) never
        // learns the shader needs it — 257x "undeclared identifier 'texsize_noise_lq'" in the 7/26
        // scan. All five noise catalog entries must compile unconditionally.
        let library = try compiledLibrary(for: """
        shader_body
        {
            float2 corr = texsize.xy * texsize_noise_lq.zw * texsize_noise_mq.zw * texsize_noise_hq.zw
                * texsize_noisevol_lq.zw * texsize_noisevol_hq.zw;
            ret = tex2D(sampler_main, uv + corr).xyz;
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_composite_main") != nil)
    }

    // MARK: - warp_N= (buildWarpShaderSource — see MilkdropPerPixelMeshRuntime.trivialVertices'
    // doc comment on why a warp shader always draws via the mesh path, hence MeshVertexOut here
    // rather than FullscreenVertexOut)

    private func compiledWarpLibrary(for hlsl: String) throws -> MTLLibrary {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device available in this test environment")
        let translated = try #require(MilkdropShaderTranslator.translate(hlsl))
        let mslSource = MilkdropMetalRenderer.buildWarpShaderSource(translated)
        return try device.makeLibrary(source: mslSource, options: nil)
    }

    @Test func minimalWarpShaderCompiles() throws {
        let library = try compiledWarpLibrary(for: """
        shader_body
        {
            ret = tex2D(sampler_main, uv).xyz;
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_warp_main") != nil)
    }

    @Test func realCorpusWarpShaderCompiles() throws {
        // Verbatim (backtick-stripped) warp_ shader from RealPreset1_ORBEtherealPlain.milk (see
        // PrismTests/Fixtures/) — reads both `uv` (already-warped) and samples sampler_fc_main/
        // sampler_noisevol_lq, exercising the uv/uv_orig distinction this wrapper (unlike the
        // composite one) actually has to get right.
        let library = try compiledWarpLibrary(for: """
        shader_body
        {
           float d = texsize.zw*8;
           float3 deltax = (tex2D(sampler_main, uv + float2(1,0)*d) + tex2D(sampler_main, uv + float2(1,0)*d))*0.5;
           float3 deltay = (tex2D(sampler_main, uv + float2(0,1)*d) + tex2D(sampler_main, uv + float2(0,1)*d))*0.5;
           float3 txr = float3(uv,q2);

           float delta = ((deltax+deltay * tex2D(sampler_main, uv + deltax+deltay))).xy - tex3D(sampler_noisevol_lq, txr*4);
           ret = tex2D(sampler_fc_main, (uv-0.5)*(1 - delta*0.01)*(0.99 - bass*0.001) + float2(0,delta*texsize.z) + 0.5 );
           ret = ret -0.002;
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_warp_main") != nil)
    }

    @Test func warpShaderDistinguishesUvFromUvOrig() throws {
        // The one behavior that's genuinely different from the composite wrapper: `uv` and
        // `uv_orig` must resolve to different struct members (in.uv vs in.uvOrig), not both alias
        // the same value the way the composite wrapper's `uv == uv_orig` intentionally does.
        let translated = try #require(MilkdropShaderTranslator.translate("""
        shader_body
        {
            ret = tex2D(sampler_main, uv_orig).xyz - tex2D(sampler_main, uv).xyz;
        }
        """))
        let source = MilkdropMetalRenderer.buildWarpShaderSource(translated)
        #expect(source.contains("uv_orig = in.uvOrig"))
        #expect(source.contains("uv = in.uv"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: source, options: nil)
        #expect(library.makeFunction(name: "milkdrop_warp_main") != nil)
    }

    @Test func getBlurGetPixelLumAndRoamCompileTogether() throws {
        // Real shape (trimmed) of a pattern found repeatedly in the 7/25 corpus compile
        // measurement — GetPixel/GetBlurN as call-site-rewritten textures, lum() as a pure-math
        // macro, and roam_cos as one of the newly-added drifting-uniform quadruplets, all in one
        // shader (the combination most likely to reveal an interaction bug between the three).
        let library = try compiledWarpLibrary(for: """
        shader_body
        {
            float3 dx = GetBlur1(uv + float2(1,0)*texsize.zw) - GetBlur1(uv - float2(1,0)*texsize.zw);
            float magic = lum(GetPixel(uv)) - lum(GetBlur2(uv));
            ret = GetMain(uv) * (0.5 + 0.5 * roam_cos.x) + dx * magic;
        }
        """)
        #expect(library.makeFunction(name: "milkdrop_warp_main") != nil)
    }

    @Test func oldStyleFinalCompositeShaderCompiles() throws {
        // Unlike the composite/warp shaders above (dynamically generated per preset from
        // translated HLSL), milkdrop_old_style_final_composite is a fixed function baked directly
        // into Shaders.metal — compiled here straight from the real file's own source (via
        // #filePath, a repo-relative path that works on any checkout, not `makeDefaultLibrary()`,
        // which loads the *calling bundle's* compiled metallib and isn't guaranteed to see the app
        // target's from inside the test target) so this catches an actual MSL syntax error in that
        // function the same way the dynamic-shader tests above do for the generated ones.
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device available in this test environment")
        let shadersURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PrismTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Prism/Milkdrop/Shaders.metal")
        let source = try String(contentsOf: shadersURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        #expect(library.makeFunction(name: "milkdrop_old_style_final_composite") != nil)
    }
}
