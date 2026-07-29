//
//  ContentView.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Which of this view's three file/folder pickers is currently up. Stacking several independent
// `.fileImporter(isPresented:)` modifiers on the same view (as this used to do — one Bool per
// picker) is a known SwiftUI/macOS foot-gun: only one of the stacked presentation coordinators on
// a given view identity reliably shows its panel, so the others silently no-op (the trigger flips
// true, nothing appears, the Bool never even gets reset). Routing all three through one
// `.fileImporter` keyed on this enum keeps exactly one coordinator on the view.
private enum ActiveFilePicker {
    case milkPreset
    case libraryFolder
    case favoritesBundle
}

struct ContentView: View {
    @State private var audioEngine = CoreAudioTapEngine()
    @State private var nowPlaying = NowPlayingManager()
    @State private var permissions = PermissionsManager()
    @State private var visualizerModel = ProjectMVisualizerModel()
    @State private var presetLibrary = MilkdropPresetLibrary()
    @State private var lastPresetStore = MilkdropLastPresetStore()
    @State private var ratingStore = MilkdropPresetRatingStore()
    // Drag-and-drop counterpart to File > "Import Milk Preset…"'s file picker — true only while a drag
    // carrying a `.milk` file is actually hovering the window, driven by
    // `PresetDroppableMTKView.onDropTargetChanged` via `handlePresetDrop`'s sibling wiring below,
    // for the brief highlight overlay that's the only feedback a valid drop target exists at all.
    @State private var isDropTargeted = false
    // "U" (User Profile) picks a NestDrop bundle XML (e.g. a preset pack's own
    // `User Profile/*.xml` favorites export) and narrows sequential discovery down to just the
    // files it names — see MilkdropPresetLibrary.filterToFavorites/MilkdropNestDropFavoritesList.
    // Library-folder and favorites-bundle picks (both above) and the milk-preset import below
    // (@Binding, since the App scene's menu command is what triggers it) all funnel through this
    // one enum-keyed `.fileImporter` — see ActiveFilePicker's doc comment for why.
    @State private var activeFilePicker: ActiveFilePicker?
    // Idle auto-cycling (TO DO.md Phase 3) — "C" toggles it on/off. Backed by a sleeping Task
    // rather than Foundation's Timer, matching the Task-based delay already used elsewhere in
    // this file (the "S" save confirmation). Any successful preset load, manual or automatic,
    // restarts the sleep window (see restartAutoCycleTimerIfNeeded) so a manual skip right before
    // the interval elapses doesn't get immediately followed by an auto-cycle a moment later.
    @State private var isAutoCycleEnabled = false
    @State private var autoCycleTask: Task<Void, Never>?
    private static let autoCycleInterval: Duration = .seconds(20)
    // Preset history (TO DO.md's "other" section) — every successful load (random draw, manual
    // Cmd-I pick, or the launch-time restore) appends here, so Left/Right can step back/forward
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
    // View menu "Hide Album Art"/"Hide Text" (PrismApp.swift's .commands, Cmd-A/Cmd-T shortcuts) —
    // independent of "P" (nowPlaying.processingEnabled, which stops the artwork *analysis*
    // pipeline entirely); these just hide whatever's already computed/rendered. Owned by the App
    // scene rather than this view so the menu bar's checkable Toggle items and the keyboard
    // shortcuts share the same source of truth.
    @Binding var isAlbumArtHidden: Bool
    @Binding var isTextHidden: Bool
    // File > "Import Milk Preset…" (PrismApp.swift's .commands) — same `.fileImporter` this view used
    // to trigger itself via the (now-disabled) "O" hotkey, just driven from the menu command's
    // Bool instead of a local one, for the same share-the-source-of-truth reason as the two
    // bindings above. Ends up loading through `loadPresetAndTrack`, the exact same path drag-and-
    // drop's `handlePresetDrop` uses, so both routes behave identically once a URL is in hand.
    @Binding var isPresetImporterPresented: Bool
    // History menu bar item (PrismApp.swift's .commands) — `sessionHistoryStore` is a plain
    // reference (not @Binding: it's a class, and PrismApp never reassigns it, just calls methods
    // on the same instance) that persists every load past this run for next launch's "Last
    // Session" rotation. `sessionPresetLog` is the in-memory log the History menu actually
    // renders; loadPresetAndTrack below appends to both, unconditionally, on every successful
    // load — including replays and History-menu-triggered loads — so a preset played twice shows
    // twice, in order. `presetToLoadFromMenu` is the reverse direction: PrismApp sets it when a
    // History/Last Session item is clicked, and this view's onChange (below) does the actual
    // security-scoped load.
    let sessionHistoryStore: MilkdropSessionHistoryStore
    @Binding var sessionPresetLog: [URL]
    @Binding var presetToLoadFromMenu: URL?
    @FocusState private var isFocused: Bool

    // Temporarily off (TO DO.md Phase 3, 7/26): the true window background (and, via
    // `.windowStyle(.hiddenTitleBar)` in PrismApp.swift, the apparent title bar) was inheriting
    // the album art's dominant color, which needs revisiting. NowPlayingManager's own computation
    // (`albumBackgroundColor`/`albumForegroundColor`) is left completely untouched -- this is a
    // one-line flip back on, not a removed feature -- so the piping is ready for whenever this
    // gets picked back up.
    private static let useAlbumArtBackgroundColor = false

    // Window > Zoom (and the title-bar zoom button, though .hiddenTitleBar already keeps it out
    // of sight) is a no-op here — see `onAppear` below, where this gets installed as the window's
    // delegate. There's no meaningful "biggest useful size" to toggle between for a full-window
    // visualizer, so zooming would just be a jarring resize with nothing to show for it.
    private final class ZoomDisablingWindowDelegate: NSObject, NSWindowDelegate {
        func windowShouldZoom(_ sender: NSWindow, toFrame newFrame: NSRect) -> Bool { false }
    }
    @State private var windowDelegate = ZoomDisablingWindowDelegate()

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
                albumArtRawImage: nowPlaying.rawArtwork, albumArtColorKeyedImage: nowPlaying.colorKeyedArtwork,
                albumArtSubjectImage: nowPlaying.subjectArtwork,
                isAlbumArtHidden: isAlbumArtHidden,
                onDropPreset: { url in handlePresetDrop(url) },
                onDropTargetChanged: { isDropTargeted = $0 }
            )
                .contentShape(Rectangle())
                .onTapGesture { loadNextSequentialPreset() }

            if !isTextHidden, let track = nowPlaying.trackName, let artist = nowPlaying.artistName {
                VStack {
                    Spacer() // Text pinned to the bottom

                    // Each label is keyed by its own text so a change swaps in a whole new view
                    // instance (rather than relabeling the same one in place) — that's what makes
                    // `.push` actually animate. Artist is keyed separately from track so a same-
                    // artist/new-song update (the common case) only replaces the track's identity;
                    // the artist Text's identity is untouched and it never moves. `.push(from:
                    // .trailing)` slides the incoming label in from the right while sliding the
                    // outgoing one out the left, i.e. new text pushes old text off to the left.
                    // White text + a `.difference` blend against whatever's rendered underneath
                    // (the Metal wave/album art) gives a true per-pixel color invert — difference-
                    // blending white against color C yields 1-C on every channel — rather than a
                    // fixed color picked once from the album art, so it stays legible as the
                    // visualizer itself keeps changing underneath.
                    HStack {
                        Text(track)
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.white)
                            .blendMode(.difference)
                            .padding()
                            .id(track)
                            .transition(.push(from: .trailing))

                        Spacer()

                        Text(artist)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .blendMode(.difference)
                            .padding()
                            .id(artist)
                            .transition(.push(from: .trailing))
                    }
                    .clipped()
                }
                .animation(.easeInOut(duration: 0.4), value: track)
                .animation(.easeInOut(duration: 0.4), value: artist)
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(bgColor)
        .animation(.easeInOut(duration: 0.5), value: bgColor)
        // .hiddenTitleBar (PrismApp.swift) removes the title bar's title/background, but SwiftUI
        // still reserves a title-bar-height safe area at the top by default; without opting out of
        // it here, content gets pushed down and that gap shows through as a plain white strip
        // (bgColor) instead of the wave. The traffic-light buttons are AppKit window chrome, not
        // part of this view hierarchy, so they stay on top regardless of what this ignores.
        .ignoresSafeArea()
        // Wave-only .milk preset loading (see ProjectMVisualizerModel):
        // File > "Import Milk Preset…" opens a file picker (drag-and-drop is the other way in — see
        // handlePresetDrop), and the preset's name shows briefly so there's some feedback that a
        // load actually happened, since nothing else in the UI names the active preset.
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
                // Clears the traffic-light buttons, which now sit directly over this corner since
                // the ZStack's .ignoresSafeArea() above lets content run under the (hidden) title
                // bar. Standard traffic-light vertical center sits ~20pt down from the window's top
                // edge, so this keeps the text's top clear of them.
                .padding(.top, 20)
            }
        }
        // Disabled for now (debug/status text in the top-right corner — FPS counter, auto-cycle/
        // masking-mode/etc. state flags) — commented out rather than removed so it can come back
        // for debugging later.
        // .overlay(alignment: .topTrailing) {
        //     // "M" (below) drives nowPlaying.maskingMode directly — a stand-in for a future
        //     // Settings control; only shown off its default so this stays invisible day to day.
        //     VStack(alignment: .trailing, spacing: 4) {
        //         // Performance counter — smoothed (not raw per-frame 1/dt) FPS, pushed once per
        //         // frame by ProjectMCoordinator.draw(in:) into visualizerModel.displayFPS.
        //         Text("\(Int(visualizerModel.displayFPS.rounded())) FPS")
        //             .monospacedDigit()
        //         if showSavedConfirmation {
        //             Text("Saved for this album")
        //         }
        //         if isAutoCycleEnabled {
        //             Text("Auto-Cycle On")
        //         }
        //         if isAlbumArtHidden {
        //             Text("Album Art Hidden")
        //         }
        //         if isTextHidden {
        //             Text("Text Hidden")
        //         }
        //         if presetLibrary.isShowingFavoritesOnly {
        //             Text("Reviewing Favorites List")
        //         }
        //         if !nowPlaying.processingEnabled {
        //             Text("Processing Off")
        //         } else {
        //             if !nowPlaying.includesTextOverlay {
        //                 Text("Text Overlay Off")
        //             }
        //             if nowPlaying.maskingMode != .combined {
        //                 Text(nowPlaying.maskingMode.label)
        //             }
        //         }
        //     }
        //     .font(.caption)
        //     .foregroundStyle(fgColor.opacity(0.6))
        //     .padding(8)
        // }
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
        // Menu-driven trigger for the milk-preset import (@Binding, owned by the App scene — see
        // isPresetImporterPresented's doc comment) funnels into `activeFilePicker` just like the
        // other two pickers' direct assignments do, so there's a single `.fileImporter` below
        // rather than three stacked on this view (see ActiveFilePicker's doc comment for why that
        // matters). Reset back to false immediately since it's a one-shot trigger, not the thing
        // that actually tracks presentation state anymore.
        .onChange(of: isPresetImporterPresented) { _, isPresented in
            guard isPresented else { return }
            activeFilePicker = .milkPreset
            isPresetImporterPresented = false
        }
        // Single `.fileImporter` for all three pickers — milk-preset import (File > "Import Milk
        // Preset…"), the preset-library folder (triggered explicitly by "L" or implicitly the
        // first time Space/tap is used before any library folder has been picked yet — see
        // MilkdropPresetLibrary.swift), and "U"'s NestDrop bundle favorites XML (narrows sequential
        // discovery to just the files it names — see MilkdropPresetLibrary.filterToFavorites; re-
        // picking the library folder clears this back to the full scan). Consolidated onto one
        // `.fileImporter`/one `activeFilePicker` enum rather than one Bool + one `.fileImporter`
        // each — see ActiveFilePicker's doc comment.
        .fileImporter(
            isPresented: Binding(
                get: { activeFilePicker != nil },
                set: { if !$0 { activeFilePicker = nil } }
            ),
            allowedContentTypes: {
                switch activeFilePicker {
                case .milkPreset: return [UTType(filenameExtension: "milk") ?? .plainText]
                case .libraryFolder: return [.folder]
                case .favoritesBundle: return [.xml]
                case nil: return [.item]
                }
            }()
        ) { [capturedFilePicker = activeFilePicker] result in
            // Captures `activeFilePicker`'s value as of *this* body evaluation (the one that
            // presented the panel) rather than reading the live @State property when the
            // completion runs: SwiftUI's `isPresented` binding above sets `activeFilePicker` back
            // to nil as part of dismissing the panel, and if that happens before this completion
            // closure is invoked (observed in practice — the panel closes but nothing loads), a
            // live read here would always see nil and every case below would silently no-op.
            guard case .success(let url) = result else { return }
            switch capturedFilePicker {
            case .milkPreset:
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                loadPresetAndTrack(from: url)
            case .libraryFolder:
                presetLibrary.setLibraryRoot(url)
                loadNextSequentialPreset()
            case .favoritesBundle:
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                presetLibrary.filterToFavorites(from: url)
                loadNextSequentialPreset()
            case nil:
                break
            }
        }
        // History/Last Session menu clicks (PrismApp.swift's .commands) land here rather than
        // calling loadPresetAndTrack directly from the App scene, since only this view actually
        // holds security-scoped access to arbitrary preset URLs (mirrors the .fileImporter
        // closures above: start, act, stop). Resets the trigger to nil immediately so clicking
        // the same entry again later still fires (SwiftUI's onChange only fires on an actual
        // value change, so a value that stayed non-nil couldn't be re-clicked).
        .onChange(of: presetToLoadFromMenu) { _, newValue in
            guard let url = newValue else { return }
            presetToLoadFromMenu = nil
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            loadPresetAndTrack(from: url)
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
        // (arrow keys / F / Esc) even though there's no preset deck to navigate here: Space
        // toggles play/pause on whichever supported player (Spotify or Music) is current — see
        // NowPlayingManager.togglePlayPause — the same effect that key has when one of those apps
        // is itself frontmost, so it isn't lost just because Prism has focus instead. Left/Right
        // step back/forward through this session's preset history (loadPreviousPreset/
        // loadNextPreset), same as tapping the visualizer for forward. Cmd-A/Cmd-T (hide album
        // art / hide text) are handled by the View menu's commands (PrismApp.swift), not here,
        // since a menu key equivalent always intercepts a press before it would reach this view's
        // onKeyPress — unaffected by the `keys:` narrowing below.
        //
        // Every other hotkey this view used to handle (N/F/O/L/C/M/P/S/W/J/X/U, 1-5) is
        // temporarily disabled by leaving it out of `keys:` below rather than deleting its case —
        // none of those characters reach this closure anymore, so the switch's other cases are
        // dead code for now, kept in place so re-enabling any of them later is just adding the
        // key back to the array.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [" ", .leftArrow, .rightArrow]) { press in
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
                nowPlaying.togglePlayPause()
                return .handled
            case "n", "N":
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
            case "u", "U":
                activeFilePicker = .favoritesBundle
                return .handled
            case "f", "F":
                NSApp.keyWindow?.toggleFullScreen(nil)
                return .handled
            case "o", "O":
                activeFilePicker = .milkPreset
                return .handled
            case "l", "L":
                activeFilePicker = .libraryFolder
                return .handled
            case "c", "C":
                toggleAutoCycle()
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
            // NSWindow.allowsAutomaticWindowTabbing = false (PrismApp.swift's init) only stops new
            // windows from automatically joining a tab group — it doesn't remove "Show Tab
            // Bar"/"Show All Tabs" from the View menu, since AppKit adds those based on whether
            // the *frontmost window itself* supports tabbing, not the app-wide default. Explicitly
            // disallowing it on this window (there's only ever the one) is what actually drops
            // those two items.
            NSApp.windows.first?.tabbingMode = .disallowed
            // Disables Window > Zoom / double-click-to-zoom (see ZoomDisablingWindowDelegate
            // above) without touching the zoom button's enabled state — the button is also how a
            // plain click enters full screen (zoom itself is Option-click or the Window menu), so
            // disabling the button outright would take full screen out with it.
            NSApp.windows.first?.delegate = windowDelegate
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
                // Wait for real audio before leaving projectM's built-in starting animation — see
                // waitForMusicSignal. Backgrounded (not awaited inline) so it doesn't hold up the
                // rest of onAppear (permissions, polling, the library-folder prompt below).
                Task {
                    await waitForMusicSignal()
                    // A manual import/drop (handlePresetDrop or the fileImporter) while we were
                    // waiting already set presetURL directly and is the one thing meant to jump
                    // straight to the preset view without music — don't stomp it with whatever
                    // was on screen last launch.
                    guard visualizerModel.presetURL == nil else { return }
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
            }
            // First-launch (or any launch before one's ever been picked) auto-prompt for the
            // preset library folder — previously only surfaced lazily, the first time Space/tap/`L`
            // was pressed, leaving Space a silent no-op until a user stumbled onto that. Harmless to
            // re-prompt on every launch until a folder is actually configured: `isConfigured` only
            // ever flips true via a real successful pick (see MilkdropPresetLibrary.setLibraryRoot),
            // so this never re-prompts someone who's already set one up.
            if !presetLibrary.isConfigured {
                activeFilePicker = .libraryFolder
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
            activeFilePicker = .libraryFolder
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
    /// candidate found in that case rather than showing nothing at all. Explicit loads (Cmd-I,
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

    /// Drag-and-drop counterpart to File > "Import Milk Preset…"'s `.fileImporter`, called by `PresetDroppableMTKView`
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

    /// Polls `audioEngine.levels` (the 40-band spectrum SpectrumAnalyzer produces every audio
    /// buffer — see CoreAudioTapEngine/SpectrumAnalyzer) until real audio shows up, so onAppear's
    /// launch-time preset restore can wait for it: silence keeps every band pinned to
    /// SpectrumAnalyzer's 0.02 floor, so a few consecutive samples clearly above that floor is
    /// enough to tell music apart from noise-floor jitter without a real detector. Until this
    /// returns, `visualizerModel.presetURL` stays nil, which is what keeps projectM on its own
    /// built-in starting animation instead of jumping straight to a preset.
    ///
    /// Also bails out the moment `presetURL` gets set out from under it — a manual drag-and-drop
    /// or File > "Import Milk Preset…" is the one thing meant to jump straight to the preset view
    /// without waiting on music at all (see the onAppear call site's guard right after this).
    private func waitForMusicSignal() async {
        let signalThreshold: CGFloat = 0.08
        let requiredConsecutiveHits = 3
        var consecutiveHits = 0
        while visualizerModel.presetURL == nil {
            let levels = audioEngine.levels
            let average = levels.reduce(0, +) / CGFloat(levels.count)
            if average > signalThreshold {
                consecutiveHits += 1
                if consecutiveHits >= requiredConsecutiveHits { return }
            } else {
                consecutiveHits = 0
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Centralizes the bookkeeping every successful preset load needs, regardless of how the URL
    /// was obtained (manual Cmd-I pick, random library draw, or restoring the last-loaded preset
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
        // History menu bar item — every successful load counts as a "play" for its purposes,
        // unconditionally (unlike presetHistory below, which skips Left/Right navigation itself
        // via recordInHistory): replaying an already-seen preset, whether via Left/Right or a
        // History/Last Session menu click, should still add another entry reflecting that replay.
        sessionPresetLog.append(url)
        sessionHistoryStore.appendToCurrentSession(url)
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
