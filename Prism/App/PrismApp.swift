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
    @State private var isMenuBarWaveformHidden = false
    // Owned here (rather than ContentView @State) so the menu bar companion's
    // MenuBarWaveformController can read the same live tap instead of opening a second Core Audio
    // process tap of its own.
    @State private var audioEngine = CoreAudioTapEngine()
    // Purely decorative menu bar status item — see MenuBarWaveformController's doc comment for why
    // it's plain AppKit rather than SwiftUI's `MenuBarExtra`. @State (not a plain `let`) so the
    // same NSStatusItem-backed instance survives across body re-evaluations instead of a fresh one
    // getting created — and a duplicate status item added — every time.
    @State private var menuBarWaveformController = MenuBarWaveformController()
    // View > "Cycle Album Layers" (Cmd-C) — a one-shot trigger, not a persistent Bool like the two
    // above: ContentView's onChange(of: cycleAlbumLayersFromMenu) flips it back to false right
    // after acting on it, same shape as isPresetImporterPresented below.
    @State private var cycleAlbumLayersFromMenu = false
    // File > "Import Preset…" — owned here (rather than ContentView @State) for the same reason
    // as the two Bools above: the menu command and ContentView's `.fileImporter` need to share
    // one source of truth via a Binding.
    @State private var isPresetImporterPresented = false
    // File > "Find Preset…" (Cmd-S) — a persistent toggle (like isAlbumArtHidden above), not a
    // one-shot trigger like isPresetImporterPresented: ContentView's search overlay stays open for
    // as long as this is true, and ContentView itself flips it back to false on Escape/picking a
    // result, same as any other Cmd-toggled panel. Owned here so the menu command and the overlay
    // share one source of truth.
    @State private var isPresetSearchPresented = false
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
    // Opens the custom About window (see the `about` Window scene below) from the CommandGroup
    // that replaces AppKit's default About panel.
    @Environment(\.openWindow) private var openWindow

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
                audioEngine: audioEngine,
                isAlbumArtHidden: $isAlbumArtHidden, isTextHidden: $isTextHidden,
                cycleAlbumLayersFromMenu: $cycleAlbumLayersFromMenu,
                isPresetImporterPresented: $isPresetImporterPresented,
                isPresetSearchPresented: $isPresetSearchPresented,
                sessionHistoryStore: sessionHistoryStore, sessionPresetLog: $sessionPresetLog,
                presetToLoadFromMenu: $presetToLoadFromMenu
            )
            .onAppear {
                // Restores the user's alternate app icon choice - can't happen in init() above,
                // since NSApp isn't set up that early in a SwiftUI App's lifecycle yet (see
                // AppIconManager's doc comment).
                AppIconManager.apply()
                // Same NSApp-isn't-ready-in-init() reasoning applies to the status item.
                menuBarWaveformController.setVisible(!isMenuBarWaveformHidden, audioEngine: audioEngine)
            }
            .onChange(of: isMenuBarWaveformHidden) { _, hidden in
                menuBarWaveformController.setVisible(!hidden, audioEngine: audioEngine)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Replaces AppKit's default About panel with the custom one in AboutView, opened via
            // the `about` Window scene below.
            CommandGroup(replacing: .appInfo) {
                Button("About Prism") {
                    openWindow(id: "about")
                }
            }
            // Replaces the default "New Window" item — this app only ever has the one window, so
            // Cmd-I for importing a preset is a more useful thing to put at that File-menu slot.
            CommandGroup(replacing: .newItem) {
                Button {
                    isPresetImporterPresented = true
                } label: {
                    Label("Import .milk Preset…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("i", modifiers: .command)
                // Search-by-name alternative to Cmd-I's file picker/drag-and-drop — jumps straight
                // to any preset already in the current library by typing its name instead of
                // hunting for it in Finder. Toggles the same way Cmd-A/Cmd-T do below (pressing it
                // again while the search overlay is open closes it).
                Button {
                    isPresetSearchPresented.toggle()
                } label: {
                    Label("Find Preset…", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("s", modifiers: .command)
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
                Toggle(isOn: $isMenuBarWaveformHidden) {
                    Label(
                        isMenuBarWaveformHidden ? "Show Menu Bar Waveform" : "Hide Menu Bar Waveform",
                        systemImage: "waveform"
                    )
                }
                .keyboardShortcut("b", modifiers: .command)
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

        // `Prism > Settings…` (Cmd-,), added to the app menu automatically by this scene type.
        Settings {
            SettingsView()
        }

        // Single fixed-size About panel — `Window` (rather than `WindowGroup`) means macOS
        // reuses the same instance instead of spawning duplicates if "About Prism" is chosen
        // again while it's already open.
        Window("About Prism", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}
