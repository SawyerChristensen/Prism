# Per-preset FPS benchmark — 8/4

Real measured render performance for every preset in the corpus, replacing guesswork
(`MilkdropPresetComplexityAnalyzer`'s static `.milk`-text heuristics) with actual numbers, so a
later feature can exclude presets below some FPS threshold from being shown/auto-cycled at all.

## Method

`fps_benchmark_main.mm` drives `ProjectMEngine` (`Prism/ProjectM/Bridge/{ProjectMEngine,
ProjectMEGLContext}.mm`) directly, standalone — same bypass-Xcode-entirely trick as
`dev-notes/projectm-corpus-scan-2026-07-27`. `ProjectMEngine.renderFrame(width:height:)` renders
into an offscreen IOSurface via an ANGLE/EGL pbuffer with no window, screen, or `NSApplication`
involved at all, so this runs fully headless in a plain command-line tool.

Unlike the corpus scan (fresh process per preset, 8-way parallel — fine for a pass/fail check),
this is one persistent process working through the corpus **serially**: parallel workers would
contend for the GPU and make every preset's measured FPS artificially low. The corpus scan already
showed real projectM 4.2 renders the whole corpus with zero crashes/timeouts, so per-process crash
isolation wasn't worth the tradeoff here. Resilience instead comes from flushing the output CSV
after every preset and skipping rows already present on startup — `run_preset_fps_benchmark.sh`
loops the binary and relies on that resume behavior if it ever dies mid-run.

For each preset: load it (`smoothTransition:NO`), render up to 8 warmup frames (bounded to 3s) to
absorb first-load shader-compile/transition-ramp-up cost, then render a measured window — at least
0.5s and up to 60 frames, capped at 2.5s wall time — while continuously feeding a synthetic stereo
signal (not silence: some presets branch per-frame on audio level, and silence would let those
skip work a real listening session never would). FPS = frames / elapsed over the measured window
only.

**Resolution matters a lot.** The dominant cost driver for some presets is real per-pixel
fragment-shader work (see `MilkdropPresetComplexityAnalyzer`'s own doc comment on
`isPixelShaderExpensive`), which scales with pixel count — an early 1280x720 run measured "amandio
c - embrace 07" at ~81fps; the same preset at this machine's native 3456x2234 display resolution
measured ~60fps, and other presets showed comparable resolution sensitivity. `run_preset_fps_benchmark.sh`
defaults to the machine's own native display resolution (`system_profiler`'s reported
`Resolution:`, which is already in device pixels) rather than an arbitrary fixed size, to match
real fullscreen/Retina usage. A preset whose cost is purely per-frame equation evaluation
(shapecode/wavecode `num_inst`/`samples` × line count, projectM's *other* cost driver) is
resolution-independent — "amandio c - the climbing..." measured ~2fps at both 1280x720 and native
resolution, matching `MilkdropPresetComplexityAnalyzer`'s own doc-comment figure almost exactly.

Absolute numbers are specific to whatever machine ran the benchmark — re-run locally if comparing
across machines matters; what's stable is the *relative* ranking, which is what a future
low-FPS-exclusion feature would actually key off.

## Running it

```
dev-notes/preset-fps-benchmark-2026-08-04/run_preset_fps_benchmark.sh
```

Builds the tool to `/tmp/prism-fps-benchmark` and writes `results.csv` (in this directory) unless
`PRISM_FPS_BENCHMARK_OUTPUT` is set. Reads the preset pack from `PRISM_PRESET_PACK_DIR` (same env
var `copy_bundled_presets.sh`/`generate_preset_visual_traits.sh` use), defaulting the same way.
Pass an explicit `<width> <height>` to override the auto-detected native resolution. Safe to
interrupt (Ctrl-C) and re-run — it resumes from whatever's already in `results.csv`.

9,795 presets; per-preset cost ranges from well under a second (fast presets, floored at the 0.5s
minimum measurement window) up to ~5.5s (warmup + measurement ceilings both maxed out on a
pathologically slow preset) — expect a multi-hour run for the full corpus.

## Output

`results.csv`: `relativePath,filename,status,fps,frames,elapsedSeconds,detail` — `relativePath` is
relative to the preset pack root (unique; used for resuming), `filename` is the bare basename
(joinable against `Resources/PresetVisualTraits.json`, which is keyed the same way).
`status=fail` rows (a preset that failed to load, e.g. a projectm-eval syntax error per the corpus
scan's own findings) have `fps=0` and a `detail` reason instead.
