//
//  MilkdropPresetVisualTraits.swift
//  Prism
//
//  The visual-side counterpart to ReccoBeatsClient's SongAudioTraits — see TO DO.md's
//  "Song-Preset Matching" section. Extracts a fixed set of numeric/categorical traits from a
//  .milk file's raw text, the same way MilkdropPresetComplexityAnalyzer already does (libprojectM
//  exposes no shader-source/parameter introspection API, so this reads the plain INI-like text
//  itself, before the preset is ever handed to the engine).
//
//  ================================================================================================
//  THE PLAN — 7 visual traits, one per song trait they're meant to pair against (see
//  SongPresetMatcher for the actual pairing/weights). All 7 were picked because they're readable
//  straight out of the text with a defensible heuristic — no expression evaluator, no rendering.
//  Surveyed against the full shipped pack (~/Documents/PrismCollection/BestMilkdropPresetsPack/
//  Presets, 9,795 .milk files) while designing this, to ground every threshold/normalization
//  constant below in real numbers instead of guesses:
//
//  1. decay (fDecay=) → pairs with acousticness.
//     A single float already sitting in the file, controlling how much of the previous frame
//     persists. High = long dreamy smeared trails, low = crisp/fast-cutting. Present in 9,780/9,795
//     files; range in practice is roughly 0...1 (median 0.98) but a handful exceed 1.0 — stored raw,
//     un-clamped, missing → nil.
//
//  2. band reactivity (bass/mid/treb mention share in per_frame_N=/per_pixel_N= lines) → pairs
//     with danceability.
//     Counts word-boundary references to bass/bass_att, mid/mid_att, treb/treb_att across every
//     per_frame_N=/per_pixel_N= line's expression (not warp_N=/comp_N= — those are real per-pixel
//     shader code in a different language, HLSL-like, where these names don't mean the same thing).
//     ~74%/65%/66% of the pack references bass/mid/treb respectively at all. The normalized shares
//     say *which* band drives the preset (pairs well with the live audio's own spectral brightness,
//     independent of any external metadata); the raw total mention count is used as an overall
//     "how audio-reactive is this preset at all" strength signal for danceability.
//
//  3. motion (per_frame_N=/per_pixel_N= assignments to zoom/rot/warp/dx/dy/sx/sy/cx/cy) → split into
//     two genuinely distinguishable sub-signals, pairing with energy and tempo respectively:
//       - motionAmplitude → energy ("screen presence"). Sum of absolute values of the bare numeric
//         literals in each assignment's right-hand side, excluding any literal already claimed by
//         the sin/cos(K*time) match below. An unbounded, uncalibrated, purely comparative score —
//         only meaningful relative to other presets' scores, never as an absolute unit. Real example
//         line: `rot = rot + 0.010*( 0.60*sin(0.381*time) + 0.40*sin(0.579*time) )` — 0.010, 0.60,
//         0.40 count toward amplitude; 0.381/0.579 do not (they're rate, see below).
//       - motionRateHz → tempo/BPM. The literal K coefficient inside a `sin(K*time)` / `sin(time*K)`
//         (or cos) call is genuinely the oscillation's angular rate, independent of amplitude — a
//         real signal, not a proxy, wherever the idiom is actually used. Checked both argument
//         orders since real presets use both (`K*time` alone: 2,543 files; `time*K` alone: 6,210;
//         either order: 7,018/9,795 ≈ 71.6%). Average of every captured K in the preset; nil when
//         the idiom never appears (~28% of the pack) rather than defaulting to a fabricated 0 — a
//         preset with no detectable base rate should read as "no signal," not "holds perfectly
//         still."
//
//  4. colorWarmth (wave_r/g/b weighted with ob_r/g/b/ib_r/g/b) → pairs with valence.
//     wave_r/g/b are present in all 9,795 files, so always readable, but plenty of presets leave
//     them at 0/0/0 (black — meaning the real color comes from a per_frame override this static
//     scan can't see) or otherwise near-gray. A signed r-minus-b warmth score, nil whenever the
//     blended color has no discernible hue (near-gray/near-black) — same "default to nil, only
//     register a color when there's a genuinely prominent one" rule TO DO.md already calls for on
//     the album-art side of this feature, applied here to presets instead of covers.
//
//  5. usesShaderTexture (any non-empty warp_N=/comp_N= line) → pairs with acousticness (again — see
//     SongPresetMatcher's own doc comment for why reusing one song trait against two visual traits
//     is fine here). Shader-driven presets (84.3% of the pack: 8,251/9,795) read as organic/liquid/
//     psychedelic; pure per-vertex-mesh presets (the other 1,544) read as more geometric/crisp.
//     A plain boolean, not the expense-weighted check MilkdropPresetComplexityAnalyzer does — that
//     one's answering "is this too slow to render," this one's answering "what does it look like."
//
//  6. waveformProminence (fWaveAlpha=) → pairs with vocal presence (speechiness, inverse of
//     instrumentalness).
//     fWaveAlpha is heavily right-skewed across the pack (median 0.001, p75 0.8, p95 11.2, max 100)
//     — most presets leave the literal oscilloscope waveform essentially invisible. Normalized via
//     `min(1, alpha / 2)`; 2.0 was picked by hand against a real preset ("Geiss - All-Spark",
//     fWaveAlpha=4.1) that's genuinely wave-forward, so it lands comfortably inside the clamp rather
//     than pegged at the ceiling.
//
//  7. glow (bAdditiveWaves=, bDarkenCenter=) → pairs with loudness.
//     Two flags read directly, no derivation needed. Additive blending (44.8% of the pack:
//     4,384/9,795) blows out highlights/glows; a darkened center (6.9%: 675/9,795) pulls the other
//     way. Combined into a single -ish glow score by SongPresetMatcher, not stored pre-combined here
//     — keeping both raw booleans lets a future caller use them independently of loudness-matching
//     too (e.g. "flag strobing candidates" already has bDarkenCenter-adjacent needs — see
//     MilkdropPresetRatingStore's `.strobing` issue flag).
//
//  Deliberately NOT mapped to anything: `liveness` (SongAudioTraits' "live performance" probability)
//  — nothing here reads as a defensible proxy for crowd/live-recording-ness, so it's left unused
//  rather than forced into a pairing that wouldn't mean anything.
//  ================================================================================================
//

import Foundation

/// One preset's visual personality, as read out of its .milk text — see this file's own doc
/// comment for the full rationale behind each field and its normalization constants. Optional
/// fields are genuinely "no signal detected," not a fabricated neutral/default — SongPresetMatcher
/// excludes them from scoring entirely rather than guessing.
///
/// Codable so the whole corpus can be precomputed once (see Scripts/generate_preset_visual_traits.
/// swift) and bundled as Resources/PresetVisualTraits.json — MilkdropPresetVisualTraitsStore loads
/// it a single time at launch, rather than every preset decision re-reading and re-scanning
/// thousands of .milk files' text on the spot.
struct MilkdropPresetVisualTraits: Codable {
    /// Raw `fDecay=`, un-clamped (rare presets exceed 1.0). Nil for the ~0.15% of presets missing
    /// the key entirely.
    let decay: Double?

    /// Share of bass/mid/treb mentions across per_frame_N=/per_pixel_N=, each 0...1, summing to 1
    /// when the preset references any of the three at all — all zero if it references none (a
    /// genuinely audio-agnostic/ambient preset, not a parsing failure).
    let bassReactivityShare: Double
    let midReactivityShare: Double
    let trebReactivityShare: Double
    /// Raw combined mention count backing the shares above — used on its own as an "how audio-
    /// reactive is this preset at all" strength signal, separate from *which* band dominates.
    let totalReactivityMentions: Int

    /// See "3. motion" above. Unbounded, comparative-only.
    let motionAmplitude: Double
    /// See "3. motion" above. Nil when no `sin/cos(K*time)` idiom was found anywhere in the
    /// preset's per_frame_N=/per_pixel_N= lines.
    let motionRateHz: Double?

    /// Signed r-minus-b warmth from the blended wave/border color, roughly -1 (cool/blue) ... +1
    /// (warm/red). Nil when the blended color is too close to gray/black to have a discernible hue.
    let colorWarmth: Double?

    /// True if the preset has at least one non-empty warp_N=/comp_N= line (a real per-pixel
    /// fragment shader body, regardless of how expensive it is to run — see
    /// MilkdropPresetComplexityAnalyzer for the separate "is it too slow" question).
    let usesShaderTexture: Bool

    /// Normalized `min(1, fWaveAlpha / 2)`. 0 when fWaveAlpha is missing or non-positive.
    let waveformProminence: Double

    /// `bAdditiveWaves=1`.
    let isAdditiveGlow: Bool
    /// `bDarkenCenter=1`.
    let darkensCenter: Bool
}

enum MilkdropPresetVisualTraitsAnalyzer {
    static func analyze(_ url: URL) -> MilkdropPresetVisualTraits? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return analyze(presetText: text)
    }

    static func analyze(presetText text: String) -> MilkdropPresetVisualTraits {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }

        let decay = scalarValue(named: "fDecay", in: lines)

        let motionLines = expressionLines(in: lines, prefixes: ["per_frame_", "per_pixel_"])
        let reactivity = bandReactivity(in: motionLines)
        let motion = motionSignals(in: motionLines)

        return MilkdropPresetVisualTraits(
            decay: decay,
            bassReactivityShare: reactivity.bassShare,
            midReactivityShare: reactivity.midShare,
            trebReactivityShare: reactivity.trebShare,
            totalReactivityMentions: reactivity.totalMentions,
            motionAmplitude: motion.amplitude,
            motionRateHz: motion.rateHz,
            colorWarmth: colorWarmth(in: lines),
            usesShaderTexture: hasShaderBody(in: lines),
            waveformProminence: min(1, max(0, scalarValue(named: "fWaveAlpha", in: lines) ?? 0) / 2),
            isAdditiveGlow: boolValue(named: "bAdditiveWaves", in: lines),
            darkensCenter: boolValue(named: "bDarkenCenter", in: lines)
        )
    }

    // MARK: - Scalar/boolean key=value reads

    private static func rawValue(named key: String, in lines: [String]) -> String? {
        let prefix = "\(key)="
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func scalarValue(named key: String, in lines: [String]) -> Double? {
        rawValue(named: key, in: lines).flatMap(Double.init)
    }

    private static func boolValue(named key: String, in lines: [String]) -> Bool {
        rawValue(named: key, in: lines) == "1"
    }

    // MARK: - Expression line gathering

    /// Every per_frame_N=/per_pixel_N= line's right-hand side (the part after the numbered key's
    /// `=`) — the milkdrop-eval expression language, where bare `bass`/`zoom=`/etc. names mean what
    /// they say. Distinct from warp_N=/comp_N=, which hold HLSL-like shader source instead (see
    /// this file's own doc comment on trait 2/3 for why those are excluded here).
    private static func expressionLines(in lines: [String], prefixes: [String]) -> [String] {
        lines.compactMap { line -> String? in
            for prefix in prefixes {
                if line.range(of: "^\(prefix)\\d+\\s*=", options: .regularExpression) != nil,
                   let equalsIndex = line.firstIndex(of: "=") {
                    return String(line[line.index(after: equalsIndex)...])
                }
            }
            return nil
        }
    }

    // MARK: - Trait 2: band reactivity

    private static func bandReactivity(in expressionLines: [String]) -> (bassShare: Double, midShare: Double, trebShare: Double, totalMentions: Int) {
        let combined = expressionLines.joined(separator: "\n")
        let bass = mentionCount(of: #"\bbass(_att)?\b"#, in: combined)
        let mid = mentionCount(of: #"\bmid(_att)?\b"#, in: combined)
        let treb = mentionCount(of: #"\btreb(_att)?\b"#, in: combined)
        let total = bass + mid + treb
        guard total > 0 else { return (0, 0, 0, 0) }
        return (Double(bass) / Double(total), Double(mid) / Double(total), Double(treb) / Double(total), total)
    }

    private static func mentionCount(of pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // MARK: - Trait 3: motion amplitude + rate

    private static let motionVariableNames = ["zoom", "rot", "warp", "dx", "dy", "sx", "sy", "cx", "cy"]

    /// `K*time`/`time*K` inside a sin(.../cos(...) call — see this file's own doc comment for why
    /// the coefficient in this exact position is a genuine rate, not a proxy.
    private static let sinCosRateRegex = try! NSRegularExpression(
        pattern: #"(?:sin|cos)\s*\(\s*(?:([0-9]*\.?[0-9]+)\s*\*\s*time|time\s*\*\s*([0-9]*\.?[0-9]+))"#,
        options: .caseInsensitive
    )
    private static let bareNumberRegex = try! NSRegularExpression(pattern: #"-?[0-9]*\.?[0-9]+"#)

    private static func motionSignals(in expressionLines: [String]) -> (amplitude: Double, rateHz: Double?) {
        var amplitude = 0.0
        var rateSamples: [Double] = []

        for line in expressionLines {
            // Only lines that actually assign one of the motion variables (`zoom = ...`, not just
            // any line that happens to mention "zoom") count toward either signal.
            guard motionVariableNames.contains(where: { name in
                line.range(of: "^\\s*\(name)\\s*=(?!=)", options: .regularExpression) != nil
            }) else { continue }

            let fullRange = NSRange(line.startIndex..., in: line)
            var consumedRanges: [Range<String.Index>] = []

            for match in sinCosRateRegex.matches(in: line, range: fullRange) {
                for groupIndex in [1, 2] {
                    guard let range = Range(match.range(at: groupIndex), in: line) else { continue }
                    if let k = Double(line[range]) {
                        rateSamples.append(k)
                        consumedRanges.append(range)
                    }
                }
            }

            for match in bareNumberRegex.matches(in: line, range: fullRange) {
                guard let range = Range(match.range, in: line) else { continue }
                if consumedRanges.contains(where: { $0.overlaps(range) }) { continue }
                if let value = Double(line[range]) {
                    amplitude += abs(value)
                }
            }
        }

        guard !rateSamples.isEmpty else { return (amplitude, nil) }
        return (amplitude, rateSamples.reduce(0, +) / Double(rateSamples.count))
    }

    // MARK: - Trait 4: color warmth

    private static func colorWarmth(in lines: [String]) -> Double? {
        func rgb(_ prefix: String) -> (r: Double, g: Double, b: Double)? {
            guard let r = scalarValue(named: "\(prefix)_r", in: lines),
                  let g = scalarValue(named: "\(prefix)_g", in: lines),
                  let b = scalarValue(named: "\(prefix)_b", in: lines) else { return nil }
            return (r, g, b)
        }

        // Waves dominate what's actually visible on screen; borders are thin accents — weighted
        // accordingly rather than averaged evenly.
        let weighted: [(rgb: (r: Double, g: Double, b: Double), weight: Double)] = [
            rgb("wave").map { ($0, 0.6) },
            rgb("ob").map { ($0, 0.25) },
            rgb("ib").map { ($0, 0.15) },
        ].compactMap { $0 }

        guard !weighted.isEmpty else { return nil }
        let totalWeight = weighted.reduce(0) { $0 + $1.weight }
        let r = weighted.reduce(0) { $0 + $1.rgb.r * $1.weight } / totalWeight
        let g = weighted.reduce(0) { $0 + $1.rgb.g * $1.weight } / totalWeight
        let b = weighted.reduce(0) { $0 + $1.rgb.b * $1.weight } / totalWeight

        // Too close to gray/black to have a discernible hue — register nil rather than a
        // meaningless near-zero warmth score (same "default to nil" rule as album art color-keying).
        let channelSpread = max(r, g, b) - min(r, g, b)
        guard channelSpread > 0.05 else { return nil }

        return max(-1, min(1, r - b))
    }

    // MARK: - Trait 5: shader texture

    private static func hasShaderBody(in lines: [String]) -> Bool {
        lines.contains { line in
            guard line.range(of: "^(warp_|comp_)\\d+\\s*=", options: .regularExpression) != nil,
                  let equalsIndex = line.firstIndex(of: "=") else { return false }
            return !line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
