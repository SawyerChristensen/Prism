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
    #if DEBUG
    // One-time grant for MilkdropPresetRatingStore's direct-to-repo writes (see that store's own
    // top-of-file doc comment) — the dev picks the Prism repo's root folder once; a security-scoped
    // bookmark persists write access to Prism/Resources/PresetRatings.json and repo-root
    // FlaggedPresets.json across every future launch. Triggered lazily from
    // promptForRepoFolderIfNeeded the first time a rating/flag keypress fires without access yet,
    // not eagerly at launch — most dev sessions never touch the review-pass keybinds at all.
    case ratingsRepoFolder
    #endif
}

struct ContentView: View {
    // Owned by PrismApp (not @State here) so the menu bar's MenuBarWaveformView can read the same
    // running tap instead of each opening its own Core Audio process tap.
    let audioEngine: CoreAudioTapEngine
    @State private var nowPlaying = NowPlayingManager()
    @State private var permissions = PermissionsManager()
    @State private var visualizerModel = ProjectMVisualizerModel()
    @State private var presetLibrary = MilkdropPresetLibrary()
    @State private var lastPresetStore = MilkdropLastPresetStore()
    @State private var ratingStore = MilkdropPresetRatingStore()
    @State private var presetVisualTraitsStore = MilkdropPresetVisualTraitsStore()
    // Drag-and-drop counterpart to File > "Import .milk Preset…"'s file picker — true only while a drag
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
    // Swift doesn't support #if branches inside an array literal (confirmed: it's a parse error,
    // not just a style nit), so the DEBUG-only "1"-"5"/"j"-"x"-"d"-"b"-"f" keys are assembled here
    // instead of inline in the `.onKeyPress(keys:)` call below. Both groups are review-pass data
    // collection tools (rating/flagging presets, writing directly into Resources/PresetRatings.json
    // and repo-root FlaggedPresets.json once repo access is granted — see
    // MilkdropPresetRatingStore's own top-of-file doc comment) that only make sense on a dev's own
    // machine, not something an end user should be able to trigger from a shipped build.
    private static let keyPressKeys: Set<KeyEquivalent> = {
        var keys: Set<KeyEquivalent> = [" ", .leftArrow, .rightArrow]
        #if DEBUG
        keys.formUnion(["1", "2", "3", "4", "5", "j", "x", "d", "b", "f"])
        #endif
        return keys
    }()
    // Preset history (TO DO.md's "other" section) — every successful load (random draw, manual
    // Cmd-I pick, or the launch-time restore) appends here, so Left/Right can step back/forward
    // through what's actually been seen this session rather than each "skip" being a one-way,
    // unrecoverable random draw. Standard browser-history shape: `presetHistoryIndex` is the
    // currently-displayed entry, and loading a genuinely new preset (not a Left/Right navigation)
    // truncates anything past it before appending, same as a fresh navigation in a browser drops
    // a stale forward branch. There's still no *saved* playlist concept — this is session-only.
    @State private var presetHistory: [URL] = []
    @State private var presetHistoryIndex = -1
    // Album art layer reveal — View > "Cycle Album Layers" (Cmd-C, PrismApp.swift's .commands)
    // peels the four stacked layers (subject on top, then text, then background-color-removed,
    // then the full cover at the bottom - see ProjectMCoordinator.AlbumArtLayerCount) off from the
    // bottom one press at a time: 4 visible -> 3 -> 2 -> 1 (just the subject) -> 0 -> wraps back to
    // 4, skipping any step whose layer this cover doesn't actually have (see
    // nextAlbumArtVisibleLayerCount below) - most covers have no OCR text and plenty have no clean
    // dominant background color, so a blind 4-step cycle made the user peel off "layers" that
    // changed nothing on screen. Session-scoped, like isAlbumArtHidden/isTextHidden below, rather
    // than a per-album saved preference: it's a manual preview toggle, not something "S" persists.
    @State private var albumArtVisibleLayerCount = AlbumArtLayerCount.all
    // Transient confirmation after "S" saves the current Cmd-C/T settings for this album (see
    // NowPlayingManager.saveCurrentArtworkPreference) — there's no other visible signal that a
    // save happened, since M/T themselves are just a live preview now, not an auto-save.
    @State private var showSavedConfirmation = false
    // Transient confirmation after Up/Down (adjustWarpAnimSpeed) shows the new multiplier, and
    // after "j"/"x"/"d"/"b"/"f" (flagCurrentPreset) confirms what just got flagged — same one-shot,
    // auto-clearing Task.sleep idiom as showSavedConfirmation above.
    @State private var ratingFeedback: String?
    // "1"-"5" star rating overlay (see showPresetRatingAnimation) — `presetRatingAnimation` holds
    // the star count to render and carries a fresh UUID every time so re-rating the same preset the
    // same number of stars twice in a row still triggers a new animation (a plain Int wouldn't
    // change, and SwiftUI has nothing to react to). `presetRatingMaskScale`/`presetRatingMaskAnchor`
    // drive the reveal/wipe via a scaleEffect mask (see the overlay's own comment for why anchor
    // flips instead of animating a width). `presetRatingAnimationTask` is cancelled and replaced on
    // every new rating so a rapid string of keypresses only ever shows the latest one, rather than
    // queuing up a backlog of reveal/hold/wipe sequences that'd fight each other.
    private struct PresetRatingAnimation: Identifiable {
        let id = UUID()
        let stars: Int
    }
    @State private var presetRatingAnimation: PresetRatingAnimation?
    @State private var presetRatingMaskScale: CGFloat = 0
    @State private var presetRatingMaskAnchor: UnitPoint = .leading
    @State private var presetRatingAnimationTask: Task<Void, Never>?
    // View menu "Hide Album Art"/"Hide Text" (PrismApp.swift's .commands, Cmd-A/Cmd-T shortcuts) —
    // independent of "P" (nowPlaying.processingEnabled, which stops the artwork *analysis*
    // pipeline entirely); these just hide whatever's already computed/rendered. Owned by the App
    // scene rather than this view so the menu bar's checkable Toggle items and the keyboard
    // shortcuts share the same source of truth.
    @Binding var isAlbumArtHidden: Bool
    @Binding var isTextHidden: Bool
    // View > "Cycle Album Layers" (PrismApp.swift's .commands, Cmd-C) — a one-shot trigger, same
    // shape as isPresetImporterPresented below: the App scene flips this true, this view's onChange
    // (below) does the actual albumArtVisibleLayerCount cycling and flips it back to false, since
    // the layer-cycling logic (nextAlbumArtVisibleLayerCount/meaningfulAlbumArtLayerCounts) reads
    // this view's own state (nowPlaying, presetVisualTraitsStore) and has nowhere else to live.
    @Binding var cycleAlbumLayersFromMenu: Bool
    // File > "Import .milk Preset…" (PrismApp.swift's .commands) — same `.fileImporter` this view used
    // to trigger itself via the (now-disabled) "O" hotkey, just driven from the menu command's
    // Bool instead of a local one, for the same share-the-source-of-truth reason as the two
    // bindings above. Ends up loading through `loadPresetAndTrack`, the exact same path drag-and-
    // drop's `handlePresetDrop` uses, so both routes behave identically once a URL is in hand.
    @Binding var isPresetImporterPresented: Bool
    // File > "Find Preset…" (PrismApp.swift's .commands, Cmd-S) — a persistent toggle (see its own
    // doc comment there), not a one-shot trigger: stays true for as long as the search overlay
    // (below) is on screen. `presetSearchQuery`/`presetSearchSelectedIndex` are reset whenever this
    // flips true (see the onChange below) so reopening the search never shows a stale query from
    // last time. `isPresetSearchFieldFocused` is a separate FocusState from `isFocused` (this
    // view's own keyboard-control-surface focus) specifically so the two never fight over which
    // one has focus at once — see the onChange below, which hands focus back and forth between them
    // as the overlay opens/closes, keeping Space/1-5/arrow-key hotkeys from firing while typing a
    // search query.
    @Binding var isPresetSearchPresented: Bool
    @State private var presetSearchQuery = ""
    @State private var presetSearchSelectedIndex = 0
    @FocusState private var isPresetSearchFieldFocused: Bool
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

    /// Cmd-S search results — case-insensitive substring match against the same display name the
    /// History menu already uses (filename minus `.milk`), scanned from the current library's full
    /// `presetURLs` (not narrowed by `filterToFavorites`, same set random/sequential draws come
    /// from) rather than requiring an exact/prefix match, so a partial artist or effect name (e.g.
    /// "geiss" or "fractal") still surfaces everything relevant. Capped at 8 — a broad query
    /// against a corpus in the thousands could otherwise return hundreds of rows for one keystroke.
    private var presetSearchResults: [URL] {
        guard !presetSearchQuery.isEmpty else { return [] }
        return presetLibrary.presetURLs
            .filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(presetSearchQuery) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        let bgColor = (Self.useAlbumArtBackgroundColor ? nowPlaying.albumBackgroundColor : nil)
            .map { Color(nsColor: $0) } ?? Color(NSColor.windowBackgroundColor)
        let fgColor = nowPlaying.albumForegroundColor.map { Color(nsColor: $0) } ?? .accentColor

        // `body` is split into a few intermediate `some View` bindings rather than one continuous
        // modifier chain: the full stack of overlays/onChange/fileImporter/onKeyPress handlers is
        // long enough that type-checking it as a single expression exceeds the compiler's budget
        // ("unable to type-check this expression in reasonable time"). Each `let` below is type-
        // checked independently, which keeps every sub-expression small.
        let content = ZStack {
            // The wave
            ProjectMMetalView(
                audioEngine: audioEngine, model: visualizerModel,
                // The album art itself is composited (fade in, then background/subject erosion,
                // distorted against the wave throughout) inside the Metal render pass now — see
                // ProjectMCoordinator — rather than as a separate SwiftUI Image layered on top;
                // only the track/artist text below is still a plain SwiftUI overlay.
                albumArtRawImage: nowPlaying.rawArtwork, albumArtColorKeyedImage: nowPlaying.colorKeyedArtwork,
                albumArtSubjectImage: nowPlaying.subjectArtwork,
                albumArtSubjectOnlyImage: nowPlaying.subjectOnlyArtwork,
                albumArtTextOnlyImage: nowPlaying.textOnlyArtwork,
                albumArtBackgroundDetailImage: nowPlaying.backgroundDetailArtwork,
                albumArtBackgroundColorImage: nowPlaying.backgroundColorArtwork,
                albumArtVisibleLayerCount: albumArtVisibleLayerCount,
                isAlbumArtHidden: isAlbumArtHidden,
                onDropPreset: { url in handlePresetDrop(url) },
                onDropTargetChanged: { isDropTargeted = $0 }
            )

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
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .blendMode(.difference)
                            .padding()
                            .id(track)
                            .transition(.push(from: .trailing))

                        Spacer()

                        Text(artist)
                            .font(.system(size: 24, weight: .bold))
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

        let decorated = content
        // Wave-only .milk preset loading (see ProjectMVisualizerModel):
        // File > "Import .milk Preset…" opens a file picker (drag-and-drop is the other way in — see
        // handlePresetDrop). Preset filenames come straight from community packs, unfiltered (can
        // contain profanity/crude author jokes — see TO DO.md), so this on-screen name overlay is
        // commented out rather than shown, for now.
        // .overlay(alignment: .topLeading) {
        //     let presetName = visualizerModel.presetURL?.deletingPathExtension().lastPathComponent
        //     if let presetName {
        //         VStack(alignment: .leading, spacing: 4) {
        //             Text(presetName)
        //             if let ratingFeedback {
        //                 Text(ratingFeedback)
        //             }
        //         }
        //         .font(.caption)
        //         .foregroundStyle(fgColor.opacity(0.6))
        //         .padding(8)
        //         // Clears the traffic-light buttons, which now sit directly over this corner since
        //         // the ZStack's .ignoresSafeArea() above lets content run under the (hidden) title
        //         // bar. Standard traffic-light vertical center sits ~20pt down from the window's top
        //         // edge, so this keeps the text's top clear of them.
        //         .padding(.top, 20)
        //     }
        // }
        // "1"-"5" star rating feedback (see showPresetRatingAnimation/rateCurrentPreset) — slides
        // in left-to-right, holds, then wipes back out left-to-right, so a review pass gets a clear
        // on-screen confirmation of what was just recorded without needing to check the log.
        .overlay(alignment: .topLeading) {
            if let presetRatingAnimation {
                let filled = String(repeating: "★", count: presetRatingAnimation.stars)
                let empty = String(repeating: "☆", count: 5 - presetRatingAnimation.stars)
                Text(filled + empty)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .blendMode(.difference)
                    .padding(8)
                    // Clears the traffic-light buttons — same reasoning as the (currently disabled)
                    // preset name overlay above.
                    .padding(.top, 20)
                    // The reveal grows this mask rectangle out from the left edge (anchor .leading,
                    // scale 0 -> 1). The wipe-away then shrinks the *same* rectangle back toward the
                    // right edge (anchor .trailing, scale 1 -> 0) rather than just running the reveal
                    // in reverse — pinning the far edge to .trailing while it shrinks is what makes
                    // the erase boundary itself travel left-to-right instead of right-to-left.
                    .mask(
                        Rectangle()
                            .scaleEffect(x: presetRatingMaskScale, y: 1, anchor: presetRatingMaskAnchor)
                    )
            }
        }
        #if DEBUG
        // "Already rated?" at a glance during a review pass — DEBUG-only, and independent of
        // SongPresetMatcher's score (see that file's presetQuality doc comment): a preset with an
        // existing rating always shows its stars here, one already reviewed or not is otherwise
        // indistinguishable on screen. Suppressed while presetRatingAnimation is playing so the two
        // topLeading overlays don't draw on top of each other right after a fresh "1"-"5" keypress;
        // the transient one already shows the same star count in that moment. Unrated (nil) shows
        // nothing at all, not empty outline stars, so blank is the visible cue to go rate it.
        .overlay(alignment: .topLeading) {
            if presetRatingAnimation == nil,
               let url = visualizerModel.presetURL,
               let stars = ratingStore.rating(for: url)?.stars {
                let filled = String(repeating: "★", count: stars)
                let empty = String(repeating: "☆", count: 5 - stars)
                Text(filled + empty)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .blendMode(.difference)
                    .padding(8)
                    .padding(.top, 20)
            }
        }
        #endif
        // Cmd-S "Find Preset…" — type-to-jump alternative to Cmd-I's file picker/drag-and-drop for
        // a preset already somewhere in the current library (see MilkdropPresetLibrary.presetURLs).
        // Matches against the same display name the History menu uses (filename minus extension),
        // case-insensitive substring, capped to a handful of results so a broad query against a
        // corpus in the thousands doesn't render an unbounded list. Up/Down move
        // `presetSearchSelectedIndex` through `presetSearchResults`, Return loads the selected
        // entry (`loadSelectedPresetSearchResult`), Escape or Cmd-S again closes it — the actual
        // open/close bookkeeping (focus handoff, resetting the query) lives in the
        // isPresetSearchPresented onChange below, not here.
        .overlay(alignment: .top) {
            if isPresetSearchPresented {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Search presets…", text: $presetSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .focused($isPresetSearchFieldFocused)
                        .onSubmit { loadSelectedPresetSearchResult() }
                        // Requesting focus here, not from the isPresetSearchPresented onChange
                        // below, because that onChange fires in the same update pass that inserts
                        // this conditional TextField into the hierarchy in the first place -
                        // setting `isPresetSearchFieldFocused = true` at that point races the
                        // view's own insertion and silently loses (Cmd-S opened the overlay but
                        // left it unfocused until a manual click). Even `.onAppear` alone isn't
                        // late enough: it fires once SwiftUI's *view graph* has this TextField, but
                        // AppKit hasn't necessarily finished installing the backing NSTextField into
                        // the window's actual view/responder hierarchy yet - setting FocusState
                        // synchronously inside onAppear silently lost the same race one level
                        // later (Cmd-S opened the overlay but nothing was focused at all, so typed
                        // keys hit no responder and just beeped). Bouncing through
                        // `DispatchQueue.main.async` defers the request to the next runloop turn,
                        // after that AppKit-side install has actually completed.
                        .onAppear {
                            DispatchQueue.main.async {
                                isPresetSearchFieldFocused = true
                            }
                        }

                    if !presetSearchResults.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(presetSearchResults.enumerated()), id: \.offset) { index, url in
                                presetSearchResultRow(index: index, url: url)
                            }
                        }
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    } else if !presetSearchQuery.isEmpty {
                        Text("No matching presets")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(maxWidth: 420)
                .padding(.top, 20)
                .shadow(radius: 12)
                .onKeyPress(.escape) {
                    isPresetSearchPresented = false
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    presetSearchSelectedIndex = max(0, presetSearchSelectedIndex - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    presetSearchSelectedIndex = min(
                        max(0, presetSearchResults.count - 1), presetSearchSelectedIndex + 1
                    )
                    return .handled
                }
            }
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

        let interactive = decorated
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
        // Cmd-S "Find Preset…" opening/closing (see isPresetSearchPresented's own doc comment) —
        // hands focus back to this view's own keyboard-control-surface `.focused($isFocused)`
        // (below) once the search closes (the *opposite* direction — focusing the search field on
        // open — happens in the TextField's own `.onAppear` instead, see its doc comment for why).
        // Also resets the query/selection on *every* open, not just the first, so reopening after a
        // previous search never shows stale state left over from last time.
        .onChange(of: isPresetSearchPresented) { _, isPresented in
            if isPresented {
                presetSearchQuery = ""
                presetSearchSelectedIndex = 0
                isFocused = false
            } else {
                isPresetSearchFieldFocused = false
                isFocused = true
            }
        }
        // Keeps the highlighted row pinned to the top match as the query changes keystroke by
        // keystroke, rather than leaving a stale index from a longer result list pointing at
        // nothing (or the wrong row) once the list shrinks.
        .onChange(of: presetSearchQuery) { _, _ in
            presetSearchSelectedIndex = 0
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
                #if DEBUG
                case .ratingsRepoFolder: return [.folder]
                #endif
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
            //
            // Also resets `activeFilePicker` here directly, unconditionally, rather than relying
            // solely on the `isPresented` binding's `set` closure above to do it: this completion
            // closure fires on every dismissal (success or cancel) regardless of *how* the panel
            // went away, whereas the binding's `set` only fires through SwiftUI's own presentation
            // machinery. If a panel is ever dismissed by some other path that machinery doesn't
            // observe, `activeFilePicker` is left non-nil with nothing actually on screen — and
            // since `.fileImporter` only presents on a false-to-true transition, every future
            // import attempt (click or keyboard) silently no-ops until the app restarts. Redundant
            // with the binding's own reset on the normal path; only matters on the abnormal one.
            activeFilePicker = nil
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
            #if DEBUG
            case .ratingsRepoFolder:
                ratingStore.setRepoRoot(url)
                showRatingFeedback("Repo folder set — ratings/flags now write directly to disk")
            #endif
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
        // View > "Cycle Album Layers" (PrismApp.swift's .commands, Cmd-C) — same one-shot trigger
        // shape as isPresetImporterPresented's onChange above. Peels one *actually visible* layer
        // off the bottom of the stack per press, wrapping back to the full stack once nothing's
        // left - see nextAlbumArtVisibleLayerCount.
        .onChange(of: cycleAlbumLayersFromMenu) { _, isTriggered in
            guard isTriggered else { return }
            cycleAlbumLayersFromMenu = false
            albumArtVisibleLayerCount = nextAlbumArtVisibleLayerCount(from: albumArtVisibleLayerCount, in: meaningfulAlbumArtLayerCounts())
        }
        // A song ending and a new one beginning should feel like a beat, not a silent swap: advance
        // to a new preset — real projectM cross-fades old/new preset internally
        // (ProjectMCoordinator.updateModelIfNeeded's smoothTransition), and that same preset load
        // also drives ProjectMCoordinator's own preset-transition album-art effect (see its doc
        // comments), so nothing else needs to be triggered here for the art to follow along.
        // Keyed off `trackReadySettledToken`, not `trackChangeToken` - see the former's own doc
        // comment: this preset load is what starts the transition ProjectMCoordinator times its
        // album-art reveal against, so it needs to fire once *both* the art and (if ReccoBeats has
        // one) the song-trait match are actually ready, not the instant the track metadata itself
        // changes, and not piecemeal as each one trickles in separately - a track change used to
        // fire this twice (once on art alone with a sequential fallback pick, then again moments
        // later once traits caught up with the real match), which played as two back-to-back
        // transitions for one song change; NowPlayingManager's ready gate (see
        // `trackReadySettledToken`) now holds both artwork and traits back until they're both
        // settled (or a timeout gives up waiting on traits) so there's only ever one.
        // `oldValue != 0` skips the very first token change (0 -> the first track detected this
        // launch) — that's "music started playing," not "a song ended," and this launch's own
        // preset restore (onAppear/waitForMusicSignal) already owns picking the very first preset;
        // racing this against it would fight over presetURL.
        .onChange(of: nowPlaying.trackReadySettledToken) { oldValue, _ in
            guard oldValue != 0, presetLibrary.isConfigured else { return }
            if let songTraits = nowPlaying.songTraits {
                PrismDebug.trace("preset: matching \"\(nowPlaying.trackName ?? "?")\" against its ReccoBeats traits")
                loadBestMatchedPreset(for: songTraits)
            } else {
                PrismDebug.trace("preset: sequential pick for \"\(nowPlaying.trackName ?? "?")\" - no ReccoBeats match")
                loadNextSequentialPreset()
            }
        }
        // ProjectMCoordinator's runtime watchdog (updateSlowPresetWatchdog) - fires when measured
        // fps has stayed unwatchably low for several seconds straight, regardless of how the
        // preset was loaded (including explicit ⌘O/drag-and-drop/history/launch-restore loads, which
        // bypass the curated-corpus guarantee that ships in Resources/Presets). Steps forward the
        // same way auto-cycle would, then clears the flag so it can fire again for the next preset.
        // Disabled for now (see ProjectMCoordinator.updateSlowPresetWatchdog's own call site) - all
        // bundled presets already measure 60fps+, so commented out rather than removed.
        // .onChange(of: visualizerModel.slowPresetDetected) { _, newValue in
        //     guard let newValue else { return }
        //     PrismDebug.trace("preset: runtime watchdog flagged \(newValue.lastPathComponent) as too slow - advancing")
        //     visualizerModel.slowPresetDetected = nil
        //     loadNextSequentialPreset()
        // }
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

        return interactive
        // Keyboard control surface, mirroring the spirit of MilkDrop pluginshell's hotkeys
        // (arrow keys / F / Esc) even though there's no preset deck to navigate here: Space
        // toggles play/pause on whichever supported player (Spotify or Music) is current — see
        // NowPlayingManager.togglePlayPause — the same effect that key has when one of those apps
        // is itself frontmost, so it isn't lost just because Prism has focus instead. Left/Right
        // step back/forward through this session's preset history (loadPreviousPreset/
        // loadNextPreset), same as tapping the visualizer for forward. Up/Down adjust
        // warpAnimSpeedMultiplier (adjustWarpAnimSpeed) — many presets animate at a fixed per-frame
        // rate baked in by the author (see Vendor/projectm-VERSION.md's warp-anim-speed-multiplier
        // local patch), so this is a manual damper for ones that read too fast, independent of the
        // automatic projectm_set_fps correction ProjectMCoordinator already applies. Cmd-A/Cmd-T (hide album
        // art / hide text) and Cmd-C (cycle album layers) are handled by the View menu's commands
        // (PrismApp.swift), not here, since a menu key equivalent always intercepts a press before
        // it would reach this view's onKeyPress — unaffected by the `keys:` narrowing below.
        //
        // Every other hotkey this view used to handle (N/O/L/C/P/S/U) is temporarily
        // disabled by leaving it out of `keys:` below rather than deleting its case — none of those
        // characters reach this closure anymore, so the switch's other cases are dead code for
        // now, kept in place so re-enabling any of them later is just adding the key back to the
        // array. "M" itself was fully removed (not just disabled) once its cycling moved to Cmd-C
        // above — see the onChange(of: cycleAlbumLayersFromMenu) handler below for the case this
        // used to be. "F" was fully removed too (not just disabled) once it was repurposed for the
        // tooFast flag below — its old `NSApp.keyWindow?.toggleFullScreen(nil)` case is gone, not
        // dead code, since a single key can only mean one thing here.
        //
        // "1"-"5" (rateCurrentPreset) and "j"/"x"/"d"/"b"/"f" (flagCurrentPreset) are both
        // DEBUG-only: review-pass data collection tools that write directly into
        // Resources/PresetRatings.json and the repo-root FlaggedPresets.json once repo access is
        // granted (see MilkdropPresetRatingStore's own top-of-file doc comment and
        // promptForRepoFolderIfNeeded), not something an end user should trigger from a shipped
        // build. Neither has any runtime effect in production either way: the bundled
        // Resources/PresetRatings.json seed strips issue flags entirely (see
        // MilkdropPresetRatingStore's own doc comment), so isFlagged(_:) — the check
        // loadNextSequentialPreset/loadBestMatchedPreset use to skip a preset during rotation — can
        // only ever be true from a flag recorded on-device, never from what shipped; and
        // SongPresetMatcher's presetQuality term that would consume ratingStars isn't wired into its
        // score at all yet (see that file's own doc comment). Both groups are left out of `keys:` in
        // release the same way the still-disabled group above is — their switch cases stay in place
        // either way, since they're a no-op when their key never reaches this closure.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: Self.keyPressKeys) { press in
            // Cmd-S "Find Preset…" being open does NOT stop this closure from firing on its own —
            // `.onKeyPress` delivers to every ancestor along the focus path whose *descendant* has
            // focus, not just the view whose own `.focused($isFocused)` binding is true, so the
            // search field having focus (isPresetSearchFieldFocused) doesn't exclude this one.
            // Without this guard, Space paused/resumed playback and 1-5 recorded a star rating on
            // every keystroke typed into the search query instead of just inserting the character.
            guard !isPresetSearchPresented else { return .ignored }
            if press.key == .leftArrow {
                loadPreviousPreset()
                return .handled
            }
            if press.key == .rightArrow {
                loadNextPreset()
                return .handled
            }
            // Up/Down (adjustWarpAnimSpeed) are temporarily disabled by leaving them out of
            // `keys:` above, same as the other hotkeys below — see the comment above this
            // modifier.
            if press.key == .upArrow {
                adjustWarpAnimSpeed(by: 0.1)
                return .handled
            }
            if press.key == .downArrow {
                adjustWarpAnimSpeed(by: -0.1)
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
            case "j", "J":
                flagCurrentPreset(.tooJittery, label: "Flagged: too jittery")
                return .handled
            case "x", "X":
                flagCurrentPreset(.strobing, label: "Flagged: strobing/flashing")
                return .handled
            case "d", "D":
                flagCurrentPreset(.tooDark, label: "Flagged: too dark")
                return .handled
            case "b", "B":
                flagCurrentPreset(.tooBright, label: "Flagged: too bright")
                return .handled
            case "f", "F":
                flagCurrentPreset(.tooFast, label: "Flagged: too fast")
                return .handled
            case "u", "U":
                activeFilePicker = .favoritesBundle
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
            // Picks the very first preset (TO DO.md Phase 4/Song-Preset Matching). Guarded on
            // presetURL == nil so a second onAppear (SwiftUI can re-fire this) never clobbers a
            // preset the user has since picked. Backgrounded (not awaited inline) so it doesn't
            // hold up the rest of onAppear (permissions, polling, the library-folder prompt below).
            if visualizerModel.presetURL == nil {
                Task {
                    // Wait for real audio before leaving projectM's built-in starting animation —
                    // see waitForMusicSignal.
                    await waitForMusicSignal()
                    // A manual import/drop (handlePresetDrop or the fileImporter) while we were
                    // waiting already set presetURL directly and is the one thing meant to jump
                    // straight to the preset view without music — don't stomp it with whatever
                    // else this pick would choose.
                    guard visualizerModel.presetURL == nil else { return }
                    // NowPlayingManager.startPolling() (called earlier in onAppear, well before
                    // this point) usually already knows the currently-playing track by now - wait
                    // a little longer for its ready gate (trackReadySettledToken) so the very first
                    // preset gets the same real song-preset match a track *change* would get,
                    // instead of blindly restoring whatever was on screen last launch or grabbing
                    // the sequentially-first preset in the corpus.
                    if await waitForNowPlayingTrack() {
                        guard visualizerModel.presetURL == nil else { return }
                        if let songTraits = nowPlaying.songTraits {
                            PrismDebug.trace("launch: matching \"\(nowPlaying.trackName ?? "?")\" against its ReccoBeats traits")
                            loadBestMatchedPreset(for: songTraits)
                        } else {
                            PrismDebug.trace("launch: sequential pick for \"\(nowPlaying.trackName ?? "?")\" - no ReccoBeats match")
                            loadNextSequentialPreset()
                        }
                        return
                    }
                    // No track detected at all (e.g. audio playing from something other than
                    // Music/Spotify) - fall back to whichever preset was on screen last launch.
                    // Falls back further to PRISM_PROJECTM_DEV_PRESETS (a debug-only hardcoded
                    // preset path, since the App Sandbox blocks reading arbitrary paths that
                    // weren't user-selected/dropped) only when there's no real remembered preset -
                    // useful for quick manual testing without a security-scoped bookmark on hand.
                    var restoredFromLastLaunch = false
                    lastPresetStore.withLastPreset { url in
                        restoredFromLastLaunch = true
                        loadPresetAndTrack(from: url)
                    }
                    if !restoredFromLastLaunch,
                       let devPresetsRoot = ProcessInfo.processInfo.environment["PRISM_PROJECTM_DEV_PRESETS"] {
                        let devPresetName = ProcessInfo.processInfo.environment["PRISM_PROJECTM_DEV_PRESET_NAME"] ?? "100-square.milk"
                        visualizerModel.requestPreset(at: URL(fileURLWithPath: devPresetsRoot).appendingPathComponent(devPresetName))
                        restoredFromLastLaunch = true
                    }
                    // withLastPreset returns nil (leaving restoredFromLastLaunch false) whenever the
                    // remembered bookmark can no longer be resolved - e.g. the file was moved/renamed
                    // since it was last remembered (see its own doc comment), which is exactly what
                    // happened to whichever preset was on screen when the Milkdrop corpus got renamed
                    // (TO DO.md). Without this last-resort fallback, presetURL would stay nil forever -
                    // stranding the app on projectM's built-in starting animation indefinitely, since
                    // nothing else ever retries the restore and a stale bookmark never becomes valid
                    // on its own. Picking the first sequential preset here is the same fallback
                    // Space/tap already performs manually (loadNextSequentialPreset).
                    if !restoredFromLastLaunch, presetLibrary.isConfigured {
                        loadNextSequentialPreset()
                    }
                }
            }
            // First-launch (or any launch before a library's ever been available) auto-prompt for
            // the preset library folder — previously only surfaced lazily, the first time
            // Space/tap/`L` was pressed, leaving Space a silent no-op until a user stumbled onto
            // that. `isConfigured` is now true on essentially every launch (MilkdropPresetLibrary's
            // init falls back to the app's own bundled preset pack when no external folder has been
            // picked — see its own header comment), so in practice this only fires for a dev build
            // made on a machine without the source pack, or a build where bundling was skipped.
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
    /// deliberately sequential (not random) so a full review pass through a library, rating as you
    /// go (see rateCurrentPreset), eventually covers every file exactly once instead of repeat
    /// draws with no completion guarantee. Prompts for a
    /// library folder instead if none is configured yet — `onAppear`'s own auto-prompt (added
    /// 7/26) handles the real first-launch case, so this is now mainly a fallback for someone who
    /// dismissed that prompt without picking a folder.
    /// `resetAutoCycle` is false only when the auto-cycle loop itself calls this — its own
    /// while-loop cadence already provides the next interval, so restarting the countdown here too
    /// would just replace the in-flight sleeping Task with an equivalent new one for no reason.
    ///
    /// Walks forward past any preset MilkdropPresetRatingStore.isFlagged(_:) reports true for
    /// (too jittery/strobing/too dark/too bright/too fast - see that store's own doc comment) rather than landing on
    /// the very next one unconditionally, bounded to one full lap of the library so an (unlikely)
    /// all-flagged library can't spin forever - silently gives up, leaving whatever's currently on
    /// screen alone, if it ever exhausts a full lap without finding anything clean.
    private func loadNextSequentialPreset(resetAutoCycle: Bool = true) {
        guard presetLibrary.isConfigured else {
            activeFilePicker = .libraryFolder
            return
        }
        var candidate = visualizerModel.presetURL
        for _ in 0..<presetLibrary.presetURLs.count {
            guard let url = presetLibrary.nextSequentialPresetURL(after: candidate) else { return }
            guard ratingStore.isFlagged(url) else {
                loadPresetAndTrack(from: url, resetAutoCycle: resetAutoCycle)
                return
            }
            candidate = url
        }
    }

    /// Song-preset matching (see SongPresetMatcher/TO DO.md's "Song-Preset Matching"
    /// section, and the trackReadySettledToken onChange handler above that calls this): ranks
    /// every preset MilkdropPresetVisualTraitsStore has precomputed traits for against `songTraits`
    /// and jumps to a random pick among the top matches, rather than always the single highest-
    /// scoring one — a deterministic argmax would show the exact same preset on every replay of the
    /// same song, which isn't the point (variety was already how the Apple Music plugin's own
    /// "new random preset every track" behavior worked before any of this). Runs the ranking work
    /// off the main actor (Task.detached, not a plain Task - this project's default actor isolation
    /// is MainActor, so a plain Task here would still run on the main thread) since scoring
    /// thousands of presets, while fast, is still real work that has no business blocking SwiftUI's
    /// main thread even briefly.
    private func loadBestMatchedPreset(for songTraits: SongAudioTraits) {
        // Star ratings looked up here, on the main actor, since MilkdropPresetRatingStore is
        // @MainActor-bound state that the Task.detached ranking below can't touch directly - see
        // SongPresetMatcher.rank's own doc comment. Flagged presets (isFlagged) are dropped from
        // the candidate pool entirely, same main-actor-lookup reasoning - too jittery/strobing/too
        // dark/too bright/too fast presets should never win a song match, not just score lower.
        let pairs = presetVisualTraitsStore.pairs(for: presetLibrary.presetURLs)
            .filter { !ratingStore.isFlagged($0.url) }
            .map { (url: $0.url, traits: $0.traits, ratingStars: ratingStore.rating(for: $0.url)?.stars) }
        guard !pairs.isEmpty else {
            PrismDebug.trace("preset: matching skipped - no precomputed traits for anything in the current library")
            return
        }

        Task.detached(priority: .userInitiated) {
            let ranked = SongPresetMatcher.rank(song: songTraits, presets: pairs)
            let topCandidateWindow = 30
            guard let winner = ranked.prefix(topCandidateWindow).randomElement() else {
                PrismDebug.trace("preset: matching found no candidates among \(ranked.count) ranked presets")
                return
            }
            // 1-based rank purely for the trace line below (readable as "3rd best out of 9780"),
            // not used for anything the actual pick depends on - the random draw above already
            // happened against the raw score-sorted `ranked` array.
            let rank = (ranked.firstIndex { $0.url == winner.url } ?? -1) + 1
            PrismDebug.trace(String(format: "preset: MATCHED -> %@  [score=%.4f, rank=%d/%d]", winner.url.lastPathComponent, winner.score, rank, ranked.count))
            await MainActor.run {
                self.loadPresetAndTrack(from: winner.url)
            }
        }
    }

    /// The ordered, deduplicated set of `albumArtVisibleLayerCount` values that actually change
    /// what's on screen for the *current* track — see ProjectMCoordinator.AlbumArtLayerCount's
    /// threshold scheme (backgroundColor only shows at count 4, backgroundDetail at >=3, text at
    /// >=2, subject at >=1). NowPlayingManager already returns nil for any layer this cover
    /// doesn't have (no clean dominant background color, no OCR text, no Vision subject cutout —
    /// see backgroundColorArtwork/backgroundDetailArtwork/textOnlyArtwork/subjectOnlyArtwork's own
    /// doc comments), so the count value that would "turn off" a nil layer renders identically to
    /// the count before it and is left out of this list entirely — built by walking the four
    /// thresholds top-to-bottom-of-stack (4, 3, 2, 1) and only appending `threshold - 1` when that
    /// layer's artwork actually exists, which keeps the result in descending order for free.
    private func meaningfulAlbumArtLayerCounts() -> [Int] {
        var counts = [AlbumArtLayerCount.all]
        if nowPlaying.backgroundColorArtwork != nil { counts.append(3) }
        if nowPlaying.backgroundDetailArtwork != nil { counts.append(2) }
        if nowPlaying.textOnlyArtwork != nil { counts.append(1) }
        if nowPlaying.subjectOnlyArtwork != nil { counts.append(0) }
        return counts
    }

    /// Cycle Album Layers' next stop: the closest value below `current` in `counts` (see
    /// `meaningfulAlbumArtLayerCounts()`), wrapping back to the full stack (list's first entry,
    /// always `AlbumArtLayerCount.all`) past the bottom — same 4 -> 3 -> 2 -> 1 -> 0 -> 4 shape as
    /// before when every layer exists, but skipping straight past any step that wouldn't change
    /// anything visible.
    private func nextAlbumArtVisibleLayerCount(from current: Int, in counts: [Int]) -> Int {
        counts.first(where: { $0 < current }) ?? counts.first ?? AlbumArtLayerCount.all
    }

    /// "1"-"5": records a star rating for whichever preset is on screen right now, then advances
    /// to the next sequential preset (same as Space) so a review pass is one keypress per preset.
    /// A no-op (no advance either) if nothing's loaded yet. Logged via PrismDebug.trace (same
    /// channel as the "preset: MATCHED" lines) so a review pass leaves a record of what got rated
    /// what, independent of the on-screen animation.
    private func rateCurrentPreset(stars: Int) {
        guard let url = visualizerModel.presetURL else { return }
        ratingStore.setStars(stars, for: url)
        PrismDebug.trace("rating: \(stars)★ for \(url.lastPathComponent)")
        showPresetRatingAnimation(stars: stars)
        loadNextSequentialPreset()
        #if DEBUG
        promptForRepoFolderIfNeeded()
        #endif
    }

    #if DEBUG
    /// Lazily triggers the one-time "select the Prism repo folder" grant (see
    /// MilkdropPresetRatingStore.setRepoRoot) the first time a rating/flag keypress fires without
    /// repo write access yet. Not blocking — setStars/flag above already recorded *this* keypress's
    /// rating via the UserDefaults fallback regardless of whether repo access exists; this just
    /// switches every *subsequent* keypress over to direct-to-repo writes once the dev picks the
    /// folder. `activeFilePicker == nil` guards against clobbering some other picker that's already
    /// up (shouldn't normally happen mid-review-session, but this is a fire-and-forget side effect,
    /// not something worth fighting for the picker slot over).
    private func promptForRepoFolderIfNeeded() {
        guard !ratingStore.hasRepoWriteAccess, activeFilePicker == nil else { return }
        activeFilePicker = .ratingsRepoFolder
    }
    #endif

    /// Drives the star overlay's slide-reveal -> hold -> wipe-away sequence (see the overlay's own
    /// comment on the mask technique). Cancels any in-flight sequence first so a fast run of "1"-"5"
    /// keypresses during a review pass only ever shows the latest rating, not a queued backlog.
    private func showPresetRatingAnimation(stars: Int) {
        presetRatingAnimationTask?.cancel()
        presetRatingAnimation = PresetRatingAnimation(stars: stars)
        // Instant, unanimated reset — any withAnimation left over from a cancelled sequence should
        // not carry into this one.
        presetRatingMaskAnchor = .leading
        presetRatingMaskScale = 0
        presetRatingAnimationTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.35)) {
                presetRatingMaskScale = 1
            }
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            // Unanimated: flips which edge the shrink is pinned to before the shrink itself starts.
            presetRatingMaskAnchor = .trailing
            withAnimation(.easeIn(duration: 0.35)) {
                presetRatingMaskScale = 0
            }
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            presetRatingAnimation = nil
        }
    }

    /// "j"/"x"/"d"/"b"/"f": flags whichever preset is on screen right now with a playback/legibility issue
    /// (MilkdropPresetRatingStore.flag), then advances to the next sequential preset (same as
    /// Space). A no-op (no advance either) if nothing's loaded yet. Unlike a star rating, this has
    /// an immediate effect on future rotation — see MilkdropPresetRatingStore's own doc comment.
    private func flagCurrentPreset(_ issue: MilkdropPresetIssue, label: String) {
        guard let url = visualizerModel.presetURL else { return }
        ratingStore.flag(issue, for: url)
        showRatingFeedback(label)
        loadNextSequentialPreset()
        #if DEBUG
        promptForRepoFolderIfNeeded()
        #endif
    }

    /// Up/Down arrow: nudges warpAnimSpeedMultiplier (ProjectMVisualizerModel), clamped so Down
    /// can't zero out the animation entirely and Up can't run it faster than presets already do
    /// unmodified. Applied every frame by ProjectMCoordinator.draw via
    /// engine.setWarpAnimSpeedMultiplier — see the PRISM_LOCAL_PATCH doc in
    /// Vendor/projectm-VERSION.md for what this does and doesn't affect.
    private func adjustWarpAnimSpeed(by delta: Double) {
        let stepped = ((visualizerModel.warpAnimSpeedMultiplier + delta) * 10).rounded() / 10
        visualizerModel.warpAnimSpeedMultiplier = min(2.0, max(0.1, stepped))
        showRatingFeedback(String(format: "Warp Speed: %.1fx", visualizerModel.warpAnimSpeedMultiplier))
    }

    /// Shared one-shot, auto-clearing confirmation for adjustWarpAnimSpeed/flagCurrentPreset — same
    /// Task.sleep idiom as showSavedConfirmation above.
    private func showRatingFeedback(_ message: String) {
        ratingFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            ratingFeedback = nil
        }
    }

    /// Drag-and-drop counterpart to File > "Import .milk Preset…"'s `.fileImporter`, called by `PresetDroppableMTKView`
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
    /// or File > "Import .milk Preset…" is the one thing meant to jump straight to the preset view
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

    /// Waits for `nowPlaying.trackReadySettledToken` to fire at least once - i.e. for
    /// NowPlayingManager to have both detected a currently-playing track *and* settled its ready
    /// gate (real artwork/traits, or its own `readyGateTimeoutInterval` backstop, whichever's
    /// first - see that token's own doc comment) - so onAppear's launch-time preset pick can use
    /// the exact same real song-preset match a track *change* gets, rather than treating "a song
    /// is already playing" as unworthy of the search a mere skip/new-track gets.
    /// `nowPlaying.startPolling()` (called earlier in onAppear) already has a head start on this
    /// by the time `waitForMusicSignal` returns, so this is usually near-instant; the timeout is
    /// only there for when nothing supported (Music/Spotify) is actually playing at all - e.g.
    /// audio from a browser or another app - so this can't hang the launch pick forever waiting
    /// for a track NowPlayingManager will never see. 12s (not NowPlayingManager's own steady-state
    /// readyGateTimeoutInterval) to comfortably clear NowPlayingManager.firstReadyGateTimeoutInterval
    /// (10s) - the launch-time ready gate this call is specifically waiting on runs on that longer,
    /// cold-start budget, not the normal 3.5s one every later track change gets.
    private func waitForNowPlayingTrack(timeoutSeconds: Double = 12) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while nowPlaying.trackReadySettledToken == 0 {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return true
    }

    /// Cmd-S "Find Preset…" Return/click handler — loads whichever `presetSearchResults` row is
    /// currently highlighted and closes the search overlay. `presetSearchResults` URLs come
    /// straight from `presetLibrary.presetURLs`, the same already-security-scoped set sequential/
    /// random draws load from directly (see loadNextSequentialPreset) - no extra
    /// startAccessingSecurityScopedResource dance needed here, unlike the `.fileImporter` closure's
    /// milk-preset case, which is handed a URL from outside that scope entirely. A no-op if the
    /// index is out of bounds - possible if Return is pressed the instant a query that had matches
    /// changes to one that doesn't, before onSubmit and the query's own onChange are done racing.
    private func loadSelectedPresetSearchResult() {
        let results = presetSearchResults
        guard results.indices.contains(presetSearchSelectedIndex) else { return }
        loadPresetAndTrack(from: results[presetSearchSelectedIndex])
        isPresetSearchPresented = false
    }

    /// One row of the Cmd-S preset search results. Extracted into its own `@ViewBuilder` so the
    /// enclosing search overlay's modifier chain stays small enough for the compiler to type-check
    /// in reasonable time.
    @ViewBuilder
    private func presetSearchResultRow(index: Int, url: URL) -> some View {
        let rowBackground: Color = index == presetSearchSelectedIndex
            ? Color.accentColor.opacity(0.35) : .clear
        Text(url.deletingPathExtension().lastPathComponent)
            .lineLimit(1)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                presetSearchSelectedIndex = index
                loadSelectedPresetSearchResult()
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
        // Every preset load funnels through here regardless of source (manual pick, history nav,
        // sequential/random fallback, song-matched pick, ...) - tracing here, not at each call
        // site, is what actually confirms *which* preset ends up on screen, complementing the
        // "why" trace lines the song-matching call site (the trackReadySettledToken onChange
        // handler, loadBestMatchedPreset) log right before calling this - see PrismDebug.swift's
        // own doc comment on why startupTracing is on by default.
        PrismDebug.trace("loadPresetAndTrack: \(url.lastPathComponent)")
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
