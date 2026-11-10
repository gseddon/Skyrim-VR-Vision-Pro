# Research: trying "Skyland AIO 1k" (texture mod) on the Skyrim VR runtime

Date: 10 November 2026. Subject: static analysis of the user's download plus code reading of this repository; nothing was run, nothing in the game install, the repo's other worktrees, the device or the private game copies was changed. Parent documents: [mods plan](../plans/2026-11-10-skyrim-vr-mods.md) (Phase 1, data mods), [mods research](2026-11-10-skyrim-vr-mods.md), [device readiness](../plans/2026-11-10-skyrim-device-readiness.md).

Evidence labels: **[measured]** = read from the download's bytes with a script run as `python3 -I` from outside the download (scripts in `/tmp/claude/perf/mods/scripts/`, not committed); **[code]** = read in this repo (file:line); **[community]** = general Skyrim knowledge not checked here; **[inferred]**; **[unverified]**.

## 1. What the mod is

Files (both from `~/Downloads`): `Skyland AIO 1k-34179-4-32-1700282181.7z` (1998 MB, 7z signature checked; Nexus SSE mod 34179, version 4.32, per the file name and `fomod/info.xml`) and the extracted folder `Skyland AIO 1k/` (2.9 GB on disk, 2299 files). No 7z tool is installed, so the archive was not listed or compared with the extracted folder; the research used the extracted folder only. [measured]

Layout [measured]: a **FOMOD installer** (`fomod/info.xml`, `fomod/ModuleConfig.xml`, both UTF-16; 69 `<plugin>` options, 46 screenshots) over 29 numbered sub-folders (`01_Granite Mountains`, `30_Skyland - A Landscape Texture Overhaul`, `40_Skyland Markarth`, `94_Windhelm` ... `131_Skyland Windows`). Inside each, files sit in inconsistent case (`Data/Textures`, `data/meshes`, `textures`). The FOMOD maps them with `<folder source=... destination=...>`. It is not a ready-to-copy `Data/` tree: the install step (picking options, merging, case) has to be reproduced by us without MO2 or Vortex.

Content, everything-in-the-folder totals (it includes mutually exclusive variants, so an actual install is smaller):

| Item | Count | Size |
| --- | --- | --- |
| DDS textures | 2059 | 3.05 GB |
| NIF meshes | 181 | about 0.5 GB of the folder (Blended Roads 66, Imperial Forts 38, Road-sign add-ons 31, ...) |
| ESP plugins | 5 | 25 KB to 105 KB each |
| BSA archives | 0 | no archives, **all loose files** |
| Screenshots, logs, xml | about 55 | 23 MB (the 3 `.log` files are Nexus-tool logs, ignorable) |

Texture formats [measured, DDS headers read for all 2059]:

| Format | Files | Bytes |
| --- | --- | --- |
| BC7_UNORM (DX10 header, DXGI 98, array size 1, no cube flags) | 1168 | 2.15 GB |
| BC1 (DXT1) | 738 | 0.70 GB |
| BC3 (DXT5) | 152 | 0.19 GB |
| Uncompressed 32-bit RGB | 1 | 6 MB |

Sizes [measured]: 1024x1024 1672 files; 2048x1024 or 1024x2048 180; 2048x2048 63; 512x512 36; **4096x4096 14; 4096x2048 or 2048x4096 11 or so**; smaller ones for the rest. Mip counts: 11 mips for 1672 files (complete chains down to 1x1); 12 or 13 for the 2k to 4k ones; 1 mip for 9 files. So "1k" is the dominant size, not a cap. About 1.5 GB of the folder is normal maps (`_n`), 26 MB glow (`_g`), 6 MB parallax (`_p`), 6 MB environment masks (`_m`).

The 4k files are the memory outliers [measured]: `01_Granite Mountains` (one variant ships `mountainslab01/02` 4096x4096 BC7 at 10.9 MB, their `mask` and `_n` at 21.8 MB each; one variant is about 110 MB of resident texture, and the whole folder holds six variants), `130_Skyland Night Skies` (three alternative 4096x2048 sky textures, 10.9 MB each), `92_Skyhaven Temple` (4096x1024 wall, 2.7 and 5.5 MB).

Compatibility with Skyrim VR [measured unless noted]:
- **SE format, so valid for VR** [community: VR shares the SE-era asset formats]. NIFs are version 20.2.0.7: 145 with user version 2 = 100 (SSE) and **36 with 83 (LE format)** in `11_Skyland HD Road Signs - Addons` (31), `90_`/`98_Skyland Towns and Villages` (2 each), `96_Dawnguard` (1). LE-format static meshes usually load in SE-engine games [community]; they are in optional folders and can be left out of a first test.
- **No SKSE dependency**: no SKSE folder, no DLL, no `.pex`, no `.esl`. The FOMOD has one flag dependency for options, no external mod dependency.
- **Plugins**: five ESPs, all `TES4` records with **flags 0x0 (not ESM, not ESL), form version 44, HEDR version 1.70** (the SE/VR header value), masters only `Skyrim.esm`, `Update.esm`, `Dawnguard.esm`, `HearthFires.esm`, `Dragonborn.esm`. The two RW2 variants additionally require `RealisticWaterTwo.esp` and `RealisticWaterTwo - Resources.esm`, which we will not have. So **no ESL, no VR-incompatible masters**, and plugin-wise only `Lit Road Signs.esp` (452 records), and one of the four Watercolor variants (`...Vanilla.esp` or `...iNeed.esp`), are usable; every ESP is optional and **the textures need none of them**. (VR needs an ESL-support plugin only for ESL-flagged files; none here.)
- Optional add-ons name other mods: "Falskaar", "Point The Way" (not compatible with Lit Road Signs, per the FOMOD text), "Cutting Room Floor", RW2, iNeed. Their textures are harmless without the mod (unused files).
- A texture-only replacement works through the game's file lookup by path; meshes shipped with the mod (Blended Roads, SMIM patch, Imperial Forts) are only needed where the mod's textures expect different UVs. SMIM-pathed textures (`Textures/SMIM/...`) are used only if the SMIM meshes are present.

Likely install sizes [inferred from the per-folder sizes above]: a "tier 1" of `30_Landscape` (446 MB) plus `110_Whiterun` (201 MB) is about 650 MB; the whole architecture and landscape set with one mountain variant, one towns variant, no add-ons and no sky is roughly 2.2 to 2.6 GB.

## 2. How our runtime finds game data

**Mac.** `tools/play_skyrim_dev.sh` runs `tools/vxrt_native_startup.py` with `--asset-root` = the read-only Steam install (`SKYRIM_ASSET_ROOT`, default `.../vxrt_steam/steamapps/common/SkyrimVR`, `play_skyrim_dev.sh:32`). The startup script makes a per-run `out/root`, `out/overlay`, `out/temp` and sets `VXRT_OVERLAY=<source>:<overlay>` (`vxrt_native_startup.py` around line 316; `source` is the common parent of the asset and DLL roots, so the game appears in the overlay as `out/overlay/SkyrimVR/...`; a previous run's overlay contained `overlay/SkyrimVR/Data/ShaderCache`). [code]

Overlay rules (`VXRuntime/src/files.c:137-150, 232-237`) [code]:
- A path under the install tree resolves to the overlay copy if the overlay has one (`stat(shadow)` succeeds, which follows symlinks), else the original. Directories stay the original when both exist; a directory only in the overlay is used. Directory listings merge both, the overlay winning on a name clash.
- The vanilla `Data/` holds the 24 ESM/BSA files plus `Interface/`, `Strings/`, `Video/` only (read-only listing of the install); there is **no `Data/Textures` or `Data/Meshes`**, so loose mod directories added to the overlay do not collide with an existing directory.
- The overlay is one layer, not a priority stack (same limit as in the mods plan), so the flattening has to be done before the run.

**Where `Data/` lives on the device.** `xros/app/Sources/main.m:357-370` (`skyrimvr_start`): the game folder is `VXRT_SKYRIM_DIR`, default `Documents/root/SkyrimVR`, holding `Data/`, the ini files and the prepared exe; `VXRT_OVERLAY=<that>:Documents/root/overlay_skyrimvr`. So the device equivalent of the Mac overlay is `Documents/root/overlay_skyrimvr/Data/...`. [code] On visionOS `vx_ci_path` (`files.c:36-60`) repairs path case against the real file names, but it starts from the original (non-overlay) path; for a mod directory that only exists in the overlay, a case mismatch would not be repaired, and the app container's APFS case rules are not checked. [code; unverified on the device]

**Loose files versus BSAs.** The game decides, not our runtime: it asks for `Data\Textures\...` paths and its own archive code reads BSAs. Evidence from our side: after the `.ini` fix, `.\Skyrim.INI` is read and opens 19 archives (the plan's status line); the `Skyrim.ini` shipped in the install has only an `[Archive]` list (`sResourceArchiveList`, `sResourceArchiveList2`) and no `bInvalidateOlderFiles` or `sResourceDataDirsFinal`. [measured, read-only] [community]: Skyrim SE/VR loads loose files over BSA contents without those keys (`bInvalidateOlderFiles` is an old Oblivion/LE fix; `sResourceDataDirsFinal=STRINGS\` is the stock default and is harmless for texture/mesh loose files in SE). Because this is the key assumption, the first test must prove it with `VXRT_TRACE_FILES` (the lever added in commit a27c799) before ini changes are considered.

**Can our ini overlay set the keys?** Yes, for `Skyrim.ini`: `--overlay-ini FILE:SECTION:KEY=VALUE` (`vxrt_native_startup.py` around lines 261-295) writes a per-run copy of a file in the asset root into the overlay with one key set; it can be repeated, and an empty value works (`play_skyrim_dev.sh:121` already uses `Skyrim.ini:General:sIntroSequence=`). So `--overlay-ini Skyrim.ini:Archive:bInvalidateOlderFiles=1` and `--overlay-ini Skyrim.ini:Archive:sResourceDataDirsFinal=` need no new code. Limits: it only edits files in the asset root (so `SkyrimVR.ini`/`SkyrimPrefs.ini` under `My Games` are not reachable; those come from `tools/prefs_seed/611670/...`, which only seeds `SkyrimPrefs.ini` today), and on the device there is no such lever yet (the ini would be edited in the overlay by hand). [code]

**plugins.txt.** Not needed for a texture-only test. If an ESP is wanted, the plan's Phase 1 item 1 applies (a `Plugins.txt` in the emulated AppData, under `root/drive_c/users/vxrt/AppData/Local/Skyrim VR/` [community path]); nothing in the repo writes one today. [code]

## 3. Options, most reasonable first

### A (recommended): Mac loose-file overlay, textures first, no game file touched

Add a `--mods-dir DIR` lever to `tools/vxrt_native_startup.py` and `play_skyrim_dev.sh`. DIR is a flattened, private mod tree (`DIR/Data/textures`, `DIR/Data/meshes`, optional ESPs). For each top-level entry in `DIR/Data`, the script symlinks it into `out/overlay/<asset path relative to source>/Data/<name>`; it records the entries and the content hash in the result JSON as a `diagnostic` (same pattern as `--saves-dir` and `--overlay-ini`). No game file, no code in the runtime changes. Pair it with `VXRT_TRACE_FILES` so the log shows the game opening the mod's files (the plan's Phase 1 deliverable 3).

Flatten step (a Mac script, new, in `tools/`, reading the FOMOD): apply a chosen option list, copy with APFS clones (`cp -c`, so the data costs no extra disk on the same volume), merge directories case-insensitively, copy into a **git-ignored private directory** (e.g. `build/private/mods/skyland/Data`). Never run anything from the download, read `ModuleConfig.xml` as data only, and keep the original in `~/Downloads`. The disk is 93 percent full (31 GB free), so use clones or move the mod there; do not keep two full copies plus the 7z.

Pros: fastest loop, shows the result in `play-*` output with existing tools, nothing is copied twice, testable A/B with the same save and the same location. The Mac run has no device memory limit, so it measures size, not the headset limit. Cons: the Mac result is a development reference (it proves file resolution, texture creation and look, not headset memory or frame time). Cost: 1 to 3 hours for the lever plus the flatten script (inferred).

Suggested option sets (from the FOMOD names): tier 1 = Landscapes (`30_`) + Whiterun (`110_`) ≈ 650 MB and a save standing in Whiterun's plains; tier 2 = all cities + Dawnguard + Dragonborn, no Granite Mountains, no Night Skies, no add-ons; tier 3 = everything chosen by the user, with a mountain variant. Leave out all ESPs in tier 1 and 2.

### B: pack into a BSA

Pros: one file instead of about 1500 small files (fewer opens and directory scans, a cleaner `devicectl` copy), BSA is the game's native format. Cons: a packing tool is needed on the Mac (BSArch and Creation Kit's Archive2 are Windows programs; `bsarch` has Linux builds, a macOS build is not known to me) [community, unverified for macOS]; the archive has to be listed in `sResourceArchiveList2` (the `--overlay-ini` can do that) or be named after an ESP; a texture BSA of 2.2 GB is near the SSE size ceiling [community: offsets are 32-bit]; archive priority against the vanilla ones is a separate thing to test; and it loses the "just see what the game opens" diagnostics of loose files. Only worth doing after A works and only if the device copy time or directory scans prove slow. No licence problem in packing the user's own downloaded files for private use; redistribution of the mod or of an archive derived from it follows the author's Nexus permissions, which were not checked (not our use).

### C: device (physical headset), only after A passes

Where: `Documents/root/overlay_skyrimvr/Data/` (see section 2), copied with `xcrun devicectl device copy to ... --domain-type appDataContainer --domain-identifier exampleprefix.VXRuntimeHost` (`VISIONOS_PORT.md:437`); Finder file sharing is on. Storage: the headset has 1 TB (`VISIONOS_PORT.md:439`), so 0.65 to 2.5 GB is no issue. Time: about 40 MB/s was the earlier measured rate (`VISIONOS_PORT.md:315`: 66 GB about 27 min), so about 20 s per 0.8 GB plus per-file overhead for roughly 1500 files: expect 1 to 3 minutes for 2.5 GB [inferred]. Steps: `devicectl` copy of the flattened tree into the overlay path, launch the Skyrim app with `-game skyrimvr`, read `Documents/host_log.jsonl` (`available_mb`, `footprint_mb` every 2 s) and `vxrt.log`. It needs the user's explicit authorization for physical-device installation and launch (`AGENTS.md`), and only a human can say whether it looks better or plays.

Memory estimate (the key risk). Facts: footprint peaks at about 7.2 GB with about 1 GB headroom (the user's figure; the app is limited to about 8.1 GB including Metal, `VISIONOS_PORT.md:305`, device-readiness 2c). Skyrim's own footprint on the device was **not recorded in the repo** (device-readiness 2c, line 89), so the 7.2 GB is the number to trust. The mod swaps textures one-for-one by path, so the question is size per replaced texture, not the count:

- A resident 1024x1024 BC7 with full mips is 1.40 MB; BC1/DXT1 0.70 MB; BC3 1.40 MB; 2048x2048 BC7 5.6 MB; 4096x4096 BC7 22.4 MB. The mod's average file is 1.48 MB. [measured arithmetic]
- Vanilla Skyrim VR textures: 31,828 files in nine `Textures*.bsa` totalling 7.5 GB; the two landscape/architecture archives that matter (`Textures1/2`) average 1.3 to 1.7 MB per file and `Textures3/4` 0.7 MB. [measured: BSA headers read-only] So Skyland 1k is **about the same size as the vanilla texture it replaces on average**, not smaller in the typical case, because vanilla SE already uses 1k and 2k BC7 (on a 1k-versus-2k basis it may be smaller for 2k vanilla sources, larger for 512 ones, e.g. 512 landscape or dungeon pieces that become 1024 are +4x). So the expected net change for a given view is small (single-digit to a few tens of percent of the texture working set) except for the 4k items. [inferred; this is the number that must be measured, not trusted]
- Worst offenders: a Granite mountain variant is about 85 to 110 MB resident whenever mountains are in view, and a 4k night sky is 11 MB. For the first device test choose "None" for mountains (the FOMOD has this option) or the Majestic Mountains variant (2048x4096 ones, 5 to 11 MB each) and no Night Skies.
- Budget suggestion for decision D3: allow at most +300 MB of resident texture memory on the headset (about 30 percent of the stated headroom) until a measured run says otherwise; abort a variant if `available_mb` drops below 400 MB in the Whiterun test.
- How to measure instead of estimate (Mac): the D3D11 path has `VXRT_TRACE_TEXTURES` (`d3d11.m:1841`) and `VXRT_STATS`; sum the bytes of textures created for the same save and spot with and without the mod, and compare the process footprint. The Metal pixel format for BC7 is native (`d3d11.m:178`), so created size is the BC size; whether Metal on the M2 stores it compressed (it should) is not measured. [unverified]
- No D3D11 equivalent of the D3D12 `VXRT_D3D12_TEX_DOWNSCALE` lever (device-readiness 2c) exists. If the measured delta is too large, adding "drop the top mip of sampled-only textures of at least 2048 texels" in `d3d11.m` `d3d_create_texture` is the safe fallback lever; the game's own `iTexMipMapSkip` in `SkyrimPrefs.ini` `[Display]` may also exist [community, unverified for VR].

### D: performance

The headset is pixel-bound (stated by the user; render scale 0.65 in commit 6d4e457), and a texture swap changes no shader, no draw count and no pixel count. The sampler cost depends on the mip chosen (screen footprint), not the source size, so sampled bandwidth hardly changes; only cache footprint and the first-touch upload do. At 0.65 render scale and 16x anisotropy (`d3d11_draw.m:491` default) most surfaces sample mip 1 or 2, so 1k-versus-2k quality differences are mostly lost; the visible effect is the photogrammetry colour and normal detail, not pixel sharpness. Streaming cost: each texture created in a cell load is a CPU copy of 0.7 to 22 MB into Metal (mip by mip); larger or more textures lengthen cell loads and can add hitches when textures stream in during movement. [inferred; measure with the existing frame stats]. The 36 LE-format NIFs and the added Blended Roads meshes add a little geometry only.

### E: shader manifest and cache

Textures do not change shader hashes. The 10,807-entry manifest (`tools/shader_manifests/skyrimvr-611670.tsv.gz`) and the metallibs are keyed by DXBC hash from the game's shader archive, a finite set (10,830 distinct per `VISIONOS_PORT.md:224`), so new content can only select among variants already in the game's files; at worst it requests a variant the manifest lacks, which compiles in-process once and is queued in `Documents/shadercache/pending` (a stutter, not a failure). Possible triggers: the mod's meshes with parallax (`_p`, 6 MB), environment (`_m`) or glow (`_g`) maps (7 and 6 MB of the folder, and Lit Road Signs' lights). Check by running the existing manifest recorder on the Mac (`VXRT_SHADER_MANIFEST=<file> tools/play_skyrim_dev.sh`) and diffing `pending/` after a Whiterun walk. Expected: none or a handful. [inferred]

## 4. Renderer blockers (D3D11 to Metal)

- **BC7 is mapped**: `d3d11.m:168-178` maps DXGI 70 to 99 to `MTLPixelFormatBC1..BC7(_sRGB)`; DXGI 98 (BC7_UNORM) is what every BC7 file here uses, and the table has it. BC1 and BC3 (71 and 77) are mapped too. [code]
- **Device support**: the on-device probe (2026-10-30) reported `bc:1`, GPU Apple M2 (Apple8), Metal 3, argument buffers tier 1, max buffer 8192 MB (`VISIONOS_PORT.md:108`, device-readiness 2d). Native BC exists on the headset; the BC refusal in `d3d11.m:320-331` is `#if VX_XROS_SIM` only. The visionOS simulator has no BC and no decoder is planned (plan `2026-11-10-skyrim-simulator-build.md`), so **the simulator cannot show any Skyrim texture, with or without this mod**; do not use it for this test. [code]
- **Mips and arrays**: all files are 2D, array size 1, not cube, mip chains complete down to 1x1 (11 to 13 mips). Metal accepts them; the D3D11 creation path takes the DDS mip count from the game (`d3d11.m:344`). Max size 4096 is far below Metal's limit. Device-readiness 2d lists the unverified items that Skyrim will hit regardless of this mod: mip levels below 4x4 in BC, sRGB BC views, `replaceRegion` with block rows. The mod's chains reach 1x1, so it exercises exactly those paths harder than a few vanilla textures would. [unverified on the device, and on the Mac the same paths already work for vanilla BC7]
- **Texture arrays**: none in the mod; the game's own texture arrays (terrain blending uses per-texture slots) are unaffected.
- **Not a blocker, but a check**: the 1 uncompressed BGRA file (6 MB) and the 9 one-mip files are fine.

## Recommendation and next steps

Recommended option: **A**, with tier 1 (Landscapes + Whiterun, no mountains variant, no ESPs) as the first content, then the headset (C) only after the Mac A/B has a measured texture-byte and footprint delta.

1. Build the lever and the flattener: `--mods-dir` in `play_skyrim_dev.sh` and `vxrt_native_startup.py` (symlinks into `out/overlay/.../Data`), plus a Mac script that reads the FOMOD, applies the chosen options and clones the files into a git-ignored `build/private/mods/skyland/Data`. First prove loose-over-BSA with a one-texture owned test mod (the plan's Phase 1 (a)) and `VXRT_TRACE_FILES`, before the Skyland tree; only then add `--overlay-ini Skyrim.ini:Archive:bInvalidateOlderFiles=1` and an empty `sResourceDataDirsFinal` if loose files are not picked up.
2. Mac A/B on tier 1: same save in Whiterun's plains, with and without the mod, alternating (A B B A): sum `VXRT_TRACE_TEXTURES` bytes, footprint, fps, shader `pending/` diff and zero strict-AOT fallbacks. If the delta is above +300 MB, trim tiers or add the D3D11 top-mip drop lever.
3. Ask for authorization for a physical-headset copy and launch of the tier that passed: `devicectl device copy to` into `Documents/root/overlay_skyrimvr/Data`, then compare `host_log.jsonl` `available_mb` and `footprint_mb` against the 7.2 GB baseline; a human judges the look.

## What stays unverified

Everything about the running game. Not checked: whether loose files override BSAs in Skyrim VR without ini keys; the real texture-memory delta; Metal's stored size of BC7 on the M2; the device's case handling for overlay-only directories; the archive's contents against the extracted folder; the mod's Nexus permissions; macOS tools for building BSAs. Texture look and playability: only a human headset playtest.
