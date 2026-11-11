# Skyrim VR on Vision Pro: from a fresh clone to the game on your headset

Status: a development checkpoint, not a release. Nothing here makes Skyrim VR "playable" on its own; that is only
established by a person playing on a headset (AGENTS.md). Everything derived from your game stays on your machine
(git-ignored, never committed or shared). You need your own legal copy of Skyrim VR.

## What you need

- An Apple-silicon Mac, macOS 14 or newer, about 40 GB free.
- Xcode 26.x with the visionOS platform (Xcode > Settings > Components), and `brew install xcodegen`.
- A **paid** Apple Developer Program team: the app needs the `extended-virtual-addressing` and `increased-memory-limit`
  entitlements, which free teams are not granted (not tested with a free team).
- A Vision Pro in Developer Mode, paired with Xcode, on the same network. Two PS VR2 Sense controllers paired to it (the
  only wired controller path today).
- Skyrim VR (Steam app 611670, the Windows build) and SteamVR (app 250820, for `msvcp140.dll`), downloaded on your Mac
  with `tools/vxrt_steam.py fetch <steam-login> 611670 250820` (SteamCMD asks for your password and Steam Guard; Steam
  confirms ownership) or copied from a library you already have. The game must be the pinned build (the doctor checks).

## 1. Your settings (once)

```sh
mkdir -p local && cp local.example.sh local/env.sh      # local/ is git-ignored
$EDITOR local/env.sh        # XROS_TEAM_ID, XROS_BUNDLE_PREFIX, VXRT_DEVICE_ID, SKYRIM_ASSET_ROOT, STEAMVR_WIN64_DLLS
python3 tools/vxrt_build.py doctor                       # what is still missing, and how to fix it
```

`tools/vxrt_build.py`, the doctor and the helper scripts read `local/env.sh` themselves; for plain `make` run
`. local/env.sh` first. The device id is the Identifier column of `xcrun devicectl list devices`.

| Variable | Meaning | Default |
| --- | --- | --- |
| `XROS_TEAM_ID` | Apple team (10 characters); required for a signed build | none: a signed build stops with a message |
| `XROS_BUNDLE_PREFIX` | reverse-DNS prefix; the app is `<prefix>.SkyrimVR` | `dev.example.vxrt` (cannot be signed) |
| `VXRT_DEVICE_ID` | your headset, for install, staging and the device helper scripts | none |
| `SKYRIM_ASSET_ROOT` | your `SkyrimVR` folder (read only) | none |
| `STEAMVR_WIN64_DLLS` | SteamVR `bin/vrwebhelper/win64` (read only) | none |
| `VXRT_PRIVATE_ROOT` | everything derived from your game | `build/private` |
| `VXRT_SKYRIM_DIR`, `VXRT_AOT_INPUTS`, `VXRT_REDIST_DIR` | prepared exe, pipeline DLL inputs, redistributables | under `$VXRT_PRIVATE_ROOT/skyrimvr/<sha>` |
| `XROS_GAME_FW`, `XROS_SHADER_DIR` | compiled modules, shader set | `$VXRT_PRIVATE_ROOT/game_fw-xros`, `.../shadercache-xros-manifest` |
| `XRIZER_RUST_ROOT` | Rust toolchain | `build/toolchains/xrizer-rust` |

## 2. The stages

Each is `python3 tools/vxrt_build.py <stage>`; each is safe to run again (a finished stage does nothing; `--force`
redoes it) and exits 2 with a message naming the missing input. `python3 tools/vxrt_build.py list` shows their state.

| Stage | What it does | Downloads? |
| --- | --- | --- |
| `toolchain [--with-steamless]` | `tools/setup_rust.sh`: Rust 1.99.1, the three Apple targets, `cargo fetch --locked`. With `--with-steamless`: Steamless (commit `cd770bf`, CC BY-NC-ND 4.0) and a private .NET SDK 8.0.427 built under `$VXRT_PRIVATE_ROOT/skyrim-tools`; prints the download list and goes ahead (`--confirm` asks first) | yes (rust-lang.org, crates.io, github.com, dot.net, NuGet) |
| `prepare` | removes the SteamStub wrapper from a copy of your `SkyrimVR.exe` with Steamless, requires the result to be exactly the pinned `8daf0519...` (input `6961efb4...`), copies the DLL inputs and checks each against its pin | no |
| `aot` | compiles the prepared exe and DLLs to ARM64 frameworks for the headset arena (`tools/skyrim_aot_pipeline.py --target xros`, config template `tools/skyrim_aot_skyrimvr.json`) | no |
| `shaders` | builds the Metal shader set from the committed hash manifest and your own `Skyrim_VR - Main.bsa` (about 5 to 25 minutes depending on load: the Metal compile of about 10,800 libraries, one process per core) | no |
| `app` | `make XROS_XRIZER_GAME=1 XROS_SDK=xros xros-app`, signed with your team; `--install` installs it on the headset, `--unsigned` skips signing | no |
| `stage-to-device` | copies the game tree (about 14 GB) into the app's container: dry run, then `--run` | no |
| `mods-fetch` | gets the Nexus Mods files named in a mods list (see below): from your Downloads folder after you download them in the browser, or through the API with an optional `NEXUS_API_KEY`; pins their md5 in the list and unpacks them under `$VXRT_PRIVATE_ROOT/mods-src` | only with a key (api.nexusmods.com and its CDN) |
| `mods` | builds a data-only mod pack from a mods list (`tools/mods.py`); `--deploy` copies it | no |

Typical first run: `toolchain --with-steamless`, `prepare`, `aot`, `shaders`, `app --install`, `stage-to-device --run`. Then wear
the headset, open Skyrim VR, accept the motion-input permission on first launch, keep the headset awake.
The first signed build with a new bundle id may need `XROS_ALLOW_PROVISIONING=1` (Xcode creates the App ID).
If the unpacked exe hash differs from the pinned one, `prepare` keeps it under `prepared-unverified/` and stops: the AOT
modules are keyed by that hash.

## Mods from Nexus Mods

Instead of downloading mods by hand, name them in the mods list and let the tool fetch them:

```json
{ "id": "higgs", "name": "HIGGS", "kind": "skse", "priority": 40,
  "nexus": { "game": "skyrimspecialedition", "mod_id": 43930, "file_id": 123456 } }
```

`game`, `mod_id` and `file_id` are in the mod's URLs: `nexusmods.com/<game>/mods/<mod_id>?tab=files&file_id=<file_id>`.
`python3 -I tools/nexus.py files <game> <mod_id>` lists a mod's files. Most Skyrim VR mods are under the game `skyrimspecialedition`;
Nexus also has a `skyrimvr` game. Which one a given mod lives under is not checked by this tool; use the one in the mod's URL.
An entry has either `source` (a local prepared tree, as before) or `nexus`, never both.

Steps: `python3 tools/vxrt_build.py mods-fetch --list mods-list.json`, then `mods --list mods-list.json`. The fetch writes the md5
of each file into the list (`nexus.md5`), so later builds are reproducible and a changed or damaged file is refused. A mod whose
archive matches its pinned md5 and is already unpacked is skipped, without the network, the key or the Downloads folder. Archives are zip, or
(7z, rar) via macOS `tar`. A FOMOD installer archive is not unpacked blindly: the fetch stops and tells you to run
`tools/fomod_auto.py` on it and use the result as `source`. Copies land in `$VXRT_PRIVATE_ROOT/downloads/nexus/`.

**Default, no API key and no Premium: your browser downloads, the tool picks the file up.** For each mod not yet fetched, in order,
`mods-fetch` prints a numbered message ("[2 of 5 done]") with the mod's name from your list, the exact Files-tab page
(`https://www.nexusmods.com/<game>/mods/<mod_id>?tab=files&file_id=<file_id>`; in a terminal it offers to `open` it) and the steps: on the
file click **Manual download**, then **Slow download**. It then watches your Downloads folder (`VXRT_DOWNLOADS_DIR`, default `~/Downloads`)
for a finished archive (`.zip`, `.7z`, `.rar`; partial downloads such as `.crdownload`, `.download`, `.part` are ignored and the size must
stop changing). An archive that is already in the folder is taken at once, so downloads you made earlier work. Matching: by the md5 pinned in
the list when there is one; otherwise by the mod id in the file name (Nexus names files `<Name>-<mod_id>-<version>-<timestamp>.<ext>`),
after you confirm it in the terminal (without a terminal, pin the md5 or pass `--accept-name-match`). The archive is copied, never moved,
the md5 is pinned in the list, and the next mod is asked for. `--wait SECONDS` sets the wait per mod (600 in a terminal, 0 otherwise, which
means "take what is there, else exit 2 and say what is missing"); Ctrl-C skips a mod (exit 2 at the end lists the skipped ones; run it
again, finished mods are not redone). A file whose md5 differs from the pinned one is refused even if its name matches. Nothing is sent to
Nexus on this path; your browser does the download under your own login.

**Optional: an API key.** A personal key is free (nexusmods.com > your avatar > Site preferences > API Keys). It is not needed. With it,
`nexus.py validate` shows your account and Premium status, `nexus.py files <game> <mod_id>` lists a mod's files with sizes and checksums, and
`mods-fetch` uses the API: Premium accounts then download directly with no browser step at all, and sizes/md5 are verified against Nexus's
record. Put it in `local/env.sh` as `NEXUS_API_KEY` (see `local.example.sh`; a password manager's CLI works, for example 1Password with a field
labelled `apikey`). Nexus has no username/password API login, so a password does not work. The key is only sent to api.nexusmods.com, never
printed or committed. `--manual` forces the browser path even when a key is set. API downloads of non-Premium accounts need an nxm link
(below); that path needs the key too, because the download-link call requires it even with a link.

**With a key but without Premium.** For each file the API will not hand out, `mods-fetch` (and `nexus.py download`) prints a short
numbered message with the mod and file name, "[2 of 5 done]", the exact Files-tab page (`https://www.nexusmods.com/<game>/mods/<id>?tab=files&file_id=<id>`;
in a terminal it offers to `open` it for you) and the instruction to click "Mod Manager Download" there. It then waits (`--wait SECONDS`,
default 600 in a terminal; 0, meaning "exit 2 and say what is missing", when not run from a terminal) for that file's link, and Ctrl-C
skips the file (the run ends with exit 2 listing what was skipped; run it again later, finished files are not redone). A link
for a different file is refused politely and kept in the queue for its own file; expired links are ignored. Links are accepted
from the queue directory `$VXRT_PRIVATE_ROOT/downloads/nexus/queue/` (mode 0700, links 0600), or pasted in the terminal. Premium
accounts never see any of this. Messages show ids only, never the key or the link's `key`/`expires`.

**The nxm handler (optional; needs an API key).** It only helps the key-and-no-Premium path above: the link it receives is useless without the key. Without a key, use the Downloads-folder path and skip this.
`python3 -I tools/nexus.py install-handler [--dry-run]` builds a small AppleScript app (`osacompile`) at
`$VXRT_PRIVATE_ROOT/tools/NexusHandler.app` (git-ignored; never committed) that passes each `nxm://` link to
`nexus.py receive`, which only saves it in the queue, and then makes it the macOS default handler for `nxm://`.
That is a system-wide setting outside this repository, so the command explains itself, shows the current handler (and warns if it looks like
Vortex or Mod Organizer, whose links would then come here), records it in `.../tools/nxm-handler-previous.json`, and asks `[y/N]` on a terminal;
there is no `--yes`. `--dry-run` changes nothing. `uninstall-handler` restores the recorded handler and removes the app (macOS cannot clear a
default: with no previous handler it says so). `handler-status` shows the current state. The registration uses
LaunchServices (`LSSetDefaultHandlerForURLScheme` via `osascript`); `duti` is not needed. The app, the real registration and a real browser
click were not run here: the build and the registration logic are tested (the registration call itself replaced by a stand-in); the first
real use is yours. If the browser asks which app should open `nxm://` links, choose NexusHandler. Without the handler, paste the link.

**Terms.** Nexus Mods' terms apply: the files are for your personal use through your own account; do not redistribute mods, and
respect each mod's own permissions (this repository never commits downloads; they stay in the private root). The tool identifies itself
with `Application-Name`/`Application-Version` headers. It uses the v1 API (stable, has the account check and file sizes/md5);
the newer v3 download-link endpoint is marked experimental by Nexus.
Not yet verified against the real service: this was tested only against a local fake server (the handler app was built, not registered or clicked).

## The split profile

The pipeline config names a profile of instruction addresses (`splits-1022-at-0x140000000.txt`): the x86 instructions of SkyrimVR.exe whose
ordered memory access crosses 16 bytes (in plain words: places where the game does a memory access that Apple chips cannot do in one go).
The compiler gives those instructions plain accesses between barriers. **Every new build needs it**: a module set made without it crashed
SkyrimVRTools in every strict run (plans/2026-11-11-skyrim-mods-combined.md).

It holds only addresses of the pinned SkyrimVR.exe, so as an exception authorized on 2026-11-11 (AGENTS.md) a copy is committed:
`tools/profiles/splits-<prepared exe sha256>.txt.gz`, with the sha256 of the unpacked text beside it. `vxrt_build.py aot` uses it first (copied
to `$VXRT_AOT_INPUTS/splits-1022-at-0x140000000.txt` with its hash in `<file>.sha256`, which the config pins) and records one only when the exe
does not match. `python3 tools/skyrim_splits.py record [--force] [--rounds N]` records your own, or adds to what is in place: it runs plain
Skyrim on the Mac (no mods, no SKSE, `play_skyrim_dev.sh` with scripted pad input) and keeps every address seen. Round 1 without a profile runs an
unsplit exe, which is slow (the main menu is reached after about 8 minutes); later rounds run modules made with the profile so far and are fast.
The doctor fails without a profile.

## Driving the stages from another program (AVP Play)

`tools/vxrt_stages.json` is the machine-readable contract: stage names, inputs (environment variables and files), outputs,
whether a stage uses the network or the headset. `python3 tools/vxrt_build.py list --json` adds the current state of each
stage. Calling convention: set the environment (or let `local/env.sh` supply it), run `tools/vxrt_build.py <stage> --json`;
stdout is one result object (`stage`, `status` of `ok`, `failed` or `missing-input`, `outputs`, `exit`), progress is on stderr, exit
0, 1 (the stage failed) or 2 (an input is missing, named in the message). AVP Play's own toolchain contract (`run.sh device`
and `stage_sync.py`, `plans/2026-11-09-avp-play-backend.md`) can wrap `prepare`/`aot`/`shaders`/`app --install` and
`stage-to-device`; that wrapper is not written yet and was not run against AVP Play.

## Checks that guard this

`make -C VXRuntime portability-check` (no personal identity in committed files, the manifest matches the dispatcher, helper
tests) and `make -C VXRuntime xros-app XROS_CODE_SIGNING=NO` (the default app must keep linking; the doctor's `--build`
runs it). Licences: Steamless is built unmodified for your own use and never redistributed; xrizer is GPL-3.0-or-later
(`THIRD_PARTY_NOTICES.md`).
