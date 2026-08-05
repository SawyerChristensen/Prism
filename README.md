# Prism

A native macOS Milkdrop/projectM-style audio visualizer. Prism captures system audio via Core
Audio Process Taps and renders `.milk` preset files through the real vendored libprojectM 4.x C++
engine (`Vendor/projectm`), bridged into Metal via an EGL/ANGLE context (see `Prism/ProjectM/`).
It also polls Spotify/Music for now-playing metadata and composites a reactive, beat-synced album
art layer derived from the track's artwork on top of the visualizer.

Three build targets ship from this repo:
- **Prism.app** — the main visualizer app.
- **PrismVisualizerPlugin** (`Prism/PrismVisualizerPlugin/`) — a Music.app visualizer plug-in,
  reusing the same projectM engine but driven by Music.app's own pushed audio instead of Prism's
  own capture.
- **PrismScreenSaver** (`Prism/PrismScreenSaver/`) — a macOS screen saver, also reusing the same
  engine, showing an idle preset with no audio capture of its own.

---

## Requirements

- macOS 14.4+ (Core Audio Process Taps).
- Xcode, with the `Vendor/projectm` git submodule checked out and built via
  `Vendor/build-projectm.sh` (produces `Vendor/projectm-build/`).
- Screen Recording and/or Automation (Apple Events) permission, requested at launch — see
  `Prism/App/PermissionsManager.swift`.

A local `.milk` preset pack isn't required to build, but the app ships with no presets to browse
without one — see `Prism/Scripts/copy_bundled_presets.sh` below.

## Testing policy

Never run `xcodebuild test` against this project — `PrismTests` hosts inside `Prism.app`, which
launches the real, audio-capturing app and can hang un-killably in this environment. Use
`xcodebuild build` / `-only-testing:PrismTests build-for-testing`, or a standalone `swiftc`
harness (see `Scripts/`, `dev-notes/`) to exercise logic directly instead.

---

## File & folder guide

### `Prism/App/` — app shell
- **`PrismApp.swift`** — `@main` entry point, window styling (hidden title bar), and the menu bar
  (History/Last Session preset menus, Hide Album Art/Hide Text toggles).
- **`ContentView.swift`** — root view: hosts the visualizer, the now-playing overlay, preset
  loading (`⌘O`, or drag-and-drop a `.milk` file onto the window), keyboard shortcuts (Space/tap =
  random preset, `A` = auto-cycle, `L` = library folder picker, `←`/`→` = step back/forward through
  session preset history), and the `loadPresetAndTrack` choke point every preset load funnels
  through (crossfade trigger, last-preset persistence, auto-cycle reset, history recording).
- **`PermissionsManager.swift`** — probes/requests the Automation (Apple Events) permission
  `NowPlayingManager` needs.
- **`PrismDebug.swift`** — master switches for diagnostic logging: `verboseLogging` (recurring
  per-frame/per-poll logs, off by default) and `startupTracing` (one-shot elapsed-time traces for
  launch-sequence hangs, on by default).

### `Prism/Audio/` — audio capture and analysis
- **`CoreAudioTapEngine.swift`** — system audio capture via Core Audio Process Taps (macOS 14.4+).
- **`SpectrumAnalyzer.swift`** — FFT/banding pipeline fed by `CoreAudioTapEngine`'s captured audio.

### `Prism/Milkdrop/` — preset library bookkeeping and song-preset matching
- **`MilkdropPresetLibrary.swift`** — the "point at an external folder" preset library: scans a
  user-picked folder for `.milk` files, persisted via a security-scoped bookmark.
- **`MilkdropLastPresetStore.swift`** — persists a bookmark for the single most-recently-loaded
  preset file, so Prism reopens where it left off across launches.
- **`MilkdropPresetRatingStore.swift`** — persists per-preset star ratings and debug issue flags,
  recorded while sequentially reviewing a library.
- **`MilkdropSessionHistoryStore.swift`** — backs the History menu bar item: an append-only,
  order-preserving log of every preset actually played this session, plus an immutable snapshot of
  the previous session's log for the "Last Session" submenu.
- **`MilkdropNestDropFavoritesList.swift`** — parses a NestDrop "bundle" XML export's
  `<FavoriteList>` into the set of preset filenames it names, for preset packs that ship NestDrop
  favorites metadata alongside their `.milk` files.
- **`MilkdropPresetVisualTraits.swift`** — a static regex/text scan of a `.milk` file's raw INI-like
  content (decay, band-reactivity, motion amplitude/rate, color warmth, etc.) that builds each
  preset's "visual fingerprint," plus the `Codable` struct it produces.
- **`MilkdropPresetVisualTraitsStore.swift`** — loads the bundled, pre-generated
  `Resources/PresetVisualTraits.json` once at launch into an in-memory lookup table; no runtime
  re-scanning.
- **`SongPresetMatcher.swift`** — pure scoring logic (no I/O) comparing a song's audio traits
  (valence, energy, danceability, tempo, etc., from `ReccoBeatsClient`) against every preset's
  visual traits, weighted-averaged over whichever sub-scores have a signal, to rank a library for
  the best-matching preset.

### `Prism/ProjectM/` — the visualizer itself (real libprojectM engine)
Renders `.milk` presets via the actual vendored libprojectM 4.x C++ library (`Vendor/projectm`,
built to `Vendor/projectm-build/`) — full HLSL/NS-EEL preset compatibility for free, at the cost of
needing an EGL/ANGLE context bridge since libprojectM targets OpenGL/GLES, not Metal.
- **`Bridge/ProjectMEngine.h`/`.mm`** — Objective-C wrapper: one persistent `projectm_handle` for
  the app's lifetime (preset transitions are a call on the same instance, not a
  renderer-reconstruction). Public surface is small and host-agnostic:
  `addInterleavedStereoPCM(_:frameCount:)`, `renderFrame(width:height:)` (returns an
  `IOSurfaceRef`), `loadPreset(at:smoothTransition:)`/`loadPresetFromData:`,
  `setTargetFPS(_:)`, and `setTextureOverrideImage:forName:` (registers an in-memory image against
  a named projectM texture, used to swap in a custom idle-preset glyph). Reused as-is by
  `PrismVisualizerPlugin` and `PrismScreenSaver` — it has no dependency on Prism.app's own audio
  capture or window management.
- **`Bridge/ProjectMEGLContext.h`/`.mm`** — the actual EGL/ANGLE context + IOSurface-backed render
  target `ProjectMEngine` renders into (`kIOSurfacePixelFormat = 'BGRA'`, i.e. `MTLPixelFormat
  .bgra8Unorm` on the consuming side — no format conversion needed to wrap it as a Metal texture).
- **`ProjectMAudioBridge.swift`** — pulls the latest raw waveform snapshot from
  `CoreAudioTapEngine`, interleaves it, feeds `ProjectMEngine.addInterleavedStereoPCM` once per
  rendered frame.
- **`ProjectMCoordinator.swift`** — the `MTKViewDelegate`: drives the render loop, wraps the
  engine's `IOSurface` as an `MTLTexture`, and composites a four-layer album-art parallax stack
  (background color, background detail, text, subject — each independently beat-zoomed) on top via
  `ProjectMCompositeShader.metal`. The album-art wipe reveal is driven off the same live
  preset-transition state (shader index, progress, random seed) real projectM uses for its own
  preset crossfade, so the two stay in lockstep.
- **`ProjectMMetalView.swift`** — bridges `MTKView` (AppKit) into SwiftUI.
- **`ProjectMVisualizerModel.swift`** — the mode/params model `ContentView` and
  `ProjectMCoordinator` share.
- **`PresetDroppableMTKView.swift`** — the concrete `MTKView` subclass, handling preset
  drag-and-drop directly on the render surface via AppKit's own `NSDraggingDestination` (SwiftUI's
  `.onDrop` showed no drag recognition at all layered on top of this view).
- **`ProjectMCompositeShader.metal`** — the album-art layer compositing: chromatic aberration
  (independently-rotating per-channel sample offsets along the wave's brightness gradient),
  per-layer beat-zoom, and the preset-transition-matched wipe effects (circle/plasma/simpleBlend/
  sweep/warp/zoomBlur, mirroring projectM's own built-in transition shaders). `AlbumArtUniforms`
  here must mirror `ProjectMCoordinator.swift`'s Swift struct of the same shape field-for-field.

### `Prism/PrismVisualizerPlugin/` — Music.app visualizer plug-in target
A separate build target (product type "Bundle", not embedded in `Prism.app`) that makes Prism
selectable under Music.app's Window > Visualizer Settings. Implements the legacy-but-still-loaded
iTunes/Music "Visual Plug-in" protocol — an old undocumented Apple SDK, not a modern
ExtensionKit/App Extension mechanism; ships and installs as a standalone `.bundle` (installation is
currently a manual step — see `TO DO.md`).
- **`iTunesSDK/`** — Apple's own iTunes Visual SDK headers (`iTunesAPI.h`, `iTunesVisualAPI.h`,
  `iTunesAPI.cpp`), vendored verbatim per their redistribution license.
- **`PrismVisualizerPlugin.mm`** — the protocol glue: exports `iTunesPluginMainMachO` (Music.app
  locates this exact symbol by convention, no CFPlugIn factory involved), registers as a visual
  plugin on init, and on each pulse (`Vpls`) message converts Music.app's pushed 8-bit waveform
  samples to interleaved float PCM and feeds them straight to a `ProjectMEngine` instance —
  deliberately does *not* use `CoreAudioTapEngine`: Music.app already owns the audio it's playing
  and pushes it to the plugin directly, so this plugin needs no audio-capture permission of its
  own. Scans for `.milk` presets first in its own bundle's `Contents/Resources/Presets/`, then
  falls back to a preset pack on disk.
- **`PrismVisualizerView.h`/`.mm`** — a `CAMetalLayer`-backed `NSView` added as a subview of
  whatever view Music.app hands the plugin on activate. Blits `ProjectMEngine`'s `IOSurface`-backed
  texture straight to the layer's drawable via `MTLBlitCommandEncoder`, and runs its own internal
  60Hz render timer independent of Music.app's pulses (which only arrive during active playback).
- **`Presets/`** — drop `.milk` files here directly (see its own `README.md`) to give the plugin
  something to render; currently empty, so a fresh checkout falls back to the on-disk preset pack
  path or projectM's blank/default state.

### `Prism/PrismScreenSaver/` — macOS screen saver target
A `ScreenSaverView` subclass reusing the same `ProjectMEngine`/`PrismVisualizerView` pair as the
Music.app plugin, showing a fixed idle preset (with its own glyph texture swapped in) and nothing
else — no audio capture, since a screen saver process has no business requesting capture
permissions of its own.

### `Prism/NowPlaying/` — album art and metadata
- **`NowPlayingManager.swift`** — polls Spotify/Music via Apple Events, orchestrates the artwork
  pipeline (masking → color extraction → text extraction → recentering) and the song-trait lookup
  (see `ReccoBeatsClient.swift`), gating both behind a single "ready" token so a track change only
  ever triggers one preset transition.
- **`AlbumColors.swift`** — background/foreground color extraction (k-means clustering) from
  album art, used for the window/text tint.
- **`SubjectMasking.swift`** — Vision-based subject-lifting segmentation to isolate album art's
  main subject from its background.
- **`TextExtraction.swift`** — Vision OCR on album art (protects detected text from being masked
  away as "background," and stores recognized text for potential future use).
- **`ArtworkRecentering.swift`** — crops/recenters artwork after masking leaves transparent
  margins, so an off-center subject doesn't stay pinned to one corner.
- **`PixelExactImage.swift`** — works around `NSImage(cgImage:size:)`'s Retina-scale-factor
  reporting bug so downstream pixel math operates on the image's *actual* dimensions.
- **`ReccoBeatsClient.swift`** — a live network client (no API key) hitting the free ReccoBeats API
  for a track's audio features (valence, energy, danceability, tempo, etc.) — a keyless mirror of
  Spotify's now-defunct `audio-features` endpoint. Requires internet access at runtime; the app
  degrades to sequential preset picking if it's unreachable or has no match for a track.
- **`SongAudioTraitsCache.swift`** — persists resolved (and confirmed-missing) ReccoBeats lookups
  to `UserDefaults`, so a replayed track skips the network round-trip.

### `Prism/MilkQuickLook/` — QuickLook thumbnail extension
Shows the `.milk` document icon as the Finder thumbnail for `.milk` preset files
(`MilkThumbnailProvider.swift`).

### `PrismTests/` — unit/integration tests (Swift Testing, `@Test`)
Mirrors the `Prism/` source structure for the library-bookkeeping layer (`MilkdropPresetLibrary`,
`MilkdropLastPresetStore`, `MilkdropPresetRatingStore`, `MilkdropNestDropFavoritesList`).

### `PrismUITests/` — Xcode-generated UI test scaffolding
Not actively used for this project's own verification — see the testing policy above.

### Top level
- **`TO DO.md`** — the active task list.
- **`README.md`** — this file.
- **`dev-notes/`** — scan output/benchmark harness snapshots from specific investigations, kept
  for reproducibility.
- **`Scripts/generate_preset_visual_traits.sh`** (+ `.swift.txt`) — an offline, dev-time-only tool:
  walks a preset pack directory, runs `MilkdropPresetVisualTraitsAnalyzer` over every `.milk` file,
  and regenerates the committed `Resources/PresetVisualTraits.json`. Never run at build or runtime.
- **`Prism/Scripts/copy_bundled_presets.sh`** — Run Script build phase: stages a curated,
  FPS-benchmarked preset pack into the built app's `Resources/Presets`, skipping NestDrop's
  per-preset thumbnails and "! Transition" folder. Defaults to a pre-measured 60fps+ subset (see
  `dev-notes/preset-fps-benchmark-2026-08-04`) rather than an unfiltered pack, so nothing in the
  shipped library needs a runtime performance guard.
- **`Prism.xcodeproj`** — Xcode project file.
- **`Vendor/`** — `projectm` (git submodule, upstream libprojectM source), `projectm-build/` (its
  built `.dylib`+headers, via `Vendor/build-projectm.sh`), `angle/` (prebuilt ANGLE `libEGL.dylib`/
  `libGLESv2.dylib`). Both the `Prism` app target and `PrismVisualizerPlugin` target link and embed
  the same three `.dylib`s independently — the plugin ships its own copies in its own bundle's
  `Contents/Frameworks/`, since it can't rely on `Prism.app` being installed.
