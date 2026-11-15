# AVP Play toolchain adapter

This folder lets [AVP Play](https://github.com/myMartek/avp-play), the Mac app that builds and installs VR games
for the Apple Vision Pro, install Skyrim VR the way it installs Half-Life: Alyx: it checks with Steam that the
account owns the game, fetches the pinned depots, builds the app on the player's Mac, signs it with their team,
installs it and copies the game data. The design is in
[plans/2026-11-09-avp-play-backend.md](../../plans/2026-11-09-avp-play-backend.md) (shape b: this project as a
second kind of toolchain behind AVP Play's existing contract).

AVP Play couples to a toolchain only through files and environment variables. This folder is such a toolchain:

| File | What AVP Play does with it | What it does here |
| --- | --- | --- |
| `visionos/run.sh device` | builds and installs; success is exit 0 and the line `BUILD SUCCEEDED` | runs the stages of `tools/vxrt_build.py` (toolchain, prepare, aot, shaders, app) and installs with devicectl |
| `visionos/stage_sync.py` | builds a hard-link mirror of what belongs on the headset (`--dry-run`), then copies it | the game tree of `tools/skyrim_device_stage.py`, to `Documents/root/SkyrimVR` |
| `visionos/targets.py` | reads the target's row | `skyrimvr`, kind `vxruntime` |
| `visionos/gen_xcodeproj.py` | looks for the names of the build options a toolchain supports | names only what `run.sh` honours |
| `toolchain.json` | version, commit, ancestors, kind | written by `make_manifest.py` (git-ignored) |

Nothing here changes what the project's own stages do, and nothing of the game leaves the Mac except to the
player's own headset. Everything runs with the tools macOS and Xcode bring (`/usr/bin/python3`, make, clang) plus
what the stages fetch themselves; xcodegen is taken from Homebrew when it is there and downloaded (checked by
SHA-256) when it is not.

## Using a checkout as the toolchain

```sh
python3 tools/avpplay_toolchain/make_manifest.py
avpplay toolchain use skyrimvr --toolchain "$PWD/tools/avpplay_toolchain"
avpplay install skyrimvr
```

The stages keep their results under the project's private root (`build/private` in a checkout), so stages already
run by hand are not repeated.

## Not done yet

- Mods (`mods-fetch`, `mods`, `skse-capture`): the app is built from plain Skyrim VR. A pack made by hand with
  `tools/vxrt_build.py mods` is picked up by the `app` stage as before.
- The icon and start picture AVP Play writes to `visionos/Assets.xcassets` are not used; the app keeps its own icon.
- Saved games: AVP Play backs up `Documents/android-files` only. The game writes under
  `Documents/root/overlay_skyrimvr` (`targets.py` names it as `saves` for a later change in AVP Play).
- Free Apple teams cannot sign the app (extended virtual addressing); `run.sh` says so.
