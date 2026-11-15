# Installing Skyrim VR on Apple Vision Pro

This project runs the Windows PC version of Skyrim VR on Apple Vision Pro itself: your Mac recompiles your own copy of the game for Apple silicon once and installs it, and the headset then plays it with no PC or streaming.

The full guide is [docs/SETUP_SKYRIM.md](docs/SETUP_SKYRIM.md), from a fresh clone to the game on your headset. The [README](README.md) covers the same steps with more background, plus the mods.

## Requirements

- An Apple-silicon Mac with Xcode 26 and the visionOS platform, and about 40 GB free
- Apple Vision Pro in Developer Mode, paired with Xcode
- A **paid** Apple Developer account: the app needs Increased Memory Limit and Extended Virtual Addressing
- Two PlayStation VR2 Sense controllers, paired and switched on before you press Start
- Your own Skyrim VR and SteamVR on Steam
- `brew install xcodegen python mingw-w64 steamcmd p7zip` (steamcmd only if the tools should download the game; mingw-w64 only for the test suite)

## Game files

You need to supply your own game files. This repository contains none. Point `SKYRIM_ASSET_ROOT` and `STEAMVR_WIN64_DLLS` in `local/env.sh` at your Steam installs, or let `python3 tools/vxrt_steam.py fetch <steam-login> 611670 250820` download them with your Steam login. `python3 tools/vxrt_build.py doctor` checks that your copy is the version the tools expect.

## Build and install

From a checkout of this repository:

```sh
mkdir -p local && cp local.example.sh local/env.sh   # then fill in your team ID, bundle prefix, device ID and game paths
python3 tools/vxrt_build.py doctor
python3 tools/vxrt_build.py toolchain --with-steamless
python3 tools/vxrt_build.py prepare
python3 tools/vxrt_build.py aot
python3 tools/vxrt_build.py shaders
python3 tools/vxrt_build.py app --install
python3 tools/vxrt_build.py stage-to-device --run
```

`toolchain` downloads Rust, Steamless and a private .NET runtime into the project folder. `stage-to-device` copies about 14 GB of game data to the headset. Then open Skyrim VR from the Home View. Mods (SKSE, HIGGS, PLANCK, VRIK, SkyUI) are optional; see the README's Mods section.
