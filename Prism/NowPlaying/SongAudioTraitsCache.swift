//
//  SongAudioTraitsCache.swift
//  Prism
//
//  Persists resolved ReccoBeats lookups, keyed by normalized artist|title — same
//  UserDefaults+Codable persistence shape as MilkdropPresetRatingStore. The point isn't just
//  saving a network call: it's latency. ReccoBeats' search + audio-features round trip is
//  realistically 200ms-2s and can fail outright, which is the one piece of the whole song-preset-
//  matching pipeline that can't be forced under a hard sub-second budget (see SongPresetMatcher's
//  own doc comment - scoring the precomputed corpus itself is sub-millisecond, never the
//  bottleneck). A personal music library replays the same tracks constantly, so caching the
//  result - including a genuine "no match" - means the *common* case (a song Prism has already
//  seen) gets the matched preset instantly, with no network wait at all, from the very first
//  frame of the new track.
//
//  Caching misses (not just hits) matters just as much: without it, a track ReccoBeats' catalog
//  genuinely doesn't have would re-run the same failing lookup on every single replay forever.
//

import Foundation

enum SongAudioTraitsCacheLookup {
    /// This artist/title pair has never been looked up.
    case notCached
    /// Looked up before; ReccoBeats had no match. Distinct from `.notCached` so a known miss isn't
    /// re-queried every replay.
    case cachedMiss
    case cachedHit(SongAudioTraits)
}

final class SongAudioTraitsCache {
    private static let defaultsKey = "SongAudioTraitsCache"

    /// Injectable so tests exercise real persistence without touching the actual app's defaults
    /// domain — same pattern as MilkdropPresetRatingStore/MilkdropPresetLibrary.
    private let defaults: UserDefaults
    private var entries: [String: SongAudioTraits?]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: SongAudioTraits?].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func lookup(artist: String, title: String) -> SongAudioTraitsCacheLookup {
        switch entries[Self.key(artist: artist, title: title)] {
        case .none: return .notCached
        case .some(.none): return .cachedMiss
        case .some(.some(let traits)): return .cachedHit(traits)
        }
    }

    /// Records a lookup's outcome — `traits: nil` records a genuine miss (see this file's own doc
    /// comment on why that's cached too, not just hits).
    func store(_ traits: SongAudioTraits?, artist: String, title: String) {
        entries[Self.key(artist: artist, title: title)] = traits
        persist()
    }

    /// Case/whitespace-normalized so metadata formatting differences between sources land on the
    /// same cache entry — same normalization NowPlayingManager.albumKey already applies for its
    /// own per-album preference keying.
    private static func key(artist: String, title: String) -> String {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedArtist)|\(normalizedTitle)"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
