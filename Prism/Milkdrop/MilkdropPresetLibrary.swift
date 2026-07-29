//
//  MilkdropPresetLibrary.swift
//  Prism
//
//  Defaults to the preset pack bundled into the app's own Resources/Presets (staged at build time
//  by Scripts/copy_bundled_presets.sh, `.milk` files only — the pack's per-preset `.jpg` NestDrop
//  preview thumbnails are excluded, since Prism never renders them and they're ~90% of the pack's
//  raw size) so a freshly downloaded/exported build has a working library with no setup. A user
//  can still override this by picking their own folder (the "L" key / library-folder picker);
//  that pick is remembered via a security-scoped bookmark (Prism is sandboxed — see
//  Prism.entitlements' com.apple.security.files.user-selected.read-write) so access survives
//  across app launches without re-prompting every time, the same mechanism System Settings-style
//  "remembered folder" pickers use. The bundled fallback needs no such bookmark — it's inside the
//  app's own bundle, always readable regardless of sandboxing.
//

import Foundation

@Observable
final class MilkdropPresetLibrary {
    private static let bookmarkDefaultsKey = "MilkdropPresetLibraryBookmark"

    private(set) var rootURL: URL?
    /// The full recursive scan of `rootURL`, sorted by path — kept separately from `presetURLs`
    /// so `filterToFavorites`/`clearFavoritesFilter` can narrow/restore the working set without
    /// re-walking the filesystem.
    private var scannedPresetURLs: [URL] = []
    /// What sequential discovery actually walks: either the full scan, or a favorites-narrowed
    /// subset of it (see `filterToFavorites`). Scanned once when the root is (re)set — not
    /// re-scanned on every sequential step, since a pack this size (real ones run into the
    /// thousands of files) makes a fresh recursive directory walk on every keypress wasteful.
    /// Sorted by path so sequential discovery has a stable, repeatable order across launches
    /// (`FileManager.enumerator` itself makes no ordering guarantee).
    private(set) var presetURLs: [URL] = []
    /// Whether `presetURLs` is currently narrowed by `filterToFavorites` rather than showing the
    /// full scan.
    private(set) var isShowingFavoritesOnly = false
    private var isAccessingSecurityScopedResource = false
    /// Injectable so tests exercise real bookmark persistence without touching the actual app's
    /// defaults domain (`.standard` in production).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreFromSavedBookmark()
        if rootURL == nil {
            useBundledPresetsIfAvailable()
        }
    }

    deinit {
        if isAccessingSecurityScopedResource {
            rootURL?.stopAccessingSecurityScopedResource()
        }
    }

    var isConfigured: Bool { rootURL != nil }

    /// Call after the user picks a folder via a folder-selecting file importer. Persists a
    /// security-scoped bookmark for next launch and rescans immediately so the very first random
    /// pick after configuring the library works without a second action.
    func setLibraryRoot(_ url: URL) {
        stopAccessingIfNeeded()

        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
        }
        // Bookmark persistence failing (shouldn't happen for a folder the user just picked through
        // a real open panel) still leaves the library usable for the rest of this session — it
        // just won't survive a relaunch, same degraded-but-functional fallback as elsewhere in Prism.

        isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
        rootURL = url
        rescan()
    }

    /// The next preset in sorted order after `currentURL`, wrapping around to the first preset
    /// past the end of the list. `currentURL` being `nil` or not found in the current scan (no
    /// preset loaded yet, or it was loaded from outside this library folder via a manual Cmd-O
    /// pick) starts back at the first preset. Returns `nil` if no library is configured or the
    /// configured folder genuinely has no `.milk` files in it.
    func nextSequentialPresetURL(after currentURL: URL?) -> URL? {
        guard !presetURLs.isEmpty else { return nil }
        guard let currentURL, let index = presetURLs.firstIndex(of: currentURL) else {
            return presetURLs.first
        }
        return presetURLs[(index + 1) % presetURLs.count]
    }

    /// Narrows sequential discovery down to only the files named in a NestDrop bundle's favorites
    /// list (see `MilkdropNestDropFavoritesList`) — e.g. reviewing a curated subset instead of the
    /// whole corpus. Matches by filename only (NestDrop bundles don't record folder paths), safe
    /// here since the real corpus this targets has zero duplicate filenames across it. Degrades
    /// silently to an empty `presetURLs` (not a crash) if the bundle can't be parsed or none of
    /// its names match anything under the current scan.
    func filterToFavorites(from bundleURL: URL) {
        let names = MilkdropNestDropFavoritesList.presetFilenames(contentsOf: bundleURL)
        presetURLs = scannedPresetURLs.filter { names.contains($0.lastPathComponent) }
        isShowingFavoritesOnly = true
    }

    /// Reverts `filterToFavorites`, restoring the full recursive scan.
    func clearFavoritesFilter() {
        presetURLs = scannedPresetURLs
        isShowingFavoritesOnly = false
    }

    private func restoreFromSavedBookmark() {
        guard let bookmark = defaults.data(forKey: Self.bookmarkDefaultsKey) else { return }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            // The folder was moved/deleted/renamed since the bookmark was saved — fall back to
            // unconfigured (the next space-press/tap will prompt for a folder again) rather than
            // holding onto a URL that can't actually be accessed.
            return
        }

        isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
        rootURL = url
        rescan()

        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
        }
    }

    /// Points `rootURL` at the app's own bundled preset pack (no security scope needed — it's
    /// inside the app's own bundle, not a user-selected external location) when no external
    /// library has ever been configured. A no-op if the bundle has no `Presets` folder (e.g. a
    /// dev build made on a machine without the source pack — see copy_bundled_presets.sh).
    private func useBundledPresetsIfAvailable() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("Presets", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.path) else { return }
        rootURL = bundled
        rescan()
    }

    private func stopAccessingIfNeeded() {
        if isAccessingSecurityScopedResource {
            rootURL?.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScopedResource = false
    }

    private func rescan() {
        isShowingFavoritesOnly = false
        guard let rootURL, let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            scannedPresetURLs = []
            presetURLs = []
            return
        }
        scannedPresetURLs = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "milk" }
            .sorted { $0.path < $1.path }
        presetURLs = scannedPresetURLs
    }
}
