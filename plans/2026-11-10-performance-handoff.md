# Handoff: Skyrim VR performance (2026-11-10)

Status at handoff: Skyrim VR runs on the Mac dev host. It runs under strict AOT (`VXRT_AOT_STRICT=1`, zero fallback), with the D3D11→Metal renderer, xrizer and the dev synthetic stage. The frame rate is still far short of a Vision Pro target at the panel's resolution. This note covers what this session built and measured, and lists the performance ideas we haven't investigated yet. Read it with the [main plan](2026-11-08-skyrim-vr-native-darwin-aot.md), the [compatibility-fix ledger](2026-11-09-windows-metal-compat-fixes.md) and the [AVP Play backend plan](2026-11-09-avp-play-backend.md).

Subject of every number below: the actual game on the Mac dev host (M-series Mac, macOS 26.6), unless it says replay or fixture. None of it was measured on the headset.

## What this session built (all on `codex/standalone-import`)

- **D3D11 capture and replay** (`src/d3d11_capture.m`, `tools/d3d11_replay.m`, built as `build/vxrt-d3d11-replay`).
  - The capture records every D3D11 call from device creation. The Skyrim capture is private: `/tmp/claude/captures/skyrim/p1300.cap`, 16.9 GB, never committed.
  - Replay flags: `--from F`, `--fast[=k]`, `--frames a-b`, `--dump-rt`, `--list-draws`, `--env K=V`, `--compare-eyes`, `--dump-eyes`.
  - Replay reaches eye frame 3000 in about 20 s (13 s with `--fast`; k=200 is the lowest that still gives correct images). The live game takes about 190 s plus start-up to get there.
  - **This is the main tool for performance work.** It runs the renderer without the game's CPU side, so renderer changes can be timed in isolation and checked for identical images.
- **Compatibility fixes, tracked with cost and an off switch** in the [ledger](2026-11-09-windows-metal-compat-fixes.md):
  - Safe (IEEE) shader math is now the default; `VXRT_D3D11_FAST_MATH=1` turns it off. It removed the left-eye grey patch. Compile and replay time stayed within noise.
  - Unbound-resource binding (fix-bind) is merged.
  - fix-zero and fix-uav stay on branches only: they changed nothing visible in this scene.
  - Remaining gaps 6–18 come from the [Windows-vs-Metal audit](../research/2026-11-09-windows-metal-guarantees-audit.md) and are not actioned yet.
- **xWMA / WMA v2 audio decoder** (`src/wmadec/`, derived from FFmpeg n9.0.1, LGPL parts only). It costs about 0.12 s of CPU per 185 s track.
- **Dev keyboard controllers and mirror window** (`xrizer_dev_host.m`, `docs/dev-keyboard.md`).
  - Seeded prefs set the right hand as dominant, skip calibration and set `iSize` to 1024×1024.
- **One-command local play:** `tools/play_skyrim_dev.sh`. Options: `--seconds`, `--mute`, `--audio`, `--hud` (sets `MTL_HUD_ENABLED=1`, the Metal performance HUD), `--no-build`, `--key-script`. The mirror title shows live rates, and F1 or `?` shows the key help.
- **Test flake fixes:** `threads.exe` (an SMC write race in `translator/engine.c` `xe_smc_write`) and `fiber_pool`. Still flaky: `kernelx` line 135, `net_events` WSA 10035, and the clipboard test when runs are parallel.
- **Parked, not merged:** the D3D11 metallib shader cache, on branch `codex/d3d11-shader-cache-parked` (`a9da0bc`). On the Mac the OS Metal cache already makes warm compiles about 0.02–0.06 ms per shader, so it wasn't worth merging. It matters on the headset, though; see idea 7.

## What we measured

| Measurement | Value | Subject |
|---|---|---|
| Eye-pair rate, 1024×1024 per eye | about 50–88 fresh pairs/s depending on scene; the latest play run was about 88 | game, dev host, which paces at 90 Hz |
| Live probe 1600 (safe math) | 36–46 pairs/s | game; one run, no control run |
| DXBC→MSL translation | 0.1 ms per shader (600 shaders in 78 ms) | real Skyrim DXBC from the capture |
| `newLibraryWithSource`, cold | about 31 ms on average (PS 59 ms, VS 9.6 ms, CS 70 ms + 12 ms PSO); 600 shaders in 18.8 s | same |
| `newLibraryWithSource`, warm (OS cache) | 0.02–0.06 ms | same, fresh process |
| Safe math compared with fast math | within noise for compile time and replay time | replay |

We have **not** measured:

- whether the game is CPU-bound or GPU-bound;
- the split between game CPU, D3D11 layer CPU and GPU time;
- draw calls, render passes or render-target bandwidth per frame;
- anything at headset resolution or on headset hardware.

The dev host reports 1024×1024 per eye. The real headset will recommend a much larger size, so expect several times the pixel cost.

## Ideas to investigate (see the second session results below for what was tried)

Roughly in order: measure first, then the likely big wins.

1. **Find the bottleneck before optimising.**
   - Run `vxrt-d3d11-replay` over a fixed frame range (warm shader cache) under Instruments: Metal System Trace plus Time Profiler. This gives GPU time per frame and the D3D11 layer's CPU time, without the game.
   - Compare the replay's frame rate with the live game's for the same frames. If replay is much faster, the game CPU side (AOT code or runtime imports) is the limit. If not, it's the renderer or GPU.
   - Also check `--list-draws` for draws per frame.
2. **Tile-based GPU render passes.** Apple GPUs pay for every render-pass load and store to memory.
   - Count the render passes per frame in the replay, and see how the D3D11 layer picks load/store actions.
   - Look for passes split by `OMSetRenderTargets` or clears, and for depth/MSAA that could be `memoryless` or `DontCare`.
   - Look for clears done as separate passes instead of `loadAction = Clear`.
   - This is often the largest Metal-on-Apple-GPU win for a D3D11 port.
3. **Per-draw CPU cost in the D3D11 layer:**
   - state hashing and PSO lookup;
   - argument and constant-buffer upload (Map/DISCARD ring sizes);
   - redundant state rebinding;
   - command-encoder churn.

   The replay with Time Profiler shows these directly.
4. **Render less: foveation and upscaling.**
   - visionOS Compositor Services gives a rasterization rate map for foveated rendering. Applying it to Skyrim's eye passes would need the D3D11 layer to attach the map to the right passes, so we need to find which passes are the eye scene.
   - Alternatively, render the eyes below panel resolution and upscale with MetalFX (spatial, or temporal if motion vectors can be found).
   - Skyrim VR's own `fRenderResolutionScaleFactor` (SkyrimVR.ini) is the zero-code version for a first measurement.
5. **Stereo cost.**
   - Check in the replay whether Skyrim VR draws the scene twice (once per eye) or uses one side-by-side target.
   - If it draws twice, Metal vertex amplification or layered rendering would need translator support. That is a bigger change; measure the share of frame time first.
6. **Game settings as a baseline.** Shadow resolution and distance, grass, decals, TAA, and SSAO/godrays in the ini files, through the seeded prefs (`tools/prefs_seed/`). It's cheap to sweep with the harness. Alternate the runs (A B B A).
7. **No shader compile on the headset** (AVP Play plan milestone 2a). Cold compiles cost about 31 ms each, and 600+ shaders are seen in one session.
   - The headset would hitch badly with no warm OS cache.
   - **Done on the Mac (2026-11-10, branch `worktree-agent-a691a5a18fa249fbc`):** the parked cache (`a9da0bc`) is merged and redesigned. It now lives in `VXRuntime/src/shader_cache.m`, shared by D3D11 and D3D12. The key is a hash of the translated MSL plus language version (fixed at Metal 3.1 for D3D11) plus math mode, so fast-math (`VXRT_D3D11_FAST_MATH=1`) and safe-math libraries never alias. The game never runs the offline compiler: a hit loads `<key>.metallib`, a miss compiles in process and writes the source to `<cache>/pending/<key>.metal` plus `.flags`. `tools/shadercache_fill.sh [DIR [SDK]]` compiles pending in parallel (SDK `macosx` by default; `xros` for the headset set, not run). Default cache for Mac dev play: `build/private/shadercache` (set by `tools/vxrt_native_startup.py`; `VXRT_SHADER_CACHE` overrides, `0` is off). A Skyrim boot has about 10800 distinct shaders (18975 requests): about 150 MB of libraries, about 80 s to fill on this Mac. `rm -rf build/private/shadercache` clears it.
   - D3D11 now keeps one `MTLLibrary` per distinct source per process (`VXRT_D3D11_LIBRARY_REUSE=0` turns it off): 18975 requests became 10807 compiles or loads.
   - Still to do for the headset: build the `xros` set from a Mac boot's pending sources, ship it as the read-only cache, and measure on the simulator and device.
   - Possibly add `MTLBinaryArchive` for PSOs later.
   - This fixes hitches, not the steady frame rate.
8. **Copies on the present path.**
   - The game copies the left eye into its desktop back buffer, `dxgi.m` presents a mirror window, and xrizer copies eye textures into the OpenXR swapchain.
   - On the headset the mirror present can be dropped entirely, and the swapchain copy may be avoidable by sharing or aliasing textures.
   - Measure how much time these copies take first.
9. **CPU side.** If the game is CPU-bound, profile AOT hot blocks.
   - Look at runtime import hot spots: `Sleep(0)` spinning, sync primitives, `WaitForSingleObject`, and the heap.
   - Check how much the strict AOT code's flag and memory-ordering handling costs per frame (the earlier ordered-access work in the continuation plan is relevant).
   - A Rosetta run of the same scene would give a reference number. Label it a development reference.
10. **Headset-specific factors.** Thermals, the chip (M2 or M5 Vision Pro), and the compositor's frame pacing and reprojection behaviour on visionOS. These are unknown until a device run, which needs its own authorization.

## Second session results (2026-11-10)

Evidence is private, under `/tmp/claude/perf/` (`idea1/`, `idea2/`, `splits/`, `ab/`, each with a `STATUS.md`). All Mac M4 Pro.

**Idea 1, the bottleneck** (replay of `p1300.cap`, frames 2000-3000, unpaced):
- About 147 eye pairs/s, with GPU about 5.7 ms/pair and renderer CPU about 3.5 ms/pair (inferred by subtracting the capture read).
- The renderer is not the limit at 1024² on the Mac. At headset resolution on an M2, the GPU will be (inferred).
- Stereo is one 2048×1024 side-by-side target, so idea 5 needs no vertex amplification.

**Idea 2, tile traffic** (replay, frame 2401):
- The 2048×1024 eye passes are 88% of GPU time, and the main scene pass alone is 50%.
- Dropping all loads and stores (a bound only) would take 5.5 ms to about 4.5 ms.
- Realistic rules save less than 0.1 ms each: full-overwrite loads 8% of traffic, wasted stores 3.7%, no-remap merge 2.7%.
- No attachment qualifies for memoryless, because all of them have the SRV bind flag.
- A full merge with colour-slot remap (about 20% of traffic) is untested.
- **The replay is not deterministic:** two identical runs differ by up to 57 per channel. Not investigated.

**Unaligned ordered-access signals** (actual game, 180 s, one run):
- 623 k signals in a roughly 10 s load burst, then about 0.7/s.
- 40 new addresses: 24 in the exe and 16 in `binkw64`, which has no split profile.
- Candidate profiles are in `/tmp/claude/perf/splits/`. Not fed back yet.

**A/B runs** (`ab/STATUS.md`):

| Change | Result | Status |
|---|---|---|
| Call tracing off (`VXRT_TRACE_CALLS` was hard-coded to 3) | process CPU about 20% lower, pairs +2% (paced) | merged: play script default off, `--trace-calls N` |
| getenv cache (`trace_draw` re-read it per draw) | no measurable change in replay | merged as a bug fix |
| Clear-fold (`VXRT_D3D11_NO_CLEAR_FOLD`) | GPU busy about 10% lower, but replay wall time about 0.9 s per 600 frames slower (CPU) | not merged; branch `worktree-agent-a814e1bc84fd5f28d` (`f05ce8c`) |
| Render scale 0.7 / + MetalFX spatial (`VXRT_METALFX=spatial`) | no change on the title screen, which is not pixel-bound; MetalFX adds about 0.9 ms | not merged; branch `worktree-agent-a2cc909b5445acafd` (`0fe740a`) |

- All live A/B runs sat on "Press Any Button". A repeatable in-world scene, for example loading a save automatically, is needed before render scale, MetalFX or game CPU work can be judged.
- visionOS 26.1 SDK: only `MTLFXSpatialScaler` is available. The temporal scaler, the denoised scaler and the frame interpolator are `API_UNAVAILABLE(visionos)`.

The simulator start-up build is on branch `worktree-agent-ae7b8d9026697ef2b`; see `plans/2026-11-10-skyrim-simulator-build.md`.

## Open correctness items to keep in mind

- The wooden part of the horse cart's harness vibrates up and down. Candidates:
  - audit gap 6 (depth bias scaling);
  - gap 11 (`SV_Position.w`);
  - gap 13 (`sample_c` clamp);
  - CPU float or animation maths.

  The proposed diagnosis is a replay of a frame sequence. Not started.
- Before dropping any compatibility fix for speed, follow the ledger's "Before dropping a fix" checklist.

## Housekeeping

- Agents must run long checks with `run_in_background`, not `while pgrep -f` loops (those match themselves and never exit).
- Captures, game files, audio and images stay under `/tmp/claude` or `build/private/`, and are never committed.
- `build/worktrees/terra-skyrim-aot` (17 GB) holds the game AOT modules. Keep it.
- Leftover agent worktrees under `.claude/worktrees/` can be cleaned up once their branches are confirmed merged or parked.

## Non-blocking eye-pair submit (2026-11-10, branch worktree-agent-a922bbc4bf32125b1)

History: the `commit; waitUntilCompleted` in `xrizer_dev_host.m` / `xrizer_xros_host.m` came with the first bootstrap (`83a543a`) to publish only after the copy finished (frame_host.h: "publish only after all producer/copy writes completed"); stats and dumps (`c2c6055`) later read the buffer after that wait. It runs on the game's render thread inside xrEndFrame -> `publish_pair`, on the provider queue. Two more CPU waits sit upstream per eye: `d3d_flush_checked` (usleep poll for all D3D11 work) and `copy_complete`'s `waitUntilCompleted` (`xrizer_guest_d3d.m`), plus Klepton's `complete_writes` wait.

Now (default; `VXRT_XR_SYNC_SUBMIT=1` restores all of the old waits): the game's work signals an `MTLSharedEvent` (marker command buffer, `d3d_flush_signal`); the guest-to-provider copy waits for it on the GPU and signals a second value; the game device's next command buffers wait for that (`d3d_xr_guard_*`), so the next frame cannot overwrite what is still being copied; Klepton's ordered image sync does not wait on the CPU; the host's eye-pair copy (pooled textures, `xrizer_eye_ring.h`, at most 2 in flight, `VXRT_XR_SUBMIT_INFLIGHT` 1..4) is queue-ordered after those writes and publishes to native_vr from its completion handler only if every command buffer in the chain (write buffers, the game's producers, the copy) completed without error, in frame order, and the session/surface is unchanged. Stats, dumps and the mirror run in that handler. When the bound is hit the submit blocks and is counted (`blocked-at-bound` in the periodic `xr submit ring:` log line). Dropped (failed, stale or superseded) frames are never shown. Failure is now reported by log and counter, not as an error to the game's xrEndFrame.

Verified: owned CPU mock `VXRuntime/tests/xrizer_xros_async_publish_test.m` (two in flight, bound, out-of-order, cancel, failed buffer, pool reuse, retire with pending), `make -C VXRuntime check`, native-vr checks, Klepton `build-test.sh`; Mac dev host actual-game smoke, 100 s each, async and `VXRT_XR_SYNC_SUBMIT=1`: no error, early eye frames byte-identical between the two. Not verified: timing, the visionOS device/simulator run, other D3D11 writers than the draw/pre command buffers (uploads on the no-context path do not wait for the guard).
`VXRT_FLUSH_DRAWS` (mid-frame commits) already exists in `d3d11_draw.m`, off by default and unmeasured here; it is now allowed through `--diag-env` for A/B runs.
