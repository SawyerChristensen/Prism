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
}
