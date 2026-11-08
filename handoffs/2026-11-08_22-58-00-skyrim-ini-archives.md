# Handoff: Skyrim `.ini` was never read (archives, null 3D crash)

Subject: actual Skyrim VR on the native arm64 host with the dev host (a synthetic offscreen Metal host: no headset, no display, no tracking). Not a playability claim.

## What changed
- Root cause of the `SkyrimVR.exe+0x27c743` null call: `GetPrivateProfileString*`/`Int*` returned defaults, so Skyrim used its built-in archive list and never opened `Meshes0/1` or `Textures*`; a placed reference had no 3D node and the game dereferenced it unchecked.
- `VXRuntime/src/client.c`: real read-only `.ini` support (A and W, String/Int/Section, enumerations). Stubs removed from `services.c`. `WritePrivateProfileString` is still a no-op.
- `VXRuntime/tests/ini.c` (`build/ini.exe`, in `make check`): passes on `terra-stage/vxrt-arm64` (non-strict).
- Diagnostics (opt-in, off by default): `VXRT_FAULT_OBJECTS=1` / `--fault-objects`; failed `GetFileAttributesEx` paths under `VXRT_TRACE_FILES`; dev host `--dump-eyes` (`VXRT_XRIZER_DEV_DUMP`); `--trace-all-opens`.

## Evidence (all under `build/worktrees/terra-skyrim-aot/build/`)
- `xrizer-game-041`: archives probed under default names (before the fix). `xrizer-game-039/040`: the crash object is a `TESObjectREFR`.
- `xrizer-game-043/044`: after the fix, all 19 archives open and no unhandled exception for 60 s; 044 published 1,858 pairs, zero fallback. Eyes: logo for about 150 frames, then transparent black.
- Host `22b189b1bdfe99c94552dfd847a97eff485c1bc3d3793154edded25647c211d2`; dylib `d09cc94c…` (`submit-diag-2`).

## Not verified
- Whether a scene or menu ever draws (the harness stops at 60 s; the process was still running). No headset, tracking, controllers or playability.
- Start-up flake (refused `CoCreateInstance` `{5A508685-…}` null call, strict-AOT miss at `+0x138afb8`) is unfixed; roughly one run in two dies early.
- `check`, `check-arm64`, `aot-suite`, `native-vr-*` not run after this change. One surviving run is a small sample for "the crash is gone".
- `WritePrivateProfileString` does not persist; the INI path is resolved relative to cwd (`.\Skyrim.INI`).

## Next
1. Find why frames after the logo are transparent: check whether the game is still loading (read the main thread and file activity near the 60 s end) or drawing nothing.
2. If a longer observation is needed, raise the harness's 60 s cap rather than bypassing it.
3. Attack the start-up flake with counts over a fixed number of runs.
4. Run the broad checks and record the baseline.
