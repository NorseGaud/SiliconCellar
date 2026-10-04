# BRINK

Recipe: [brink.json](../brink.json)

## OpenGL version check

**Symptom.** The game stops and asks for OpenGL 3.1. The Mac driver reports OpenGL 2.1.

**Change.** Play patches `brink.exe` so the version test accepts 2.0.

**Reuse.** Use this when a game rejects the Mac OpenGL 2.1 driver on a version number alone.

## Missing extension name

**Symptom.** The game requires `GL_EXT_texture3D`. The driver has `glTexImage3D` and omits that name from the extension string.

**Change.** Play skips that name check in `brink.exe`.

**Reuse.** Use this when the driver implements the entry point and the game only checks the extension string.

## Texture format record

**Symptom.** The game stops after it creates a texture. The driver stores a sized format. The game stored an unsized name or `DEPTH_COMPONENT24`.

**Change.** Play copies the driver format into the texture record. `DEPTH_COMPONENT24` becomes `DEPTH_COMPONENT32`. Unsized `RGB` and `RGBA` become `RGB8` and `RGBA8`.

**Reuse.** Use this when a game compares the format it requested with the format the driver reports.

## Per-buffer color mask

**Symptom.** The game calls `glColorMaski`. That entry point is absent, and the process stops.

**Change.** Play sends buffer 0 through `glColorMask`.

**Reuse.** Use this when a game calls a per-buffer OpenGL entry point that the 2.1 driver does not export.

## GLSL 1.30 shaders

**Symptom.** The picture is black, or the meshes draw with no texture. The driver compiles GLSL 1.20 only. The game writes GLSL 1.30.

**Change.** Play copies `brinkglsl.dll` from `scripts/brink-glsl.c` into the game folder. `brink.exe` loads it in place of `glShaderSourceARB`. The DLL rewrites `#version 130` to GLSL 1.20 with `GL_EXT_gpu_shader4` and `GL_ARB_shader_texture_lod`. `out vec4 name[N]` maps onto `gl_FragData`, so `name[i]` is draw buffer i. `highp`, `mediump`, and `lowp` are removed. `textureLodOffset` is rewritten for a 2D sampler.

**Reuse.** Use this when a game compiles GLSL 1.30 on the Mac OpenGL 2.1 context. Read a failed shader from the game's shader dump before you change the translator.

## Full screen and frame rate

**Symptom.** The Mac menu bar stays visible, or the frame rate is too low.

**Change.** `base/autoexec.cfg` sets the window to the full display frame, so the window covers the menu bar. `r_screenFraction` is 50, so the 3D view draws at half of that size and is stretched. Occlusion queries stay off, because this driver stalls on them.

**Reuse.** Use the full display frame when a window one point short of the screen leaves the menu bar visible. Use `r_screenFraction` when a game fills the whole frame and the frame rate is too low. Turn occlusion queries off when the frame time is a stall, not a fill-rate limit.
