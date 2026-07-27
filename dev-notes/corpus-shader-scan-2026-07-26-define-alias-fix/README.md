# Follow-up corpus scan — 2026-07-26 (after the preamble `#define`-alias fix)

Re-measurement after fixing `MilkdropShaderTranslator.expandObjectMacros`: presets sometimes alias
a name via a plain object-like `#define ALIAS TARGET` before `shader_body` (real corpus patterns:
`#define MyGet GetPixel`, `#define sat saturate`, `#define sampler_pic sampler_prayerwheel`), which
was previously silently dropped by `preambleDeclarations` (a `#define` line has no trailing `;`,
the boundary that function splits on). See `scan_output.txt` for the full raw output; rerun the
same way as the original scan (copy this folder's `harness_main.swift` in as `main.swift` — it's
identical to the prior scans, unchanged).

## How this was found

The prior scan (`dev-notes/corpus-shader-scan-2026-07-26-followup/`) recorded 62.72%/68.03% as the
state after the uniforms/GetPixel/`%`-modulo fixes. Before trusting that number for a *different*
batch of already-committed-but-unmeasured fixes (helper-function hoisting, `vol`/`hue_shader`/
`mul()`-overload/blur-texsize shims — see the main commit history), this scan was re-run first, per
this project's own "measure, don't guess" policy. The result came back **byte-identical** to the
prior scan (same file counts, same top error signatures, right down to "46x `MyGet`" still present)
— a strong signal that whichever of those fixes was supposed to address the "46x `MyGet`" item
hadn't actually moved anything. Manually reproducing a real failing file
("Stahlregen & fiShbRaiN + Geiss + spookytay - Circuits in Flames (Jelly V3).milk") confirmed why:
the preset's `MyGet` isn't a preset-defined *function* (`extractHelperFunctions`'s territory) — it's
`#define MyGet GetPixel //GetBlur1`, a plain macro alias, a construct nothing in the file was
handling at all.

A quick corpus grep for `#define` lines specifically inside `warp_N=`/`comp_N=` (not just anywhere
in the preset) found ~213 files using this pattern, dominated by three shapes:
- `#define MyGet GetPixel` (~48x) — implicit-texture-function aliasing.
- `#define sat saturate` (69x) — intrinsic aliasing.
- `#define sampler_pic sampler_prayerwheel` / similar (~100x combined across several texture
  names) — custom-texture aliasing (silently resolving to the *wrong*, likely-missing texture
  before this fix, not just failing to compile).

## Result

Full 9,795-file corpus, **warp_N= 63.35% (5,020/7,924), comp_N= 68.06% (5,425/7,971)** — up from
62.72%/68.03% (warp_N= +0.63 points, comp_N= +0.03 points). `translateFail` (outright `translate()`
returning `nil`, as opposed to a real MTLDevice compile failure) dropped from 14/3 to 0/0. The
"undeclared identifier 'MyGet'" signature is gone from the top-30 list entirely.

The modest overall percentage move (despite ~213 affected files) is expected, not a sign the fix
is incomplete: most files using a preamble `#define` alias are *also* blocked by the still-open
"dominant remaining cause" (general implicit vector narrowing/widening — see `TO DO.md`), so fixing
the alias alone doesn't flip them to a full pass. A handful were unblocked outright; the rest will
show up once the narrowing fix lands.
