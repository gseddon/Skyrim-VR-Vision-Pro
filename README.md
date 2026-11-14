# Skyrim VR on Apple Vision Pro

This project runs the Windows PC version of **Skyrim VR** directly on an Apple Vision Pro. Nothing is streamed from a gaming PC, and no Mac has to stay connected while you play. A Mac does the one-time preparation and installs the app. After that, the headset runs the game by itself.

You need your own copy of Skyrim VR. This repository holds only the tools that do the conversion. It contains no game files, and it can't be used to play without owning the game.

## Does it work?

**Yes, and it plays well.** You can play Skyrim VR properly on the headset: walk around, fight, and explore Helgen and beyond. Head tracking, the PlayStation VR2 Sense controllers, sound, menus and saves all work, with your hands in the world thanks to the physics mods listed below.

- **It feels smooth.** The game itself draws about 35 frames per second. A separate compositor redraws the view at the headset's full 100 Hz from your latest head position, so looking around feels much smoother than the frame rate suggests. The game renders at 75% of the headset's resolution, and Apple's MetalFX upscales it to full sharpness.
- **Mods work.** SKSE, HIGGS, PLANCK, VRIK and SkyUI all run on the headset, so you get physical hands, a full body and the improved menus.
- **Connect your controllers first.** Make sure both controllers are on and connected *before* you press **Start** on the app's main screen. This is a Skyrim VR limitation: controllers that connect after the game starts get their buttons but not their thumbsticks.

It's a hobby project, so expect the odd rough edge, but it's very much a game you can sit down and play.

## How it works

Skyrim VR is a Windows program. It's built for Intel/AMD processors, draws with Microsoft's Direct3D 11 and talks to VR headsets through Valve's SteamVR. The Vision Pro has none of those: it has an Apple chip, Apple's Metal graphics and Apple's own way of drawing into the headset. Four pieces translate between the two worlds.

1. **Recompiling the game ahead of time.** The game's machine code is translated from x86-64 (Intel/AMD) to ARM64 (Apple silicon) on the Mac, before the app is installed. This is different from how Rosetta or emulators usually work: they translate while the program runs, often with a just-in-time (JIT) compiler. visionOS doesn't allow apps to generate code while they run, so every piece of code the game will execute has to be translated in advance. That includes the code that mods add. The translated code is packaged as ordinary Apple frameworks inside the app.

2. **Windows compatibility (VXRuntime).** The game expects Windows: its files, memory, threads, and system libraries. VXRuntime provides those on Apple's operating system. It's a similar idea to Wine, written for this purpose, and a few parts are adapted from Wine and FFmpeg. Among other things, it decodes the game's xWMA audio for Skyrim's XAudio2 sound engine.

3. **Direct3D 11 → Metal.** VXRuntime's renderer takes the game's Direct3D 11 drawing commands and replays them with Metal. It also converts the game's 10,807 shaders (the small GPU programs that draw everything) into Metal shaders, which are built once and shipped inside the app. Apple's **MetalFX** then upscales each frame.

4. **SteamVR → visionOS (xrizer and OpenXR).** The game asks SteamVR (the OpenVR interface) for headset and controller positions, and hands it a finished image for each eye. **[xrizer](https://github.com/Supreeeme/xrizer)** is an open-source project that answers those OpenVR calls using OpenXR, the industry-standard VR interface. Underneath it, an OpenXR provider adapted from the open-source **Klepton** project maps OpenXR onto visionOS's CompositorServices and ARKit. That provider handles the headset view, controller tracking and haptics. A compositor running at the headset's 100 Hz keeps head movement smooth even when the game itself runs slower.

## What you need

- **Your own Skyrim VR on Steam**, plus SteamVR installed (a couple of Windows libraries are taken from it). Nothing from either is ever committed or shared.
- **A paid Apple Developer account** ($99/year). The app needs extra memory and a larger address space, and Apple grants those only to paid accounts.
- **An Apple-silicon Mac** with Xcode 26 and the visionOS platform installed, and about 40 GB of free space.
- **A Vision Pro** in Developer Mode, paired with Xcode, and **PlayStation VR2 Sense controllers** paired to it.

### Installing the tools

Install Xcode from the App Store, then add the visionOS platform in Xcode's settings. Then install the rest with [Homebrew](https://brew.sh):

```sh
brew install xcodegen python mingw-w64 steamcmd p7zip
```

- **xcodegen** and **python** are needed to build the app.
- **mingw-w64** is a Windows C compiler. It's only needed to run the project's own test suite (`make check`), not to build the game.
- **steamcmd** is only needed if you want the tools to download the game from Steam. Skip it if you'll copy the game from an existing Steam library. (On some setups it's a cask: `brew install --cask steamcmd`.)
- **p7zip** unpacks some mod archives.

The setup itself downloads Rust and, if needed, Steamless and a private .NET runtime into the project folder. You don't need to install those yourself.

## Setting it up

There's a longer guide in [docs/SETUP_SKYRIM.md](docs/SETUP_SKYRIM.md).

### 1. Tell it about your account, headset and game

```sh
mkdir -p local && cp local.example.sh local/env.sh
open -e local/env.sh
```

Fill in the values. The `local/` folder is never committed.

```sh
export XROS_TEAM_ID=ABCDE12345                       # your Apple team ID (developer.apple.com → Membership)
export XROS_BUNDLE_PREFIX=com.yourname.vxrt          # any reverse-domain name; the app becomes <prefix>.SkyrimVR
export VXRT_DEVICE_ID=00000000-0000-0000-0000-000000000000   # from: xcrun devicectl list devices
export SKYRIM_ASSET_ROOT="$HOME/path/to/steamapps/common/SkyrimVR"    # your game install (only read, never changed)
export STEAMVR_WIN64_DLLS="$HOME/path/to/SteamVR/bin/vrwebhelper/win64"
```

If the game isn't on this Mac, the tools can fetch it with your Steam login: `python3 tools/vxrt_steam.py fetch <steam-login> 611670 250820`. Steam asks for your password and checks that you own it.

Then check that everything is in place:

```sh
python3 tools/vxrt_build.py doctor
```

The doctor lists anything that's missing and tells you how to fix it, including whether your copy of the game is the version these tools expect.

### 2. Build and install

Everything runs through one script, `tools/vxrt_build.py`, in steps. Run them in this order:

```sh
python3 tools/vxrt_build.py toolchain --with-steamless   # downloads Rust, Steamless and .NET into the project
python3 tools/vxrt_build.py prepare                      # removes Steam's DRM wrapper from your SkyrimVR.exe (a private copy)
python3 tools/vxrt_build.py aot                          # recompiles the game for Apple silicon
python3 tools/vxrt_build.py shaders                      # builds the Metal shaders from your game data
python3 tools/vxrt_build.py app --install                # builds, signs and installs the app on your Vision Pro
python3 tools/vxrt_build.py stage-to-device --run        # copies the game data (about 14 GB) to the headset
```

The `aot` step also needs a list of places in the game where it does a kind of memory access that Apple chips can't do in one go. The recompiler has to know them in advance. A list for the supported version of the game comes with this repository (`tools/profiles/`), and `aot` uses it automatically. If you want your own, or want to add to the shipped one, run `python3 tools/skyrim_splits.py record --force`: it watches the game run on your Mac for about 10 minutes. It plays plain Skyrim, with no mods and no SKSE, and the list only holds places inside `SkyrimVR.exe`. Adding to a list that already exists (the usual case) is a tour: the script loads a copy of a saved character from `build/private/saves/race` (your own saves are never touched) and uses the developer console to teleport to seven places, about every two minutes, so the run reaches more of the game than a walk through the opening would (`--no-tour` turns that off, and `--seconds 900` gives it about 15 minutes). If your `SkyrimVR.exe` isn't the supported version, `aot` records the list for you the first time.

Then open **Skyrim VR** from the Vision Pro's Home view.

Good to know:

- **Steps skip finished work.** A step that has already finished does nothing next time, so it's safe to rerun the whole list. Add `--force` to redo one.
- **Status and errors.** `python3 tools/vxrt_build.py list` shows each step's status. A step that's missing something says what, and exits with code 2.
- **No questions asked.** The steps run without prompting. The only exceptions: `toolchain --confirm` asks before downloading, and the mod download step asks you to download files in your browser.
- **What touches the headset:** only `app --install`, `stage-to-device --run` and `mods --deploy`. **What uses the internet:** only `toolchain` and `mods-fetch`.
- **Settings.** The app has a start screen with settings: render scale, upscaling, sharpening, snap or smooth turning, teleport or walking, and a range of Skyrim's own settings. Each one defaults to the game's usual value.

## Mods

Mods are supported, including the ones that make Skyrim VR feel physical. These are on by default:

| Mod | Version | What it does |
| --- | --- | --- |
| SKSE VR | 2.0.12 | The script extender most other mods need |
| SkyrimVRTools | 2.3 beta | A shared helper library that VR mods build on |
| HIGGS | 1.10.10 | Use your hands: grab, pull and throw objects |
| PLANCK | 0.8.2 | Physical combat: weapons and bodies collide and react (needs HIGGS) |
| VRIK | 0.8.8 | Gives you a full body you can see, moved by your head and hands |
| SkyUI VR | 1.2.2 | A better menu and inventory interface |
| Skyland AIO | 1k | Higher-quality landscape and architecture textures |

All of these have been played with on the headset.

Mods that add code (SKSE plugins) are recompiled ahead of time along with the game. Changing the set of code mods means rerunning that step. SkyUI contains a small scripting engine (LuaJIT) that normally generates code while it runs. The tools add a tiny patch that switches that off.

`mods.py deploy` only copies files to the headset (devicectl cannot delete), so at launch the app removes any SKSE plugin DLL in `Data/SKSE/Plugins` that the deployed pack's `mods.json` no longer lists. It touches nothing else, and does nothing if `mods.json` is missing.

### Getting the mod files

The mod files themselves aren't included. You download them from [Nexus Mods](https://www.nexusmods.com) under its terms, for your own use. **A free Nexus account is enough: no Premium and no API key needed.**

```sh
python3 tools/vxrt_build.py mods-fetch
```

For each mod, this shows a link to its Nexus download page. Open it and click the download button in your browser as usual. The tool watches your Downloads folder, recognises each file, checks that it's exactly the expected file, and unpacks it. With an optional `NEXUS_API_KEY` it looks up file ids from the pinned checksums and, on a Premium account, downloads directly; a free account just uses the browser flow. SKSE VR comes from [skse.silverlock.org](https://skse.silverlock.org/) the same way. Then build the mod pack and send it to the headset:

```sh
python3 tools/vxrt_build.py mods --deploy
```

Without `--list`, these use the default list in [mods/default.json](mods/default.json). To change the mods, copy it, add or remove entries, and pass your copy with `--list`. Its format is described at the top of `tools/mods.py`. If you have Nexus Premium, setting `NEXUS_API_KEY` makes the downloads automatic. You can also register a handler for Nexus's "Mod Manager Download" buttons: `python3 tools/nexus.py install-handler`.

### SKSE plugins

HIGGS, PLANCK, VRIK and SkyUI VR are SKSE plugins, and the headset can't patch code while it runs, so they need one extra step on your Mac. After `mods-fetch` and `mods` (which also picks up the SKSE VR download from your Downloads folder: it isn't on Nexus, and needs no account), run:

```sh
python3 tools/vxrt_build.py skse-capture
```

This runs Skyrim on your Mac for a few minutes (it waits if another Skyrim session is running) and records what the plugins change in the game's code. It then recompiles the game with those changes included and checks that the game still runs. The next `app --install` and `mods --deploy` use the result. Run it again whenever you add, remove or update an SKSE plugin; if nothing changed, it skips itself.

## What's in this repository

| Folder | What's in it |
| --- | --- |
| `VXRuntime/` | The recompiler, the Windows compatibility layer, the Direct3D → Metal renderer and the visionOS app |
| `third_party/xrizer/` | xrizer (SteamVR/OpenVR → OpenXR), with the changes for Apple platforms |
| `third_party/klepton_openxr/` | The OpenXR provider for visionOS, adapted from Klepton |
| `tools/` | The build script, the mod tools and developer utilities |
| `tests/` | Automated tests |
| `plans/`, `research/`, `history/` | Design notes, measurements and a decision log |

### For developers

- **Plans.** Start with [the main plan](plans/2026-11-08-skyrim-vr-native-darwin-aot.md) and [the decision log](history/2026-11-09-10-decision-log.md).
- **Playing on the Mac.** `tools/play_skyrim_dev.sh` runs the game on the Mac with keyboard controls, which is handy for testing. See the top of the script for options.
- **Tests:**

```sh
make -C VXRuntime check                                  # needs mingw-w64
make -C VXRuntime xros-app XROS_CODE_SIGNING=NO          # builds the app without signing
python3 -m unittest discover -s tests -p 'skyrim*_test.py'
```

## Credits and licensing

This project grew out of **[VeRantyx](https://github.com/Ag3497120/VeRantyx)** (its original README is kept in [docs/VERANTYX_UPSTREAM_README.md](docs/VERANTYX_UPSTREAM_README.md)), whose x86-64 → ARM64 recompiler and Windows compatibility layer it builds on. VeRantyx's original MIT notice is kept in [LICENSE](LICENSE).

It also uses, with their own licences:

- **xrizer** (GPL-3.0-or-later);
- **Klepton**'s OpenXR and controller code (MIT);
- parts adapted from **Wine** and **FFmpeg** (LGPL-2.1-or-later);
- **AMD FidelityFX CAS** (MIT);
- the Khronos OpenXR and Valve OpenVR headers.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the full list and each component's licence.

Skyrim VR is © Bethesda Softworks. SteamVR and OpenVR are Valve's. This project isn't affiliated with Bethesda, Valve, Apple or Nexus Mods. Game files, Valve and Microsoft libraries, and the recompiled game code all stay on your own machine and headset. Never redistribute them.
