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
    // View > Hide Album Art / Hide Text — plain "a"/"t" shortcuts (no modifier), matching this
    // app's existing single-letter hotkey convention (see ContentView's onKeyPress). Owned here
    // rather than as ContentView @State so the View menu's checkable Toggle items and the
    // keyboard shortcuts share one source of truth via the same Binding.
    @State private var isAlbumArtHidden = false
    @State private var isTextHidden = false

    init() {
        // A single window, never tabbed — without this, AppKit still adds "Show Tab Bar"/"Show
        // All Tabs" to the View menu by default (on top of the two items above) even though
        // there's no multi-tab UI anywhere in this app.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView(isAlbumArtHidden: $isAlbumArtHidden, isTextHidden: $isTextHidden)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle(isOn: $isAlbumArtHidden) {
                    Label(isAlbumArtHidden ? "Show Album Art" : "Hide Album Art", systemImage: "photo")
                }
                .keyboardShortcut("a", modifiers: [])
                Toggle(isOn: $isTextHidden) {
                    Label(isTextHidden ? "Show Text" : "Hide Text", systemImage: "textformat")
                }
                .keyboardShortcut("t", modifiers: [])
            }
        }
    }
}
