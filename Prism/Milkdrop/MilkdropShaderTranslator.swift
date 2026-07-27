//
//  MilkdropShaderTranslator.swift
//  Prism
//
//  Translates a preset's `warp_N=`/`comp_N=` HLSL shader source (see MilkdropPresetFile.swift) into
//  a Metal Shading Language function body, by targeted text substitution rather than a full HLSL
//  grammar parser — MSL and HLSL are both C-family languages with matching types (`float4` etc.)
//  and control flow (`for`/`while` need no translation at all), so the real work is a handful of
//  mechanical rewrites, not a compiler. This is a from-scratch Swift implementation; projectM's own
//  approach (vendoring a full HLSL->GLSL grammar transpiler, ~7,200 lines) was judged disproportionate
//  after surveying a real 9,795-preset corpus: syntax compatibility between HLSL and MSL is high, so
//  string surgery covers the vast majority of what projectM needs a full parser for.
//
//  Ported algorithm, confirmed against projectM's MilkdropShader.cpp and real preset samples from
//  the survey corpus:
//   - Textures are discovered from `tex2D(NAME, uv)`/`tex3D(NAME, uv)` **call sites**, not `sampler
//     NAME;` declarations — real presets routinely use `sampler_main`/`sampler_fc_main` and the
//     standard noise textures with no declaration at all (confirmed verbatim in corpus samples: a
//     shader declaring only `sampler_fw_noisevol_hq` still calls `tex2D(sampler_fc_main, ...)` and
//     `tex2D(sampler_noise_lq, ...)` undeclared). A declaration only matters for names this scan
//     wouldn't otherwise see used — which in practice means it never adds new information here, so
//     it isn't parsed at all; call-site discovery is both simpler and matches real files better.
//   - Every texture identifier is prefixed `sampler_` by convention; what follows classifies
//     filter/wrap AND the base texture: a 2-letter+underscore qualifier (`fc_`/`cf_` = linear+clamp,
//     `fw_`/`wf_` = linear+repeat, `pc_`/`cp_` = nearest+clamp, `pw_`/`wp_` = nearest+repeat) is
//     stripped to get the base name; no qualifier defaults to linear+repeat (confirmed against
//     TextureManager::ExtractTextureSettings, TextureManager.cpp:355-401). Base name "main" is the
//     feedback/previous-frame texture (a special case in real Milkdrop too — TextureManager.cpp:76);
//     the standard noise-texture base names (MilkdropNoiseTextures.swift) are resolved here too;
//     anything else becomes `.custom(baseName)`, resolved at draw time against a preset pack's own
//     `Textures/` folder (MilkdropCustomTextureManager.swift) rather than rejected — a shader
//     doesn't need every texture it names to actually exist on disk to still be worth compiling.
//   - The shader body is everything between the first `{` after the literal token `shader_body` and
//     the *last* `}` in the source, mutating a `float3 ret` that starts at zero (MilkdropShader.cpp:
//     376-429) — not a real function with its own signature. A shader missing `shader_body` is
//     malformed by Milkdrop's own rules (real Milkdrop throws), so here translation just fails and
//     the preset falls back to the plain warp transform, never a crash or a refused preset load.
//   - `sampler_state { ... };` override blocks (rare; real Milkdrop's own comment calls its removal
//     "not totally fool-proof") are stripped outright — Prism resolves filter/wrap from the
//     identifier's qualifier prefix instead, so these blocks carry no information this port acts on.
//

import Foundation

enum MilkdropShaderTranslator {
    /// One texture a shader body samples, resolved from a `tex2D`/`tex3D` call-site identifier.
    struct TextureBinding {
        /// The exact identifier as used in the shader source (e.g. `sampler_fw_noisevol_hq`) —
        /// reused verbatim as the MSL function's texture/sampler parameter name, so call-site
        /// rewrites don't need a separate lookup table.
        var declaredName: String
        /// The resolved base resource: `.main` (the feedback texture), `.noise(baseName)` where
        /// `baseName` is one of MilkdropNoiseTextures' catalog keys (`noise_lq`, `noisevol_hq`,
        /// etc), or `.blur(level)` for the `GetBlur1`/`GetBlur2`/`GetBlur3` helper functions (see
        /// this file's header on `GetPixel`/`GetBlurN` below) — resolved to a real, genuinely
        /// blurred/downsampled cascade texture (MilkdropMetalRenderer.updateBlurTextures, done
        /// 7/26; MilkdropMetalRenderer.metalTexture(for:mainTexture:) does the actual lookup, with
        /// an unblurred-`main`-texture fallback only if a level hasn't been generated yet).
        var resource: Resource
        var filter: Filter
        var wrap: Wrap
        /// Whether this was used via `tex3D` (volumetric) rather than `tex2D` — determines whether
        /// the caller binds a `texture3d<float>` or `texture2d<float>` parameter.
        var isVolume: Bool

        /// `.custom(baseName)` is any qualifier-stripped name that isn't `main` or a standard noise
        /// texture — resolved at draw time against a preset pack's own `Textures/` folder (see
        /// MilkdropCustomTextureManager.swift), falling back to a 1x1 black placeholder if the name
        /// can't be found there, exactly like real Milkdrop's own TextureManager does. This used to
        /// make `classify`/`translate` return `nil` for the whole shader — a preset pack missing
        /// even one referenced texture file (common — see MilkdropCustomTextureManager.swift's
        /// header) shouldn't lose 100% of that shader's other effects over it.
        // `nonisolated` on all three — plain value types with no UI/main-thread state, compared via
        // `==` from test code that runs in a nonisolated context; without this, the project-wide
        // default MainActor isolation would apply even to their (explicit or synthesized)
        // `Equatable` conformance, same fix as AlbumColors.swift's `BackgroundTone`.
        nonisolated enum Resource: Equatable { case main, noise(String), blur(Int), custom(String) }
        nonisolated enum Filter { case linear, nearest }
        nonisolated enum Wrap { case repeatWrap, clampToEdge }
    }

    /// Reserved, collision-proof parameter names for the implicit `GetPixel`/`GetBlurN` textures
    /// (see `discoverImplicitHelperTextures` below) — a double-underscore prefix no real preset
    /// identifier uses, so these never collide with an explicitly-declared `sampler_main` etc. that
    /// might *also* be present in the same shader.
    static let getPixelTextureName = "__milkdrop_getpixel_main"
    static func getBlurTextureName(_ level: Int) -> String { "__milkdrop_getblur_\(level)" }

    struct Result {
        /// MSL statements that mutate `ret` (declared by the caller) — not a complete function; see
        /// this file's header for why the source has no natural function boundary of its own.
        var body: String
        /// Every texture this shader body needs bound, in first-referenced order — the caller
        /// builds the compiled function's texture/sampler parameter list from this.
        var textures: [TextureBinding]
        /// Complete helper function definitions the preset declared *before* `shader_body` (real
        /// example: `float2 uv_polar(float2 domain, float2 center){ ... }`) — see
        /// `extractHelperFunctions`. Unlike `body`, the caller must paste these at true top-level
        /// scope, *before* the wrapping `milkdrop_composite_main`/`milkdrop_warp_main` function
        /// definition, not inside it — MSL (like C) doesn't allow a nested function definition.
        /// Empty for the common case (no preset-defined helper functions).
        var helperFunctions: String = ""
    }

    /// The only base texture names, beyond `main`, this port resolves — projectM's standard 2D/3D
    /// value-noise catalog (see MilkdropNoiseTextures.swift). The dominant real-world dependency,
    /// but not the only one worth having: a corpus re-scan on 7/25 (via direct file-level regex
    /// over all 9,795 presets, not through MilkdropPresetFile — see this session's notes in
    /// TO DO.md on why that distinction matters) found noise textures referenced in 5,115-of-8,251
    /// shader-using presets, but *also* found a real gap this comment previously mischaracterized:
    /// the literal `image=` INI key genuinely is unused (0/9,795, confirmed), but that's a
    /// different, disused mechanism from the one that actually matters — custom sampler names like
    /// `sampler_worms`/`sampler_clouds` resolving to files in a preset pack's own `Textures/`
    /// folder — which showed up in **19.2% of the full corpus** (22.7% of shader-using presets;
    /// top names: worms 521, clouds 226, rand00 178, lichen 109, sky 95). That was Phase 2's
    /// "Custom texture loading" TODO item — **done 7/25**, see `TextureBinding.Resource.custom` and
    /// MilkdropCustomTextureManager.swift — resolved at draw time against a preset pack's own
    /// `Textures/` folder rather than here; this set only ever gates the *noise* catalog now.
    static let supportedNoiseTextures: Set<String> = [
        "noise_lq", "noise_mq", "noise_hq", "noisevol_lq", "noisevol_hq",
    ]

    /// Returns `nil` only if `hlslSource` is empty or malformed (no `shader_body` marker — same
    /// requirement real Milkdrop enforces) — no longer for an unresolved texture reference of any
    /// kind (main/noise/custom all always classify successfully now; a *custom* name that turns out
    /// not to exist on disk resolves to a 1x1 black placeholder at draw time instead, matching real
    /// Milkdrop's own TextureManager rather than refusing the whole shader over it).
    static func translate(_ hlslSource: String) -> Result? {
        guard !hlslSource.isEmpty else { return nil }

        // Real preset shader source can contain `//`/`/* */` comments (confirmed: a genuine,
        // widespread corpus pattern — commented-out debug lines are common in hand-edited presets),
        // and every text-substitution pass in this file — old and new — is blind to them (none
        // special-case "this text is inside a comment"). Stripped once, up front, rather than
        // patched into each individual rewrite pass: `rewriteFloatModulo`'s tokenizer is the one
        // that actually broke on this (it reformats inter-token whitespace, so an unrecognized `//`
        // got tokenized as two separate `/` operators and re-joined as `/ /` — a real comment with
        // a space in the middle isn't a comment anymore, turning "commented out" code back into
        // live, and now syntactically broken, code — 9877x "expected expression" in a corpus
        // re-scan), but every other pass (helper-function extraction's brace/paren depth-matching,
        // `discoverTextures`' call-site scan, etc.) had the same latent blind spot even before that;
        // stripping comments here protects all of them going forward, not just the one that happened
        // to surface it.
        var source = stripComments(hlslSource)
        source = stripSamplerStateBlocks(source)
        // Captured before `extractShaderBody` below discards everything preceding `shader_body`'s
        // own `{` — see `preambleDeclarations` for why this text still matters.
        let preamble = source.range(of: "shader_body").map { String(source[source.startIndex..<$0.lowerBound]) } ?? ""
        guard let bodyRange = extractShaderBody(&source) else { return nil }
        let rawBody = String(source[bodyRange])

        guard let textures = discoverTextures(in: rawBody) else { return nil }

        var body = rewriteTextureSampleCalls(rawBody, textures: textures)
        body = renameIntrinsics(body)

        // Must run before `preambleDeclarations` below: that function splits on `;`, which would
        // shred a function body (itself full of statement-terminating `;`s) into garbage fragments
        // if the function text were still mixed in with the plain variable declarations. Fails the
        // whole translation (matching `discoverTextures`'s own contract on `rawBody` above) if any
        // helper function references a malformed texture identifier.
        guard let (helperFunctions, remainderPreamble, extraArgsByName, helperTextures) = extractHelperFunctions(from: preamble) else { return nil }

        // A hoisted helper function is genuinely top-level MSL (see `extractHelperFunctions`'s doc
        // comment), so any call to one — from `shader_body` itself, or from a preamble declaration's
        // initializer (`float2 uv2 = uv_polar(uv, c);`) — must pass `uniforms` and any textures that
        // function (transitively) needs explicitly now that the callee takes them as parameters
        // (see `threadUniformsParameter`/`threadTextureParameters`). 99x "undeclared identifier
        // 'uniforms'", 42x "undeclared identifier 'GetPixel'"/`GetBlur1`/`GetBlur2` in the 7/26
        // corpus scan.
        body = appendExtraArguments(to: body, forCallsTo: extraArgsByName)
        let declarations = renameIntrinsics(preambleDeclarations(appendExtraArguments(to: remainderPreamble, forCallsTo: extraArgsByName)))
        if !declarations.isEmpty {
            // The body is wrapped in its own `{ }` block, *nested inside* the hoisted declarations'
            // scope rather than flattened alongside them — real HLSL block-scoping lets
            // `shader_body` legally redeclare (shadow) a name already declared above it (a real,
            // observed pattern: a preset's own `float2 uv2;` before `shader_body` *and* its own
            // `float2 uv2;` again as the body's first line) — flattening both into one scope would
            // make MSL reject that as a redefinition even though the original HLSL was fine.
            body = declarations + "\n{\n" + body + "\n}"
        }

        // The outer wrapping function (`milkdrop_composite_main`/`milkdrop_warp_main`, built by
        // MilkdropMetalRenderer from `Result.textures`) is the only place with real
        // `[[texture(i)]]`/`[[sampler(i)]]` binding indices — every texture any hoisted helper
        // needs (even transitively, via a helper-calls-helper chain) must be bound there too, or
        // the call site threaded above would reference a name with nothing in scope.
        var allTextures = textures
        var seenTextureNames = Set(textures.map(\.declaredName))
        for texture in helperTextures where !seenTextureNames.contains(texture.declaredName) {
            allTextures.append(texture)
            seenTextureNames.insert(texture.declaredName)
        }

        return Result(body: body, textures: allTextures, helperFunctions: renameIntrinsics(helperFunctions))
    }

    /// Real Milkdrop preset shaders sometimes declare local scratch variables *before*
    /// `shader_body` (`float2 dz, uv2, uv3; float3 ret1, neu, mus; shader_body { ... }`) rather than
    /// inline inside the body — `extractShaderBody` above (matching MilkdropShader.cpp's own
    /// landmark-based extraction) only ever looks at what's between `shader_body`'s `{`/`}`, so
    /// these were silently discarded, leaving the body referencing undeclared identifiers. Confirmed
    /// directly against real corpus files (e.g. "suksma - my face is black pus"'s `comp_N=`, which
    /// failed to compile over exactly this — `dz`/`ret1`/`neu`/`mus`/`uv3`/`uv4` all declared before
    /// `shader_body`, never redeclared inside it) rather than assumed.
    ///
    /// Scans for simple `<type> name1, name2, ...;` declarations (`float`/`float1`-`float4`/`int`/
    /// `bool`) and hoists them to the top of the generated function body instead of discarding them.
    /// Deliberately excludes any statement mentioning `texture`/`sampler` (real preset shaders often
    /// *also* declare textures/samplers up here, e.g. `texture sampler_fw_noisevol_hq;`) — those are
    /// resolved entirely separately, from call sites, not declarations (see this file's header), and
    /// aren't valid as a plain MSL local variable regardless.
    /// Real preset shaders sometimes declare complete helper functions before `shader_body`, not
    /// just plain variables — confirmed against a real corpus file ("propre hypno.milk"'s `comp_N=`,
    /// which defines `uv_polar`/`uv_lens_half_sphere` above `shader_body` and calls them from inside
    /// it). MSL, like C, doesn't allow a function definition nested inside another function, so these
    /// can't stay where `preambleDeclarations` would otherwise put them (inside the wrapped body) —
    /// the caller must paste `Result.helperFunctions` at true top-level scope instead. This runs
    /// *before* `preambleDeclarations` and pulls each complete `<type> name(...) { ... }` span out of
    /// the preamble first, in original source order (a later function may call an earlier one, as
    /// `uv_lens_half_sphere` calls `uv_polar`), leaving only plain declarations behind for
    /// `preambleDeclarations`'s semicolon-split logic to see — splitting a function's own body on
    /// `;` would otherwise shred it.
    ///
    /// Uses paren/brace-depth matching (unlike `extractShaderBody`'s simple landmark search) because,
    /// unlike the single well-known `shader_body` marker, a function's parameter list and body can
    /// both contain arbitrarily nested `(`/`{` of their own.
    private static func extractHelperFunctions(from preamble: String) -> (functions: String, remainder: String, extraArgsByName: [String: [String]], textures: [TextureBinding])? {
        let chars = Array(preamble)
        let typeKeywords = [
            "float2x2", "float3x3", "float4x4",
            "float4", "float3", "float2", "float1", "float", "int", "bool", "void",
        ]
        func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" }

        var functions: [(name: String, signature: String, body: String)] = []
        var remainder = ""
        var i = 0
        while i < chars.count {
            let atTokenBoundary = i == 0 || !isIdentifierChar(chars[i - 1])
            var matchedType: String? = nil
            if atTokenBoundary {
                for kw in typeKeywords {
                    let kwChars = Array(kw)
                    let end = i + kwChars.count
                    guard end <= chars.count, Array(chars[i..<end]) == kwChars else { continue }
                    guard end >= chars.count || !isIdentifierChar(chars[end]) else { continue }
                    matchedType = kw
                    break
                }
            }
            guard let type = matchedType else {
                remainder.append(chars[i])
                i += 1
                continue
            }

            var k = i + type.count
            guard k < chars.count, chars[k].isWhitespace else {
                remainder.append(chars[i]); i += 1; continue
            }
            while k < chars.count, chars[k].isWhitespace { k += 1 }
            guard k < chars.count, isIdentifierStart(chars[k]) else {
                remainder.append(chars[i]); i += 1; continue
            }
            var idEnd = k
            while idEnd < chars.count, isIdentifierChar(chars[idEnd]) { idEnd += 1 }

            var p = idEnd
            while p < chars.count, chars[p].isWhitespace { p += 1 }
            guard p < chars.count, chars[p] == "(" else {
                remainder.append(chars[i]); i += 1; continue
            }
            var parenDepth = 1
            var q = p + 1
            while q < chars.count, parenDepth > 0 {
                if chars[q] == "(" { parenDepth += 1 } else if chars[q] == ")" { parenDepth -= 1 }
                q += 1
            }
            guard parenDepth == 0 else {
                remainder.append(chars[i]); i += 1; continue
            }

            var r = q
            while r < chars.count, chars[r].isWhitespace { r += 1 }
            guard r < chars.count, chars[r] == "{" else {
                remainder.append(chars[i]); i += 1; continue
            }
            var braceDepth = 1
            var s = r + 1
            while s < chars.count, braceDepth > 0 {
                if chars[s] == "{" { braceDepth += 1 } else if chars[s] == "}" { braceDepth -= 1 }
                s += 1
            }
            guard braceDepth == 0 else {
                remainder.append(chars[i]); i += 1; continue
            }

            functions.append((name: String(chars[k..<idEnd]), signature: String(chars[i..<q]), body: String(chars[q..<s])))
            i = s
        }

        guard !functions.isEmpty else { return ("", remainder, [:], []) }
        let names = Set(functions.map(\.name))

        // Each hoisted function is genuinely top-level MSL (see this function's own doc comment
        // above): it has no implicit access to the wrapping fragment function's `uniforms` buffer
        // (every `time`/`bass`/`q1`/etc. #define — see MilkdropMetalRenderer.uniformDefines —
        // expands to `uniforms[N]` regardless of which function it textually lands in, so
        // *any* reference to one, even transitively through another macro like `hue_shader`, needs
        // `uniforms` threaded in explicitly), and no implicit access to any texture/sampler bound
        // on the wrapping function's own parameter list either — a direct `GetPixel`/`GetBlur1`/
        // `tex2D` call inside a hoisted function's own body needs that specific texture threaded
        // the same way. 99x "undeclared identifier 'uniforms'", 42x "undeclared identifier
        // 'GetPixel'"/`GetBlur1`/`GetBlur2` in the 7/26 corpus scan.
        //
        // Textures are discovered per function from its own raw body (mirroring `discoverTextures`
        // on `rawBody` in `translate` above — same call-site-based discovery, same failure
        // contract: a malformed texture identifier fails the whole translation). `uniforms` is
        // simpler — always threaded, since detecting real usage would mean replicating the full
        // macro dependency graph for no real savings (an unused parameter costs nothing).
        var ownTextures: [String: [TextureBinding]] = [:]
        for fn in functions {
            guard let discovered = discoverTextures(in: fn.body) else { return nil }
            ownTextures[fn.name] = discovered
        }

        // One hoisted function calling another (`uv_lens_half_sphere` calling `uv_polar`, a real
        // corpus pattern) means a texture only the *callee* samples directly must still be threaded
        // through the *caller*'s own signature, purely to forward it along — a transitive closure
        // over the small call graph between hoisted functions, fixed-point iterated since the
        // call graph can itself be a chain more than one level deep.
        var calledHelpers: [String: Set<String>] = [:]
        for fn in functions {
            calledHelpers[fn.name] = calledHelperNames(in: fn.body, candidates: names)
        }
        var requiredTextures = ownTextures
        var changed = true
        while changed {
            changed = false
            for fn in functions {
                var merged = requiredTextures[fn.name] ?? []
                var seen = Set(merged.map(\.declaredName))
                for callee in calledHelpers[fn.name] ?? [] {
                    for texture in requiredTextures[callee] ?? [] where !seen.contains(texture.declaredName) {
                        merged.append(texture)
                        seen.insert(texture.declaredName)
                        changed = true
                    }
                }
                requiredTextures[fn.name] = merged
            }
        }

        var extraArgsByName: [String: [String]] = [:]
        for fn in functions {
            var args = ["uniforms"]
            for texture in requiredTextures[fn.name] ?? [] {
                args.append(texture.declaredName)
                args.append("\(texture.declaredName)_smp")
            }
            extraArgsByName[fn.name] = args
        }

        let threaded = functions.map { fn -> String in
            var rewrittenBody = rewriteTextureSampleCalls(fn.body, textures: ownTextures[fn.name] ?? [])
            rewrittenBody = appendExtraArguments(to: rewrittenBody, forCallsTo: extraArgsByName)
            var signature = threadUniformsParameter(intoSignature: fn.signature)
            signature = threadTextureParameters(intoSignature: signature, textures: requiredTextures[fn.name] ?? [])
            return signature + rewrittenBody
        }

        var allHelperTextures: [TextureBinding] = []
        var seenHelperTextureNames = Set<String>()
        for fn in functions {
            for texture in requiredTextures[fn.name] ?? [] where !seenHelperTextureNames.contains(texture.declaredName) {
                allHelperTextures.append(texture)
                seenHelperTextureNames.insert(texture.declaredName)
            }
        }

        return (threaded.joined(separator: "\n\n"), remainder, extraArgsByName, allHelperTextures)
    }

    /// Every hoisted-function name (from `candidates`) mentioned as a whole word anywhere in
    /// `text` — used to build the call graph between hoisted functions for
    /// `extractHelperFunctions`'s transitive texture-requirement closure. A plain word-boundary
    /// mention (not a stricter "is this actually followed by `(`" call-site check, unlike
    /// `appendExtraArguments` below) is a deliberately loose but safe over-approximation: treating
    /// a name as "called" when it wasn't just threads an unused parameter, never breaks anything.
    private static func calledHelperNames(in text: String, candidates: Set<String>) -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let chars = Array(text)
        func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var found: Set<String> = []
        var i = 0
        while i < chars.count {
            let atBoundary = i == 0 || !isIdentifierChar(chars[i - 1])
            if atBoundary {
                for name in candidates where !found.contains(name) {
                    let nameChars = Array(name)
                    let end = i + nameChars.count
                    guard end <= chars.count, Array(chars[i..<end]) == nameChars,
                          end == chars.count || !isIdentifierChar(chars[end])
                    else { continue }
                    found.insert(name)
                }
            }
            i += 1
        }
        return found
    }

    /// Inserts `constant float *uniforms` as the last parameter of `signature` (a complete
    /// `<type> name(params)` span, closing paren included) — appending after any existing
    /// parameters, or as the sole parameter if the original list was empty.
    private static func threadUniformsParameter(intoSignature signature: String) -> String {
        guard signature.hasSuffix(")") else { return signature }
        let withoutCloseParen = signature.dropLast()
        guard let openParen = withoutCloseParen.firstIndex(of: "(") else { return signature }
        let params = withoutCloseParen[withoutCloseParen.index(after: openParen)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let head = withoutCloseParen[...openParen]
        return params.isEmpty
            ? "\(head)constant float *uniforms)"
            : "\(head)\(params), constant float *uniforms)"
    }

    /// Appends a `texture2d<float>`/`texture3d<float>` + `sampler` parameter pair for each of
    /// `textures` to `signature` (called after `threadUniformsParameter`, so the parameter list is
    /// never empty by this point) — the signature half of the same threading `appendExtraArguments`
    /// applies at call sites, for a hoisted function that (transitively) samples a texture.
    private static func threadTextureParameters(intoSignature signature: String, textures: [TextureBinding]) -> String {
        guard !textures.isEmpty, signature.hasSuffix(")") else { return signature }
        let withoutCloseParen = signature.dropLast()
        let extra = textures.map { texture -> String in
            let textureType = texture.isVolume ? "texture3d<float>" : "texture2d<float>"
            return "\(textureType) \(texture.declaredName), sampler \(texture.declaredName)_smp"
        }.joined(separator: ", ")
        return "\(withoutCloseParen), \(extra))"
    }

    /// Rewrites every call site of a name in `extraArgsByName`'s keys within `text` to pass that
    /// name's associated extra arguments (`uniforms`, plus a `texture, sampler` pair per texture
    /// the callee transitively needs) as additional trailing arguments (`foo(a, b)` -> `foo(a, b,
    /// uniforms, sampler_main, sampler_main_smp)`, `foo()` -> `foo(uniforms)`) — the call-site half
    /// of `threadUniformsParameter`/`threadTextureParameters` above. Recurses into each call's own
    /// arguments so a nested call (one hoisted function calling another inside an expression) is
    /// rewritten too. Uses paren-depth matching, not a regex, since arguments nest.
    private static func appendExtraArguments(to text: String, forCallsTo extraArgsByName: [String: [String]]) -> String {
        guard !extraArgsByName.isEmpty else { return text }
        let chars = Array(text)
        func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        var result = ""
        var i = 0
        while i < chars.count {
            let atBoundary = i == 0 || !isIdentifierChar(chars[i - 1])
            var matchedName: String? = nil
            if atBoundary {
                for name in extraArgsByName.keys {
                    let nameChars = Array(name)
                    let end = i + nameChars.count
                    guard end <= chars.count, Array(chars[i..<end]) == nameChars, end < chars.count, !isIdentifierChar(chars[end]) else { continue }
                    var j = end
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    guard j < chars.count, chars[j] == "(" else { continue }
                    matchedName = name
                    break
                }
            }
            guard let name = matchedName, let extraArgs = extraArgsByName[name] else {
                result.append(chars[i])
                i += 1
                continue
            }

            var j = i + name.count
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            let parenStart = j // chars[parenStart] == "("
            var depth = 1
            var k = parenStart + 1
            while k < chars.count, depth > 0 {
                if chars[k] == "(" { depth += 1 } else if chars[k] == ")" { depth -= 1 }
                if depth > 0 { k += 1 }
            }
            guard k < chars.count else {
                result.append(contentsOf: chars[i...])
                return result
            }

            let argsText = String(chars[(parenStart + 1)..<k])
            let rewrittenArgs = appendExtraArguments(to: argsText, forCallsTo: extraArgsByName)
            let trimmedArgs = rewrittenArgs.trimmingCharacters(in: .whitespacesAndNewlines)
            let joinedExtraArgs = extraArgs.joined(separator: ", ")
            result.append(name)
            result.append("(")
            result.append(trimmedArgs.isEmpty ? joinedExtraArgs : "\(rewrittenArgs), \(joinedExtraArgs)")
            result.append(")")
            i = k + 1
        }
        return result
    }

    private static func preambleDeclarations(_ preamble: String) -> String {
        let keywords = ["float", "int", "bool"] // covers float1-float4 too (all share the "float" prefix)
        var kept: [String] = []
        for rawStatement in preamble.split(separator: ";") {
            let statement = rawStatement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else { continue }
            let lowered = statement.lowercased()
            guard !lowered.contains("texture"), !lowered.contains("sampler") else { continue }
            guard keywords.contains(where: { lowered.hasPrefix($0) }) else { continue }
            kept.append(statement + ";")
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Comment stripping

    /// Removes every `//`-to-end-of-line and `/* ... */` span from `source` — see `translate`'s
    /// doc comment on why this runs first, before any other pass gets a chance to misparse comment
    /// text as code. An unterminated `/*` (malformed source) strips through the end of the string
    /// rather than looping forever.
    private static func stripComments(_ source: String) -> String {
        let chars = Array(source)
        var result = ""
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    // MARK: - sampler_state removal

    /// Repeatedly deletes `<lhs> = sampler_state { ... };` spans — a direct port of
    /// MilkdropShader.cpp:347-374's find-`sampler_state`/backtrack-to-`=`/forward-to-`;` loop.
    private static func stripSamplerStateBlocks(_ source: String) -> String {
        var text = source
        while let stateRange = text.range(of: "sampler_state") {
            guard let equalsRange = text.range(of: "=", options: .backwards, range: text.startIndex..<stateRange.upperBound),
                  let braceRange = text.range(of: "}", range: stateRange.upperBound..<text.endIndex),
                  let semicolonRange = text.range(of: ";", range: braceRange.upperBound..<text.endIndex)
            else {
                break // No closing brace/semicolon — matches upstream giving up rather than looping forever.
            }
            text.removeSubrange(equalsRange.lowerBound..<semicolonRange.upperBound)
        }
        return text
    }

    // MARK: - shader_body extraction

    /// Locates `shader_body`, the `{` immediately following it, and the *last* `}` in the source —
    /// mirroring MilkdropShader.cpp:376-429's exact landmark-based extraction (not brace-matching:
    /// real Milkdrop trusts the preset is well-formed, and this port extends it the same trust).
    private static func extractShaderBody(_ source: inout String) -> Range<String.Index>? {
        guard let markerRange = source.range(of: "shader_body") else { return nil }
        guard let openBrace = source.range(of: "{", range: markerRange.upperBound..<source.endIndex) else { return nil }
        guard let closeBrace = source.range(of: "}", options: .backwards) else { return nil }
        guard openBrace.upperBound <= closeBrace.lowerBound else { return nil }
        return openBrace.upperBound..<closeBrace.lowerBound
    }

    // MARK: - Texture discovery (from call sites, not declarations — see this file's header)

    /// `GetPixel(uv)`/`GetBlur1(uv)`/`GetBlur2(uv)`/`GetBlur3(uv)` are real Milkdrop shader helper
    /// *functions*, not `tex2D`/`tex3D` calls, but they implicitly depend on the main/blur textures
    /// exactly the same way — `scanTextureCalls` recognizes them as call sites too (see below), just
    /// with an *implied* sampler identifier (these reserved names) instead of one parsed from the
    /// call's own first argument, since `GetPixel(uv)` only ever takes the UV, never a sampler name.
    /// Deliberately rewritten at the call site (`discoverTextures`/`rewriteTextureSampleCalls`
    /// below), not left as-is with a separately-declared MSL helper function: unlike GLSL, MSL
    /// texture/sampler bindings are function *parameters*, not globals, so a standalone `GetBlur1`
    /// function has no way to reach a texture bound to a completely different function's parameter
    /// list — confirmed the hard way (a real corpus shader compiled with the texture parameter
    /// declared but "use of undeclared identifier" inside the separate helper function) before
    /// settling on call-site rewriting instead.
    private static let implicitTextureFunctions: [String: (name: String, resource: TextureBinding.Resource)] = [
        "GetPixel": (getPixelTextureName, .main),
        // `GetMain`/`GetPixel` are the exact same thing in real Milkdrop (both `#define`d to
        // `tex2D(sampler_main,uv).xyz` — confirmed against projectM's PresetShaderHeaderGlsl330.inc),
        // so both share the one reserved main-texture binding rather than requesting two.
        "GetMain": (getPixelTextureName, .main),
        "GetBlur1": (getBlurTextureName(1), .blur(1)),
        "GetBlur2": (getBlurTextureName(2), .blur(2)),
        "GetBlur3": (getBlurTextureName(3), .blur(3)),
    ]

    /// Scans `body` for every `tex2D`/`tex2Dlod`/`tex3D`/`GetPixel`/`GetBlur1`/`GetBlur2`/`GetBlur3`
    /// call, collects the distinct textures referenced, and classifies each. Returns `nil` the
    /// moment any referenced texture resolves to something this port doesn't support.
    ///
    /// Recurses into each call's own arguments, not just the top-level scan — `scanTextureCalls`
    /// only ever reports the *outermost* call starting at a given position (real corpus example:
    /// `tex2D(sampler_main, GetBlur1(uv))` — the nested `GetBlur1(uv)` becomes part of the outer
    /// call's own consumed range and is otherwise invisible to a second top-level scan), so without
    /// this a nested `GetBlur1`/`GetPixel`/`tex2D`/etc. never gets its texture binding declared at
    /// all (16x/13x "undeclared identifier 'GetBlur1'/'GetPixel'" in the 7/26 corpus scan — both
    /// were nested inside an outer call's arguments, not genuinely unrecognized names).
    private static func discoverTextures(in body: String) -> [TextureBinding]? {
        var seen: [String: TextureBinding] = [:]
        var order: [String] = []

        func visit(_ text: String) -> Bool {
            for call in scanTextureCalls(text) {
                if let implicit = implicitTextureFunctions[call.function] {
                    if seen[implicit.name] == nil {
                        seen[implicit.name] = TextureBinding(
                            declaredName: implicit.name, resource: implicit.resource,
                            filter: .linear, wrap: .clampToEdge, isVolume: false
                        )
                        order.append(implicit.name)
                    }
                } else if let name = call.arguments.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    if seen[name] == nil {
                        guard let binding = classify(declaredName: name, isVolume: call.function == "tex3D") else { return false }
                        seen[name] = binding
                        order.append(name)
                    }
                }
                for argument in call.arguments where !visit(argument) {
                    return false
                }
            }
            return true
        }

        guard visit(body) else { return nil }
        return order.map { seen[$0]! }
    }

    /// Applies the qualifier-prefix rule (see this file's header) to `declaredName` (expected to
    /// start with `sampler_`, matching Milkdrop's own naming convention) and resolves the base name
    /// against `main`/the noise catalog.
    private static func classify(declaredName: String, isVolume: Bool) -> TextureBinding? {
        guard declaredName.hasPrefix("sampler_") else { return nil }
        let qualified = String(declaredName.dropFirst("sampler_".count))
        let (baseName, filter, wrap) = extractQualifier(qualified)

        let resource: TextureBinding.Resource
        if baseName == "main" {
            resource = .main
        } else if supportedNoiseTextures.contains(baseName) {
            resource = .noise(baseName)
        } else {
            // Anything else — `worms`, `rand00`, etc. — resolves against a preset pack's own
            // Textures/ folder at draw time (see MilkdropCustomTextureManager.swift), not here;
            // this port has no reason to reject the shader over a name it hasn't seen yet.
            resource = .custom(baseName.lowercased())
        }
        return TextureBinding(declaredName: declaredName, resource: resource, filter: filter, wrap: wrap, isVolume: isVolume)
    }

    /// Port of `TextureManager::ExtractTextureSettings` (TextureManager.cpp:355-401): a qualified
    /// name shorter than 4 characters, or whose 3rd character isn't `_`, has no qualifier at all.
    private static func extractQualifier(_ qualified: String) -> (baseName: String, filter: TextureBinding.Filter, wrap: TextureBinding.Wrap) {
        let lower = qualified.lowercased()
        guard lower.count > 3, lower[lower.index(lower.startIndex, offsetBy: 2)] == "_" else {
            return (qualified, .linear, .repeatWrap)
        }
        let prefix = String(lower.prefix(3))
        let baseName = String(qualified.dropFirst(3))
        switch prefix {
        case "fc_", "cf_": return (baseName, .linear, .clampToEdge)
        case "fw_", "wf_": return (baseName, .linear, .repeatWrap)
        case "pc_", "cp_": return (baseName, .nearest, .clampToEdge)
        case "pw_", "wp_": return (baseName, .nearest, .repeatWrap)
        default: return (baseName, .linear, .repeatWrap) // Milkdrop still strips an unrecognized "XY_" prefix.
        }
    }

    // MARK: - Call-site scanning shared by discovery and rewriting

    private struct TextureCall {
        var function: String // "tex2D" | "tex2Dlod" | "tex3D" | "GetPixel" | "GetBlur1" | "GetBlur2" | "GetBlur3"
        var range: Range<Int> // Index range into the `chars` array the caller scanned, full call incl. parens.
        var arguments: [String]
    }

    /// Every call-site name `discoverTextures`/`rewriteTextureSampleCalls` recognize. Longer
    /// prefixes first (`tex2Dlod` before `tex2D`) so a case-insensitive scan can't misfire on the
    /// shorter name's prefix.
    private static let recognizedCallNames = ["tex2Dlod", "tex2D", "tex3D", "GetPixel", "GetMain", "GetBlur1", "GetBlur2", "GetBlur3"]

    /// Finds every `tex2D(...)`/`tex2Dlod(...)`/`tex3D(...)`/`GetPixel(...)`/`GetBlur1(...)`/
    /// `GetBlur2(...)`/`GetBlur3(...)` call in `body`, using a paren-depth scanner rather than a
    /// single regex since real arguments nest — e.g. `tex2D(sampler_fc_main, float2(ruv.x,
    /// ruv.y))`, a verbatim call from the survey corpus.
    private static func scanTextureCalls(_ body: String) -> [TextureCall] {
        let chars = Array(body)
        var calls: [TextureCall] = []
        var i = 0

        func matchFunctionCall(_ name: String) -> Bool {
            guard i + name.count < chars.count else { return false }
            // Case-insensitive: real preset shaders (confirmed in the corpus) sometimes write
            // `tex2d`/`tex3d` in lowercase — HLSL/Cg's own compiler apparently tolerates this,
            // so this port does too rather than silently missing the texture reference entirely.
            guard String(chars[i..<i + name.count]).caseInsensitiveCompare(name) == .orderedSame else { return false }
            var j = i + name.count
            while j < chars.count, chars[j] == " " { j += 1 }
            return j < chars.count && chars[j] == "("
        }

        while i < chars.count {
            guard let funcName = recognizedCallNames.first(where: matchFunctionCall) else {
                i += 1
                continue
            }
            var j = i + funcName.count
            while j < chars.count, chars[j] == " " { j += 1 }
            let parenStart = j
            var depth = 0
            var k = parenStart
            while k < chars.count {
                if chars[k] == "(" { depth += 1 }
                if chars[k] == ")" { depth -= 1; if depth == 0 { break } }
                k += 1
            }
            guard k < chars.count else { break } // Unbalanced parens — stop scanning rather than guess.

            let argsText = String(chars[(parenStart + 1)..<k])
            calls.append(TextureCall(function: funcName, range: i..<(k + 1), arguments: splitTopLevelArguments(argsText)))
            i = k + 1
        }
        return calls
    }

    /// Splits `a, b(c, d), e` into `["a", "b(c, d)", "e"]` — comma-splitting that respects
    /// parenthesis nesting, needed since `tex2D`'s UV argument is often itself a call like
    /// `float2(ruv.x, ruv.y)`.
    private static func splitTopLevelArguments(_ text: String) -> [String] {
        var args: [String] = []
        var depth = 0
        var current = ""
        for ch in text {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == "," && depth == 0 {
                args.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    // MARK: - Rewriting

    /// Rewrites every call `scanTextureCalls` found into MSL's explicit texture+sampler calling
    /// convention: `tex2D(NAME, uv)` -> `NAME.sample(NAME_smp, uv)` (`tex2Dlod`'s bias argument
    /// passes through as an extra `.sample` parameter the same way).
    ///
    /// Recurses into each call's own arguments before building its replacement — `scanTextureCalls`
    /// only ever reports the *outermost* call starting at a given position, so a nested call buried
    /// inside another call's arguments (real corpus example: `tex2D(sampler_main,
    /// GetBlur1(uv))`) would otherwise be left as untranslated HLSL text (an "undeclared identifier"
    /// at the MSL compile stage) — see `discoverTextures`'s matching recursion for the same reason
    /// nested calls need their texture binding discovered in the first place.
    ///
    /// `defaultWidth` is what a nested call falls back to when it isn't itself a `<type> name = ...`
    /// initializer (see `declaredAssignmentWidth`) — 3 (float3) at the true top level, matching this
    /// function's original single-purpose default, but a recursive call processing another call's
    /// *coordinate* arguments passes 2 instead: a nested texture call used as a UV coordinate (the
    /// `GetBlur1(uv)` above, passed as `tex2D`'s second argument) wants a float2, not a float3 —
    /// reusing the float3 default there would just trade one MSL width-mismatch error for another.
    private static func rewriteTextureSampleCalls(_ body: String, textures: [TextureBinding], defaultWidth: Int = 3) -> String {
        let chars = Array(body)
        let calls = scanTextureCalls(body)
        guard !calls.isEmpty else { return body }

        var result = ""
        var cursor = 0
        for call in calls {
            result.append(contentsOf: chars[cursor..<call.range.lowerBound])
            let samplerName: String
            let rawArgs: [String]
            if let implicit = implicitTextureFunctions[call.function] {
                // GetPixel(uv)/GetBlurN(uv): the sampler identifier is implied by which function
                // was called, not parsed from an argument — every argument present is the "uv".
                samplerName = implicit.name
                rawArgs = call.arguments
            } else {
                samplerName = call.arguments.first?.trimmingCharacters(in: .whitespaces) ?? ""
                rawArgs = Array(call.arguments.dropFirst())
            }
            let remainingArgs = rawArgs
                .map { rewriteTextureSampleCalls($0, textures: textures, defaultWidth: 2).trimmingCharacters(in: .whitespaces) }
                .joined(separator: ", ")
            result.append("\(samplerName).sample(\(samplerName)_smp, \(remainingArgs))")
            // HLSL's tex2D/tex3D return a float4, and real preset code routinely relies on HLSL's
            // implicit float4->float3 narrowing conversion when assigning straight into a float3
            // (`float3 x = tex2D(...);`, `ret = tex2D(...);` where `ret` is float3 — both verbatim
            // patterns in the survey corpus) — MSL has no implicit vector-narrowing conversion at
            // all, so that assignment simply fails to compile without an explicit swizzle. If the
            // original call isn't already explicitly swizzled (`.xyz`/`.rgb`/`.a`/etc immediately
            // follows in the source), a swizzle needs to be appended here to reproduce what HLSL
            // did silently; leave an already-swizzled call alone so `tex2D(sampler, uv).a` keeps
            // working exactly as before.
            //
            // Which swizzle: **not always `.xyz`** (confirmed 7/26 as a real, high-volume bug —
            // the single biggest cause of corpus-wide compile failures measured that day). A call
            // that's the *entire initializer* of a `<type> name = ...;` declaration needs a
            // swizzle matching *that* declared width, not a hardcoded float3 — real corpus example:
            // `float4 noise9 = tex3D(sampler_noisevol_hq, ...);` wants the full float4 (no swizzle
            // at all), but this function used to always append `.xyz` regardless, turning a
            // perfectly valid declaration into a width mismatch **that Prism's own translator
            // introduced**, not one that existed in the original preset text. `ret`'s own
            // declaration (`float3 ret = float3(0.0);`, in the wrapping template, not this body) is
            // exactly why `.xyz` was the right default for the common case this was originally
            // written for (`ret = tex2D(...);`) — it just wasn't the *only* case.
            if call.range.upperBound >= chars.count || chars[call.range.upperBound] != "." {
                switch declaredAssignmentWidth(beforeCallAt: call.range.lowerBound, in: chars) ?? defaultWidth {
                case 4: break // Full float4 wanted — no swizzle needed, keep the whole sample.
                case 3: result.append(".xyz")
                case 2: result.append(".xy")
                case 1: result.append(".x")
                default: result.append(".xyz") // Unrecognized width — the original, still-common-case default.
                }
            }
            cursor = call.range.upperBound
        }
        result.append(contentsOf: chars[cursor...])
        return result
    }

    /// If the texture call starting at `callStart` is the *entire initializer* of a
    /// `<type> name = ...;` declaration (`float4 noise9 = tex3D(...)`, `float3 x = tex2D(...)`,
    /// etc.), returns that declared type's component count (1/2/3/4) — scans backward from
    /// `callStart` past whitespace, an `=` (rejecting `==`/`<=`/`>=`/`!=`, which aren't
    /// assignment), an identifier (the variable name), and checks whether a `float`/`float1-4`
    /// keyword immediately precedes that identifier. `nil` for anything else (a bare `name =
    /// tex2D(...)` assignment to an already-declared variable, the call embedded in a larger
    /// expression, the very start of the shader body, etc.) — the caller falls back to its
    /// original float3 default for those, unchanged from before this function existed.
    private static func declaredAssignmentWidth(beforeCallAt callStart: Int, in chars: [Character]) -> Int? {
        func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        var i = callStart - 1
        func skipWhitespace() { while i >= 0, chars[i].isWhitespace { i -= 1 } }

        skipWhitespace()
        guard i >= 0, chars[i] == "=" else { return nil }
        // Reject `==`/`<=`/`>=`/`!=` — comparisons, not assignment.
        if i - 1 >= 0, ["<", ">", "!", "="].contains(chars[i - 1]) { return nil }
        i -= 1
        skipWhitespace()

        guard i >= 0, isIdentifierChar(chars[i]) else { return nil }
        while i >= 0, isIdentifierChar(chars[i]) { i -= 1 }
        skipWhitespace()

        for (keyword, width): (String, Int) in [("float4", 4), ("float3", 3), ("float2", 2), ("float1", 1), ("float", 1)] {
            let kw = Array(keyword)
            let start = i - kw.count + 1
            guard start >= 0, Array(chars[start...i]) == kw else { continue }
            // Reject a false match on a longer identifier's suffix (e.g. "myfloat3").
            guard start == 0 || !isIdentifierChar(chars[start - 1]) else { continue }
            return width
        }
        return nil
    }

    /// The small set of HLSL-vs-MSL naming mismatches Milkdrop shader code actually exercises
    /// (confirmed against the survey corpus) — `frac` really is just a rename (MSL's stdlib has
    /// `fract`), while `lerp`/`saturate`/`mul` are renamed to uniquely-prefixed names resolved by
    /// shim overloads in the compiled function's preamble (see MilkdropMetalRenderer.swift) rather
    /// than risking a redefinition clash if MSL's own stdlib happens to already define them.
    private static func renameIntrinsics(_ body: String) -> String {
        var text = body
        for (from, to) in [
            ("frac", "fract"),
            ("lerp", "milkdrop_lerp"),
            ("saturate", "milkdrop_saturate"),
            ("mul", "milkdrop_mul"),
            // HLSL's degenerate "vector of 1" type — a real (if uncommon) type in the corpus,
            // measured 7/25 at ~9% of remaining warp-shader compile failures. MSL has no such
            // type; a plain `float` is exactly equivalent (a 1-component vector *is* a scalar).
            ("float1", "float"),
            // Real Milkdrop presets occasionally declare `double`/`double3`/etc. (confirmed: two
            // real corpus files, "suksma - schlotkin(k).milk"'s warp_, `double3 ist =
            // GetBlur1(uv*1);`) — real Milkdrop compiles these through nVidia's Cg toolkit, whose
            // documented behavior is to treat `double`/`double2`-`double4` as plain aliases for
            // `float`/`float2`-`float4` on profiles without true double-precision support (which
            // Milkdrop's own ps_2_0/ps_3_0-era shader profiles never had) — not a distinct type
            // with different runtime behavior. MSL's own `double` is a *reserved but unimplemented*
            // keyword (forward-declared, never defined — "incomplete type" at the MSL compile
            // stage), so leaving it as-is would fail outright; renaming to `float`/`floatN` matches
            // what real Milkdrop itself actually does with these.
            ("double4", "float4"), ("double3", "float3"), ("double2", "float2"), ("double", "float"),
        ] {
            text = renameIdentifier(from, to: to, in: text)
        }
        // `static const float x = 1;`-style local constants — valid HLSL, not meaningfully
        // different from a plain local `const` for Milkdrop's usage (always a simple named
        // constant, never state persisting across calls), and MSL's `static` has different
        // function-local semantics — drop the keyword rather than translate it.
        text = text.replacingOccurrences(of: #"\bstatic\s+const\b"#, with: "const", options: .regularExpression)
        text = rewriteSingleArgumentMatrixConstructors(text)
        text = rewriteFloatModulo(text)
        return text
    }

    /// Rewrites HLSL's `%` — always floating-point modulo in HLSL/Cg shader math, with no separate
    /// integer type in the source language presets are authored against — into MSL's `fmod()`
    /// call. MSL's own `%` is integer-only ("invalid operands to binary expression ('float' and
    /// 'int')" at compile, ~400-450x in the 7/26 corpus scan). Unlike every other rewrite in this
    /// file, `%` is an infix operator with no comma/paren call-site delimiters to lean on, so this
    /// walks a small expression grammar — just enough to find each `%`'s operand boundaries
    /// (postfix chains, unary prefixes, nested parens/brackets/calls recursed into first, and
    /// `*`/`/`/`%`'s own left-associative chaining, e.g. `a*b%c` -> `fmod(a * b, c)` not
    /// `a*fmod(b,c)`) — rather than a single text substitution.
    ///
    /// Applied to the whole shader-body/helper-function/preamble-declaration text (this runs from
    /// `renameIntrinsics`, called on all three), not just isolated expressions, so it reassembles
    /// non-expression syntax (statements, braces, keywords, control flow) unchanged other than
    /// normalizing inter-token whitespace to a single space — always semantically safe in a
    /// C-family language, and necessary: dropping whitespace outright between two token runs with
    /// no operator between them (`float ret`, `return x`) would otherwise glue them into one
    /// invalid identifier.
    private static func rewriteFloatModulo(_ text: String) -> String {
        foldModuloChains(tokenizeForModulo(Array(text)))
    }

    private enum ModuloToken {
        case term(String)
        case mulOp(Character) // * / %
        case boundary(String) // any lower-precedence separator/keyword-breaking text, passed through
        /// A run of whitespace, preserved verbatim rather than collapsed to a single space — a
        /// real corpus preset can have a `#if`/`#else`/`#endif` preprocessor conditional *inside*
        /// `shader_body` (confirmed: "Mig_177.milk"'s `comp_`), which only works because the `#`
        /// starts its own physical line; collapsing every newline to `" "` (this file's original
        /// approach) silently merges that directive onto the same line as the code around it,
        /// turning a working `#if`/`#endif` into raw, invalid text the MSL preprocessor no longer
        /// recognizes as a directive at all (120x "expected expression" in a corpus re-scan).
        case whitespace(String)
    }

    private static func isModuloAtomChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "."
    }

    /// Extends a `while isModuloAtomChar` run to also swallow a scientific-notation exponent sign
    /// (`1e-5`, `2.4E+3`) — without this, the generic atom scan stops right after the `e`/`E` and
    /// the following `+`/`-` gets misread as a binary/unary operator, corrupting the literal.
    private static func consumeModuloAtomRun(_ chars: [Character], _ start: Int) -> Int {
        var j = start
        while j < chars.count, isModuloAtomChar(chars[j]) { j += 1 }
        if j > start, j < chars.count, (chars[j - 1] == "e" || chars[j - 1] == "E"), (chars[j] == "+" || chars[j] == "-") {
            var k = j + 1
            var sawDigit = false
            while k < chars.count, chars[k].isNumber { k += 1; sawDigit = true }
            if sawDigit { j = k }
        }
        return j
    }

    /// Consumes one balanced `(...)`/`[...]` group starting at `open`, recursing
    /// `rewriteFloatModulo` into its contents first — so a `%` nested inside a call's arguments or
    /// an index expression is rewritten before the group is treated as a single opaque term by the
    /// surrounding scan.
    private static func consumeModuloGroup(_ chars: [Character], _ open: Int) -> (text: String, end: Int) {
        let openChar = chars[open]
        let closeChar: Character = openChar == "(" ? ")" : "]"
        var depth = 1
        var j = open + 1
        while j < chars.count, depth > 0 {
            if chars[j] == openChar { depth += 1 } else if chars[j] == closeChar { depth -= 1 }
            j += 1
        }
        let inner = j > open + 1 ? String(chars[(open + 1)..<(j - 1)]) : ""
        return ("\(openChar)\(rewriteFloatModulo(inner))\(closeChar)", j)
    }

    /// Consumes one full postfix chain: an identifier/number run or a parenthesized group,
    /// followed by any number of `(args)`/`[index]` postfix pieces (`foo(a, b).xyz`, `arr[i].x`,
    /// `sampler.sample(smp, uv).xyz`, etc — the leading `.member`/`.sample` in that last example is
    /// already part of the initial atom run since `.` is itself an atom character).
    private static func consumeModuloPrimary(_ chars: [Character], _ start: Int) -> (text: String, end: Int) {
        var i = start
        var text: String
        if chars[i] == "(" || chars[i] == "[" {
            let (groupText, end) = consumeModuloGroup(chars, i)
            text = groupText
            i = end
        } else {
            let end = consumeModuloAtomRun(chars, i)
            text = String(chars[i..<end])
            i = end
        }
        while true {
            var j = i
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count, chars[j] == "(" || chars[j] == "[" else { break }
            let (groupText, end) = consumeModuloGroup(chars, j)
            text += groupText
            i = end
            var k = i
            while k < chars.count, chars[k].isWhitespace { k += 1 }
            guard k < chars.count, chars[k] == "." else { continue }
            let memberEnd = consumeModuloAtomRun(chars, k)
            text += String(chars[k..<memberEnd])
            i = memberEnd
        }
        return (text, i)
    }

    private static func matchesModuloOp(_ chars: [Character], _ i: Int, _ op: String) -> Bool {
        let opChars = Array(op)
        let end = i + opChars.count
        return end <= chars.count && Array(chars[i..<end]) == opChars
    }

    private static func tokenizeForModulo(_ chars: [Character]) -> [ModuloToken] {
        var tokens: [ModuloToken] = []
        var i = 0
        var expectOperand = true
        let twoCharOps = ["&&", "||", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "++", "--"]
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                var j = i
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                tokens.append(.whitespace(String(chars[i..<j])))
                i = j
                continue
            }
            if let op = twoCharOps.first(where: { matchesModuloOp(chars, i, $0) }) {
                tokens.append(.boundary(op))
                i += 2
                expectOperand = true
                continue
            }
            if c == "(" || c == "[" || isModuloAtomChar(c) {
                let (primaryText, end) = consumeModuloPrimary(chars, i)
                tokens.append(.term(primaryText))
                i = end
                expectOperand = false
                continue
            }
            switch c {
            case "%", "*", "/":
                tokens.append(.mulOp(c))
                i += 1
                expectOperand = true
            case "+", "-", "!", "~":
                if expectOperand {
                    var prefix = ""
                    var j = i
                    while j < chars.count, "+-!~".contains(chars[j]) {
                        prefix.append(chars[j])
                        j += 1
                        while j < chars.count, chars[j].isWhitespace { j += 1 }
                    }
                    guard j < chars.count, (chars[j] == "(" || chars[j] == "[" || isModuloAtomChar(chars[j])) else {
                        tokens.append(.boundary(prefix))
                        i = j
                        expectOperand = true
                        continue
                    }
                    let (primaryText, end) = consumeModuloPrimary(chars, j)
                    tokens.append(.term(prefix + primaryText))
                    i = end
                    expectOperand = false
                } else {
                    tokens.append(.boundary(String(c)))
                    i += 1
                    expectOperand = true
                }
            default:
                tokens.append(.boundary(String(c)))
                i += 1
                expectOperand = true
            }
        }
        return tokens
    }

    /// Folds a left-associative `*`/`/`/`%` chain left to right, wrapping only `%` sub-expressions
    /// in `fmod(...)` — e.g. `a * b % c / d` tokenizes as term/op pairs and folds to
    /// `fmod(a * b, c) / d`, matching what real left-to-right evaluation of the original HLSL would
    /// have produced. Whitespace between a chain's terms/operators is looked past (not treated as
    /// a chain-breaker — `a *\nb` is one chain, same as `a * b`) but its exact original text is
    /// preserved around any `*`/`/` left as-is; only a `%` span's own surrounding whitespace is
    /// discarded, since that span is being restructured into a function call anyway. Everywhere
    /// else (outside any chain), whitespace/boundary tokens are emitted completely unchanged — see
    /// `ModuloToken.whitespace`'s doc comment for why that fidelity matters.
    private static func foldModuloChains(_ tokens: [ModuloToken]) -> String {
        var pieces: [String] = []
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case .whitespace(let text), .boundary(let text):
                pieces.append(text)
                i += 1
            case .mulOp(let op):
                // Unreachable in well-formed input (a chain always starts from the `.term` branch
                // below) — pass through defensively rather than silently drop text.
                pieces.append(String(op))
                i += 1
            case .term(let firstTerm):
                var acc = firstTerm
                i += 1
                while true {
                    var j = i
                    while j < tokens.count, case .whitespace = tokens[j] { j += 1 }
                    guard j < tokens.count, case .mulOp(let op) = tokens[j] else { break }
                    var k = j + 1
                    var wsAfterOp = ""
                    while k < tokens.count, case .whitespace(let ws) = tokens[k] { wsAfterOp += ws; k += 1 }
                    guard k < tokens.count, case .term(let nextTerm) = tokens[k] else { break }
                    if op == "%" {
                        acc = "fmod(\(acc), \(nextTerm))"
                    } else {
                        var wsBeforeOp = ""
                        for t in tokens[i..<j] { if case .whitespace(let ws) = t { wsBeforeOp += ws } }
                        acc = "\(acc)\(wsBeforeOp.isEmpty ? " " : wsBeforeOp)\(op)\(wsAfterOp.isEmpty ? " " : wsAfterOp)\(nextTerm)"
                    }
                    i = k + 1
                }
                pieces.append(acc)
            }
        }
        return pieces.joined()
    }

    /// Real HLSL supports constructing a matrix from a single vector, packing its 4 components
    /// row-major (`float2x2(_qa)` -> row0=`_qa.xy`, row1=`_qa.zw`) — confirmed as a real, common
    /// pattern (397 real corpus presets build a rotation matrix straight from a `_qa`/`_qb` q-var
    /// bank this way, e.g. `uv = mul(uv, float2x2(_qa));`), not a hypothetical case. MSL's own
    /// `float2x2` constructor has no equivalent single-vector overload (only per-scalar or
    /// per-column-vector forms — "no matching conversion for functional-style cast from 'float4' to
    /// 'metal::float2x2'" at the MSL compile stage), so this rewrites the single-argument call site
    /// into the two-column form MSL does support. Only `float2x2` needs this: a `float3x3`/`float4x4`
    /// would need 9/16 components, more than a single `float4` bank can ever supply, and no such
    /// pattern was found in the corpus scan this was written against.
    private static func rewriteSingleArgumentMatrixConstructors(_ body: String) -> String {
        let chars = Array(body)
        let ctorChars = Array("float2x2")
        func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        var result = ""
        var i = 0
        while i < chars.count {
            let atBoundary = i == 0 || !isIdentifierChar(chars[i - 1])
            let end = i + ctorChars.count
            guard atBoundary, end < chars.count, Array(chars[i..<end]) == ctorChars, !isIdentifierChar(chars[end]) else {
                result.append(chars[i])
                i += 1
                continue
            }
            var j = end
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count, chars[j] == "(" else {
                result.append(chars[i])
                i += 1
                continue
            }
            var depth = 1
            var k = j + 1
            while k < chars.count, depth > 0 {
                if chars[k] == "(" { depth += 1 } else if chars[k] == ")" { depth -= 1 }
                k += 1
            }
            guard depth == 0 else {
                result.append(chars[i])
                i += 1
                continue
            }
            let argsText = String(chars[(j + 1)..<(k - 1)])
            let args = splitTopLevelArguments(argsText)
            if args.count == 1 {
                let arg = args[0].trimmingCharacters(in: .whitespaces)
                result.append("float2x2((\(arg)).xy, (\(arg)).zw)")
            } else {
                result.append(contentsOf: chars[i..<k])
            }
            i = k
        }
        return result
    }

    /// Word-boundary-safe identifier rename (so `saturate(` renames but `mysaturate(`/`saturated`
    /// don't) — `NSRegularExpression`'s `\b` already does this correctly for ASCII identifiers.
    private static func renameIdentifier(_ from: String, to: String, in text: String) -> String {
        text.replacingOccurrences(of: "\\b\(from)\\b", with: to, options: .regularExpression)
    }
}
