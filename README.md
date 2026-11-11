# Skyrim VR on Vision Pro

Experimental work toward running an owned Windows x86-64 Skyrim VR build locally on Apple Vision Pro: ahead-of-time ARM64 recompilation, VXRuntime Windows compatibility and D3D11→Metal, with native xrizer and a Klepton-derived OpenXR provider.

## Status

Skyrim VR runs standalone on Apple Vision Pro and goes in-game. The game is recompiled ahead of time to ARM64 on a Mac, installed in a signed visionOS app, and executed on the headset with no streaming, no Mac or PC helper and no external SteamVR. There is no JIT: the accepted path is strict AOT.

What has been observed (subject: the physical headset, played by a person):

- In-game play through the Helgen cart ride, with head tracking and PS VR2 Sense controllers, at 0.75 render scale with MetalFX spatial upscaling, a 100 Hz compositor and audio.
- The full mods build (below) was installed on the headset on 2026-11-11. HIGGS, PLANCK and VRIK were verified loading there (strict AOT, 0 fallbacks). SkyUI's menus have not yet been exercised in the headset.

Known open issues:

- Controllers connected after the game has launched lose their analog sticks.
- Performance is pixel-bound at about 35 stereo pairs/s.

This is an experimental development project, not a release. It does not establish that the whole game is playable beyond what is listed above. The plans are the source of truth: [main plan](plans/2026-11-08-skyrim-vr-native-darwin-aot.md), [decision log](history/2026-11-09-10-decision-log.md), [AOT feasibility](plans/2026-11-08-skyrim-vr-prepared-input-aot-feasibility.md), [xrizer/Klepton](plans/2026-11-08-xrizer-klepton-native-openxr.md).

## Requirements

- Your own copy of Skyrim VR (Steam app 611670, the pinned Windows build) and SteamVR (app 250820, for `msvcp140.dll`). Nothing derived from them is committed or shared.
- A paid Apple Developer Program team. The app needs the `increased-memory-limit` and `extended-virtual-addressing` entitlements, which free teams do not get.
- An Apple-silicon Mac (macOS 14 or newer, about 40 GB free) with Xcode 26.x and the visionOS platform, to build.
- A Vision Pro in Developer Mode, paired with Xcode, and PS VR2 Sense controllers paired to it.
- `local/env.sh` with your team and device IDs (see below).

### Dependencies

Install the Homebrew packages with one command:

```sh
brew install xcodegen python mingw-w64 steamcmd p7zip
```

- `xcodegen` and `python` (3.9 or newer) are required; the doctor checks both.
- `mingw-w64` (provides `x86_64-w64-mingw32-gcc`) is only needed for `make check` and the owned Windows test programs, not for building the Skyrim app. The doctor reports it as a warning if missing.
- `steamcmd` is only needed for `tools/vxrt_steam.py fetch`; skip it if you copy the game from an existing Steam library. Formula name unverified (it may be a cask on your Homebrew).
- `p7zip` is used for some archive types by the mod tools; macOS `bsdtar` handles the rest. Formula name and exact need unverified.

Not from Homebrew:

- From Xcode: the visionOS SDKs (`xros`, `xrsimulator`), `xcrun`, `devicectl`, the Metal toolchain and `clang` (`xcode-select --install` for the command line tools).
- Fetched by the `toolchain` stage into git-ignored `build/toolchains` and `build/private`: Rust 1.99.1 with the Apple targets and the locked crates, and with `--with-steamless` Steamless and a private .NET 8 SDK. Do not install these yourself.

I found no use of nasm, cmake, ninja or git-lfs in the scripts or Makefiles.

## Setup

Full detail: [docs/SETUP_SKYRIM.md](docs/SETUP_SKYRIM.md).

1. Your settings, once:

```sh
mkdir -p local && cp local.example.sh local/env.sh      # local/ is git-ignored
$EDITOR local/env.sh
python3 tools/vxrt_build.py doctor                       # what is still missing, and how to fix it
```

`local/env.sh` holds `export` lines (placeholders shown):

```sh
export XROS_TEAM_ID=ABCDE12345                                 # your 10-character Apple team ID
export XROS_BUNDLE_PREFIX=com.yourname.vxrt                    # the app becomes <prefix>.SkyrimVR
export VXRT_DEVICE_ID=00000000-0000-0000-0000-000000000000     # xcrun devicectl list devices, Identifier column
export SKYRIM_ASSET_ROOT="$HOME/path/to/steamapps/common/SkyrimVR"   # your install; read only
export STEAMVR_WIN64_DLLS="$HOME/path/to/SteamVR/bin/vrwebhelper/win64"   # read only
```

The build tools and doctor read `local/env.sh` themselves; for plain `make` run `. local/env.sh` first. Your own Skyrim VR comes from `SKYRIM_ASSET_ROOT` (copy it from a Steam library, or `python3 tools/vxrt_steam.py fetch <steam-login> 611670 250820`, where SteamCMD asks for your password and Steam confirms ownership). The doctor checks the game is the pinned build.

2. The stages. Each is `python3 tools/vxrt_build.py <stage>`; each is idempotent (a finished stage does nothing unless `--force`). Exit 0 means done, 2 a missing input (the message names it), 1 a failure. `--json` prints one result object. `python3 tools/vxrt_build.py list` shows every stage and its state.

| Stage | What it does | Output |
| --- | --- | --- |
| `doctor` | checks prerequisites, settings and inputs | a report |
| `toolchain [--with-steamless] [--confirm]` | Rust and the locked crates; with `--with-steamless` also Steamless and .NET 8. It lists what it downloads and goes ahead; `--confirm` asks first. Network | `build/toolchains/xrizer-rust` |
| `prepare` | unpacks your SkyrimVR.exe with Steamless (hash-checked) and collects the input DLLs | prepared exe and inputs under `build/private` |
| `aot` | compiles the prepared exe and DLLs to ARM64 frameworks | `build/private/game_fw-xros` |
| `shaders` | builds the Metal shader set from the committed manifest and your Main.bsa | `build/private/shadercache-xros-manifest` |
| `app [--unsigned] [--install]` | builds and signs the visionOS app; `--install` installs it with devicectl | `VXRuntime/build/xros-xrizer-fixture/derived/Build/Products/Debug-xros/VXRuntimeHost.app` |
| `stage-to-device [--run]` | copies the game tree (about 14 GB) into the app's container; a dry run unless `--run` | on the headset |
| `mods-fetch --list L` | fetches the Nexus files named in a mods list (below) | `build/private/downloads/nexus`, `mods-src` |
| `mods --list L [--out DIR] [--deploy]` | builds a mod pack; `--deploy` copies it to the headset | `build/private/mods-pack` |

There is no all-in-one auto-yes flag: the stages do not prompt, except `toolchain --confirm` (opt-in) and, on a terminal, the Nexus fetch prompts. Only `app --install`, `stage-to-device --run` and `mods --deploy` touch the headset, and only `toolchain` and `mods-fetch` (with a key) use the network.

Typical first run:

```sh
python3 tools/vxrt_build.py toolchain --with-steamless
python3 tools/vxrt_build.py prepare
python3 tools/vxrt_build.py aot
python3 tools/vxrt_build.py shaders
python3 tools/vxrt_build.py app --install
python3 tools/vxrt_build.py stage-to-device --run
```

Then start the app from the Vision Pro Home view. For a development run on the Mac with keyboard controllers there is `tools/play_skyrim_dev.sh` (see its header for flags).

## Mods

`tools/mods.py` builds a mod pack from a mods list (`mods-list.json`, format documented at the top of `tools/mods.py`). A mod can name a Nexus file (`game`, `mod_id`, `file_id`); `tools/nexus.py` fetches it. This works without Nexus Premium and without an API key:

1. `python3 tools/vxrt_build.py mods-fetch --list mods-list.json` prints, for each mod, the Nexus Files page to open.
2. Download the file in your browser. The tool watches `~/Downloads` (`VXRT_DOWNLOADS_DIR` to change), matches the archive by mod ID, checks its md5 against the pinned value (and pins it on first fetch), and unpacks it under `build/private/mods-src`. A file whose md5 differs from the pin is refused.
3. An nxm:// handler is optional (`python3 tools/nexus.py install-handler`, `handler-status`, `uninstall-handler`). A personal `NEXUS_API_KEY` is also optional; with Premium it makes downloads automatic.
4. `python3 tools/vxrt_build.py mods --list mods-list.json [--deploy]` builds the pack and optionally copies it to the headset.

Mods are for your personal use under Nexus's terms; they are not in this repository and must not be redistributed. The mods list itself is not committed, because it holds local paths. The default set built for the 2026-11-11 headset install, read from that build's list and pack (`mods.json`), is:

| Mod | Version | Purpose |
| --- | --- | --- |
| SKSE VR (Papyrus scripts and loader support) | 2.0.12 | script extender that the other plugins load through |
| SkyrimVRTools | 2.3 BETA | in-game VR settings and configuration overlay |
| HIGGS | 1.10.10 | physical hand interaction: grab, pull and throw objects |
| PLANCK | 0.8.2 | physics-based active ragdoll and collision; requires HIGGS |
| VRIK | 0.8.8 | full-body player avatar driven by head and hands |
| SkyUI VR | 1.2.2 | the menu interface; a small overlay mod adds `jit.off()` to its `MainEntry.lua` (`tools/skyui_nojit.py`), because strict AOT cannot run LuaJIT-generated code |
| Skyland AIO 1k | | texture and visual overhaul (Lit Road Signs and Watercolor plugins active) |

The build also carries an owned diagnostic plugin (`modlist-dump`) that logs the loaded plugin list. Skyland's version string is not recorded in the list. HIGGS, PLANCK and VRIK are verified loading on the headset; the rest are installed but not individually verified there.

## Source layout

| Directory | Purpose |
| --- | --- |
| `VXRuntime/` | Windows compatibility, x64→ARM64 compiler, Metal renderer, visionOS host, owned fixtures |
| `third_party/xrizer/` | Pinned GPL xrizer source and Apple port |
| `third_party/klepton_openxr/` | Pinned/adapted MIT OpenXR provider and owned native Metal fixtures |
| `tools/`, `tests/` | Static audits, reproducible AOT pipeline, native startup evidence and unit tests |
| `plans/`, `research/` | Decisions, verified results, provenance and remaining risks |

The target here is standalone headset execution. See [UPSTREAM.md](UPSTREAM.md) for source provenance and [MIGRATION.md](MIGRATION.md) for the active workspaces.

## Initial checks

On an Apple silicon Mac with Xcode and the visionOS SDK installed:

```sh
mkdir -p build
make -C VXRuntime build/vxrt-aot build/native_vr_test
VXRuntime/build/native_vr_test
python3 -m unittest discover -s tests -p 'skyrim*_test.py'
python3 -m unittest discover -s tests -p 'vxrt_native_startup_test.py'
third_party/klepton_openxr/build-test.sh
```

The full runtime also requires the existing MinGW cross-compiler. Rust checks use the repository-local toolchain in `build/toolchains/xrizer-rust` (override with `XRIZER_RUST_ROOT`); component scripts document targets/features. The experimental `owned-apple-test` route is for owned integration fixtures. Ordinary Apple initialization remains unavailable while required behaviors are incomplete.

## Private inputs and artifacts

This repository contains source and owned test inputs. Game executables/data, Microsoft/Valve runtime DLLs, prepared images, translated game code, toolchains, downloaded tool packages, build outputs and raw run directories remain local and ignored. Do not redistribute them. Private-input tools require local hashes/paths and preserve original installations.

## Licensing

The original MIT notice of the upstream project this derives from is retained in [LICENSE](LICENSE). xrizer is GPL-3.0-or-later; Klepton and Khronos/OpenVR headers retain their own licenses and notices. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and each component's source record. The original project README is retained under `docs/VERANTYX_UPSTREAM_README.md`.
