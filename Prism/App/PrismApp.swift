//
//  PrismApp.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import SwiftUI
import AppKit

@main
struct PrismApp: App {
    // View > Hide Album Art / Hide Text — Cmd-A/Cmd-T, matching Import's Cmd-I (see
    // CommandGroup(replacing: .newItem) below) now that the Edit menu (and its Cmd-A "Select
    // All") is gone. Owned here rather than as ContentView @State so the View menu's checkable
    // Toggle items and the keyboard shortcuts share one source of truth via the same Binding.
    @State private var isAlbumArtHidden = false
    @State private var isTextHidden = false
    // View > "Cycle Album Layers" (Cmd-C) — a one-shot trigger, not a persistent Bool like the two
    // above: ContentView's onChange(of: cycleAlbumLayersFromMenu) flips it back to false right
    // after acting on it, same shape as isPresetImporterPresented below.
    @State private var cycleAlbumLayersFromMenu = false
    // File > "Import Preset…" — owned here (rather than ContentView @State) for the same reason
    // as the two Bools above: the menu command and ContentView's `.fileImporter` need to share
    // one source of truth via a Binding.
    @State private var isPresetImporterPresented = false
    // History menu bar item — owned here (not ContentView @State) since SwiftUI's `.commands`
    // menus are only reachable from the App scene, same reason as the properties above. Persisted
    // history is a class (MilkdropSessionHistoryStore), so ContentView gets a plain reference to
    // it (mutating it doesn't need a Binding); `sessionPresetLog` is the in-memory mirror of its
    // current-session log that the History menu itself renders, so it does need a Binding since
    // ContentView is what appends to it. `lastSessionPresetLog` is resolved once in init() below
    // and never changes for the rest of this run, so ContentView never needs to see or touch it.
    @State private var sessionHistoryStore: MilkdropSessionHistoryStore
    @State private var sessionPresetLog: [URL] = []
    @State private var lastSessionPresetLog: [URL]
    // Set by a History/Last Session menu click; ContentView's onChange picks it up, does the
    // actual (security-scoped) load, then resets this to nil — same "menu sets a Bool/URL,
    // ContentView's the one that owns the resources to act on it" split as isPresetImporterPresented.
    @State private var presetToLoadFromMenu: URL?

    init() {
        // A single window, never tabbed — without this, AppKit still adds "Show Tab Bar"/"Show
        // All Tabs" to the View menu by default (on top of the two items above) even though
        // there's no multi-tab UI anywhere in this app.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Rotate session history before anything can load a preset: whatever the previous run
        // logged (it never got a clean "session ended" signal — see
        // MilkdropSessionHistoryStore's doc comment) becomes this run's frozen "Last Session"
        // list, and the current-session slot starts empty for this run's own log.
        let historyStore = MilkdropSessionHistoryStore()
        _lastSessionPresetLog = State(initialValue: historyStore.rotateSessionsAtLaunch())
        _sessionHistoryStore = State(initialValue: historyStore)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                isAlbumArtHidden: $isAlbumArtHidden, isTextHidden: $isTextHidden,
                cycleAlbumLayersFromMenu: $cycleAlbumLayersFromMenu,
                isPresetImporterPresented: $isPresetImporterPresented,
                sessionHistoryStore: sessionHistoryStore, sessionPresetLog: $sessionPresetLog,
                presetToLoadFromMenu: $presetToLoadFromMenu
            )
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Replaces the default "New Window" item — this app only ever has the one window, so
            // Cmd-I for importing a preset is a more useful thing to put at that File-menu slot.
            CommandGroup(replacing: .newItem) {
                Button {
                    isPresetImporterPresented = true
                } label: {
                    Label("Import Milk Preset…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Toggle(isOn: $isAlbumArtHidden) {
                    Label(isAlbumArtHidden ? "Show Album Art" : "Hide Album Art", systemImage: "photo")
                }
                .keyboardShortcut("a", modifiers: .command)
                Toggle(isOn: $isTextHidden) {
                    Label(isTextHidden ? "Show Text" : "Hide Text", systemImage: "textformat")
                }
                .keyboardShortcut("t", modifiers: .command)
                // Was the bare "M" hotkey; moved to Cmd-C (ContentView's onKeyPress no longer
                // handles "M" at all — see its keyboard-control-surface doc comment) so it shows up
                // in the View menu alongside Hide Album Art/Hide Text rather than being invisible.
                Button {
                    cycleAlbumLayersFromMenu = true
                } label: {
                    Label("Cycle Album Layers", systemImage: "square.3.layers.3d")
                }
                .keyboardShortcut("c", modifiers: .command)
            }
            // No Edit menu — this app has no text editing/undo/paste surface, so the three
            // command groups that together make up the default Edit menu (Undo/Redo, Cut/Copy/
            // Paste, Select All) are each emptied out here rather than left with their default
            // items; SwiftUI drops the whole menu once none of its groups have any content.
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .textEditing) {}
            // CommandMenu (not a CommandGroup insertion into an existing menu) puts a brand new
            // "History" item in the menu bar. Top section is this session's play log, duplicates
            // and all — every entry, including replays, comes from ContentView's
            // loadPresetAndTrack unconditionally appending to sessionPresetLog. Displayed most-
            // recent-first (`.reversed()`) even though the backing array itself stays oldest-
            // first/append-only — append-only is what makes "truncate nothing, just keep adding"
            // simple, but most-recent-at-top is the more useful reading order for a menu you
            // reopen after every few presets. "Last Session" is a frozen snapshot from the
            // previous run (see MilkdropSessionHistoryStore), same reversed-for-display treatment;
            // clicking an entry there loads it and, since it goes through the same
            // presetToLoadFromMenu -> loadPresetAndTrack path as the top section, appends onto
            // *this* session's log rather than mutating the immutable last-session list.
            CommandMenu("History") {
                if sessionPresetLog.isEmpty {
                    Text("No Presets Played Yet")
                } else {
                    ForEach(Array(sessionPresetLog.enumerated().reversed()), id: \.offset) { _, url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            presetToLoadFromMenu = url
                        }
                    }
                }
                Divider()
                Menu("Last Session") {
                    if lastSessionPresetLog.isEmpty {
                        Text("No Previous Session")
                    } else {
                        ForEach(Array(lastSessionPresetLog.enumerated().reversed()), id: \.offset) { _, url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                presetToLoadFromMenu = url
                            }
                        }
                    }
                }
            }
        }
    }
}
