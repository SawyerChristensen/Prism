#!/bin/bash
# Builds fps_benchmark_main.mm standalone (same trick as dev-notes/projectm-corpus-scan-2026-07-27
# - bypasses Xcode/the sandboxed app entirely) and runs it over the full preset corpus, at the
# resolution given as $1 x $2 (defaults to this machine's own native display pixel resolution, via
# `system_profiler` - resolution matters a lot here: the dominant cost driver for some presets is
# real per-pixel fragment-shader work, which scales with pixel count, so benchmarking at a small
# resolution understates real fullscreen/Retina cost).
#
# Wrapped in a restart loop: fps_benchmark_main.mm flushes its output CSV after every single
# preset and skips relativePaths already present in it on startup, so if the run ever does die
# (Ctrl-C, a machine sleep/reboot, a crash) rerunning this script picks up right where it left off
# instead of starting over. Exits the loop once the tool itself reports it processed every
# preset in one pass (nothing left to skip).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PRESET_DIR="${PRISM_PRESET_PACK_DIR:-$HOME/Documents/PrismCollection/BestMilkdropPresetsPack/Presets}"
OUTPUT_CSV="${PRISM_FPS_BENCHMARK_OUTPUT:-$SCRIPT_DIR/results.csv}"
BIN="/tmp/prism-fps-benchmark"

if [ $# -ge 2 ]; then
    WIDTH="$1"
    HEIGHT="$2"
else
    # NSScreen backingScaleFactor is already baked into system_profiler's reported "Resolution" -
    # it's real device pixels, not points (verified: NSScreen.main.frame.width * backingScaleFactor
    # matches it exactly on this machine) - so no further scaling needed here.
    read -r WIDTH HEIGHT <<< "$(system_profiler SPDisplaysDataType 2>/dev/null \
        | grep -m1 "Resolution:" | sed -E 's/.*Resolution: ([0-9]+) x ([0-9]+).*/\1 \2/')"
    if [ -z "${WIDTH:-}" ] || [ -z "${HEIGHT:-}" ]; then
        echo "error: couldn't detect display resolution - pass width/height explicitly: $0 <width> <height>" >&2
        exit 1
    fi
fi

if [ ! -d "$PRESET_DIR" ]; then
    echo "error: preset pack not found at $PRESET_DIR - set PRISM_PRESET_PACK_DIR to override" >&2
    exit 1
fi

echo "Building fps_benchmark ($BIN)..."
clang++ -std=c++17 -fobjc-arc -O2 \
    -framework Metal -framework Foundation -framework IOSurface -framework CoreFoundation -framework AppKit \
    -I "$REPO_DIR/Vendor/angle/include" -I "$REPO_DIR/Vendor/projectm/src/api/include" -I "$REPO_DIR/Vendor/projectm-build/include" \
    -I "$REPO_DIR/Prism/ProjectM/Bridge" \
    -L "$REPO_DIR/Vendor/angle/lib" -L "$REPO_DIR/Vendor/projectm-build/lib" \
    -Wl,-rpath,"$REPO_DIR/Vendor/angle/lib" -Wl,-rpath,"$REPO_DIR/Vendor/projectm-build/lib" \
    -lEGL -lGLESv2 -lprojectM-4 \
    "$REPO_DIR/Prism/ProjectM/Bridge/ProjectMEGLContext.mm" "$REPO_DIR/Prism/ProjectM/Bridge/ProjectMEngine.mm" \
    "$SCRIPT_DIR/fps_benchmark_main.mm" \
    -o "$BIN"

echo "Benchmarking $PRESET_DIR at ${WIDTH}x${HEIGHT} -> $OUTPUT_CSV"

attempt=0
while true; do
    attempt=$((attempt + 1))
    before=$(wc -l < "$OUTPUT_CSV" 2>/dev/null || echo 0)

    set +e
    "$BIN" "$PRESET_DIR" "$OUTPUT_CSV" "$WIDTH" "$HEIGHT"
    status=$?
    set -e

    after=$(wc -l < "$OUTPUT_CSV" 2>/dev/null || echo 0)

    if [ "$status" -eq 0 ] && [ "$after" -eq "$before" ]; then
        # A clean exit that appended nothing new means everything was already done (skipped).
        echo "All presets already benchmarked. Done."
        break
    fi

    echo "run attempt $attempt exited with status $status (rows: $before -> $after) - restarting to resume..." >&2
    sleep 2
done
