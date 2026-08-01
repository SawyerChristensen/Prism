# projectM engine corpus scan — 7/27 (post-rewrite verification)

Phase 7 of the `projectm-vendor-rewrite` branch: measuring the real vendored projectM 4.2.0 engine
(replacing the old hand-rolled Swift parser/evaluator/shader-translator, which only compiled
~73% of this same corpus — see the `corpus-shader-scan-*` entries above) against the full
9,795-file real-world preset corpus at `~/Desktop/BestMilkdropPresetsPack/Presets`.

## Result

```
pass=9728 fail=67 crash=0 timeout=0 total=9795
Pass rate: 99.32%
```

Zero crashes, zero timeouts, across the entire corpus. All 67 failures are the same class of
issue — real `projectm-eval` (the vendored flex/bison NS-EEL compiler) syntax errors on specific
legacy-authored presets:

| Failure reason | Count |
|---|---|
| `Could not compile per-frame code: syntax error` | 40 |
| `Could not compile per-pixel code: syntax error` | 10 |
| `Could not compile per-frame INIT code: syntax error` | 9 |
| `Could not compile custom shape 0 per-frame code: syntax error` | 7 |
| `Could not compile custom shape 1 per-frame code: syntax error` | 1 |

This is a real, known-shaped upstream projectM 4.x parsing limitation on a small tail of
older-syntax presets — not a Prism integration bug, and not something to patch locally (unlike
the GLES-version-gate patch in `Vendor/projectm-local-patches/`, which was a local
config/capability mismatch we control; this is the vendored compiler's actual grammar coverage).
See `failures.log` for the full file-by-file list.

## Method

`corpus_scan.py` drives `corpus_scan_probe_main.mm` (compiled standalone against
`Prism/ProjectM/Bridge/{ProjectMEngine,ProjectMEGLContext}.mm`, bypassing Xcode/the sandboxed
app entirely — see `Vendor/angle-gles-probe.mm` for the same pattern this was built from) as one
subprocess per preset: load, feed a few frames of synthetic PCM, render at 128x128, check for a
`presetLoadFailureHandler` callback firing or a `NULL` render result. One process per preset is
deliberate — it means a crash on one pathological preset can't take down the whole scan, unlike a
single long-lived process working through the corpus in a loop. 8-way parallel (subprocess.run
releases the GIL while waiting), ~15.7 presets/sec sustained, full corpus in ~10.4 minutes.

`scan_output.txt` is the full run's progress log (raw stdout).
