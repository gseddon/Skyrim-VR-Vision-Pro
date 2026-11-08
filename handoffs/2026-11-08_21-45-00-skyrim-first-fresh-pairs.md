# Skyrim first fresh pairs handover

8 November 2026, 21:45 UTC. Continue from the integration checkout. Do not push. Do not start a game while a runtime is already running.

## Status

Probe 032 is the first run where Skyrim's own frames reach the dev host: 871 `xrizer dev host: offscreen fresh pair frame N pose N (1211x1211, 1211x1211), no display` lines in about 24 seconds, three AOT summaries (83.9M entries) with zero fallback, harness `validate` passes. The process still exits 5: main thread `0xc0000005` at `SkyrimVR.exe+0x27c743`, reading address 0, about 28 seconds after launch. Pixel content of the pairs was not read back. A scene, a display, tracking and playability are unproven.

## What was found

Probe 022's stuck frame: Skyrim uses the Standing origin (xrizer maps it to the STAGE reference space) and never calls `SetExplicitTimingMode`, so xrizer runs Implicit. The provider's `klxr_LocateViews` returns zero flags for STAGE while `KlNativeFrameSample.stage_valid` is 0, and the dev host never set it. `end_frame` then returned false, the frame stayed Begun, `xrWaitFrame` returned `ERROR_CALL_ORDER_INVALID`, `WaitGetPoses` returned 1 and the next `Submit` returned 108. Each step is now logged by a `warn!`.

The dev host now has an opt-in `VXRT_XRIZER_DEV_STAGE=1` (harness flag `--dev-synthetic-stage`): the synthetic local origin is declared the floor. It is off by default; the owned `xrizer_openvr_exports_joined_check.py` still passes every check with it off (107 entries, 0 fallback, includes `standing_cancel`).

Left as is, deliberately: on invalid views the Apple branch of xrizer's `end_frame` still returns false and leaves the frame Begun. It recovers when tracking returns, but a physical headset that loses tracking will hit the same 108 chain until then. Ending the frame with zero layers (as non-Apple does) would be the alternative; that is a design call, not made here.

## Identities

- Host `VXRuntime/build/terra-stage/vxrt-arm64` SHA `4ad351d1f6c591e78b7c0feed1a144ad4100cbd6a48e99eaf7f65fda5c7ca676`, helper `libvxrt_vm.dylib` `1a0555fa…` beside it. Built from this checkout's `src/` (not the candidate-14 bridge copy) with the provider objects `core.o`, `pose.o`, `metal.o` built from `third_party/klepton_openxr/src` in `VXRuntime/build/terra-stage/`. The make command is the one in `build_candidate.py` under `build/worktrees/terra-skyrim-aot/build/xrizer-candidate-14/`, with `VXRT_ARM64_TARGET=build/terra-stage/vxrt-arm64` and `VXRT_ARM64_THUNKS_ROOT=build/terra-stage`.
- Dylib `build/xrizer-submit-diag-dylib/aarch64-apple-darwin/debug/libxrizer.dylib` SHA `d09cc94cee474e0a317556c7299d298a882cf35f96d216aaf4b5978578e6e6c4`, `XRIZER_VERSION=submit-diag-2`. Built from this checkout (not the pinned snapshot) with `cargo build --lib --no-default-features --features owned-apple-test --target aarch64-apple-darwin --locked --offline`. Without `--features owned-apple-test` the dylib fails init with `AppleBackendUnavailable` (probe 023). The checkout's `compositor.rs` also differs from the snapshot: Apple no-render gating in `begin_frame` and `submit_impl`.
- Probe 032 log `build/worktrees/terra-skyrim-aot/build/xrizer-game-032/startup.log` SHA `e385b42d…`. Probe 031 has a log only. Prepared EXE, original EXE and `aot-mmx` modules are unchanged from the previous handoff.
- The harness flags `--dev-synthetic-stage` and `--trace-files` live in this checkout's `tools/vxrt_native_startup.py`. The skyrim worktree's copy is still at `b4a0d02`; copy this file over it for a run, then `git checkout` it afterwards. Do not restore it until the harness has exited (probe 031's harness died with its shell and wrote no `result.json`; run the harness in the foreground).

## Next steps

1. Read the pixels. The dev host publishes pairs but nothing has looked at them. Dump one published pair (a PNG per eye, or a checksum compared with a blank) before saying the game rendered anything. The texture is one 2422×1211 `R8G8B8A8_UNORM` image split at u=0.5.
2. `SkyrimVR.exe+0x27c743`: `+0x27c730` calls `[[rdx]+0x380](rdx)` and dereferences the result (null). It happens at 28–30 s with and without frames, about 270–290 ms after a main-thread `FindFirstFileA` from `+0x14137de31` fails with error 2 (the worker made the same call 12 s earlier; its argument is `Saves/`). The relation is a guess. Candidates: what the FindFirstFile result feeds, or a 28–30 s load stage. A bounded check: does the runtime treat a `/` in a FindFirstFileA spec like `\`? `find_first` in `VXRuntime/src/files.c` splits only on `\`.
3. Start-up flake: probes 024, 028, 029 died in the first 20 ms to 2 s (null call after the refused `CoCreateInstance` class `{5A508685-A254-4FBA-9B82-9A24B00306AF}`, or a strict-AOT miss at `+0x138afb8` while loading `d3dx9_42`). Surviving runs also log `the image arena at 0xf00000000 is taken`. Do more paired runs (old vs new dylib) before blaming the dylib.
4. Still open and not this change: probe 013's untraced fault, Terra B's simulator frame/pose check, broad `check` / `check-arm64` failures, the empty SetupDi HID list, the two 1D `sample(..., level())` shader failures (`7d305c67`, `96d61b6b`), regenerating `third_party/xrizer/apple-port.patch` (stale, noted in `SOURCE.md`), and any physical headset. Physical install needs its own approval.

## Files in this commit

- `VXRuntime/src/xrizer_dev_host.m` — opt-in synthetic stage
- `third_party/xrizer/upstream/src/compositor.rs` — warnings on silent frame-failure returns
- `tools/vxrt_native_startup.py` — `--dev-synthetic-stage`, `--trace-files`
- `third_party/xrizer/SOURCE.md`, both plan files, this handoff
