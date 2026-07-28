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
    // File > "Import Preset…" — owned here (rather than ContentView @State) for the same reason
    // as the two Bools above: the menu command and ContentView's `.fileImporter` need to share
    // one source of truth via a Binding.
    @State private var isPresetImporterPresented = false

    init() {
        // A single window, never tabbed — without this, AppKit still adds "Show Tab Bar"/"Show
        // All Tabs" to the View menu by default (on top of the two items above) even though
        // there's no multi-tab UI anywhere in this app.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                isAlbumArtHidden: $isAlbumArtHidden, isTextHidden: $isTextHidden,
                isPresetImporterPresented: $isPresetImporterPresented
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
            }
            // No Edit menu — this app has no text editing/undo/paste surface, so the three
            // command groups that together make up the default Edit menu (Undo/Redo, Cut/Copy/
            // Paste, Select All) are each emptied out here rather than left with their default
            // items; SwiftUI drops the whole menu once none of its groups have any content.
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .textEditing) {}
        }
    }
}
