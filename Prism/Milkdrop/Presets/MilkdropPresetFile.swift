//
//  MilkdropPresetFile.swift
//  Prism
//
//  Parses the subset of Milkdrop's ".milk" preset format Prism's waveform-only pipeline actually
//  needs: the top-level `key=value` constants that seed a preset's wave state (nWaveMode,
//  fWaveScale, fWaveSmoothing, fWaveParam, wave_x/y/r/g/b), plus the numbered `per_frame_N=`/
//  `per_frame_init_N=` lines, which get concatenated in numeric order into expression programs
//  (see MilkdropExpressionEvaluator.swift). Everything else in the file — warp/composite shaders,
//  custom shapes/waveforms, motion vectors, borders — is read past but not interpreted; Prism
//  only renders the waveform layer, not the full preset visual (see MilkdropWaveform.swift's
//  header for that scope decision).
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
        func float(_ key: String, _ fallback: Float) -> Float {
            constants[key].map(cleaned).flatMap(Float.init) ?? fallback
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            constants[key].map(cleaned).flatMap { Int(Double($0) ?? Double(fallback)) } ?? fallback
        }

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
    }
}
