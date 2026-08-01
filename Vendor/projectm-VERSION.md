# Vendored projectM version

- Repo: https://github.com/projectM-visualizer/projectm.git
- Pinned commit: `2f244141320f6b97b09bf99964cc72a4efdfcfd3` ("Update libprojectM version to 4.2.0")
- CMake project version: 4.2.0
- Nested submodule `vendor/projectm-eval`: https://github.com/projectM-visualizer/projectm-eval.git @ `da885dcdf33620ef26aa04cac9e215378b80252e`

## Upgrading

```
cd Prism/Vendor/projectm
git fetch origin
git checkout <new-commit-or-tag>
git submodule update --init --recursive
cd ../../..
git add Prism/Vendor/projectm
```

Then re-run the CMake build in `Prism/Vendor/projectm-build/` (see build script) and update this file's pinned commit.

## Local patch: lowered GLES minimum version gate

The patch is checked in at `Prism/Vendor/projectm-local-patches/0001-lower-gles-min-version-3.0-for-angle-metal.patch`
and is **not** part of the submodule's tracked commit (a plain `git submodule update` would
silently drop it, since it only exists as an uncommitted working-tree diff inside the submodule).
`Prism/Vendor/build-projectm.sh` re-applies it automatically and idempotently (checks for the
`PRISM_LOCAL_PATCH` marker before applying) every time it runs, so this is self-healing across
submodule updates as long as the build script is always used to build - do not build the
submodule directly with a separate CMake invocation that bypasses the script.


`src/libprojectM/Renderer/Platform/GladLoader.cpp` (`CheckGLRequirements()`, `#ifdef USE_GLES` branch)
upstream requires GLES 3.2 / GLSL ES 3.20. Apple's ANGLE Metal backend (see
`Prism/Vendor/angle-VERSION.md`) currently only negotiates GLES 3.0 contexts on this hardware/OS
combination (verified via `Prism/Vendor/angle-gles-probe.mm`: `eglCreateContext` fails with
`EGL_BAD_CONFIG` for both 3.2 and 3.1, succeeds for 3.0). The gate was locally patched to require
3.0/3.00 instead, matching what ANGLE-Metal actually provides.

This was verified safe before patching: `grep`ing the whole `Renderer/`/`MilkdropPreset/`/`Audio/`
tree for `GL_COMPUTE_SHADER`, `GL_GEOMETRY_SHADER`, `GL_TESS_CONTROL`/`GL_TESS_EVALUATION`,
`glDispatchCompute`, and `GL_SHADER_STORAGE_BUFFER` found zero matches — nothing in the actual
renderer depends on ES 3.1/3.2-exclusive features. `angle-gles-probe.mm` (in this directory)
confirms `projectm_create_with_opengl_load_proc()` succeeds end-to-end against the patched gate.
The patch is marked `PRISM_LOCAL_PATCH` in the source for easy grepping and must be re-applied
after any `git submodule update --remote` bump (search for that marker after upgrading), unless a
future ANGLE build negotiates GLES 3.2 on Metal, at which point this patch should be dropped and
the gate reverted to upstream's `WithMinimumVersion(3, 2)` / `WithMinimumShaderLanguageVersion(3, 20)`.

## Local patch: app-controlled warp animation speed multiplier

The patch is checked in at
`Prism/Vendor/projectm-local-patches/0004-warp-anim-speed-multiplier.patch` (same not-part-of-the-
submodule's-tracked-commit caveat as above — re-applied by `Prism/Vendor/build-projectm.sh`).

Adds a new public C API pair, `projectm_set_warp_anim_speed_multiplier(instance, float)` /
`projectm_get_warp_anim_speed_multiplier(instance)`, mirroring the shape of the existing
`projectm_set_fps`/`projectm_get_fps`. It threads a new `ProjectM::m_warpAnimSpeedMultiplier`
member through `RenderContext::warpAnimSpeedMultiplier` (set once per frame in
`ProjectM::GetRenderContext`, next to where `ctx.fps` is set) down to
`PerPixelMesh::WarpedBlit`'s `warpTime` calculation
(`src/libprojectM/MilkdropPreset/PerPixelMesh.cpp`), where it multiplies on top of whatever
`fWarpAnimSpeed` the loaded preset itself specifies. Default 1.0 (no change from upstream
behavior).

Motivation: presets step their `per_frame`/`per_pixel` code once per rendered frame with no
built-in time-scaling (see `frame`/`fps` builtins in `PerFrameContext.cpp` — `frame` is a raw
per-call counter, and `fps` only helps presets that explicitly normalize against it), so output
frame rate directly changes how fast a preset's *content* animates, not just how smoothly it's
drawn. This multiplier only affects the engine's own built-in warp-noise animation
(`fWarpAnimSpeed`), not arbitrary preset `per_frame` code — see Prism's `projectm_set_fps` call
site (`ProjectMCoordinator.swift`) for the complementary fix that helps `fps`-normalized presets.
Exposed to the user via up/down arrow keys in `ContentView.swift`.
