//
//  MilkdropPresetComplexityAnalyzer.swift
//  Prism
//
//  Some .milk presets are dramatically more expensive to render than others. Two independent
//  cost drivers, checked separately:
//
//  1. Per-pixel warp_N=/comp_N= shader bodies doing real fragment-shader work (as opposed to
//     presets that only warp a coarse mesh per-vertex) — see TO DO.md: "amandio c - embrace 07
//     ..." measured at ~3fps even though ProjectMMetalView targets 120fps, traced to its
//     warp/comp shaders doing a tex3D noise-volume lookup plus multi-tap GetPixel/GetBlur1/2/3
//     neighbor samples (Sobel-style edge/gradient effect) every pixel, every frame.
//  2. Per-frame equation evaluation for shapecode/wavecode instances — shapecode_N_num_inst (or
//     wavecode_N_samples, for wave per-point code) multiplies straight through: a shapecode with
//     num_inst=1024 runs its whole shape_N_per_frame equation block 1024 times, every frame, no
//     pixel shader involved at all. See TO DO.md: "amandio c - the climbing ..." measured at only
//     a couple fps from ~2,174 total shape instances (two shapecodes at num_inst=1024 each) each
//     running ~85-100 trig-heavy per_frame lines — real per-pixel shader checks alone (its warp
//     shader uses tex2D, not tex3D; its comp shader calls GetBlur1/GetBlur2/GetBlur3, never the
//     bare "GetBlur(" this file used to look for) never see this cost at all.
//
//  libprojectM's public C API (Vendor/projectm) exposes no shader-source or complexity accessor,
//  and no per-instance-equation-cost accessor either — projectm_load_preset_file is fire-and-
//  forget — so this scans the raw .milk text itself before ever handing the URL to the engine.
//  .milk is a plain, line-oriented INI-like format, and warp_N=/comp_N= lines *are* the shader
//  source verbatim (confirmed against a real corpus file: each numbered line holds one backtick-
//  prefixed line of shader code).
//

import Foundation

enum MilkdropPresetComplexityAnalyzer {
    /// warp_N=/comp_N= lines with 3+ GetPixel/GetBlur1/2/3 neighbor-sample calls are doing a
    /// multi-tap convolution (e.g. Sobel-style edge detection) — the specific pattern that made
    /// "amandio c - embrace 07 ..." slow. A single incidental call isn't enough on its own to
    /// flag a preset.
    private static let minNeighborSampleCount = 3

    /// Total shape_N_per_frame / wave_N_per_point equation-line evaluations per rendered frame
    /// (num_inst or samples × line count, summed across every enabled shapecode/wavecode) above
    /// which a preset is expensive regardless of pixel-shader cost. "amandio c - the climbing
    /// ..." totals ~233,000 (two shapecodes alone contribute ~173,000) against typical presets'
    /// low hundreds to low thousands, so this threshold has wide margin on both sides.
    private static let maxEquationEvaluationsPerFrame = 50_000

    private static let neighborSampleRegex = try! NSRegularExpression(
        pattern: #"getpixel\(|getblur\d*\("#
    )

    static func isExpensive(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return isExpensive(presetText: text)
    }

    static func isExpensive(presetText text: String) -> Bool {
        if isPixelShaderExpensive(text) { return true }
        return equationEvaluationsPerFrame(in: text) >= maxEquationEvaluationsPerFrame
    }

    private static func isPixelShaderExpensive(_ text: String) -> Bool {
        let shaderText = shaderBody(from: text).lowercased()
        guard !shaderText.isEmpty else { return false }

        // A 3D noise-volume lookup is real per-pixel volumetric sampling work on its own.
        if shaderText.contains("tex3d(") { return true }

        let range = NSRange(shaderText.startIndex..., in: shaderText)
        let neighborSampleCount = neighborSampleRegex.numberOfMatches(in: shaderText, range: range)
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

    /// Sums (num_inst × shape_N_per_frame line count) across every enabled shapecode_N, plus
    /// (samples × wave_N_per_point line count) across every enabled wavecode_N that actually has
    /// per-point code. Defaults (num_inst=1, samples=512, enabled=true) match real Milkdrop/
    /// projectM's own preset defaults, so a block missing an explicit key is still counted rather
    /// than silently skipped.
    private static func equationEvaluationsPerFrame(in text: String) -> Int {
        var shapeEnabled: [Int: Bool] = [:]
        var shapeNumInst: [Int: Int] = [:]
        var shapeFrameLineCount: [Int: Int] = [:]
        var waveEnabled: [Int: Bool] = [:]
        var waveSamples: [Int: Int] = [:]
        var wavePointLineCount: [Int: Int] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let (idx, value) = keyValue(line, prefix: "shapecode_", suffix: "_enabled") {
                shapeEnabled[idx] = (Int(value) ?? 0) != 0
            } else if let (idx, value) = keyValue(line, prefix: "shapecode_", suffix: "_num_inst") {
                shapeNumInst[idx] = Int(value) ?? 1
            } else if let idx = numberedLineIndex(line, prefix: "shape_", infix: "_per_frame") {
                shapeFrameLineCount[idx, default: 0] += 1
            } else if let (idx, value) = keyValue(line, prefix: "wavecode_", suffix: "_enabled") {
                waveEnabled[idx] = (Int(value) ?? 0) != 0
            } else if let (idx, value) = keyValue(line, prefix: "wavecode_", suffix: "_samples") {
                waveSamples[idx] = Int(value) ?? 512
            } else if let idx = numberedLineIndex(line, prefix: "wave_", infix: "_per_point") {
                wavePointLineCount[idx, default: 0] += 1
            }
        }

        var total = 0
        for (idx, lineCount) in shapeFrameLineCount where shapeEnabled[idx] ?? true {
            total += (shapeNumInst[idx] ?? 1) * lineCount
        }
        for (idx, lineCount) in wavePointLineCount where waveEnabled[idx] ?? true {
            total += (waveSamples[idx] ?? 512) * lineCount
        }
        return total
    }

    /// Matches a line like "shapecode_2_num_inst=1024" against `prefix`="shapecode_",
    /// `suffix`="_num_inst", returning (2, "1024"). No regex: the .milk key format is a fixed
    /// `key=value` shape, so plain substring slicing is both simpler and cheaper here.
    private static func keyValue(_ line: String, prefix: String, suffix: String) -> (index: Int, value: Substring)? {
        guard line.hasPrefix(prefix), let equalsIndex = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<equalsIndex]
        guard key.hasSuffix(suffix) else { return nil }
        let idxStart = line.index(line.startIndex, offsetBy: prefix.count)
        let idxEnd = key.index(key.endIndex, offsetBy: -suffix.count)
        guard idxStart <= idxEnd, let idx = Int(line[idxStart..<idxEnd]) else { return nil }
        return (idx, line[line.index(after: equalsIndex)...])
    }

    /// Matches a line like "shape_0_per_frame23=..." against `prefix`="shape_",
    /// `infix`="_per_frame", returning 0 — the trailing per-line number (23) is irrelevant, this
    /// only needs to count how many such lines exist per shape/wave index.
    private static func numberedLineIndex(_ line: String, prefix: String, infix: String) -> Int? {
        guard line.hasPrefix(prefix), let infixRange = line.range(of: infix) else { return nil }
        let idxStart = line.index(line.startIndex, offsetBy: prefix.count)
        guard idxStart <= infixRange.lowerBound, let idx = Int(line[idxStart..<infixRange.lowerBound]) else { return nil }
        return idx
    }
}
