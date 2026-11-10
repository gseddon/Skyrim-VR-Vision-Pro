# Plan: the Skyrim VR mod stack (data mods, SKSE VR, SkyUI VR, VRIK, HIGGS, PLANCK)

Date: 10 November 2026. Status: not started; design only. Evidence, sources and file:line citations are in [the research report](../research/2026-11-10-skyrim-vr-mods.md). Parent plan: [native Darwin AOT](2026-11-08-skyrim-vr-native-darwin-aot.md). Read it and `AGENTS.md` first.

**Update 2026-11-11:** the user's actual mod set (Skyland, SkyUI, HIGGS 1.10.10, PLANCK 0.8.2), the findings from their downloads, the Mac proof of the data layer and the configurability/mod-manager design are in [plans/2026-11-11-skyrim-mods-combined.md](2026-11-11-skyrim-mods-combined.md) and research sections 8 and 9; this plan's SKSE design and decisions D1 to D4 stay in force.

## Goal

A user who owns Skyrim VR can run the community's modern interaction stack on the standalone Vision Pro app: their data mods, SKSE VR with its foundations, SkyUI VR, then VRIK (body), HIGGS (hands, grabbing, two-handed weapons) and PLANCK (physics reactions, melee collisions). The headset session needs no Mac, no streaming and no SteamVR. A Mac may prepare everything beforehand.

## Scope

In: loose files, ESP/ESL/ESM, BSA, `plugins.txt`; SKSE VR 2.0.12 for game 1.4.15; VR Address Library; PapyrusUtil and the other common dependencies found by measurement; SkyUI VR; VRIK, HIGGS, PLANCK; the prepare-time pipeline that patches and translates them.

Out for now: ENB, ReShade, Community Shaders and other renderer mods (their GPU cost is not affordable on the headset today, and they need the same plugin work first); Nemesis, xEdit, DynDOLOD, BodySlide and MO2 (they stay on the Mac or PC and only produce data); hand tracking as an input for these plugins; any other game.

Rules that stay: no JIT or runtime code generation on the accepted path (`AGENTS.md`); mod and plugin files are the user's own downloads, kept in git-ignored private directories, never committed or redistributed; the original Steam install stays read-only and all writes go to overlays; GPL source (HIGGS, PLANCK) may be read, but we run the author's released DLLs from the user's download rather than rebuilding (the sources need Havok headers the author does not supply).

## The design decision: code patches under strict AOT

Verified in the repo: AOT modules are keyed by the hash of the PE file and made at a fixed base (`VXRuntime/src/loader.c:856-858, 921`); an address with no module stops the run under `VXRT_AOT_STRICT` (`VXRuntime/translator/aot.c:480-490`); visionOS has no engine and its self-modifying-code hooks are empty stubs (`VXRuntime/translator/engine_nojit.c:44-45`); `VirtualProtect` only edits a bookkeeping table (`VXRuntime/src/kernel32.c:1378-1395`). So SKSE's runtime branch and trampoline writes into the exe would either do nothing or run unmapped code.

From reading the HIGGS and PLANCK sources: they patch one exe build at fixed offsets, about 35 and 45 code patches plus 6 and 14 vtable swaps, with 24 and 21 small generated stubs. The sets are finite and unconditional apart from a few feature switches. Vtable swaps are data writes and already work if the target is AOT'd.

| Option | What it is | For | Against |
| --- | --- | --- | --- |
| **A (recommended): capture on the Mac, replay statically** | Run SKSE and the plugins once on the Mac development path with a write logger. Record every write into the exe image, every executable allocation and the generated stub bytes. Prepare step: apply the byte diffs to a private copy of the PE, add the stubs as an extra AOT module, translate the patched exe and every plugin DLL. At run time the loader maps the plugins; their patch attempts find the bytes already in place and are accepted as no-ops. | Reuses the existing AOT path; zero fallback is checkable; works on visionOS unchanged; sites are enumerable and diffable against the plugins' source | Needs one Mac run per mod set; hooks that depend on run-time state are not captured; every plugin or version change means a re-prepare |
| B: intercepts in `vxrt-aot` | Teach the compiler "replace the function or call site at address X by native entry F", as it already does for imports. A plugin's declared hooks become intercepts at translation time. | Cleaner long term; no patched PE copy | Larger compiler change; mid-function patches still need byte patches; needs per-plugin hook knowledge |
| C: tiny x86 interpreter for run-time-written code | Anything written at run time is interpreted, not translated. | General escape hatch | Slow; adds a second execution engine; policy question below; do not start here |
| D: patch SKSE and plugins' source | Rebuild them as static ones | Smallest runtime | Closed source (VRIK) rules it out; Havok headers unavailable |

Choice: A first, B only if A cannot cover a plugin, C only with the user's explicit ruling. A also gives the acceptance test for free: the capture list must match the plugin's own hook list.

## Open decisions for the user (and what each gates)

| # | Decision | Gates |
| --- | --- | --- |
| D1 | May SKSE VR and the plugins run on the Mac development path (the translator engine allowed on Mac, labelled a development reference) to capture patches? | Phase 2 onward; Phase 1 does not need it |
| D2 | Does a tiny interpreter for run-time-written code (no code generation, interpretation only) count as allowed under the no-runtime-code-generation rule? | Option C only; no phase depends on it unless A fails for a plugin |
| D3 | Memory and GPU budget for mods on the headset: how much texture/mesh memory, and how much frame time may physics and UI add? | Phase 1 content sizing; Phases 4 to 6 acceptance thresholds |
| D4 | Who supplies SKSE VR, Address Library, PapyrusUtil, SkyUI, VRIK, HIGGS, PLANCK? Proposed: the user downloads them, we never fetch or redistribute. | All phases |

## Phases

Venue key. Mac: the only place the capture tooling and the logger can run, and the quickest to iterate. Simulator: proves the strict-AOT visionOS build and file layout without the physical device; it has no tracking and its GPU is not representative. Headset: the only venue for tracking, haptics, comfort, memory limits and frame time, and the only one that can say "playable" (`AGENTS.md`).

### Phase 1: data mods through the overlay

Deliverables:
1. A private mods layout: loose files, ESP/ESL/ESM and BSA under the overlay shadow of the install's `Data/`, plus a `plugins.txt` in the emulated AppData path the game reads. Read order is the user's.
2. A Mac prepare script that flattens an MO2 or Wabbajack profile into that layout, resolving priority off-device (`VXRuntime/src/files.c:137-150` has one overlay, not a stack).
3. A file-access log showing the game opened the mod's files, and a count of new shader hashes and AOT misses a mod list adds.

Acceptance: (a) Mac, strict AOT: a tiny owned test mod (one retextured asset, one small ESP) is read by the game, zero new fallbacks. Venue: Mac, because file reads and logs are faster to inspect there and nothing here depends on the device. (b) Simulator: same layout loads in the visionOS build, to catch case sensitivity and sandbox path differences. (c) Headset: a mid-size texture and mesh list loads and plays without exceeding the memory limit (D3); this sizes the budget. Unverified until run: shader permutations new content may request, `RECOMP.md:135` memory under the device's limit.

### Phase 2: SKSE VR and its foundations

Deliverables:
1. Capture tooling: a logger for writes into the exe image, executable allocations and `WriteProcessMemory` (hook points `kernel32.c:1378`, `client.c:648`), producing a diffable record. Needs D1.
2. An in-process loader for SKSE VR: map the SKSE DLL and each `Data/SKSE/Plugins` DLL through our PE loader (each with an AOT module), call the plugin entry points. No `CREATE_SUSPENDED`, no remote thread (`posix_spawn` refused on visionOS, `VISIONOS_PORT.md:308`).
3. The prepare step of option A: patched PE copy, stub module, module set, a provenance record of every input hash.
4. VR Address Library and PapyrusUtil working (PapyrusUtil has no code hooks; Address Library is data). The plugin dependency set of the target list is found by measurement, not guessed.

Acceptance: Mac then simulator. (a) Mac: SKSE VR alone loads, its log shows plugins loaded, the capture diff is stable across two runs, a PapyrusUtil-using script runs. (b) Mac strict AOT on the patched exe: zero fallback, no run-time code write observed. (c) Simulator: same, with the headset-only features off. Venue reason: capture must be on the Mac; the simulator proves the no-JIT build accepts the result. Headset only for a first smoke run once Mac and simulator pass. Unverified: SKSE core's own patch set; whether any of it depends on run-time state; the exe base the Address Library offsets assume (rebased exe, `tools/skyrim_aot_skyrimvr.json`).

### Phase 3: SkyUI VR and UI dependencies

Deliverables: SkyUI VR plus its SKSE plugin and the UI/menu dependencies found in Phase 2, in the prepared set; mod configuration menu usable with the Sense controllers; text and widgets legible on the headset.

Acceptance: Mac (menus open, MCM page changes a setting, saved to the overlay), simulator (renders both eyes), headset (a human can open the menu, point and click with the controller, and read it). Venue reason: UI correctness is checkable on the Mac; pointing and legibility need the device. Unverified: Scaleform UI rendering through our D3D11 path with SkyUI's extra SWF, and controller pointer mapping through xrizer.

### Phase 4: VRIK

Deliverables: capture of VRIK's patch set (closed source, so the capture is the only way to know it); prepared set including VRIK; calibration settings reachable; grip/aim offset review against VRIK's wrist targets (commit d0759e1 added a Sense grip offset).

Acceptance: Mac (loads, capture diff stable, zero fallback), simulator (loads under strict AOT), headset (a human sees a body that follows head and both hands without arm-length mismatch after in-game calibration, holsters work). Venue: capture on the Mac; body fit is only judgeable in the headset. Unverified: VRIK's hook set, CPU cost per frame, any dependency on the in-game OpenVR pose array being fresh.

### Phase 5: HIGGS

Deliverables: capture compared with the ~35 call/branch/byte patches and the vtable swaps enumerated from `hooks.cpp`; a fixture exercising what HIGGS calls on the game's `IVRSystem` (role lookup, connected state, pose velocities, haptic pulse) through the generated guest stubs against xrizer; haptic mapping for Sense (microseconds to amplitude and duration).

Acceptance: Mac (every logged write matches a source site, none extra; fixture passes with correct velocity units and frame); simulator (loads strict AOT); headset (grab, throw, two-handed weapon hold and haptics work; a human rates feel). Venue: the match-against-source check is static and Mac-only; throw feel depends on pose velocity quality, which only the device shows. Unverified: pose velocity and angular velocity values from xrizer and Sense, haptic timing.

### Phase 6: PLANCK

Deliverables: capture compared with the ~45 patches and 14 vtable swaps; HIGGS interface fetched by PLANCK in PostPostLoad; a physics cost measurement with NPCs in combat.

Acceptance: Mac (loads with HIGGS, zero fallback), simulator, headset (melee collisions and character reactions work, frame time within the D3) budget; measured separately from compilation and other GPU load, as `AGENTS.md` requires). Unverified: CPU cost with many active ragdolls, stability of the physics step at our frame pacing (17 compositor frames/s today, commit 569bad4).

## Risks

- VRIK is closed: its patch set is only knowable by capture, and a hidden run-time-dependent hook would break option A.
- Scope explosion in the foundations: many other plugins pull in their own hooks (Engine Fixes replaces the allocator); stage the set, never "all of the user's mods".
- Every mod set change forces a re-prepare and a new AOT module set; large lists multiply AOT build time and storage.
- GPU is already the limit; physics and UI add frame time. Memory on device is tight with big textures.
- Strict AOT means one missed site stops the run; the Mac profile loop (misses to roots, `RECOMP.md`) must be run per set.
- Licences: GPL source is for reading; do not copy it into MIT files without a notice entry in `THIRD_PARTY_NOTICES.md`.
- Simulator success says nothing about tracking, haptics, comfort or frame time.

## What stays unverified

Everything above is design. Verified only in code reading: the AOT keying, strict stop, `VirtualProtect` behaviour, the overlay semantics and the HIGGS/PLANCK hook enumeration. Not verified: any plugin loading on our runtime, SKSE's patch set, xrizer's velocity and haptic behaviour with these plugins, CPU and memory cost, popularity ranking (Nexus was unreachable), and anything about playability. Only a human physical-headset playtest establishes playable.
