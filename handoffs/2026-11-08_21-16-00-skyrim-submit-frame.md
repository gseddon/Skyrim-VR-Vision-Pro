# Skyrim submit frame handover

> Historical (2026-11-08): the Rust toolchain path named below moved to `build/toolchains/xrizer-rust` in this repository on 2026-11-10.


8 November 2026, 21:16 UTC. Continue from the integration checkout. Do not push. Do not start a game while a runtime is already running.

## Status

Probe 022 submits both eyes and the copies finish. The frame does not. `PostPresentHandoff` returns, the next `WaitGetPoses` returns 1, and the next `Submit` returns 108 (`AlreadySubmitted`). The dev host logs no fresh pair and no cancelled frame. The process then exits 5: main thread `0xc0000005` at `SkyrimVR.exe+0x27c743`, reading address 0. Exit summary 67,108,866 entries, zero fallback. A published stereo image, a scene, and playability are unproven.

## Read first

1. `AGENTS.md`
2. `plans/2026-11-08-skyrim-vr-native-darwin-aot.md` (status and the checkpoint paragraph)
3. `plans/2026-11-08-standalone-skyrim-terra-continuation.md` (execution log through probe 022)
4. This file

## Where the code is

Branch `codex/standalone-import` in `/Users/gseddon/git/Skyrim-VR-Vision-Pro`. Parent before this handoff's commit: `27fcc79`. Ahead of origin by the unpushed commits; do not push.

Game probes run from `build/worktrees/terra-skyrim-aot` at `b4a0d02`. That worktree's `tools/vxrt_native_startup.py` is clean. Its ledger is the historical one. Do not reset `build/worktrees/terra-guest-stereo`; it is dirty.

| Role | Path |
| --- | --- |
| Source of truth | this checkout |
| Game probe, ledger, private AOT | `build/worktrees/terra-skyrim-aot` |
| Pinned xrizer snapshot that probe 022's dylib was built from | `build/worktrees/terra-pose-input/third_party/klepton_openxr/build/xrizer-frontend-dkziw5/source` |
| Rust toolchain | `/Users/gseddon/git/VeRantyx/build/toolchains/xrizer-rust` (`CARGO_HOME` and `RUSTUP_HOME` underneath). Do not change it. |

The snapshot's `metal.rs` was restored after the dylib build and still has the old Gamma check. The fix lives in this checkout's `third_party/xrizer/upstream/src/graphics_backends/metal.rs`. That snapshot's `compositor.rs` differs from this checkout. Rebuilding the dylib from this checkout would pick up that difference. Probe 022's dylib is the snapshot plus only the Gamma/UNORM change.

## What probe 022 established

Skyrim submits one DirectX texture, color space Gamma (1), flags 0:

- handle is a live D3D11 texture
- 2422×1211, array 1, samples 1, DXGI 28 (`R8G8B8A8_UNORM`), Metal format 70
- left bounds `0, 0, 0.5, 1`; right bounds `0.5, 0, 1, 1`
- `xrizer_guest_d3d` acquire accepts it
- both eyes log `destination copy … GPU complete` and `Submit result 0`
- then `handoff` from `SkyrimVR.exe+0xdbbe37`
- then `wait_poses` returns 1
- the next logged submits return 108

The 102 from probes 020 and 021 was the Metal backend requiring an sRGB format (71 or 81) for Gamma. UNORM 70/80 is now accepted for Gamma and Auto. Texels are copied as stored. Linear stays UNORM-only. `copy_complete` accepts color spaces 0, 1, and 2.

Owned check: `cargo test` of `graphics_backends::metal::tests::resolves_and_copies_directx_with_failures` passed, 1 test. Host check `VXRuntime/tests/xrizer_projection_raw_host.c` passes for `GetProjectionRaw` (vtable and FnTable) and `CanRenderScene`. It is not a guest-thunk proof. Compile it with an empty thunk include so the ARM64 bridge does not pull generated thunks.

## Identities

- Prepared EXE `8daf05196ecad57963be61614ce4a4cd5c4dc27d222db14e01c262b36b3d46d4`
- Original EXE `6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971` (read-only)
- AOT dir `…/aot-mmx`. Bink module `1681bdabe14785f141f563d0ed8393db34a1e69ae65d386a80a76324f639e2ec`. Do not regenerate modules.
- Probe 022 runtime `VXRuntime/build/terra-imports/vxrt-arm64` SHA `0e592296cbbd41b920d2e4cd4270ce487d44b2669b88f63b1cf74d853cf2a7e6`
- Helper `libvxrt_vm.dylib` sits beside that binary (`@executable_path`)
- Probe 022 dylib `build/xrizer-gamma-unorm-dylib/aarch64-apple-darwin/debug/libxrizer.dylib` SHA `082c3906c8d1dfcbe06342cd736145f4cb0efb1c0fa2befabd684ea15fad979d`, version string `gamma-unorm-70`
- Previous dylib, which still returns 102: `…/xrizer-frontend-dkziw5/libxrizer.dylib` SHA `71aed917…`
- Logs: `build/worktrees/terra-skyrim-aot/build/xrizer-game-022/startup.log` SHA `06c12046…`. Probes 017–021 are the previous numbers in that directory.
- Asset root `/Users/gseddon/Verantyx_VR_Drive/vxrt_steam/steamapps/common/SkyrimVR`
- Appid 611670 is a label only

The game host links `build/worktrees/terra-skyrim-aot/build/xrizer-candidate-14/xrizer_guest_bridge.c`, not the source file directly. After editing `VXRuntime/src/xrizer_guest_bridge.c`, copy it onto that candidate-14 file before `make`. `xrizer_guest_d3d.m` is compiled from `src/`.

Idle check before a probe:

```sh
pgrep -x 'vxrt(-arm64)?(-[[:alnum:]_.]+)*|vrserver|vrcompositor'
pgrep -fl '[w]ine.*(vrserver|hlvr|SkyrimVR)'
```

Run the probe from the skyrim worktree with `python3 tools/vxrt_native_startup.py`, `--trace-null-target`, `--experimental-xrizer`, the absolute dylib above, `--seconds 40`. Do not pass `--trace-call-ring` unless sampling a hang. The ring changes Sleep/Wait timing and stalled the first indexed draw on probe 017. Probe 018 returned from that draw without the ring.

zsh `status` is read-only. `|| true` makes `$?` always 0. A killed process writes no exit summary. Missing AOT counters are unknown.

## Next step

Find why the completed pair does not finish the frame. `PostPresentHandoff` in the snapshot `compositor.rs` returns without advancing when `frame_state` is not `Begun`, and `end_frame` returns false while `image_acquired` is set or, on Apple, when the two views are missing valid orientation and position. Either path leaves the eyes submitted, which matches `AlreadySubmitted` on the next `Submit`. That is a hypothesis until a log or a probe shows which return fired. Do not claim a presented frame.

Still open and not this patch: probe 013's untraced access violation, Terra B's simulator frame/pose check, broad `check` / `check-arm64` failures, the empty SetupDi HID list, the refused COM class, the two 1D `sample(..., level())` shader failures (`7d305c67`, `96d61b6b`), and any physical headset. Physical install needs its own approval.

## Files in this commit

- `third_party/xrizer/upstream/src/graphics_backends/metal.rs` — Gamma/Auto accept UNORM 70/80
- `VXRuntime/src/xrizer_guest_d3d.m` — copy accepts color space 0–2; first four acquires are logged
- `VXRuntime/src/xrizer_guest_bridge.c` — `GetProjectionRaw`, `CanRenderScene`, first four submits logged
- `VXRuntime/tests/xrizer_projection_raw_host.c` — host-only slot check
- `VXRuntime/src/calltrace.c`, `tools/vxrt_native_startup.py` — ARM64 call ring and `--trace-call-ring`
- both plan files
