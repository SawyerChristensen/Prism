# Prism — To Do

For what each file/folder does and the full development history (why things were built the way
they were, with measurements), see `PROJECT.md`. This file is just the active task list.

**Standing method — measure, don't guess**: for anything preset-format-related, verify against the
real ~9,795-file corpus at `~/Desktop/BestMilkdropPresetsPack/Presets` via a standalone `swiftc`
harness (see "Testing policy" below), not a synthetic snippet or a single file. Re-run the relevant
measurement after a fix, don't assume it worked.

---

## Open — shader compile gaps (`MilkdropShaderTranslator.swift`/`MilkdropMetalRenderer.swift`)

Current state (2026-07-27): full 9,795-file corpus, **warp_N= 72.69% (5,760/7,924), comp_N=
79.54% (6,340/7,971)** compile through a real `MTLDevice` — up from 63.35%/68.06% at the start of
7/26 (+9.34pt/+11.48pt, +740/+915 files, across three rounds of fixes this session). See
`PROJECT.md`'s development history for everything already fixed to get here. Ordered by real
full-corpus error-signature counts as of the last scan
(`dev-notes/corpus-shader-scan-2026-07-27-round3/README.md` explains how to rerun it, and has the
full three-round writeup) — re-measure before trusting these counts, they'll drift as fixes land.

- [x] **THE DOMINANT REMAINING CAUSE, several thousand instances**: general implicit vector
  narrowing on *plain* assignments and other expressions — not texture-sample calls (already
  fixed). Real example: `mask = 1-.9*milkdrop_saturate(8*dist)*milkdrop_saturate(64*neu);` where
  `mask` is declared `float` but the RHS evaluates to `float3` ("propre hypno.milk"'s comp_).
  **Fixed 7/26**: `narrowWideAssignments` walks each shader body/helper function, using a
  lightweight symbol table (`collectDeclarations`/`collectParameterWidths` — every local's
  declared width from its own `<type> name` declaration or parameter) plus a width inferencer
  (`widthOfExpression`/`widthOfPrimary`/`widthOfCall`, covering arithmetic chains, componentwise
  intrinsics, swizzles, ternaries, and preset-defined helper-function return widths) to insert a
  narrowing swizzle wherever a *provably wider* RHS is assigned into a narrower-declared lvalue —
  bailing silently (leaving the statement untouched) whenever the width isn't confidently known,
  rather than guessing. Deliberately scoped to the narrowing direction only (not widening,
  compound-assignment operators, or swizzled-LHS writes like `ret.xyz = ...` — see
  `dev-notes/corpus-shader-scan-2026-07-26-narrowing/README.md` for what's still open in this
  space). Measured impact on the full corpus: `warp_N=` 63.35% -> 66.56% (+3.21pt, 5,020 -> 5,274
  OK), `comp_N=` 68.06% -> 76.26% (+8.20pt, 5,425 -> 6,079 OK) — the single largest single-fix jump
  measured so far this project, especially for `comp_N=`. Real regression risk was the whole
  reason this was flagged as the biggest remaining item to get right — re-verified against the
  full corpus after landing, not just a sample; 0 parse failures, 0/0 `translateFail`, no new
  runaway error signature (unlike the `%`-modulo rewrite's earlier comment-corruption regression).
- [x] **Swizzled-LHS writes and compound assignment weren't narrowed** (`ret.xyz = wideExpr;`,
  `mask += wideExpr;`): the narrowing pass above only recognized a plain-identifier `=` target.
  **Fixed 7/27**: `trailingSwizzleWidth` recognizes a component write (target width = the swizzle's
  own length, no symbol lookup needed); the assignment-operator scan now also recognizes `+=`/`-=`/
  `*=`/`/=` (narrowing just the RHS is still correct there — see `processStatementChunk`'s own doc
  comment on why that commutes).
- [x] **`static`/`const`-qualified preamble declarations silently dropped** (~180x combined across
  `sunpos`/`sw2`/`samples`/`res`/`n` "undeclared identifier" signatures): `preambleDeclarations`
  only ever checked for `float`/`int`/`bool` at the very *start* of a statement, never past a
  qualifier — `static float2 sunpos = ...;`/`const float4 samples[5] = {...};` were dropped
  wholesale. **Fixed 7/27** (`preambleDeclarations`'s qualifier-stripping), plus two things this
  surfaced once the declarations stopped being dropped: a bare `static` (no `const`) is invalid MSL
  on a function-scope variable (**fixed**, `renameIntrinsics` now drops it, matching its existing
  `static const` -> `const` handling); and a helper function referencing a preamble local (not a
  parameter) has no more implicit access to it than to `uniforms`/a texture (**fixed**,
  `extractHelperFunctions` now threads plain preamble locals the same way, including transitively
  through a helper-calls-helper chain — see `collectDeclaredTypeKeywords`/`threadLocalParameters`).
- [x] **`int`/`int2`/`int3`/`int4` declared from a float-typed RHS** (42x, e.g. `int2 k1 =
  (texsize.xy*uv)%2;`, identical across all 42 files): real HLSL/Cg implicitly truncates float->int
  on assignment; MSL doesn't. **Fixed 7/27**: a fresh int-typed declaration's whole RHS gets wrapped
  in an explicit `intN(...)` cast, unconditionally.
- [x] **35x "no matching function for call to `milkdrop_mul`"**: the existing matrix-shaped
  overloads didn't cover real HLSL's *other* documented `mul` forms (scalar-scalar, scalar-vector —
  confirmed against "Star Forge v13c.milk"'s warp_, `mul(pow(q3,1.25), .013*tex2D(...))`). **Fixed
  7/27**: added `milkdrop_mul(float,float)`/`(float,floatN)`/`(floatN,float)` overloads (down to
  15x after — the remaining ones are likely the *vector,vector* form, not attempted without a
  confirmed real example of what that should do).
- [x] **27x "no matching function for call to `all`"**: HLSL's `all`/`any` implicitly test each
  component against zero on any numeric vector; MSL's only accept `boolN`. **Fixed 7/27**: added
  `all(floatN)`/`any(floatN)` overloads to the shim header (a real overload, not a redefinition
  risk, unlike `lerp`/`saturate`/`mul`).
- [x] **56x "excess elements in array initializer"**: real HLSL/Cg allows a flat, ungrouped scalar
  initializer list for an array of vectors (`const float4 samples[5] = {0.0,0.0,0,11.0/3.0, ...};`,
  identical across all 56 files); MSL's aggregate initialization has no implicit grouping. **Fixed
  7/27**: `regroupFlatVectorArrayInitializers` regroups the flat list into `floatN(...)` per
  element, only when unambiguous (no existing brace nesting, value count divides evenly by width).
- [ ] **"ambiguous call to `dot`/`length`/`clamp`/`min`/`pow`/`fmod`/`max`" (394x/156x/58x/51x/
  47x/45x/21x) and the broader "implicit conversions between vector types" cluster
  (521x/348x/307x/297x/273x/243x/192x/153x/66x/34x ≈ 2,400 instances)**: still the largest remaining
  cluster after all of the above — some is the narrowing pass's own documented scope limit
  (function-*call-argument* narrowing was never attempted, only assignment/compound-assignment/
  swizzle-write targets), some may be distinct, uninvestigated bugs. See
  `dev-notes/corpus-shader-scan-2026-07-27-round3/README.md` for the full remaining-gaps writeup,
  including several newly-visible smaller signatures (49x "read-only variable is not assignable",
  20x "redefinition of 'tmp'", 40x "invalid operands ... float2x2 and int", 28x "no matching member
  function for call to 'sample'" — confirmed as a texture-helper call's *coordinate* argument
  evaluating to `float3` instead of `float2`, a narrower variant of the same narrowing-scope-limit
  issue, in a real preset).
- [x] **~48x "undeclared identifier 'MyGet'"/69x broken `sat(...)` calls/~100x custom-texture
  aliases silently resolving to the wrong (likely-missing) texture**: **fixed 7/26** — root cause
  was a plain object-like preprocessor alias before `shader_body`, e.g. `#define MyGet GetPixel`,
  `#define sat saturate`, `#define sampler_pic sampler_prayerwheel` (confirmed via real corpus
  scan of preamble `#define` lines, ~213 files). Not a function *definition*
  (`extractHelperFunctions`'s shape) or a `;`-terminated variable declaration
  (`preambleDeclarations`'s shape) — a `#define` line has neither, so `preambleDeclarations`'s
  semicolon-split was silently merging it into garbage and dropping it, leaving the alias
  unrecognized everywhere downstream. `expandObjectMacros` now substitutes each alias with its
  real target before texture discovery/intrinsic renaming/helper extraction ever run. Measured
  impact on the full corpus: `warp_N=` 62.72% -> 63.35% (+0.63pt, 4,970 -> 5,020 OK),
  `comp_N=` 68.03% -> 68.06% (+0.03pt), and 14/3 `translateFail` (outright `translate()` nil)
  dropped to 0/0 — modest, since most files hitting this were *also* blocked by the still-open
  narrowing bug above, but a handful were unblocked outright and the specific error signature is
  now gone from the top-30 list entirely.
- [x] **~400-450x "invalid operands to binary expression ('float' and 'int')"**: HLSL's `%` does
  floating-point modulo; MSL's `%` is integer-only. **Fixed 7/26**: `MilkdropShaderTranslator`
  now walks a small expression grammar (postfix chains, unary prefixes, nested groups, `*`/`/`/`%`'s
  own left-associative chaining) to find each `%`'s real operand boundaries and rewrites it to
  `fmod(a, b)` — see `rewriteFloatModulo`. Caused a serious regression along the way (comments and
  `#if`/`#endif` mid-shader both got corrupted by the rewriter's text-reformatting) — see
  `dev-notes/corpus-shader-scan-2026-07-26-followup/README.md` for the full story; both are fixed
  now (`stripComments` runs first in `translate`; the rewriter preserves original whitespace
  instead of reformatting it).
- [x] **99x "undeclared identifier 'uniforms'"**: **fixed 7/26** — `uniforms` is now threaded as
  an explicit parameter through every hoisted helper function and its call sites (both from
  `shader_body` and from other helpers), since a hoisted function is genuinely top-level MSL with
  no implicit access to the wrapping function's uniform buffer. See `threadUniformsParameter`/
  `appendExtraArguments`.
- [x] **42x "undeclared identifier 'GetPixel'"** (and `GetBlur1`/`GetBlur2`): **fixed 7/26** —
  same threading approach extended to textures: a hoisted helper that directly samples a texture
  gets that texture/sampler threaded as parameters, with a transitive-closure pass so a helper
  that merely *calls* another texture-using helper also gets it forwarded correctly. See
  `extractHelperFunctions`'s `requiredTextures` closure.

---

## Open — white-screen presets

**New 7/27: a systemic NaN/Inf-poisoning theory, fixed.** The user reported *many* presets going
white — not just the handful individually investigated below — often after animating fine for a
while first, not immediately. That "fine, then permanently white" pattern doesn't match a per-
preset authoring bug (those would be wrong from frame one); it matches a non-finite (NaN/Inf) value
entering the persistent GPU feedback texture at some unpredictable frame, then never leaving — the
warp pass's bilinear sampling spreads a single bad pixel to its neighbors every subsequent frame,
it typically reads back as solid white once stored to the 8-bit UNORM target, and white is a stable
fixed point most preset math can't pull back down from (comparisons against NaN are never true).
The 7/26 session already found and fixed one source of this (fast-math-induced UB on div-by-zero/
negative-`pow` inside *compiled* shaders — see development history below), but `.safe` math mode
only removes the compiler's *extra* UB on top of NaN; it doesn't stop a preset's own math from
legitimately computing NaN under plain IEEE rules (e.g. `pow` of a negative base to a fractional
exponent, or `asin`/`acos` of an unnormalized signal like `bass` — which routinely exceeds 1, see
`MilkdropBeatState.minimumBassFloor`). Nothing anywhere in the pipeline — the CPU NS-EEL evaluator,
the per-frame `warpParams`/`oldStyleCompositeParams` funnel, or the dynamically-compiled shaders'
own final output — ever checked for or scrubbed a non-finite value before it became part of the
persistent state. **Fixed**, defense-in-depth at every layer:
  1. `MilkdropExpressionEvaluator.swift`: `asin`/`acos` now clamp their input to `[-1, 1]` before
     calling (matching this file's existing sqrt/log domain-guard convention) instead of letting an
     out-of-range input reach NaN; `pow` returns 0 for a negative base with a non-integer exponent
     (same convention) instead of NaN. Both `callFunction` implementations (resolved-slot fast path
     and the string-keyed original) fixed identically.
  2. `MilkdropVisualizerView.swift`'s `updatePresetPerFrame`: every `warpParams`/
     `oldStyleCompositeParams` field read from `presetVariables` (the ten warp-transform fields plus
     `gammaAdj`/`videoEchoZoom`/`videoEchoAlpha`) now only applies if `.isFinite` — a non-finite
     per-frame result just holds last frame's value instead of latching corruption in, so it
     self-heals the moment the preset's own script produces a sane number again.
  3. `Shaders.metal`/`MilkdropMetalRenderer.swift`'s shim header: a `milkdrop_sanitize`/
     `milkdrop_sanitize4` helper (`select(c, 0, !isfinite(c))`) now wraps the final output of every
     pass that writes the persistent feedback texture — `feedback_fragment`, `feedback_mesh_fragment`,
     the dynamically-compiled `comp_N=`/`warp_N=` wrappers' `ret`, and the old-style composite (on
     top of its existing `saturate`, whose own NaN behavior is implementation-defined) — so *any*
     non-finite value, from *any* source (including ones (1)/(2) don't cover, like a GPU-transpiled
     `per_pixel_N=` script's own `pow`/`asin`/`acos` use), gets scrubbed to black right where it
     would otherwise become permanent, rather than needing every individual cause hunted down first.
  - Verified: full app build + `PrismTests` build-for-testing both succeed (this project's policy —
    never `xcodebuild test`, see below). Re-ran the standing full-corpus `warp_N=`/`comp_N=` compile
    scan (`dev-notes/corpus-shader-scan-2026-07-27-round3/harness_main.swift` harness) after the
    shim-header change: **warp_N= 72.69% (5,760/7,924), comp_N= 79.54% (6,340/7,971)** — identical
    OK counts to the pre-change baseline (0 parse failures, 0 translateFail, same top-30 error
    signatures) — confirms `milkdrop_sanitize` is valid MSL everywhere it's inserted, with zero
    compile regressions across the full real corpus.
  - This doesn't replace the case-by-case investigations below (none of those presets' shaders were
    found to produce NaN — their causes, where identified, are distinct), but should stop the
    broader "many presets, unpredictably, over time" pattern the user reported.

- [ ] **"suksma - gss,sth - hogwoman style - species pay"** and **"carved in skin nz+"**: both
  `warp_N=` and `comp_N=` already compile successfully for both — **not a shader-compile bug**.
  Two candidate mechanisms investigated, neither confirmed: (1) "carved in skin nz+"'s `comp_N=`
  lerps toward HDR-range colors (`float3(3,2,1)`, literal `2`) that clamp to white on the 8-bit
  UNORM feedback texture if a region saturates — but real projectM's own feedback texture is also
  8-bit RGBA, so this isn't obviously a Prism-specific bug; (2) "hogwoman style"'s heavy
  multi-instance (`num_inst=33`) additive shapes with `rand()`-heavy per-frame scripts gated on a
  `q30` value the *main* per-frame script sets — Prism's multi-instance shape loop and `rand()`
  look structurally correct on inspection, but confirming whether per-frame-script execution order
  or `rand()`'s distribution matches real Milkdrop needs actual live rendering to verify (not done
  — GUI automation is unreliable in this environment, and the project's own testing policy avoids
  launching the real audio-capturing app via automation). Whoever picks this up needs a manual,
  eyeballed A/B: load each preset directly and watch it over time.
- [ ] **"suksma - my face is black pus"**: blocked on the general implicit-narrowing gap above
  (`neu = dist*neu + (1-dist)*lum(neu)*.5*(1+roam_cos);` — `roam_cos` is `float4`, `neu` is
  `float3`) — not a separate bug, just needs that fix.
- [ ] **"Krash and Zealot - Snowflake Halo (Ice Cube mix)"**: old-style (no `comp_N=`/`warp_N=`)
  preset whose `decay * gammaAdj ≈ 1.85` per-frame growth factor is a real, verified-against-
  upstream-source property (real Milkdrop's own `RenderFrame` feeds final-composited output back
  into the next frame's warp source the same way) — whether this preset saturates to white in
  *real* Milkdrop too (working as designed) or something else prevents it there is unresolved.
- [x] **"suksma - schlotkink"/"suksma - schlotkin"**: was a genuine compile failure — the preset
  declares `double3 ist = GetBlur1(uv*1);`, and MSL's `double` is a reserved-but-unimplemented
  keyword ("incomplete type" at compile). **Fixed**: `double`/`double2`-`double4` now alias to
  `float`/`float2`-`float4` in `renameIntrinsics`, matching real Cg/HLSL's own documented behavior
  on profiles without true double-precision support. (`comp_N=` already compiled; `warp_N=` still
  hits the general-narrowing/`%`-operator gaps above, unrelated to this fix.)
- [x] Goody's Trichromatic Mind games, 246, LuxXx - MoltenWheel I —Isosceles edit7 — fixed 7/26,
  see `PROJECT.md` (`.safe` math mode + pre-`shader_body` declaration hoisting).

---

## Open — other

- [x] Drag-and-drop `.milk` loading — **done 7/27, rewritten same day after "not working" report**:
  dropping a preset file anywhere on the window loads it, same as `⌘O`'s picker. First attempt used
  SwiftUI's `.onDrop` + `NSItemProvider` — user-reported "no visual reaction at all" (no cursor/
  highlight feedback), meaning nothing in the view hierarchy was actually registering as a drop
  target, not just a failed read after accepting. Rewritten on AppKit's own `NSDraggingDestination`
  directly on the MTKView (`PresetDroppableMTKView` in `MilkdropMetalView.swift`) —
  `registerForDraggedTypes([.fileURL])` + `draggingEntered`/`draggingUpdated`/`performDragOperation`,
  the same mechanism a plain AppKit app uses, reading the dropped URL off the dragging pasteboard
  (`NSPasteboard.readObjects(forClasses: [NSURL.self], ...)` — the traditional, sandbox-blessed path
  for a dropped file under App Sandbox, unlike `NSItemProvider` which is primarily an iOS/share-
  extension mechanism). Doesn't conflict with the existing tap-to-advance gesture
  (`MilkdropVisualizerView`'s `.onTapGesture`, applied to the same view): dragging callbacks only
  fire during a genuine external drag session, a separate AppKit dispatch path from mouse click
  handling. `handlePresetDrop` (`ContentView.swift`) now takes a plain, already-`.milk`-filtered
  `URL` and calls `loadPresetAndTrack` directly — AppKit's dragging callbacks run on the main thread
  already, so (unlike the `NSItemProvider` version) no `Task { @MainActor }` hop is needed. Verified
  via full `xcodebuild build` + `PrismTests build-for-testing` (zero warnings) and a brief direct
  launch-and-terminate of the built binary (confirms no startup crash) — the actual drag interaction
  itself still hasn't been verified live (no way to simulate an external Finder drag from this
  environment), so a real drag-a-file-onto-the-window check by hand is still the one thing left.
- [x] Fill out the app icon list in assets — **done 7/26**: `AppIcon.appiconset` only had the
  512x512@2x slot filled (`prismAppIcon.png`); every other mac idiom slot (16/32/128/256/512 at
  1x/2x) had no filename, so Xcode was synthesizing them by naive scaling instead of using real
  resampled assets. Generated all 9 missing sizes from the existing 1024x1024 source via `sips`
  and wired them into `Contents.json`. Verified via a full `xcodebuild build`: `actool` compiles
  a real `AppIcon.icns` with no warnings.
- [ ] Preset browser UI: folder-scanned and categorized (mirroring the desktop pack's
  Reaction/Fractal/Geometric/Supernova/Particles/Waveform/Dancer/Sparkle/Hypnotic/`! Transition`
  folder structure), replacing the current single-file `⌘O` picker as the only way to load a
  preset.
- [ ] Batch-load smoke test against the full 9,795-preset corpus: confirm nothing crashes/hangs
  parsing, get a real "% of corpus renders without silently falling back to plain warp/defaults"
  number.
- [ ] Live, extended-listening A/B pass on the "spazz factor" tuning (beat-punch magnitude,
  refractory interval) — verified correct in isolation (frame-rate independence, magnitude math)
  but never eyeballed against real audio for a full session. Adjust `MilkdropBeatState`'s constants
  further by ear if still not right. **Reduced again 7/27** (user: "way too jittery" even on presets
  not individually flagged) — `MilkdropBeatState.refractoryInterval` 0.16s -> 0.22s (~4.5 triggers/
  sec ceiling, still above a 260 BPM quarter-note rate) and `punchHalfLife` 0.12s -> 0.18s (slower,
  smoother swell per hit); `MilkdropMetalRenderer.renderToTexture`'s zoom/rotation punch formula cut
  again (baseline ~1.10x zoom/sec / ~2.1°/sec -> ~1.06x / ~1.4°/sec; full-punch ~2.0x / ~12.4°/sec ->
  ~1.52x / ~8.3°/sec — same direct-calculation verification method as the 7/26 reduction, see that
  code's own comment); waveform line-width's punch coefficient 1.4 -> 0.8. Still hasn't had the
  live-audio A/B pass this item asks for — tune further by ear from here. (Dev Note: the goal is to
  make the spazz/constant zoom speed lesser. The visualizer should still be responsive but much more
  relaxed. Maybe we can increase the intensity if the BPM is especially fast, but we can get to that
  later as a possible future to-do item — still true, not attempted this round.)
- [ ] `GetBlur1`/`GetBlur2`/`GetBlur3`'s missing dynamic-range rescale (`_c5.x`/`_c5.y` scale/bias
  from `blur1_min`/`blur1_max`/etc., real per-frame-scriptable variables Prism doesn't parse yet) —
  narrow (~10 files reference a blur sampler at all), scoped precisely in `PROJECT.md`.
- [ ] Proper Settings UI (still just keyboard shortcuts for everything).
- [ ] Custom-waveform and custom-shape per-instance GPU offload (same NS-EEL→MSL transpiler core
  as the per-pixel mesh's Tier 3, deferred behind proving that out first — see `PROJECT.md`).
- [x] Preset history (prev/next) + shuffle — **done 7/26**: `ContentView` now tracks a
  session-only `presetHistory`/`presetHistoryIndex` (browser-style, truncating any forward branch
  on a genuinely new load); Left/Right arrow keys step back/forward, Right falling back to a fresh
  random draw past the end of history (same as Space) since there's still no *saved* playlist
  concept.
- [x] `texsize_blur1`/`texsize_blur2`/`texsize_blur3` alias the generic `texsize` uniform instead
  of each blur level's real (smaller) dimensions — **fixed 7/26**: each level's real size is a
  deterministic function of the level above it (`updateBlurTextures`'s own `max(16, w/2)` halving),
  so `MilkdropMetalRenderer.blurTexsizeDefine` expresses it as a chained MSL macro rooted at the
  real `texsize` uniform rather than needing a new runtime uniform slot.
- [x] First-launch auto-prompt for the preset library folder (currently lazy — only prompts on
  first Space/tap/`L` use) — **fixed 7/26**: `ContentView.onAppear` now prompts immediately if no
  library is configured yet, rather than waiting for the user to stumble onto Space/`L`.

---

## Testing policy (added 7/25, after the CRLF parsing bug — see `PROJECT.md` for the full story)

- **Never run `xcodebuild test` directly** — it launches the real, audio-capturing Prism app and
  can hang unkillable. Use `xcodebuild build-for-testing` (compile-only) or a standalone `swiftc`
  harness instead.
- **Any feature that parses a new kind of preset input** must be tested against at least one real,
  byte-for-byte-copied `.milk` fixture under `PrismTests/Fixtures/` — not a synthetic string
  literal, even a "verbatim-transcribed" one (a Swift `"""` literal always normalizes line endings,
  which is exactly what hid the CRLF bug). See `RealPresetFixtureTests.swift` for the pattern.
- **Before marking a parsing/translation feature done, measure it against a real corpus sample** —
  not just "the unit test passes." Reference method: a standalone `swiftc`-compiled harness (the
  parser/translator files have no framework dependency) reading real files and reporting actual
  counts. Report the real numbers in the TODO item.
- **GUI automation (screenshotting the running app, simulating keystrokes) has proven unreliable**
  in this environment — don't rely on it for verification; prefer the harness-against-real-corpus
  method, and fall back to a manual, deliberate eyeballed check only when nothing else can confirm
  the specific thing in question (e.g. live-rendering runtime bugs, not compile-time ones).
- **Preset library decision**: Prism points at an external, user-chosen folder rather than bundling
  a preset pack (259MB, unclear redistribution rights). `PrismTests/Fixtures/` is the one
  exception — 2 real files (~30KB), used only for parser regression testing.
