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
    @State private var visualizerModel = ProjectMVisualizerModel()
    @State private var presetLibrary = MilkdropPresetLibrary()
    @State private var lastPresetStore = MilkdropLastPresetStore()
    @State private var ratingStore = MilkdropPresetRatingStore()
    @State private var isPresetImporterPresented = false
    @State private var isLibraryFolderPickerPresented = false
    // Drag-and-drop counterpart to "O"'s file picker — true only while a drag carrying a `.milk`
    // file is actually hovering the window, driven by `PresetDroppableMTKView.onDropTargetChanged`
    // via `handlePresetDrop`'s sibling wiring below, for the brief highlight overlay that's the
    // only feedback a valid drop target exists at all.
    @State private var isDropTargeted = false
    // "U" (User Profile) picks a NestDrop bundle XML (e.g. a preset pack's own
    // `User Profile/*.xml` favorites export) and narrows sequential discovery down to just the
    // files it names — see MilkdropPresetLibrary.filterToFavorites/MilkdropNestDropFavoritesList.
    @State private var isFavoritesBundlePickerPresented = false
    // Idle auto-cycling (TO DO.md Phase 3) — "A" toggles it on/off. Backed by a sleeping Task
    // rather than Foundation's Timer, matching the Task-based delay already used elsewhere in
    // this file (the "S" save confirmation). Any successful preset load, manual or automatic,
    // restarts the sleep window (see restartAutoCycleTimerIfNeeded) so a manual skip right before
    // the interval elapses doesn't get immediately followed by an auto-cycle a moment later.
    @State private var isAutoCycleEnabled = false
    @State private var autoCycleTask: Task<Void, Never>?
    private static let autoCycleInterval: Duration = .seconds(20)
    // Preset history (TO DO.md's "other" section) — every successful load (random draw, manual
    // Cmd-O pick, or the launch-time restore) appends here, so Left/Right can step back/forward
    // through what's actually been seen this session rather than each "skip" being a one-way,
    // unrecoverable random draw. Standard browser-history shape: `presetHistoryIndex` is the
    // currently-displayed entry, and loading a genuinely new preset (not a Left/Right navigation)
    // truncates anything past it before appending, same as a fresh navigation in a browser drops
    // a stale forward branch. There's still no *saved* playlist concept — this is session-only.
    @State private var presetHistory: [URL] = []
    @State private var presetHistoryIndex = -1
    // Transient confirmation after "S" saves the current M/T settings for this album (see
    // NowPlayingManager.saveCurrentArtworkPreference) — there's no other visible signal that a
    // save happened, since M/T themselves are just a live preview now, not an auto-save.
    @State private var showSavedConfirmation = false
    // Transient confirmation after a "1"-"5"/"w" rating keybind records a rating/flag for the
    // preset just left behind (see rateCurrentPreset/flagCurrentPresetWhite) — same one-shot,
    // auto-clearing Task.sleep idiom as showSavedConfirmation above, since a review pass through
    // dozens of presets in a row needs to trust each keypress actually recorded without checking
    // a log after the fact.
    @State private var ratingFeedback: String?
    // "H" toggles the album art (+ track/artist text) overlay off entirely, independent of "P"
    // (nowPlaying.processingEnabled, which stops the artwork *analysis* pipeline) — this just
    // hides whatever's already computed, for looking at the wave alone without a track playing.
    @State private var isAlbumArtHidden = false
    @FocusState private var isFocused: Bool

    // Temporarily off (TO DO.md Phase 3, 7/26): the true window background (and, via
    // `.windowStyle(.hiddenTitleBar)` in PrismApp.swift, the apparent title bar) was inheriting
    // the album art's dominant color, which needs revisiting. NowPlayingManager's own computation
    // (`albumBackgroundColor`/`albumForegroundColor`) is left completely untouched -- this is a
    // one-line flip back on, not a removed feature -- so the piping is ready for whenever this
    // gets picked back up.
    private static let useAlbumArtBackgroundColor = false

    var body: some View {
        let bgColor = (Self.useAlbumArtBackgroundColor ? nowPlaying.albumBackgroundColor : nil)
            .map { Color(nsColor: $0) } ?? Color(NSColor.windowBackgroundColor)
        let fgColor = nowPlaying.albumForegroundColor.map { Color(nsColor: $0) } ?? .accentColor

        ZStack {
            // The wave
            ProjectMMetalView(
                audioEngine: audioEngine, model: visualizerModel,
                // The album art itself is composited (fade in, then background/subject erosion,
                // distorted against the wave throughout) inside the Metal render pass now — see
                // ProjectMCoordinator — rather than as a separate SwiftUI Image layered on top;
                // only the track/artist text below is still a plain SwiftUI overlay.
                albumArtRawImage: nowPlaying.rawArtwork, albumArtSubjectImage: nowPlaying.subjectArtwork,
                isAlbumArtHidden: isAlbumArtHidden,
                onDropPreset: { url in handlePresetDrop(url) },
                onDropTargetChanged: { isDropTargeted = $0 }
            )
                .contentShape(Rectangle())
                .onTapGesture { loadNextSequentialPreset() }

            if !isAlbumArtHidden, let track = nowPlaying.trackName, let artist = nowPlaying.artistName {
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
        // Wave-only .milk preset loading (see ProjectMVisualizerModel):
        // "O" opens a file picker, and the preset's name shows briefly so there's some feedback
        // that a load actually happened, since nothing else in the UI names the active preset.
        .overlay(alignment: .topLeading) {
            let presetName = visualizerModel.presetURL?.deletingPathExtension().lastPathComponent
            if let presetName {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presetName)
                    if let ratingFeedback {
                        Text(ratingFeedback)
                    }
                }
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
                // frame by ProjectMCoordinator.draw(in:) into visualizerModel.displayFPS.
                Text("\(Int(visualizerModel.displayFPS.rounded())) FPS")
                    .monospacedDigit()
                if showSavedConfirmation {
                    Text("Saved for this album")
                }
                if isAutoCycleEnabled {
                    Text("Auto-Cycle On")
                }
                if isAlbumArtHidden {
                    Text("Album Art Hidden")
                }
                if presetLibrary.isShowingFavoritesOnly {
                    Text("Reviewing Favorites List")
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
        // Only visible feedback that a drag is actually hovering a valid drop target — driven by
        // `PresetDroppableMTKView.onDropTargetChanged`, not SwiftUI's own `.onDrop`/`isTargeted`
        // (that modifier showed no drag recognition at all over this view — see
        // PresetDroppableMTKView's doc comment for why drag-and-drop is handled at the AppKit
        // level here instead).
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(fgColor, lineWidth: 3)
                    .padding(10)
                    .allowsHitTesting(false)
            }
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
            loadNextSequentialPreset()
        }
        // "U": narrow sequential discovery to a NestDrop bundle's favorites list instead of the
        // whole library — see MilkdropPresetLibrary.filterToFavorites. Re-picking the library
        // folder (L) clears this back to the full scan.
        .fileImporter(
            isPresented: $isFavoritesBundlePickerPresented,
            allowedContentTypes: [.xml]
        ) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            presetLibrary.filterToFavorites(from: url)
            loadNextSequentialPreset()
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
        // (arrow keys / F / Esc) even though there's no preset deck to navigate here: Space steps
        // to the next preset in sequential library order (same action as tapping the visualizer),
        // F toggles fullscreen, L (re)picks the library folder, A toggles idle auto-cycling,
        // Left/Right step back/forward through this session's preset history. "1"-"5" record a
        // star rating; "w"/"j"/"x" flag the current preset as all-white, too jittery, or
        // strobing/flashing respectively (for revisiting later) — "x" rather than "s" for
        // strobing since "s" already saves the current artwork M/T preference below. All of these
        // advance to the next sequential preset afterward, the same as Space, so reviewing a
        // library is a single keypress per preset: rate (or flag), see the next one immediately.
        // "H" toggles the album art overlay on/off. "U" (User Profile) picks a NestDrop bundle
        // XML and narrows sequential discovery to just its favorites list.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [" ", "f", "F", "o", "O", "l", "L", "a", "A", "t", "T", "m", "M", "p", "P", "s", "S", "w", "W", "j", "J", "x", "X", "h", "H", "u", "U", "1", "2", "3", "4", "5", .leftArrow, .rightArrow]) { press in
            if press.key == .leftArrow {
                loadPreviousPreset()
                return .handled
            }
            if press.key == .rightArrow {
                loadNextPreset()
                return .handled
            }
            switch press.characters {
            case " ":
                loadNextSequentialPreset()
                return .handled
            case "1", "2", "3", "4", "5":
                if let stars = Int(press.characters) {
                    rateCurrentPreset(stars: stars)
                }
                return .handled
            case "w", "W":
                flagCurrentPreset(.allWhite, label: "Flagged: all white")
                return .handled
            case "j", "J":
                flagCurrentPreset(.tooJittery, label: "Flagged: too jittery")
                return .handled
            case "x", "X":
                flagCurrentPreset(.strobing, label: "Flagged: strobing/flashing")
                return .handled
            case "h", "H":
                isAlbumArtHidden.toggle()
                return .handled
            case "u", "U":
                isFavoritesBundlePickerPresented = true
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
            // preset the user has since picked. Falls back to PRISM_PROJECTM_DEV_PRESETS (a
            // debug-only hardcoded preset path, since the App Sandbox blocks reading arbitrary
            // paths that weren't user-selected/dropped) only when there's no real remembered
            // preset to restore - useful for quick manual testing without a security-scoped
            // bookmark on hand.
            if visualizerModel.presetURL == nil {
                var restoredFromLastLaunch = false
                lastPresetStore.withLastPreset { url in
                    restoredFromLastLaunch = true
                    loadPresetAndTrack(from: url)
                }
                if !restoredFromLastLaunch,
                   let devPresetsRoot = ProcessInfo.processInfo.environment["PRISM_PROJECTM_DEV_PRESETS"] {
                    let devPresetName = ProcessInfo.processInfo.environment["PRISM_PROJECTM_DEV_PRESET_NAME"] ?? "100-square.milk"
                    visualizerModel.requestPreset(at: URL(fileURLWithPath: devPresetsRoot).appendingPathComponent(devPresetName))
                }
            }
            // First-launch (or any launch before one's ever been picked) auto-prompt for the
            // preset library folder — previously only surfaced lazily, the first time Space/tap/`L`
            // was pressed, leaving Space a silent no-op until a user stumbled onto that. Harmless to
            // re-prompt on every launch until a folder is actually configured: `isConfigured` only
            // ever flips true via a real successful pick (see MilkdropPresetLibrary.setLibraryRoot),
            // so this never re-prompts someone who's already set one up.
            if !presetLibrary.isConfigured {
                isLibraryFolderPickerPresented = true
            }
            PrismDebug.trace("ContentView.onAppear returned (both calls are async/backgrounded)")
        }
        .task {
            PrismDebug.trace("ContentView.task -> audioEngine.start() awaiting")
            await audioEngine.start()
            PrismDebug.trace("ContentView.task -> audioEngine.start() returned")
        }
    }

    /// Space/tap's action: step to the next preset in the configured library's sorted order —
    /// deliberately sequential (not random) so a full review pass through a library, rating/
    /// flagging as you go (see rateCurrentPreset/flagCurrentPresetWhite), eventually covers every
    /// file exactly once instead of repeat draws with no completion guarantee. Prompts for a
    /// library folder instead if none is configured yet — `onAppear`'s own auto-prompt (added
    /// 7/26) handles the real first-launch case, so this is now mainly a fallback for someone who
    /// dismissed that prompt without picking a folder.
    /// `resetAutoCycle` is false only when the auto-cycle loop itself calls this — its own
    /// while-loop cadence already provides the next interval, so restarting the countdown here too
    /// would just replace the in-flight sleeping Task with an equivalent new one for no reason.
    private func loadNextSequentialPreset(resetAutoCycle: Bool = true) {
        guard presetLibrary.isConfigured else {
            isLibraryFolderPickerPresented = true
            return
        }
        guard let url = nextNonExpensiveSequentialPresetURL(after: visualizerModel.presetURL) else { return }
        loadPresetAndTrack(from: url, resetAutoCycle: resetAutoCycle)
    }

    /// Walks `presetLibrary.nextSequentialPresetURL(after:)` forward, skipping any preset
    /// `MilkdropPresetComplexityAnalyzer` flags as expensive (TO DO.md: some presets measured as
    /// low as 3fps due to genuinely heavy per-pixel warp/comp shaders) — expensive presets default
    /// to being skipped during sequential stepping/auto-cycle for now, rather than ever landing on
    /// screen at a few fps. Bounded to one full pass over the library so a library that's *all*
    /// flagged expensive still terminates instead of spinning forever — falls back to the first
    /// candidate found in that case rather than showing nothing at all. Explicit loads (Cmd-O,
    /// drag-and-drop, history Left/Right, launch-time restore) intentionally bypass this — the user
    /// picked that exact file, so it should still load.
    private func nextNonExpensiveSequentialPresetURL(after currentURL: URL?) -> URL? {
        var candidate = currentURL
        var firstCandidate: URL?
        let maxAttempts = max(presetLibrary.presetURLs.count, 1)
        for _ in 0..<maxAttempts {
            guard let next = presetLibrary.nextSequentialPresetURL(after: candidate) else { return nil }
            if firstCandidate == nil { firstCandidate = next }
            if !MilkdropPresetComplexityAnalyzer.isExpensive(next) { return next }
            candidate = next
        }
        return firstCandidate
    }

    /// "1"-"5": records a star rating for whichever preset is on screen right now, then advances
    /// to the next sequential preset (same as Space) so a review pass is one keypress per preset.
    /// A no-op (no advance either) if nothing's loaded yet.
    private func rateCurrentPreset(stars: Int) {
        guard let url = visualizerModel.presetURL else { return }
        ratingStore.setStars(stars, for: url)
        showRatingFeedback(String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars))
        loadNextSequentialPreset()
    }

    /// "w"/"j"/"x": flags whichever preset is on screen right now with a debug issue, for
    /// revisiting later (MilkdropPresetRatingStore.urls(flaggedWith:)), then advances to the next
    /// sequential preset (same as Space). A no-op (no advance either) if nothing's loaded yet.
    private func flagCurrentPreset(_ issue: MilkdropPresetIssue, label: String) {
        guard let url = visualizerModel.presetURL else { return }
        ratingStore.flag(issue, for: url)
        showRatingFeedback(label)
        loadNextSequentialPreset()
    }

    /// Shared one-shot, auto-clearing confirmation for rateCurrentPreset/flagCurrentPresetWhite —
    /// same Task.sleep idiom as showSavedConfirmation above.
    private func showRatingFeedback(_ message: String) {
        ratingFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            ratingFeedback = nil
        }
    }

    /// Drag-and-drop counterpart to "O"'s `.fileImporter`, called by `PresetDroppableMTKView`
    /// once a `.milk` file's actually been dropped — the extension check already happened there
    /// (`milkURL(from:)`), so anything reaching here is already known-good.
    /// AppKit's dragging-destination callbacks always run on the main thread already (unlike this
    /// method's SwiftUI-`.onDrop`-based predecessor, which needed a `Task { @MainActor }` hop), so
    /// this can touch `@State`/call `loadPresetAndTrack` directly. Still brackets the actual read in
    /// `startAccessingSecurityScopedResource`/`stopAccessingSecurityScopedResource`, mirroring the
    /// `.fileImporter` closures elsewhere in this file, for a URL this app didn't pick via its own
    /// panel. `PrismDebug.trace` since a load that silently does nothing would otherwise be
    /// unobservable — see PrismDebug.swift's own doc comment on why `startupTracing` (not
    /// `verboseLogging`) is on by default.
    private func handlePresetDrop(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        PrismDebug.trace("handlePresetDrop: loading \(url.lastPathComponent)")
        loadPresetAndTrack(from: url)
    }

    /// Centralizes the bookkeeping every successful preset load needs, regardless of how the URL
    /// was obtained (manual Cmd-O pick, random library draw, or restoring the last-loaded preset
    /// at launch): remembers it for next launch's restore (MilkdropLastPresetStore) and restarts
    /// the idle auto-cycle countdown so a manual skip doesn't get immediately followed by an
    /// auto-cycle a moment later.
    ///
    /// Just sets `visualizerModel.presetURL` and lets real projectM handle the rest internally -
    /// unlike the old hand-rolled renderer, which had to construct a whole new model/renderer
    /// instance per preset and cross-fade them in Swift, real projectM performs preset
    /// transitions (smooth_transition) inside the C++ engine on one persistent instance (see
    /// ProjectMCoordinator.updateModelIfNeeded), so there's no outgoing/incoming model split here.
    /// `recordInHistory` is false only for a Left/Right history navigation itself
    /// (`loadPreviousPreset`/`loadNextPreset` below) — replaying an already-recorded URL from
    /// `presetHistory` shouldn't re-append it or truncate the very forward branch Right is about
    /// to step into.
    private func loadPresetAndTrack(from url: URL, resetAutoCycle: Bool = true, recordInHistory: Bool = true) {
        // Real projectM's own load failures surface asynchronously (see ProjectMCoordinator's
        // presetLoadFailureHandler wiring) rather than as a synchronous parse result here, so
        // there's no failure gate before the shared bookkeeping below - matches
        // projectm_load_preset_file's own "keep showing the current preset" behavior on a bad file.
        visualizerModel.requestPreset(at: url)
        lastPresetStore.rememberLoaded(url)
        if recordInHistory {
            if presetHistoryIndex < presetHistory.count - 1 {
                presetHistory.removeSubrange((presetHistoryIndex + 1)...)
            }
            presetHistory.append(url)
            presetHistoryIndex = presetHistory.count - 1
        }
        if resetAutoCycle {
            restartAutoCycleTimerIfNeeded()
        }
    }

    /// Left arrow: step back to the previous entry in `presetHistory` — a no-op at the very start
    /// of history (nothing to go back to yet), same as a browser's disabled back button.
    private func loadPreviousPreset() {
        guard presetHistoryIndex > 0 else { return }
        presetHistoryIndex -= 1
        loadPresetAndTrack(from: presetHistory[presetHistoryIndex], recordInHistory: false)
    }

    /// Right arrow: step forward to the next already-visited entry if one exists (from a prior
    /// Left), otherwise falls back to the next sequential preset — same as Space — since there's
    /// no pre-built playlist to advance through past what's already been seen.
    private func loadNextPreset() {
        guard presetHistoryIndex >= 0, presetHistoryIndex < presetHistory.count - 1 else {
            loadNextSequentialPreset()
            return
        }
        presetHistoryIndex += 1
        loadPresetAndTrack(from: presetHistory[presetHistoryIndex], recordInHistory: false)
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
                loadNextSequentialPreset(resetAutoCycle: false)
            }
        }
    }
}
