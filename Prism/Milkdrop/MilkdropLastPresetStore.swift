//
//  MilkdropLastPresetStore.swift
//  Prism
//
//  Persists a security-scoped bookmark for whichever `.milk` preset most recently loaded
//  successfully — via a manual (Cmd-O) pick or a random library draw — so Prism can reopen the
//  same preset automatically on the next launch instead of starting blank (TO DO.md Phase 4:
//  "Persist last-loaded preset/folder across launches"). Independent of MilkdropPresetLibrary's
//  own bookmark: that one remembers the *library folder* random-cycling draws from (already
//  persisted), this one remembers the single *file* that was actually on screen when the app
//  last quit. Same security-scoped-bookmark mechanism as MilkdropPresetLibrary, since Prism is
//  sandboxed (com.apple.security.files.user-selected.read-write in Prism.entitlements).
//

import Foundation

final class MilkdropLastPresetStore {
    private static let bookmarkDefaultsKey = "MilkdropLastPresetBookmark"

    /// Injectable so tests exercise real bookmark persistence without touching the actual app's
    /// defaults domain (`.standard` in production) — same pattern as MilkdropPresetLibrary.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Call after every successful `loadPreset(from:)`, regardless of how the URL was obtained
    /// (manual pick or random library draw), so whichever preset was on screen last is what
    /// reopens next launch.
    func rememberLoaded(_ url: URL) {
        guard let bookmark = Self.makeBookmark(for: url) else {
            // Bookmark creation failing leaves this session's preset unaffected — it just won't
            // be restored next launch, same degraded-but-functional fallback MilkdropPresetLibrary
            // uses for its own bookmark.
            return
        }
        defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
    }

    /// `.withSecurityScope` bookmark creation throws for any URL the sandbox never granted a
    /// scoped extension for — which includes every preset loaded from the app's own bundled
    /// preset pack (see MilkdropPresetLibrary.useBundledPresetsIfAvailable's own doc comment: "no
    /// security scope needed — it's inside the app's own container"). That bundled pack is the
    /// only source on most installs (no external library folder ever picked), so requiring
    /// `.withSecurityScope` unconditionally here silently failed on *every* preset load — this
    /// store's defaults key never got written at all, and "restore last preset" quietly never
    /// fired. Falling back to a plain (unscoped) bookmark for exactly that case still round-trips
    /// fine: a plain bookmark resolves correctly for a bundle-relative resource, which needs no
    /// sandbox extension to read in the first place.
    private static func makeBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves the last-remembered preset, if any, granting security-scoped access for the
    /// duration of `body` (mirroring ContentView's own single-file `.fileImporter` access
    /// pattern: start, act, stop — not a persistently held scope like the library folder's,
    /// since this is a one-shot restore at launch, not a folder random-cycling repeatedly reads
    /// from) and returning whatever `body` returns. Returns `nil` without calling `body` if
    /// nothing is remembered or the bookmark can no longer be resolved (the file was
    /// moved/deleted/renamed since it was last remembered).
    @discardableResult
    func withLastPreset<T>(_ body: (URL) -> T) -> T? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkDefaultsKey) else { return nil }

        // Mirrors makeBookmark's create-side fallback: a bundled preset's bookmark was never
        // security-scoped to begin with, so resolving it with .withSecurityScope needlessly risks
        // the option itself rejecting a plain bookmark - try scoped first (the common case for a
        // user-picked file), then plain.
        var isStale = false
        let url: URL
        if let scoped = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            url = scoped
        } else if let plain = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            url = plain
        } else {
            return nil
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let result = body(url)

        if isStale, let refreshed = Self.makeBookmark(for: url) {
            defaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
        }

        return result
    }
}
