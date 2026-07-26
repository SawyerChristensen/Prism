//
//  ContentView.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var audioEngine = CoreAudioTapEngine()
    @State private var nowPlaying = NowPlayingManager()
    @State private var permissions = PermissionsManager()
    @State private var visualizerModel = MilkdropVisualizerModel()
    @State private var presetLibrary = MilkdropPresetLibrary()
    @State private var lastPresetStore = MilkdropLastPresetStore()
    @State private var isPresetImporterPresented = false
    @State private var isLibraryFolderPickerPresented = false
    // Idle auto-cycling (TO DO.md Phase 3) — "A" toggles it on/off. Backed by a sleeping Task
    // rather than Foundation's Timer, matching the Task-based delay already used elsewhere in
    // this file (the "S" save confirmation). Any successful preset load, manual or automatic,
    // restarts the sleep window (see restartAutoCycleTimerIfNeeded) so a manual skip right before
    // the interval elapses doesn't get immediately followed by an auto-cycle a moment later.
    @State private var isAutoCycleEnabled = false
    @State private var autoCycleTask: Task<Void, Never>?
    private static let autoCycleInterval: Duration = .seconds(20)
    // Transient confirmation after "S" saves the current M/T settings for this album (see
    // NowPlayingManager.saveCurrentArtworkPreference) — there's no other visible signal that a
    // save happened, since M/T themselves are just a live preview now, not an auto-save.
    @State private var showSavedConfirmation = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let bgColor = nowPlaying.albumBackgroundColor.map { Color(nsColor: $0) } ?? Color(NSColor.windowBackgroundColor)
        let fgColor = nowPlaying.albumForegroundColor.map { Color(nsColor: $0) } ?? .accentColor

        let bassEnergy = audioEngine.levels.prefix(4).reduce(0, +) / 4

        ZStack {
            // The wave
            MilkdropVisualizerView(audioEngine: audioEngine, color: fgColor, bassEnergy: bassEnergy, model: visualizerModel, onTap: { loadRandomPreset() })
            
            // The album art
            if let track = nowPlaying.trackName, let artist = nowPlaying.artistName {
                if let artwork = nowPlaying.artwork {
                    // Real alpha transparency where the artwork's own background was keyed
                    // out in NowPlayingManager (see NSImage.keyingOutBackground) — not a
                    // blend mode, so only the actual background pixels go transparent, not
                    // every dark/light pixel that happens to be part of the subject.
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 300, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        //.shadow(color: fgColor, radius: 6)
                } /*else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(width: 250, height: 250)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }*/
                
                VStack {
                    Spacer() // Text pinned to the bottom
                    
                    HStack {
                        Text(track)
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(fgColor)
                            .padding()
                        
                        Spacer()
                        
                        Text(artist)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(fgColor.opacity(0.8))
                            .padding()
                    }
                }
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(bgColor)
        .animation(.easeInOut(duration: 0.5), value: bgColor)
        // Wave-only .milk preset loading (see MilkdropPresetFile.swift/MilkdropVisualizerModel):
        // "O" opens a file picker, and the preset's name shows briefly so there's some feedback
        // that a load actually happened, since nothing else in the UI names the active preset.
        .overlay(alignment: .topLeading) {
            if let presetName = visualizerModel.presetName {
                Text(presetName)
                    .font(.caption)
                    .foregroundStyle(fgColor.opacity(0.6))
                    .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            // "T"/"M" (below) drive nowPlaying.includesTextOverlay/maskingMode directly — stand-
            // ins for future Settings controls; only shown off their defaults so this stays
            // invisible day to day.
            VStack(alignment: .trailing, spacing: 4) {
                // Performance counter — smoothed (not raw per-frame 1/dt) FPS, pushed once per
                // frame by MilkdropMetalRenderer.draw(in:) into visualizerModel.displayFPS.
                Text("\(Int(visualizerModel.displayFPS.rounded())) FPS")
                    .monospacedDigit()
                if showSavedConfirmation {
                    Text("Saved for this album")
                }
                if isAutoCycleEnabled {
                    Text("Auto-Cycle On")
                }
                if !nowPlaying.processingEnabled {
                    Text("Processing Off")
                } else {
                    if !nowPlaying.includesTextOverlay {
                        Text("Text Overlay Off")
                    }
                    if nowPlaying.maskingMode != .combined {
                        Text(nowPlaying.maskingMode.label)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(fgColor.opacity(0.6))
            .padding(8)
        }
        .fileImporter(
            isPresented: $isPresetImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "milk") ?? .plainText]
        ) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            loadPresetAndTrack(from: url)
        }
        // Folder (not single-file) picker for the preset library random-cycling draws from — see
        // MilkdropPresetLibrary.swift. Triggered explicitly (L) or implicitly the first time Space/
        // tap is used before any library folder has been picked yet.
        .fileImporter(
            isPresented: $isLibraryFolderPickerPresented,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else { return }
            presetLibrary.setLibraryRoot(url)
            loadRandomPreset()
        }
        .alert(
            "Couldn't Load Preset",
            isPresented: Binding(
                get: { visualizerModel.presetLoadError != nil },
                set: { if !$0 { visualizerModel.presetLoadError = nil } }
            )
        ) {
            Button("OK") { visualizerModel.presetLoadError = nil }
        } message: {
            Text(visualizerModel.presetLoadError ?? "")
        }
        // Keyboard control surface, mirroring the spirit of MilkDrop pluginshell's hotkeys
        // (arrow keys / F / Esc) even though there's no preset deck to navigate here: Space jumps
        // to a random preset from the loaded library (same action as tapping the visualizer),
        // F toggles fullscreen, L (re)picks the library folder, A toggles idle auto-cycling.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [" ", "f", "F", "o", "O", "l", "L", "a", "A", "t", "T", "m", "M", "p", "P", "s", "S"]) { press in
            switch press.characters {
            case " ":
                loadRandomPreset()
                return .handled
            case "f", "F":
                NSApp.keyWindow?.toggleFullScreen(nil)
                return .handled
            case "o", "O":
                isPresetImporterPresented = true
                return .handled
            case "l", "L":
                isLibraryFolderPickerPresented = true
                return .handled
            case "a", "A":
                toggleAutoCycle()
                return .handled
            case "t", "T":
                nowPlaying.includesTextOverlay.toggle()
                return .handled
            case "m", "M":
                let all = ArtworkMaskingMode.allCases
                let idx = all.firstIndex(of: nowPlaying.maskingMode) ?? 0
                nowPlaying.maskingMode = all[(idx + 1) % all.count]
                return .handled
            case "p", "P":
                nowPlaying.processingEnabled.toggle()
                return .handled
            case "s", "S":
                nowPlaying.saveCurrentArtworkPreference()
                showSavedConfirmation = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    showSavedConfirmation = false
                }
                return .handled
            default:
                return .ignored
            }
        }
        .onAppear {
            PrismDebug.trace("ContentView.onAppear")
            permissions.checkAndRequestPermissions()
            nowPlaying.startPolling()
            isFocused = true
            // Restore whichever preset was on screen last launch (TO DO.md Phase 4). Guarded on
            // presetURL == nil so a second onAppear (SwiftUI can re-fire this) never clobbers a
            // preset the user has since picked.
            if visualizerModel.presetURL == nil {
                lastPresetStore.withLastPreset { url in
                    loadPresetAndTrack(from: url)
                }
            }
            PrismDebug.trace("ContentView.onAppear returned (both calls are async/backgrounded)")
        }
        .task {
            PrismDebug.trace("ContentView.task -> audioEngine.start() awaiting")
            await audioEngine.start()
            PrismDebug.trace("ContentView.task -> audioEngine.start() returned")
        }
    }

    /// Space/tap's action: jump straight to a random preset from the configured library — no
    /// preset history/prev-next concept exists yet (see TO DO.md's Phase 4), so every "skip" is an
    /// independent uniform-random draw from the whole scanned folder, same as pressing it again
    /// could re-pick the same file. Prompts for a library folder instead, the first time this runs
    /// with none configured yet — mirrors Phase 4's "first-launch (or Settings-triggered) folder
    /// picker" decision without needing a separate onboarding flow.
    /// `resetAutoCycle` is false only when the auto-cycle loop itself calls this — its own
    /// while-loop cadence already provides the next interval, so restarting the countdown here too
    /// would just replace the in-flight sleeping Task with an equivalent new one for no reason.
    private func loadRandomPreset(resetAutoCycle: Bool = true) {
        guard presetLibrary.isConfigured else {
            isLibraryFolderPickerPresented = true
            return
        }
        guard let url = presetLibrary.randomPresetURL() else { return }
        loadPresetAndTrack(from: url, resetAutoCycle: resetAutoCycle)
    }

    /// Centralizes the bookkeeping every successful preset load needs, regardless of how the URL
    /// was obtained (manual Cmd-O pick, random library draw, or restoring the last-loaded preset
    /// at launch): remembers it for next launch's restore (MilkdropLastPresetStore) and restarts
    /// the idle auto-cycle countdown so a manual skip doesn't get immediately followed by an
    /// auto-cycle a moment later.
    private func loadPresetAndTrack(from url: URL, resetAutoCycle: Bool = true) {
        visualizerModel.loadPreset(from: url)
        guard visualizerModel.presetLoadError == nil else { return }
        lastPresetStore.rememberLoaded(url)
        if resetAutoCycle {
            restartAutoCycleTimerIfNeeded()
        }
    }

    private func toggleAutoCycle() {
        isAutoCycleEnabled.toggle()
        if isAutoCycleEnabled {
            restartAutoCycleTimerIfNeeded()
        } else {
            autoCycleTask?.cancel()
            autoCycleTask = nil
        }
    }

    /// (Re)starts the sleep-then-skip loop from a fresh interval. A no-op when auto-cycling is
    /// off, so this is safe to call unconditionally from loadPresetAndTrack after every load —
    /// Task-based (see the "S" save-confirmation above for the same idiom elsewhere in this file)
    /// rather than Foundation's Timer.
    private func restartAutoCycleTimerIfNeeded() {
        guard isAutoCycleEnabled else { return }
        autoCycleTask?.cancel()
        autoCycleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoCycleInterval)
                guard !Task.isCancelled else { return }
                loadRandomPreset(resetAutoCycle: false)
            }
        }
    }
}
