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
- The icon AVP Play writes to `visionos/Assets.xcassets` is not used; the app keeps its own. (The start picture is:
  `run.sh` copies `StartHero-skyrimvr.imageset/hero.png` into the app's resources as `bundle/StartHero.png`, and the
  start window shows it behind the title. It is the player's own picture and never part of this repository.)
- Saved games: AVP Play backs up `Documents/android-files` only. The game writes under
  `Documents/root/overlay_skyrimvr` (`targets.py` names it as `saves` for a later change in AVP Play).
- Free Apple teams cannot sign the app (extended virtual addressing); `run.sh` says so.

## Language

The game has no language menu; Steam installs a language by replacing `Skyrim.ini` and adding one voice archive. Here one
set of game files serves every language:

- The app has "Game language" under its game options (English, Deutsch, Français, Italiano, Español, Polski, Русский, or
  automatic). It overrides `sLanguage` and the voice archive in `sResourceArchiveList2` when the game starts
  (`VXGameLanguage` in `VXRuntime/xros/app/Sources/VXSettings.swift`); the texts of these languages are in the game's data.
- `KLEPTON_GAME_LANGUAGE` (AVP Play's game language: `device`, `en`, `de_DE`, ...) is what "automatic" means while
  nothing else decides; `run.sh` passes it into the app's Info.plist (`VXGameLanguageDefault`).
- The voices of a language other than English are `Data/Skyrim - Voices_<code>0.bsa` from that language's Steam depot
  (German: depot 611676, 2.0 GB). The installer copies the file to `Documents/root/SkyrimVR/Data` (AVP Play: a recipe
  file with a locale); the adapter has no part in it. One installed voice archive makes that language the automatic
  choice; without the file a language's texts go with the English voices. An empty file counts as absent.

## Mods

AVP Play's switch is `KLEPTON_GAME_MODS`, a comma-separated list of the sets in `visionos/mods.json`: `core` (SKSE VR,
SkyrimVRTools, HIGGS, PLANCK, VRIK, SkyUI VR) and `skyland` (Skyland AIO). They are groups of entries of the project's
own list, `mods/default.json`; `visionos/vx_mods.py` writes the list the stages use.

- `visionos/mods_fetch.py` runs before the build (AVP Play starts it): `tools/mods.py fetch` for the chosen sets. Without
  a key it opens each Nexus page in the browser and takes the archive from the Downloads folder by its md5; with
  `NEXUS_API_KEY` (a Premium account's key, which AVP Play keeps in the keychain) the project's client downloads them.
- `visionos/run.sh` then runs the stages `mods` and, for `core`, `skse-capture` (the game runs on the Mac for about five
  minutes, muted) before `app`. Without mods the pack of an earlier build is set aside, so the plain modules are embedded.
- `visionos/stage_sync.py` copies the pack beside the game tree and a list of the pack's files (`mods-files.txt`). The
  app removes, at its next start, files an earlier list named and this one does not, so switching mods off leaves
  nothing of them in the game's overlay.

