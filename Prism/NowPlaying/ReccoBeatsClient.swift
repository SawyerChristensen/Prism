//
//  ReccoBeatsClient.swift
//  Prism
//
//  Free source for the numeric traits TO DO.md's "Song-Preset Matching" section grades presets
//  against. AcousticBrainz (the source that TO DO item originally named) has had its live API and
//  crowd-submission pipeline offline since 2022 — only a frozen mid-2022 dataset dump remains, so
//  it returns nothing for anything released since. ReccoBeats (https://reccobeats.com) mirrors
//  Spotify's own now-defunct `audio-features` endpoint field-for-field (Spotify deprecated that
//  endpoint for new API keys in Nov 2024, with no official replacement since), is free with no
//  API key/auth, and is looked up by plain artist/title search rather than a Spotify track id.
//

import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.prism.app", category: "ReccoBeatsClient")

/// The numeric traits behind ReccoBeats' `/track/{id}/audio-features` — same schema as Spotify's
/// old audio-features endpoint. `acousticness`/`danceability`/`energy`/`instrumentalness`/
/// `liveness`/`speechiness`/`valence` all range 0.0–1.0.
///
/// Codable (not just Decodable) so SongAudioTraitsCache can persist a resolved lookup — repeat
/// plays of the same track then skip the ReccoBeats round-trip entirely, which matters because
/// that round-trip is the one piece of the preset-matching pipeline that can't be made to finish
/// in under a second on demand (see SongPresetMatcher's own doc comment on why the actual scoring
/// step never needs to wait on anything).
struct SongAudioTraits: Codable {
    let acousticness: Double
    let danceability: Double
    let energy: Double
    let instrumentalness: Double
    /// Pitch class of the track's estimated overall key: 0 = C, 1 = C♯/D♭, ... 11 = B, or -1 if
    /// ReccoBeats couldn't detect one.
    let key: Int
    let liveness: Double
    /// Overall loudness in decibels (dB) — typically negative.
    let loudness: Double
    /// 1 = major, 0 = minor.
    let mode: Int
    let speechiness: Double
    /// Beats per minute.
    let tempo: Double
    let valence: Double
}

/// Free (no API key), keyed by artist/title search rather than by id — see this file's own doc
/// comment for why it replaces AcousticBrainz. Only wraps the two GET endpoints Prism needs
/// (catalog search + audio-features); ReccoBeats also has a POST /v1/analysis/audio-features that
/// runs its own Essentia-based analysis directly on an uploaded audio file, which would be the
/// natural fallback for tracks its catalog search can't find, but Prism has no local-file access
/// wired up yet to feed it.
enum ReccoBeatsClient {
    private static let baseURL = URL(string: "https://api.reccobeats.com")!

    private struct SearchResponse: Decodable {
        struct Track: Decodable {
            let id: String
            let artists: [Artist]
        }
        struct Artist: Decodable {
            let name: String
        }
        let content: [Track]
    }

    /// Looks `title` up against ReccoBeats' catalog (searchText is a title-only lookup — appending
    /// the artist into the same query string, tried first, made every single search come back
    /// empty even for extremely well-known songs like Metallica's "Enter Sandman"; confirmed via
    /// direct curl testing that dropping the artist from the query is what actually returns
    /// results) and disambiguates among the results by matching `artist` against each candidate's
    /// artist list. Returns nil - a genuine miss, not a guess - if the title search itself comes up
    /// empty, or if it returns results but none of them credit this artist (common titles like
    /// "Sentimental" return dozens of unrelated tracks by that name; blindly taking the top result
    /// in that case would hand the matcher a completely different song's traits).
    ///
    /// Retries once with `title`'s version annotation stripped (see `strippingVersionAnnotation`)
    /// if the first attempt finds nothing - Apple Music in particular reports track titles like
    /// "Enter Sandman (Remastered)" where ReccoBeats' catalog just has "Enter Sandman" (confirmed:
    /// this was the very first real-world lookup this code failed on).
    static func searchTrack(artist: String, title: String) async -> String? {
        if let id = await searchTrack(artist: artist, exactTitle: title) {
            return id
        }
        let stripped = strippingVersionAnnotation(title)
        guard stripped != title else { return nil }
        return await searchTrack(artist: artist, exactTitle: stripped)
    }

    private static func searchTrack(artist: String, exactTitle title: String) async -> String? {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/track/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "searchText", value: title)]
        guard let url = components?.url else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            logger.error("track search request failed for \(title, privacy: .public) — \(artist, privacy: .public)")
            return nil
        }
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            logger.error("track search decode failed for \(title, privacy: .public) — \(artist, privacy: .public)")
            return nil
        }

        let normalizedTarget = normalize(artist)
        return response.content.first { track in
            track.artists.contains { normalize($0.name) == normalizedTarget }
        }?.id
    }

    /// Strips a trailing parenthesized/bracketed version annotation - "(Remastered)", "(Live)",
    /// "(Deluxe Edition)", "(Radio Edit)", "(Mono Version)", etc. - gated on a known keyword list
    /// rather than stripping *any* trailing parenthetical, so a title where the parens are actually
    /// part of the song's name (e.g. "Under Pressure (feat. David Bowie)") is left alone. Returns
    /// `title` unchanged if nothing matches, so callers can detect "nothing to retry with" by
    /// comparing the result back against the input.
    private static let versionAnnotationRegex = try! NSRegularExpression(
        pattern: #"\s*[\(\[][^()\[\]]*\b(remaster(ed)?|live|deluxe|explicit|clean|radio\s*edit|mono|stereo|single\s*version|album\s*version|bonus\s*track|demo|anniversary)\b[^()\[\]]*[\)\]]\s*$"#,
        options: .caseInsensitive
    )

    private static func strippingVersionAnnotation(_ title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        let stripped = versionAnnotationRegex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased, alphanumeric-only comparison — tolerant of the kind of small punctuation/
    /// whitespace differences that show up between sources (Apple Music vs. ReccoBeats' own
    /// Spotify-sourced catalog) without being so loose it starts matching unrelated artists.
    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Fetches the numeric traits for a ReccoBeats track id — see `searchTrack(artist:title:)` to
    /// resolve one from plain artist/title first.
    static func audioFeatures(trackID: String) async -> SongAudioTraits? {
        let url = baseURL.appendingPathComponent("v1/track/\(trackID)/audio-features")
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            logger.error("audio-features request failed for track id \(trackID, privacy: .public)")
            return nil
        }
        guard let traits = try? JSONDecoder().decode(SongAudioTraits.self, from: data) else {
            logger.error("audio-features decode failed for track id \(trackID, privacy: .public)")
            return nil
        }
        return traits
    }

    /// Convenience: search + fetch in one call. nil if the search comes up empty or the
    /// audio-features call fails.
    static func fetchTraits(artist: String, title: String) async -> SongAudioTraits? {
        guard let trackID = await searchTrack(artist: artist, title: title) else { return nil }
        return await audioFeatures(trackID: trackID)
    }
}
