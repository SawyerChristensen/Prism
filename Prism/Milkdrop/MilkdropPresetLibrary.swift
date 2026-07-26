//
//  MilkdropPresetLibrary.swift
//  Prism
//
//  The "point at an external folder" preset library decided in TO DO.md's testing-policy notes:
//  Prism never bundles/copies a preset pack (unclear redistribution rights, 259MB+ of content),
//  so this just remembers which folder the user picked and lists the `.milk` files under it.
//  Persisted via a security-scoped bookmark (Prism is sandboxed — see Prism.entitlements'
//  com.apple.security.files.user-selected.read-write) so access survives across app launches
//  without re-prompting the user every single time, the same mechanism System Settings-style
//  "remembered folder" pickers use.
//

import Foundation

@Observable
final class MilkdropPresetLibrary {
    private static let bookmarkDefaultsKey = "MilkdropPresetLibraryBookmark"

    private(set) var rootURL: URL?
    /// Every `.milk` file found under `rootURL`, scanned once when the root is (re)set — not
    /// re-scanned on every random pick, since a pack this size (real ones run into the thousands
    /// of files) makes a fresh recursive directory walk on every keypress wasteful.
    private(set) var presetURLs: [URL] = []
    private var isAccessingSecurityScopedResource = false
    /// Injectable so tests exercise real bookmark persistence without touching the actual app's
    /// defaults domain (`.standard` in production).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreFromSavedBookmark()
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

    /// Picks a uniformly random preset from the current scan, or `nil` if no library is configured
    /// (or the configured folder genuinely has no `.milk` files in it).
    func randomPresetURL() -> URL? {
        presetURLs.randomElement()
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

    private func stopAccessingIfNeeded() {
        if isAccessingSecurityScopedResource {
            rootURL?.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScopedResource = false
    }

    private func rescan() {
        guard let rootURL, let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            presetURLs = []
            return
        }
        presetURLs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "milk" }
    }
}
