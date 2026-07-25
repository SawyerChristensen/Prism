//
//  MilkdropShaderTranslatorTests.swift
//  PrismTests
//
//  Coverage for MilkdropShaderTranslator against both synthetic minimal cases and real shader
//  bodies pulled verbatim from a 9,795-preset corpus survey (see MilkdropShaderTranslator.swift's
//  header) — the nested-tex2D-argument and undeclared-sampler_main cases in particular were only
//  found by testing against real files, not by guessing at the format from documentation.
//

import Testing
@testable import Prism

struct MilkdropShaderTranslatorTests {

    @Test func emptySourceReturnsNil() {
        #expect(MilkdropShaderTranslator.translate("") == nil)
    }

    @Test func missingShaderBodyMarkerReturnsNil() {
        // Real Milkdrop throws on this; this port just fails translation instead.
        #expect(MilkdropShaderTranslator.translate("ret = tex2D(sampler_main, uv).xyz;") == nil)
    }

    @Test func minimalSupportedShaderTranslates() throws {
        let source = """
        shader_body
        {
            ret = tex2D(sampler_main, uv).xyz;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv)"))
        #expect(result.textures.count == 1)
        #expect(result.textures[0].declaredName == "sampler_main")
        #expect(result.textures[0].resource == .main)
        #expect(result.textures[0].isVolume == false)
    }

    @Test func nestedParenArgumentSplitsCorrectly() throws {
        // Verbatim (trimmed) from a real preset in the survey corpus — the UV argument is itself a
        // float2(...) call, which a naive single-level comma split would misparse.
        let source = """
        shader_body
        {
            float2 ruv = uv;
            ret = tex2D(sampler_fc_main, float2(ruv.x, ruv.y)).xyz;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("sampler_fc_main.sample(sampler_fc_main_smp, float2(ruv.x, ruv.y))"))
        #expect(result.textures.map(\.declaredName) == ["sampler_fc_main"])
        // fc_ prefix -> linear + clamp-to-edge (TextureManager.cpp:371-376).
        #expect(result.textures[0].filter == .linear)
        #expect(result.textures[0].wrap == .clampToEdge)
    }

    @Test func undeclaredSamplerMainStillDiscoveredFromCallSite() throws {
        // Real presets frequently never declare `sampler sampler_main;` at all — confirmed
        // verbatim: a preset that only declares `sampler_fw_noisevol_hq` but also calls
        // tex2D(sampler_fc_main, ...) and tex2D(sampler_noise_lq, ...) with no declaration for
        // either. Discovery must come from call sites, not `sampler NAME;` lines.
        let source = """
        sampler sampler_fw_noisevol_hq;
        shader_body
        {
            float3 rc = tex3D(sampler_fw_noisevol_hq, pos);
            ret = tex2D(sampler_fc_main, uv).xyz;
            ret += tex2D(sampler_noise_lq, uv_orig).xyz;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        let names = Set(result.textures.map(\.declaredName))
        #expect(names == ["sampler_fw_noisevol_hq", "sampler_fc_main", "sampler_noise_lq"])
        let volumeTexture = try #require(result.textures.first { $0.declaredName == "sampler_fw_noisevol_hq" })
        #expect(volumeTexture.isVolume == true)
        #expect(volumeTexture.resource == .noise("noisevol_hq"))
        #expect(volumeTexture.filter == .linear) // fw_ -> linear + repeat
        #expect(volumeTexture.wrap == .repeatWrap)
    }

    @Test func unrecognizedCustomSamplerFailsTranslation() {
        // "clouds" isn't main or a standard noise texture — verbatim pattern from a real preset
        // (`sampler_fw_clouds`) that this port intentionally doesn't support (see this file's
        // header: the survey found custom `image=`-style textures essentially unused in practice,
        // 0/9,795, so this is a deliberate scope cut, not an oversight).
        let source = """
        sampler sampler_fw_clouds;
        shader_body
        {
            ret = tex2D(sampler_fw_clouds, uv).xyz;
        }
        """
        #expect(MilkdropShaderTranslator.translate(source) == nil)
    }

    @Test func blurHelperFunctionIsNotATextureCallAndDoesntBlockTranslationByItself() {
        // GetBlur1(uv) isn't a tex2D/tex3D call at all, so texture discovery doesn't see it or
        // reject it — but Prism has no GetBlur1 implementation, so a shader using it will fail to
        // *compile* later (MilkdropMetalRenderer.swift), not fail translation here. This test
        // documents that boundary rather than asserting a specific outcome for GetBlur1 itself.
        let source = """
        shader_body
        {
            ret = tex2D(sampler_main, uv).xyz - GetBlur1(uv);
        }
        """
        let result = MilkdropShaderTranslator.translate(source)
        #expect(result != nil)
        #expect(result?.body.contains("GetBlur1(uv)") == true)
    }

    @Test func realCompositeShaderFromCorpusTranslates() throws {
        // Verbatim (backtick-stripped) comp_ shader from a real preset in the survey corpus —
        // "Stahlregen & Geiss + Illusion + Krash + Rovastar - Crystal Brain Elderly_3 - effluvia":
        // a 4-tap max-downsample of sampler_main, never declared explicitly.
        let source = """
        shader_body
        {
            uv *= 0.5;
            ret = tex2D(sampler_main, uv).xyz;
            ret = max(ret, tex2D(sampler_main,uv + float2(0.5,0)).xyz);
            ret = max(ret, tex2D(sampler_main,uv + float2(0,0.5)).xyz);
            ret = max(ret, tex2D(sampler_main,uv + float2(0.5,0.5)).xyz);
            ret *= 1.666;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.textures.map(\.declaredName) == ["sampler_main"])
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv + float2(0.5,0))"))
    }

    @Test func qualifierPrefixesResolveFilterAndWrap() throws {
        let cases: [(String, MilkdropShaderTranslator.TextureBinding.Filter, MilkdropShaderTranslator.TextureBinding.Wrap)] = [
            ("sampler_pw_noise_lq", .nearest, .repeatWrap),
            ("sampler_pc_noise_lq", .nearest, .clampToEdge),
            ("sampler_fw_noise_hq", .linear, .repeatWrap),
            ("sampler_fc_noise_hq", .linear, .clampToEdge),
            ("sampler_noise_mq", .linear, .repeatWrap), // No qualifier -> default.
        ]
        for (name, expectedFilter, expectedWrap) in cases {
            let source = "shader_body\n{\nret = tex2D(\(name), uv).xyz;\n}"
            let result = try #require(MilkdropShaderTranslator.translate(source), "Expected \(name) to translate")
            #expect(result.textures[0].filter == expectedFilter, "\(name) filter")
            #expect(result.textures[0].wrap == expectedWrap, "\(name) wrap")
        }
    }

    @Test func samplerStateBlockIsStripped() throws {
        let source = """
        sampler_state
        {
            Texture = <sampler_main>;
        };
        shader_body
        {
            ret = tex2D(sampler_main, uv).xyz;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(!result.body.contains("sampler_state"))
    }

    @Test func intrinsicsAreRenamedToAvoidRedefinitionRisk() throws {
        let source = """
        shader_body
        {
            static const float k = 1.0;
            float3 a = frac(uv.x);
            float3 b = lerp(a, a, 0.5);
            float3 c = saturate(b);
            float2 d = mul(float2x2(1,0,0,1), uv);
            ret = a + b + c + float3(d, 0) + k;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("fract(uv.x)"))
        #expect(result.body.contains("milkdrop_lerp(a, a, 0.5)"))
        #expect(result.body.contains("milkdrop_saturate(b)"))
        #expect(result.body.contains("milkdrop_mul(float2x2(1,0,0,1), uv)"))
        #expect(result.body.contains("const float k"))
        #expect(!result.body.contains("static"))
    }
}
