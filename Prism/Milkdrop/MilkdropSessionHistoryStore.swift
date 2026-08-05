//
//  MilkdropSessionHistoryStore.swift
//  Prism
//
//  Backs the History menu bar item: an append-only, order-preserving log of every preset that's
//  actually played this session (duplicates included — replaying an earlier preset adds another
//  entry rather than moving/deduping the original), plus an immutable snapshot of the previous
//  session's log for the "Last Session" submenu. Distinct from ContentView's `presetHistory`,
//  which is a Back/Forward navigation buffer that truncates on a fresh branch — this log never
//  truncates and exists purely for the menu, not for Left/Right stepping.
//
//  Prism has no clean "session ended" hook (quitting doesn't run app code), so "end of session"
//  is approximated by continuously persisting the current session's log as it grows, and treating
//  whatever's there at the *next* launch as belonging to the session that just ended — the same
//  crash-safe, no-explicit-save-point approach as MilkdropLastPresetStore. Bookmark-based (not
//  plain URLs) for the same sandboxing reason as MilkdropLastPresetStore/MilkdropPresetLibrary —
//  Prism is sandboxed (com.apple.security.files.user-selected.read-write).
//

import Foundation

final class MilkdropSessionHistoryStore {
    private static let currentSessionDefaultsKey = "MilkdropCurrentSessionHistoryBookmarks"
    private static let lastSessionDefaultsKey = "MilkdropLastSessionHistoryBookmarks"

    /// Injectable so tests exercise real bookmark persistence without touching the actual app's
    /// defaults domain (`.standard` in production) — same pattern as MilkdropLastPresetStore.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Call once at launch, before any preset loads this run. Whatever's saved under the
    /// "current session" key is what the *previous* run logged before it quit (with no clean
    /// shutdown hook, that key just keeps accumulating until something rotates it) — so it
    /// becomes this launch's frozen "Last Session" snapshot, and the current-session slot is
    /// cleared so this run's log starts empty. Returns the resolved URLs for the History menu's
    /// "Last Session" submenu to show immediately; a bookmark that no longer resolves (file
    /// moved/deleted since last session) is silently dropped rather than shown as a broken entry.
    @discardableResult
    func rotateSessionsAtLaunch() -> [URL] {
        let previous = bookmarks(forKey: Self.currentSessionDefaultsKey)
        defaults.set(previous, forKey: Self.lastSessionDefaultsKey)
        defaults.removeObject(forKey: Self.currentSessionDefaultsKey)
        return previous.compactMap(resolve)
    }

    /// Call after every successful preset load this session, in play order — including replays
    /// of a preset already in the log, so the persisted record matches the in-memory log
    /// ContentView shows under the History menu's top-level (non-"Last Session") section.
    func appendToCurrentSession(_ url: URL) {
        guard let bookmark = Self.makeBookmark(for: url) else {
            // Same degraded-but-functional fallback as MilkdropLastPresetStore: the in-memory
            // menu still reflects this play, it just won't survive into next session's rotation.
            return
        }
        var current = bookmarks(forKey: Self.currentSessionDefaultsKey)
        current.append(bookmark)
        defaults.set(current, forKey: Self.currentSessionDefaultsKey)
    }

    /// `.withSecurityScope` bookmark creation throws for any URL the sandbox never granted a
    /// scoped extension for — which includes every preset loaded from the app's own bundled
    /// preset pack (see MilkdropPresetLibrary.useBundledPresetsIfAvailable's own doc comment: "no
    /// security scope needed — it's inside the app's own container"). That bundled pack is the
    /// only source on most installs (no external library folder ever picked), so requiring
    /// `.withSecurityScope` unconditionally here silently failed on *every* preset load — this
    /// store's "current session" key never got written at all, so the next launch's "Last
    /// Session" menu always rotated in an empty log. Falling back to a plain (unscoped) bookmark
    /// for exactly that case still round-trips fine: a plain bookmark resolves correctly for a
    /// bundle-relative resource, which needs no sandbox extension to read in the first place.
    private static func makeBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func bookmarks(forKey key: String) -> [Data] {
        defaults.array(forKey: key) as? [Data] ?? []
    }

    private func resolve(_ bookmark: Data) -> URL? {
        // Mirrors makeBookmark's create-side fallback - try scoped first (the common case for a
        // user-picked file), then plain (the bundled-preset case).
        var isStale = false
        if let scoped = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return scoped
        }
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}
