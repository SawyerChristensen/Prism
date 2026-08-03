#!/bin/bash
# Dev-time tool: compiles and runs generate_preset_visual_traits.swift, which walks the preset
# pack (PRISM_PRESET_PACK_DIR, same env var copy_bundled_presets.sh uses, defaulting the same way)
# and rewrites Resources/PresetVisualTraits.json from scratch. Re-run by hand whenever the preset
# pack changes — unlike copy_bundled_presets.sh, this is NOT an Xcode build phase (parsing every
# preset's per-frame equations is real work; a build-time hook would slow down every single build
# for a corpus that changes rarely, if ever).
#
# Lives at the repo's top level (sibling to Prism/), not inside Prism/Scripts/ alongside
# copy_bundled_presets.sh: Prism.xcodeproj uses a file-system-synchronized group for the whole
# Prism/ folder, which dynamically sweeps in *everything* under it at build time, not just at
# file-creation time — this tool's .swift.txt companion first broke the real app build in Xcode
# ("Unexpected input file") from inside Prism/Scripts/ even with the non-.swift extension, because
# the synced group re-evaluates on every build, not just once. Being a physical sibling of Prism/
# instead is what actually keeps it out, not the file extension trick alone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PRISM_DIR="$REPO_DIR/Prism"

# The source lives as .swift.txt (not .swift) so Xcode's file-system-synchronized group for
# Prism/ doesn't sweep this script's top-level statements into the real app target's compiled
# sources — see generate_preset_visual_traits.swift.txt's own doc comment. Copying it to a real
# .swift file in a scratch dir before invoking swiftc keeps that true while still letting swiftc
# recognize it as a source file. Named exactly main.swift (not generate_preset_visual_traits.swift)
# because that's swiftc's actual rule for where top-level statements are allowed once more than one
# file is being compiled together — any other name/count combination errors with "statements are
# not allowed at the top level" even though the exact same file compiles fine alone.
TMP_DIR="$(mktemp -d)"
cp "$SCRIPT_DIR/generate_preset_visual_traits.swift.txt" "$TMP_DIR/main.swift"

TMP_BIN="$TMP_DIR/generate_preset_visual_traits"
swiftc -O \
    "$PRISM_DIR/Milkdrop/MilkdropPresetVisualTraits.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_BIN"
PRISM_PROJECT_DIR="$PRISM_DIR" "$TMP_BIN"
rm -rf "$TMP_DIR"
