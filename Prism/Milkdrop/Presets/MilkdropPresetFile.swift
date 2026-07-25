//
//  MilkdropPresetFile.swift
//  Prism
//
//  Parses the subset of Milkdrop's ".milk" preset format Prism's pipeline actually needs: the
//  top-level `key=value` constants that seed a preset's wave state (nWaveMode, fWaveScale,
//  fWaveSmoothing, fWaveParam, wave_x/y/r/g/b), the numbered `per_frame_N=`/`per_frame_init_N=`
//  lines, and up to 4 custom shapes' `shapecode_N_*` constants plus their `shape_N_init*`/
//  `shape_N_per_frame*` code — all of which get concatenated in numeric order into expression
//  programs (see MilkdropExpressionEvaluator.swift). Note the shape code slots use a *different*
//  numbering convention than the main preset's: `shape_0_init1`, not `shape_0_init_1` — confirmed
//  against projectM's PresetFileParser::GetCode, which appends the slot number directly with no
//  separating underscore. Everything else in the file — warp/composite shaders, custom waveforms,
//  motion vectors, borders, textures — is read past but not interpreted; Prism doesn't render the
//  full preset visual (see MilkdropWaveform.swift's header for that scope decision).
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
    /// Concatenated `per_frame_N=` lines, in ascending numeric order. Empty if the preset defines
    /// none (common for the older, non-per-frame-scripted presets).
    var perFrameProgram: String = ""
    /// Concatenated `per_frame_init_N=` lines — run once, before `perFrameProgram`'s first
    /// evaluation, to seed any custom variables the per-frame program reads (e.g. `SPEED=10;`).
    var perFrameInitProgram: String = ""
    /// Always 4 elements (indices 0-3), matching Milkdrop's `CustomShapeCount`. A shape with no
    /// `shapecode_N_*` keys at all in the file stays at `MilkdropShapePreset()`'s defaults —
    /// `enabled == false`, so it's simply skipped at render time.
    var shapes: [MilkdropShapePreset] = Array(repeating: MilkdropShapePreset(), count: 4)

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
        var shapeConstants: [Int: [String: String]] = [:]
        var shapeInitLines: [Int: [(index: Int, text: String)]] = [:]
        var shapePerFrameLines: [Int: [(index: Int, text: String)]] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
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
            } else {
                constants[key] = value
            }
        }

        perFrameLines.sort { $0.index < $1.index }
        perFrameProgram = perFrameLines.map(\.text).joined(separator: "\n")
        perFrameInitLines.sort { $0.index < $1.index }
        perFrameInitProgram = perFrameInitLines.map(\.text).joined(separator: "\n")

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
