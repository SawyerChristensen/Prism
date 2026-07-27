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

    @Test func unrecognizedCustomSamplerResolvesToACustomResourceInsteadOfFailing() throws {
        // "clouds" isn't main or a standard noise texture — verbatim pattern from a real preset
        // (`sampler_fw_clouds`). Used to fail translation outright; now resolves to `.custom`,
        // looked up against a preset pack's own Textures/ folder at draw time instead (see
        // MilkdropCustomTextureManager.swift) — a preset pack missing this one file shouldn't lose
        // the shader's other effects too.
        let source = """
        sampler sampler_fw_clouds;
        shader_body
        {
            ret = tex2D(sampler_fw_clouds, uv).xyz;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.textures.map(\.declaredName) == ["sampler_fw_clouds"])
        #expect(result.textures[0].resource == .custom("clouds"))
        #expect(result.textures[0].filter == .linear) // fw_ -> linear + repeat
        #expect(result.textures[0].wrap == .repeatWrap)
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

    // MARK: - Fixes from the 7/25 corpus-scale warp-shader compile measurement (10.5% -> much
    // higher pass rate; see TO DO.md's "Compile & run warp_N= HLSL shaders" entry for the numbers)

    @Test func implicitFloat4ToFloat3NarrowingGetsAnExplicitSwizzle() throws {
        // HLSL implicitly truncates tex2D's float4 return when assigning into a float3 lvalue;
        // MSL has no such implicit narrowing conversion. Both real shapes seen in the corpus.
        let source = """
        shader_body
        {
            float3 pre = tex2D(sampler_main, uv);
            ret = tex2D(sampler_main, uv_orig);
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv).xyz"))
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv_orig).xyz"))
    }

    @Test func explicitSwizzleAfterTexCallIsNotDoubled() throws {
        // `tex2D(sampler, uv).a` already explicitly swizzles — appending `.xyz` on top would break
        // it (`.xyz` has no `.a` component), so the fix above must not touch this shape at all.
        let source = """
        shader_body
        {
            ret.x = tex2D(sampler_main, uv).a;
            ret.y = tex2D(sampler_main, uv).rgb.r;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv).a"))
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv).rgb.r"))
        #expect(!result.body.contains(".xyz"))
    }

    // MARK: - Fix from the 7/26 full-corpus compile scan (the single biggest cause measured that
    // day, ~2,554+ instances): the auto-appended swizzle above used to *always* assume float3
    // (matching the common `ret = tex2D(...)` shape), but a texture call that's the entire
    // initializer of a `<type> name = ...;` declaration needs a swizzle matching *that* declared
    // width — a real corpus preset's `float4 noise9 = tex3D(sampler_noisevol_hq, ...);` wanted the
    // full float4 (no swizzle at all), but got force-narrowed to float3 by the old blind default,
    // turning a valid declaration into a width mismatch Prism's own translator introduced.

    @Test func declaredFloat4InitializerGetsNoSwizzleAtAll() throws {
        let source = "shader_body\n{\nfloat4 noise9 = tex3D(sampler_noisevol_hq, pos);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("sampler_noisevol_hq.sample(sampler_noisevol_hq_smp, pos);"))
        #expect(!result.body.contains(".xyz"))
    }

    @Test func declaredFloat2InitializerGetsXYSwizzle() throws {
        let source = "shader_body\n{\nfloat2 uv2 = tex2D(sampler_main, uv);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv).xy;"))
    }

    @Test func declaredScalarFloatInitializerGetsXSwizzle() throws {
        let source = "shader_body\n{\nfloat x = tex2D(sampler_main, uv);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv).x;"))
    }

    @Test func plainAssignmentToAlreadyDeclaredVariableStillDefaultsToFloat3() throws {
        // No type keyword immediately precedes `name =` here (it's a bare reassignment, not a
        // declaration) — `declaredAssignmentWidth` can't know `existing`'s real type without a
        // full symbol table, so this deliberately falls back to the original float3 default,
        // matching the common `ret = tex2D(...)` case this whole mechanism was first built for.
        let source = "shader_body\n{\nexisting = tex2D(sampler_main, uv);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv).xyz;"))
    }

    // "function definition is not allowed here" (2nd-largest cause in the 7/26 corpus scan, 483x):
    // real presets sometimes declare complete helper functions before `shader_body`, not just plain
    // variables — confirmed verbatim against "propre hypno.milk"'s comp_N=, which defines
    // `uv_polar`/`uv_lens_half_sphere` above `shader_body` and calls them from inside it.
    // `extractHelperFunctions` pulls these out and `Result.helperFunctions` carries them separately
    // so the caller can paste them at true top-level MSL scope instead of nesting a function
    // definition inside another function (illegal in MSL, same as C).

    @Test func helperFunctionBeforeShaderBodyIsHoistedOutOfTheBody() throws {
        let source = """
        float2 uv_polar(float2 domain, float2 center){
           float2 c = domain - center;
           return float2(atan2(c.x,c.y), length(c));
        }

        shader_body
        {
            ret = float3(uv_polar(uv, float2(0.5,0.5)), 0.0);
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.helperFunctions.contains("float2 uv_polar(float2 domain, float2 center){"))
        #expect(!result.body.contains("float2 uv_polar"))
        #expect(result.body.contains("uv_polar(uv, float2(0.5,0.5))"))
    }

    @Test func laterHelperFunctionCallingAnEarlierOneKeepsSourceOrder() throws {
        // `uv_lens_half_sphere` calls `uv_polar`, defined just above it in the real preset — MSL
        // (like C) requires a function be declared before its first use, so hoisting must preserve
        // the original source order, not e.g. reverse or alphabetize it.
        let source = """
        float2 uv_polar(float2 domain, float2 center){
           return domain - center;
        }

        float2 uv_lens_half_sphere(float2 domain, float2 position){
           return uv_polar(domain, position) * 2.0;
        }

        shader_body
        {
            ret = float3(uv_lens_half_sphere(uv, float2(0.5,0.5)), 0.0);
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        let polarRange = try #require(result.helperFunctions.firstRange(of: "float2 uv_polar"))
        let lensRange = try #require(result.helperFunctions.firstRange(of: "float2 uv_lens_half_sphere"))
        #expect(polarRange.lowerBound < lensRange.lowerBound)
    }

    @Test func plainDeclarationsBeforeAndAfterAHelperFunctionAreStillHoistedIntoTheBody() throws {
        // Real shape (e.g. "propre hypno.milk"): plain scratch-variable declarations, then one or
        // more helper functions, all before `shader_body`. `preambleDeclarations`'s semicolon-split
        // logic must only ever see what's left *after* `extractHelperFunctions` removes the function
        // text — otherwise it would shred the function body's own statement-terminating `;`s.
        let source = """
        float3 ret1, neu;
        float k, m;

        float2 helper(float2 x){
            return x * 2.0;
        }

        shader_body
        {
            ret1 = float3(helper(uv), 0.0);
            ret = ret1;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.helperFunctions.contains("float2 helper(float2 x){"))
        #expect(result.body.contains("float3 ret1, neu;"))
        #expect(result.body.contains("float k, m;"))
        #expect(!result.body.contains("float2 helper(float2 x){"))
    }

    @Test func shaderWithNoHelperFunctionsHasAnEmptyHelperFunctionsString() throws {
        let source = "shader_body\n{\nret = float3(1.0);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(!result.helperFunctions.contains(where: { !$0.isWhitespace }))
    }

    @Test func singleArgumentFloat2x2ConstructorIsRewrittenToTwoColumnForm() throws {
        // Real HLSL supports `float2x2(v)` from a single float4 (row-major packing) — MSL's own
        // float2x2 constructor has no equivalent single-vector overload, so this rewrites the call
        // site to the two-column form MSL does support. Confirmed as a real, common pattern: 397
        // real corpus presets build a rotation matrix straight from a `_qa`/`_qb` q-var bank this
        // way (e.g. `mul(uv, float2x2(_qa))`).
        let source = "shader_body\n{\nuv = mul(uv, float2x2(_qa));\nret = float3(uv, 0.0);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("float2x2((_qa).xy, (_qa).zw)"))
        // A genuine 4-scalar-argument float2x2(...) call must be left alone.
        let scalarSource = "shader_body\n{\nfloat2x2 m = float2x2(1,0,0,1);\nret = float3(mul(uv,m), 0.0);\n}"
        let scalarResult = try #require(MilkdropShaderTranslator.translate(scalarSource))
        #expect(scalarResult.body.contains("float2x2(1,0,0,1)"))
    }

    @Test func doubleTypesAreAliasedToFloatEquivalents() throws {
        // Real Cg/HLSL treats `double`/`double2`-`double4` as plain aliases for `float`/`floatN`
        // on profiles without true double-precision support (which Milkdrop's own shader profiles
        // never had) — confirmed as a real pattern via a white-screen preset report
        // ("suksma - schlotkin(k).milk"'s warp_, `double3 ist = GetBlur1(uv*1);`). MSL's own
        // `double` is a reserved-but-unimplemented keyword ("incomplete type" at compile), so
        // leaving it as-is would fail outright.
        let source = "shader_body\n{\ndouble3 ist = GetBlur1(uv);\ndouble d = 1.0;\nret = ist*float(d);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.body.contains("float3 ist"))
        #expect(result.body.contains("float d = 1.0;"))
        #expect(!result.body.contains("double"))
    }

    @Test func lowercaseTex2dAndTex3dAreRecognized() throws {
        // Confirmed against real corpus presets that use lowercase `tex2d`/`tex3d` — a small
        // fraction of compile failures (6/1384 in the 7/25 measurement), but a free fix once
        // `matchFunctionCall` compares case-insensitively.
        let source = """
        shader_body
        {
            ret = tex2d(sampler_main, uv).xyz;
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.textures.map(\.declaredName) == ["sampler_main"])
        #expect(result.body.contains("sampler_main.sample(sampler_main_smp, uv)"))
    }

    @Test func getPixelAndGetBlurAreDiscoveredAsImplicitTexturesAndRewrittenAtTheCallSite() throws {
        // GetPixel/GetBlur1/GetBlur2/GetBlur3 are real Milkdrop shader helper *functions*, not
        // tex2D/tex3D calls — measured 7/25 as the single largest cause of warp-shader compile
        // failures (1016/1384, 73%) before this existed. Rewritten at the call site exactly like
        // tex2D (NOT left as-is with a separately-declared MSL helper function referencing a
        // "global" texture — MSL texture/sampler bindings are function *parameters*, not globals,
        // so a standalone GetBlur1 function has no way to reach a texture bound to a completely
        // different function's parameter list; confirmed by an actual compile failure — "use of
        // undeclared identifier" inside the separate helper — before switching to this approach).
        let source = """
        shader_body
        {
            ret = GetPixel(uv) - GetBlur1(uv) + GetBlur3(uv_orig);
        }
        """
        let result = try #require(MilkdropShaderTranslator.translate(source))
        let names = Set(result.textures.map(\.declaredName))
        #expect(names.contains(MilkdropShaderTranslator.getPixelTextureName))
        #expect(names.contains(MilkdropShaderTranslator.getBlurTextureName(1)))
        #expect(names.contains(MilkdropShaderTranslator.getBlurTextureName(3)))
        #expect(!names.contains(MilkdropShaderTranslator.getBlurTextureName(2))) // Not referenced.
        let pixelName = MilkdropShaderTranslator.getPixelTextureName
        let blur1Name = MilkdropShaderTranslator.getBlurTextureName(1)
        let blur3Name = MilkdropShaderTranslator.getBlurTextureName(3)
        #expect(result.body.contains("\(pixelName).sample(\(pixelName)_smp, uv).xyz"))
        #expect(result.body.contains("\(blur1Name).sample(\(blur1Name)_smp, uv).xyz"))
        #expect(result.body.contains("\(blur3Name).sample(\(blur3Name)_smp, uv_orig).xyz"))
        #expect(!result.body.contains("GetPixel(")) // No trace of the original call left.
    }

    @Test func nestedTextureCallInsideAnotherCallsArgumentsIsDiscoveredAndRewritten() throws {
        // Real corpus pattern (e.g. "suksma - bonnie self.milk"'s comp_): a texture call used as
        // *another* texture call's coordinate argument, `tex2D(sampler_main, GetBlur1(uv))`.
        // `scanTextureCalls` only ever reports the outermost call starting at a given position, so
        // without recursing into each call's own arguments, the nested `GetBlur1(uv)` was silently
        // left as untranslated HLSL — both undiscovered as a needed texture binding and never
        // rewritten to MSL's `.sample(...)` form (16x/13x "undeclared identifier 'GetBlur1'/
        // 'GetPixel'" in the 7/26 corpus scan, both nested this way, not genuinely unrecognized).
        let source = "shader_body\n{\nfloat3 blur = tex2D(sampler_main, GetBlur1(uv)).xyz;\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        let blur1Name = MilkdropShaderTranslator.getBlurTextureName(1)
        #expect(result.textures.map(\.declaredName).contains(blur1Name))
        #expect(result.textures.map(\.declaredName).contains("sampler_main"))
        #expect(!result.body.contains("GetBlur1(")) // No trace of the original nested call left.
        // The nested call is itself a UV *coordinate*, not a `<type> name = ...` initializer, so it
        // must default to a float2 (`.xy`) swizzle, not the top-level float3 (`.xyz`) default —
        // `sampler_main.sample` expects a `float2` coordinate argument.
        #expect(result.body.contains("\(blur1Name).sample(\(blur1Name)_smp, uv).xy)"))
    }

    @Test func getBlurResolvesToMainTextureAsADocumentedApproximation() throws {
        let source = "shader_body\n{\nret = GetBlur2(uv);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        let binding = try #require(result.textures.first { $0.declaredName == MilkdropShaderTranslator.getBlurTextureName(2) })
        #expect(binding.resource == .blur(2))
    }

    @Test func getMainIsTreatedIdenticallyToGetPixel() throws {
        // Confirmed against projectM's PresetShaderHeaderGlsl330.inc: both are literally the same
        // `#define` (`tex2D(sampler_main,uv).xyz`) upstream, so they should share one texture
        // binding rather than requesting two identical ones under different names.
        let source = "shader_body\n{\nret = GetMain(uv) + GetPixel(uv);\n}"
        let result = try #require(MilkdropShaderTranslator.translate(source))
        #expect(result.textures.map(\.declaredName) == [MilkdropShaderTranslator.getPixelTextureName])
        let name = MilkdropShaderTranslator.getPixelTextureName
        #expect(result.body.contains("\(name).sample(\(name)_smp, uv).xyz + \(name).sample(\(name)_smp, uv).xyz"))
    }
}
