//
//  MilkdropPresetRatingStore.swift
//  Prism
//
//  Persists per-preset star ratings and a small set of playback/legibility flags (tooJittery/
//  strobing/tooDark/tooBright/tooFast), recorded while sequentially reviewing a library (see
//  ContentView's "1"-"5"/"j"/"x"/"d"/"b"/"f" keybinds). Unlike stars, a flag has a real runtime
//  effect: ContentView's loadNextSequentialPreset/loadBestMatchedPreset both skip any preset
//  `isFlagged(_:)` reports true for, so a strobing preset (a genuine photosensitive-seizure risk),
//  a jittery/too-fast one, or one that's just too dark/bright to read never comes up through
//  sequential/random/song-matched rotation again — only an explicit pick by identity (Cmd-I,
//  drag-and-drop, Cmd-S search, History menu) can still load one on purpose. Keyed by filename
//  rather than absolute path — same "filenames are unique across the whole corpus" assumption
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
//  Also seeds itself from the bundled Resources/PresetRatings.json (see init's own doc comment) so
//  the dev's own ratings actually reach production installs instead of living only in the dev
//  machine's UserDefaults — real UserDefaults ratings still override the bundled seed per-filename
//  once a user rates something themselves.
//
//  DEBUG builds (only — see setRepoRoot's own doc comment) skip UserDefaults for rating/flagging
//  entirely once the dev has granted access, and instead write each "1"-"5"/"j"/"x"/"d"/"b"/"f"
//  keypress straight into the real, committed Prism/Resources/PresetRatings.json and repo-root
//  FlaggedPresets.json — every keypress is immediately the same bytes that ship, with no manual
//  export step (the old Scripts/generate_preset_ratings.sh / generate_flagged_presets.sh, both
//  removed - see git history) and no intermediate UserDefaults snapshot that export step could ever
//  go stale against or silently drop entries from (see the incident this replaced in git history
//  around 2026-08-13). Production installs are entirely unaffected — end users have no repo to
//  write into and this store's release-build behavior (UserDefaults, seeded from the bundled JSON
//  above) is untouched either way.
//

import Foundation

enum MilkdropPresetIssue: String, Codable {
    case tooJittery
    case strobing
    case tooDark
    case tooBright
    case tooFast
}

struct MilkdropPresetRating: Codable, Equatable {
    var stars: Int?
    var issues: Set<MilkdropPresetIssue> = []

    init(stars: Int? = nil, issues: Set<MilkdropPresetIssue> = []) {
        self.stars = stars
        self.issues = issues
    }

    // Custom init(from:) instead of relying on synthesized Decodable - a stored property's `= []`
    // default only initializes it when *this type's own* init runs; it does nothing for decoding,
    // where the synthesized conformance still requires the key to be present and throws
    // .keyNotFound otherwise. That silently broke every previously-persisted rating the moment
    // `issues` was added to this struct: both the bundled Resources/PresetRatings.json seed and
    // local UserDefaults were written back when this struct had only `stars`, so neither had an
    // "issues" key, and MilkdropPresetRatingStore's `try?`-guarded decode calls quietly treated
    // both as empty on the very next launch - not a lost-data incident, a decode-compat bug
    // (see git history around 2026-08-10 for the full incident write-up in ContentView.swift/
    // Scripts/generate_preset_ratings.swift.txt). decodeIfPresent + `?? []` here is what makes an
    // old-shape `{"stars":4}` blob (with no "issues" key at all) decode exactly as it always did.
    private enum CodingKeys: String, CodingKey {
        case stars, issues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stars = try container.decodeIfPresent(Int.self, forKey: .stars)
        issues = try container.decodeIfPresent(Set<MilkdropPresetIssue>.self, forKey: .issues) ?? []
    }
}

final class MilkdropPresetRatingStore {
    private static let defaultsKey = "MilkdropPresetRatings"

    /// Injectable so tests exercise real persistence without touching the actual app's defaults
    /// domain (`.standard` in production) — same pattern as MilkdropPresetLibrary/
    /// MilkdropLastPresetStore.
    private let defaults: UserDefaults
    private var ratingsByFilename: [String: MilkdropPresetRating]

    #if DEBUG
    private static let repoBookmarkDefaultsKey = "MilkdropPresetRatingsRepoBookmark"
    private var repoRootURL: URL?
    private var isAccessingRepoSecurityScopedResource = false
    private static let sortedKeysEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    #endif

    /// Seeded from the bundled, pre-generated `Resources/PresetRatings.json` — a snapshot of star
    /// ratings accumulated on the dev's machine (in DEBUG builds, written there directly by
    /// setStars/flag below once repo write access is granted — see setRepoRoot), shipped so fresh
    /// installs get a non-empty `presetQuality` term in SongPresetMatcher instead of every preset
    /// scoring as neutral/unrated. The bundled seed never carries issue flags (those live in the
    /// separate, never-bundled repo-root FlaggedPresets.json instead — a live, session-driven safety
    /// signal that only matters for rotation on the machine that actually saw the preset play;
    /// shipping a stale snapshot of someone else's judgment call into every install makes no sense).
    /// Local `UserDefaults` entries win per-filename over the bundled seed (not merged per-field):
    /// once a user rates or flags a preset themselves, that's a more current signal than whatever
    /// shipped. `persist()` writes to `defaults` and never touches the bundled seed at runtime in
    /// release builds (same division of responsibility as MilkdropPresetVisualTraitsStore's bundled
    /// JSON vs. this store's own UserDefaults-backed state) — DEBUG builds are the one exception,
    /// where setStars/flag intentionally rewrite the real source file directly instead of calling
    /// persist() at all once repo access exists (see this file's own top-of-file doc comment).
    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let bundled = Self.loadBundledSeed(from: bundle)
        let local = Self.loadPersisted(from: defaults)
        ratingsByFilename = bundled.merging(local) { _, local in local }
        #if DEBUG
        restoreRepoBookmarkIfAvailable()
        if hasRepoWriteAccess {
            // Live on-disk repo files, not the bundled-seed-plus-UserDefaults merge above, are the
            // current state once repo access exists — see loadFromRepoFilesIfAvailable's own doc
            // comment for why a relaunch needs this instead of what init just computed.
            loadFromRepoFilesIfAvailable()
        }
        #endif
    }

    #if DEBUG
    deinit {
        if isAccessingRepoSecurityScopedResource {
            repoRootURL?.stopAccessingSecurityScopedResource()
        }
    }

    var hasRepoWriteAccess: Bool { repoRootURL != nil }

    private var presetRatingsFileURL: URL? {
        repoRootURL?.appendingPathComponent("Prism/Resources/PresetRatings.json")
    }
    private var flaggedPresetsFileURL: URL? {
        repoRootURL?.appendingPathComponent("FlaggedPresets.json")
    }

    /// Call after the dev picks the Prism repo's root folder (ContentView's `.ratingsRepoFolder`
    /// file importer case, triggered lazily the first time a rating/flag keypress fires without
    /// this access yet — see ContentView.promptForRepoFolderIfNeeded) — the one folder that
    /// contains both `Prism/Resources/PresetRatings.json` and this repo-root's own
    /// `FlaggedPresets.json`. Persists a security-scoped bookmark (Prism is sandboxed — same
    /// mechanism as MilkdropPresetLibrary.setLibraryRoot) so this grant survives across every
    /// future launch without re-prompting: a one-time dialog, not a recurring one.
    func setRepoRoot(_ url: URL) {
        if isAccessingRepoSecurityScopedResource {
            repoRootURL?.stopAccessingSecurityScopedResource()
        }
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Self.repoBookmarkDefaultsKey)
        }
        isAccessingRepoSecurityScopedResource = url.startAccessingSecurityScopedResource()
        repoRootURL = url
        flushCurrentStateIntoRepoFiles()
    }

    private func restoreRepoBookmarkIfAvailable() {
        guard let bookmark = defaults.data(forKey: Self.repoBookmarkDefaultsKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            // The folder was moved/deleted/renamed since the bookmark was saved — fall back to
            // unconfigured (the next rating/flag keypress will prompt again) rather than holding
            // onto a URL that can't actually be accessed.
            return
        }
        isAccessingRepoSecurityScopedResource = url.startAccessingSecurityScopedResource()
        repoRootURL = url
        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(refreshed, forKey: Self.repoBookmarkDefaultsKey)
        }
    }

    /// Once repo write access exists, the live on-disk repo files are more current than what init's
    /// bundled-seed-plus-UserDefaults merge computed: DEBUG rating/flagging no longer writes to
    /// UserDefaults at all once access is granted (see setStars/flag below), and the bundled seed
    /// is only as fresh as the last Xcode build's "Copy Bundle Resources" phase. Reading the repo
    /// files directly here is what makes a same-session relaunch (no rebuild in between) show
    /// exactly what was rated/flagged last session instead of a stale snapshot.
    private func loadFromRepoFilesIfAvailable() {
        guard let starsURL = presetRatingsFileURL,
              let starsData = try? Data(contentsOf: starsURL),
              let stars = try? JSONDecoder().decode([String: MilkdropPresetRating].self, from: starsData) else { return }
        var merged = stars
        if let flagsURL = flaggedPresetsFileURL,
           let flagsData = try? Data(contentsOf: flagsURL),
           let flags = try? JSONDecoder().decode([String: [String]].self, from: flagsData) {
            for (filename, rawIssues) in flags {
                var entry = merged[filename] ?? MilkdropPresetRating()
                entry.issues = Set(rawIssues.compactMap(MilkdropPresetIssue.init(rawValue:)))
                merged[filename] = entry
            }
        }
        ratingsByFilename = merged
    }

    /// One-time migration the instant repo write access is granted (see setRepoRoot): merges every
    /// rating/flag already accumulated in memory (bundled seed + whatever UserDefaults collected
    /// before this grant) into the on-disk repo files, so nothing recorded in an earlier session —
    /// back when this store was still UserDefaults-only — is left stranded there once writes switch
    /// over to direct-to-file. Read-modify-write against what's already on disk, same as every
    /// other write here — never replaces, only adds/updates.
    private func flushCurrentStateIntoRepoFiles() {
        if let starsURL = presetRatingsFileURL {
            var starsOnDisk = (try? Data(contentsOf: starsURL)).flatMap { try? JSONDecoder().decode([String: MilkdropPresetRating].self, from: $0) } ?? [:]
            for (filename, rating) in ratingsByFilename {
                guard let stars = rating.stars else { continue }
                starsOnDisk[filename] = MilkdropPresetRating(stars: stars)
            }
            if let encoded = try? Self.sortedKeysEncoder.encode(starsOnDisk) {
                try? encoded.write(to: starsURL)
            }
        }
        if let flagsURL = flaggedPresetsFileURL {
            var flagsOnDisk = (try? Data(contentsOf: flagsURL)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
            for (filename, rating) in ratingsByFilename {
                guard !rating.issues.isEmpty else { continue }
                let existing = Set(flagsOnDisk[filename]?.compactMap(MilkdropPresetIssue.init(rawValue:)) ?? [])
                flagsOnDisk[filename] = existing.union(rating.issues).map(\.rawValue).sorted()
            }
            if let encoded = try? Self.sortedKeysEncoder.encode(flagsOnDisk) {
                try? encoded.write(to: flagsURL)
            }
        }
    }

    /// Merges a single filename's star rating directly into the real, committed
    /// Prism/Resources/PresetRatings.json — read the whole file, update just this one entry, write
    /// back sorted. Read-modify-write per keypress is fine at this file's size (a few hundred KB).
    private func writeStarsDirectlyToRepo(filename: String, stars: Int) {
        guard let fileURL = presetRatingsFileURL else { return }
        var onDisk = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: MilkdropPresetRating].self, from: $0) } ?? [:]
        onDisk[filename] = MilkdropPresetRating(stars: stars)
        guard let data = try? Self.sortedKeysEncoder.encode(onDisk) else { return }
        try? data.write(to: fileURL)
    }

    /// Same read-modify-write shape as writeStarsDirectlyToRepo, but for the repo-root
    /// FlaggedPresets.json worklist — filename -> sorted array of issue raw values. Flags accumulate
    /// (union with whatever's already on disk for this filename), same as the in-memory store.
    private func writeFlagDirectlyToRepo(filename: String, issues: Set<MilkdropPresetIssue>) {
        guard let fileURL = flaggedPresetsFileURL else { return }
        var onDisk = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        onDisk[filename] = issues.map(\.rawValue).sorted()
        guard let data = try? Self.sortedKeysEncoder.encode(onDisk) else { return }
        try? data.write(to: fileURL)
    }
    #endif

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
    /// issue flags on the same preset untouched — a preset can be both rated and flagged.
    func setStars(_ stars: Int, for url: URL) {
        var entry = ratingsByFilename[url.lastPathComponent] ?? MilkdropPresetRating()
        entry.stars = stars
        ratingsByFilename[url.lastPathComponent] = entry
        #if DEBUG
        if hasRepoWriteAccess {
            writeStarsDirectlyToRepo(filename: url.lastPathComponent, stars: stars)
            return
        }
        #endif
        persist()
    }

    /// Flags `url` with a playback/legibility issue (too jittery, strobing/flashing, too dark, too
    /// bright, too fast) — see this file's own doc comment for the runtime effect this has on
    /// rotation. Leaves any existing star rating and other flags on the same preset untouched —
    /// flags accumulate, they don't replace one another (a preset can be both too jittery and strobing,
    /// say).
    func flag(_ issue: MilkdropPresetIssue, for url: URL) {
        var entry = ratingsByFilename[url.lastPathComponent] ?? MilkdropPresetRating()
        entry.issues.insert(issue)
        ratingsByFilename[url.lastPathComponent] = entry
        #if DEBUG
        if hasRepoWriteAccess {
            writeFlagDirectlyToRepo(filename: url.lastPathComponent, issues: entry.issues)
            return
        }
        #endif
        persist()
    }

    /// True if `url` carries any playback/legibility flag at all — the check
    /// loadNextSequentialPreset/loadBestMatchedPreset use to skip it during automatic rotation.
    /// Doesn't distinguish *which* issue; nothing downstream currently needs to.
    func isFlagged(_ url: URL) -> Bool {
        !(ratingsByFilename[url.lastPathComponent]?.issues.isEmpty ?? true)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(ratingsByFilename) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
