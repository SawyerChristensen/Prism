# Vendored ANGLE build

- Repo: https://chromium.googlesource.com/angle/angle.git
- Built commit: `ac96187bddd384ef81df82a262d3dc9168552cf9`
- Backend: Metal only (`angle_enable_metal=true`, `angle_enable_gl=false`, `angle_enable_vulkan=false`)
- Target: `arm64` macOS, `mmacos-version-min=13.0`, Release (non-component build)

Only the built `libEGL.dylib`/`libGLESv2.dylib` + public headers (`EGL/`, `GLES2/`, `GLES3/`, `KHR/`) are
vendored here — ANGLE's source is not checked into this repo (it's a huge Chromium-infra tree with its
own `depot_tools`/GN/Ninja toolchain, not CMake/Xcode-buildable). Rebuild from scratch with:

```
# One-time setup (outside this repo, e.g. ~/Documents/GitHub):
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"

mkdir angle-build && cd angle-build
fetch --nohooks angle
gclient runhooks

# Build:
buildtools/mac/gn gen out/Release --args='
is_debug=false
target_cpu="arm64"
target_os="mac"
angle_enable_metal=true
angle_enable_gl=false
angle_enable_vulkan=false
angle_enable_null=false
angle_enable_wgpu=false
angle_build_all=false
angle_enable_essl=true
angle_enable_glsl=true
angle_enable_hlsl=false
use_custom_libcxx=false
is_component_build=false
treat_warnings_as_errors=false
'
ninja -C out/Release libEGL libGLESv2
```

Note: `treat_warnings_as_errors=false` was required because the Chromium-toolchain clang downloaded by
`gclient runhooks` (an LLVM 23 pre-release snapshot) flags `-Wunsafe-buffer-usage` in
`src/common/FixedVector.h` more aggressively than this ANGLE revision's own
`unsafe_buffers_paths.txt` exclusion list accounts for. This is a warning only (confirmed harmless for
our purposes), not a vendored-source patch — no ANGLE source was modified.

## Re-vendoring after a rebuild

```
cp out/Release/libEGL.dylib out/Release/libGLESv2.dylib <Prism>/Prism/Vendor/angle/lib/
cd <Prism>/Prism/Vendor/angle/lib
install_name_tool -id "@rpath/libEGL.dylib" libEGL.dylib
install_name_tool -id "@rpath/libGLESv2.dylib" libGLESv2.dylib
codesign -f -s - libEGL.dylib libGLESv2.dylib
```

Update the built-commit hash above afterward.
