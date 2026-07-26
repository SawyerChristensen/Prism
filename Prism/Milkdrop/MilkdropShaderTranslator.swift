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

        var source = stripSamplerStateBlocks(hlslSource)
        guard let bodyRange = extractShaderBody(&source) else { return nil }
        let rawBody = String(source[bodyRange])

        guard let textures = discoverTextures(in: rawBody) else { return nil }

        var body = rewriteTextureSampleCalls(rawBody, textures: textures)
        body = renameIntrinsics(body)

        return Result(body: body, textures: textures)
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
    private static func discoverTextures(in body: String) -> [TextureBinding]? {
        var seen: [String: TextureBinding] = [:]
        var order: [String] = []

        for call in scanTextureCalls(body) {
            if let implicit = implicitTextureFunctions[call.function] {
                if seen[implicit.name] == nil {
                    seen[implicit.name] = TextureBinding(
                        declaredName: implicit.name, resource: implicit.resource,
                        filter: .linear, wrap: .clampToEdge, isVolume: false
                    )
                    order.append(implicit.name)
                }
                continue
            }
            guard let name = call.arguments.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            if seen[name] != nil { continue }
            guard let binding = classify(declaredName: name, isVolume: call.function == "tex3D") else { return nil }
            seen[name] = binding
            order.append(name)
        }
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
    private static func rewriteTextureSampleCalls(_ body: String, textures: [TextureBinding]) -> String {
        let chars = Array(body)
        let calls = scanTextureCalls(body)
        guard !calls.isEmpty else { return body }

        var result = ""
        var cursor = 0
        for call in calls {
            result.append(contentsOf: chars[cursor..<call.range.lowerBound])
            let samplerName: String
            let remainingArgs: String
            if let implicit = implicitTextureFunctions[call.function] {
                // GetPixel(uv)/GetBlurN(uv): the sampler identifier is implied by which function
                // was called, not parsed from an argument — every argument present is the "uv".
                samplerName = implicit.name
                remainingArgs = call.arguments.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            } else {
                samplerName = call.arguments.first?.trimmingCharacters(in: .whitespaces) ?? ""
                remainingArgs = call.arguments.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            }
            result.append("\(samplerName).sample(\(samplerName)_smp, \(remainingArgs))")
            // HLSL's tex2D/tex3D return a float4, and real preset code routinely relies on HLSL's
            // implicit float4->float3 narrowing conversion when assigning straight into a float3
            // (`float3 x = tex2D(...);`, `ret = tex2D(...);` where `ret` is float3 — both verbatim
            // patterns in the survey corpus) — MSL has no implicit vector-narrowing conversion at
            // all, so that assignment simply fails to compile without an explicit swizzle. If the
            // original call isn't already explicitly swizzled (`.xyz`/`.rgb`/`.a`/etc immediately
            // follows in the source), append `.xyz` here to reproduce what HLSL did silently;
            // leave an already-swizzled call alone so `tex2D(sampler, uv).a` keeps working exactly
            // as before (`.xyz` has no `.a` component, so blindly appending it would break that
            // call instead of fixing anything).
            if call.range.upperBound >= chars.count || chars[call.range.upperBound] != "." {
                result.append(".xyz")
            }
            cursor = call.range.upperBound
        }
        result.append(contentsOf: chars[cursor...])
        return result
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
        ] {
            text = renameIdentifier(from, to: to, in: text)
        }
        // `static const float x = 1;`-style local constants — valid HLSL, not meaningfully
        // different from a plain local `const` for Milkdrop's usage (always a simple named
        // constant, never state persisting across calls), and MSL's `static` has different
        // function-local semantics — drop the keyword rather than translate it.
        text = text.replacingOccurrences(of: #"\bstatic\s+const\b"#, with: "const", options: .regularExpression)
        return text
    }

    /// Word-boundary-safe identifier rename (so `saturate(` renames but `mysaturate(`/`saturated`
    /// don't) — `NSRegularExpression`'s `\b` already does this correctly for ASCII identifiers.
    private static func renameIdentifier(_ from: String, to: String, in text: String) -> String {
        text.replacingOccurrences(of: "\\b\(from)\\b", with: to, options: .regularExpression)
    }
}
