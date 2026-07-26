# Full-corpus shader compile scan — 2026-07-26

Real, exhaustive measurement: every one of the 9,795 `.milk` files in
`~/Desktop/BestMilkdropPresetsPack/Presets` parsed via the real `MilkdropPresetFile`,
its `warp_N=`/`comp_N=` HLSL translated via the real `MilkdropShaderTranslator`, and
the resulting MSL compiled via a real `MTLDevice` — not a sample, not a "did
`translate()` return non-nil" check. See `scan_output.txt` for the full raw output;
see TO DO.md's top-of-file handoff note for the summary and prioritized next steps.

## How to rerun this

This harness is a standalone `swiftc` command-line tool (no Xcode project needed) —
`MilkdropPresetFile.swift`/`MilkdropShaderTranslator.swift`/`MilkdropMetalRenderer.swift`
and their dependencies have no AppKit/CoreAudio dependency that blocks this, per this
project's own standing testing policy (never run `xcodebuild test` — see memory).

```bash
mkdir -p /tmp/corpus_scan && cd /tmp/corpus_scan
cp /Users/sawyerchristensen/Documents/Prism/Prism/Milkdrop/*.swift .
cp /Users/sawyerchristensen/Documents/Prism/Prism/Milkdrop/Presets/*.swift .
cp /Users/sawyerchristensen/Documents/Prism/Prism/Audio/*.swift .
cp /Users/sawyerchristensen/Documents/Prism/Prism/App/PrismDebug.swift .
cp /Users/sawyerchristensen/Documents/Prism/dev-notes/corpus-shader-scan-2026-07-26/harness_main.swift ./main.swift
swiftc -O *.swift -o harness
./harness > output.txt 2>&1   # takes ~20 minutes over 9,795 files (real Metal compiles, not free)
```

Run it with `run_in_background: true` if using Claude Code's Bash tool — stdout is
fully buffered to a file until the process exits, so nothing appears until it's done;
poll via `ps -o pid,etime,%cpu,rss -p <pid>` to confirm it's still working (steady CPU,
growing RSS) rather than stalled, and set a background wakeup rather than blocking.
