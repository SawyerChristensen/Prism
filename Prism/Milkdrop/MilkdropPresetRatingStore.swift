//
//  MilkdropPresetRatingStore.swift
//  Prism
//
//  Persists per-preset star ratings and debug issue flags, recorded while sequentially reviewing
//  a library (see ContentView's "1"-"5"/"w"/"j"/"x" keybinds). Keyed by absolute file path rather
//  than a security-scoped bookmark like MilkdropLastPresetStore/MilkdropPresetLibrary use for the
//  file/folder they persist across launches — this store is only ever consulted while the library
//  folder itself is already open (its own bookmark already grants access to every path under it),
//  so a plain path is enough to look a rating back up.
//

import Foundation

enum MilkdropPresetIssue: String, Codable {
    case allWhite
    case tooJittery
    case strobing
}

struct MilkdropPresetRating: Codable, Equatable {
    var stars: Int?
    var issues: Set<MilkdropPresetIssue> = []
}

final class MilkdropPresetRatingStore {
    private static let defaultsKey = "MilkdropPresetRatings"

    /// Injectable so tests exercise real persistence without touching the actual app's defaults
    /// domain (`.standard` in production) — same pattern as MilkdropPresetLibrary/
    /// MilkdropLastPresetStore.
    private let defaults: UserDefaults
    private var ratingsByPath: [String: MilkdropPresetRating]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: MilkdropPresetRating].self, from: data) {
            ratingsByPath = decoded
        } else {
            ratingsByPath = [:]
        }
    }

    func rating(for url: URL) -> MilkdropPresetRating? {
        ratingsByPath[url.path]
    }

    /// Records a 1-5 star rating for `url`, overwriting any previous rating. Leaves any existing
    /// issue flags on the same preset untouched — a preset can be both rated and flagged (e.g.
    /// "2 stars, and it's too jittery").
    func setStars(_ stars: Int, for url: URL) {
        var entry = ratingsByPath[url.path] ?? MilkdropPresetRating()
        entry.stars = stars
        ratingsByPath[url.path] = entry
        persist()
    }

    /// Flags `url` with a debug issue (all-white, too jittery, strobing/flashing, ...) for later
    /// investigation. Leaves any existing star rating and other flags on the same preset
    /// untouched — flags accumulate, they don't replace one another.
    func flag(_ issue: MilkdropPresetIssue, for url: URL) {
        var entry = ratingsByPath[url.path] ?? MilkdropPresetRating()
        entry.issues.insert(issue)
        ratingsByPath[url.path] = entry
        persist()
    }

    /// Every preset flagged with `issue` so far, for revisiting/debugging later.
    func urls(flaggedWith issue: MilkdropPresetIssue) -> [URL] {
        ratingsByPath
            .filter { $0.value.issues.contains(issue) }
            .keys
            .map { URL(fileURLWithPath: $0) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(ratingsByPath) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
