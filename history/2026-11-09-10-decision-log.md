# Decision log: Skyrim VR on Vision Pro, 9–10 November 2026

This is a record of the decisions Gareth made across two orchestrated sessions, kept for a write-up. It covers what was decided, why, and what came of it. Claude was the orchestrator in both sessions and handed the actual work to subagents, mostly Sonnet.

The technical detail lives in the plans:
- [the main plan](../plans/2026-11-08-skyrim-vr-native-darwin-aot.md)
- [the performance handoff](../plans/2026-11-10-performance-handoff.md)
- [the compatibility-fix ledger](../plans/2026-11-09-windows-metal-compat-fixes.md)
- [the Windows-vs-Metal audit](../research/2026-11-09-windows-metal-guarantees-audit.md)

Unless a line says otherwise, the measurements are from the actual game on the Mac dev host (M-series Mac), not the headset.

---

## Session 1: "Skyrim arena and exe rebase handover" (9 Nov 20:40 → 10 Nov 01:30)

The session started from a handoff. Skyrim VR ran under strict ahead-of-time translation (x86-64 → ARM64 modules, zero fallback) after an arena and exe rebase, but the 3D scene never showed in the eyes.

### How to work
- **Picked up the handoff and launched all three proposed agents.** Permissions blocked them at first, so Gareth turned on bypass permissions and then turned the sandbox off.
- **"I want updates more often."** He had waited 15 minutes to learn the agents weren't doing anything. From then on the orchestrator streamed agent status logs live.
- **"Remember you're the orchestrator. Stop running commands yourself."** Fixes went to Sonnet subagents, for example: "fix the flaky threads.exe in a Sonnet subagent please, don't do it yourself."
- **No long trail of leftovers.** Finished agents' work was merged into `codex/standalone-import`, worktrees removed and evidence kept. Disk space was watched, and the Rosetta agent's output was deleted to save space.
- **Asked whether monitoring agents should be Sonnet** rather than the bigger model, and about the cost of so many agents running at once.

### Concurrency
- **Each run's busy check should only detect its own game.** The harness refused to start if any `vxrt-arm64` was running, and some test fixtures run as `vxrt-arm64` too. Making the check instance-specific let GPU work overlap.

### xrizer, the OpenVR implementation
- **Started a parallel agent to finish the xrizer and frontend implementations,** then **merged the xrizer improvements:** "I like it."
- **Enable xrizer's normal Apple startup only if it's useful and won't slow the development loop.**
- **Asked for controller stubs or more xrizer input** as a parallel route to unblocking the game, which became input host work in later sessions.

### Debugging the missing scene
- Asked whether a Rosetta comparison would help, and whether it would be useful beyond this bug.
- **"Something is appearing!!!"** (23:17). Cause: new depth-stencil textures had undefined contents. Skyrim's fade pass is gated by a stencil test against a depth-stencil texture the game never clears, so it drew nothing. Windows hands out zeroed memory; Metal doesn't.
- **"Are there other assumptions like this we should be validating?"** That produced the Windows-vs-Metal guarantees audit.
- **Track every compatibility fix with its cost and an off switch,** "in case they make performance way worse and we can drop them". That's the ledger.
- **Keep the audit list saved, but don't action the remaining gaps yet.** He noticed the wooden part of the horse cart's harness vibrating and suspected "funky maths". It's still open.

### Audio
- **Wire in sound.** XAudio2 was rejecting xWMA. An xWMA/WMA v2 decoder was derived from FFmpeg, LGPL parts only, which he had authorised.
- **Asked for a decoded clip to listen to:** "ok the audio sounds great!"

### Playing it on the Mac
- **Keyboard dev controllers behind an env var,** mapped to in-game controller buttons. Keyboard first, real controllers on the Mac later.
- **Seed a settings file so the first-run VR setup isn't repeated.** He had noticed the intro detours through controller and settings screens when input is attached. The seeded prefs set right hand dominant, skip calibration and set a 1024² window.
- **Capture/replay tool:** run it with input off to avoid that detour, and add a fast-forward mode.
- **Shader cache:** first asked for one that the replayer could share too. Then: **"drop the shader cache (or just leave it on a branch), doesn't seem worth it."** On the Mac the OS Metal cache already made warm compiles cheap. This decision was revisited on 10 Nov.
- **Asked what the mirror window shows** (one eye, tall and narrow), and had it changed to the 1080p back-buffer shape. Asked what 16:9 would involve and whether it would actually add resolution or only stretch.
- **"Commit and push where we are now, this is a great place to be."** Then: can I just boot this up and play locally? That became `tools/play_skyrim_dev.sh`, with a live frame-rate title and a key-help panel.
- **The verdict at the end:** "this is nowhere near fast enough to run on a Vision Pro, especially at the native panel resolution." He asked for a performance handoff, which became [plans/2026-11-10-performance-handoff.md](../plans/2026-11-10-performance-handoff.md), and a push.

### Also decided in this session
- Use AVP Play (`~/git/avp-play`) as the eventual wrapper: Skyrim becomes a VXRuntime toolchain behind AVP Play's existing contract. A design session was started for it.
- Asked where a JIT comes into it. The accepted standalone path is strict AOT with no JIT.

---

## Session 2: "Performance handoff orchestration" (10 Nov, from about 02:00)

### Opening decisions
- **Work through the top ideas of the performance handoff with Sonnet subagents,** with Claude as orchestrator.
- **Measure first:** replay profiling (idea 1), then the render-pass anatomy (ideas 2 and 5), in sequence because both use the GPU.
- **Investigate a simulator build in parallel, and look at the Klepton question.** Klepton is the MIT-licensed open-source runtime whose OpenXR code we partly adapted.

### Disk space
- **"17 GB is insanely big, what takes all that space?"** The answer was old run logs and eye dumps (12 GB) and generated assembly (2.7 GB); one set of game modules is only about 0.37 GB. **Pruned both.** The AOT worktree went from 17 GB to 3.2 GB.
- Later, a full disk stopped the simulator build. The cause was 55 GB of eye dumps from an agent's image checks, which were deleted.

### Is our translated code slow?
- **"Could it be less efficient than Wine on the fly?"** He clarified he meant the generated code, not the generation. Wine doesn't translate x86; on Apple Silicon Rosetta does. The earlier measurements put our code at roughly Rosetta's speed, except where hardware memory ordering (TSO) matters, which an ordinary process, and visionOS, can't switch on.
- **Count the unaligned ordered-access signals in a real run.** Result: 623 k in a roughly 10 s load burst, then about 0.7 per second. That's negligible.

### Simulator
- **Simulator for start-up only; no BC texture decoder.** The simulator GPU has no BC texture support.
- **The build script's stale runtime pin is the agent's to fix.** Later the pipeline itself was changed: only `--probe` runs require the runtime to match its pin.
- **Wire up xrizer for the simulator, as long as it doesn't complicate testing on the Mac.**
- **Build the real DirectInput rather than an empty stand-in:** "can't you just build what we need for DirectInput that will eventually provide input?"
- **The real VR controller path goes to a separate agent.** That's PS VR2 Sense controllers → ARKit accessory tracking → xrizer's input host.
- **"Is it redoing anything that would be done by Klepton?"** Yes, partly. So the controller code was adapted from Klepton's `KleptonControllers.swift` (MIT, attributed): prediction cap, grip tuning, haptics engine.
- **Add haptics plumbing now** so a real controller only needs the hardware check.
- Outcome: Skyrim starts in the visionOS simulator through strict AOT and xrizer init, gets past DirectInput, and stops at the expected BC texture refusal.

### Audio effects
- **Queued XAudio2 reverb and effect chains, then parked them.** He asked for them to be written up as a general list of "API gaps seen in Skyrim's logs": audit §19.

### Rendering
- **Two separate agents: the cheap render-pass fixes, and render scale with MetalFX.** I merge them if they're definite improvements. **MetalFX goes behind a flag.**
- Result: neither was merged. Clear-folding cut GPU time but cost more CPU, and on the title screen (not pixel-bound) render scale and MetalFX showed no gain.
- visionOS has only MetalFX's spatial scaler; temporal upscaling and frame interpolation aren't available there.

### Getting into the world for measurements
- **Build an auto-scene harness option, in a subagent.** It took too long: two dead ends, and each try is a full game boot.
- **"Just make it stop. Our original xinput testing sequence got there fine."** A scripted gamepad pressing A gets to the Helgen cart. That became `play_skyrim_dev.sh --helgen`.
- Later: **skip the intro logo, and have `--helgen` press as early as possible.** Done with a per-run overlay `Skyrim.ini` (`sIntroSequence=` empty) and A from 6 s.

### "Why is a 15-year-old game this slow?"
- **Asked for an investigation of where the live frame time goes.** Findings, on an 18 ms frame (about 55 pairs/s) in the Helgen cart:
  1. **CPU and GPU take turns instead of overlapping.** That's three CPU waits for the GPU per eye pair, and one D3D11 command buffer per frame. It was introduced with the first xrizer bootstrap (8 Nov) as a correctness-first choice. **Decision: replace it with a non-blocking submit that keeps the frame-ownership guarantees.**
  2. **AOT module entry/exit writing FPCR/FPSR** on every crossing: about 2.3 ms a frame.
  3. D3D11 layer CPU: about 2.5–3.3 ms.
  4. A `getenv` on every draw: a broken cache, present since the import.
  5. xrizer built unoptimised by the play script.
- **Estimate the renderer CPU fixes before building them, and add them to the audit** (§20). Estimated savings: retain/release 0.28–0.40 ms, dirty-slot binding 0.10–0.25 ms, constant-buffer ring 0.12–0.25 ms, worker-thread encoding 0.4–0.8 ms. Argument buffers aren't worth it.
- **Asked about shader precompilation and adaptation.** Possible routes: half precision, fewer bounds guards, function constants, Apple's shader converter by way of DXIL.

### Merged as definite improvements
- **Call tracing off by default** in the play script: about 20% less process CPU.
- **The `getenv` fix.**
- **xrizer in release.**
- **Lazy FPCR/FPSR stubs, plus rebuilt modules.** Helgen cart: **60.9 → about 71 pairs/s (+16%).** A control arm suggests about half the gain is the FPCR change and half the rebuild. Across about 594 million module entries Skyrim's FP mode was always the default.
  - **"Do we really need A2?"** He was impatient, so he cut A/B arms and cancelled A2 mid-run.
- The play script now uses the new modules. `aot-splits4a` is kept only as evidence and a fallback until the new set has been played for real.

### Found along the way
- **"Lots of instances running at the same time."** Three orphaned game processes from abandoned runs were found and killed. The harness can leave the game running when interrupted.
- **"It seems to be locked to 60 Hz."** It was a regression in the new async submit: the mirror window's `nextDrawable` blocked the game thread. The mirror is now best-effort. Also found: xrizer reported the display frequency as about 0.011, because it returned the frame period instead of the rate.
- **Boot time:** about 60 s of cold Metal shader compiles before the first frame; warm boots take about 5 s. **Decision: merge the parked metallib shader cache after all.**

### Still open at the time of writing
- The non-blocking submit A/B, on the fixed branch.
- The metallib cache merge.
- Merging the visionOS branches: simulator start-up, DirectInput, controllers and haptics.
- Physical headset and controller testing, which needs separate authorisation.
- The vibrating harness.
- The replay's non-determinism.
