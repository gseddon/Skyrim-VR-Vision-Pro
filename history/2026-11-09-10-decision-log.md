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

---

## Session 2, afternoon (10 Nov): onto the headset

- **Merged:** the metallib shader cache (redesigned to queue sources in `pending/` and fill offline), the non-blocking eye-pair submit (Helgen cart about 59 → 85 pairs/s on the Mac), the visionOS branches, and the F2 keyboard passthrough. The developer console opened with real typing on the Mac.
- **Shaders:** Skyrim really has 10,807 distinct shaders; our translator adds no variants. The offline manifest gives byte-identical output to the runtime. **Gareth chose to check in the gzipped manifest** (hashes only), so a headset shader set needs no game boot.
- **"Allow it to continue onto the headset."** He approved device installs, then standing approval to deploy, screenshot and iterate. **"Is there some Klepton stuff we could be just using?"** That steered the work to reuse Klepton's visionOS host conventions piece by piece rather than inventing them.
- **The road to pixels on the Vision Pro, run by run:**
  - runs 1–2: the frame loop waited on ARKit, which was waiting on the motion permission prompt;
  - run 3: the app ran out of file descriptors loading 10,807 shaders;
  - run 4: the provider refused xrWaitFrame with a frame begun;
  - run 5: no STAGE space;
  - run 6: the flat window;
  - runs 7–8: the in-app capture proved Skyrim rendered correctly but nothing showed;
  - **run 9: reverse-Z depth.** The eye pass wrote depth 0 ("infinitely far"), so visionOS showed nothing. Klepton writes 0.05. **"Skyrim has just rendered in immersive now!!"**
- **After that:**
  - runs 10–11: shared frame readers fixed the flicker;
  - the head and controllers turned out to share an ARKit origin;
  - the headset is GPU-bound at about 17 fresh pairs/s with about 150 ms pair age, which is the lag on head turns;
  - run 13 added head-pose prediction and Klepton's Sense grip offset: "a bit better, still juddery".
- **Next, as he asked:** a display-rate, GPU-priority compositor; a clean loading bar instead of pink squares; foveated rendering; the controller offset, now to the left of the hand.

---

## Session 2, evening (10 Nov): performance and robustness on the headset

All measurements in this section are from the physical headset unless they say Mac.

### Compositor and feel
- **Compositor at display rate (100 Hz) on its own queue.** "ok the compositor is way better. Let's keep that." The judder went. A pair gate (release the game only when the last pair is in flight) cut motion-to-photon age from about 137 to about 77 ms.
- **Controllers:** aligned to ARKit's aim pose using coloured debug dots and screenshots he took in the headset (IMG 0037–0040). "ok I'm very happy with this. commit it and then turn all the dots off." Hand pass-through hidden by default, as a future Klepton setting.
- A loading bar replaced the pink squares.

### Resolution
- **Foveation stayed parked.** It lost on the Mac, and visionOS gives apps no gaze, only the system's rasterization-rate map. "This is a big shame, I was counting on that to fix our performance problems."
- **Pixel test on the headset** (screen kept unlocked with the proximity sensor covered; a remote `devicectl device reboot` cleared wedged file copies): GPU ms per pair scales about 1:1 with pixel count. The headset is pixel-bound; the Mac replay misleads.
- **0.55 render scale with MetalFX spatial upscaling:** "yeah the sharpness feels ok!"
- **Smart gate:** release the game early by the predicted GPU finish. Cart ride 35.2 pairs/s against 29.1 for the plain gate, at the same latency (25 at the old 0.7 scale). These three became the defaults on the integration branch.

### Frontend
- **Klepton frontend, option A+:** keep Klepton's settings names and env vars so it is familiar to Klepton users, and leave room for AVP Play to install the game. **Rejected forking Klepton,** because its runtime is tied to running Android APKs.
- **"Brand it Skyrim":** the app is now "Skyrim VR" with his downloaded icon, committed on his decision. English only. Preloading behind the start window deferred.

### "Skyrim vanishes"
- **He rejected a retry-only launch fix:** "I don't like your launch fix that involves just retries and not debugging the actual problem."
- **Root cause:** our own `exit(0)` when visionOS backgrounds the app on doff. Now the app pauses and resumes the layer. A follow-up regression (a dead Resume window over the resumed game) was fixed from the device log; the double window came from two persisted scene sessions.

### Saves
- On the Mac, saves were lost in per-run roots; a persistent saves dir fixed that. His downloaded save is a Skyrim SE save (no SkyrimVR.esm), and loading it crashes the game. Native VR saves work. Copying a working save to the headset is pending.

### Other
- **Hidden-area mesh:** the game uses it once xrizer gets XR_KHR_visibility_mask. On the Mac a large inset cut GPU time 32%; the headset calibration is next.
- **Mods plan:** VRIK, HIGGS, PLANCK, SKSE VR and SkyUI VR, added to the improvements list. OpenComposite isn't needed: xrizer already fills that role.
- **Settings research:** INI keys verified against the exe, with a device A/B plan.
- **Smoke "rectangles" on the main menu:** traced to the native present treating Skyrim's gamma-coded 8-bit eye textures as linear, so they are sRGB-encoded twice and the darkest 8-bit steps get about ten times brighter. He asked to also check the earlier audit items.
- **Three disk cleanups,** each deleting project leftovers (worktrees, old dumps).

---

## Session 3 (10–11 Nov): settings, portability and mods

The subject is the physical headset unless a line says Mac.

### Rendering
- **0.75 render scale, no foveation:** "it's looking much nicer at 0.75". **It became the default.**
- **System foveation:** this is visionOS's own rasterization-rate map, not gaze. He had the probe researched in full instead of building it. The verdict was not to build it yet ([research](../research/2026-11-11-system-foveation-scene-passes.md)).
- **GAP 6 and GAP 13 of the audit:** these were to be merged only if they cost little or nothing. They were measured, then: **"ditch these, mark as won't fix."** The code was deleted.
- **MetalFX sharpness:** VXRT_SHARPEN and VXRT_RENDER_QUALITY were added. He liked the default MetalFX, so the other probes were cancelled and the defaults stay. visionOS 26.1 has only the spatial scaler. Render quality needs foveation turned on, otherwise visionOS rejects the layer. That fix is on its own branch and not yet tested on the device.
- **ReShade:** researched and found incompatible with the Glamur preset. **"Ditch the ReShade reporter."**

### Controls and the frontend
- **The Crown button now quits the game.** It had once seemed to quit, but that was Siri ("Siri, exit").
- **Controllers that connect after launch:** the buttons work but the analog sticks don't. Keyboard binds were ruled out. He rejected added logging as bloat ("take it out"). **Still open.**
- **Launcher settings:** snap or smooth turning, teleport or walk, and 19 more INI settings. Each defaults to "Game default".

### Portability
- **Make the repo portable:** his team and device IDs were un-hardcoded. They now live in an uncommitted `local/env.sh` wrapper. The VeRantyx paths were removed, and scripts were added for Steamless, Rust, staging and a doctor. The setup scripts were test-run and ship auto-yes.
- **Removed all the exampleprefix stuff.**
- **Full AOT build from cold:** 448 s.
- **"Why does the shader set take 25 minutes?"** A false rebuild trigger. Fixed: a full shader rebuild takes about 5 minutes, all of it Metal compilation.
- **A free Apple account isn't enough today.** The increased-memory-limit and extended-virtual-addressing entitlements need a paid team.
- **Memory:** the app's limit is about 8.2 GB with increased-memory-limit.

### Mods: SKSE VR, HIGGS, PLANCK, VRIK, SkyUI VR
- **SKSE on strict AOT:** SKSE plugins are captured statically, then patched into the AOT modules ahead of time, with a verifier and a watcher. A late capture covers VRIK's 14 late patch sites (118 code runs in all). The capture depends on directory order, so file listings are now sorted as NTFS sorts them. The plugin set needs recapturing whenever it changes.
- **"Can't keep putting the headset on":** the start window was turned off for testing, and runs looped until the game loaded.
- **HIGGS "esp exists but not active":** the cause was CRLF. The game reads Plugins.txt in text mode, our C runtime didn't translate line endings, and every plugin name ended in `\r`. Text-mode reads now turn CR LF into LF, as Windows does. Seven other hypotheses were ruled out along the way. "done! It seemed to work?"
- **Why the headset's memory layout is higher:** extended virtual addressing puts our arena at 0x7000000000 on the device; on the Mac it is around 0x300000000.
- **SkyUI VR kept failing:** it embeds LuaJIT. Only at the device layout can LuaJIT find memory near its VM, so its JIT runs and traps under strict AOT. **"JIT isn't even allowed on Vision Pro anyway"**, so the fix is a `jit.off()` prelude in SkyUI's Lua through a mod overlay. A strict guard now refuses executable memory outside loaded images.
- **"Just merge in all the fixes into one branch together, SKSE, SkyUI, VRIK. Do a combined build and install it."** That's branch `final`, merged into `codex/standalone-import`. It holds SKSE VR, SkyrimVRTools, HIGGS, PLANCK, VRIK, SkyUI VR with LuaJIT off, and Skyland, at 0.75 with the MetalFX defaults. It was installed on 11 Nov, ready to launch from Home. SkyUI's menus have not been tried in the headset yet.
- **Nexus downloads without Premium:** this "just works" with no API key. The browser's free download goes to ~/Downloads, which is watched and matched by mod ID, then checked by md5. The user is prompted nicely, and an nxm handler is optional. **"Why does the downloads manager keep trying to access my keys? There's no API key."** The 1Password call was removed.

### Still open
- The analog sticks on controllers connected after launch.
- Render quality and system foveation on the device.
- SkyUI menus in the headset, and a playtest of the full mods build.
- `make check` on the final merge.
