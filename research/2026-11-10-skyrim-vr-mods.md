# Skyrim VR mods on the standalone Vision Pro port: what is popular, what each needs

Date: 2026-11-10. Subject: static analysis of the repository plus web reading. Nothing was run, built or downloaded.
Evidence tags: [code] verified in this repo (file:line); [web] read at the cited URL; [know] background knowledge of the
Skyrim VR modding scene that I could not confirm from a fetched page (treat as unverified).

Source quality warning. The Nexus Mods pages returned HTTP 403 to the fetch tool, and several GitHub URLs I guessed
(Shizof/HIGGS, the modding guides) returned 404. So there are no verified download or endorsement counts here. The popularity
ranking below is [know] (community consensus as I remember it) and should be checked against the Nexus "Skyrim VR" most
endorsed list (https://www.nexusmods.com/skyrimspecialedition/mods/ , filtered to the VR game page) by a human with a browser.

## 1. What people actually install

The Skyrim VR scene is smaller than flat Skyrim SE. The usual stack, from the community guides and the big Wabbajack lists
(FUS, Mad God's Overhaul, Auriel's Dream, Tahrovin's VR list) [know], is:

| Layer | Typical mods [know] | Kind |
| --- | --- | --- |
| Script extender | SKSEVR 2.0.12 for game 1.4.15 (https://skse.silverlock.org/ [web]); plugins live in Data/SKSE/Plugins [web] | native DLL loader plus plugins |
| Offsets | VR Address Library for SKSEVR | data file (a .bin of ID to offset), read by plugins |
| Bug fixes | SSE-style engine fixes for VR (Engine Fixes VR, "Skyrim VR Tweaks"-type), PapyrusUtil VR, powerofthree's Tweaks VR | SKSE plugins (native DLLs that patch the exe) |
| UI | SkyUI VR, Spell Wheel VR, VR-specific menus (VRIK-style config, Wheeler), Immersive HUD | Flash/SWF and Papyrus plus SKSE plugin |
| VR physics and body | VRIK (body IK), HIGGS (hand grab), PLANCK (physical combat), Fully Dynamic Weapons-style tools, CBPC/SMP physics (hdt-SMP VR, CBPC) | SKSE plugins, many hooking the game's character and havok code heavily |
| Animations | Open Animation Replacer, DAR (Dynamic Animation Replacer), FNIS/Nemesis/Pandora output | SKSE plugin plus data (HKX), generation off-line |
| Graphics | ENB (d3d11.dll proxy), ReShade (dxgi.dll/d3d11.dll proxy), Community Shaders (SKSE plugin with VR support), vrperfkit/Skyrim VR performance tools (dxgi.dll proxy), SSE Display Tweaks-style plugins | renderer-level |
| Data mods | Textures (Skyrim 2020-style, Noble Skyrim), meshes, landscapes, Unofficial Skyrim Special Edition Patch ported to VR, quests, followers, armour, Papyrus-only gameplay mods | ESP/ESL/ESM plus loose files or BSA |
| Tools at install time | MO2 (USVFS), Vortex, xEdit/SSEEdit, Wrye Bash, DynDOLOD and TexGen, BodySlide, Nemesis/Pandora, LOOT, ParallaxGen | PC programs, off-device |

Web-verified facts behind this table:

- SKSE VR current build is 2.0.12 for game 1.4.15, launched through loader executables, plugins go in Data/SKSE/Plugins
  (https://skse.silverlock.org/ [web]).
- SKSE64 sources have separate loader directories (skse64_loader, skse64_steam_loader) and bundle xbyak, a runtime x86-64
  assembler used to build hook code (https://github.com/ianpatt/skse64 [web]; the use of xbyak for hooks is inferred from the directory, not stated).
- CommonLibSSE-NG supports SE, AE and VR in one DLL, and VR plugins need the "VR Address Library for SKSEVR"
  (https://github.com/CharmedBaryon/CommonLibSSE-NG [web]). This is the base most modern VR plugins (and Community Shaders) are built on [know].
- Community Shaders is an SKSE core plugin that ships per-feature shader trees and lists "AE, SE and VR" as targets; it needs Address
  Library (https://github.com/doodlum/skyrim-community-shaders [web]). Its D3D11 hooking mechanics are not on that page [know: it hooks the game's
  shader setup and the swap chain from inside the process].
- vrperfkit installs as a dxgi.dll next to the game exe, supports Direct3D 11 with OpenVR (https://github.com/fholger/vrperfkit [web]).
- MO2 has a dedicated Skyrim VR game plugin (modorganizer-game_skyrimVR) and a separate usvfs component
  (https://github.com/ModOrganizer2/modorganizer [web]); the hook mechanism is documented only in usvfs [know: it hooks file APIs in the child process].

## 2. What our port has today (all [code])

- No mod support exists. The plan lists "SKSE/mods" as out of scope for the first proof (plans/2026-11-08-skyrim-vr-native-darwin-aot.md:353). grep of tools/, VXRuntime/*.md, plans/ and research/ for SKSE finds only that line.
- No ESP or plugins.txt handling in the runtime: grep of VXRuntime/src for "plugins.txt" and ".esp" finds nothing. The game itself reads
  plugins.txt from the AppData path and Data/*.esp through ordinary file APIs, so the runtime only has to present those files.
- File mapping and overlay: Windows paths map to $VXRT_ROOT/drive_c (VXRuntime/src/files.c:4). VXRT_OVERLAY=<tree>:<overlay> makes writes under
  the install tree go to the overlay, reads come from the overlay copy first, and directory listings merge both with the overlay's entry
  winning (files.c:137-150, env read at files.c:202). That is exactly a one-layer virtual file system for loose files: dropping a mod's Data/ files into
  the overlay makes the game see them. Limit: it is a single overlay, not a priority-ordered stack of mods (what MO2/USVFS gives).
- DLL search: LoadLibrary resolves through the game directory, overlay copy first (VXRuntime/src/loader.c:575-590), then VXRT_DLL_PATH for the user's own
  Windows DLLs. So a plugin DLL placed in the overlay would be found and mapped.
- AOT is keyed by file content. Each PE is hashed and looked up as `<name>-<hash>.dylib` in VXRT_AOT_DIR (loader.c:856-858, 921), made at a fixed base (the module set
  in tools/skyrim_aot_skyrimvr.json lists the exe rebased to 0x308000000 plus bink, openvr_api, steam_api, msvc runtime, d3dx9, X3DAudio at 0x300000000-0x305000000).
  A DLL with no module is a fallback to the translator (counted), and with VXRT_AOT_STRICT=1 the process stops: "has no recompiled code; stopping"
  (VXRuntime/translator/aot.c:480-490). On visionOS there is no engine at all: engine_nojit.c replaces it and its self-modifying-code hooks are
  empty stubs (VXRuntime/translator/engine_nojit.c:44-45; MAP_JIT unavailable, VXRuntime/VISIONOS_PORT.md:43; "No fallback", RECOMP.md:178).
- VirtualProtect is bookkeeping only. It records a protection value in a table and refuses to make never-writable native pages writable
  (VXRuntime/src/kernel32.c:1378-1395, error 487). The table does not change real page permissions of AOT module code, and a write to the exe's code bytes
  in memory would not change what the AOT module executes. WriteProcessMemory exists (VXRuntime/src/client.c:648) and FlushInstructionCache is a no-op (VXRuntime/src/services.c:589).
  Consequence, [inferred from the above]: runtime code patching (SKSE's branch and trampoline writes) silently has no effect on AOT code, or crashes if the patch target
  is executed from a freshly written trampoline page that no module covers (strict stop).
- The renderer: D3D11 to Metal with DXBC translated to MSL; the shader manifest is built offline from the game's own packs (shaders011_vr.fxp in
  Skyrim_VR - Main.bsa, 10777 containers, all requested at runtime; VXRuntime/VISIONOS_PORT.md:228-240). A shader the manifest lacks must be added to
  the offline set; there is no on-device compile of unknown DXBC planned [know-from-plan; check VISIONOS_PORT.md before relying].
- Mod-relevant D3D11 consequence: an ENB or ReShade d3d11.dll/dxgi.dll proxy next to the exe is just another PE the loader would find first (load_library search order, loader.c:532-590).

## 3. Classification and what each needs

### (a) Data only (ESP, ESL, ESM, BSA, loose textures, meshes, sounds, SWF, Papyrus scripts .pex)

Works with no code change to the game binary, once the files are visible and the engine loads them. Needed:
1. Files placed in the overlay (or a merged Data/) so the game finds them; plugins.txt and Plugins list in the emulated AppData (the game reads
   %LOCALAPPDATA%\Skyrim VR\plugins.txt); loadorder is the user's. Edit-time ordering by LOOT or MO2 stays on the Mac.
2. Archives: BSA reading is the game's own code, but the game opens big files; the existing runtime already handles the stock BSAs (Skyrim_VR - Main.bsa).
   Loose-file priority: the game honours loose files over BSA contents with sResourceDataDirsFinal, so nothing special.
3. New shaders only appear with graphics mods (see c). Texture and mesh mods increase memory; the device footprint (RECOMP.md:135 "memory under the device's limit") is the
   real constraint on a headset, not file format. Texture packs (2K to 4K) and big meshes should be budgeted.
4. Papyrus script mods are data from the runtime's view (scripts run in the game's VM, which is AOT'd code already). Script-only mods that use only vanilla papyrus functions work with no SKSE.
Risk: new content hits untested engine paths (more shader permutations, other NIF/havok paths), so expect translator/AOT miss lists to grow: the
profile loop in RECOMP.md ("misses to roots") still applies to the exe. Value: very high. Effort: low (overlay + path presentation).

### (b) SKSEVR and native plugins

How SKSE works [know, confirmed only at the structural level by the skse64 repo listing]: a loader exe creates SkyrimVR.exe suspended, injects skse64_*.dll, which
patches the exe in memory (code writes using VirtualProtect, branch and call writes, and trampolines in allocated executable memory generated with xbyak). It then loads every DLL in
Data/SKSE/Plugins and calls SKSEPlugin_Load; plugins use the same pattern against addresses resolved from the VR Address Library .bin (ID to RVA table) or from fixed offsets.

Why this conflicts with our port (consequences verified in code above; the hook mechanics are [know]):
- Strict AOT: the exe is translated once from the unpatched file. A patch applied in memory changes bytes the AOT module never reads. Trampoline pages
  written at runtime have no module: strict mode stops; visionOS has no engine to fall back on (engine_nojit.c:44-45).
- W^X on visionOS: no MAP_JIT, and no executable page can be written by the app (VISIONOS_PORT.md:43, :308). Even a "correct" runtime hook needs executable writable memory.
- Injection: no CreateProcess with CREATE_SUSPENDED or remote threads (posix_spawn is refused, VISIONOS_PORT.md:308), so the SKSE loader cannot run as it is.

What would be needed (design options, ordered by plausibility):

| Option | Idea | Cost | Verdict |
| --- | --- | --- | --- |
| B1 Static SKSE | At prepare time on the Mac, run a normal "patch exe" step: apply SKSEVR's own patches to a copy of the PE (their branch writes are deterministic given the file), then AOT the patched exe and each plugin DLL. Skip runtime patching. | Needs the list of patch sites. Obtainable by running SKSEVR + plugin once under the Mac development path (translator engine allowed on Mac) with a write logger on VirtualProtect/WriteProcessMemory/stores into the image, recording the final bytes of the exe's code range, then replaying the diff statically. Trampolines become part of an extra generated module. | Feasible for SKSE core and plugins whose hooks are unconditional. Hooks that depend on runtime state (config, other plugins' presence, game settings) are not static. |
| B2 AOT'd plugin loader | Replace the SKSE loader by an in-process loader inside our runtime: load the SKSE DLL and plugin DLLs through our PE loader (each with an AOT module keyed by hash, loader.c:856), call SKSEPlugin_Load. The DLLs' write attempts go to a "patch shim" implemented by the runtime. | The shim must turn a runtime write into something the AOT understands. Options: at prepare time pre-translate the exe's PATCHED bytes (B1), or have the AOT'd exe consult an indirection table at each hooked function entry (dispatch table checked on entry to every translated function, expensive). | The loader half is straightforward (our loader already maps DLLs, loader.c:983-1060). The patching half is the hard part. |
| B3 Hook table in the AOT compiler | Teach vxrt-aot a "replace function at address A with native function F" feature (like how it already treats native thunks as targets: "a native function: its thunk is called from C", RECOMP.md:30-34). Plugin hooks are mapped to those entries at prepare time. | Moderate: AOT already supports native entries for imports. Entry-level hooks (call/jmp replacement at function start, most SKSE hooks) fit. Mid-function patches (changing a single instruction or a constant) fit through a byte patch before translation. | Best long-term design; same data as B1 but expressed as intercepts instead of a patched file. |
| B4 Interpret generated trampolines | A tiny x86 interpreter for regions of runtime-generated code (already contemplated: VISIONOS_PORT.md:388, "A tiny x86 interpreter for the rare l...") | Makes any runtime-written code run slowly, no JIT. Plugin DLLs and exe stay AOT. | Escape hatch for odd plugins; slow but general. No code generation, so it respects the rule (interpreting is not generating). Needs a decision from the user: does an interpreter count as "debugger-assisted or runtime CPU code generation"? It does not generate code, but confirm. |

Address Library mapping. The VR Address Library is a data file mapping a version-independent ID to an RVA in the one VR exe build (1.4.15). Because our exe is
exactly that build (hash 6961efb4... in tools/skyrim_aot_skyrimvr.json) and is only rebased (to 0x308000000), plugins resolve IDs to base+RVA as on Windows; no rewrite is needed as long as the loader reports the rebased
image base through GetModuleHandle(NULL). One check: the Mac currently uses a rebased exe, and plugins that hardcode 0x140000000-relative absolute addresses (rare in CommonLib-based plugins) would break. [inferred; verify]

Plugins by difficulty [know]:
- Easy (pure SKSE API, Papyrus functions, few hooks): PapyrusUtil, SKSE-menu-framework-style libraries, Spell Wheel VR, SkyUI VR support DLLs, "Better Dialogue Controls"-style.
- Medium (entry hooks, vtable swaps): powerofthree Tweaks, Engine Fixes (also patches CRT allocation, memory manager; patches are mostly static byte writes plus replacement of the allocator: replacing the game's allocator
  with a native function matches B3), OAR/DAR (hook the behaviour graph character load).
- Hard (heavy Havok, hand and body control, per-frame hooks into the VR pose pipeline): VRIK, HIGGS, PLANCK. They install many hooks and read/write OpenVR poses directly. They depend on the
  same openvr_api.dll path xrizer already serves, but they also call vtable entries in the game's VR code and use Havok internals. These are the high-value VR mods (body, hand grabbing, physical combat), and the highest risk.
- Physics add-ons (hdt-SMP, CBPC): hook per-frame update paths and run heavy math. They add CPU cost on a headset.

### (c) Renderer-level mods (ENB, ReShade, Community Shaders, vrperfkit)

- Proxy DLLs (d3d11.dll, dxgi.dll): found first by the loader if placed next to the exe (loader.c:532-590). They need an AOT module (hash-keyed) like any DLL. They then call the real d3d11/dxgi (ours) through
  imports. The calls are ordinary D3D11 API calls, so our renderer receives them: more draws, their own HLSL compiled at runtime with D3DCompile.
- Blocker for runtime shader compilation: ENB, ReShade and Community Shaders compile HLSL at run time (D3DCompile in d3dcompiler_47.dll) or ship precompiled DXBC. On visionOS we translate DXBC to MSL
  from an offline manifest (VISIONOS_PORT.md:228-240). Prepare-time pipeline: run the mod once on the Mac, log every DXBC hash (the existing `VXRT_SHADER_MANIFEST` flow records one line per cache miss), add them to the manifest.
  The manifest scheme works only if the full shader set is finite and known ahead, which holds for fixed ENB presets and ReShade presets, but not for user editing shaders on the device.
  Community Shaders precompiles/caches its shader permutations in a disk cache [know]; that cache can be harvested on the Mac.
- Performance: the GPU is already the limit at 17 compositor frames/s (git log 569bad4). Heavy post-processing (ENB SSAO/DOF/volumetrics) is not affordable on the headset. Light ReShade (sharpen, colour grade) is plausible later.
- Foveation: the recent branch applies foveated rendering to D3D11 scene passes (commit 60ef4ec). A mod that adds its own passes will not be foveated by default; its SV_Position use may break the warp/unwarp logic. [inferred]
- vrperfkit style tools (fixed foveated, upscale): redundant, since the port has its own render scale and foveation levers.
- Community Shaders for VR is the only graphics mod family that is VR-aware and is an SKSE plugin, so it also needs B (the plugin side) in addition to C.

Value: high visually, but medium on the headset because of the GPU budget. Effort: high (needs B first for CS; proxy DLL only for ENB/ReShade).

### (d) Off-device tools (stay on the Mac, no port work)

Nemesis/Pandora/FNIS (behaviour generation writes HKX files into Data: data from the game's view), xEdit/SSEEdit and patches, DynDOLOD/TexGen, BodySlide, LOOT, Wabbajack, MO2 as an installer: all produce data
that the overlay then carries. Notes:
- MO2's USVFS and Vortex's hardlinks exist to avoid copying; on our side, the overlay copy or a flattened output (MO2 "export"/Wabbajack install to a plain Data folder) replaces them. Running MO2 itself requires a Windows environment;
  on a Mac the practical way is Wabbajack or MO2 under another system, or running MO2 through VXRuntime, then copying the result [know]. The runtime on device must not need USVFS (it hooks file APIs inside the child process; unrelated to us, since we own the file layer, files.c).
- Wabbajack lists are Windows tools and download from Nexus with a Premium account for automation. That's an install-time user task, and any downloaded content is the user's own, so it remains in private directories per AGENTS.md.
- Anything these tools patch inside the exe (SKSE preloaders, "4GB patch") is class (b).

## 4. Ranking by value against effort

| Rank | Item | Value | Effort | Blocking dependencies |
| --- | --- | --- | --- | --- |
| 1 | Loose files, ESP/ESL/ESM, BSA mods, plugins.txt, texture/mesh/quest/follower/armour mods | Very high (most of any list's content) | Low | Overlay presentation and plugin list; memory budget on device |
| 2 | SKSEVR core + Address Library + simple plugins (PapyrusUtil, SkyUI VR, Spell Wheel VR, Tweaks) | High (SkyUI/spell wheel are expected by almost every VR user; many mods require SKSE) | High, but feasibility spike is cheap | Decision among B1/B3 and patch-site extraction |
| 3 | Engine Fixes VR and similar allocator/crash fixes | Medium to high (stability/perf) | Medium once (b) works | B3 native replacement |
| 4 | VRIK, HIGGS, PLANCK | Very high for VR feel | Very high | (b) fully working, xrizer pose paths, Havok internals; real headset playtest only |
| 5 | OAR/DAR and Nemesis output | Medium | Medium | (b) plus data |
| 6 | ReShade (light), vrperfkit | Low to medium | Medium | proxy DLL AOT, shader manifest extension |
| 7 | ENB, Community Shaders | Medium visual, GPU-limited | High | Proxy DLL/CS + manifest, GPU budget |
| 8 | MO2 USVFS/Vortex on device | None needed | n/a | Replace by flattened output |

## 5. Recommended first steps

1. Overlay-first data mod support (low risk, no AOT change). Define a private "mods overlay" layout: Data/ loose files and ESP/ESL/BSA under the
   VXRT_OVERLAY shadow of the install's Data, a plugins.txt in the emulated AppData, and an install-time Mac script that flattens an MO2/Wabbajack profile into it (priority resolved off-device).
   Test with a harmless owned-fixture style mod (one retextured asset plus one tiny ESP), checking the game reads it (file access log) and no new AOT miss appears. Verdict level: actual game on the Mac; headset later. Extend the overlay from a single tree to a list only if needed.
2. Measure the memory and miss impact: run a mid-size texture/mesh list on the Mac with strict AOT and the shader manifest recorder, to see new DXBC hashes and exe AOT misses (RECOMP.md profile loop). This sizes the device budget before promising more.
3. SKSEVR feasibility spike on the Mac development path only. With the translator engine allowed on Mac (explicitly labelled development reference), run SKSEVR 2.0.12 with a logging build of
   VirtualProtect/WriteProcessMemory/stores into the image range (hook points: kernel32.c:1378, client.c:648). Record every code write the SKSE core and one plugin make, and every executable allocation. The output answers the real question: are the patches static
   (B1/B3 viable) and how many generated trampolines exist. Needs the user to supply SKSEVR from their own download; do not fetch it for them.
4. Decide the AOT design from step 3: either a "patched exe" prepare step (B1) with extra module for trampolines, or intercept entries in vxrt-aot (B3), plus the in-process SKSE loader (B2). Prototype with PapyrusUtil only (no hooks) first, then one hook plugin; success is zero-fallback strict AOT and the plugin's log line in the game.
5. Only then: renderer-level proxies (ReShade light first) by AOT'ing the proxy DLL and extending the shader manifest from a Mac run, and the heavy VR plugins (HIGGS/VRIK/PLANCK) with a human physical-headset playtest (AGENTS.md: only a human physical playtest establishes playable).

## 6. What is verified and what is not

Verified in our code: no SKSE/plugins.txt/ESP handling exists; overlay semantics (files.c:137-150); DLL search through overlay (loader.c:575-590); hash-keyed AOT modules and strict stop
(loader.c:856-858, aot.c:480-490); VirtualProtect is a bookkeeping call (kernel32.c:1378-1395); no engine/SMC on visionOS (engine_nojit.c:44-45, VISIONOS_PORT.md:43); shader manifest source (VISIONOS_PORT.md:228-240).
From the web: SKSE VR version and plugin directory; CommonLibSSE-NG VR support and Address Library need; Community Shaders SKSE plugin with AE/SE/VR target; vrperfkit dxgi.dll proxy; MO2 VR game plugin and usvfs split.
Not verified (background knowledge or inference): popularity and endorsement ranking, which mods depend on which hooks, SKSE's actual patch mechanism details, Address Library file format use, whether
the translator's interpreter option is allowed by policy, ENB/Community Shaders runtime shader compilation behaviour on Skyrim VR, and any claim that a given plugin works under xrizer.
Open questions for the user: (1) may we run SKSEVR on the Mac development path to log patches, (2) is a small x86 interpreter for runtime-written code acceptable under the "no runtime CPU code generation" rule, (3) target mod budget (memory/GPU) on the headset.

## 7. The interaction trio: VRIK, HIGGS, PLANCK

Subject: static reading of the plugins' public source via the GitHub API into /tmp (not into the repo), plus code reads here. Nothing run.
Tags as before. The reads below are of adamhynek/higgs `src/hooks.cpp`, `src/main.cpp`, `src/haptics.cpp`, `src/vrikinterface001.cpp` and
adamhynek/activeragdoll (PLANCK) `src/main.cpp` (https://github.com/adamhynek/higgs , https://github.com/adamhynek/activeragdoll). Both are GPL-3.0 [web].
Last pushes per the API: HIGGS 2026-05-15, PLANCK 2026-10-14 [web]. (The user's "updated Jan 2026" for HIGGS was not seen; the API shows later pushes.)
Counts are grep counts of call sites in those files, so approximate (they include a few helper definitions).

### 7.1 Dependencies and versions (verified in source)

| Plugin | Runtime target | Depends on | Notes |
| --- | --- | --- | --- |
| HIGGS | SKSEVR, refuses anything but VR game 1.4.15 (`higgs_main.cpp:1136`) | SKSE messaging; VRIK optional but checked: asks VRIK's interface by message and requires VRIK build >= 80400 (`higgs_main.cpp:1106-1107`, `higgs_vrik.cpp`) | Offers a C++ API, fetched in PostPostLoad (README [web]) |
| PLANCK | same check (`planck_main.cpp:8398`) | HIGGS: includes `higgsinterface001.h` and calls `GetHiggsInterface001` (`planck_main.cpp:41, 8345`); detects VRIK with `GetModuleHandle("vrik")` (`planck_main.cpp:8319`) | README does not mention HIGGS [web]; the source does |
| VRIK | SKSEVR, closed source [know]; I could not read it | Not verifiable | Its build number and message API are consumed by HIGGS as above |

Important correction to the Address Library assumption in section 3(b): HIGGS and PLANCK do not use the VR Address Library. Their hook
locations are hardcoded `RelocAddr<uintptr_t>(0x...)` offsets from the exe base (HIGGS ~30 in `hooks.cpp:28-98`, PLANCK 38 `RelocAddr` plus 16 `RelocPtr` in `main.cpp`),
valid for the one VR build, which is the build we run (hash in tools/skyrim_aot_skyrimvr.json). They resolve through the base, so our rebase to 0x308000000 is
transparent provided GetModuleHandle(NULL) returns the rebased base. Address Library still matters for other plugins (Engine Fixes, CS) [web: CommonLibSSE-NG].

### 7.2 How they patch the game (verified in source)

| Kind of patch | HIGGS (`hooks.cpp`) | PLANCK (`main.cpp`) | Static-patchable before AOT? |
| --- | --- | --- | --- |
| rel32 call-site redirects (`Write5Call`, `Write6Call`) into a plugin function | 17 | 32 | Yes in principle: replace the call target; target is a plugin function whose module base is fixed at prepare time |
| rel32 jump redirects into Xbyak-generated stubs (`Write5Branch`, `Write6Branch`, `g_localTrampoline.StartAlloc` + Xbyak) | 12 (24 Xbyak code blocks, e.g. `hooks.cpp:960-1408`) | 7 (21 Xbyak mentions) | Only after capture: the stubs are generated at plugin load (save registers, call hook, replay displaced instructions, jump back). Capture the final bytes from a Mac run and add them as an extra AOT module |
| vtable slot swaps (`SafeWrite64`, `set_vtbl`) | 4 + 2: PlayerCharacter::Update, Missile/ArrowProjectile::UpdateImpactFromCollector, hkpCachingShapePhantom::setPositionAndLinearCast, bhkRigidBodyT vtbl (`hooks.cpp:1453-1504`, `:668`) | 14 | Yes, and easiest: a data write into the vtable. The AOT exe reads the pointer from memory at run time, so it already works as long as the new target is an AOT'd function |
| raw byte writes (`SafeWriteBuf`, `SafeWrite8`) | 3: a 7-byte NOP at 0x6AC012, a `ret` written at startGrabObject 0x6CC000, a size constant at 0x6B0828 (`hooks.cpp:1426-1448`) | 3 | Yes: apply to the PE bytes before translation |
| Havok calls used directly (not patching) | bhkWorld, ahkpWorld::LinearCast, bhkRigidBody ctor, collision-filter compare (`hooks.cpp:32-68`), hkpCharacterProxy integrate (`:97-98`) | heavy: rigid bodies, constraints, keyframing | n/a: ordinary calls into exe code at RVAs |

Totals: HIGGS roughly 35 code patches, 6 data (vtable) swaps; PLANCK roughly 45 code patches, 14 vtable swaps. Hook trampoline pool: each plugin asks SKSE for
a 1024-byte branch pool (`higgs_main.cpp:86-110`, `planck_main.cpp:8065`), so the generated code is small. A plugin's patch set is a fixed list of
sites for one exe build, not dependent on runtime state in the parts I read (the sites are unconditional apart from config/feature `if`s around a few, e.g. `hooks.cpp:1426-1464`).
That supports the static route: the sites are enumerable, finite and stable for the single supported build. What still needs a Mac capture is the Xbyak output (about 24 + 21 stubs) and the SKSE core's
own patches.

Not verified: VRIK's patch set (closed source). Its public behaviour (replaces the player body skeleton, drives 3rd-person nodes, holsters, gestures) implies
vtable/call hooks in PlayerCharacter::Update and skeleton updates, as HIGGS's `preVRIK*`/`postVRIK*` hook points hint (`hooks.cpp:42-52`, "before the vrik main thread hook"), but its code can only be
captured by running it on the Mac and logging the writes (section 5 step 3).

### 7.3 OpenVR calls they make, and xrizer coverage

How: HIGGS reads the game's own `BSOpenVR` object (`*g_openVR`, `higgs_main.cpp:125`, `higgs_haptics.cpp:11`) and calls through its `vrSystem` pointer, i.e. the game's `IVRSystem` obtained from
openvr_api.dll. There is no SKSE-side OpenVR hook in the code I read. Calls seen in HIGGS main/haptics:
`GetTrackedDeviceIndexForControllerRole` (left and right), `IsTrackedDeviceConnected`, the game's cached pose array (velocity and angular velocity from `TrackedDevicePose_t`, converted to Skyrim space `higgs_main.cpp:166-167`),
and `TriggerHapticPulse` (`higgs_haptics.cpp`). PLANCK repeats the role lookup and velocity use (`planck_main.cpp`, 4 role lookups).
xrizer (third_party/xrizer/upstream/src/system.rs) implements `IsTrackedDeviceConnected` (:784), `GetTrackedDeviceIndexForControllerRole` (:817), `GetDeviceToAbsoluteTrackingPose` (:874),
`GetControllerState` (:1003) and `TriggerHapticPulse` (:394, routed to `Input::legacy_haptic`) [code]. The provider forwards haptics to Sense per hand (commit d4ac931 "Merge controllers and haptics").
Open points: whether velocity fields in poses are populated with correct units/frames; whether a legacy `TriggerHapticPulse` of microseconds is mapped to a perceptible OpenXR amplitude/duration; and the guest ABI check for these calls
(AGENTS.md: verify through generated guest stubs). None of this has been run with these plugins.

### 7.4 Cost on the headset (not measured; reasoning only)

- Physics: all three drive Havok from the main thread each frame (HIGGS hooks the physics step and update timing, `hooks.cpp:65-89`; PLANCK adds constraint-driven rigid bodies per actor bone chain
  and extra raycasts/ phantoms). The game already runs Havok under AOT'd code. I have no measured per-frame CPU figure; the only budget evidence in repo is that the GPU is the limit at ~17 compositor
  frames/s (commit 569bad4), so CPU spare capacity is unknown. PLANCK's cost grows with the number of active ragdolls/NPCs in combat [know].
- visionOS specifics: no JIT, so every plugin DLL plus the Xbyak stubs must be in AOT modules (hash-keyed, loader.c:856-921); strict stop on any miss (aot.c:480-490). The plugins add roughly
  1-3 MB of DLL code each [know], against the device memory limit (RECOMP.md:135).
- Input: they use controller pose + velocity every frame. Velocity quality drives HIGGS throw/grab feel. Sense controller tracking supplies poses; our grip/aim offsets (commit d0759e1,
  "Klepton general Sense grip offset on grip and aim") shift the hand node, so the offset directly moves HIGGS's hand rigid body and VRIK's wrist target. Wrong offsets would show as arm length/body mismatch
  or objects grabbed off-hand. VRIK also asks the user to calibrate height/arm length in-game (body calibration) [know], which should absorb a constant error, not a pose-dependent one.
- Hand tracking as an alternative input: neither plugin has finger or hand-tracking awareness beyond buttons and the Oculus/Index finger curves (`finger_curves.cpp`, 130 KB, drives finger animation from controller
  axes [web: file name]). Hand tracking would have to be mapped into controller-like poses, velocity and button states by xrizer or the provider. Not recommended until controller path works.
- Haptics: HIGGS fires pulses on touch/grab (`haptics.cpp`); with Sense, haptic latency/amplitude mapping needs a device test.

### 7.5 Verdict and smallest milestones

Verdict. Feasible in principle, and better than the generic SKSE worry suggested, for this reason: HIGGS and PLANCK patch a single known exe build with fixed offsets, in finite sets of about 35 and 45 code patches
plus vtable swaps, and the source is open (GPL-3.0, so a prepare-time pipeline that patches and AOTs it is within the repo's GPL policy, but note the source requires Havok-2010.2-like headers
the author does not supply, so we use the author's released DLLs from the user's own download, not rebuilds). Static patching is plausible; the hard parts are SKSE core's own patches, the Xbyak stubs, and VRIK (closed, unreadable, but it must be captured the same way).
Real playability can only be established by a human physical-headset playtest; physics CPU cost is unknown.

Smallest first milestones, in order:
1. Mac-only, labelled development reference: run SKSEVR 2.0.12 + HIGGS (no VRIK) under the existing translator with a write logger on VirtualProtect/WriteProcessMemory/stores into the exe
   image and executable allocations. Output: the list of code-byte diffs and Xbyak stub bytes, compared against the ~35 sites enumerated from `hooks.cpp`. Pass condition: every logged write matches a source site, no unexpected ones.
2. Static replay on the Mac: apply that diff to a private copy of the PE, AOT the patched exe plus the SKSE and HIGGS DLLs plus a stub module, run strict AOT: HIGGS logs its load line, zero fallback, no runtime code writes.
3. A fixture round-trip for the OpenVR calls HIGGS makes (role lookup, connected, pose velocities, haptic pulse) through the generated guest stubs against xrizer, with the Sense fixture.
4. Only then add VRIK (capture first), then PLANCK; then a physical-headset session for feel, grip offsets and frame cost.

## 8. Findings from the user's downloads (2026-11-11): HIGGS 1.10.10, PLANCK 0.8.2, SkyUI

Subject: static reading of the zip files in `~/Downloads` (listed and parsed in memory by `python3 -I` scripts kept outside the repo; nothing extracted or run). Complements section 7, which read the source. Combined plan: [plans/2026-11-11-skyrim-mods-combined.md](../plans/2026-11-11-skyrim-mods-combined.md).

### 8.1 HIGGS 1.10.10 and PLANCK 0.8.2 [measured]

| | HIGGS 1.10.10 | PLANCK 0.8.2 |
| --- | --- | --- |
| Archive | `HIGGS 1.10.10-43930-1-10-10-1768263289.zip`, 11 entries | `PLANCK 0.8.2 66025 ... .zip`, 10 entries |
| DLL | `SKSE/Plugins/higgs_vr.dll`, 877,568 bytes, x64, PE time stamp 2026-01-13 | `SKSE/Plugins/activeragdoll.dll`, 736,768 bytes, x64, time stamp 2026-10-12 |
| Exports | `SKSEPlugin_Query`, `SKSEPlugin_Load` (old SKSE plugin API, so SKSE VR 2.0.12 style; no `SKSEPlugin_Version`) | same |
| Imports | KERNEL32 (112), USER32 (`MessageBoxA`), SHELL32 (`SHGetFolderPathA`), WINMM (`timeGetTime`, `timeBeginPeriod`, `timeGetDevCaps`). No OpenVR, no Address Library DLL | KERNEL32 (98), same others |
| Notable kernel32 | `VirtualProtect/Alloc/Free/Query`, `GetModuleHandleA/W/ExW`, `GetProcAddress`, `LoadLibraryExW`, `RtlVirtualUnwind`, `SetUnhandledExceptionFilter`, `CreateThread/ExitThread/FreeLibraryAndExitThread`, `GetPrivateProfileStringA` | same minus the thread functions |
| Data files | `higgs_vr.esp` (TES4, form 44, not ESL, masters Skyrim.esm and Update.esm), `Scripts/HiggsVR.pex` (+ `.psc`), `higgs_vr.ini` (593 lines), a 17.5 MB `.pdb` | `Scripts/planck.pex` (+ `.psc`), `activeragdoll.ini` (758 lines), a 17.5 MB `.pdb`; **no ESP** |
| Needs | SKSE VR (messages, task and Papyrus interfaces; "Couldn't get SKSE VR interface. You probably have an outdated SKSE version"); the ESP active; VRIK optional | SKSE VR; HIGGS (interface and minimum version); a branch trampoline **and a code-generation buffer** from SKSE (both fatal when missing) |
| Log files | via `Data\SKSE\Plugins\higgs_vr.ini` for settings | `\My Games\Skyrim VR\SKSE\activeragdoll.log` |

Strings in the release builds match the source reading of section 7: HIGGS reports hooks such as "PlayerCharacter::Update pre-vrik hook complete", "Actor::Jump bhkCharacterController::SetJumping hook complete", "ArrowProjectile::AddImpact bhkCollisionObject::GetRigidBody hook complete", "Adding listeners and collision to new havok world", Papyrus events for grab, pull, drop, stash, consume and two-handing; PLANCK has hook functions such as `BSLookAtModifier_modify_Hook`, `ahkpCharacterProxy_updateManifold_Hook`, `ActorProcess_ExitFurniture_ResetRagdoll_Hook` and RTTI of `hkbRagdollDriver`, `hkpContactListener`. This confirms the hook families; the exact byte sites of these two versions still need the Mac capture (the source I read in section 7 is a later push than the HIGGS build date: the API showed 2026-05-15 for HIGGS, the DLL is 2026-01-13, so the site list could differ by version) [inferred].

### 8.2 What our runtime needs to load them

1. **A Plugins.txt and ESP layer.** HIGGS stops if its ESP is not active. In the Mac trace the game tried `C:\users\vxrt\AppData\Local\Skyrim VR\Plugins.txt` and failed to open it [measured]; nothing writes it. M0 of the combined plan.
2. **An in-process SKSE VR.** The loader (`skse_loader.exe`) starts the game suspended and injects `sksevr_1_4_15.dll`; neither step exists for us (`posix_spawn` refused on visionOS, `VISIONOS_PORT.md:308`; no remote thread). The core DLL then patches the exe (Papyrus registration, game-start and save/load hooks, Scaleform, messaging). Under strict AOT the translated exe never reads its own code bytes, so those writes must be captured and baked in (option A), or the exe translated with patch slots (option B/catalog).
3. **AOT of the plugin DLLs** with the same pipeline as the game DLLs (`tools/skyrim_aot_pipeline.py`); both are plain x64 DLLs with a small import set, no TLS callbacks were checked [unverified: `.tls` directory and static constructors need a look when the DLL is first translated].
4. **The generated stubs**: HIGGS and PLANCK write Xbyak code into the SKSE codegen buffer at load; capture it on the Mac and ship it as an extra AOT module whose addresses match (fixed base).
5. **Address Library**: not needed by these two. Needed only by other plugins.
6. **Havok, player character, controller input**: all inside the exe at fixed offsets (called or hooked); controller input is the game's cached `IVRSystem` pose array and role lookups, which xrizer implements (section 7.3). No new OpenVR hook.
7. **A guest ABI check** for the calls HIGGS and PLANCK make through the game's `IVRSystem` (haptics, velocities), per `AGENTS.md`.

### 8.3 SkyUI package [measured]

`SkyUI-12604-6-11-1778020881.zip`: two entries. `SkyUI_SE.esp` (2433 bytes, TES4 flags 0x200 = **ESL**, form version 44, HEDR 1.70, master Skyrim.esm, SNAM "SkyUI SE 6.0") and `SkyUI_SE.bsa` (2.9 MB, v105, flags 0x3, uncompressed; 71 files: 47 SWF, 12 PEX, 11 text, 1 DDS). The SWFs replace vanilla menus (inventory, magic, barter, container, gift, favorites, crafting, map, quest journal, start menu, HUD, loading, message box, ...) and add `skyui/` panels, icon sets and MCM (`configpanel.swf`, `mcm_splash.swf`). The scripts are `ski_main`, `ski_configbase`, `ski_configmanager`, `ski_configmenu`, `ski_favoritesmanager`, `ski_settingsmanager`, `ski_widgetbase`, `ski_widgetmanager`, `ski_activeeffectswidget`, `ski_questbase`, `ski_qf_configmanagerinstance`, `ski_playerloadgamealias`. There is no `*vr*` file name; whether this is the VR-usable build is for the user to confirm on the Nexus page [unverified].

SKSE dependency, measured in the data: `SKI_Main.pex` has the error constants `ERR_SKSE_MISSING`, `ERR_SKSE_VERSION_RT`, `ERR_SKSE_VERSION_SCPT`, `ERR_SKSE_BROKEN`, `MinSKSERelease` and the messages "The Skyrim Script Extender (SKSE64) is not running", "SKSE64 is outdated", with `GetVersionRelease`; 15 SWFs contain the `skse` identifier (inventory 12, magic 12, container 12, map 11, configpanel 11, crafting 10, barter 10, gift 10, favorites 9, inventorylists 9, mapfinderpanel 9, bottombar 5, itemcard 5, widgetloader 2, activeeffects 3, plus single references in start menu, message box and quest journal); the Papyrus uses `UI.Invoke`, `InvokeBool/Int/String/...A`, `RegisterForModEvent`, `SendModEvent`, `RegisterForMenu`. So: without SKSE the SWFs may load but the menus lose their extended data, and `SKI_Main` shows its error box. They do not work usefully without SKSE; they need from the SKSE core only (a) the Papyrus natives `SKSE`, `UI`, `ModEvent`, menu registration, (b) the Scaleform `skse` object and `ExtendData` hooks. Both live in the SKSE core DLL, no per-game-site patches of SkyUI's own.

### 8.4 SkyUI, data side through `--mods-dir`

The BSA loads automatically because its name matches the ESP (`SkyUI_SE.esp`/`.bsa`) when the ESP is active [community]; both files are top-level entries of `Data/`, which `--mods-dir` already links as symlinks (the lever links any top-level entry; `tools/skyland_flatten.py` refuses `.esp/.bsa` on purpose, so a general flattener is needed, M0). Needs: `Plugins.txt` with `*SkyUI_SE.esp`; the ESL flag solved (the VR exe has no light-plugin support [community]: either the "Skyrim VR ESL Support" plugin or a private copy of the ESP with bit 0x200 of the TES4 flags cleared; check the record list first); the game's `Interface/Translations` lookups find `skyui_se_english.txt` inside the BSA. Scaleform rendering of the extra SWFs is the game's own code path (the vanilla `interface` BSA is already used), so no new renderer work is expected [inferred]; the VR menus are drawn on the game's own VR UI quad.

### 8.5 Phasing of SkyUI (also in the combined plan)

After the data layer (M0) and the SKSE core (M1/M2), before HIGGS: SkyUI needs no exe patches of its own, so it is the cheapest consumer of the SKSE bootstrap and the first end-to-end proof of Papyrus natives and Scaleform extension. Acceptance: Mac strict AOT, no `ERR_SKSE_*` box, MCM page opens and saves a setting to the overlay; the headset check is a human opening the menu with the Sense controllers and reading it.

## 9. Skyland on the Mac: loose-file proof, A/B, full-install smoke (2026-11-11)

Subject: actual game on the Mac development host (strict AOT, `--experimental-xrizer`, synthetic head, Helgen cart intro with the scripted pad, empty `sIntroSequence` through `--overlay-ini`), **not a headset**. Runtime built from this branch; AOT set `aot-fpcr-d5b2320`; shader cache a private clone of the 10,807-entry cache (no `pending/` appeared in any run, so no new shader was needed). Texture bytes are summed from `VXRT_TRACE_TEXTURES` lines (`Direct3D: texture WxH ... mips M format F`), BC block sizes from the DXGI format, all mips; the host is not paced by a display, so its frame rate is a throughput proxy and noisy. Logs: `build/mods-<label>/startup.log` in the worktree (git-ignored); runs list `/tmp/claude/perf/mods/runs.log`.

### 9.1 Loose files override the BSAs with no ini change [measured]

| Run | Mods | What the trace shows |
| --- | --- | --- |
| P0 | none | `GetFileAttributesEx(...\data\TEXTURES\): error 2`, same for `MESHES`: the game probes the loose directories at start and finds none |
| P1 | one file, `Textures/Landscape/dirt01.dds` (from Skyland) | `data\TEXTURES\` found; `FindFirstFile` lists `Landscape\` and `dirt01.dds` (size 699192 = the mod's file); later `CreateFile(...\data\TEXTURES\Landscape\dirt01.dds): opened`. No `[Archive]` key was set |
| S1 | full install (below) | 414 loose texture opens and 314 loose mesh opens, `Plugins.txt` opened, both ESPs opened (`fopen(...\DATA\Lit Road Signs.esp)`); the game also looked for `data/Lit Road Signs.ini`, i.e. it registered the plugin |

So `--mods-dir` works for textures, meshes and ESPs, and `bInvalidateOlderFiles` / `sResourceDataDirsFinal` are not needed (the section 2 assumption holds for VR 1.4.15 on our runtime).

### 9.2 A/B, tier 1 (Landscapes + Whiterun, 516 files, 661 MB), 150 s each, order A B B A

| Run | Mod | Textures created | BC bytes | Other bytes | Total | Frames / s (proxy) | Fallbacks | Footprint max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | no | 2517 | 1467 MB | 686 MB | 2153 MB | 6001 in 141 s (42) | 0 | 6439 MB |
| B1 | tier 1 | 2570 | 1478 MB | 690 MB | 2168 MB | 8274 in 142 s (58) | 0 | not captured |
| B2 | tier 1 | 2568 | 1480 MB | 690 MB | 2169 MB | 8545 in 143 s (60) | 0 | not captured |
| A2 | no | 2542 | 1489 MB | 682 MB | 2171 MB | 9871 in 144 s (69) | 0 | not captured |

Reading: **texture memory created is the same with and without the mod (2153 to 2171 without, 2168 and 2169 with; the spread between the two identical no-mod runs is 18 MB)**, in this scene (Helgen forest, the part of the world the tier-1 files cover least). The frame-rate proxy ranges overlap (42 and 69 without, 58 and 60 with) and cannot show a difference; it is not a measure of the headset. Footprint: only A1 was captured correctly (6.3 to 6.4 GB; my sampler matched the Python wrapper in the other three runs: a sampler bug, fixed afterwards). A planned B3/A3 pair was refused by the harness (`user_not_playing`: another agent's `vxrt-d3d11-replay` was running), not overridden. No crash in any run (exit by the harness time limit).

### 9.3 Full install smoke, S1 [measured]

Install: `tools/fomod_auto.py` applied the FOMOD's own choices into `build/private/mods/skyland-aio-1k-full` (APFS clones; df before and after: 82.99 GB and 83.00 GB free). Rules: every option of a SelectAny group; the first (preselected) option of an exclusive group, which gives Tan Granite Mountains (4096x4096, the "default" variant), Skyking Galaxy night sky (4096x2048), Grey towns, Dirt Roads "No" and Snowy Stone Roads (the first options, no files), Blended Roads and the SMIM patch, all ten cities, forts, ruins, ships, tents, windows, road signs and lanterns, Dawnguard, Dragonborn and the road-sign add-ons except Point The Way (the FOMOD says it conflicts with Lit Road Signs). Plugins with official masters only: `Lit Road Signs.esp` and `Skyland Watercolor - Slow Green-Vanilla.esp` (the iNeed twin has the same size and records and is an alternative; the two RW2 ones are skipped). 34 LE-format NIFs removed and listed in `manifest.json` (not copied). Three tool logs in the download were not copied.

| Item | Value |
| --- | --- |
| Files | 2057 (1917 DDS, 138 NIF, 2 ESP) |
| Size | 2,632,276,741 bytes (2.45 GiB) |
| `Plugins.txt` | `*Lit Road Signs.esp`, `*Skyland Watercolor - Slow Green-Vanilla.esp` (SE-style; the game reads `C:\users\vxrt\AppData\Local\Skyrim VR\Plugins.txt`, which the runtime maps to `<root>/drive_c/users/vxrt/AppData/Local/Skyrim VR/Plugins.txt`) |
| Lite variant (no mountains, no night sky) | `skyland-aio-1k-full-lite`, 2049 files, 2,507,844,381 bytes |

S1 (200 s, tracing every open, so slower than the A/B runs): textures created 2583, 2157 MB (BC 1468 MB), 14,684 frames in 191 s, **0 fallbacks, no crash**, no new shader (`pending/` absent), footprint rose to a **maximum of 6688 MB** against 6439 MB in A1 (single runs, and S1 ran 50 s longer with all-opens tracing: +250 MB is an upper estimate of the difference, not a measurement of it). The full install again created the same texture bytes (2157 MB), so the first look suggests the cost is not in the textures this scene loads; the 4096x4096 mountain textures only load where the mountains are in view.

### 9.4 Eye crops (left eye, 1024x1024 raw RGBA dumped by the dev host)

`/tmp/claude/perf/mods/crops/` (private game imagery, not committed): `compare_A2_f6600_NOMOD_vs_B1_f5850_MOD.png`, `compare_A1_f5550_NOMOD_vs_B1_f6000_MOD.png`, `compare_A2_f6300_NOMOD_vs_B2_f5700_MOD.png` (no mod on the left, tier 1 on the right, a magenta bar between, a 600x400 crop of the lower scene) and the whole left eyes `A*_f*_lefteye.png`, `B*_f*_lefteye.png`. The pairs were chosen as the frames with the smallest 128x128 pixel difference between runs, because the cart's position at a given frame number differs between runs (the best same-config pairs, A1/A2 and B1/B2, differ by 7 to 10 of 255 on average, the same as no-mod against mod, so a pixel difference cannot be attributed to the mod; the eye can judge the rocks and road). First look at A2/B1: the boulders and the wooden cart parts differ in grain and contrast; the scene is dark fog and an unquantified claim of "better" is not made here.

### 9.5 Readiness for a headset try

Ready for a first device copy of the full tree, with these cautions: (1) the device file system is case-sensitive, so the build must contain the `files.c` change of this branch (overlay names looked up case-insensitively); the test for it passes on a Mac but only the device exercises it; (2) the footprint margin on the headset was about 1 GB at a 7.2 GB peak, the Mac showed up to +250 MB with the full install: use the lite tree first if `available_mb` falls under 400; (3) HIGGS, PLANCK and SkyUI need SKSE VR, which the runtime cannot load yet, so they are not in this run. Nothing here says the look or the frame time are acceptable on the headset.
