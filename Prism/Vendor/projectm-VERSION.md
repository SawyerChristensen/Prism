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
