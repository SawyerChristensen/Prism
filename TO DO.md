# Prism — To Do

For what each file/folder does and the full development history (why things were built the way
they were, with measurements), see `PROJECT.md`. This file is just the active task list.

**Standing method — measure, don't guess**: for anything preset-format-related, verify against the
real ~9,795-file corpus at `~/Desktop/BestMilkdropPresetsPack/Presets` via a standalone `swiftc`
harness (see "Testing policy" below), not a synthetic snippet or a single file. Re-run the relevant
measurement after a fix, don't assume it worked.

---

## Open — shader compile gaps (`MilkdropShaderTranslator.swift`/`MilkdropMetalRenderer.swift`)

Current state (2026-07-26): full 9,795-file corpus, **warp_N= 62.72% (4,970/7,924), comp_N=
68.03% (5,423/7,971)** compile through a real `MTLDevice`. See `PROJECT.md`'s development history
for everything already fixed to get here. Ordered by real full-corpus error-signature counts as of
the last scan (`dev-notes/corpus-shader-scan-2026-07-26-followup/README.md` explains how to rerun
it) — re-measure before trusting these counts, they'll drift as fixes land.

- [ ] **THE DOMINANT REMAINING CAUSE, several thousand instances**: general implicit vector
  narrowing/widening on *plain* assignments and other expressions — not texture-sample calls
  (already fixed). Real example: `mask = 1-.9*milkdrop_saturate(8*dist)*milkdrop_saturate(64*neu);`
  where `mask` is declared `float` but the RHS evaluates to `float3` ("propre hypno.milk"'s
  comp_). Needs real type-tracking: walk the shader body, infer each local's declared width from
  its first declaration, insert a narrowing swizzle wherever a wider expression is assigned into
  it — a lightweight symbol table, bigger than any fix so far (those were all call-site/text-
  substitution scoped). Real regression risk to the 62.72%/68.03% that already compiles —
  re-verify against the full corpus after, not just a sample.
- [ ] **"ambiguous call to `dot`/`length`/`pow`" (375x/152x/47x)**: almost certainly cascading
  symptoms of the narrowing item above (a wrongly-widened/narrowed argument makes overload
  resolution ambiguous), not independent bugs. Re-measure after that fix before spending time here.
- [ ] **46x `MyGet`, 45x `sw2`, 45x "expression is not assignable", 44x "called object type
  'float4' is not a function or function pointer", 62x undeclared `sunpos`, 41x undeclared
  `samples`, 30x undeclared `res`**: smaller, not yet investigated individually. Some may be
  genuine bugs in the *original preset*, not a translator gap — check a real failing example for
  each before assuming it's fixable.
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

Root cause confirmed and fixed for one preset family; two others investigated but still open —
see `PROJECT.md`'s development history for the full investigation writeup.

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
  further by ear if still not right. (Dev Note: the goal is to make the spazz/constant zoom speed lesser. The visualizer should still be responsive but much more relaxed. Right now it is incredibly fast, spazzy, and jittery. It should be more calming and relaxing overall. Maybe we can increase the intensity if the BPM is especially fast, but we can get to that later as a possible future to-do item)
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
