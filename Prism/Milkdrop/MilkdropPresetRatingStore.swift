//
//  MilkdropPresetRatingStore.swift
//  Prism
//
//  Persists per-preset star ratings and debug issue flags, recorded while sequentially reviewing
//  a library (see ContentView's "1"-"5"/"w"/"j"/"x" keybinds). Keyed by filename rather than
//  absolute path — same "filenames are unique across the whole corpus" assumption
//  MilkdropPresetVisualTraitsStore/MilkdropNestDropFavoritesList.presetFilenames already rely on
//  (reverified when generating PresetVisualTraits.json: zero collisions across all 9,795 shipped
//  presets). An absolute-path key seemed reasonable at first (this store is only ever consulted
//  while the library folder itself is already open), but it silently orphans every rating the
//  moment the same preset is loaded from a different copy of the pack — a different library
//  folder, a reorganized/renamed collection directory, or (worst case in practice) a Debug build
//  run from Xcode, whose bundled Presets folder lives under a DerivedData path that changes on
//  every clean build. A rating is about the preset itself, not the specific copy on disk it
//  happened to be sitting in when rated.
//
//  Also seeds itself from the bundled Resources/PresetRatings.json (see init's own doc comment
//  and Scripts/generate_preset_ratings.sh) so the dev's own ratings actually reach production
//  installs instead of living only in the dev machine's UserDefaults — real UserDefaults ratings
//  still override the bundled seed per-filename once a user (or the dev, on the next re-run of the
//  generate script) rates something themselves.
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
    private var ratingsByFilename: [String: MilkdropPresetRating]

    /// Seeded from the bundled, pre-generated `Resources/PresetRatings.json` (see
    /// `Scripts/generate_preset_ratings.sh`) — a snapshot of star ratings accumulated on the dev's
    /// machine, shipped so fresh installs get a non-empty `presetQuality` term in
    /// SongPresetMatcher instead of every preset scoring as neutral/unrated. The bundled seed never
    /// carries issue flags — the generate script strips those (stale ad hoc debug notes that
    /// nothing in the matching algorithm reads) before writing the resource. Local `UserDefaults`
    /// entries win per-filename over the bundled seed (not merged per-field): once a user rates or
    /// flags a preset themselves, that's a more current signal than whatever shipped. `persist()`
    /// still only ever writes to `defaults` — the bundled seed is baseline-only, never rewritten at
    /// runtime (same division of responsibility as MilkdropPresetVisualTraitsStore's bundled JSON
    /// vs. this store's own UserDefaults-backed state).
    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let bundled = Self.loadBundledSeed(from: bundle)
        let local = Self.loadPersisted(from: defaults)
        ratingsByFilename = bundled.merging(local) { _, local in local }
    }

    private static func loadBundledSeed(from bundle: Bundle) -> [String: MilkdropPresetRating] {
        guard let url = bundle.url(forResource: "PresetRatings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: MilkdropPresetRating].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func loadPersisted(from defaults: UserDefaults) -> [String: MilkdropPresetRating] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: MilkdropPresetRating].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func rating(for url: URL) -> MilkdropPresetRating? {
        ratingsByFilename[url.lastPathComponent]
    }

    /// Records a 1-5 star rating for `url`, overwriting any previous rating. Leaves any existing
    /// issue flags on the same preset untouched — a preset can be both rated and flagged (e.g.
    /// "2 stars, and it's too jittery").
    func setStars(_ stars: Int, for url: URL) {
        var entry = ratingsByFilename[url.lastPathComponent] ?? MilkdropPresetRating()
        entry.stars = stars
        ratingsByFilename[url.lastPathComponent] = entry
        persist()
    }

    /// Flags `url` with a debug issue (all-white, too jittery, strobing/flashing, ...) for later
    /// investigation. Leaves any existing star rating and other flags on the same preset
    /// untouched — flags accumulate, they don't replace one another.
    func flag(_ issue: MilkdropPresetIssue, for url: URL) {
        var entry = ratingsByFilename[url.lastPathComponent] ?? MilkdropPresetRating()
        entry.issues.insert(issue)
        ratingsByFilename[url.lastPathComponent] = entry
        persist()
    }

    /// Filenames of every preset flagged with `issue` so far, for revisiting/debugging later —
    /// filenames rather than URLs since that's all this store has on hand; resolving one back to
    /// an openable URL means matching it against the currently open library's own URLs (same shape
    /// as MilkdropPresetVisualTraitsStore.pairs(for:)).
    func filenames(flaggedWith issue: MilkdropPresetIssue) -> [String] {
        ratingsByFilename
            .filter { $0.value.issues.contains(issue) }
            .keys
            .map { $0 }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(ratingsByFilename) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
