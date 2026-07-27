//
//  MilkdropPresetComplexityAnalyzer.swift
//  Prism
//
//  Some .milk presets are dramatically more expensive to render than others because their
//  warp_N=/comp_N= shader bodies are genuine per-pixel fragment shaders (as opposed to presets
//  that only warp a coarse mesh per-vertex) — see TO DO.md: "amandio c - embrace 07 ..." measured
//  at ~3fps even though ProjectMMetalView targets 120fps, traced to its warp/comp shaders doing a
//  tex3D noise-volume lookup plus a multi-tap GetPixel neighbor sample (Sobel-style edge/gradient
//  effect) every pixel, every frame.
//
//  libprojectM's public C API (Vendor/projectm) exposes no shader-source or complexity accessor —
//  projectm_load_preset_file is fire-and-forget — so this scans the raw .milk text itself before
//  ever handing the URL to the engine. .milk is a plain, line-oriented INI-like format, and
//  warp_N=/comp_N= lines *are* the shader source verbatim (confirmed against a real corpus file:
//  each numbered line holds one backtick-prefixed line of shader code).
//

import Foundation

enum MilkdropPresetComplexityAnalyzer {
    /// warp_N=/comp_N= lines with 3+ GetPixel/GetBlur neighbor-sample calls are doing a multi-tap
    /// convolution (e.g. Sobel-style edge detection) — the specific pattern that made "amandio c -
    /// embrace 07 ..." slow. A single incidental call isn't enough on its own to flag a preset.
    private static let minNeighborSampleCount = 3

    static func isExpensive(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return isExpensive(presetText: text)
    }

    static func isExpensive(presetText text: String) -> Bool {
        let shaderText = shaderBody(from: text).lowercased()
        guard !shaderText.isEmpty else { return false }

        // A 3D noise-volume lookup is real per-pixel volumetric sampling work on its own.
        if shaderText.contains("tex3d(") { return true }

        let neighborSampleCount = shaderText.components(separatedBy: "getpixel(").count - 1
            + shaderText.components(separatedBy: "getblur(").count - 1
        return neighborSampleCount >= minNeighborSampleCount
    }

    /// Concatenates every warp_N=/comp_N= line's value — the only lines in a .milk file that are
    /// ever real per-pixel shader code (per-frame equations and the per-vertex mesh warp are both
    /// comparatively cheap). Line-prefix match rather than a stricter regex since real-world .milk
    /// files are otherwise unstructured/free-form past the `key=` prefix.
    private static func shaderBody(from text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.range(of: #"^(warp_|comp_)\d+\s*="#, options: .regularExpression) != nil
            }
            .joined(separator: "\n")
    }
}
