#!/bin/sh
# Builds Prism/Vendor/projectm as a dylib and vendors the artifact into
# Prism/Vendor/projectm-build/lib. Re-run after bumping the projectm submodule
# (see Prism/Vendor/projectm-VERSION.md).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/projectm"
BUILD_DIR="${PROJECTM_BUILD_DIR:-$SCRIPT_DIR/.build}"
OUT_DIR="$SCRIPT_DIR/projectm-build/lib"
PATCH_MARKER_FILE="$SRC_DIR/src/libprojectM/Renderer/Platform/GladLoader.cpp"
PATCH_MARKER="PRISM_LOCAL_PATCH"

# Local patches (see Prism/Vendor/projectm-local-patches/) aren't part of the submodule's
# tracked commit, so `git submodule update` silently drops them. Re-apply idempotently.
for patch in "$SCRIPT_DIR"/projectm-local-patches/*.patch; do
    [ -e "$patch" ] || continue
    if ! grep -q "$PATCH_MARKER" "$PATCH_MARKER_FILE" 2>/dev/null; then
        echo "Applying local patch: $(basename "$patch")"
        git -C "$SRC_DIR" apply "$patch"
    fi
done

STAMP_FILE="$OUT_DIR/.built-commit"
CURRENT_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$CURRENT_COMMIT" ] && [ "$1" != "--force" ]; then
    echo "libprojectM already built for commit $CURRENT_COMMIT (pass --force to rebuild)"
    exit 0
fi

cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4 \
    -DBUILD_SHARED_LIBS=ON \
    -DENABLE_GLES=ON \
    -DENABLE_SDL_UI=OFF \
    -DENABLE_PLAYLIST=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_DOCS=OFF \
    -DENABLE_SYSTEM_PROJECTM_EVAL=OFF \
    -DENABLE_SYSTEM_GLM=OFF

make -C "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)" projectM

mkdir -p "$OUT_DIR"
cp -P "$BUILD_DIR"/src/libprojectM/libprojectM-4*.dylib "$OUT_DIR/"
install_name_tool -id "@rpath/libprojectM-4.4.dylib" "$OUT_DIR"/libprojectM-4.4.2.0.dylib
codesign -f -s - "$OUT_DIR"/libprojectM-4.4.2.0.dylib

# CMake-generated headers (generate_export_header + configure_file) aren't part of the source
# tree, so they must be vendored separately alongside the built dylib.
GEN_INCLUDE_DIR="$SCRIPT_DIR/projectm-build/include/projectM-4"
mkdir -p "$GEN_INCLUDE_DIR"
cp "$BUILD_DIR"/src/api/include/projectM-4/projectM_export.h \
   "$BUILD_DIR"/src/api/include/projectM-4/projectM_cxx_export.h \
   "$BUILD_DIR"/src/api/include/projectM-4/version.h \
   "$GEN_INCLUDE_DIR/"

echo "$CURRENT_COMMIT" > "$STAMP_FILE"
echo "Built libprojectM for commit $CURRENT_COMMIT -> $OUT_DIR"
