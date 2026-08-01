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
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            // Same degraded-but-functional fallback as MilkdropLastPresetStore: the in-memory
            // menu still reflects this play, it just won't survive into next session's rotation.
            return
        }
        var current = bookmarks(forKey: Self.currentSessionDefaultsKey)
        current.append(bookmark)
        defaults.set(current, forKey: Self.currentSessionDefaultsKey)
    }

    private func bookmarks(forKey key: String) -> [Data] {
        defaults.array(forKey: key) as? [Data] ?? []
    }

    private func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}
