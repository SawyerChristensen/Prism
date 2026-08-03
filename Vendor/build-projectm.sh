#!/bin/sh
# Builds Vendor/projectm as a dylib and vendors the artifact into
# Vendor/projectm-build/lib. Re-run after bumping the projectm submodule
# (see Vendor/projectm-VERSION.md).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/projectm"
BUILD_DIR="${PROJECTM_BUILD_DIR:-$SCRIPT_DIR/.build}"
OUT_DIR="$SCRIPT_DIR/projectm-build/lib"

# Local patches (see Prism/Vendor/projectm-local-patches/) aren't part of the submodule's
# tracked commit, so `git submodule update` silently drops them. Re-apply idempotently - checked
# per patch (via `git apply --check`, which fails once a patch's changes are already present) so
# that applying an earlier patch in the loop never causes a later one to be skipped. (An earlier
# version of this check only tested a single marker string in one file, which meant only the
# first not-yet-applied patch in the whole directory ever actually got applied per run - every
# patch after it in the loop saw the marker from that first one and was skipped outright.)
for patch in "$SCRIPT_DIR"/projectm-local-patches/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$SRC_DIR" apply --check "$patch" 2>/dev/null; then
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
rm -f "$OUT_DIR"/libprojectM-4*.dylib
# Xcode's embed-and-codesign copy step doesn't handle a two-level SONAME symlink chain
# (libprojectM-4.dylib -> libprojectM-4.4.dylib -> libprojectM-4.4.2.0.dylib) well, and that
# versioning scheme is pointless for a single vendored artifact anyway - just vendor one real file.
cp "$BUILD_DIR"/src/libprojectM/libprojectM-4.4.2.0.dylib "$OUT_DIR"/libprojectM-4.dylib
install_name_tool -id "@rpath/libprojectM-4.dylib" "$OUT_DIR"/libprojectM-4.dylib
codesign -f -s - "$OUT_DIR"/libprojectM-4.dylib

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
