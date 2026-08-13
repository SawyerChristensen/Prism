//
//  SongPresetMatcher.swift
//  Prism
//
//  The "search function that looks at each of those traits with different levels of importance"
//  from TO DO.md's "Song-Preset Matching" section — pairs ReccoBeatsClient's SongAudioTraits
//  against MilkdropPresetVisualTraits (see that file's own doc comment for the full rationale
//  behind each of the 7 visual traits and why they're paired the way they are below).
//
//  Two song traits get reused against two visual traits each — acousticness drives both decay
//  (smeared/dreamy vs crisp) and texture type (liquid/shader vs geometric/mesh), since both are
//  genuinely part of "how acoustic does this feel," not one canonical mapping split awkwardly in
//  two. `liveness` isn't used anywhere — nothing in MilkdropPresetVisualTraits reads as a
//  defensible proxy for it.
//
//  Every per-trait comparison is scored 0...1 (1 = perfect fit) and combined as a weighted average
//  — NOT a fixed-length weighted sum — over only the pairs where the preset actually has a signal.
//  A preset with no discernible color or no detected motion rate should be neither rewarded nor
//  punished for the missing signal; excluding the term entirely (rather than defaulting it to a
//  neutral 0.5) is what makes that true.
//

import Foundation

/// `nonisolated`: this is a pure value-type computation (no shared mutable state), and
/// `loadBestMatchedPreset` in ContentView.swift calls `rank` from a `Task.detached` specifically
/// to keep the ranking work off the main thread — the project's default `MainActor` isolation
/// would otherwise force every call site through an `await` hop back onto it, defeating that.
nonisolated enum SongPresetMatcher {
    /// Starting weights — relative importance, not calibrated against real listening sessions yet.
    /// Energy/danceability weighted highest since screen presence and responsiveness are the most
    /// visually obvious mismatches when wrong; loudness/glow weighted lowest since it's the
    /// subtlest of the seven. Tune once you've actually watched some matches play out.
    struct Weights {
        var colorWarmthForValence = 1.0
        var motionAmplitudeForEnergy = 1.2
        var reactivityForDanceability = 1.2
        var decayForAcousticness = 0.9
        var motionRateForTempo = 0.8
        var waveformForVocalPresence = 0.6
        var textureForAcousticness = 0.5
        var glowForLoudness = 0.5
        /// Reserved for a future production-only term reading ratingStars on its own 1-5 scale,
        /// once the whole library has an initial rating pass (see the note below) - currently
        /// unused in every configuration, including DEBUG. Debug/testing builds must never let
        /// rating influence which preset wins a match: that's what would make a review pass
        /// untrustworthy, since a highly-rated preset could get pulled onto screen regardless of
        /// how badly it actually fits the song being tested against. Rating during debugging is
        /// purely an out-of-band annotation - recorded via the "1"-"5" keybind, surfaced via the
        /// star overlay in ContentView - not a thing that's allowed to perturb the search itself.
        var presetQuality = 1.5

        static let `default` = Weights()
    }

    /// Higher = better fit for `song`. Always in 0...1, except the degenerate case (no signal
    /// present at all — shouldn't happen in practice since motionAmplitude/reactivity/texture are
    /// never nil) where it falls back to a neutral 0.5.
    ///
    /// `ratingStars` is the preset's own 1-5 star rating from MilkdropPresetRatingStore, looked up
    /// by the caller before crossing onto the detached ranking task (see `rank`'s own doc comment).
    static func score(song: SongAudioTraits, preset: MilkdropPresetVisualTraits, ratingStars: Int?, weights: Weights = .default) -> Double {
        var terms: [(weight: Double, subscore: Double)] = []

        // 1. valence -> colorWarmth: warm palette for positive valence, cool for negative.
        if let warmth = preset.colorWarmth {
            let signedValence = 2 * song.valence - 1 // 0...1 -> -1...+1, same scale as colorWarmth
            terms.append((weights.colorWarmthForValence, 1 - abs(signedValence - warmth) / 2))
        }

        // 2. energy -> motionAmplitude ("screen presence" — how hard the preset's own per-frame
        // math swings zoom/rot/warp).
        let normalizedAmplitude = normalizeAmplitude(preset.motionAmplitude)
        terms.append((weights.motionAmplitudeForEnergy, 1 - abs(song.energy - normalizedAmplitude)))

        // 3. danceability -> total band-reactivity mentions ("responsiveness" — how much the
        // preset's math references bass/mid/treb at all, regardless of which band).
        let normalizedReactivity = normalizeReactivity(preset.totalReactivityMentions)
        terms.append((weights.reactivityForDanceability, 1 - abs(song.danceability - normalizedReactivity)))

        // 4. acousticness -> decay ("vibe": high decay/long smeared trails for acoustic/ambient,
        // low decay/crisp cuts for produced/electronic).
        if let decay = preset.decay {
            terms.append((weights.decayForAcousticness, 1 - abs(song.acousticness - min(1, max(0, decay)))))
        }

        // 5. tempo -> motionRateHz (the preset's own detected base oscillation rate, independent
        // of how hard it swings).
        if let rateHz = preset.motionRateHz {
            let normalizedTempo = normalizeTempo(song.tempo)
            let normalizedRate = min(1, rateHz / referenceRateScale)
            terms.append((weights.motionRateForTempo, 1 - abs(normalizedTempo - normalizedRate)))
        }

        // 6. vocal presence (speechiness, and the inverse of instrumentalness) -> waveformProminence
        // (vocal-forward tracks get a preset that actually draws the waveform; purely instrumental
        // tracks get full abstract warp with the waveform suppressed).
        let vocalPresence = min(1, max(0, (song.speechiness + (1 - song.instrumentalness)) / 2))
        terms.append((weights.waveformForVocalPresence, 1 - abs(vocalPresence - preset.waveformProminence)))

        // 7. acousticness -> texture type (shader-driven/liquid for produced/electronic, i.e. low
        // acousticness; pure-mesh/geometric for acoustic/ambient, i.e. high acousticness).
        let textureAcousticFit = preset.usesShaderTexture ? (1 - song.acousticness) : song.acousticness
        terms.append((weights.textureForAcousticness, textureAcousticFit))

        // 8. loudness -> glow (additive blending pushes toward blown-out/glowing; a darkened
        // center pulls the other way).
        let normalizedLoudness = min(1, max(0, (song.loudness + 60) / 60))
        let glow = max(0, (preset.isAdditiveGlow ? 1.0 : 0.0) - (preset.darkensCenter ? 0.3 : 0.0))
        terms.append((weights.glowForLoudness, 1 - abs(normalizedLoudness - glow)))

        // 9. presetQuality -> deliberately not wired up yet in ANY configuration. `ratingStars`
        // still travels all the way through (see `rank`'s doc comment) so it's ready the moment
        // this term is turned on for production, reading ratingStars on its own 1-5 scale once the
        // whole library has had an initial rating pass. Until then it stays inert here in both
        // DEBUG and release builds - see weights.presetQuality's own doc comment for why debug
        // ranking specifically must never let rating skew which preset wins a match (a review pass
        // needs to trust it's seeing the genuine best/worst fit, not whatever's been rated so far).
        // "Already rated?" surfaces during debugging a different way instead: ContentView's star
        // overlay (topLeading, DEBUG-only) reads MilkdropPresetRatingStore directly and shows
        // on-screen, without touching this score at all.

        let totalWeight = terms.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0.5 }
        return terms.reduce(0) { $0 + $1.weight * $1.subscore } / totalWeight
    }

    /// Ranks every preset in `presets` against `song`, best fit first. `ratingStars` travels
    /// alongside each preset's visual traits rather than being looked up here, since this runs from
    /// a detached background task (see this enum's own doc comment) and MilkdropPresetRatingStore
    /// is `@MainActor`-bound state the caller must read before crossing that boundary.
    static func rank(song: SongAudioTraits, presets: [(url: URL, traits: MilkdropPresetVisualTraits, ratingStars: Int?)], weights: Weights = .default) -> [(url: URL, score: Double)] {
        presets
            .map { ($0.url, score(song: song, preset: $0.traits, ratingStars: $0.ratingStars, weights: weights)) }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: - Normalization

    /// motionAmplitude is an unbounded, uncalibrated heuristic (see MilkdropPresetVisualTraits'
    /// own doc comment on trait 3) — log-compressed so a "typical" preset lands mid-range rather
    /// than everything piling up near 0 or 1. Scale picked empirically against a sample of the real
    /// shipped pack (~/Documents/PrismCollection/BestMilkdropPresetsPack/Presets) — see the
    /// standalone harness this was calibrated with; re-tune if it starts feeling off against a
    /// wider sample.
    private static func normalizeAmplitude(_ amplitude: Double) -> Double {
        min(1, log1p(amplitude) / log1p(referenceAmplitudeScale))
    }
    private static let referenceAmplitudeScale = 12.0

    /// Same reasoning as normalizeAmplitude, for totalReactivityMentions.
    private static func normalizeReactivity(_ mentions: Int) -> Double {
        min(1, Double(mentions) / referenceReactivityScale)
    }
    private static let referenceReactivityScale = 20.0

    private static let referenceRateScale = 1.2

    private static func normalizeTempo(_ bpm: Double) -> Double {
        min(1, max(0, (bpm - 60) / 120))
    }
}
