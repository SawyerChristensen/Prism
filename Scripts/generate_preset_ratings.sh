#!/bin/bash
# Dev-time tool: exports the real app's MilkdropPresetRatings UserDefaults entry (Sawyer.Prism,
# the same bundle ID whether sandboxed or not — `defaults`/CFPreferences resolves the sandbox
# container transparently), cross-references the committed Resources/PresetVisualTraits.json to
# drop ratings for presets no longer in the current shipped corpus, and rewrites
# Resources/PresetRatings.json from what's left. Re-run by hand after a rating/flagging session
# (the "1"-"5" keybind in ContentView) — this is NOT an Xcode build phase, since it reads live
# UserDefaults state that only exists on the dev's own machine. Requires
# Resources/PresetVisualTraits.json to already exist (run generate_preset_visual_traits.sh first
# if the corpus itself changed).
#
# See generate_preset_ratings.swift.txt's doc comment for why the source lives as .swift.txt and
# gets copied to a scratch main.swift before compiling.
set -euo pipefail

BUNDLE_ID="Sawyer.Prism"
DEFAULTS_KEY="MilkdropPresetRatings"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PRISM_DIR="$REPO_DIR/Prism"

if ! defaults export "$BUNDLE_ID" - 2>/dev/null | plutil -extract "$DEFAULTS_KEY" raw -o - - >/dev/null 2>&1; then
    echo "error: no $DEFAULTS_KEY found in $BUNDLE_ID's UserDefaults — rate at least one preset in a running build first" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
cp "$SCRIPT_DIR/generate_preset_ratings.swift.txt" "$TMP_DIR/main.swift"

TMP_BIN="$TMP_DIR/generate_preset_ratings"
swiftc -O \
    "$PRISM_DIR/Milkdrop/MilkdropPresetRatingStore.swift" \
    "$PRISM_DIR/Milkdrop/MilkdropPresetVisualTraits.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_BIN"

defaults export "$BUNDLE_ID" - | plutil -extract "$DEFAULTS_KEY" raw -o - - | base64 -d \
    | PRISM_PROJECT_DIR="$PRISM_DIR" "$TMP_BIN"

rm -rf "$TMP_DIR"
