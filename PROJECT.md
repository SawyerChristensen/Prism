# Prism — Project Documentation

A native macOS Milkdrop/projectM-style audio visualizer. Captures system audio via Core Audio
Process Taps and renders `.milk` preset files through the real vendored libprojectM 4.x C++ engine
(`Vendor/projectm`, via an EGL/ANGLE-backed bridge — see `Prism/ProjectM/`) — Prism's own earlier
hand-rolled Metal renderer/NS-EEL interpreter was fully replaced by this. Also polls Spotify/Music
for now-playing metadata and derives a background/foreground color scheme from the album art. Also
ships as a Music.app visualizer plug-in (`Prism/PrismVisualizerPlugin/`), reusing the same
projectM engine but driven by Music.app's own pushed audio instead of Prism's own capture.

This file is a map of the codebase (what each file is responsible for) plus a development history
(what's been built and why, session by session). For open work, see `TO DO.md`.

---

## File & folder guide

### `Prism/App/` — app shell
- **`PrismApp.swift`** — `@main` entry point, window styling (hidden title bar).
- **`ContentView.swift`** — root view: hosts the visualizer, the now-playing overlay, the FPS/status
  overlay, preset-loading (`⌘O`, or drag-and-drop a `.milk` file onto the window — `handlePresetDrop`,
  added 7/27), keyboard shortcuts (Space/tap = random preset, `A` = auto-cycle, `L` = library folder
  picker, `←`/`→` = step back/forward through this session's preset history), and the
  `loadPresetAndTrack` choke point every preset load funnels through (crossfade trigger, last-preset
  persistence, auto-cycle reset, history recording) — drag-and-drop feeds into this same choke point,
  not a separate load path. Also auto-prompts for the preset library folder on launch if none is
  configured yet (added 7/26 — previously only prompted lazily, the first time Space/`L` was
  pressed).
- **`PermissionsManager.swift`** — probes/requests the TCC permissions Prism needs (Screen Recording
  for `AudioCaptureEngine`, Automation for `NowPlayingManager`'s Apple Events).
- **`PrismDebug.swift`** — master switch (`PrismDebug.isEnabled`) for verbose diagnostic logging
  across the audio/analysis pipeline; off by default to keep the console quiet.

### `Prism/Audio/` — audio capture and analysis
- **`AudioCaptureEngine.swift`** — audio-only capture via ScreenCaptureKit. Requires the Screen
  Recording permission.
- **`CoreAudioTapEngine.swift`** — alternative capture path via Core Audio Process Taps (macOS
  14.4+), avoiding the Screen Recording permission. Both engines share the same downstream
  analysis (`SpectrumAnalyzer`).
- **`SpectrumAnalyzer.swift`** — shared FFT/banding pipeline both capture engines feed into, so
  comparing the two only varies the capture mechanism, not the analysis.

### `Prism/Milkdrop/` — preset library bookkeeping (no longer rendering)
Everything that used to render presets here (hand-rolled Metal renderer, `MilkdropShaderTranslator`,
the NS-EEL parser/evaluator under `Presets/`) was removed wholesale when Prism switched to the real
vendored libprojectM engine — see `Prism/ProjectM/` below. What's left in this folder is just
library/state bookkeeping that has nothing to do with *how* a preset renders:
- **`MilkdropPresetLibrary.swift`** — the "point at an external folder" preset library: scans a
  user-picked folder for `.milk` files, persisted via a security-scoped bookmark.
- **`MilkdropLastPresetStore.swift`** — persists a bookmark for the single most-recently-loaded
  preset file, so Prism reopens where it left off across launches.
- **`MilkdropPresetComplexityAnalyzer.swift`** — static text scan of a `.milk` file's `warp_N=`/
  `comp_N=` shader lines (tex3D noise-volume lookups, multi-tap GetPixel/GetBlur neighbor sampling)
  to flag presets expensive enough to render at only a few fps. `ContentView`'s sequential
  stepping/auto-cycle skip anything flagged, by default, before ever handing the URL to the engine.
- **`MilkdropPresetRatingStore.swift`** — persists per-preset star ratings and debug issue flags,
  recorded while sequentially reviewing a library (`ContentView`'s `1`-`5`/`w`/`j`/`x` keybinds).
  Keyed by absolute file path rather than a security-scoped bookmark, since it's only ever
  consulted while the library folder is already open.
- **`MilkdropSessionHistoryStore.swift`** — backs the History menu bar item: an append-only,
  order-preserving log of every preset actually played this session, plus an immutable snapshot of
  the previous session's log for the "Last Session" submenu.
- **`MilkdropNestDropFavoritesList.swift`** — parses a NestDrop "bundle" XML export's
  `<FavoriteList>` into the set of preset filenames it names, for preset packs that ship NestDrop
  favorites metadata alongside their `.milk` files.

### `Prism/ProjectM/` — the visualizer itself (real libprojectM engine)
Renders `.milk` presets via the actual vendored libprojectM 4.x C++ library (`Vendor/projectm`,
built to `Vendor/projectm-build/`) rather than a hand-rolled interpreter — full HLSL/NS-EEL preset
compatibility for free, at the cost of needing an EGL/ANGLE context bridge since libprojectM
targets OpenGL/GLES, not Metal.
- **`Bridge/ProjectMEngine.h`/`.mm`** — Objective-C wrapper: one persistent `projectm_handle` for
  the app's lifetime (preset transitions are a call on the same instance, not a
  renderer-reconstruction like the old Metal engine did). Public surface is small and
  host-agnostic: `addInterleavedStereoPCM(_:frameCount:)`, `renderFrame(width:height:)` (returns an
  `IOSurfaceRef`), `loadPreset(at:smoothTransition:)`, `setTargetFPS(_:)`. This same class is
  reused as-is by `Prism/PrismVisualizerPlugin/` (see below) — it has no dependency on Prism.app's
  own audio capture or window management.
- **`Bridge/ProjectMEGLContext.h`/`.mm`** — the actual EGL/ANGLE context + IOSurface-backed render
  target `ProjectMEngine` renders into (`kIOSurfacePixelFormat = 'BGRA'`, i.e. `MTLPixelFormat
  .bgra8Unorm` on the consuming side — no format conversion needed to wrap it as a Metal texture).
- **`ProjectMAudioBridge.swift`** — pulls the latest raw waveform snapshot from
  `CoreAudioTapEngine`, interleaves it, feeds `ProjectMEngine.addInterleavedStereoPCM` once per
  rendered frame. Kept separate from `ProjectMCoordinator` so render-loop orchestration doesn't
  tangle with audio-format/interleaving concerns.
- **`ProjectMCoordinator.swift`** — the `MTKViewDelegate`: drives the render loop, wraps the
  engine's `IOSurface` as an `MTLTexture` (`device.makeTexture(descriptor:iosurface:plane:)`,
  cached and only rebuilt when size/surface identity changes), and composites the album-art
  overlay/transitions on top via `ProjectMCompositeShader.metal`.
- **`ProjectMMetalView.swift`** — bridges `MTKView` (AppKit) into SwiftUI.
- **`ProjectMVisualizerModel.swift`** — the mode/params model `ContentView` and
  `ProjectMCoordinator` share.
- **`PresetDroppableMTKView.swift`** — the concrete `MTKView` subclass, handling preset
  drag-and-drop directly on the render surface.
- **`ProjectMCompositeShader.metal`** — the album-art overlay/transition shaders composited over
  projectM's raw output; `AlbumArtUniforms` here must mirror `ProjectMCoordinator.swift`'s Swift
  struct of the same shape field-for-field.

### `Prism/PrismVisualizerPlugin/` — Music.app visualizer plug-in target
A separate build target (product type "Bundle", not embedded in `Prism.app`) that makes Prism
selectable under Music.app's Window > Visualizer Settings. Implements the legacy-but-still-loaded
iTunes/Music "Visual Plug-in" protocol — an old undocumented Apple SDK, not a modern
ExtensionKit/App Extension mechanism; ships and installs as a standalone `.bundle` copied into
`~/Library/iTunes/iTunes Plug-ins/`, not through the App Store or any embed-and-launch flow. See
`TO DO.md` for what's still untested/unfinished (real-Music.app verification, shipping presets).
- **`iTunesSDK/`** — Apple's own iTunes Visual SDK headers (`iTunesAPI.h`, `iTunesVisualAPI.h`,
  `iTunesAPI.cpp`), vendored verbatim per their redistribution license — defines the wire protocol
  (message types, `RenderVisualData`, etc.) Music.app itself speaks to any loaded visual plugin.
- **`PrismVisualizerPlugin.mm`** — the actual protocol glue: exports `iTunesPluginMainMachO`
  (Music.app locates this exact symbol name by convention, no CFPlugIn factory involved),
  registers as a visual plugin on init, and on each pulse (`Vpls`) message converts Music.app's
  pushed 8-bit waveform samples (`RenderVisualData.waveformData`, 0-255 centered on 128) to
  interleaved float PCM and feeds them straight to a `ProjectMEngine` instance — deliberately does
  *not* use `AudioCaptureEngine`/`CoreAudioTapEngine`: Music.app already owns the audio it's
  playing and pushes it to the plugin directly, so this plugin needs no Screen Recording or audio
  capture permission of its own.
- **`PrismVisualizerView.h`/`.mm`** — a `CAMetalLayer`-backed `NSView` added as a subview of
  whatever view Music.app hands the plugin on activate (the host's own view isn't guaranteed
  drawable into directly — the reference iTunes/Music projectM plugin uses the same
  add-a-subview technique). Blits `ProjectMEngine`'s `IOSurface`-backed texture straight to the
  layer's drawable via `MTLBlitCommandEncoder` — no custom shader needed since both sides are
  `bgra8Unorm`.
- **`Presets/`** — currently empty; drop `.milk` files here directly (see its own `README.md`) to
  give the plugin something to render. Without any, projectM renders its blank/default state.
  GPU-parallel dispatch.

### `Prism/NowPlaying/` — album art and metadata
- **`NowPlayingManager.swift`** — polls Spotify/Music via Apple Events, orchestrates the artwork
  pipeline (masking → color extraction → text extraction → recentering).
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

### `PrismTests/` — unit/integration tests (Swift Testing, `@Test`)
Mirrors the `Prism/` source structure one-to-one for the most part. Two things worth knowing:
- **`RealPresetFixtureTests.swift`** + **`Fixtures/`** — tests against real, byte-for-byte-copied
  `.milk` files (not Swift string literals, which always normalize line endings) — see the CRLF
  bug in the development history below for why this category of test exists at all.
- **`MilkdropMetalRendererShaderTests.swift`** / **`MilkdropShaderTranslatorTests.swift`** — the
  former compiles generated MSL through a real `MTLDevice` (catches invalid-MSL bugs the latter,
  string-transformation-only, can't).

### `PrismUITests/` — Xcode-generated UI test scaffolding (not actively used for this project's own
verification — see `TO DO.md`'s testing-policy note on why standalone `swiftc` harnesses are used
instead of `xcodebuild test`).

### Top level
- **`TO DO.md`** — the active task list. Read this for what's actually left to do.
- **`PROJECT.md`** — this file.
- **`dev-notes/`** — scan output/harness snapshots from specific investigations (e.g.
  `corpus-shader-scan-2026-07-26/`), kept for reproducibility rather than pasted inline into
  `TO DO.md`.
- **`Prism.xcodeproj`** — Xcode project file.
- **`Vendor/`** — `projectm` (git submodule, upstream libprojectM source), `projectm-build/` (its
  built `.dylib`+headers, via `Vendor/build-projectm.sh`), `angle/` (prebuilt ANGLE `libEGL.dylib`/
  `libGLESv2.dylib`). Both the `Prism` app target and `PrismVisualizerPlugin` target link and embed
  the same three `.dylib`s independently (the plugin ships its own copies in its own bundle's
  `Contents/Frameworks/` — it can't rely on `Prism.app` being installed, since Music.app loads it
  standalone).

---

## Development history

Chronological log of what's been built and the real bugs/measurements behind each decision.
Session dates are approximate (as recorded at the time); "measured against the real corpus" means
the ~9,795-file preset pack at `~/Desktop/BestMilkdropPresetsPack` on the development machine, via
a standalone `swiftc` harness (see `TO DO.md`'s testing-policy section) — not a guess.

### 2026-07-23 — project start
Initial app shell, audio capture (both ScreenCaptureKit and Core Audio Tap engines), FFT/spectrum
analysis, now-playing polling and album-art pipeline (masking, color extraction, text extraction,
recentering), and the original CPU/CGContext-based waveform visualizer.

### 2026-07-24 — GPU renderer, Metal migration
Replaced the CPU `CGContext`-based trail buffer with a GPU feedback-texture pipeline
(`MilkdropMetalRenderer`, `Shaders.metal`) — the CPU path couldn't hold 120fps fullscreen on a
high-refresh display and had no headroom for warp effects.

### 2026-07-25 — critical parser bug, then Phase 1/2 feature build-out
- **Critical bug found and fixed: the preset parser never actually parsed a single real preset.**
  `MilkdropPresetFile.init(text:)` split lines on the Character `"\n"`, but Swift's `String` treats
  `"\r\n"` as one extended grapheme cluster (`"\r\n".count == 1`), so the split found zero line
  breaks in a CRLF file and the whole file collapsed into one unparseable blob. Every `.milk` file
  in the real pack (Windows-authored, like the whole Milkdrop/NestDrop ecosystem) is CRLF —
  confirmed 800/800 in a random sample — so this silently defeated 100% of real-world presets the
  entire time. Every existing test used a `"""` triple-quoted Swift string literal, which always
  normalizes to plain `\n` regardless of the source file's line endings, so nothing in the test
  suite exercised the CRLF path either. Fixed by splitting on `\.isNewline` instead. This is the
  origin of the testing-policy rule in `TO DO.md`: any new parsing feature needs a real,
  byte-for-byte fixture, not just a "verbatim-transcribed" string literal.
- **Per-pixel warp mesh** (`per_pixel_N=`, `MilkdropPerPixelMesh.swift`): 32x24-vertex grid, NS-EEL
  eval per vertex, one persistent variable environment shared across the sweep.
- **`warp_N=` HLSL shader compilation** (`MilkdropShaderTranslator`/`MilkdropMetalRenderer`).
  Measured overlap first: 80.9% of corpus has `warp_N=`, 61.8% has `per_pixel_N=`, 48.4% has both —
  a compiled warp shader always draws via the mesh path (matching real Milkdrop's architecture).
  Corpus-scale compile-rate measurement started at 10.5% and, after fixing `GetPixel`/`GetBlurN`
  call-site rewriting (73% of failures), the `tex2D`→`float3` implicit-narrowing swizzle, and
  `texsize_X`/`float1` gaps, reached 39.1% by end of session.
- **Custom waveforms** (`wavecode_N_*`, `MilkdropCustomWaveform.swift`) — 47.7% of corpus.
- **`q1`-`q32` custom per-frame variables** threaded into shader uniforms and the per-pixel mesh.
- **Wave modes 4/5/8** (DerivativeLine, ExplosiveHash, SpectrumLine) ported from projectM.
- **Textured custom shapes** (`shapecode_N_textured=1`) — 64.6% of corpus, the single biggest
  Phase 2 gap by reach.
- **Custom texture loading by sampler name** (`sampler_worms`, etc., resolving against a preset
  pack's own `Textures/` folder) — 19.2% of corpus. Required a `MilkdropShaderTranslator`
  architecture change: an unresolvable custom texture name now resolves to a `.custom(baseName)`
  binding instead of failing translation of the whole shader outright.
- **Motion vectors** (`mv_*`) — measured 8.2% actually visually enabled (vs. 99.2% key-presence,
  which would have been a misleading priority signal — Milkdrop always serializes the keys as
  boilerplate).
- **Border, darken-center** — 52.6% / 6.9% of corpus.
- **Video echo + gamma + brighten/darken/solarize/invert** (the old-style final-composite fallback
  for presets with no `comp_N=`/`warp_N=` at all) — 15.8% of corpus is old-style. Collapsed
  VideoEcho.cpp's multi-pass blend-equation drawing into one closed-form MSL fragment shader,
  verified by direct simulation of the original per-pass algebra (48 checks, all exact matches).
- **Spacebar/tap → random preset**, **preset library** (`MilkdropPresetLibrary.swift`, security-
  scoped bookmark to a user-picked folder), **20s auto-cycle timer**, **last-preset persistence**
  (`MilkdropLastPresetStore.swift`).
- **Performance pass** (reported "abysmally slow"): GPU buffer reuse (`TransientBufferPool`,
  triple-buffered, replacing a fresh `MTLBuffer` allocation every draw call every frame) and
  elimination of a per-function-call heap allocation in the NS-EEL evaluator's `.call` case.

### 2026-07-26 — audit pass, performance Tiers 2-3, preset transitions, shader-compile deep dive
- **Phase 1 re-audit against real projectM source**: found and fixed `pixelsx`/`pixelsy` being
  seeded with aspect ratio instead of real viewport pixel dimensions, and ExplosiveHash dropping
  its Y-axis aspect correction (plus every wave mode using an unclamped aspect ratio, wrong in
  portrait windows).
- **Headline correctness finding: NS-EEL's `if`/`&&`/`||` actually short-circuit** (confirmed
  against `vendor/projectm-eval/TreeFunctions.c`) — only `above`/`below`/`equal`/`band`/`bor`/
  `bnot` (the plain *function* forms) are eager. The evaluator, the GPU-safety analyzer, and the
  MSL transpiler had this backwards (all three assumed eager `if`/`&&`/`||`); all three corrected.
  This is also why the GPU-transpiled path got *simpler* — `if`/`&&`/`||` now transpile to native
  MSL `?:`/`&&`/`||` instead of eager shim functions.
- **Performance Tier 2**: slot-based NS-EEL variable/function resolution (`MilkdropVariableSlots`,
  `MilkdropResolvedProgram`) replacing the `[String: Float]` dictionary storage — 1.69ms → 0.82ms
  per simulated 825-vertex mesh sweep (2.06x).
- **Performance Tier 3**: NS-EEL → MSL GPU vertex-function transpile for `per_pixel_N=`, gated by
  the parallel-safety analyzer. 86.7% of per-pixel-scripted files (5,244/6,049) classified
  sweep-parallel-safe.
- **Preset crossfade transitions**: real dual-live-render blend (`MilkdropMetalCoordinator`,
  `MilkdropSharedRenderResources`), not a freeze-frame dissolve — matches real projectM's
  `m_activePreset`/`m_transitioningPreset` architecture. Blend curve is projectM's exact cosine
  ease; transition duration is projectM's own default (3.0s).
- **Idle "spazz"/jitteriness tuning pass** (user-reported): fixed a fps-floor fix that had been
  described in an earlier commit message but never actually landed; found the beat-punch
  zoom/rotation nudge was frame-rate-coupled with no time-normalization (compounding to ~2.05x
  zoom/sec at the view's actual 120fps target vs. the ~1.43x/sec it read as tuned for); reduced the
  punch magnitude itself (~4-5x calmer) and lengthened the beat-onset refractory interval so dense
  material can't re-trigger on sub-beat transients.
- **Audio-signal bootstrap spike fix**: `MilkdropSignalAnalyzer` seeded `avg`/`longAvg` to a
  hardcoded `1.0` guess rather than the track's real level, causing `bass_rel`/`avg_rel` to read as
  a false onset for the first several seconds after any (re)creation — fixed to snap to the first
  real measurement, plus a `relCap` of 4.0 as a second line of defense.
- **All 10 build warnings fixed** (Swift concurrency / strict-isolation mismatches under
  `-default-isolation=MainActor`), zero-warning build policy adopted going forward.
- **White-screen preset investigation** (5 named presets): found and fixed two real bugs — (1)
  dynamically-compiled `warp_N=`/`comp_N=` shaders used default (fast) math instead of `.safe`
  (fast math permits undefined behavior on divide-by-zero/negative-`pow`, both present in the
  reported presets' actual shader code); (2) local variables declared *before* `shader_body` were
  silently dropped (confirmed in 787/~3,265 sampled files, ~24% of corpus) — this is the origin of
  `MilkdropShaderTranslator.preambleDeclarations`. Two of the five presets remained open at session
  end, both narrowed to specific, documented root causes (see the follow-up entry below for one of
  them; the other is a suspected old-style-composite feedback-gain saturation, unconfirmed against
  real Milkdrop).

### 2026-07-26, continued — full-corpus shader compile scan and fix pass (two sessions)
A session ran out of usage mid-investigation into "how did we not catch the white-screen glitch
before, if everything compiled perfectly?" — the honest answer: `translate()` returning non-nil
only means text-rewriting succeeded, not that the resulting MSL is valid, and historical compile-
rate numbers in this project were point-in-time snapshots, not continuously re-verified. A real,
exhaustive scan of all 9,795 preset files (parse → translate → real `MTLDevice` compile) found only
**41.5%/40.8%** of `warp_N=`/`comp_N=` shaders actually compiled — the dominant cause was HLSL's
general implicit vector narrowing/widening (thousands of instances), plus several smaller,
well-scoped gaps.

The following session worked through that list and beyond, each fix verified against real corpus
examples through a real `MTLDevice` compile (never a synthetic snippet in isolation), with
regression test coverage added to `PrismTests/`:
1. **Swizzle-width mismatch on texture-sample calls** (the dominant cause, ~2,554+ instances) —
   `rewriteTextureSampleCalls` always appended `.xyz` regardless of the actual declared target
   width; now checks via `declaredAssignmentWidth` (scans backward for a `<type> name = ...`
   initializer).
2. **Helper functions defined before `shader_body`** ("function definition is not allowed here",
   483x) — `extractHelperFunctions` hoists them to true top-level MSL scope (`Result
   .helperFunctions`), preserving source order since a later function can call an earlier one.
3. **`M_PI`/`M_PI_2`/`M_INV_PI_2`** (268x undeclared) — added to `shaderShimHeader`, values
   confirmed against projectM's `PresetShaderHeaderGlsl330.inc`.
4. **`texsize_<noise>` always emitted** (257x) — a preset can reference a noise texture's size
   uniform for pure math without ever sampling that texture in the same shader, so call-site-only
   discovery never triggered the define; all 5 noise catalog entries are now unconditional.
5. **`_qa`-`_qh` raw q-var banks** — some presets use the whole float4 bank directly
   (`mul(uv,float2x2(_qa))`), not just individual `q1`-`q32`.
6. **`milkdrop_mul` vector-first overloads** (171x) — HLSL's `mul(a,b)` overloads on argument
   *order*: `mul(matrix,vector)` is M*v, `mul(vector,matrix)` is row-vector v*M; only matrix-first
   existed.
7. **Nested texture calls inside another call's arguments** — `tex2D(sampler_main,
   GetBlur1(uv))`. `scanTextureCalls` only reported the outermost call at a given position, so
   the nested call was invisible to both discovery and rewriting. Both `discoverTextures` and
   `rewriteTextureSampleCalls` now recurse into each call's own arguments (the rewrite also needed
   a different default swizzle — `.xy`, not `.xyz` — for a nested call used as a coordinate arg).
8. **`hue_shader`** (95-110x in samples, the largest *named* gap once the above landed) — real
   Milkdrop bilinearly interpolates 4 grid-corner colors across a subdivided composite mesh; Prism
   has no such mesh, so `milkdrop_hue_shader` returns the interpolant's center value (average of
   the 4 corners) instead — a global per-frame value, reusing the existing `rand_preset` uniform
   as the `hueRandomOffsets` stand-in.
9. **`vol`/`vol_att`** (52-83x) — `vol = (bass+mid+treb)*0.333`, confirmed against projectM's
   `PCM.cpp`. Appended at uniform indices 74/75 so no existing hardcoded index needed renumbering.
10. **`float2x2(singleVectorArg)`** (231x) — HLSL supports constructing a matrix from a single
    vector (row-major pack); MSL's constructor has no equivalent. Rewrites the call site to the
    two-column form MSL supports.
11. **`double`/`double2`/`double3`/`double4`** — real Cg/HLSL treats these as plain aliases for
    `float`/`floatN` on profiles without true double-precision support (which Milkdrop's shader
    profiles never had); MSL's own `double` is a reserved-but-unimplemented keyword. Found while
    investigating a user-reported white-screen preset ("suksma - schlotkin(k).milk").

**Final measured result**: full 9,795-file corpus, **warp_N= 60.03% (4,757/7,924), comp_N= 65.39%
(5,212/7,971)** — up from the 41.5%/40.8% baseline (warp_N= +18.5 points, comp_N= +24.6 points).

**White-screen re-investigation** (3 more user-reported presets): "suksma - schlotkink"/"suksma -
schlotkin" were a genuine compile failure, fixed by the `double3` alias above (though their `warp_`
still hits the general-narrowing/`%`-operator gaps documented in `TO DO.md`). "suksma - gss,sth -
hogwoman style - species pay" and "carved in skin nz+" both compile successfully already (both
`warp_N=` and `comp_N=`) — so their white-screen cause isn't a shader compile failure. Investigated
two candidate mechanisms without reaching a conclusive root cause: (1) "carved in skin nz+"'s
`comp_N=` lerps toward HDR-range colors (`float3(3,2,1)`, literal `2`) that would clamp to solid
white on an 8-bit UNORM render target if a feedback loop pushes a region to saturation — but real
projectM's own feedback texture is *also* `GL_RGBA8` (confirmed against `MilkdropNoise.cpp`), so
this alone isn't a Prism-specific format bug, just a shared architectural property that may or may
not runaway differently here than in real Milkdrop; (2) "hogwoman style"'s heavy use of
multi-instance (`num_inst=33`) additively-blended shapes with `rand()`/`int()`-heavy per-frame
scripts, gated on a `q30` value set by the main per-frame script — Prism's multi-instance shape
loop and `rand()` implementation both look structurally correct on inspection, but confirming
whether per-frame-script execution order (main script vs. shape script q-var visibility) or
`rand()`'s exact distribution matches real Milkdrop would need live rendering to verify, which
wasn't done this session. See `TO DO.md` for this as an open item.

### 2026-07-26, continued — uniforms/GetPixel threading, `%` operator, and two feature TODOs
Worked through three more items from `TO DO.md`'s prioritized shader-compile-gap list, each
verified against the full real corpus (never a synthetic snippet alone) per this project's
testing policy — see `dev-notes/corpus-shader-scan-2026-07-26-followup/` for the full scan output.

1. **`uniforms` threading through hoisted helper functions** (99x "undeclared identifier
   'uniforms'") — a helper function `extractHelperFunctions` hoists to true top-level MSL scope
   has no implicit access to the wrapping fragment function's `uniforms` buffer parameter, even
   though every `time`/`bass`/`q1`/etc. `#define` (`MilkdropMetalRenderer.uniformDefines`) expands
   to `uniforms[N]` regardless of which function it textually lands in. Fixed by threading
   `uniforms` as an explicit parameter through every hoisted function's signature and rewriting
   every call site (from `shader_body`, a preamble declaration, or another hoisted function) to
   pass it along — `threadUniformsParameter`/`appendExtraArguments`.
2. **Texture threading for `GetPixel`/`GetBlur1`/`GetBlur2`** (42x undeclared) — same root cause,
   extended to textures: a hoisted helper directly sampling a texture needs that texture/sampler
   pair threaded as parameters too. Includes a transitive-closure fixed-point pass
   (`extractHelperFunctions`'s `requiredTextures`) so a helper that merely *calls* another
   texture-using helper also gets the right parameters forwarded, verified against a real
   corpus example of exactly that two-level call pattern.
3. **HLSL `%` (float modulo) → MSL `fmod()`** (~400-450x "invalid operands to binary expression")
   — MSL's own `%` is integer-only. Unlike every other rewrite in this file, `%` is an infix
   operator with no comma/paren call-site delimiters to lean on, so `rewriteFloatModulo` walks a
   small expression grammar (postfix chains, unary prefixes, nested groups recursed into first,
   `*`/`/`/`%`'s own left-associative chaining — `a*b%c` correctly becomes `fmod(a * b, c)`, not
   `a*fmod(b,c)`) to find real operand boundaries.
   - **Caused a serious regression, caught before being trusted**: the first full-corpus re-scan
     came back at 14.02%/18.64% (down from 60.03%/65.39%) — the modulo rewriter's tokenizer didn't
     know about `//`/`/* */` comments (a real, common corpus pattern), and reformatting a `//` into
     `/ /` turned commented-out code back into live, broken code (9877x "expected expression").
     Fixed by stripping comments in one pass at the very start of `translate`, before any other
     rewrite pass sees the text — which also protects every *other* text-substitution pass in this
     file (old and new) from the same latent blind spot, not just this one.
   - A second, smaller regression (120x "expected expression") surfaced next: the rewriter also
     collapsed all whitespace, including newlines, to single spaces — breaking `#if`/`#else`/
     `#endif` preprocessor conditionals some presets write directly inside `shader_body`
     ("Mig_177.milk"), which only work because `#` starts its own physical line. Fixed by having
     the rewriter preserve original whitespace verbatim (`ModuloToken.whitespace`) instead of
     reformatting it, while still folding `*`/`/`/`%` chains correctly by looking *past* whitespace
     tokens (not treating them as chain-breakers).

**Final measured result**: full 9,795-file corpus, **warp_N= 62.72% (4,970/7,924), comp_N= 68.03%
(5,423/7,971)** — up from 60.03%/65.39% (warp_N= +2.69 points, comp_N= +2.64 points). All three
targeted error signatures are gone from the top-30 list; the dominant remaining cause is still the
general implicit vector-narrowing gap documented in `TO DO.md`.

Also shipped two smaller `TO DO.md` items in `ContentView.swift`/`MilkdropMetalRenderer.swift`:
- **Preset history (Left/Right arrow keys)** — session-only browser-style back/forward through
  `presetHistory`, Right falling back to a fresh random draw past the end of history.
- **First-launch preset-library auto-prompt** — `onAppear` now prompts immediately if no library
  is configured, instead of waiting for a user to stumble onto Space/`L`.
- **`texsize_blur1`/`texsize_blur2`/`texsize_blur3` real dimensions** — previously aliased the
  generic `texsize` uniform (the main frame's size, not the smaller blur cascade level's own);
  fixed via a chained MSL macro (`blurTexsizeDefine`) expressing each level's real size as a
  deterministic function of the level above it, matching `updateBlurTextures`'s own halving loop —
  no new runtime uniform slot needed.

### 2026-07-27 — systemic white-screen (NaN/Inf feedback poisoning) fix, further spazz reduction
User report: *many* presets flagged "all white," including ones never individually flagged as
buggy, often not white immediately but "animate for a bit and then become all white." That shape —
fine for a while, then permanently broken, on a broad swath of otherwise-unrelated presets — doesn't
match a per-preset authoring bug (those are wrong from frame one, on that one preset). It matches a
non-finite (NaN/Inf) value entering the persistent GPU feedback texture at some unpredictable frame
and never leaving: `feedback_fragment`/`feedback_mesh_fragment`'s bilinear sampling spreads one bad
pixel to its neighbors every subsequent frame, it typically reads back as solid white once stored to
the 8-bit UNORM feedback texture, and white is a stable fixed point most preset math can't pull back
down from (comparisons against NaN are never true, so a later `pow`/`mix`/`clamp` can't rescue it).

The 7/26 session had already found and fixed *one* source of this — fast-math-induced undefined
behavior on div-by-zero/negative-`pow` inside dynamically-compiled `warp_N=`/`comp_N=` shaders,
fixed via `.safe` math mode. Re-examined this session: `.safe` mode only removes the *compiler's*
extra UB on top of an already-non-finite value — it does nothing to stop a preset's own math from
legitimately computing NaN under plain IEEE rules in the first place (`pow` of a negative base to a
fractional exponent is NaN whether or not fast-math is on; so is `asin`/`acos` of an out-of-domain
input, and real presets commonly feed in unnormalized audio signals like `bass`, which routinely
exceeds 1 — see `MilkdropBeatState.minimumBassFloor`). Confirmed by code inspection that nothing
anywhere in the pipeline — the CPU NS-EEL evaluator, the per-frame `warpParams`/
`oldStyleCompositeParams` funnel in `MilkdropVisualizerView.swift`, or the dynamically-compiled
shaders' own final output — ever checked for or scrubbed a non-finite value before it became part
of the persistent feedback state. (A corpus grep for direct `asin(`/`acos(` calls on an audio
signal found only ~10 files — not "many" on its own — but that undercounts the real exposure: any
NS-EEL expression chain can produce an out-of-range intermediate value feeding a later `pow`/`asin`/
`acos`, not just a literal one-line call on `bass` itself, and a GPU-transpiled `per_pixel_N=`
script has the identical exposure on the vertex side, which a CPU-side fix alone wouldn't reach.)

**Fixed, defense-in-depth at every layer** rather than chasing one root cause, since NaN can enter
from several independent places and the goal is that none of them can ever permanently break the
picture:
1. `MilkdropExpressionEvaluator.swift` — `asin`/`acos` clamp their input to `[-1, 1]` before calling
   (matching the file's existing sqrt/log domain-guard convention) instead of reaching NaN on an
   out-of-range input; `pow` returns 0 for a negative base with a non-integer exponent (same
   convention) instead of NaN. Fixed identically in both `callFunction` implementations (the
   resolved-slot fast path used by per-frame/per-vertex/per-shape evaluation, and the string-keyed
   original used for one-shot init programs).
2. `MilkdropVisualizerView.swift`'s `updatePresetPerFrame` — every `warpParams`/
   `oldStyleCompositeParams` field read from `presetVariables` (the ten warp-transform fields that
   drive the feedback pass's multiplicative zoom/rotate/decay, plus `gammaAdj`/`videoEchoZoom`/
   `videoEchoAlpha`, the old-style composite path's equivalent) now only applies when `.isFinite`.
   A non-finite per-frame result just holds last frame's value instead of latching the corruption
   in forever — self-healing the instant the preset's own script produces a sane number again.
3. `Shaders.metal` and `MilkdropMetalRenderer.swift`'s `shaderShimHeader` — a small
   `milkdrop_sanitize`/`milkdrop_sanitize4` helper (`select(c, float(N)(0), !isfinite(c))`) now wraps
   the final output of *every* pass that writes the persistent feedback texture: `feedback_fragment`,
   `feedback_mesh_fragment`, the dynamically-compiled `comp_N=`/`warp_N=` wrappers' `ret` (the two
   `return float4(ret, 1.0)` sites in `buildCompositeShaderSource`/`buildWarpShaderSource`), and the
   old-style composite (layered on top of its existing `saturate`, since `clamp`'s NaN behavior is
   implementation-defined, not guaranteed to land on 0). This is the actually-universal backstop:
   whatever produced the non-finite value — a CPU per-frame variable (already caught by (2), but
   defense-in-depth costs nothing here), a GPU-transpiled `per_pixel_N=` script's own `pow`/`asin`/
   `acos` (not covered by (1)/(2) at all, since that path never goes through the CPU evaluator), or
   something not yet identified — it gets scrubbed to black right at the one choke point everything
   already funnels through, instead of needing every individual cause hunted down first.

Verified: full `xcodebuild build` and `-only-testing:PrismTests build-for-testing` both succeed
(this project's standing policy — never `xcodebuild test`, see `TO DO.md`). Additionally re-ran the
standing full-corpus `warp_N=`/`comp_N=` real-`MTLDevice` compile scan (reusing
`dev-notes/corpus-shader-scan-2026-07-27-round3/harness_main.swift`, per this project's "measure,
don't guess" method) against the shim-header change specifically: **warp_N= 72.69% (5,760/7,924),
comp_N= 79.54% (6,340/7,971)** — identical OK counts, 0 parse failures, 0 translateFail, and the
same top-30 error signatures as the pre-change baseline — confirms `milkdrop_sanitize` is valid MSL
everywhere it's inserted and introduces zero compile regressions across the full real corpus. This fix doesn't replace the three case-by-case white-screen investigations already in
`TO DO.md` (none of those presets' shaders were found to produce NaN — their causes, where
identified, are distinct and still open), but should close the broader "many presets, at
unpredictable times" pattern the user actually reported.

**Separately, a further "make it more relaxing" pass** on `MilkdropBeatState`'s beat-punch tuning
(same user report: many presets read as jittery/spazzy even without an individual bug) — same
direct-calculation verification method as the 7/26 reduction that established this pattern:
`refractoryInterval` 0.16s -> 0.22s (~4.5 triggers/sec ceiling, still comfortably above a 260 BPM
quarter-note rate — fewer re-triggers on dense/bassy material's sub-beat transients), `punchHalfLife`
0.12s -> 0.18s (a hit swells in and fades more slowly, reading as calmer rather than a quick flash).
`renderToTexture`'s zoom/rotation punch formula reduced again: baseline ~1.10x zoom/sec / ~2.1°/sec
-> ~1.06x / ~1.4°/sec, full-punch ~2.0x / ~12.4°/sec -> ~1.52x / ~8.3°/sec (1.0010^60≈1.062,
1.0070^60≈1.520, 0.0004·60 rad≈1.38°, 0.0024·60 rad≈8.25°). Waveform line-width's own punch
coefficient cut 1.4 -> 0.8, so the stroke doesn't pulse as hard on a hit either. Still no live-audio
A/B pass done (GUI automation is unreliable in this environment, and the project's testing policy
avoids launching the real audio-capturing app via automation) — see `TO DO.md`'s open item.

**Also shipped this session: drag-and-drop `.milk` loading.** `ContentView.handlePresetDrop`
accepts any file drag onto the window (`.onDrop(of: [.fileURL], ...)`) and only actually loads it
if `url.pathExtension.lowercased() == "milk"` — anything else is silently ignored rather than
rejected up front, since narrowing the drop target's accepted types to just `.milk` would need a
formally-exported UTI this app doesn't declare (the existing `.fileImporter` picker gets away with
a dynamic `UTType(filenameExtension: "milk")` for its *own* filtering, but that doesn't extend to
what a drag source advertises on the pasteboard). `NSItemProvider.loadDataRepresentation`'s
completion handler runs off the main actor, so the actual load — touching `@State` and needing
security-scoped access to a URL this app didn't pick via its own panel — hops back via
`Task { @MainActor in }`, then brackets the load in `startAccessingSecurityScopedResource`/
`stopAccessingSecurityScopedResource`, mirroring the `.fileImporter` closure's own pattern a few
lines away. Feeds into the same `loadPresetAndTrack` choke point every other load path already
uses, so crossfade/history/last-preset-persistence all work identically regardless of how the
preset arrived. A thin `strokeBorder` overlay, shown only while `isDropTargeted` is true, is the
one piece of feedback that a drag is hovering a valid target at all.

### 2026-07-27, continued — expensive-preset detection and default skip
User-reported: the preset "amandio c - embrace 07 z in the unlikely uneventuality c" renders at
~3fps against a 120fps target. Traced to real per-pixel cost, not a Prism throttle/bug: this
branch (`projectm-vendor-rewrite`) runs the real vendored libprojectM 4.2.0 C++ engine, which
exposes no shader-source/complexity accessor over its public C API (`projectm_load_preset_file` is
fire-and-forget) — so there's no way to ask the engine "is this expensive" before or during a load.
That preset's `warp_N=`/`comp_N=` shader lines do a `tex3D` noise-volume lookup plus a multi-tap
`GetPixel` neighbor sample (Sobel-style edge/gradient effect) every pixel, every frame — genuinely
heavy per-pixel work, unlike presets that only warp a coarse mesh per-vertex.

Added `MilkdropPresetComplexityAnalyzer` — a static scan of the raw `.milk` text (line-oriented,
`warp_N=`/`comp_N=` lines *are* the shader source verbatim) that flags a preset expensive if it
contains a `tex3D(` call, or 3+ `GetPixel`/`GetBlur` neighbor-sample calls. Runs entirely outside
the C++ engine, so it can gate a load before `loadPreset` is ever called. Wired into
`ContentView.loadNextSequentialPreset` (shared by Space, tap, and the auto-cycle timer): expensive
presets default to being skipped, walking forward through the library bounded to one full pass so
a library that's entirely flagged still terminates rather than spinning forever. Explicit loads
(Cmd-O, drag-and-drop, history Left/Right, launch-time restore) intentionally bypass this — the
user picked that exact file, so it still loads. See `TO DO.md` for the follow-up idea (render
flagged presets at reduced resolution and upscale, instead of skipping them outright).

### 2026-07-31 — Music.app visualizer plug-in target, and this doc's stale rendering-architecture writeup
This file's `Prism/Milkdrop/` and `Prism/Milkdrop/Presets/` sections still described the original
hand-rolled Metal renderer/NS-EEL interpreter, which by this point had already been fully replaced
by the real vendored libprojectM engine (`Prism/ProjectM/`) — rewritten to match current source.

Added `PrismVisualizerPlugin`, a new Xcode target that makes Prism selectable under Music.app's
Window > Visualizer Settings. This uses the old (Apple-abandoned, undocumented, but still actually
loaded by current Music.app) iTunes/Music "Visual Plug-in" bundle protocol — confirmed still
functional by the actively-maintained open-source `projectM-visualizer/frontend-music-plug-in`
plugin, which this target's structure is modeled on: a `CFBundlePackageType=hvpl`/
`CFBundleSignature=hook`-style bundle (ours uses `prsm` as its own creator/signature) installed to
`~/Library/iTunes/iTunes Plug-ins/`, exporting a well-known `iTunesPluginMainMachO` symbol Music.app
locates by name (no CFPlugIn factory involved — this predates that convention).

Deliberately reuses `ProjectMEngine` as-is (it was already host-agnostic) but bypasses
`AudioCaptureEngine`/`CoreAudioTapEngine` entirely inside the plugin: Music.app pushes waveform
data to any active visual plugin via the pulse (`Vpls`) message at its own audio's rate, so the
plugin just forwards that straight to `addInterleavedStereoPCM` — meaning the plugin needs zero
Screen Recording or audio-capture permission of its own. This mattered because a plugin `.bundle`
loaded into Music.app's process runs under *Music.app's* sandbox/TCC identity, not Prism's; had the
plugin tried to run its own `AudioCaptureEngine`, the permission prompt would have been confusing
("Music wants to record your screen") and not something the user could grant on Prism's behalf.

Two real Xcode-project pitfalls hit while wiring the new target in by hand (`Prism.xcodeproj` uses
Xcode 16's file-system-synchronized groups for the main `Prism` target, which auto-discovers every
file under `Prism/` unless explicitly excepted):
1. `GENERATE_INFOPLIST_FILE = YES` silently overrides an explicit `CFBundlePackageType` in a
   checked-in `Info.plist` with the generic `BNDL` default — fatal here, since Music.app identifies
   plugin bundles by that exact four-char code. Fixed by setting it to `NO` for this target and
   relying solely on the static `Info.plist` (variable substitution like `$(PRODUCT_BUNDLE_IDENTIFIER)`
   still works without generation).
2. Excluding the new target's folder from the main `Prism` app target's synchronized-group
   membership needed per-file entries in `membershipExceptions` (mirroring the pre-existing
   single-file `Info.plist` exception) — a folder-level exception name alone was silently ignored,
   which surfaced as a "Multiple commands produce .../Contents/Resources/Info.plist" build failure
   (the same latent, previously-harmless issue exists for `Prism/MilkQuickLook/Info.plist`, which
   was never excluded and had just never collided with anything else before now).

Verified via `xcodebuild build -target PrismVisualizerPlugin` and `-target Prism` (both succeed;
per this project's testing policy, `xcodebuild test`/launching the real Music.app was not run from
here — see `TO DO.md` for what's still needed: installing the built bundle and confirming it
actually renders inside a live Music.app, plus shipping real presets into the plugin's empty
`Presets/` folder).

### 2026-08-03 — a second unwatchably-slow preset (num_inst, not pixel shaders), and a runtime watchdog
User-reported: "amandio c - the climbing - shf fab slow downward headfirst crawl to psychological
terminus" renders at a couple fps, and `MilkdropPresetComplexityAnalyzer` — added 2026-07-27 for
the *first* "amandio c" slow preset — wasn't catching it. Two separate reasons:

1. That analyzer only ever scanned `warp_N=`/`comp_N=` (the pixel shader). This preset's real cost
   is `shapecode_2`/`shapecode_3` at `num_inst=1024` each — ~2,174 total shape instances/frame,
   each running ~85-100 trig-heavy `shape_N_per_frame` equation lines, every frame. Pure CPU-side
   expression-evaluation cost with no pixel shader involved at all; the analyzer had zero
   visibility into `shapecode_N_num_inst`/`shape_N_per_frame` (or the wave equivalent,
   `wavecode_N_samples`/`wave_N_per_point`).
2. Even the pixel-shader checks it does run don't hold up: the noise lookup here is
   `tex2D(sampler_noise_hq, ...)`, not `tex3D`, and the neighbor-sample check looked for the exact
   substring `"getblur("` — which never appears in real presets, since the actual MilkDrop/
   projectM intrinsics are always numbered (`GetBlur1`/`GetBlur2`/`GetBlur3`). This preset's `comp`
   shader calls all three and still scored 0 neighbor samples. That half of the check was
   effectively dead code against any real-world corpus.

Fixed both: the neighbor-sample regex now matches `getblur\d*\(` (still requires 3+ combined
GetPixel/GetBlur calls to flag, per the original heuristic), and a new
`equationEvaluationsPerFrame` scan sums `num_inst × per_frame line count` across every enabled
shapecode and `samples × per_point line count` across every enabled wavecode, flagging anything
≥50,000 (this preset totals ~233,000; typical presets are low hundreds to low thousands). Added
`MilkdropPresetComplexityAnalyzerTests.swift` covering both fixed paths plus the original tex3D/
GetPixel cases — verified via `xcodebuild build-for-testing` (compiles) and a standalone `swift`
script exercising the analyzer directly against real fixture text, including this exact preset
file, rather than `xcodebuild test` (which hosts `PrismTests` inside `Prism.app` — see this
project's testing policy in `PROJECT.md`'s own file guide).

That static-scan approach is still fundamentally guesswork over a Turing-complete expression
language, though — this is the *second* pattern it's needed patching for, and it only ever runs
before a load on paths that consult it (sequential stepping/auto-cycle/song-matching); explicit
loads (⌘O, drag-and-drop, history, launch-restore) bypass it by design (see the 2026-07-27 entry).
Rather than keep chasing new patterns, `ProjectMCoordinator` also gained a runtime watchdog
(`updateSlowPresetWatchdog`, called from `updateDisplayFPS` where the existing `smoothedFPS` EMA
already lives): if measured fps stays below 15 for 2.5 seconds straight, the current preset —
whatever it is, however it was loaded — gets reported once via a new
`ProjectMVisualizerModel.slowPresetDetected` property, which `ContentView` consumes the same way
it already consumes `presetLoadError`: step to the next preset and clear the flag. This is
empirical rather than predictive, so it catches every real case (including this one, and whatever
the next one turns out to be) regardless of cause or load path — the static analyzer stays in
place as a fast pre-filter for the load paths that already used it, but the watchdog is now the
actual backstop.
