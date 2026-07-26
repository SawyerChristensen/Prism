//
//  MilkdropPresetFile.swift
//  Prism
//
//  Parses the subset of Milkdrop's ".milk" preset format Prism's pipeline actually needs: the
//  top-level `key=value` constants that seed a preset's wave state (nWaveMode, fWaveScale,
//  fWaveSmoothing, fWaveParam, wave_x/y/r/g/b), the numbered `per_frame_N=`/`per_frame_init_N=`/
//  `per_pixel_N=` lines, up to 4 custom shapes' `shapecode_N_*` constants plus their
//  `shape_N_init*`/`shape_N_per_frame*` code, and up to 4 custom waveforms' `wavecode_N_*`
//  constants plus their `wave_N_init*`/`wave_N_per_frame*`/`wave_N_per_point*` code (see
//  MilkdropCustomWaveform.swift) — all of which get concatenated in numeric order into expression
//  programs (see MilkdropExpressionEvaluator.swift; `per_pixel_N=` specifically feeds
//  MilkdropPerPixelMesh.swift, re-evaluated per warp-mesh vertex rather than once per frame). Note
//  the shape/wave code slots use a *different* numbering convention than the main preset's:
//  `shape_0_init1`/`wave_0_init1`, not `shape_0_init_1`/`wave_0_init_1` — confirmed against
//  projectM's PresetFileParser::GetCode, which appends the slot number directly with no separating
//  underscore. `warp_N=`/`comp_N=` (real HLSL, not NS-EEL — same numbering as `per_frame_N`) are
//  parsed too, handed to MilkdropShaderTranslator/MilkdropMetalRenderer rather than the expression
//  evaluator; `compositeShaderSource` is compiled and run for real, `warpShaderSource` is parsed
//  but not yet compiled (see MilkdropVisualizerModel's doc comment on why). Everything else in the
//  file — motion vectors, borders, sprite/`image=` textures — is read past but not interpreted;
//  Prism doesn't render the full preset visual (see MilkdropWaveform.swift's header
//  for that scope decision).
//
//  Format reference: a flat INI-style file, one `[presetNN]` section (Prism only ever reads the
//  first), lines are `key=value` with no quoting. Milkdrop's own parser matches keys
//  case-insensitively (real presets in the wild mix `fWaveScale`/`fwavescale`/`FWAVESCALE`), so
//  keys are lowercased on both the writing and reading side here to match. Constant values
//  sometimes carry a trailing `;` left over from copy-pasting an equation fragment (e.g.
//  `warp=0;`, seen in projectM's own 001-line.milk test preset) — stripped before numeric parsing,
//  same as Milkdrop's own tolerant number parsing would do.
//

import Foundation

enum MilkdropPresetFileError: Error {
    case unreadable
}

/// One `shapecode_N_*` custom shape: a per-frame-scripted polygon/circle overlay, independent of
/// the main preset's waveform. Defaults match projectM's CustomShape.cpp (the reference this was
/// ported from) exactly, since a preset that only sets a few keys relies on the rest of these.
struct MilkdropShapePreset {
    var enabled: Bool = false
    var sides: Int = 4
    var additive: Bool = false
    var thickOutline: Bool = false
    /// `num_inst`: how many independently-scripted copies to draw (see MilkdropShapeState.swift).
    var numInst: Int = 1
    var x: Float = 0.5
    var y: Float = 0.5
    var rad: Float = 0.1
    var ang: Float = 0.0
    /// `textured=1` swaps the flat gradient fill for a texture sample (see CustomShape.cpp:145-201
    /// and MilkdropMetalRenderer.swift's shapeTextured* pipelines) — the per-vertex color above
    /// still applies, multiplied against the sampled texel.
    var textured: Bool = false
    /// `tex_ang`/`tex_zoom`: the fill UVs' own independent rotation/scale, separate from the
    /// polygon's own `ang`/`rad`.
    var texAng: Float = 0.0
    var texZoom: Float = 1.0
    /// projectM's own addition: an explicit texture name to sample instead of the main/feedback
    /// texture. Measured 0/9,795 in the real corpus (see TO DO.md's Phase 2 notes) — parsed for
    /// completeness, but effectively always empty in practice.
    var image: String = ""
    /// Center-vertex color of the fill gradient.
    var r: Float = 1.0
    var g: Float = 0.0
    var b: Float = 0.0
    var a: Float = 1.0
    /// Rim-vertex color of the fill gradient (a real per-vertex gradient in Milkdrop, not a flat
    /// fill — see MilkdropMetalRenderer.swift's shape draw path).
    var r2: Float = 0.0
    var g2: Float = 1.0
    var b2: Float = 0.0
    var a2: Float = 0.0
    /// Outline color/alpha. `borderA <= 0` (Milkdrop's default) means no outline is drawn at all.
    var borderR: Float = 1.0
    var borderG: Float = 1.0
    var borderB: Float = 1.0
    var borderA: Float = 0.0
    /// Concatenated `shape_N_init*=` lines — run once at load, same role as the main preset's
    /// `perFrameInitProgram`.
    var initProgram: String = ""
    /// Concatenated `shape_N_per_frame*=` lines — re-evaluated once per instance, every frame.
    var perFrameProgram: String = ""
}

/// One `wavecode_N_*` custom waveform: a per-point-scripted line/dot trace, independent of the
/// main preset's built-in `nWaveMode` line (see MilkdropCustomWaveform.swift). Defaults match
/// projectM's CustomWaveform.hpp exactly. Note `x`/`y` fields exist on CustomWaveform.hpp too but
/// are dead — never read from the preset file nor used in CustomWaveform::Draw upstream — so
/// they're deliberately not ported here.
struct MilkdropCustomWavePreset {
    var enabled: Bool = false
    /// Clamped against the actual PCM/spectrum buffer length at render time — see
    /// MilkdropCustomWaveform.swift's `resolvePoints`.
    var samples: Int = 512
    /// Sample-offset separation between the L/R channels' windows into the PCM buffer (PCM mode
    /// only — ignored in spectrum mode, matching CustomWaveform.cpp exactly).
    var sep: Int = 0
    var scaling: Float = 1.0
    var smoothing: Float = 0.5
    var r: Float = 1.0
    var g: Float = 1.0
    var b: Float = 1.0
    var a: Float = 1.0
    /// Spectrum (FFT magnitude) data vs. raw PCM waveform data.
    var spectrum: Bool = false
    var useDots: Bool = false
    var drawThick: Bool = false
    var additive: Bool = false
    /// Concatenated `wave_N_init*=` lines — run once at load, in the per-frame code's own
    /// variable environment (shares state with `perFrameProgram`, not a separate scope).
    var initProgram: String = ""
    /// Concatenated `wave_N_per_frame*=` lines — re-evaluated once per rendered frame.
    var perFrameProgram: String = ""
    /// Concatenated `wave_N_per_point*=` lines — re-evaluated once per waveform vertex, every
    /// frame.
    var perPointProgram: String = ""
}

struct MilkdropPresetFile {
    var waveMode: Int = 0
    var waveScale: Float = 1.0
    var waveSmoothing: Float = 0.75
    var waveParam: Float = 0.0
    var waveX: Float = 0.5
    var waveY: Float = 0.5
    var waveR: Float = 1.0
    var waveG: Float = 1.0
    var waveB: Float = 1.0
    var waveAlpha: Float = 0.8
    /// Static per-frame-loop starting values for the feedback warp transform (zoom/rotate/stretch/
    /// translate — see MilkdropVisualizerView.swift's warpParams). Defaults and key names (`zoom`,
    /// `rot`, `cx`/`cy`, `dx`/`dy`, `sx`/`sy`, `warp`, `fDecay`, `fZoomExponent`) confirmed against
    /// projectM's PresetState.cpp/.hpp. A per-frame script that reads/writes these (e.g.
    /// `rot=rot+0.01;`) starts from whichever of these values is in effect, same as wave_x/y do.
    var zoom: Float = 1.0
    var zoomExponent: Float = 1.0
    var rot: Float = 0.0
    var rotCX: Float = 0.5
    var rotCY: Float = 0.5
    var xPush: Float = 0.0
    var yPush: Float = 0.0
    var warpAmount: Float = 1.0
    var stretchX: Float = 1.0
    var stretchY: Float = 1.0
    var decay: Float = 0.98
    /// Not per-frame-scriptable (absent from projectM's PerFrameContext variable list) — a plain
    /// load-time constant that only shapes the warp-wiggle animation's speed/scale.
    var warpAnimSpeed: Float = 1.0
    var warpScale: Float = 1.0
    /// Border.cpp's two nested-square outlines: an outer ring at the screen edge and an inner ring
    /// just inside it, each independently sized/colored. Both `*_a <= 0` (the real defaults) means
    /// no border at all — `ob_r/g/b`/`ib_r/g/b` are per-frame-scriptable (PerFrameContext.cpp's
    /// `ob_*`/`ib_*` REG_VARs), same treatment as zoom/rot above. Defaults confirmed against
    /// PresetState.hpp exactly (inner border defaults to a visible gray *color* even though its
    /// alpha of 0 keeps it invisible by default — a preset that only sets `ib_a` gets that gray,
    /// not black).
    var outerBorderSize: Float = 0.01
    var outerBorderR: Float = 0.0
    var outerBorderG: Float = 0.0
    var outerBorderB: Float = 0.0
    var outerBorderA: Float = 0.0
    var innerBorderSize: Float = 0.01
    var innerBorderR: Float = 0.25
    var innerBorderG: Float = 0.25
    var innerBorderB: Float = 0.25
    var innerBorderA: Float = 0.0
    /// `bDarkenCenter` — gates a small, fixed-size dark smudge drawn at screen center
    /// (DarkenCenter.cpp). Per-frame-scriptable as `darken_center` (`> 0` means on), same as the
    /// border fields above.
    var darkenCenter: Bool = false
    /// Concatenated `per_frame_N=` lines, in ascending numeric order. Empty if the preset defines
    /// none (common for the older, non-per-frame-scripted presets).
    var perFrameProgram: String = ""
    /// Concatenated `per_frame_init_N=` lines — run once, before `perFrameProgram`'s first
    /// evaluation, to seed any custom variables the per-frame program reads (e.g. `SPEED=10;`).
    var perFrameInitProgram: String = ""
    /// Concatenated `per_pixel_N=` lines, in ascending numeric order — the scripted counterpart to
    /// the plain per-frame zoom/rot/warp transform, re-evaluated at every warp-mesh vertex (see
    /// MilkdropPerPixelMesh.swift). Confirmed against projectM's `PresetState::Initialize`
    /// (`parsedFile.GetCode("per_pixel_")`) — same code-family mechanics as `per_frame_`, just a
    /// different key prefix, so parsed with the same >=1000-is-a-comment convention as that family.
    var perPixelProgram: String = ""
    /// Always 4 elements (indices 0-3), matching Milkdrop's `CustomShapeCount`. A shape with no
    /// `shapecode_N_*` keys at all in the file stays at `MilkdropShapePreset()`'s defaults —
    /// `enabled == false`, so it's simply skipped at render time.
    var shapes: [MilkdropShapePreset] = Array(repeating: MilkdropShapePreset(), count: 4)
    /// Always 4 elements (indices 0-3), matching Milkdrop's `CustomWaveformCount`. Same
    /// disabled-by-default/no-keys-means-skip pattern as `shapes` above.
    var customWaves: [MilkdropCustomWavePreset] = Array(repeating: MilkdropCustomWavePreset(), count: 4)
    /// Concatenated `warp_N=`/`comp_N=` lines (same underscore-before-digit numbering as
    /// `per_frame_N`, confirmed against projectM's `GetCode("warp_")`/`GetCode("comp_")` in
    /// PresetState.cpp) — real HLSL shader code, not NS-EEL expressions, handed to
    /// MilkdropShaderTranslator rather than MilkdropExpressionProgram. Empty for the majority of
    /// presets (only the newer "shader-based" Milkdrop 2.0+ format has these at all). Each line's
    /// leading backtick — present on every shader-code line in real preset files, e.g.
    /// `` warp_1=`sampler sampler_fw_noisevol_hq; `` — is stripped here, same as projectM's own
    /// `GetCode` does, rather than left for the translator to deal with.
    var warpShaderSource: String = ""
    var compositeShaderSource: String = ""

    /// `MILKDROP_PRESET_VERSION` — absent (default 100, matching PresetState.hpp's own field
    /// initializer) or below 200 means a Milkdrop 1.x-format preset, predating `comp_N=`/`warp_N=`
    /// shader syntax entirely. Confirmed against PresetState::Initialize's exact version-gating
    /// logic — used here only to pick the final-composite path (see `usesOldStyleFinalComposite`
    /// below); Prism doesn't otherwise distinguish PSVERSION/PSVERSION_WARP/PSVERSION_COMP's own
    /// finer-grained versioning, since nothing else in this port depends on it.
    var presetVersion: Int = 100
    /// True for the ~15.8%-of-corpus (measured 7/25) "old-school" presets with no composite shader
    /// at all — real Milkdrop's FinalComposite runs VideoEcho+Filters for these instead of a
    /// `comp_N=` shader (see MilkdropOldStyleComposite.swift/MilkdropMetalRenderer.swift). A preset
    /// with `presetVersion >= 200` but genuinely no `comp_N=` code either (rare — a modern-format
    /// preset that just doesn't customize its composite step) is NOT this case: real Milkdrop treats
    /// that as "use the default `ret = tex2D(sampler_main,uv).xyz` passthrough shader", exactly
    /// matching Prism's own existing behavior when `compositeShaderSource` is empty for that reason.
    var usesOldStyleFinalComposite: Bool { presetVersion < 200 }
    /// `fGammaAdj` — a brightness multiplier applied every final-composite frame for an old-style
    /// preset (VideoEcho.cpp), not just an optional adjustment: even the default (2.0, not 1.0)
    /// means every old-style preset's output is doubled in brightness relative to a flat passthrough.
    var gammaAdj: Float = 2.0
    /// `fVideoEchoZoom`/`fVideoEchoAlpha`/`nVideoEchoOrientation` — blends a zoomed/flipped copy of
    /// the frame on top of itself. `videoEchoAlpha <= 0` (the default) means no echo copy at all,
    /// just the gamma-adjusted frame (VideoEcho::DrawGammaAdjustment vs. DrawVideoEcho upstream).
    var videoEchoZoom: Float = 2.0
    var videoEchoAlpha: Float = 0.0
    /// 0-3: bit 0 flips U, bit 1 flips V (VideoEcho.cpp's `orientation % 2`/`orientation >= 2`).
    var videoEchoOrientation: Int = 0
    /// `bBrighten`/`bDarken`/`bSolarize`/`bInvert` — Filters.cpp's classic Milkdrop 1 blend-equation
    /// tricks, applied in this fixed order (each operates on whatever VideoEcho already drew, not
    /// independently) only when `usesOldStyleFinalComposite`.
    var brighten: Bool = false
    var darken: Bool = false
    var solarize: Bool = false
    var invert: Bool = false

    init(contentsOf url: URL) throws {
        // Presets in the wild are inconsistently encoded (Milkdrop predates any UTF-8 convention),
        // so fall back to Latin-1 — which, unlike UTF-8, never fails to decode a byte stream —
        // rather than rejecting an otherwise-parseable file outright.
        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = latin1
        } else {
            throw MilkdropPresetFileError.unreadable
        }
        self.init(text: text)
    }

    init(text: String) {
        var constants: [String: String] = [:]
        var perFrameLines: [(index: Int, text: String)] = []
        var perFrameInitLines: [(index: Int, text: String)] = []
        var perPixelLines: [(index: Int, text: String)] = []
        var shapeConstants: [Int: [String: String]] = [:]
        var shapeInitLines: [Int: [(index: Int, text: String)]] = [:]
        var shapePerFrameLines: [Int: [(index: Int, text: String)]] = [:]
        var waveConstants: [Int: [String: String]] = [:]
        var waveInitLines: [Int: [(index: Int, text: String)]] = [:]
        var wavePerFrameLines: [Int: [(index: Int, text: String)]] = [:]
        var wavePerPointLines: [Int: [(index: Int, text: String)]] = [:]
        var warpLines: [(index: Int, text: String)] = []
        var compLines: [(index: Int, text: String)] = []

        // Every warp_N/comp_N line's value starts with a literal backtick in real preset files —
        // strip it here so downstream code never has to think about it again.
        func stripBacktick(_ raw: String) -> String {
            raw.hasPrefix("`") ? String(raw.dropFirst()) : raw
        }

        // Real .milk files are Windows-authored and near-universally CRLF-terminated (confirmed
        // against this app's actual preset corpus — every sampled file used CRLF). Splitting on
        // the Character "\n" alone silently parses *nothing*: Swift's String treats "\r\n" as one
        // Character (an extended grapheme cluster — `"\r\n".count == 1`), so a literal "\n"
        // separator never matches inside a CRLF file, and the entire file comes back as a single
        // "line" that can't be parsed as any recognized key. `isNewline` correctly treats "\r\n"
        // (as well as a lone "\n" or old-Mac lone "\r") as one line break either way.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("["), let eq = line.firstIndex(of: "=") else { continue }

            let key = String(line[line.startIndex..<eq]).lowercased()
            let value = String(line[line.index(after: eq)...])

            // Milkdrop reserves indices >= 1000 on either numbered-line family for human-readable
            // comments shown in preset editors (see the "// simple wave" examples in projectM's
            // test presets), not executable code — skip those so they don't get parsed as
            // expressions. Check the longer prefix first so `per_frame_init_` lines don't get
            // misread as `per_frame_` ones (`per_frame_init_1` would otherwise parse as key
            // `per_frame_` with suffix `init_1`, which isn't a valid index and gets silently
            // dropped instead of ending up in the wrong program).
            if key.hasPrefix("per_frame_init_"), let n = Int(key.dropFirst("per_frame_init_".count)) {
                if n < 1000 {
                    perFrameInitLines.append((n, value))
                }
            } else if key.hasPrefix("per_frame_"), let n = Int(key.dropFirst("per_frame_".count)) {
                if n < 1000 {
                    perFrameLines.append((n, value))
                }
            } else if key.hasPrefix("per_pixel_"), let n = Int(key.dropFirst("per_pixel_".count)) {
                if n < 1000 {
                    perPixelLines.append((n, value))
                }
            } else if key.hasPrefix("warp_"), let n = Int(key.dropFirst("warp_".count)) {
                // No >= 1000-is-a-comment convention here (unlike per_frame_ above) — that's a
                // per_frame-specific preset-editor convention, and a real multi-hundred-line
                // shader could plausibly reach index 1000 legitimately; safer not to guess.
                warpLines.append((n, stripBacktick(value)))
            } else if key.hasPrefix("comp_"), let n = Int(key.dropFirst("comp_".count)) {
                compLines.append((n, stripBacktick(value)))
            } else if key.hasPrefix("shapecode_"), let (idx, subKey) = splitIndexedKey(key, after: "shapecode_"), (0..<4).contains(idx) {
                shapeConstants[idx, default: [:]][subKey] = value
            } else if key.hasPrefix("shape_"), let (idx, codeKey) = splitIndexedKey(key, after: "shape_"), (0..<4).contains(idx) {
                // No underscore between the code-family name and its slot number here (unlike
                // `per_frame_N` above) — see this file's header for why.
                if codeKey.hasPrefix("init"), let n = Int(codeKey.dropFirst("init".count)) {
                    shapeInitLines[idx, default: []].append((n, value))
                } else if codeKey.hasPrefix("per_frame"), let n = Int(codeKey.dropFirst("per_frame".count)) {
                    shapePerFrameLines[idx, default: []].append((n, value))
                }
            } else if key.hasPrefix("wavecode_"), let (idx, subKey) = splitIndexedKey(key, after: "wavecode_"), (0..<4).contains(idx) {
                waveConstants[idx, default: [:]][subKey] = value
            } else if key.hasPrefix("wave_"), let (idx, codeKey) = splitIndexedKey(key, after: "wave_"), (0..<4).contains(idx) {
                // Same no-underscore-before-slot-number convention as shape_N above — confirmed
                // against projectM's CustomWaveform::Initialize (`wavePrefix = "wave_" + index +
                // "_"`, then `GetCode(wavePrefix + "init")`/`"per_frame"`/`"per_point"`). Doesn't
                // collide with the un-indexed `wave_x`/`wave_y`/`wave_r`/etc. top-level constants
                // (see MilkdropPresetFile's other `float("wave_x", ...)` reads) — those have no
                // digit immediately after `wave_`, so `splitIndexedKey` returns nil for them and
                // this branch is never entered.
                if codeKey.hasPrefix("init"), let n = Int(codeKey.dropFirst("init".count)) {
                    waveInitLines[idx, default: []].append((n, value))
                } else if codeKey.hasPrefix("per_frame"), let n = Int(codeKey.dropFirst("per_frame".count)) {
                    wavePerFrameLines[idx, default: []].append((n, value))
                } else if codeKey.hasPrefix("per_point"), let n = Int(codeKey.dropFirst("per_point".count)) {
                    wavePerPointLines[idx, default: []].append((n, value))
                }
            } else {
                constants[key] = value
            }
        }

        perFrameLines.sort { $0.index < $1.index }
        perFrameProgram = perFrameLines.map(\.text).joined(separator: "\n")
        perFrameInitLines.sort { $0.index < $1.index }
        perFrameInitProgram = perFrameInitLines.map(\.text).joined(separator: "\n")
        perPixelLines.sort { $0.index < $1.index }
        perPixelProgram = perPixelLines.map(\.text).joined(separator: "\n")
        warpLines.sort { $0.index < $1.index }
        warpShaderSource = warpLines.map(\.text).joined(separator: "\n")
        compLines.sort { $0.index < $1.index }
        compositeShaderSource = compLines.map(\.text).joined(separator: "\n")

        func cleaned(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasSuffix(";") { s.removeLast() }
            return s.trimmingCharacters(in: .whitespaces)
        }
        func floatIn(_ dict: [String: String], _ key: String, _ fallback: Float) -> Float {
            dict[key].map(cleaned).flatMap(Float.init) ?? fallback
        }
        func intIn(_ dict: [String: String], _ key: String, _ fallback: Int) -> Int {
            dict[key].map(cleaned).flatMap { Int(Double($0) ?? Double(fallback)) } ?? fallback
        }
        func boolIn(_ dict: [String: String], _ key: String, _ fallback: Bool) -> Bool {
            dict[key].map(cleaned).flatMap { Double($0) }.map { $0 != 0 } ?? fallback
        }
        func float(_ key: String, _ fallback: Float) -> Float { floatIn(constants, key, fallback) }
        func int(_ key: String, _ fallback: Int) -> Int { intIn(constants, key, fallback) }

        waveMode = int("nwavemode", waveMode)
        waveScale = float("fwavescale", waveScale)
        waveSmoothing = float("fwavesmoothing", waveSmoothing)
        waveParam = float("fwaveparam", waveParam)
        waveX = float("wave_x", waveX)
        waveY = float("wave_y", waveY)
        waveR = float("wave_r", waveR)
        waveG = float("wave_g", waveG)
        waveB = float("wave_b", waveB)
        waveAlpha = float("fwavealpha", waveAlpha)

        zoom = float("zoom", zoom)
        zoomExponent = float("fzoomexponent", zoomExponent)
        rot = float("rot", rot)
        rotCX = float("cx", rotCX)
        rotCY = float("cy", rotCY)
        xPush = float("dx", xPush)
        yPush = float("dy", yPush)
        warpAmount = float("warp", warpAmount)
        stretchX = float("sx", stretchX)
        stretchY = float("sy", stretchY)
        decay = float("fdecay", decay)
        warpAnimSpeed = float("fwarpanimspeed", warpAnimSpeed)
        warpScale = float("fwarpscale", warpScale)

        outerBorderSize = float("ob_size", outerBorderSize)
        outerBorderR = float("ob_r", outerBorderR)
        outerBorderG = float("ob_g", outerBorderG)
        outerBorderB = float("ob_b", outerBorderB)
        outerBorderA = float("ob_a", outerBorderA)
        innerBorderSize = float("ib_size", innerBorderSize)
        innerBorderR = float("ib_r", innerBorderR)
        innerBorderG = float("ib_g", innerBorderG)
        innerBorderB = float("ib_b", innerBorderB)
        innerBorderA = float("ib_a", innerBorderA)
        darkenCenter = boolIn(constants, "bdarkencenter", darkenCenter)

        presetVersion = int("milkdrop_preset_version", presetVersion)
        gammaAdj = float("fgammaadj", gammaAdj)
        videoEchoZoom = float("fvideoechozoom", videoEchoZoom)
        videoEchoAlpha = float("fvideoechoalpha", videoEchoAlpha)
        videoEchoOrientation = int("nvideoechoorientation", videoEchoOrientation)
        brighten = boolIn(constants, "bbrighten", brighten)
        darken = boolIn(constants, "bdarken", darken)
        solarize = boolIn(constants, "bsolarize", solarize)
        invert = boolIn(constants, "binvert", invert)

        shapes = (0..<4).map { idx in
            let dict = shapeConstants[idx] ?? [:]
            var shape = MilkdropShapePreset()
            shape.enabled = boolIn(dict, "enabled", shape.enabled)
            shape.sides = intIn(dict, "sides", shape.sides)
            shape.additive = boolIn(dict, "additive", shape.additive)
            shape.thickOutline = boolIn(dict, "thickoutline", shape.thickOutline)
            shape.numInst = intIn(dict, "num_inst", shape.numInst)
            shape.x = floatIn(dict, "x", shape.x)
            shape.y = floatIn(dict, "y", shape.y)
            shape.rad = floatIn(dict, "rad", shape.rad)
            shape.ang = floatIn(dict, "ang", shape.ang)
            shape.textured = boolIn(dict, "textured", shape.textured)
            shape.texAng = floatIn(dict, "tex_ang", shape.texAng)
            shape.texZoom = floatIn(dict, "tex_zoom", shape.texZoom)
            shape.image = dict["image"].map(cleaned) ?? shape.image
            shape.r = floatIn(dict, "r", shape.r)
            shape.g = floatIn(dict, "g", shape.g)
            shape.b = floatIn(dict, "b", shape.b)
            shape.a = floatIn(dict, "a", shape.a)
            shape.r2 = floatIn(dict, "r2", shape.r2)
            shape.g2 = floatIn(dict, "g2", shape.g2)
            shape.b2 = floatIn(dict, "b2", shape.b2)
            shape.a2 = floatIn(dict, "a2", shape.a2)
            shape.borderR = floatIn(dict, "border_r", shape.borderR)
            shape.borderG = floatIn(dict, "border_g", shape.borderG)
            shape.borderB = floatIn(dict, "border_b", shape.borderB)
            shape.borderA = floatIn(dict, "border_a", shape.borderA)

            let initLines = (shapeInitLines[idx] ?? []).sorted { $0.index < $1.index }
            shape.initProgram = initLines.map(\.text).joined(separator: "\n")
            let frameLines = (shapePerFrameLines[idx] ?? []).sorted { $0.index < $1.index }
            shape.perFrameProgram = frameLines.map(\.text).joined(separator: "\n")
            return shape
        }

        customWaves = (0..<4).map { idx in
            let dict = waveConstants[idx] ?? [:]
            var wave = MilkdropCustomWavePreset()
            wave.enabled = boolIn(dict, "enabled", wave.enabled)
            wave.samples = intIn(dict, "samples", wave.samples)
            wave.sep = intIn(dict, "sep", wave.sep)
            wave.scaling = floatIn(dict, "scaling", wave.scaling)
            wave.smoothing = floatIn(dict, "smoothing", wave.smoothing)
            wave.r = floatIn(dict, "r", wave.r)
            wave.g = floatIn(dict, "g", wave.g)
            wave.b = floatIn(dict, "b", wave.b)
            wave.a = floatIn(dict, "a", wave.a)
            wave.spectrum = boolIn(dict, "bspectrum", wave.spectrum)
            wave.useDots = boolIn(dict, "busedots", wave.useDots)
            wave.drawThick = boolIn(dict, "bdrawthick", wave.drawThick)
            wave.additive = boolIn(dict, "badditive", wave.additive)

            let initLines = (waveInitLines[idx] ?? []).sorted { $0.index < $1.index }
            wave.initProgram = initLines.map(\.text).joined(separator: "\n")
            let frameLines = (wavePerFrameLines[idx] ?? []).sorted { $0.index < $1.index }
            wave.perFrameProgram = frameLines.map(\.text).joined(separator: "\n")
            let pointLines = (wavePerPointLines[idx] ?? []).sorted { $0.index < $1.index }
            wave.perPointProgram = pointLines.map(\.text).joined(separator: "\n")
            return wave
        }
    }
}

/// Splits a lowercased key like `shapecode_0_sides` (after stripping the `shapecode_` prefix into
/// `0_sides`) into its shape index and the remaining sub-key (`sides`). Returns nil for a
/// malformed key (no second underscore, or a non-numeric index) rather than crashing.
private func splitIndexedKey(_ key: String, after prefix: String) -> (index: Int, rest: String)? {
    let remainder = key.dropFirst(prefix.count)
    guard let underscore = remainder.firstIndex(of: "_"), let index = Int(remainder[remainder.startIndex..<underscore]) else {
        return nil
    }
    return (index, String(remainder[remainder.index(after: underscore)...]))
}
