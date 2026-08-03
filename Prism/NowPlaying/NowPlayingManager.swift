//
//  NowPlayingManager.swift
//  Prism
//
//  Polls Spotify and Music via Apple Events for the current track/artist. Exercises the
//  com.apple.security.automation.apple-events entitlement end-to-end, rather than just
//  the dummy permission-probe AppleScript in PermissionManager.
//

import AppKit
import Foundation
import os

// nonisolated: read from the nonisolated background helpers (queryNowPlaying, runScript) that do
// the actual off-main-thread Apple Events work.
private nonisolated let logger = Logger(subsystem: "com.prism.app", category: "NowPlayingManager")

/// How NowPlayingManager decides what to keep opaque vs. make transparent in the album art
/// background. User-selectable (eventually via a Settings UI — `maskingMode` is a plain settable
/// property specifically so a picker can bind to it directly); `.combined` is the default.
enum ArtworkMaskingMode: String, CaseIterable, Codable {
    /// Color-key the measured background color out broadly, then draw Vision's detected subject
    /// back on top at full fidelity — the subject can never be accidentally punched full of holes
    /// by the color key even if it shares the background's color. See
    /// NowPlayingManager.compositeArtwork.
    case combined
    /// The approach this replaced: Vision's subject mask alone if it found one, else color-keying
    /// alone, with no combining. Simpler and cheaper (no overlay compositing step), but a subject
    /// that shares the background's color can lose pixels to the color key with nothing to
    /// rescue them, and a background Vision can't segment falls back to color-keying's own
    /// black/white-only limitation instead of getting any subject protection at all.
    case visionAloneElseColorKey

    var label: String {
        switch self {
        case .combined: return "Combined (color-key + subject overlay)"
        case .visionAloneElseColorKey: return "Subject detection only"
        }
    }
}

/// The user-facing display choices NowPlayingManager remembers per album — see
/// `NowPlayingManager.artworkPreferences`.
struct ArtworkDisplayPreference: Codable, Equatable {
    var maskingMode: ArtworkMaskingMode
    var includesTextOverlay: Bool
    /// Whether any processing (color-keying, subject masking, text overlay) runs at all for this
    /// album, vs. showing the untouched original artwork — some covers (dense typographic
    /// designs, art with no clean subject/background split) just look best left alone. Defaults
    /// to true so existing/uncurated albums keep today's behavior; `decodeIfPresent` so entries
    /// saved before this field existed still decode instead of failing outright.
    var processingEnabled: Bool = true

    init(maskingMode: ArtworkMaskingMode, includesTextOverlay: Bool, processingEnabled: Bool = true) {
        self.maskingMode = maskingMode
        self.includesTextOverlay = includesTextOverlay
        self.processingEnabled = processingEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maskingMode = try container.decode(ArtworkMaskingMode.self, forKey: .maskingMode)
        includesTextOverlay = try container.decode(Bool.self, forKey: .includesTextOverlay)
        processingEnabled = try container.decodeIfPresent(Bool.self, forKey: .processingEnabled) ?? true
    }
}

@Observable
final class NowPlayingManager {
    private(set) var trackName: String?
    private(set) var artistName: String?
    private(set) var albumName: String?
    private(set) var artwork: NSImage?
    /// Public window onto `cachedRawArtwork` (the unmodified fetched cover, before any masking/
    /// color-keying) — exposed for ContentView's Metal album-art compositing, which needs the full
    /// cover separately from `subjectArtwork` to choreograph a fade-in-then-background-erodes-away
    /// sequence rather than just showing whatever `maskingMode` already flattened.
    var rawArtwork: NSImage? { cachedRawArtwork }
    /// Vision's subject cutout with OCR-detected text drawn back on top at full fidelity — the
    /// same "subject + text" merge `compositeArtwork`'s `.combined` mode produces as its `final`
    /// image (see below), just *without* that function's own last step
    /// (`recenteredOnOpaqueContent()`): the Metal compositing needs this pixel-registered with
    /// `rawArtwork`/`colorKeyedArtwork` — same dimensions, same subject position — so it can be
    /// punched as one hole out of the background layer and sampled at the same scale; recentering
    /// would crop/reposition it out of alignment with the other two. This *is* "the end graphic"
    /// as far as the Metal pass is concerned — what gets treated as the locked-in-place subject
    /// that the background separates away from, text included, not the bare Vision mask alone.
    ///
    /// A plain window onto `cachedSubjectArtwork` — recomputed once per track (or once whenever
    /// `includesTextOverlay` toggles), *not* on every access, by `recomputeDerivedAlbumArtLayers()`.
    /// ProjectMMetalView reads this every SwiftUI update tick (once per rendered frame, since
    /// ContentView's on-screen FPS counter forces a re-render every frame — see
    /// visualizerModel.displayFPS), so doing the actual Otsu-thresholding/CGContext-compositing
    /// work live in here, as an earlier version of this property did, meant redoing that full-image
    /// processing ~120 times a second on the main thread for a cover that never changes between
    /// frames — measured tanking an otherwise-120fps preset down to ~14fps.
    var subjectArtwork: NSImage? { cachedSubjectArtwork }
    /// Vision's subject cutout alone, with no OCR text drawn back on top — the "only the subject"
    /// step of ContentView's four-style album-art cycle (see AlbumArtDisplayStyle), distinct from
    /// `subjectArtwork` above which always includes text when `includesTextOverlay` is on. A plain
    /// window onto `cachedSubjectMask`, cached per track exactly like `subjectArtwork` — same
    /// "don't recompute per access" reasoning applies (ProjectMMetalView reads this every frame).
    var subjectOnlyArtwork: NSImage? { cachedSubjectMask }
    /// OCR-detected text alone, masked out the same way `subjectOnlyArtwork` masks out the subject
    /// — the "subject with text" style's text half, kept as its own layer (rather than pre-merged
    /// into `subjectArtwork`) so the Metal compositing can hold text static while the subject layer
    /// beat-zooms independently on top of it (see ProjectMCoordinator.texturesForCurrentStyle) —
    /// zooming the merged subject+text image together would drag the text along with the subject's
    /// pulse. A plain window onto `cachedTextOnlyArtwork`, cached per track/`includesTextOverlay`
    /// toggle exactly like `subjectArtwork`.
    var textOnlyArtwork: NSImage? { cachedTextOnlyArtwork }
    /// The same color-keying step `.combined` mode uses (see `compositeArtwork`) — nil when the
    /// measured background color isn't a clean solid (`backgroundTone == .other`), same as
    /// `compositeArtwork`'s own `colorKeyed` local. A plain window onto `cachedColorKeyedArtwork` —
    /// cached, not recomputed per access, for the same reason as `subjectArtwork` above (this one
    /// specifically measured ~20-30ms/frame of `keyingOutBackground`'s per-pixel scan, on top of
    /// `subjectArtwork`'s own cost, before caching). Exposed so the Metal compositing (see
    /// `rawArtwork`/`subjectArtwork`) can reinstate `.combined`'s "color-key the background out,
    /// then keep Vision's subject at full fidelity" default instead of relying on the subject mask
    /// alone, which was punching a subject-shaped hole out of the *unkeyed* raw cover for the
    /// background layer.
    var colorKeyedArtwork: NSImage? { cachedColorKeyedArtwork }
    /// The cover keyed out against its own measured background color, subject and OCR text *also*
    /// punched out (see NSImage.punchingHole(using:)) - the fully-separated "background minus
    /// color" layer of ContentView's four-layer stack (see ProjectMCoordinator.AlbumArtLayerCount),
    /// distinct from `colorKeyedArtwork` itself, which still carries the subject/text pixels
    /// (colorKeyingOut a solid background color doesn't know anything about where the subject is).
    /// Unlike `colorKeyedArtwork`, this keys out regardless of `backgroundTone` - `colorKeyedArtwork`
    /// stays gated to near-black/near-white covers because a bad key there would flip `.combined`
    /// mode's *default* look worse for ordinary photo covers, but this layer only shows up when the
    /// user has already revealed it via "M", so a less-precise cutout on a busy cover just means
    /// "some real detail" instead of "always a flat swatch" for the vast majority of covers, which
    /// aren't near-black/near-white. Nil only when there's no measured background color at all (or
    /// no raw artwork loaded yet). Cached alongside the other derived layers by
    /// `recomputeDerivedAlbumArtLayers()` for the same "don't redo this ~120 times a second"
    /// reason as `subjectArtwork`.
    var backgroundDetailArtwork: NSImage? { cachedBackgroundDetailArtwork }
    /// A flat, fully-opaque fill of the measured background color (see NSImage.filled(with:size:))
    /// - the "background color" layer of ContentView's four-layer stack, the bottom of the stack.
    /// Nil only when there's no measured background color at all - not gated on `backgroundTone`
    /// (see `recomputeDerivedAlbumArtLayers`'s own comment on why a flat fill has no precision
    /// requirement the way a color key does).
    var backgroundColorArtwork: NSImage? { cachedBackgroundColorArtwork }
    /// Text Vision found on the current artwork (see TextExtraction.swift), most-confident
    /// reading per line, in whatever order Vision returned them — not guaranteed to be reading
    /// order. Empty (not nil) when there's no text, which is the common case for most covers.
    /// Exposed as its own property (independent of the artwork image itself) so a future feature
    /// can drive an animation off the actual strings/positions without re-running OCR.
    private(set) var albumArtText: [RecognizedTextLine] = []
    private(set) var genre: String?
    private(set) var sourceApp: String?
    private(set) var albumBackgroundColor: NSColor?
    private(set) var albumForegroundColor: NSColor?

    /// Which background-removal strategy to composite the artwork with — see
    /// ArtworkMaskingMode. Settable (not private(set)) so a future Settings picker, or
    /// ContentView's "M" shortcut in the meantime, can bind to it directly. Changing it
    /// recomposites the *current* artwork from cached ingredients (no re-running Vision/OCR —
    /// those already ran once when the track loaded) rather than waiting for the next track. This
    /// is a live preview only — it doesn't save anything on its own; see
    /// `saveCurrentArtworkPreference()`/ContentView's "S" shortcut for that.
    var maskingMode: ArtworkMaskingMode = .combined {
        didSet {
            guard maskingMode != oldValue else { return }
            recomposite()
        }
    }

    /// Whether OCR-detected text gets drawn back on top of the masked artwork at all (see
    /// TextExtraction.swift/`compositeArtwork`). Settable for the same reason as `maskingMode` —
    /// a future Settings toggle can bind to it directly, with the same live-preview-only
    /// recompose-on-change behavior. No manual keyboard shortcut currently exposes this ("T" was
    /// reassigned to ContentView's "Hide Text" toggle, a display-only concern independent of this
    /// pipeline-level flag) — it's driven automatically today (applyParentalAdvisoryDefaultIfNeeded)
    /// and via the persisted per-album ArtworkPreferences.
    var includesTextOverlay: Bool = true {
        didSet {
            guard includesTextOverlay != oldValue else { return }
            recomposite()
            recomputeDerivedAlbumArtLayers()
        }
    }

    /// Master on/off switch for all processing — some covers (dense typographic designs, art
    /// with no clean subject to lift) just look best shown untouched. False bypasses
    /// `compositeArtwork` entirely and shows the raw fetched image, regardless of `maskingMode`/
    /// `includesTextOverlay`. Defaults to true (today's behavior); same live-preview-only,
    /// settable-for-a-future-Settings-picker treatment as the other two.
    var processingEnabled: Bool = true {
        didSet {
            guard processingEnabled != oldValue else { return }
            recomposite()
        }
    }

    // Per-track ingredients cached so `recomposite()` (triggered by `maskingMode` changing) can
    // rebuild `artwork` from the same Vision/OCR results already computed for this track, instead
    // of re-running either. Reset alongside `artwork` in `loadArtwork`, set once per track
    // alongside `artwork` in loadSpotifyArtwork/loadArtworkFromiTunes.
    private var cachedRawArtwork: NSImage?
    private var cachedColors: (background: NSColor, foreground: NSColor)?
    private var cachedSubjectMask: NSImage?
    // Backing storage for `colorKeyedArtwork`/`subjectArtwork`/`textOnlyArtwork` (see their doc
    // comments) — recomputed by `recomputeDerivedAlbumArtLayers()`, never live in the property
    // getter, since ProjectMMetalView reads these every rendered frame.
    private var cachedColorKeyedArtwork: NSImage?
    private var cachedSubjectArtwork: NSImage?
    private var cachedTextOnlyArtwork: NSImage?
    private var cachedBackgroundDetailArtwork: NSImage?
    private var cachedBackgroundColorArtwork: NSImage?

    // Remembers maskingMode/includesTextOverlay per album (see `Self.albumKey`, `loadArtwork`,
    // `saveCurrentArtworkPreference`). Loaded at launch from the bundled Resources/
    // ArtworkPreferences.json — that's what "ships with the app" for every user, curated ahead of
    // time. Saving is explicit (ContentView's "S" shortcut), not automatic on every mode/text
    // change, since M/T are for live-previewing candidates while picking the best one, not
    // something to persist on every keystroke. In DEBUG builds, saving also writes straight back
    // to that same source file (via `sourceResourceURL`, resolved from this file's own compile-
    // time path) so curating during development literally edits the project resource that will
    // ship on the next build — not a separate per-machine store to merge in later.
    private var artworkPreferences: [String: ArtworkDisplayPreference] = [:]
    private var currentAlbumKey: String?

    // Bumped on every `recomposite()` call and captured before dispatching; the write-back only
    // applies if it's still the newest one when the detached task finishes. Without this, rapid
    // M/T toggling can race two concurrent Task.detached calls, and a slower one (e.g. text-on,
    // which does extra Otsu work) can complete after a faster one and silently overwrite the
    // display with a stale result.
    private var recompositeGeneration = 0

    private var timer: Timer?

    // Identifies the currently loaded track so artwork is only re-fetched when the track
    // actually changes, rather than on every 2-second poll.
    private var currentTrackKey: String?

    /// Bumped every time `refresh()` detects an actual track change, synchronously, before any
    /// artwork fetch for that change (if any) has even started - metadata-only (track/artist/album
    /// strings), so there's nothing to wait on. ContentView's "select a new preset on track change"
    /// `onChange` keys off this - preset selection doesn't need to wait on artwork, and
    /// ProjectMCoordinator's own preset-transition album-art effect (see its own doc comments)
    /// reacts automatically to whatever preset that selection loads, so nothing else needs to key
    /// off this directly.
    private(set) var trackChangeToken = 0

    init() {
        loadArtworkPreferences()
    }

    func startPolling() {
        logger.debug("startPolling() called")
        PrismDebug.trace("NowPlayingManager.startPolling()")
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private nonisolated static let supportedApps: [(name: String, bundleID: String)] = [
        ("Spotify", "com.spotify.client"),
        ("Music", "com.apple.Music"),
    ]

    /// `queryNowPlaying` is an Apple Events round-trip (NSAppleScript, synchronous, can block on
    /// TCC/automation permission or a slow/hung target app), so it must never run on the main
    /// thread — `refresh()` is called from a `Timer` on the main run loop every 2 seconds, and a
    /// single slow round-trip there would freeze the UI for that long, repeatedly.
    private func refresh() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for app in Self.supportedApps {
                if let info = Self.queryNowPlaying(app: app) {
                    let key = "\(app.bundleID)|\(info.track)|\(info.artist)|\(info.album)"
                    await MainActor.run {
                        self.trackName = info.track
                        self.artistName = info.artist
                        self.albumName = info.album.isEmpty ? nil : info.album
                        self.sourceApp = app.name
                        if key != self.currentTrackKey {
                            self.currentTrackKey = key
                            self.trackChangeToken += 1
                            // Same-album track change (e.g. skipping to the next song on the same
                            // record) — the art itself isn't changing, so leave cachedRawArtwork/
                            // cachedSubjectArtwork/etc. (and currentAlbumKey) completely alone rather
                            // than clearing and re-fetching them. Since ProjectMCoordinator's own
                            // scaleIn/separate/outgoingExit choreography (see
                            // ProjectMCoordinator.advanceAlbumArtAnimation) only triggers when
                            // rawArtwork hands it a *new* NSImage instance, leaving these untouched
                            // means the art just stays put on screen instead of tearing itself apart
                            // and reassembling for art that would look identical anyway. A nil
                            // albumKey (no artist or album metadata at all) can't be compared this
                            // way, so it always falls through to a normal fetch.
                            let newAlbumKey = Self.albumKey(artist: info.artist, album: info.album)
                            if newAlbumKey == nil || newAlbumKey != self.currentAlbumKey {
                                self.loadArtwork(app: app, artist: info.artist, album: info.album)
                            }
                        }
                    }
                    return
                }
            }
            /*await MainActor.run {
                self.trackName = nil
                self.artistName = nil
                self.albumName = nil
                self.sourceApp = nil
                self.artwork = nil
                self.genre = nil
                self.albumBackgroundColor = nil
                self.albumForegroundColor = nil
                self.currentTrackKey = nil
            }*/
        }
    }

    /// "Space" (ContentView's onKeyPress): toggles play/pause on whichever supported player
    /// (Spotify or Music) is actually current, mirroring the same key's effect when one of those
    /// apps is itself frontmost. Prefers `sourceApp` (the last app `refresh()` saw actively
    /// playing — still meaningful once paused, since `refresh()` leaves it untouched rather than
    /// clearing it when nothing's playing, see `refresh()`'s trailing no-op branch) as long as
    /// that app is still running; falls back to the first of `supportedApps` that's running
    /// (Spotify checked before Music, same order `queryNowPlaying` already uses) for the
    /// nothing's-played-yet-this-launch case. A no-op if neither supported app is running.
    /// Dispatched off the main thread for the same reason `queryNowPlaying`/`runScript` are: a
    /// blocking, synchronous Apple Events round-trip.
    func togglePlayPause() {
        let preferredBundleID = Self.supportedApps.first(where: { $0.name == sourceApp })?.bundleID
        Task.detached(priority: .userInitiated) {
            let running = NSWorkspace.shared.runningApplications
            func isRunning(_ bundleID: String) -> Bool {
                running.contains { $0.bundleIdentifier == bundleID }
            }
            guard let target = Self.supportedApps.first(where: { $0.bundleID == preferredBundleID && isRunning($0.bundleID) })
                ?? Self.supportedApps.first(where: { isRunning($0.bundleID) }) else { return }
            _ = Self.runScript("tell application id \"\(target.bundleID)\" to playpause", appName: target.name)
        }
    }

    private nonisolated static func queryNowPlaying(app: (name: String, bundleID: String)) -> (track: String, artist: String, album: String)? {
        // `application "X" is running` is unreliable from inside App Sandbox (returns false
        // even when the app is genuinely running), so check via NSWorkspace instead — that's a
        // plain Cocoa API and doesn't need Apple Events at all.
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == app.bundleID }) else {
            return nil
        }

        // Addressing by bundle id (rather than by name, e.g. `tell application "Spotify"`) avoids
        // an App Sandbox quirk where by-name Apple Event addressing fails to resolve the target
        // process and surfaces as a generic "Application isn't running" (-600) error.
        let script = """
        tell application id "\(app.bundleID)"
            if player state is playing then
                return (name of current track) & "\u{241F}" & (artist of current track) & "\u{241F}" & (album of current track)
            end if
        end tell
        return ""
        """
        guard let result = runScript(script, appName: app.name) else {
            return nil
        }

        let value = result.stringValue ?? ""
        if PrismDebug.verboseLogging {
            logger.debug("raw result for \(app.name, privacy: .public): \"\(value, privacy: .public)\"")
        }
        let parts = value.components(separatedBy: "\u{241F}")
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        if PrismDebug.verboseLogging {
            logger.debug("now playing via \(app.name, privacy: .public): \(parts[0], privacy: .public) — \(parts[1], privacy: .public) — \(parts[2], privacy: .public)")
        }
        return (track: parts[0], artist: parts[1], album: parts[2])
    }

    // MARK: - Artwork

    private func loadArtwork(app: (name: String, bundleID: String), artist: String, album: String) {
        // Deliberately *not* clearing artwork/cachedRawArtwork/etc. here before kicking off the
        // fetch below: this fires the instant a new album is detected, but the fetch itself is a
        // network round trip (hundreds of ms to a couple seconds) — clearing eagerly used to leave
        // `rawArtwork` (and the rest) nil for that whole window, which ProjectMCoordinator reads as
        // "the art just changed" and immediately blanks the on-screen layers, then blanks them
        // *again* moments later when the real new art actually lands — a visible disappear-then-
        // reappear rather than one clean transition. Leaving the previous track's art in place
        // until the new art is actually ready means there's only ever one real change for
        // ProjectMCoordinator to react to. If this fetch fails outright, the previous track's art
        // just stays on screen (now stale) rather than the screen going blank — an acceptable
        // trade-off for never flashing empty.
        genre = nil // Reset genre here too

        // Apply a saved preference for this album (if any) *before* kicking off the artwork
        // fetch below, so the first composite already uses it instead of the defaults/whatever
        // was left over from whichever album played last. Setting these can trigger `didSet` ->
        // `recomposite()`, which recomposites whatever `cachedRawArtwork` still holds (the previous
        // track's, per the comment above) using the new preference — a harmless, self-correcting
        // mismatch, since the fetch below overwrites `cachedRawArtwork` (and recomposites properly
        // against it) the moment it actually completes.
        currentAlbumKey = Self.albumKey(artist: artist, album: album)
        if let currentAlbumKey, let saved = artworkPreferences[currentAlbumKey] {
            maskingMode = saved.maskingMode
            includesTextOverlay = saved.includesTextOverlay
            processingEnabled = saved.processingEnabled
        }

        switch app.bundleID {
        case "com.spotify.client":
            loadSpotifyArtwork()
            // Only the genre is wanted here — the iTunes lookup must not touch artwork/colors,
            // since it runs as a separate detached task and could otherwise race with
            // loadSpotifyArtwork() and overwrite Spotify's own artwork with Apple Music's.
            loadArtworkFromiTunes(artist: artist, album: album, updateArtwork: false)
        case "com.apple.Music":
            loadArtworkFromiTunes(artist: artist, album: album, updateArtwork: true)
        default:
            break
        }
    }

    // Spotify exposes the artwork as a remote URL. Fetching that URL is itself another blocking
    // AppleScript round-trip (same hazard as queryNowPlaying), so the whole thing — script call
    // included — runs detached, not just the network fetch.
    private func loadSpotifyArtwork() {
        Task.detached(priority: .userInitiated) { [weak self] in
            // `self?.x = ...` inside the nested MainActor.run closure below trips "reference to
            // captured var 'self' in concurrently-executing code" — a weak-optional capture reads
            // as a var to the concurrency checker. Resolving to a strong `let` up front avoids it.
            guard let self else { return }
            let script = """
            tell application id "com.spotify.client"
                if player state is playing then
                    return artwork url of current track
                end if
            end tell
            return ""
            """
            guard let result = Self.runScript(script, appName: "Spotify"),
                  let urlString = result.stringValue,
                  let url = URL(string: urlString) else {
                return
            }

            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else {
                return
            }

            let colors = image.extractColors()
            let subjectMasked = image.maskingOutBackgroundBySubject()
            let textLines = image.recognizedTextLines()
            let (mode, includeText, processing) = await MainActor.run { () -> (ArtworkMaskingMode, Bool, Bool) in
                self.applyParentalAdvisoryDefaultIfNeeded(textLines)
                return (self.maskingMode, self.includesTextOverlay, self.processingEnabled)
            }
            let composited = Self.compositeArtwork(image, colors: colors, subjectMasked: subjectMasked, textLines: textLines, mode: mode, includeText: includeText, processingEnabled: processing)

            await MainActor.run {
                self.artwork = composited
                self.albumArtText = textLines
                self.albumBackgroundColor = colors?.background
                self.albumForegroundColor = colors?.foreground
                self.cachedRawArtwork = image
                self.cachedColors = colors
                self.cachedSubjectMask = subjectMasked
                self.recomputeDerivedAlbumArtLayers()
            }
        }
    }

    // Response shape for the iTunes Search API album lookup.
    private struct iTunesSearchResponse: Decodable {
        struct Result: Decodable {
            let artworkUrl100: String?
            let primaryGenreName: String?
        }
        let results: [Result]
    }

    // Looks album art up by artist + album through the iTunes Search API. Used for sources
    // (like Music) whose artwork can't be read directly, and to fetch genre metadata for
    // sources (like Spotify) that don't expose it — in the latter case `updateArtwork` is
    // false so this can't overwrite artwork/colors already fetched from the real source.
    private func loadArtworkFromiTunes(artist: String, album: String, updateArtwork: Bool) {
        guard !album.isEmpty || !artist.isEmpty else { return }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { return }

        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let response = try? JSONDecoder().decode(iTunesSearchResponse.self, from: data),
                  let firstResult = response.results.first, // 👈 Grab the whole result first
                  let thumbURL = firstResult.artworkUrl100 else {
                return
            }

            let fetchedGenre = firstResult.primaryGenreName // 👈 Extract the genre

            guard updateArtwork else {
                await MainActor.run {
                    self?.genre = fetchedGenre
                }
                return
            }

            // The API returns a 100x100 thumbnail URL; request a larger rendition instead.
            let highResURL = thumbURL.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let artURL = URL(string: highResURL),
                  let (imageData, _) = try? await URLSession.shared.data(from: artURL),
                  let image = NSImage(data: imageData) else {
                return
            }

            // 💡 Extract colors off the main thread
            let colors = image.extractColors()
            let subjectMasked = image.maskingOutBackgroundBySubject()
            let textLines = image.recognizedTextLines()
            let (mode, includeText, processing) = await MainActor.run { () -> (ArtworkMaskingMode?, Bool?, Bool?) in
                self?.applyParentalAdvisoryDefaultIfNeeded(textLines)
                return (self?.maskingMode, self?.includesTextOverlay, self?.processingEnabled)
            }
            let composited = Self.compositeArtwork(image, colors: colors, subjectMasked: subjectMasked, textLines: textLines, mode: mode ?? .combined, includeText: includeText ?? true, processingEnabled: processing ?? true)

            await MainActor.run {
                self?.artwork = composited
                self?.albumArtText = textLines
                self?.genre = fetchedGenre
                self?.albumBackgroundColor = colors?.background
                self?.albumForegroundColor = colors?.foreground
                self?.cachedRawArtwork = image
                self?.cachedColors = colors
                self?.cachedSubjectMask = subjectMasked
                self?.recomputeDerivedAlbumArtLayers()
            }
        }
    }

    /// Turns `includesTextOverlay` off when `lines` is nothing but the RIAA Parental Advisory
    /// sticker (see `[RecognizedTextLine].isOnlyParentalAdvisoryLabel`) — that label is
    /// compliance boilerplate, not part of the cover's actual design, so it shouldn't need to be
    /// drawn back into the visualizer by default. Only applies when this album has no explicit
    /// saved preference yet; an album the user already curated (even to turn text back on)
    /// always wins over this default.
    private func applyParentalAdvisoryDefaultIfNeeded(_ lines: [RecognizedTextLine]) {
        guard currentAlbumKey.map({ artworkPreferences[$0] == nil }) ?? true else { return }
        guard lines.isOnlyParentalAdvisoryLabel else { return }
        includesTextOverlay = false
    }

    /// Rebuilds `cachedColorKeyedArtwork`/`cachedSubjectArtwork` (the backing storage behind the
    /// public `colorKeyedArtwork`/`subjectArtwork` properties) from this track's already-cached
    /// ingredients — called once per track (end of loadSpotifyArtwork/loadArtworkFromiTunes) and
    /// once whenever `includesTextOverlay` toggles, never from the property getters themselves.
    /// Those getters are read by ProjectMMetalView on every SwiftUI update tick, which in practice
    /// is every rendered frame (ContentView's on-screen FPS counter reads `visualizerModel.
    /// displayFPS`, which `ProjectMCoordinator.draw(in:)` updates every frame, forcing a re-render
    /// each time) — doing the real per-pixel color-keying/Otsu-thresholding/CGContext work live in
    /// the getters, as an earlier version did, meant redoing it ~120 times a second for a cover
    /// that never changes between frames, measured tanking an otherwise-120fps preset to ~14fps.
    /// No-op (leaves both caches as they are) if nothing's loaded yet.
    private func recomputeDerivedAlbumArtLayers() {
        guard let cachedRawArtwork else { return }

        if let background = cachedColors?.background, background.backgroundTone != .other {
            cachedColorKeyedArtwork = cachedRawArtwork.keyingOutBackground(background)
        } else {
            cachedColorKeyedArtwork = nil
        }

        let textOverlay = includesTextOverlay ? cachedRawArtwork.maskingOutBackgroundByText(albumArtText) : nil
        cachedTextOnlyArtwork = textOverlay
        switch (cachedSubjectMask, textOverlay) {
        case let (.some(subject), .some(text)):
            cachedSubjectArtwork = subject.overlaying(text) ?? subject
        case let (.some(subject), nil):
            cachedSubjectArtwork = subject
        case let (nil, .some(text)):
            cachedSubjectArtwork = text
        case (nil, nil):
            cachedSubjectArtwork = nil
        }

        // The four-layer stack's own two "background" layers (see ContentView's "M" cycle /
        // ProjectMCoordinator.AlbumArtLayerCount) - genuinely non-overlapping with the subject/
        // text layers above, unlike colorKeyedArtwork itself (color-keying a solid background
        // color out doesn't know anything about where the subject or text actually are, so it
        // still carries their pixels). Reuses `cachedColorKeyedArtwork` when the background already
        // qualified as clean (avoids keying the same image twice); otherwise keys out the same way
        // regardless of `backgroundTone` - see `backgroundDetailArtwork`'s own doc comment for why
        // that's safe here even though `colorKeyedArtwork` itself stays gated. Nil (leaving this
        // layer empty/transparent, letting backgroundColor show through) only when there's no
        // measured background color to key against at all.
        let backgroundDetailKeyedArtwork = cachedColorKeyedArtwork
            ?? cachedColors.flatMap { cachedRawArtwork.keyingOutBackground($0.background) }
        cachedBackgroundDetailArtwork = backgroundDetailKeyedArtwork?
            .punchingHole(using: cachedSubjectMask)
            .punchingHole(using: textOverlay)
        // Unlike colorKeyedArtwork, deliberately *not* gated on backgroundTone != .other: that
        // check exists because keying only works well against a genuinely solid/near-solid
        // background (a bad key color punches holes randomly through the rest of the photo), but a
        // flat fill has no such precision requirement - it's just a solid rectangle of whatever
        // color was actually measured, valid to show for any cover extractColors managed to read
        // *a* dominant background color from at all. Gating this the
        // same way `colorKeyedArtwork` is would leave the backgroundColor layer permanently nil
        // (and this layer of the four-layer stack invisible) for every cover whose background
        // isn't near-black/near-white, which is most of them.
        //
        // Disabled - always nil for now, which the rest of the pipeline already treats as "this
        // layer doesn't exist for this cover" (see ContentView.meaningfulAlbumArtLayerCounts's own
        // doc comment): ProjectMCoordinator falls back to its transparent empty texture, and "M"'s
        // reveal cycle skips straight from the full stack to backgroundDetail without a dead step.
        // Uncomment to bring the flat-fill layer back.
        // if let background = cachedColors?.background {
        //     cachedBackgroundColorArtwork = .filled(with: background, size: cachedRawArtwork.size)
        // } else {
        //     cachedBackgroundColorArtwork = nil
        // }
        cachedBackgroundColorArtwork = nil
    }

    /// Re-composites `artwork` from this track's already-cached ingredients (raw image, colors,
    /// Vision subject mask, OCR lines) after `maskingMode` or `includesTextOverlay` changes — no
    /// re-running Vision or OCR, just the cheap CGContext compositing steps, so a future Settings
    /// picker feels immediate rather than waiting for the next track. No-op if nothing's loaded
    /// yet (`cachedRawArtwork` is nil before the first track finishes loading).
    private func recomposite() {
        guard let cachedRawArtwork else { return }
        let colors = cachedColors
        let subjectMasked = cachedSubjectMask
        let textLines = albumArtText
        let mode = maskingMode
        let includeText = includesTextOverlay
        let processing = processingEnabled

        recompositeGeneration += 1
        let generation = recompositeGeneration

        Task.detached(priority: .userInitiated) { [weak self] in
            let composited = Self.compositeArtwork(cachedRawArtwork, colors: colors, subjectMasked: subjectMasked, textLines: textLines, mode: mode, includeText: includeText, processingEnabled: processing)
            // `guard let self` here (in the still-nonisolated detached-task body), not inside the
            // nested `MainActor.run` closure — capturing the already-unwrapped, non-optional `self`
            // into that nested closure type-checks cleanly; referencing the outer closure's own
            // `weak self` optional from within a nested closure is what triggered the "captured var
            // in concurrently-executing code" warning (an error under strict Swift 6 concurrency).
            guard let self else { return }
            await self.applyRecomposited(composited, ifStillCurrent: generation)
        }
    }

    /// Applies a background-composited image back onto `artwork`, but only if `generation` still
    /// matches the most recent `recomposite()` call — a slower-to-finish stale composite (e.g. from
    /// a track already skipped past) must never clobber a newer one that finished first.
    private func applyRecomposited(_ composited: NSImage, ifStillCurrent generation: Int) {
        guard recompositeGeneration == generation else { return }
        artwork = composited
    }

    /// Composites the final artwork from already-computed ingredients (color-keying is the one
    /// exception — cheap enough to just redo here rather than cache — see NSColor.backgroundTone
    /// for why it's only meaningful against a solid black/white background) according to `mode`
    /// (see ArtworkMaskingMode):
    ///
    /// `.combined` — color-keying subtracts the measured background color wherever it appears,
    /// then the Vision-detected subject is drawn back on top at full fidelity, so the subject is
    /// never accidentally punched full of holes by the color key even if it shares the
    /// background's color, while the color key still cleans up anything outside the subject that
    /// color-keying alone would have caught.
    ///
    /// `.visionAloneElseColorKey` — the approach `.combined` replaced: Vision subject masking
    /// alone if it found something, else color-keying alone, else the untouched original. No
    /// combining, so no protection against a subject sharing the background's color.
    ///
    /// When `includeText` is true, OCR text detection (see TextExtraction.swift) then gets the
    /// same never-punched-full-of-holes overlay treatment as the subject, independent of `mode` —
    /// when false, the pipeline stops right after the subject-masking step and any detected text
    /// is left exactly as `mode` alone would have handled it (color-keyed away if it shares the
    /// background's color, kept if it doesn't).
    ///
    /// When `processingEnabled` is false, all of the above is skipped entirely and `image` comes
    /// back untouched — some covers just look best left alone (see `ArtworkDisplayPreference`).
    ///
    /// Whatever comes out of the steps above then gets recentered on its own remaining opaque
    /// content (see ArtworkRecentering.swift) as the true last step — after text, not before —
    /// so a subject masking left pinned in a corner (or a text overlay drawn back in near an
    /// edge) doesn't stay off-center once the transparent margin around it is gone.
    private nonisolated static func compositeArtwork(
        _ image: NSImage,
        colors: (background: NSColor, foreground: NSColor)?,
        subjectMasked: NSImage?,
        textLines: [RecognizedTextLine],
        mode: ArtworkMaskingMode,
        includeText: Bool,
        processingEnabled: Bool
    ) -> NSImage {
        guard processingEnabled else { return image }

        let colorKeyed: NSImage? = {
            guard let background = colors?.background, background.backgroundTone != .other else { return nil }
            return image.keyingOutBackground(background)
        }()

        let withoutText: NSImage
        switch mode {
        case .combined:
            switch (colorKeyed, subjectMasked) {
            case let (.some(colorKeyed), .some(subjectMasked)):
                withoutText = colorKeyed.overlaying(subjectMasked) ?? subjectMasked
            case let (.some(colorKeyed), nil):
                withoutText = colorKeyed
            case let (nil, .some(subjectMasked)):
                withoutText = subjectMasked
            case (nil, nil):
                withoutText = image
            }
        case .visionAloneElseColorKey:
            withoutText = subjectMasked ?? colorKeyed ?? image
        }

        let final: NSImage
        if includeText, let textMasked = image.maskingOutBackgroundByText(textLines) {
            final = withoutText.overlaying(textMasked) ?? withoutText
        } else {
            final = withoutText
        }
        return final.recenteredOnOpaqueContent()
    }

    // MARK: - Per-album display preferences

    /// Case/whitespace-normalized so "Radiohead" and "radiohead " (say, from two different
    /// sources' metadata formatting) land on the same saved preference. Nil for a track with
    /// neither an artist nor an album name — nothing stable to key on.
    private nonisolated static func albumKey(artist: String, album: String) -> String? {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedArtist.isEmpty || !normalizedAlbum.isEmpty else { return nil }
        return "\(normalizedArtist)|\(normalizedAlbum)"
    }

    /// Explicit save (ContentView's "S") — locks in the *currently previewed* `maskingMode`/
    /// `includesTextOverlay` as this album's preference, in memory immediately (so it applies for
    /// the rest of this run even in a RELEASE build) and, in DEBUG, back to the actual source
    /// resource file so it ships with the app on the next build.
    func saveCurrentArtworkPreference() {
        guard let currentAlbumKey else { return }
        artworkPreferences[currentAlbumKey] = ArtworkDisplayPreference(maskingMode: maskingMode, includesTextOverlay: includesTextOverlay, processingEnabled: processingEnabled)
        #if DEBUG
        persistArtworkPreferencesToSource()
        #endif
    }

    /// Baseline preferences every user gets: read from the bundled resource at launch. This is
    /// the "ships with the app" half — whatever's in Resources/ArtworkPreferences.json at build
    /// time is what a fresh install starts with, no network or write access needed.
    private func loadArtworkPreferences() {
        guard let url = Bundle.main.url(forResource: "ArtworkPreferences", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ArtworkDisplayPreference].self, from: data) else {
            return
        }
        artworkPreferences = decoded
    }

    #if DEBUG
    /// This source file's own project directory, resolved from `#filePath` (captured at compile
    /// time, so it's only meaningful on the machine that built this binary — hence DEBUG-only).
    /// Writing straight back to Resources/ArtworkPreferences.json here — not to UserDefaults, not
    /// to Application Support — is the point: it edits the actual project resource in place, so
    /// `git status` shows the new curated entries and the next build (and every user who installs
    /// it) ships with them.
    private nonisolated static let sourceResourceURL: URL = {
        URL(fileURLWithPath: #filePath) // .../Prism/NowPlaying/NowPlayingManager.swift
            .deletingLastPathComponent() // .../Prism/NowPlaying/
            .deletingLastPathComponent() // .../Prism/
            .appendingPathComponent("Resources/ArtworkPreferences.json")
    }()

    // Prism runs App Sandboxed (see Prism.entitlements), so a plain Data.write(to:) to a path
    // under ~/Documents — outside the sandbox container — fails silently at runtime (caught,
    // logged, otherwise invisible): confirmed as the actual reason "S" saves never showed up in
    // this file despite no crash or visible error. A security-scoped bookmark is the standard
    // sandboxed-app answer for "I have a legitimate, recurring reason to write to this exact file
    // outside my container": the developer grants access once via the system's file panel, and
    // every save after that reuses the bookmark silently. Stored in UserDefaults (not the synced
    // kind — this is dev-machine-only DEBUG tooling, never meant to ship).
    private static let sourceResourceBookmarkKey = "ArtworkPreferences.sourceResourceBookmark"

    private func resolvedWritableSourceResourceURL() -> URL? {
        let defaults = UserDefaults.standard
        if let bookmarkData = defaults.data(forKey: Self.sourceResourceBookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale), !isStale {
                return url
            }
            // Stale or unresolvable (file moved, bookmark revoked) — fall through and re-prompt.
        }

        let panel = NSOpenPanel()
        panel.message = "Grant Prism write access to ArtworkPreferences.json so pressing \"S\" can save curated album art settings back into the project (one-time, DEBUG builds only)."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.sourceResourceURL.deletingLastPathComponent()
        panel.nameFieldStringValue = Self.sourceResourceURL.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Self.sourceResourceBookmarkKey)
        }
        return url
    }

    private func persistArtworkPreferencesToSource() {
        guard let url = resolvedWritableSourceResourceURL() else {
            logger.error("no writable URL for artwork preferences — sandbox access not granted")
            return
        }
        // A bookmark created before the user-selected read-write entitlement existed (or one
        // pointing at a file that's since moved) resolves without throwing but doesn't actually
        // carry working access — dropping it here means the *next* save re-prompts cleanly
        // instead of silently failing on this same broken bookmark forever.
        guard url.startAccessingSecurityScopedResource() else {
            logger.error("couldn't access artwork preferences URL — clearing stale bookmark")
            UserDefaults.standard.removeObject(forKey: Self.sourceResourceBookmarkKey)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(artworkPreferences) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("couldn't write artwork preferences back to source: \(error, privacy: .public) — clearing stale bookmark")
            UserDefaults.standard.removeObject(forKey: Self.sourceResourceBookmarkKey)
        }
    }
    #endif

    // MARK: - Helpers

    private nonisolated static func runScript(_ source: String, appName: String) -> NSAppleEventDescriptor? {
        guard let appleScript = NSAppleScript(source: source) else {
            logger.error("NSAppleScript(source:) init failed for \(appName, privacy: .public)")
            return nil
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            logger.error("AppleScript error for \(appName, privacy: .public): \(error, privacy: .public)")
            return nil
        }
        return result
    }
}
