# Plan: Skyrim VR through AVP Play, with VXRuntime as its toolchain

Date: 9 November 2026. Status: not started; design only. Evidence and file:line citations are in [the research report](../research/2026-11-09-avp-play-backend.md). Parent plan: [native Darwin AOT](2026-11-08-skyrim-vr-native-darwin-aot.md).

## Goal

The user installs Skyrim VR (Steam app 611670) on their Vision Pro from AVP Play, the same way as Half-Life: Alyx:

1. Steam confirms ownership.
2. AVP Play fetches the pinned Windows depots and signs with the user's team.
3. It installs our app and syncs the game data.
4. The game opens with a start window offering play area, controller settings and room measurement.

Underneath stay our ARM64 AOT, the D3D11→Metal renderer, xrizer and our Metal OpenXR provider. Playing needs no Mac, no streaming and no SteamVR.

## Decisions

- **Shape (b): a VXRuntime toolchain behind AVP Play's existing contract**, not a target inside the Klepton fork. AVP Play couples to a toolchain only through files and environment variables (`visionos/run.sh device` + `BUILD SUCCEEDED`, `stage_sync.py`, `targets.py`, `KL_LX_*`, `build/dd-device-<target>`, `toolchain.json`). It already lets each game pin its own toolchain, a working copy at any path included. Skyrim gets ours and every other game keeps Klepton.
- **Klepton's start window, play-area boundary and controller UX** are MIT. Adapt them into `VXRuntime/xros/app` with attribution; do not embed Klepton's OpenXR runtime or compositor. Keep our frame-ownership invariants.
- **Steam ownership** is confirmed by Steam (SteamCMD `licenses_for_app`) before any fetch.
- **SteamVR parts and Steamworks stubs** are allowed since 2026-11-09 (`AGENTS.md`). Try the no-Steam route first (`VXRuntime/NOSTEAM.md`). Vendor or stub only what a measured run needs, and keep it private.
- **Paid Apple team only**, because the guest arena needs `extended-virtual-addressing`. Do not advertise `KLEPTON_EVA`, so AVP Play refuses free teams up front.

## Prerequisites (in this repo, from the parent plan)

Milestone 1 below starts only after the first three are true.

- [ ] Skyrim VR runs from our `xros-app` on the visionOS simulator: AOT modules built for xrsimulator, strict AOT with zero fallback, the world in both eyes.
- [ ] A Skyrim AOT module set for the device target is embedded in a signed app that installs, with size and signing limits measured.
- [ ] The runtime takes its game root and save location from launch configuration (env/Info.plist), not hard-coded `Documents/root`.
- [ ] Real controller input reaches input host v3 from `AccessoryTrackingProvider`, with haptics or an honest refusal.
- [ ] The headset test is authorized separately by the user, then a human playtest. These gate "playable", not the toolchain work.

## Milestones

### 1. Verify the contract against the real Klepton toolchain

- [ ] With the user's approval, download `klepton-toolchain-866-e65c433` (or the fork at that tag) into an ignored private directory.
- [ ] Read `run.sh`, `stage_sync.py`, `targets.py` (the `alyx` row), `gen_xcodeproj.py` and the start-window SwiftUI.
- [ ] Replace each *(inferred)* item in the research report with file:line facts. Run nothing from the package.

### 2. Contract-compatible VXRuntime toolchain directory

- [ ] Add `tools/avpplay_toolchain/`: `visionos/run.sh`, `visionos/stage_sync.py`, `visionos/targets.py` (`skyrimvr`, `kind: vxruntime`), a `gen_xcodeproj.py` naming only the features we honour, and `toolchain.json`.
- [ ] `run.sh device`:
  1. Validate the env (`KLEPTON_TEAM`, `KLEPTON_TARGET`, `KLEPTON_DEVICE`, `KLEPTON_BUNDLE_ID`, `KL_LX_GAME`).
  2. Copy the game's code inputs into `build/private/skyrimvr/<exe sha>/`, prepare them with pinned Steamless, and run `tools/skyrim_aot_pipeline.py` for the xros target and arena.
  3. Run `make -C VXRuntime xros-app` signed for the team, install with devicectl, and copy the `.app` to `visionos/build/dd-device-skyrimvr/…`.
  4. Print `BUILD SUCCEEDED` only after a real install. Failures print `!! install FAILED: <why>` and `!! signing: <why>` as AVP Play expects.
- [ ] `stage_sync.py --phase all [--dry-run]`: hard-link mirror into `KL_LX_MIRROR` of what the runtime reads (Data, .ini files, media). Leave out the code already compiled into the app. Copy it to the device root the runtime is configured with.
- [ ] Owned fixture tests: the script's env handling and failure strings, and the mirror selection against a fake tree. No device.

### 3. Start window, play area and controller settings in our app

- [ ] Port Klepton's start window (Start / Settings / Measure room) with MIT attribution in `THIRD_PARTY_NOTICES.md` and the component's source record.
- [ ] Port the play-area boundary (`KLBoundary`) as a host overlay in our presenter. The provider keeps reporting stage bounds unavailable.
- [ ] Read AVP Play's build-time defaults (`KLRoomGuardDefault`, `KLControllerModeDefault`, display name/version) from Info.plist.
- [ ] Hero image and icon from `Assets.xcassets/StartHero-skyrimvr`/`AppIcon-skyrimvr`.
- [ ] Simulator check of the window and its settings persistence. The boundary needs the headset.

### 4. Private recipe and end-to-end run

- [ ] Write `skyrimvr.json` as sketched in the research report: depots 611673/611672/611671 at the pinned manifests, markers `SkyrimVR.exe` and `Data/SkyrimVR.esm`. Keep it private until it is verified.
- [ ] Find out whether the depots overlap and which depot carries the exe.
- [ ] Run AVP Play with `AVPPLAY_HOME` set to an empty folder and our toolchain pinned for `skyrimvr` only, to check the build, install and sync. This needs the headset authorization.
- [ ] Measure the Steam need: does Skyrim VR start with `steam_api64` finding no Steam? Stub only what the run shows is needed, and record which.
- [ ] Measure the SteamVR need, if any, and vendor those files from the user's install as a private `data` tree.

### 5. Upstream proposal to AVP Play (needs the user's go-ahead to post)

- [ ] Draft only: `toolchain.kind` that a recipe requires, a per-kind save root (today backups only cover `Documents/android-files`), and a kind-specific device tree path (today progress polls `Documents/lx`).

## Open questions

These are tracked in the research report: what the Klepton scripts actually do, the depot layout, the device tree path, AOT module size and signing limits on the device, which SteamVR files are needed, Steamworks behaviour, and GPL-3 obligations if anything is ever published.
