#!/bin/bash
# Run Script build phase: stages the .milk preset pack straight into the built app's
# Resources/Presets, skipping the pack's per-preset .jpg thumbnails (NestDrop preview images
# Prism never renders — see MilkdropPresetLibrary.swift) and its "! Transition" folder (NestDrop's
# convention for presets meant only for brief manual triggering as a VJ transition effect, never
# for full-song display — MilkdropPresetLibrary.rescan() already filters these out of any library
# at runtime too, this just keeps them from being staged into the bundle at all). Keeps the pack
# out of git and out of Xcode's own file list (both would be painful at this file count) while
# still landing in every local build/archive, so an exported app has a working preset library out
# of the box.
#
# Defaults to the curated 60fps+ subset (dev-notes/preset-fps-benchmark-2026-08-04) of the full
# ~9,795-file BestMilkdropPresetsPack, not that full pack itself — every preset in it already
# measured performant on real hardware, so there's no need for MilkdropPresetComplexityAnalyzer's
# old static text-heuristic guard at preset-selection time (removed) or for a preset that stalls
# playback at a few fps to ever reach the screen at all.
#
# Pulls from ProductionMilkdropCorpus, not PerformantMilkdropPresetsPack directly — the former is
# a renamed copy of the latter with community preset filenames standardized to
# "Author - Subcategory MainCategory[ N]" (author omitted where none could be identified) so the
# UI never surfaces the raw NestDrop filenames, some of which carried profanity/offensive text.
# ProductionMilkdropCorpus never had a "! Transition" folder copied into it, so no exclude needed here.
#
# Also stages the shared Textures/ folder (~4.2MB of .jpg images) that a subset of presets across
# every category reference by name (e.g. warp_N=`... tex2D(sampler_heart, uv) needs heart.jpg).
# ProductionMilkdropCorpus/PerformantMilkdropPresetsPack never carried this folder over from their
# common source, BestMilkdropPresetsPack — it's pulled from there directly. Without it,
# ProjectMEngine's texture search path (see -[ProjectMEngine init]) has nothing to find, and
# projectM's TextureManager silently falls back to a placeholder texture for every preset that
# needs one (Vendor/projectm/.../TextureManager.cpp's TryLoadingTexture). Copied *without* the
# presets' blanket *.jpg exclude above — these are real render inputs, not NestDrop thumbnails.
set -euo pipefail

SRC="${PRISM_PRESET_PACK_DIR:-$HOME/Documents/PrismCollection/ProductionMilkdropCorpus}"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Presets"
TEXTURE_SRC="${PRISM_TEXTURE_PACK_DIR:-$HOME/Documents/PrismCollection/BestMilkdropPresetsPack/Textures}"
TEXTURE_DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Textures"

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

if [ ! -d "$TEXTURE_SRC" ]; then
    echo "warning: texture pack not found at $TEXTURE_SRC — skipping texture bundling (presets needing a named texture will render with projectM's placeholder)"
    exit 0
fi

mkdir -p "$TEXTURE_DEST"
rsync -a --delete \
    --exclude='.DS_Store' \
    "$TEXTURE_SRC/" "$TEXTURE_DEST/"

texture_count=$(find "$TEXTURE_DEST" -type f | wc -l | tr -d ' ')
texture_size=$(du -sh "$TEXTURE_DEST" | cut -f1)
echo "Bundled $texture_count textures ($texture_size) into $TEXTURE_DEST"
