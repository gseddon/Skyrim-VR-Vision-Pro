# Our runtime as an AVP Play backend

2026-11-09. This was a read-only design investigation of `~/git/avp-play` at HEAD `1a19607` ("Portal: accept the hl2 folder…"). I built nothing, ran nothing, installed nothing and launched no device or simulator. Paths of the form `core/…`, `recipes/…` and `third-party/…` are in `~/git/avp-play`. `kl_openxr.c` and `Klepton*.swift` are files from the Klepton fork packaged with AVP Play v1.10.7 (`klepton-toolchain-866-e65c433`). Only these files were extracted earlier, into the read-only VeRantyx reference checkout at `build/worktrees/native-darwin-aot/third_party/klepton_openxr/build/avp-source/`: `runtime/xr/kl_openxr.c`, `visionos/Sources/KleptonCompositor.swift`, `KleptonControllers.swift` and `LICENSE`. The provenance is in `research/2026-11-08-klepton-extraction.md`. The fork's `visionos/run.sh`, `stage_sync.py`, `targets.py`, `gen_xcodeproj.py` and its start-window SwiftUI are **not available locally**, so what this report says about them is inferred from how AVP Play calls them. Each such statement is marked *(inferred)*.

## User decision recorded here (2026-11-09)

The user overrode the earlier rule for this work. Two things are now allowed:

- We may vendor the relevant parts of SteamVR from the user's own install once they have pulled the DLLs.
- We may stub Steamworks responses as needed.

How this report applies that decision:

- Steam must still confirm ownership before anything is fetched (AVP Play already does this, below).
- SteamVR files and stubbed responses stay private: on the user's Mac and in the app built for the user's own headset. They are never redistributed or committed.
- Anti-cheat remains out of scope.

`AGENTS.md` was amended on the same day to match (synced and checked with `tools/vxrt_agents.py`).

## 1. How AVP Play drives a toolchain

**What a toolchain is.** It is a directory containing `visionos/run.sh`; that file's existence is the whole check (`Toolchain.swift:49-56`). A packaged toolchain also carries `toolchain.json` (version, commit, ancestors, appRevision) (`ToolchainPackage.swift:5-33`). A recipe pins `toolchain.target` and `minCommit`. For a package, `minCommit` is checked against `ancestors`; for a git checkout, against `git merge-base` (`Toolchain.swift:104-108`). Packages are the `klepton-toolchain-<n>-<sha>.tar.gz` assets of AVP Play releases (`ToolchainChoice.swift:113-200`), unpacked with `ToolchainPackager.install` (`ToolchainPackage.swift:261`).

**Order of an install** (`Installer.swift`):

1. **Fetch.** Recipe files and trees come from Meta, Steam, a public URL or the user. Steam fetching is in `Steam.swift:466-563`:
   - Ownership first: `steamcmd +login <acct> +licenses_for_app <app>` (`:500`). The result must parse as owned, or the install stops (`:503-507`).
   - Then `+download_depot <app> <depot> <manifest>` for each pinned depot (`:525-526`).
   - Then the depots are assembled into the tree in order, and an earlier depot is never overwritten (`:548-555`; `assemble` `:584`).
   - A tree is accepted only if all its `markers` (path, size, SHA-256) match (`Trees.swift:77-85`).

   `download_depot` takes any depot and manifest. Nothing in the fetch path is Android-specific; only Steam *library discovery* (`SteamLibrary.swift:136-160`, `oslist … contains("android")`) is limited to Android depots. A hand-written recipe with Windows depots therefore fetches through the same code.
2. **Prepare.** `Toolchain.prepare` (`Toolchain.swift:121-178`) writes the start-window hero image to `visionos/Assets.xcassets/StartHero-<target>.imageset` (`:117-126`). A recipe without an APK that has `trees` only gets its icon, `AppIcon-<target>.solidimagestack` (`:127-135`, `:223-225`). An APK recipe is unpacked to `<root>/<target>/` (`:137-177`).
3. **Build and install.** `Toolchain.buildAndInstall` (`Toolchain.swift:439-535`) runs `visionos/run.sh device` in the toolchain root (`:503-511`) with:
   - `PATH=/usr/bin:/bin:/usr/sbin:/sbin`;
   - `KLEPTON_TEAM`, `KLEPTON_TARGET`, `KLEPTON_DEVICE` (udid), `KL_SKIP_STAGE=1`, `KL_SKIP_LAUNCH=1`, `KLEPTON_START_SCREEN=1`, `KLEPTON_APP_VERSION`, `KLEPTON_APP_BUILD`;
   - optionally `KLEPTON_TEST_ON`, `KLEPTON_RENDER_SCALE`, `KLEPTON_SCOTLAND2`, `KLEPTON_BUNDLE_ID`, `KLEPTON_EVA=0`/`KLEPTON_LOW_LATENCY=0` for free teams (`:484-491`), and `KLEPTON_DISPLAY_*` (`BundleNaming.swift:48-53`);
   - `KLEPTON_CONTROLLER_MODE`/`KLEPTON_SURREAL_SUPPORT` (`:334-342`);
   - the tree locations `KL_LX_GAME`, `KL_LX_SYSROOT`, `KL_LX_XRIZER` (`Trees.swift:19-27`, `:93-99`, via `Installer.swift:712`);
   - `KLEPTON_ROOM_GUARD` and `KLEPTON_GAME_LANGUAGE` when supported (`Installer.swift:711-733`).

   Success means exit status 0 **and** the log contains `BUILD SUCCEEDED` (`Toolchain.swift:516-534`). The log text is also searched for Apple refusals, for `!! install FAILED:` and for `!! signing:`. Each optional feature is detected by grepping the toolchain's own sources (`visionos/gen_xcodeproj.py` for `KLEPTON_EVA`, `KLEPTON_ROOM_GUARD`, …; `Toolchain.swift:256-415`). AVP Play reads back from `visionos/build/dd-device-<target>/Build/Products/Debug-xros/*.app`: `KLControllerModeDefault` in its Info.plist and the profile expiry in `embedded.mobileprovision` (`:270-280`, `:418-425`).
4. **Sync.** First the recipe files go to `Documents/<dest>` through devicectl (`Installer.swift:900-950`). For trees, `syncTrees` (`Toolchain.swift:551-576`) runs `python3 stage_sync.py --phase all --device <udid> [--dry-run]` in `visionos/`, with `KLEPTON_TARGET`, the `KL_LX_*` variables and `KL_LX_MIRROR` (`Installer.swift:957-1000`). The dry run builds a hard-link mirror of what belongs on the device. AVP Play lists the mirror for progress, runs the real copy with up to six retries, and polls `Documents/lx` (`Installer.treeDestination`, `:1190`). Which files go is decided by the toolchain *(inferred: in `stage_sync.py`)*.
5. **Saves.** Backup only looks under `Documents/android-files` (`Saves.swift:30-37`).

**Bundle ID.** The default is `<user>.[freeTeam.]dev.klepton.target.<target>` (`BundleNaming.swift:12-35`), and it has to match the ID the toolchain installs under (`visionos/targets.py bundle_for`).

**Where the start window, play area, controllers and room measurement come from.** All of them are the Klepton fork's visionOS app; AVP Play only sets build-time defaults:

- **Start window.** It is enabled by `KLEPTON_START_SCREEN=1` (`Toolchain.swift:463-464`); without it the app shows the development boot report. The SwiftUI itself is not local *(inferred: in the fork's `visionos/Sources`)*. README: "*Start*, *Settings* for picture, play area and controls, and the room measured once for all games".
- **Room measurement / play area.** `KLEPTON_ROOM_GUARD` → in-app `KLRoomGuardDefault` (`Toolchain.swift:385-393`). The boundary is drawn by the compositor itself (`KleptonCompositor.swift:4636`, `:4826-4840`, `KLBoundary`). The OpenXR runtime does **not** report it: `xrGetReferenceSpaceBoundsRect` returns `XR_SPACE_BOUNDS_UNAVAILABLE` with zero extents (`kl_openxr.c:4210-4221`). The play area is therefore a host-side safety overlay, not OpenXR configuration.
- **Controllers.**
  - `KLEPTON_CONTROLLER_MODE` (standard/surreal) → Info.plist `KLControllerModeDefault`.
  - The interaction profile is chosen per run from the profiles the guest actually suggested: Touch preferred, then Valve frame, Pico Neo3 and hand interaction (`kl_openxr.c:4268-4305`). Bindings are the guest's own suggested bindings, and unknown paths stay inactive (`kl_openxr.c:4224-4250`).
  - Tuning goes through `KL_*` environment variables and `klepton.*` UserDefaults read in Swift: `KL_SENSE_*`, `KL_HAPTICS_*`, `klepton.haptics` (`KleptonControllers.swift:247-425`, `:1727-1780`).
- **What the runtime gets.** No file. The start-window settings are UserDefaults and Info.plist defaults in the same process. The provider reads them through the shared in-process input state (`kl_ovrp_*`, `kl_openxr.c:4232-4236`).

## 2. The Klepton toolchain locally

- **Not present.** `~/Library/Application Support/AVPPlay` (`DataLocation.swift:16-21`) does not exist, `QuestInstaller` does not exist, there is no `dist/klepton-toolchain-*` in `~/git/avp-play`, and no Klepton checkout is under `~/git`.
- **Partial copy.** Only the three source files above, from release asset `klepton-toolchain-866-e65c433.tar.gz` (SHA-256 `beb45820…ea27`), were extracted earlier. The fork is public at `github.com/myMartek/Klepton`, branch `avp-play`, with tags `toolchain-N` (`README.md:120-126`).
- **Approval needed.** Downloading the package or cloning the fork needs the user's approval. That is the step that would verify the *(inferred)* items here.

**What a "target" is.** It is a key of the `TARGETS` dict in `visionos/targets.py`, whose values are plain strings (`BundleNaming.swift:125-156`, parsed with `ast`). Known keys:

| Key | Meaning |
|---|---|
| `kind` | `unity`, `ue4`, … |
| `entry` | entry library (`libmain`, `libUE4`) |
| `obb` | main data file destination |
| `qtplugins` | Qt plugin folder |
| `render_scale` | default render scale |

There is also `targets.py <target> <key>` as a CLI (`:104-123`), plus per-target artefacts: `StartHero-`/`AppIcon-<target>` assets, `visionos/pipelines/<target>.pipelines`, `ports/scotland2` profiles and `build/dd-device-<target>`. A "generic" target (`KLEPTON_GENERIC_TARGET`) derives everything from the unpacked APK (`BundleNaming.swift:39-42`).

**How `alyx` differs from the Android targets:**

| | Android targets (Beat Saber, Portal/SourceVR) | `alyx` |
|---|---|---|
| Input | an APK (`files[role=apk]`), unpacked to `<root>/<target>/`, ARM64 `.so` under `lib/arm64-v8a` (`BundleNaming.swift:96-102`) | no APK; three `trees`: `game` (Steam Linux ARM64 depots 546564+546561), `sysroot` (Steam Linux Runtime 4 arm64 from Valve) and `xrizer` (AVP Play's own Linux ARM64 `vrclient.so` build) (`recipes/alyx.json`) |
| Toolchain inputs | entry library and obb from `targets.py` | `KL_LX_GAME`, `KL_LX_SYSROOT`, `KL_LX_XRIZER` |
| On the device | data under `Documents/android-files/…` | `Documents/lx`, sent by `stage_sync.py` through a mirror ("only libraries the game loads, no links", `Toolchain.swift:549-550`) |
| VR API | Meta's OVR / OpenXR straight to `kl_openxr` | OpenVR → xrizer (a separate GPL program the game loads) → `kl_openxr` |

Both kinds of ELF code are ARM64 already. Klepton turns them into signed code in the app at build time (`Toolchain.swift:231-233`: "also as translated code inside the program… the signed version is what is loaded"). This is the step our x86-64 → ARM64 AOT plays.

## 3. Two ways to integrate

### (a) A `skyrimvr` target inside the Klepton fork

We would put `libvxrt.a`, `libaot.a`, our AOT modules and xrizer into Klepton's visionOS app as a new target kind.

**Free:** Steam ownership check and depot fetch, signing, install, renewal, icon and hero image, the start window, room measurement and its boundary, controller mode, haptics settings and the AVP Play Remote/menu bar.

**What has to change, and the costs:**

- **Two OpenXR runtimes in one app.** Klepton's `kl_openxr.c` (10.4k lines, GLES/Vulkan only, MoltenVK) and our Metal-native provider. Its swapchains are VkImage→Metal through MoltenVK (`research/2026-11-08-klepton-extraction.md`), and our D3D11→Metal frames do not fit them. We would bypass its runtime and keep only its Swift host. That means a deep, fork-specific seam in its 382 KB compositor.
- **Our frame-ownership rules conflict with the fork's.** The fork publishes after a Vulkan wait timeout and has a fence-backlog bypass (same report). We would have to keep its compositor away from our frames.
- **Licensing.** Klepton/AVP Play are MIT, and our app statically links GPL-3 xrizer and LGPL Wine/FFmpeg-derived parts. For Alyx, xrizer stays a separate `vrclient.so` the game loads (`THIRD-PARTY.md`, xrizer section). A Klepton target with xrizer linked in would make that target's build GPL. That is fine for a local build but awkward to upstream.
- **Build and release.** Our build needs `vxrt-aot`, MinGW, the AOT pipeline and the arena layout (`XROS_ARENA=0x7000000000`, `VXRuntime/Makefile:262-266`). All of it would become part of the fork's `run.sh`, and every runtime change would need a fork release (`toolchain-N`) to reach users.
- **Upstream maintenance.** Rebasing on a 7.6k→10.4k-line fast-moving fork.

### (b) A second toolchain kind backed by VXRuntime

Here a `vxruntime` toolchain uses our own `make -C VXRuntime xros-app` plus `tools/skyrim_aot_pipeline.py` behind the same build/sync contract.

The coupling between AVP Play and a toolchain is **only files and environment variables**: the `run.sh device` + `BUILD SUCCEEDED` contract, `stage_sync.py`, `targets.py`, the `build/dd-device-<target>` product path, the asset folders and `toolchain.json`. A VXRuntime toolchain directory that implements those can run **with no change to AVP Play** for a first experiment:

| Contract file | Our implementation |
|---|---|
| `visionos/run.sh device` | Reads `KLEPTON_TARGET=skyrimvr`, `KLEPTON_TEAM`, `KLEPTON_DEVICE`, `KLEPTON_BUNDLE_ID` and `KL_LX_GAME`. Runs our prepare/AOT step (below) against the game tree, then `make -C VXRuntime xros-app` signed for the team, installs with devicectl, and prints `BUILD SUCCEEDED`. Copies the `.app` to `visionos/build/dd-device-skyrimvr/Build/Products/Debug-xros/`. |
| `visionos/stage_sync.py --phase all [--dry-run]` | Mirrors the game tree minus the exe/DLLs already in the app as AOT modules into `KL_LX_MIRROR` (dry run). Copies it to the device's `Documents/lx`, or better a VXRuntime root path AVP Play can also be told about. |
| `visionos/targets.py` | `TARGETS = {"skyrimvr": {"kind": "vxruntime", …}}` |
| `visionos/gen_xcodeproj.py` | Contains only the feature names we really honour. Its contents are what turns AVP Play's switches on (`Toolchain.swift:256-415`), so it must not claim Surreal, MetalFX or test switches we lack. |
| `toolchain.json` | Our own version and commit numbering. |

Each game can already pin its own toolchain in AVP Play. `ToolchainChoices` maps a recipe ID to a `Pin`, and a working copy at any `path` counts (`ToolchainChoice.swift:3-40`, `:63`, `:68-69`, `:305-315`). The VXRuntime toolchain can therefore be pinned for `skyrimvr` only, and the Klepton package stays the default for every other game. The upstream change is still worth proposing: a `toolchain.kind` (or a `kind` from `targets.py`) that the recipe requires. Without it, AVP Play would build Skyrim with Klepton if the pin were cleared, and would try to give a VXRuntime root the Klepton-only steps (APK prepare, pipeline lists, mods).

**Free in (b):** Steam ownership and the pinned depot fetch, marker checks, the library on an external disk, signing team handling and refusal messages, renewal reminders, the icon and hero image (as asset folders we include), device sync with retries and progress, the AVP Play Remote/menu bar and job resume.

**Not free in (b), what we have to build:**

- **A start window.** Ours is `VXApp.swift` (`WindowGroup` "display" + `ImmersiveSpace` "vr", `VXRuntime/xros/app/Sources/VXApp.swift:15-59`). Klepton's start window, boundary (`KLBoundary`) and controller code are MIT and can be adapted with attribution, as `third_party/klepton_openxr` already does for `kl_openxr.c`. The boundary is drawn by the host compositor, not passed to OpenXR, so it ports as a host overlay in our presenter and does not affect the provider.
- **Play area config.** Read `KLRoomGuardDefault`, and keep stage bounds honest exactly as Klepton does (bounds unavailable, `kl_openxr.c:4210-4221`).
- **Controllers.** Our provider's input host v3 already has the same shape as Klepton's runtime:
  - a host-reported controller kind (Touch, Index, Vive or simple);
  - activation gated on the application's suggested bindings;
  - one `InteractionProfileChanged` event per change;
  - grip/aim poses (`third_party/klepton_openxr/SOURCE.md`, input host v3).

  Missing compared with Klepton: real `AccessoryTrackingProvider` input routed into v3 (only synthetic dev-host controllers today), haptics, the Valve-frame and hand-interaction profiles, dominant-hand routing, `KLControllerModeDefault` and the `klepton.*` tuning keys. Skyrim VR uses OpenVR legacy input, which xrizer maps to the Touch, Index and Vive profiles we already accept.
- **Saves.** AVP Play only backs up `Documents/android-files` (`Saves.swift:30-37`), while our app keeps Skyrim's writes in an overlay under `Documents/root` (`VXRuntime/xros/app/Sources/main.m:38`, `:254-260`). Either AVP Play's rule gets a root per kind, or our runtime writes the `My Games/Skyrim VR` overlay under `Documents/android-files/…` (a misleading name).
- **Free teams don't work.** Our app needs `extended-virtual-addressing` (`VXRuntime/xros/app/Sources/VXRuntimeHost.entitlements`) for the guest arena, and AVP Play notes that free teams cannot have it (`Toolchain.swift:482-491`). `gen_xcodeproj.py` must not contain `KLEPTON_EVA`, so AVP Play refuses free teams up front (`Toolchain.swift:485-488`) instead of producing a broken build.
- **AOT for visionOS.** `skyrim_aot_pipeline.py` currently builds macOS ARM64 dylibs (`BUILDER`, `tools/skyrim_aot_pipeline.py:40-41`). The app path uses `tools/xros_aot.sh` with the arena base. A Skyrim module set built for `arm64-apple-xros` and embedded as frameworks is not yet demonstrated.

### Recommendation

**(b).** It keeps our D3D11→Metal renderer, direct Metal OpenXR provider and frame-ownership rules intact. It reuses everything AVP Play does well (store, fetch, sign, install, sync) through a contract that is just files and environment variables. Klepton's start window, boundary and controller UX can be adapted into our app under MIT with attribution, without fighting its runtime.

How to stage it:

1. A local contract-compatible VXRuntime toolchain directory, pinned as a working copy for the private `skyrimvr` recipe only, used with `AVPPLAY_HOME` set to an empty folder. Then the user's real AVP Play setup and toolchain choice are untouched (`DataLocation.swift:14-21`).
2. Propose `toolchain.kind` and per-recipe toolchain selection, plus a per-kind save root, to AVP Play upstream once Skyrim runs on a headset.

Avoid (a) unless the AVP Play maintainer wants all runtimes inside one fork. Even then, only the Swift host would be shared.

## 4. Recipe sketch for Skyrim VR

Inputs are taken from the user's existing install: `~/Verantyx_VR_Drive/vxrt_steam/steamapps/appmanifest_611670.acf`, buildid `2743427`. Only the two `SkyrimVR.exe` markers are confirmed:

- SHA-256 `6961efb4…7f87971` (`tools/skyrim_aot_skyrimvr.json`);
- size 35,530,960 B, which I read with `stat`.

`SkyrimVR.esm` is 332,403 B, SHA-256 `cf261da8cbfe281c87fae4b379edc5ad6635bd2fc58f1bb587eec18e7ed5df87`; I read both values from the install. Depot 611673's manifest size equals the exe's size exactly, so the exe probably comes from 611673. That is not checked.

```json
{
 "schema": 1,
 "id": "skyrimvr",
 "title": "The Elder Scrolls V: Skyrim VR",
 "package": "steam-app-611670",
 "versionName": "Steam-Build 2743427",
 "versionCode": 2743427,
 "store": {},
 "icon": { "steamAppId": "611670" },
 "toolchain": { "target": "skyrimvr", "minCommit": "<vxruntime toolchain commit>" },
 "files": [],
 "trees": [
  {
   "name": "game",
   "role": "game",
   "source": {
    "kind": "user",
    "hint": { "en": "Skyrim VR (Windows) from your own Steam account; fetched with your Steam sign-in (about 15 GB)." },
    "steam": {
     "app": "611670",
     "depots": [
      { "id": "611673", "manifest": "4815482462544068657", "bytes": 35530960 },
      { "id": "611672", "manifest": "1928013110065929089", "bytes": 439323938 },
      { "id": "611671", "manifest": "3877383290467193767", "bytes": 14641416342 }
     ]
    }
   },
   "markers": [
    { "path": "SkyrimVR.exe", "size": 35530960,
      "sha256": "6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971" },
    { "path": "Data/SkyrimVR.esm", "size": 332403,
      "sha256": "cf261da8cbfe281c87fae4b379edc5ad6635bd2fc58f1bb587eec18e7ed5df87" }
   ]
  }
 ],
 "status": { "playability": "untested", "download": "special" }
}
```

Notes on the recipe:

- **Field mapping.** `store: {}` and `package: "steam-app-…"` follow `recipes/alyx.json`. Ownership is still checked: the Steam fetch runs `licenses_for_app 611670` before any download (`Steam.swift:496-509`). Depot order follows Alyx's rule that an earlier depot is never overwritten; whether the depots overlap at all has not been checked.
- **Leave out the shared depots.** 228986 and 228990 (VC++ and DirectX redist) are not needed: VXRuntime supplies or loads its own redist (`build/xros/game_bundle/redist`, `VXRuntime/Makefile:296`).
- **`sysroot` and `xrizer` trees are not used.** xrizer is built into our app; `third_party/xrizer`.
- **SteamVR (new, under the 2026-11-09 decision).** Add an optional second tree, used only if a step needs SteamVR's own files, e.g. `vrwebhelper/win64`, already one of the `dll_roots` in `tools/skyrim_aot_skyrimvr.json`:
  - role `data` with a `dest` under our root, from app 250820 (SteamVR, a free licence; the user's `appmanifest_250820.acf` is present);
  - markers on the exact DLLs we use;
  - never committed or published.

  AVP Play's three tree roles (`game`/`sysroot`/`xrizer`) have no `steamvr` role, so this means a `data` tree or a new role upstream.

**The AOT step**, in our `run.sh` between fetch and Xcode:

1. Copy `KL_LX_GAME/SkyrimVR.exe` and the game's DLLs into `build/private/skyrimvr/<exe sha>/`. Never modify the store copy.
2. Prepare the exe as the plan already does (pinned Steamless removes the SteamStub wrapper, `plans/2026-11-08-skyrim-vr-native-darwin-aot.md`, "Active Priority"). Record input and output hashes.
3. Run `tools/skyrim_aot_pipeline.py --config <generated config> --build` for the **xros** target and arena base, then embed the modules with `xros/app/embed_aot_frameworks.sh`.
4. Build the app (`make -C VXRuntime xros-app`, signed with `KLEPTON_TEAM`).
5. `stage_sync.py` sends `Data/`, the `.ini` files, `binkw64`/media assets and anything else the game reads to the device. The exe and DLL code goes only as AOT modules inside the signed app; the original exe is still needed as data for the PE image mapping.

Translated code and prepared images stay in ignored private directories on the Mac and in the user's own signed app. Apple signing and installing to the user's own device is not distribution.

**Steamworks.** Try the existing route first: no Steam client, `steam_api64` finds no Steam (`VXRuntime/NOSTEAM.md`; Cyberpunk ran that way on the Mac). Stub `SteamAPI_*` only if Skyrim VR refuses to start without it, now allowed by the user. Ownership is already confirmed at fetch time.

## Open questions

1. Is the exact `targets.py` row for `alyx` (its `kind`) right, and what do `run.sh`, `stage_sync.py`'s file selection and the start-window SwiftUI actually contain? Checking needs the approved download of `klepton-toolchain-866-e65c433` (or the fork at that tag).
2. Would the AVP Play maintainer accept `toolchain.kind` with per-recipe toolchain selection, plus a per-kind save root? This is an outward-facing proposal and needs the user's go-ahead.
3. Where should the game tree live on the device? AVP Play's tree progress polling assumes `Documents/lx` (`Installer.swift:985`, `:1190`), and our app reads `Documents/root`. Should we make our runtime take a root from the environment or Info.plist, or ask AVP Play to make the path kind-specific?
4. Do Skyrim VR's depots overlap? Which depot carries `SkyrimVR.exe`? Does the game run with `steam_api64` finding no Steam, or does it need stubs?
5. Can a Skyrim-size AOT module set (the dev-host set is the exe split into 16 MB parts plus six DLLs) be embedded and signed within visionOS limits, and loaded within the arena on the headset?
6. Which SteamVR files, if any, are actually needed once xrizer is in the app? The answer should come from measurement, not a guess.
7. Is a GPL-3 combined app acceptable for the user's own builds? Yes for local use. Anything published would need source offers.

## What must be true in this repo first

- A Skyrim VR run on the **visionOS simulator** from our `xros-app`: AOT modules built for xrsimulator, strict AOT with zero fallback, reaching the world in both eyes. Today it has only run on the Mac dev host (`558be7d`).
- A Skyrim AOT module set built for the **device** target and embedded in a signed app that installs. Size and signing limits need to be measured.
- Real controller input through input host v3 from `AccessoryTrackingProvider` (not the synthetic dev-host controllers), with haptics or an honest refusal.
- A **physical headset test** that the user authorizes separately, then a human playtest before any "playable" claim.
- A root path the runtime takes from launch configuration, and a save location AVP Play can back up.
- Then: the local contract-compatible toolchain directory and a private recipe run under an isolated `AVPPLAY_HOME`.
