# Plan: Skyland + SkyUI + HIGGS + PLANCK together, user-configurable, with a mod manager

Date: 11 November 2026. Status: design and research; the data-only path (Phase A) is proven on the Mac, everything after it is not started. Parent: [the mods plan](2026-11-10-skyrim-vr-mods.md) (SKSE design, options A to D, decisions D1 to D4 stay as written there) and its [research](../research/2026-11-10-skyrim-vr-mods.md) (section 8 holds the findings from the user's downloads). Texture mod details: [Skyland research](../research/2026-11-10-skyland-aio-1k.md). Read `AGENTS.md` first. Evidence labels as in the research: **[measured]** (read from the files or a run), **[code]**, **[community]**, **[inferred]**, **[unverified]**. Nothing in this plan has run on a headset.

## 1. What the user has, and what each needs (all [measured] from the files, read only)

| Mod | File in `~/Downloads` | Contents | Needs |
| --- | --- | --- | --- |
| Skyland AIO 1k 4.32 | folder + 7z | 2059 DDS, 181 NIF, 5 ESP, FOMOD, all loose | files only; no plugin required |
| HIGGS 1.10.10 (built 2026-01-13) | zip, 11 entries | `SKSE/Plugins/higgs_vr.dll` (877 KB, x64), `higgs_vr.ini` (593 lines), `higgs_vr.esp` (TES4 form 44, not ESL, masters Skyrim.esm + Update.esm), `Scripts/HiggsVR.pex`, `Source/Scripts/HiggsVR.psc`, a 17 MB `.pdb` (not needed at run time) | SKSE VR; **the ESP must be active** (the DLL logs "Could not get modinfo", "esp exists but is not active" and stops); VRIK optional ("Did not get VRIK api. This is okay."); Papyrus |
| PLANCK 0.8.2 (built 2026-10-12) | zip, 10 entries | `SKSE/Plugins/activeragdoll.dll` (737 KB), `activeragdoll.ini` (758 lines), `Scripts/planck.pex`, `planck.psc`, `.pdb`; **no ESP** | SKSE VR; **HIGGS** (it says "HIGGS is required for this mod" and checks the HIGGS interface version); Papyrus; branch trampoline and a code-gen buffer from SKSE ("couldn't acquire codegen buffer ... fatal") |
| SkyUI (package named `SkyUI-12604-6-11`) | zip, 2 entries | `SkyUI_SE.esp` (2.4 KB, **ESL-flagged**, form 44, master Skyrim.esm, SNAM "SkyUI SE 6.0") and `SkyUI_SE.bsa` (v105, 71 files: 47 SWF, 12 PEX, 11 translation/config txt, 1 DDS) | SKSE VR (its Papyrus checks it); an ESL answer (below); BSA loaded because its name matches the ESP |

Both plugin DLLs are old-style SKSE plugins: they export `SKSEPlugin_Query` and `SKSEPlugin_Load`, import only KERNEL32, USER32, SHELL32 and WINMM (no OpenVR, no Address Library), so they are ordinary x64 PE DLLs we can translate ahead of time, and they use fixed offsets of the one exe build (as the source reading in research section 7 said). The released builds contain the same strings as the source's hook log messages ("PlayerCharacter::Update pre-vrik hook complete", "Adding listeners and collision to new havok world", "hkpCharacterProxy..."), so the source reading applies to these versions [inferred: same author, same hook names; the byte-for-byte site list still has to come from the capture]. Kernel32 imports worth knowing for our runtime: `VirtualProtect`, `VirtualAlloc`, `VirtualQuery`, `GetModuleHandleW/ExW`, `GetProcAddress`, `LoadLibraryExW`, `RtlVirtualUnwind`, `SetUnhandledExceptionFilter` (both), `CreateThread` (HIGGS only), `timeBeginPeriod` (WINMM) [measured].

**SkyUI build question.** This is the **SE package** (`SkyUI_SE.*`, `skyui_se_*` translations); it contains no VR-specific file name. Whether it is the file the VR community uses (they run SkyUI's SE build under SKSE VR; a separate "SkyUI VR" port is also circulated) could not be settled from the package or from the repo [unverified; community]. The user should confirm on the Nexus page which file he took. Two facts matter either way:
1. Its ESP has the **ESL flag (0x200)**; Skyrim VR 1.4.15 has no light-plugin support [community]. Options: the "Skyrim VR ESL Support" SKSE plugin (a third SKSE plugin to catalogue), or a prepare-time private copy of the ESP with the ESL bit cleared (one flag bit in the TES4 header; safe when all form IDs are in the normal range, which has to be checked with the file's record list). [unverified]
2. **It hard-requires SKSE**: `SKI_Main.pex` contains the error texts "The Skyrim Script Extender (SKSE64) is not running", "SKSE64 is outdated. Required version / Detected version" and calls `GetVersionRelease` [measured]; 15 menu and panel SWFs reference the `skse` Scaleform object (inventory, magic, barter, container, gift, favorites, crafting, map, MCM panel, ...; 1 to 12 references each, `activeeffects`/`widgetloader`/`bottombar` also) [measured]; its Papyrus uses `UI.Invoke*`, `RegisterForModEvent`/`SendModEvent`, `RegisterForMenu` [measured names in `SKI_ConfigBase/ConfigManager`]. So the SWFs alone do not give the new menus: SkyUI refuses to start without SKSE (an error box at load, the vanilla-replacing menus without the extended data), which is why the SkyUI phase follows the SKSE core phase rather than the data phase.

## 2. Feasibility verdict

| Piece | Verdict | Why |
| --- | --- | --- |
| Skyland (textures and meshes) | **Works now** on the Mac; memory and look on the headset unverified | `--mods-dir`; see section 6 evidence |
| ESP/BSA/`Plugins.txt` mods (SkyUI data side, HIGGS ESP, Skyland ESPs) | **Small build, no research risk** (2 to 4 days) | the file layer already presents them; the game reads `C:\users\vxrt\AppData\Local\Skyrim VR\Plugins.txt` and today it fails to open it [measured in the P0 trace]; we write that file |
| SKSE VR core (needed by all three) | **Feasible but the largest unknown** | the loader injects into a suspended process and patches the exe; neither exists in-process under strict AOT (`CREATE_SUSPENDED` refused, `VirtualProtect` is bookkeeping `kernel32.c:1378-1395`, AOT executes translated code, never the bytes). Research option A: capture the core's patches on the Mac, replay them statically into a patched PE and an extra AOT module. Never tried for SKSE core |
| SkyUI | Feasible once SKSE core runs | no exe patches of its own; Papyrus natives and Scaleform extension live in the SKSE core DLL |
| HIGGS 1.10.10 | Feasible in principle, after SKSE core | about 35 code patches, 6 vtable swaps, 24 generated stubs (source), finite; OpenVR through the game's own `IVRSystem` (xrizer has the calls); haptics and velocity quality unverified |
| PLANCK 0.8.2 | Feasible in principle after HIGGS | about 45 patches, 14 vtable swaps, 21 stubs; Havok-heavy; CPU cost unknown |
| VRIK | Not assessed (closed source; not downloaded yet) | capture is the only route |
| "Native OpenVR hooks" | Not needed | neither DLL imports OpenVR; both read the game's cached poses and call through the game's `IVRSystem` |

Hard rule inherited: no JIT, no runtime code generation. Both plugins ask SKSE for a **code-generation buffer and a branch trampoline** and fill them with Xbyak-generated x86 at load. Under strict AOT that code cannot run unless it was captured on the Mac and added as an AOT module before the run (option A). A run that reaches an unmapped address stops (`aot.c:480-490`).

### Effort and milestones (ranges are [inferred], a single developer, Mac work unless stated)

| # | Milestone | Done when | Estimate |
| --- | --- | --- | --- |
| M0 | Plugins and archives layer: `--mods-dir` passes ESP/BSA, `Plugins.txt` written per run, ESL-flag handling for SkyUI, flattener generalised from `tools/skyland_flatten.py` | SkyUI_SE.bsa opened (file trace) and the ESP shown loaded in the game log with the right form count | 2 to 4 days |
| M1 | Spike, needs decision D1: run SKSE VR 2.0.12 on the Mac development path with a write logger (hook points `kernel32.c:1378`, `client.c:648`) | a diffable record of the core's code writes, executable allocations and trampolines, stable across two runs | 1 to 2 weeks |
| M2 | Static replay: patched private PE, stub module, AOT of the patched exe (keyed by its hash, so a new full AOT run), in-process SKSE bootstrap instead of the injector | strict AOT run, SKSE log lists plugins, 0 fallbacks, no run-time code write observed | 2 to 4 weeks (largest risk) |
| M3 | SkyUI: Papyrus runs `SKI_Main` without the SKSE error, MCM page opens, a setting persists to the overlay | Mac then headset (a human opens the menu and reads it) | 1 to 2 weeks |
| M4 | HIGGS: capture matches the source site list, fixtures for role lookup, connected state, pose velocities and haptic pulse through generated guest stubs against xrizer | Mac strict AOT, zero fallback, load line in `higgs_vr.log`; feel only on the headset | 3 to 5 weeks |
| M5 | PLANCK on top of HIGGS | loads with HIGGS, zero fallback, cost measured with NPCs in combat | 2 to 4 weeks |
| M6 | Mod manager pieces (section 5): VFS index in `files.c`, `mods.json`, Mac installer/FOMOD runner, device toggles | section 5 acceptance | 4 to 6 weeks, mostly independent of M1 to M5 and can run in parallel |

Total for the plugin route to a first playable test: roughly 3 to 4 months of focused work if M1 shows the patches are static, longer if not [inferred; M1 is the gate that turns this guess into a number]. Only a human physical-headset playtest can say any of it is playable.

## 3. Combined phasing

### Phase A: data-only mods (works now)

Skyland tier 1 (Landscapes + Whiterun) through `--mods-dir`, then tier 2 (cities, no Granite Mountains, no Night Skies). Proven on the Mac for one texture and tier 1 (research doc, section 9, with numbers). Next: M0.

### Phase B: plugins and archives (M0)

`SkyUI_SE.esp`/`.bsa`, `higgs_vr.esp`, Skyland's optional ESPs. They load without SKSE, but SkyUI and HIGGS will refuse to run (their own error boxes); that is the first visible proof the ESP and BSA layer works. Verify with the file trace and the game's plugin list.

### Phase C: SKSE core (M1, M2), then SkyUI (M3)

SkyUI is the first consumer because its needs are only inside the SKSE core: no game-code patches of its own, no Havok, no OpenVR. If SKSE core replay works for SkyUI, it works for the rest of the interface layer.

### Phase D: HIGGS (M4), E: PLANCK (M5), F: VRIK (later)

Gate every step on the previous one's strict-AOT zero fallback.

### Load order and conflicts

Plugin order written to `Plugins.txt` (`*` marks enabled, as SE and VR use [community]): `Skyrim.esm`, `Update.esm`, `Dawnguard.esm`, `HearthFires.esm`, `Dragonborn.esm` (the official ones are implicit), then `SkyUI_SE.esp`, `higgs_vr.esp`, then Skyland's `Lit Road Signs.esp` and one Watercolor variant (Vanilla or iNeed; the RW2 variants need Realistic Water Two, which we do not have). PLANCK has no plugin. Loose-file priority for the VFS: Skyland meshes and textures are one mod; SkyUI and HIGGS ship scripts and an interface BSA; none overlaps Skyland's paths (Skyland touches `textures/`, `meshes/`, `textures/arthmoor/...`; SkyUI `interface/` and `scripts/`; HIGGS `scripts/`) [measured by path]. Known conflicts: Skyland "Point The Way" signs versus "Lit Road Signs" (the FOMOD says incompatible), Skyland SMIM textures versus no SMIM meshes (harmless), HIGGS versus PLANCK patching the same sites such as `PlayerCharacter::Update` (the M4/M5 captures must list any site both write; PLANCK was written to run with HIGGS, so it is expected to be compatible) [unverified].

### Memory budget on the headset

Baseline: peak footprint about 7.2 GB, about 1 GB headroom (user figure; the app has about 8.1 GB including Metal, `VISIONOS_PORT.md:305`). Proposed allocation of the 1 GB until measured: textures and meshes from data mods at most 300 MB (Skyland tier 1 measurement in research section 9), plugin code and stubs under 10 MB (two DLLs of 1.6 MB, AOT modules of the DLLs add file-backed code), SkyUI SWFs and scripts under 20 MB (BSA 2.9 MB), HIGGS/PLANCK heap and Havok bodies unmeasured (reserve 150 MB), and 500 MB kept free. Abort criterion for any step on the headset: `available_mb` below 400 MB in `host_log.jsonl`.

## 4. User configurability

Principle: the Mac prepares, the headset only toggles what was prepared. Anything that needs unpacking, patching or AOT (archives, FOMOD choices, the SKSE patch set) is a Mac step; anything that is a switch among prepared things is a headset setting.

**4.1 `mods.json` in the overlay root** (`Documents/root/mods.json` on the device; `--mods-config FILE` on the Mac). One schema, written by the Mac tool, read by the runtime:

```
{ "version": 1, "profile": "default",
  "mods": [ { "id": "skyland-t1", "name": "Skyland AIO 1k (landscapes, Whiterun)", "enabled": true, "priority": 10,
              "path": "mods/skyland-t1", "kind": "files",
              "memory_hint_mb": 250, "sha256_tree": "..." },
            { "id": "skyui", "enabled": true, "priority": 20, "path": "mods/skyui",
              "plugins": ["SkyUI_SE.esp"], "requires": ["skse-core"] },
            { "id": "higgs", "enabled": true, "path": "mods/higgs", "plugins": ["higgs_vr.esp"],
              "skse_plugin": "higgs_vr.dll", "patch_set": "higgs-1.10.10", "requires": ["skse-core"], "conflicts": [] },
            { "id": "planck", "enabled": false, "skse_plugin": "activeragdoll.dll", "patch_set": "planck-0.8.2", "requires": ["higgs"] } ],
  "ini": { "Skyrim.ini": { "Archive": { "bInvalidateOlderFiles": "1" } } },
  "plugin_order": ["SkyUI_SE.esp", "higgs_vr.esp"] }
```

The runtime derives from it, at start: the ordered list of mod roots (VFS), `Plugins.txt`, the per-run ini edits (today's `--overlay-ini`), and which SKSE plugins to map. A mod whose `requires` is disabled or absent is disabled with a logged reason. Equivalent of MO2's `modlist.txt` + `plugins.txt` in one file.

**4.2 Settings window.** `VXStartView.swift` already has Resolution, Upscaling, Latency, Hands, Sense, Prediction and Eye height sections, with `VXSettings` mapping stored values to `VXRT_*` environment (Klepton's persistence conventions). Add a **Mods** section: one row per mod in `mods.json` (name, size, memory hint, toggle), a warning line when the sum of memory hints exceeds the budget, and a "restart to apply" note (the file index and plugins are read at start, like Resolution). Toggles write a small `mods_state.json` (id to enabled) beside `mods.json`, so the Mac-prepared file stays immutable and "reset to defaults" is deleting one file. Cost: about a week in Swift plus the C reader.

**4.3 AVP Play as installer.** `plans/2026-11-09-avp-play-backend.md` makes AVP Play couple to our toolchain only through files and environment (`stage_sync.py`, `toolchain.json`). It already syncs the game data to the headset; the proposal is that its sync also carries the prepared `mods/` tree and `mods.json` into the same Documents root (one more path in the stage sync), and that the Mac side tool in section 5 produces them. That is a change to the AVP Play contract and needs the user's go-ahead to propose upstream; until then the copy is `devicectl device copy to` or Finder sharing (`UIFileSharingEnabled`), as for the game data.

**4.4 SKSE plugins are not freely toggleable unless built so.** Under option A, each patch set is baked into a patched exe and its AOT module; changing the set means a new full AOT of the exe. Making enable/disable a headset setting needs the **catalog design**: translate the exe once with every catalogued patch site compiled as a guarded indirection (a table slot per site, filled at start from `mods.json`: slot empty runs the original instructions, slot set calls the plugin hook with the displaced instructions replayed by the generated stub). That is a larger compiler change (research option B), but it is the only route to "tick HIGGS on or off in the settings window" and to supporting a short list of known plugin versions (`higgs-1.10.10`, `planck-0.8.2`, `skse-core-2.0.12`) rather than arbitrary ones. Recommendation: start with option A (one fixed set, no toggles) and design the capture format so it converts to the catalog later. Arbitrary user-supplied SKSE plugins stay out of scope: each new plugin needs its own capture, review and AOT.

## 5. Mod manager: what it is, what we would build

**What the established managers do** [community, for orientation; not verified against their source here]:

| Function | MO2 | Vortex | Our current state |
| --- | --- | --- | --- |
| Install an archive | extract into `mods/<name>/`; FOMOD wizard (XML `fomod/ModuleConfig.xml`, steps, groups, flag conditions) | extract to staging, then deploy | by hand; `tools/skyland_flatten.py` handles one FOMOD subset |
| Virtual file system | usvfs hooks the launched process's file APIs to present `Data` plus every enabled mod folder by priority; writes go to an `overwrite` folder; Data never modified | hardlinks or symlinks mods into `Data` ("deploy") and tracks them | one overlay layer in `files.c:137-150` (reads overlay-first, writes to overlay): the right place to extend, because the runtime already implements the guest's file APIs; no API hooking needed |
| Load order | `plugins.txt` and `loadorder.txt` per profile, LOOT sorting | same files, LOOT | none; `Plugins.txt` unopened |
| Priority and conflicts | mod list order is priority; conflict icons show file-level winners and losers | rules and deploy order | no priority between mods (single layer) |
| Profiles | `profiles/<name>/` with `modlist.txt` (`+Mod`/`-Mod` lines), `plugins.txt`, `loadorder.txt`, profile ini files | profiles of mod state | none |
| Executables | launches Skyrim through `skse_loader.exe` inside usvfs | launches tool | our launcher starts the prepared exe; SKSE would be our bootstrap (section 2) |
| Online | Nexus links, downloads | Nexus integration | none; the user downloads (decision D4) |

**What we need, split by where it runs**

| Piece | Where | Build or adopt | Licence if reused |
| --- | --- | --- | --- |
| Archive extraction (zip/7z/rar) | Mac | macOS `bsdtar` (libarchive reads zip and 7z; rar not) or a user step; never on the headset | system tool |
| FOMOD runner (`ModuleConfig.xml`: installSteps, groups, plugins with `typeDescriptor`, `conditionFlags`, `dependencies`, `files`/`folders`, `conditionalFileInstalls`) | Mac, Python, run on data only, no scripts | **write our own from the schema and the files**, as `skyland_flatten.py` begins to (Skyland's file declares `ModConfig5.0.xsd`) | Nexus-Mods `fomod-installer` is GPL-3.0 C#: reading is allowed, copying needs the user's say-so (`AGENTS.md`); not needed |
| Mod store and profiles | Mac | adopt **MO2's profile text formats as input/output** (`modlist.txt`, `plugins.txt`, `loadorder.txt`, `mods/<name>/meta.ini`) so a profile from a Windows MO2 install can be imported; our own `mods.json` is the runtime form | formats are not code; MO2 is GPL-3.0, so no copying of its code; `modorganizer-basic_games` is MIT; `usvfs` shows NOASSERTION in the GitHub API and its licence was not read, so do not reuse it (we do not need it: Windows API hooking is irrelevant in our runtime) |
| Plugin sorting | Mac | optional: LOOT (GPL-3.0, masterlist data) as an external tool whose output we import; do not embed | GPL-3.0 [community] |
| VFS merge at open time | runtime (`files.c`, both platforms) | **build**: replace the single overlay by an ordered list of read layers over the install and one write layer; a prepared index (lower-cased path to layer) built on the Mac and shipped next to `mods.json`, so the headset never scans; directory listings are unions; writes still go to the overlay. Also removes the case-sensitivity worry for overlay-only directories (`vx_ci_path` starts from the original path) | ours |
| Plugins.txt writer | runtime start (C) and Mac | build, a few dozen lines | ours |
| Conflict view, load-order UI, installer wizard | Mac app (`MacApp/`, SwiftUI "Play" page) | build later; the existing Library/Play structure is the natural place | ours |
| Mods settings on the headset | visionOS app | build (4.2) | ours (MIT-style per Klepton conventions already used) |

**Mac versus headset.** The Mac does everything that changes bytes: extraction, FOMOD, flattening or indexing, ESL clearing, texture checks, patch capture, AOT, `mods.json`, the copy. The headset app only reads `mods.json` + `mods_state.json`, builds nothing, toggles and reports (`host_log.jsonl`). This keeps the no-JIT, no-helper rule intact for the play session (a Mac may prepare and install, per `AGENTS.md`).

**Is MO2-style per-mod folders merged at file-open time in `files.c` realistic?** Yes, and it is the best-fit part: the runtime already resolves every guest path (`vx_unix_path`), lists directories (`find_first`), and has an overlay. The additions are (a) a layer list from `mods.json`, (b) an index file, (c) union directory listing, (d) tests with the owned fixtures plus a file trace on Skyrim. Risk: Skyrim scans loose directories recursively at start (observed: it lists `data\TEXTURES\` and every subdirectory, P1 trace), so the union listing must be correct for every directory, and fast for 10,000+ files. Phase A already shows that a symlinked top-level directory works.

**Recommendation.** Do not adopt a whole manager. Adopt the file formats (FOMOD XML as input, MO2 profile text files as import/export), write the small pieces ourselves, and put the VFS in the runtime.

## 6. Evidence from this session (Mac, strict AOT, Helgen, not a headset)

See research doc section 9 for the tables (A/B, full-install smoke, eye crops). Proof that loose files are used with no ini change: baseline P0 shows `GetFileAttributesEx(...data\TEXTURES\): error 2`; with one Skyland texture linked (P1) the game found `data\TEXTURES\`, listed `Landscape\dirt01.dds` (size 699192 = the mod's file) and later `CreateFile(...data\TEXTURES\Landscape\dirt01.dds): opened`. So no `[Archive]` ini keys were added. The lever is `--mods-dir` in `tools/play_skyrim_dev.sh` and `tools/vxrt_native_startup.py`; the tree comes from `tools/skyland_flatten.py`.

## 7. Open decisions for the user

| # | Decision | Gates |
| --- | --- | --- |
| D1 (from the mods plan) | May SKSE VR and the plugins run on the Mac development path to capture patches? | M1 onward |
| D5 | Which SkyUI file is this (SE vs VR port), and ESL: add "Skyrim VR ESL Support" to the catalogue or clear the flag in a private copy? | M0/M3 |
| D6 | Supported-plugin catalogue (fixed list of versions, toggles on the headset) versus per-run capture (option A only)? Recommended: A first, catalogue later | M2 design |
| D7 | May we propose the `mods/` sync to AVP Play upstream (posting needs a go-ahead)? | 4.3 |
| D8 | Memory budget: accept 300 MB for data mods until measured? | Phase A on the device |

## 8. Next three steps

1. M0 (2 to 4 days, Mac): extend `--mods-dir`/the flattener to carry `.esp`/`.bsa`, write `Plugins.txt` into the per-run root, clear the ESL bit in a private copy of `SkyUI_SE.esp`; run once with SkyUI + HIGGS data only and confirm with the file trace that `SkyUI_SE.bsa` and `higgs_vr.esp` open and the plugin list shows them.
2. M1 (needs D1): the SKSE VR write-logging spike on the Mac, using the user's own SKSE VR download, to decide option A versus B for good.
3. In parallel, the VFS index and `mods.json` reader in `files.c` plus the Mods section in `VXStartView.swift`, tested on the Mac with Skyland tiers as the first two mods.

## 9. Device copy plan for the full Skyland install (written 2026-11-11, nothing run on the device)

Source (Mac, private, git-ignored): `build/private/mods/skyland-aio-1k-full` in the `mods-research` worktree (2057 files, 2,632,276,741 bytes; `Data/Textures`, `Data/meshes`, two ESPs; `Plugins.txt`; `manifest.json`). Fallback if memory is tight: `skyland-aio-1k-full-lite` (no Granite Mountains, no night sky; 2049 files, 2.51 GB). HIGGS, PLANCK and SkyUI are not part of this run: they need SKSE VR, which the runtime cannot load yet.

**Prerequisites.** (1) The app build contains `e0197c4` (`files.c`: the overlay's own names looked up case-insensitively; the visionOS file system is case-sensitive, so without it the game's `data\TEXTURES\...` does not find a `Textures` folder in the overlay). (2) The user's authorization for a physical-device copy and launch. (3) No other session on the device.

**Where things go** (`Documents` is the app container's; `VXRT_ROOT` = `Documents/root`, the game folder `Documents/root/SkyrimVR`, overlay `Documents/root/overlay_skyrimvr`: `main.m` `skyrimvr_start`):

| Source | Destination in the container |
| --- | --- |
| `<tree>/Data/Textures/` (1917 files) | `Documents/root/overlay_skyrimvr/Data/Textures/` |
| `<tree>/Data/meshes/` (138 files) | `Documents/root/overlay_skyrimvr/Data/meshes/` |
| `<tree>/Data/Lit Road Signs.esp`, `<tree>/Data/Skyland Watercolor - Slow Green-Vanilla.esp` | `Documents/root/overlay_skyrimvr/Data/` (top level of Data) |
| `<tree>/Plugins.txt` (CRLF; `*Lit Road Signs.esp`, `*Skyland Watercolor - Slow Green-Vanilla.esp`) | `Documents/root/drive_c/users/vxrt/AppData/Local/Skyrim VR/Plugins.txt` (outside the overlay; the Mac trace shows the game opening exactly `C:\users\vxrt\AppData\Local\Skyrim VR\Plugins.txt`) |

Nothing is written into `Documents/root/SkyrimVR/Data` (the game copy stays unmodified).

**How.** `xcrun devicectl device copy to` copies a directory recursively ("copies a file or directory to the device, skipping files that have not been modified"; `--source` may be repeated; `--remove-existing-content` defaults to false), so no tar and no unpack step is needed, and a repeated run resumes. Per-file cost for about 2000 files is unknown; the earlier measured rate was about 40 MB/s (`VISIONOS_PORT.md:315`), so roughly 1 to 2 minutes of bulk transfer plus overhead [inferred]. Steps:
1. List the container first: `xcrun devicectl device info files --device <id> --domain-type appDataContainer --domain-identifier <the Skyrim app's bundle id> --subdirectory Documents/root` and confirm `SkyrimVR/` and `overlay_skyrimvr/` (the bundle id in `VISIONOS_PORT.md:437` is `exampleprefix.VXRuntimeHost`; use the one of the app being installed).
2. Probe the path semantics with two small copies: `Plugins.txt` to its full destination path above (checks that missing directories are created), and `Data/meshes` (138 files) to `.../overlay_skyrimvr/Data/meshes`; list the result. If it nested wrongly (`Data/meshes/meshes`), copy to the parent (`.../overlay_skyrimvr/Data`) instead, for every directory.
3. Copy `Data/Textures` (about 2.4 GB), then the two ESPs (each to the full file path).
4. Verify: list `Documents/root/overlay_skyrimvr/Data` recursively and compare the file count with `manifest.json` (2057 plus `Plugins.txt`) and spot-check sizes of `Textures/Landscape/mountains/mountainslab01mask.dds` (22,369,744 bytes in the source) and one NIF.
5. Launch the game as usual. In `Documents/vxrt.log` expect `fopen(C:\users\vxrt\AppData\Local\Skyrim VR\Plugins.txt, r): opened`, `data\TEXTURES\`: found (not error 2), both ESP names opened. If these lines show errors, stop and read the casing in the path it asked for.
6. Watch `Documents/host_log.jsonl` `available_mb`: stop and switch to the lite tree if it falls under 400 MB. Roll back with `devicectl device copy to --remove-existing-content true` of an empty folder onto `.../overlay_skyrimvr/Data` (this deletes the shader-cache folder the overlay may hold under `Data/ShaderCache`; check with step 1 before) or, for the plugins alone, by removing `Plugins.txt`.

What the device run answers (unknown today): does the case fix make the loose files resolve on a case-sensitive volume, what the memory delta is with these textures in the actual world (the Mac showed up to +250 MB and the same texture bytes in the Helgen scene), whether the load or streaming hitches, and how it looks; a human has to judge the last two.
