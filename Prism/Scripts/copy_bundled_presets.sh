#!/bin/bash
# Run Script build phase: stages the .milk preset pack straight into the built app's
# Resources/Presets, skipping the pack's per-preset .jpg thumbnails (NestDrop preview images
# Prism never renders — see MilkdropPresetLibrary.swift). Keeps the pack out of git and out of
# Xcode's own file list (both would be painful at this file count) while still landing in every
# local build/archive, so an exported app has a working preset library out of the box.
#
# Defaults to the curated 60fps+ subset (dev-notes/preset-fps-benchmark-2026-08-04) of the full
# ~9,795-file BestMilkdropPresetsPack, not that full pack itself — every preset in it already
# measured performant on real hardware, so there's no need for MilkdropPresetComplexityAnalyzer's
# old static text-heuristic guard at preset-selection time (removed) or for a preset that stalls
# playback at a few fps to ever reach the screen at all.
set -euo pipefail

SRC="${PRISM_PRESET_PACK_DIR:-$HOME/Documents/PrismCollection/PerformantMilkdropPresetsPack/Presets}"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Presets"

if [ ! -d "$SRC" ]; then
    echo "warning: preset pack not found at $SRC — skipping preset bundling (app will ship with no built-in presets)"
    exit 0
fi

mkdir -p "$DEST"
rsync -a --delete \
    --exclude='*.jpg' --exclude='*.jpeg' --exclude='.DS_Store' \
    "$SRC/" "$DEST/"

count=$(find "$DEST" -name '*.milk' | wc -l | tr -d ' ')
size=$(du -sh "$DEST" | cut -f1)
echo "Bundled $count .milk presets ($size) into $DEST"
