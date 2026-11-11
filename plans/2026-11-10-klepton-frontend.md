# Plan: Klepton frontend for the Skyrim VR host (research phase)

Status: research only, nothing implemented. Written 2026-11-10 on the worktree branch from `codex/standalone-import` (7bf3dc7 and later).
Subject of every claim below: static reading of the fork `myMartek/Klepton` at `a7bad301` (shallow clone `build/private/klepton-src`, read-only; paths below are under its `visionos/`) and of our host (`VXRuntime/xros/app/Sources`, `VXRuntime/src/xrizer_xros_*.m`). Nothing was built, installed or launched; the headset was not touched (the foveation agent is using it) and no simulator was booted. Licence record: `third_party/klepton_host/SOURCE.md`.

## 1. Klepton's frontend, inventoried

Klepton is one SwiftUI app (`Sources/KleptonApp.swift`, `@main KleptonApp` at :338). One bundle per game ("target"); AVP Play builds it per title and bakes per-title defaults into Info.plist keys (`KL*Default`, listed in `Info.plist`).

### 1.1 Scenes and lifecycle

| What | Where | Notes |
| --- | --- | --- |
| Start/boot window `WindowGroup(id: SurrealAimGuide.launcherID) { BootView() }`, 1280x800 | KleptonApp.swift:370 | Hosts everything below. `scenePhase` handler `Lifecycle.scenePhaseChanged` is on the app phase, not this window's. |
| Immersive space `Immersive.id` with `CompositorLayer(KleptonStageConfiguration())` | :436-472 | `.immersionStyle` `.mixed` or `.full` (observed `chroma.immersionFull`), `.persistentSystemOverlays(Immersive.systemOverlays)`, `.upperLimbVisibility(chroma.upperLimbVisibility)` (reactive: a toggle changes the live space). |
| Extra windows: keyboard entry (:384), controller-recovery prompt (:394, utility panel, `.plain`, suppressed at launch), web page (:411), RealityKit switch window (:425) | | Klepton/game specific, except the controller prompt. |
| Extra spaces: surreal aim guide (:416), room measure `KLRoomFlow.spaceID` (:420), RealityKit present (:431) | | The room space is the play-area feature. |
| Boot flow: `BootView.boot()` (:1611) configures the guest, then `openImmersiveSpace(id: Immersive.id)` (:1094, :1858). `Immersive.wanted` (:70-90) makes the space the app (default on; `KL_IMMERSIVE=0` gives the window-only report). | | The window stays open beside the space unless `dismissWindow()`. |
| Backgrounding = exit (`Lifecycle`, :175-336), already adopted by us as `VXLifecycle`. | | |

### 1.2 Screens

* **Start front** `BootView.startFront` / `startFrontContent` (:1132-1300): hero art (`UIImage(named: "StartHero")`), title, big **Start** (shows Running / Starting... / Not started), **Settings**, **Measure room**, play-area choice, status line (graphics preparation progress from `kl_app_prepare_progress`, Steam Cloud status), version stamp in the corner. Gated on the `KLStartScreen` Info.plist key (AVP Play sets `KLEPTON_START_SCREEN=1`, `avp-play/core/Sources/AVPPlayCore/Toolchain.swift:464`); otherwise the developer **boot report** (`bootReport`, :1425+).
* **Settings page** `BootView.settingsPage` (:1342-1415): `NavigationStack`, title = game, **Done**, sections in this order: launcher/files panel (hl1/hl2 only), `PlayerSettingsView`, `RoomSettingsView`, player name, game language, Walkabout unlock, mod credits, mic; then `DisclosureGroup("Advanced")` with Picture in detail, max eye resolution, eye-tracked sharpness, Passthrough/chroma key, Controller alignment (`TuningView`), Test switches, Diagnostics (log export via `ShareLink`).
* **`PlayerSettingsView`** (:719-840), "the few things a player may change": Controllers (`KleptonControllerSettingsView`, `KleptonSurrealView.swift:4`: Standard vs Surreal Touch), **Picture** (foveation toggle/level, MSAA, resolution via `PicturePrimary`, `KleptonTuning.swift:1140`), **Frame rate** (100/120, :841), **Frame generation** (:860), **Your hands** (toggle "Show my real hands over the game" bound to `chroma.settings.handMatting`, plus `HandPinchView`, `KleptonTuning.swift:703`), game controller status (:890). Footer: "Changes to the picture apply the next time you start the game."
* **Controller tuning** `TuningView` (`KleptonTuning.swift:106`) and `HandTuneView` (:177): sliders for Sense grip pitch/pos/pivot and OpenXR grip/aim, live (published under a lock into the pose path and `kl_openxr_set_grip_tune`, :73); "Log as environment" prints the values as env lines (`asEnvironment()` :84). This is Klepton's equivalent of our `Documents/vxrt_sense.txt`.
* **Play area / room**: `RoomSettingsView` (`KleptonRoomSpace.swift:1504`: on/off, room-scale vs stationary, wall/fade/off at the edge, Measure room, Forget rooms), `RoomQuickSettings` (:1458), the room space and measuring flow (`KleptonRoomSpace.swift`, 1573 lines), `KLBoundary`, `KLRoomStore`/`KLRoomGuard` (`KleptonRoomStore.swift:228`).
* **Controller pairing/permissions**: no onboarding wizard. Permissions are the Info.plist usage strings (we have them). Pairing is "pair under Settings > Bluetooth" text (`GamepadStatusView` :890). After a system interruption `KLControllerRecovery` (`KleptonControllerRecovery.swift:28`, prompt view :227, state :211) raises a 184x304 utility window; one pinch on it hands the accessory list back (a pinch in the immersive space delivers no spatial events).
* **In-session overlay**: there is no menu inside the space. The window beside the space is the control surface (`handTune`, tuning, panel toggles); in game, the performance panel is toggled by controller buttons (`KleptonMetrics.swift`, `KleptonTapAction` `KleptonTuning.swift:1602`). Recentre = Sense options button (`pendingRecenter`, `KleptonControllers.swift`).
* **Branding/assets**: `Assets.xcassets` is an empty catalog in the repo; per-game `AppIcon-<target>` image stacks and `StartHero` are generated at build time from Steam art (`gen_xcodeproj.py:257,390-421`, `steam_art.py`). Strings are inline English/German pairs through `klT(en, de)` (`KleptonText.swift:11-18`; `KL_LANG` overrides); no strings table. Klepton's own name appears only in the developer boot report.

### 1.3 Settings model, persistence, delivery to the runtime

| Setting group | Model | Persistence | Reaches the runtime how |
| --- | --- | --- | --- |
| Picture: foveation, MSAA, render scale (`klepton.renderScale`, min 0.5), frame rate, output, MetalFX | `KleptonRendering.shared`, `ObservableObject` with `@Published` + `didSet` (`KleptonTuning.swift:247-575`) | `UserDefaults.standard`; per-key "target default" from Info.plist (`KLRenderScaleDefault` etc.); epoch/reset keys re-apply a new default once (:455-505) | Pushed once at boot through C seams (`kl_ovrp_set_render_scale_default(Float)`, :552). Read "when the game starts"; changing it mid-run is stored for the next start. |
| Hands / chroma | `KleptonChroma`, a Codable struct as one JSON blob `klepton.chroma` (`KleptonChroma.swift:21,79,157`) | `UserDefaults` (one key, `decodeIfPresent` so older blobs read) | `@Published settings` observed by the `App` scene, so `.upperLimbVisibility` flips live. Env var `KL_HAND_MATTING` wins when set (:112-122: "environment, then saved, then default"). |
| Controller mode | `KleptonControllerMode` (`KleptonControllerMode.swift:4`) | `@AppStorage("klepton.controllerMode")` | read by the controller stack at boot |
| Controller tune | `KleptonTuning.shared` / `KLSenseTune` | not persisted (live; printed as env lines) | published under a lock to the pose path |
| Room | `KLRoomGuard` keys via `@AppStorage`; rooms in `KLRoomStore` (a file) | UserDefaults + file | read by the compositor each frame |
| Diagnostics | `@AppStorage(KleptonDiagnostics.waitersKey)` | UserDefaults | next app start |

Delivery is therefore: UserDefaults is the store; Info.plist is the per-title default; the process environment (`KL_*`) is the developer override that wins; C functions or a lock-protected snapshot carry the value to the runtime. No IPC and no config file (our `vxrt_sense.txt` live file is a different, simpler mechanism). Helpers: `klEnvOn`, `klEnvFloat` (KleptonApp.swift:~40-67).

### 1.4 Overlap with AVP Play (read, not changed)

AVP Play (`~/git/avp-play`) is the Mac installer. It builds the per-title Klepton app and presets defaults into the bundle: `KLEPTON_RENDER_SCALE` (-> `KLRenderScaleDefault`; what the player sets in the game applies afterwards, `Toolchain.swift:406`), `KLEPTON_GAME_LANGUAGE`, controller mode (`AVPPlayCore.ControllerMode`; "shared wire values", `KleptonControllerMode.swift:3`), MetalFX/prediction presets, `KLEPTON_START_SCREEN=1`. Its README states the player-facing contract: "Every game opens with the same start window: Start, Settings for picture, play area and controls". So the unified interface the user wants IS this start window. Matching it means matching the Info.plist default keys (`KLRenderScaleDefault`, `KLHandMattingDefault`, `KLControllerModeDefault`, `KLStartScreen`) and the UserDefaults keys (`klepton.renderScale`, `klepton.chroma`, `klepton.controllerMode`) so a later AVP Play wrapper can preset and read them. AVP Play builds with Klepton's `gen_xcodeproj.py`; our app is built with XcodeGen (`xros/app/project.yml`, `make xros-app`). Whether AVP Play will later build our host or only install/launch it is open (question 7).

## 2. Comparison with our host

### 2.1 Already adopted (see SOURCE.md)

Sense tuning/prediction cap/aim base (`VXSenseTune.swift`), haptics, accessory session shape, privacy strings and `GCSupportedGameControllers`, persistent overlays hidden, backgrounding = exit, the immersive space as the app (`VXDefaultLaunch`), `.windowStyle(.plain)` + utility-panel placement, frame-loop discipline, paused/invalidated layer handling. Our loading card (`VXLoading.swift`, a bitmap blitted into the eye images) is ours, not Klepton's.

### 2.2 Our current knobs, all environment-only today

| Knob | Default | Where read | When it takes effect | Natural user setting? |
| --- | --- | --- | --- | --- |
| `VXRT_RENDER_SCALE` | 0.75 (was 0.65, before 0.55 and 0.7; with MetalFX and the hidden-area mask), valid 0.3-1.5 else 0.75 | `xrizer_xros_fixture.m:210-216`, `static`, first geometry query | next launch (first query of the process) | Yes (user request). Slider; Klepton's minimum is 0.5 and its step 0.05; propose 0.5-1.0. |
| `VXRT_SHOW_HANDS` | hidden | `VXApp.swift:48`, scene modifier evaluated at scene build from `ProcessInfo` | live if it becomes an observed value (Klepton's `chroma.upperLimbVisibility` pattern) | Yes (user request). Toggle "Show my real hands over the game". |
| `VXRT_PAIRS_IN_FLIGHT` | 1 (0 = no gate, max 4) | `xrizer_xros_host.m:105-111`, cached on first use | next launch | Yes, as a labelled trade-off (Latency: lower latency vs smoother game pace), 0 or 1 only. Evidence: readiness plan runs A to D (1 in flight: 77 ms pose-to-shown, 25 fresh pairs/s; no gate: 137 ms, 28/s). |
| `VXRT_GATE` (supersedes `VXRT_PAIRS_IN_FLIGHT` as the setting) | `smart` (off / one / smart) | `xrizer_xros_host.m` `gate_mode()`, plus `vx_xros_set_gate_mode` for a live change | live | Yes: Latency, Smart (default) / Lower latency (one) / Max throughput (off). Stored `vxrt.latency` (an older "smoother" reads as Max throughput). |
| `VXRT_UPSCALE` | `metalfx` (metalfx / bilinear) | `xrizer_xros_host.m` `upscale_requested()`, read once | next launch | Yes: Upscaling, MetalFX (default) / Bilinear. Stored `vxrt.upscale`; Info.plist `VXUpscaleDefault`. |
| `VXRT_PREDICT_MS` | follows the measured delay (starts 60 ms, cap 140) | `VXImmersive.swift:39-45`, instance init | next launch | Advanced only (diagnostic): Auto or a fixed ms. |
| `Documents/vxrt_sense.txt` ("pitch= yaw= roll= pos=x,y,z", re-read each second) and `VXRT_SENSE_*` | aim base, zero offsets | `VXSenseTune.swift` `refresh()` | live, within 1 s | Yes, Advanced > Controller alignment (Klepton `TuningView` equivalent): sliders write the same values; the file stays as the developer/live-copy route. |
| `VXRT_STAGE_EYE_HEIGHT` | 1.6 m | `xrizer_xros_fixture.m:165-173` | to be checked whether live (read on a lazy path) | Advanced (standing/seated height). |
| `VXRT_TURN` (`game`/`snap`/`smooth`), `VXRT_SNAP_ANGLE`, `VXRT_TURN_SPEED` | `game` (nothing written), no snap angle, no speed | `VXSettings.swift` -> `VXRT_INI_SET` `VRInput.bGamepadLookAngleSnapping`, `bGamepadLookAngleSnapSmoothing`, `fGamepadLookAngleSnapAmount`, `fGamepadLookAngleSnapSmoothingSpeed` (`client.c` `ini_override`) | next launch | Settings, Turning (no Klepton equivalent; UserDefaults `vxrt.turn`, `vxrt.snapAngle`, `vxrt.turnSpeed`, Info.plist `VXTurnDefault`). Tri-state: Game default writes nothing. Keys: `research/2026-11-11-skyrim-vr-gameplay-settings.md`. Not yet checked on a headset. |
| `VXRT_MOVE` (`game`/`teleport`/`walk`) | `game` (nothing written) | `VXRT_INI_SET` `VRInput.bDirectMovementWithWands` 0/1 | next launch | Settings, Movement (`vxrt.move`, `VXMoveDefault`). Not yet checked on a headset. |
| `VXRT_OVERLAYS`, `VXRT_EXIT_ON_BACKGROUND`, `VXRT_SHOW_WINDOW`, `VXRT_DISMISS_WINDOW`, `VXRT_REOPEN`, `VXRT_OVERSCAN`, `VXRT_SENSE_BASE`, `VXRT_SHARED_QUEUE` | see code | | | No: developer levers; stay env-only. |
| Foveation (later) | off | `foveation` branch (another agent; `d3d11*.m`, `dxbc.*`, `plans/2026-11-10-foveated-rendering.md`; not touched here) | | Yes, a Picture row once that branch lands. The settings model can reserve the key but must not wire it. |

### 2.3 What is missing, in order of value

1. A start window / settings page (none; our only window is a hidden 160x90 swap-chain host).
2. A settings store with Info.plist defaults and env override (none; everything is `getenv` at first use).
3. A start gate. Today the program starts at launch (`vxrt_boot` from `VXRootController.viewDidAppear`, main.m:493-513; fallback after 4 s, :515) and `getenv` is read lazily during the run. Settings must be applied before the runtime thread starts, so Start must gate `vxrt_boot`, or settings are applied from UserDefaults at process start and edits need a relaunch.
4. Live hand visibility (an observed value instead of an env read at scene build).
5. Controller alignment UI over `VXSenseTune`; controller status (which Sense controllers are paired; we already log `xr_controllers`).
6. Branding/start art and a version stamp.
7. Controller recovery prompt after a system interruption (`KleptonControllerRecovery.swift`). No such interruption problem seen in our device runs; unverified, defer.
8. Play area / recentre (`KleptonBoundary`, `KleptonRoomSpace`, `pendingRecenter`). Large; defer.
9. Log export (`ShareLink` of `host_log.jsonl`/`vxrt.log`), which we currently pull with devicectl.

### 2.4 Conflicts with our host

* **Hidden display window.** Our window exists to host the swap chain's view (`VXDisplayView`, 160x90, opacity 0, `glassBackgroundEffect(.never)`); the game's present may stall if that view is detached (SOURCE.md run 7; `VXRT_DISMISS_WINDOW` is untested). A Klepton start window is a second, visible window; the display window must stay alive and invisible while the start window is shown and after it closes. Closing the last visible scene must not look like backgrounding (our `VXLifecycle` reacts to scene phase, as Klepton does).
* **Start gate versus "boot straight into Skyrim".** The user's earlier decision was no menu. A start window changes the default launch; it needs a "Start automatically" setting (default: question 1) to keep today's behaviour.
* **Window order.** Today the display view's `viewDidAppear` starts the program and `.task` opens the space. With a start window the display view must still appear (it gives `vxrt_xros_attach` a view) but `vxrt_boot` waits for Start. `UIApplicationSceneManifest` has no scene configurations, and adding an immersive-role entry killed the simulator app (SOURCE.md, run 7), so window/space switching stays SwiftUI-driven (`openWindow`/`openImmersiveSpace`/`dismissWindow`), as in Klepton.
* **Immersive space config.** Ours `.full`; Klepton `.mixed` with a black backdrop by default, and its "Frame rate up to 100/120" choice is built on that (`Immersive.mixed`, KleptonApp.swift:~95-110). Not adopted (not measured), so no frame-rate picker until it is measured.
* **Upper-limb visibility.** Same scene modifier; ours is static from env, Klepton's observed. Easy to align; default stays hidden.
* **Loading card.** Ours is drawn into the eye drawables and is the only in-space UI; Klepton shows progress in the start window ("Preparing graphics: n of m"). With a start window we could mirror the stage text there too; the card stays.
* **Own frame loop.** Nothing in the frontend needs `KleptonCompositor`. Its links into the frontend are C seams (`kl_app_*`, `kl_ovrp_*`, `kl_present_*`, `KLRun`) that we do not have and must not import.
* **Foveation branch.** Do not touch `d3d11*.m`, `dxbc.*`; the settings model may reserve a key only.

### 2.5 Klepton-specific, not worth bringing

Surreal Touch (`KleptonSurreal*`), Alyx panel (`KleptonAlyx.swift`, 1390 lines), HL1/Xash launcher and game data (`KleptonLauncher`, `KleptonHL1`, `KleptonGameData`, `KleptonBackup`), Steam Cloud (`KleptonSteamCloud`, `SteamCloudKit/`; also an authentication matter we do not take on), Walkabout/Beat Saber/mod-credits views, MetalFX preset and frame generation (`KleptonMetalFX*`, `KleptonFrameGen`), chroma/passthrough key beyond the hand toggle, Apple Music, mic, web and keyboard windows, RealityKit present, test switches, `kl_app.c`, `SurrealHarness/`, `XboxPWA/`, `lx/`.

## 3. Integration options

All options keep our compositor, runtime and loading card. SOURCE.md's approach (reimplement with the Klepton file named as reference) continues; MIT permits copying with the notice, so small self-contained pieces (the Codable settings-struct pattern, `klT`, two-language strings) may be adapted verbatim where noted.

### Option A: start window with a settings sheet (minimal)

A SwiftUI `VXStartView` window (title, Start, Settings) plus a settings page (Render scale, Show real hands, Latency, Start automatically, Advanced > controller alignment, predict ms, stage eye height, log export) and a `VXSettings` store (UserDefaults, Info.plist defaults, env override) and a start gate in `vxrt_boot`. Keys use Klepton's names so AVP Play can read/preset them. Layout and wording follow Klepton's `PlayerSettingsView` (GroupBox sections, grey callout explanations, "Changes apply the next time you start", English/German through a `klT`-style helper).
* Pros: smallest change; fits the existing app; covers the two requested settings and the other levers; reversible through "Start automatically".
* Cons: only a "somewhat" unified look; no shared code with Klepton; each later Klepton feature needs another port.
* Effort: about 1.5-2.5 days agent time (store and gate 0.5-1, views 0.5-1, live hands and sense tuning 0.25-0.5, simulator smoke check and plan/notice updates 0.25-0.5), plus one headset run, with the user's approval, to confirm that the settings change the physical session.

### Option B: Klepton-style launcher shell with Skyrim as its single title

Option A plus Klepton's start front (hero art, large Start, Settings, status line, version stamp, boot-progress bar mirrored from `vx_xros_load_stage`), the `NavigationStack` settings page with the same section order and Advanced disclosure, controller status/pairing text, and later the controller-recovery prompt and play-area pieces. Same Info.plist default keys as AVP Play's presets.
* Pros: closest look and wording to the user's other Klepton apps; the page grows by adding sections as features appear (foveation, recentre).
* Cons: more screens to keep working without Klepton's runtime seams; art/branding decisions (no Skyrim art can be committed); more headset testing; risk of drifting from Klepton anyway.
* Effort: about 4-6 days agent time (A plus start-front art, progress mirror, controller status, recovery prompt) and headset time for the start/launch flow, window dismissal and the game-keeps-presenting question.

### Option C: shared Swift package with Klepton's UI

Extract `PlayerSettingsView`, `KleptonRendering`, `KleptonChroma`, `TuningView`, `RoomSettingsView` into a package both apps use.
* Pros: genuinely shared interface.
* Cons: those files are entangled with Klepton's C runtime (`kl_app_*`, `kl_ovrp_*`, `kl_reproject_*`, `klIsAlyx()`, `KLRun`) and per-target Info.plist; the extraction would be done in a 31.9k-line tree maintained by others (upstream shinyquagsire23, fork myMartek), so we would maintain a fork.
* Effort: 2+ weeks and coordination with the fork's owner. Not recommended.

### Recommendation

**Option A now, shaped to grow into B.** Build the settings store, the start gate and the settings view with Klepton's layout, wording style, keys and Info.plist default names. Start/Settings with: Render scale, Show real hands, Latency (pairs in flight), Start automatically, and Advanced (controller alignment sliders over `VXSenseTune`, predict ms, stage eye height, log export; a reserved Foveation row hidden until the `foveation` branch is merged). Add B's art, progress mirror and controller status when the user wants the full launcher look. C is not worth doing.

Implementation outline for A (for later, once questions are answered; not started):
1. `VXSettings.swift`: struct with the keys above, shared `ObservableObject`, UserDefaults store, Info.plist defaults (`VXRenderScaleDefault`, `VXShowHandsDefault`, `VXStartAutomatically`), environment override wins (Klepton's order, `KleptonChroma.swift:95-122`). At the gate it exports `VXRT_RENDER_SCALE`, `VXRT_PAIRS_IN_FLIGHT`, `VXRT_PREDICT_MS`, `VXRT_STAGE_EYE_HEIGHT` with `setenv(..., 0)` so an explicit env still wins and the C side is unchanged.
2. Gate in `main.m`: `vxrt_boot` waits for a start flag set by Start (or is immediate with Start automatically); `vxrt_boot_fallback` must not fire while the start window is up.
3. `VXApp.swift`: add the start `WindowGroup`, keep the `display` window, observe `VXSettings` for `.upperLimbVisibility`; dismiss the start window after the space opens only once it is shown that the game keeps presenting.
4. `VXSenseTune`: the tuning sliders write the live tuple and the same `vxrt_sense.txt` format; pose maths unchanged.
5. Checks: `make -C VXRuntime check`, `check-arm64`, simulator `xros-app` build and a UI smoke check of the start window and settings (screenshot) and that the fixture still reaches the first pair with defaults; a Mac unit test of the settings-to-env mapping; then one headset run, with approval, for the user to confirm render scale, hands and latency take effect.

## 4. Licences and attribution

* Klepton is MIT, Copyright (c) 2026 Max Thomas; the fork (myMartek) carries the same text (hash recorded in SOURCE.md, identical to `third_party/klepton_openxr/LICENSE`). `THIRD_PARTY_NOTICES.md` already has "Klepton visionOS host conventions (2026-11-10)" (:83-89) and the Sense-controller section (:73-81); `SOURCE.md` lists files read.
* For A/B: extend the SOURCE.md "Adopted" table with each frontend piece (file, line, reimplemented vs adapted), add the newly read files (`KleptonApp.swift` BootView/PlayerSettingsView/settingsPage, `KleptonTuning.swift` KleptonRendering/TuningView, `KleptonChroma.swift`, `KleptonText.swift`, `KleptonRoomSpace.swift` RoomSettingsView) with the SHA-256 of the fork's copies; put a header comment in every new Swift file derived from Klepton (as `VXSenseTune.swift` has: copyright, repository, pinned revision, lines); name the new files in the THIRD_PARTY_NOTICES section.
* No hero art, icons or Klepton name/logo are in the repo (`Assets.xcassets` is an empty catalog; art is generated from Steam at build time). Steam/Bethesda art must not be committed, so our branding starts as text or a plain monogram we make (question 5).
* German strings are the Klepton author's text; verbatim reuse falls under the same MIT notice; our own wording avoids it.
* AVP Play has its own LICENSE and THIRD-PARTY.md; nothing is copied from or changed in it. Shared key names are interface facts, not copied code.
* AGENTS.md: record per piece the pinned revision and local modifications; update this plan only with verified work; leave headset checks unchecked until the user confirms.

## 5. Venues

* Mac: build, `make check`, the settings-to-env unit test, XcodeGen project.
* Simulator: build and UI smoke check of the start window and settings (screenshot) plus the existing fixture path; any simulator booted is shut down afterwards.
* Headset: not used in this phase (the foveation agent has it); install and launch need the user's approval. Evidence that render scale, hands and latency settings change the physical session is a headset item.

## 6. Open questions

Relayed to the user in the final message of the research phase; answers will be recorded here before implementation.

## 7. Option D: fork Klepton itself and keep our Skyrim runtime as its single title (asked 2026-11-10)

### 7.1 What "Klepton's runtime" is (what option C and D would tie us to)

Klepton runs **Android ARM64 VR APKs** on the Vision Pro: `klepton-ld` translates the guest's `.so` libraries into Apple dylibs/frameworks which link into a C runtime (`README.md`, Architecture); GLES goes through a vendored ANGLE (Metal backend), Vulkan through MoltenVK. The runtime is the C tree `runtime/` (`jni/`, `linux/`, `libc/`, `gfx/`, `xr/`, `guest/`, `media/`; e.g. `kl_jni.c` 178 KB, `kl_image.c` 88 KB, `m_boot.c` 52 KB) with a JNI emulation, an Android-ish libc/linux layer, an OpenXR/OVR provider (`kl_openxr`, `kl_ovrp`) and the one-process, one-guest model ("the guest boots once per process", `Sources/KleptonApp.swift:1611-1620`). The app is a thin Swift platform layer over a C seam (`Sources/Klepton-Bridging-Header.h`: `kl_app.h`, `kl_glfb.h`, `kl_ovrp.h`, `kl_openxr.h`, `kl_reproject.h`, `kl_audio.h`, `kl_present.h`, `kl_mono.h`). Our app runs something different: **Windows x86-64 Skyrim VR** AOT-compiled to ARM64 by VXRuntime, with D3D11-to-Metal, xrizer as OpenVR and our own provider.

Frontend dependence on that runtime (counts of `kl_*(` calls / `"KL_*"` env reads): `KleptonApp.swift` 44 / 40; `KleptonTuning.swift` 20 / 71; `KleptonRoomSpace.swift` 29 / -; `KleptonChroma.swift` 1 / 7 (the chroma panel's `kl_reproject_set_chroma`, :175 area; the hand toggle itself has none). Examples: `boot()` calls `kl_app_configure`, the target table and `klAlyxApply()` before the runtime reads its environment (:1611-1640); the picture settings end in `kl_ovrp_set_render_scale_default` (`KleptonTuning.swift:552`); the start window's presentation mode comes from `kl_present_mode_now()` (`KleptonApp.swift:~1050`); `Immersive.wanted` reads `kl_app_target_is_steamlink()` (:70-90); tuning publishes through `kl_openxr_set_grip_tune` (`KleptonTuning.swift:73`); the room feature draws through Klepton's compositor. Every one is a seam we would have to re-implement against our runtime or delete.

### 7.2 D against A and B

| Aspect | D (fork Klepton, Skyrim as a target) | A / B (our host, Klepton-style frontend) |
| --- | --- | --- |
| Upstream fixes | Upstream `shinyquagsire23/Klepton` pushed 2026-11-10; the myMartek fork had about 60 commits in the last 3 weeks (up to 15 a day), "coarse history", private tree landing per release. A merge of the app shell would be cheap only while we keep its files untouched; but the fixes that matter upstream are in the guest runtime and `KleptonCompositor` (6.7k lines), which we would have deleted. The frontend files change often (`KleptonApp.swift` 1.9k, `KleptonTuning.swift` 1.7k lines), so every merge touches the places we edited. | None to track; we re-read the fork periodically and port by hand (as SOURCE.md does). |
| Delete / keep | Delete: `runtime/`, `guest/`, ANGLE, MoltenVK, `klepton-ld`, `KleptonCompositor`, Surreal, Alyx, HL1, Steam Cloud, mic, audio, frame generation, MetalFX, room space (all tied to `kl_*`). Keep: `KleptonApp` scene wiring, `BootView` start front, `settingsPage`, `PlayerSettingsView`, `KleptonRendering`/`KleptonChroma` models, `klT`, Info.plist `KL*` keys, `Lifecycle`. That is under 15% of the 32k Swift lines, and what remains still imports the seam header. | Nothing deleted; we add about 1k lines of our own. |
| Env naming | We could make the new settings code read `KL_*` first with `VXRT_*` as aliases (one helper, `klEnvOn`-style, checks both), or keep VXRT_* and accept KL_* aliases. Cheap in either direction, and it does not need a fork. Most Klepton env names are for its runtime (`DEBUG_ENV_VARS.md`, 330 KB) and have no meaning for ours; only the shared user-level ones (`KL_FULL`, `KL_OVERLAYS`, `KL_EXIT_ON_BACKGROUND`, `KL_HAND_MATTING`, `KL_LANG`) map. | Same alias helper in our own `VXSettings`. |
| Build system | Klepton is `gen_xcodeproj.py` + `targets.py` + `run.sh`/`mkguest.sh`/`stage_assets.sh`, with `make xros` building its C runtime. Our app is XcodeGen (`xros/app/project.yml`), `make xros-app`, `embed_aot_frameworks.sh`, `libvxrt.a`/`libaot.a`. D means replacing Klepton's generator with ours or teaching `gen_xcodeproj.py` a second runtime; either way two build systems or a rewrite, and our `make check` targets and the vxrt harness assume the current layout. | Unchanged. |
| Licence | MIT, Copyright (c) 2026 Max Thomas; fine for a fork, notices kept. Note the fork README says it is the AVP Play toolchain; our changes would not be upstreamable. | MIT notices as in section 4. |
| Our host moving into Klepton's structure | `VXImmersive` (738 lines: compositor loop, provider queue, fresh/repeat/stale counters, loading card, anchor handling), `native_vr_present.m`, `VXNativeXRTracking`, `VXSenseTune`, the xrizer provider and `main.m`'s boot would all be re-plumbed behind `KleptonApp`'s scenes and its `kl_app_*` boot, or `KleptonCompositor` replaced by ours. All of the headset-proven path (runs A to D) sits in exactly these files. | None. |
| Signing / bundle id | Klepton derives bundle ids `gseddon.dev.klepton.target.*` from `targets.py`, team via `KLEPTON_TEAM`, entitlements `Klepton.entitlements`; our device build is `gseddon.dev.vxrt.SkyrimVR`, team MA9VLPU826, and app data (15 GB game, caches) lives in that container. Changing the id loses the staged game and caches. Solvable (set the id in the target table) but a re-stage. | Unchanged. |
| Effort | Roughly 2-3 weeks: carve out the frontend (1 week, because of the seam), port our host under it or the reverse (1 week), build-system merge and re-verification of the headset path (0.5-1 week), plus an ongoing merge cost. | A 1.5-2.5 days, B 4-6 days. |
| Risk to the working headset path | High. The path that works (display-rate compositor, own provider queue, one pair in flight, Sense aim pose, backgrounding, layer reopen) would be moved, and the headset is shared with the foveation work. | Low: additive; the gate defaults to today's behaviour. |

### 7.3 Recommendation, and a hybrid

D is not better than A for us. Its benefit (shared UI, shared names, upstream fixes) is mostly available without it, and its cost is moving every proven file. Upstream fixes that matter to us are in code D would delete.

The hybrid the user is asking for is worth doing, in a bounded form: **"A+" = vendor Klepton's settings model and views as a small module inside our host, keeping Klepton's keys and names, with the seams replaced by one protocol.** Concretely:
* Copy (MIT, with headers and the pinned revision) `klT`/`KLText`, the `PlayerSettingsView`/`settingsPage` layout, the `KleptonRendering` and `KleptonChroma`-hands models with their UserDefaults keys (`klepton.renderScale`, `klepton.chroma`, `klepton.controllerMode`) and Info.plist `KL*Default` keys, with every `kl_*` call removed behind a small `VXSettingsSink` that our host implements (exports `setenv(VXRT_*, 0)` at the start gate; live hand visibility; Sense file writer).
* Env names: one helper reads `KL_*` and `VXRT_*` (shared user-level names accept both; ours stay VXRT_* as canonical because the C code reads them), so scripts written for Klepton apps work.
* Keep our loop, compositor, provider queue, loading card and Sense tune untouched.
* Cost over A: about +1 day (vendoring with minimal edits and tracking drift against the pinned `a7bad301`), for views that look and behave like the other Klepton apps and would be easy to refresh from the fork. Risk stays low. This is the recommended form of option A; B's extras can follow.

Open for the user: whether "common names" means UserDefaults/Info.plist keys (cheap, recommended) or the full `KL_*` environment surface (not meaningful for most of it, see 7.2).

## 8. Implementation of option A+ (2026-11-10)

User answers (relayed): Klepton's UserDefaults and Info.plist key names and a familiar layout, not the KL_* env surface; VXRT_* stays canonical with KL_* aliases only for mapped user-level settings; Start window plus "Start automatically" (default off); render scale 0.5 to 1.0 step 0.05 default 0.7; latency "Lower latency" (1 pair in flight, default) or "Smoother pace"; Advanced with controller alignment, predict ms, stage eye height and log export; Skyrim branding, text only (no Bethesda or Steam art in the repo); English only; play area, controller-recovery prompt and frame-rate picker out of this phase.

### 8.1 What was built (subject: owned fixture on the visionOS simulator plus Mac unit test; not the device, not the game)

| Piece | File | Notes |
| --- | --- | --- |
| Settings store | `VXRuntime/xros/app/Sources/VXSettings.swift` | Klepton keys `klepton.renderScale` and `klepton.chroma` (JSON blob, `handMatting`), Info.plist defaults `KLRenderScaleDefault`, `KLHandMattingDefault` (our default: hidden when absent), `KLAutoBootDefault`; ours namespaced `vxrt.latency`, `vxrt.startAutomatically`, `vxrt.predictMs`, `vxrt.stageEyeHeight`. Precedence as Klepton: environment, saved, plist, built-in. Env: `VXRT_RENDER_SCALE` (alias `KL_OVRP_RENDER_SCALE`), `VXRT_SHOW_HANDS` (`KL_HAND_MATTING`), `VXRT_START_AUTOMATICALLY` (`KL_AUTOBOOT`), `VXRT_PAIRS_IN_FLIGHT`, `VXRT_PREDICT_MS`, `VXRT_STAGE_EYE_HEIGHT`; `KL_OVERLAYS`, `KL_EXIT_ON_BACKGROUND` aliases in `VXApp.swift`. |
| Start window and settings page | `VXStartView.swift` | Title, Start, Settings, status (runtime milestones), version stamp; settings: Resolution, Latency, Your hands, Start; Advanced: controller alignment (writes `Documents/vxrt_sense.txt`, which `VXSenseTune` re-reads each second), head prediction, stage eye height, log export. 5 s countdown with Cancel when "Start automatically" is on, so settings stay reachable. |
| Gate | `VXApp.swift`, `Info.plist` `VXStartWindow`, `main.m` `vxrt_default_launch()` | Gated only when the build asks (`XROS_START_WINDOW=1`, default on for `XROS_XRIZER_GAME=1`), the launch is the default one (no `-test`/`-game`) and `VXRT_START_WINDOW` is not 0. The display window (swap-chain host, hidden, unchanged) is opened by Start; its view starts the program (`vxrt_boot`), so `VXSettings.applyEnvironment()` (setenv with overwrite off) runs before the runtime reads anything. `vxrt_boot_fallback` is called by Start instead of at launch. |
| Live settings | `VXApp.swift` (hands scene modifier observes `VXSettings`), `xrizer_xros_host.m` `vx_xros_set_pairs_in_flight` | Hand visibility and latency change at once; resolution, predict ms and eye height apply on the next launch. |
| Branding | `CFBundleDisplayName` = `$(VXRT_DISPLAY_NAME)` ("Skyrim VR" for the game build), title text in the start window. | No icon artwork yet (default icon): not done. |
| Test | `VXRuntime/tests/xros_settings_test.swift`, `make -C VXRuntime xros-settings-check` (part of `check`) | persistence, precedence, aliases, clamps, plist presets, a Klepton-written blob, gate, sense file. |

Bundle id and team are unchanged (`gseddon.dev.vxrt.SkyrimVR`, MA9VLPU826).

### 8.2 Verification

* `make -C VXRuntime xros-settings-check`: "xros settings: ok".
* Simulator build (`XROS_SDK=xrsimulator XROS_XRIZER_FIXTURE=1 XROS_START_WINDOW=1 XROS_DEFAULT_LAUNCH="-test xrizer_xros_guest -immersive"`, owned fixture guest): app builds. Fresh install, default launch: the log has `app_init` with `start_window:true`, then only `scene_phase`/`heartbeat`: no program started, and the start window is on screen (screenshots under `/tmp/claude/perf/klepton-frontend/start2.png`, `settings1.png`: title, Start/Settings, version stamp; settings with Resolution 70%, Latency, Your hands off, Start). With defaults written for the app (`klepton.renderScale` 0.85, `vxrt.latency` smoother, `vxrt.startAutomatically` true): 5.4 s after launch `settings_applied` logs `VXRT_RENDER_SCALE=0.85 VXRT_PAIRS_IN_FLIGHT=0`, the runtime log shows "render scale 0.85 (VXRT_RENDER_SCALE)" and the fixture guest passes ("OpenVR geometry, two D3D pairs and provider readback passed"). The simulator was shut down; the app was uninstalled.
* Not verified: any tap interaction (no tool for touch/gaze input on the simulator; the slider, toggle and Start button were exercised only through the stored values and the countdown path), the physical device (not touched), the real game, the live latency gate on a running game, the live hand toggle.

### 8.3 Start while loading: boot timeline and decision

Measured from an existing Mac run of the actual game rather than a new one (the Mac GPU was busy with the foveation agent's replays; the run is the cold `--helgen` boot `build/play-105948/startup.log`, main checkout, harness start 10:59:52.1; analysis notes in `/tmp/claude/perf/boot/STATUS.md`). Timestamps are the runtime's own (`VXRT_LOG_TIME`), seconds after the first line:

| Step | Cold run | Warm runs (same notes) |
| --- | --- | --- |
| AOT modules mapped | +0.6 | 0.04 s load |
| xrizer `VR_Init` (native Init) and first `IVRSystem` call | +1.0 | |
| `GetRecommendedRenderTargetSize` (System019 slot 7) | +1.0 (the same millisecond group as Init) | |
| XAudio2 created | +2.7 | |
| `IVRCompositor` interface, first `WaitGetPoses` (first frame) | +6.5 | first fresh pair 5.3 s |
| Loading menus | 6 to 69 s | loading to about 17 s |
| Main menu | +78 to 86 s | |
| Cart/title visible | +100 s | |

Shader cache: warm per-user Metal cache; the cold run compiled for 66 s with no fresh pair until +66.3 s. Shader-set mapping on the device is a separate cost (the device uses the embedded set; no device timeline was measured here).

Result by the coordinator's rule: the render-size request is at about +1 s of a 17 s (warm) to 80 s (cold) boot, so most of the boot comes AFTER it. Option 1 (hold at the render-size request) would preload only about 1 s, so **option 2 (hold at the first frame or later) is the one that pays**, at the cost of the render scale being fixed at that point (changing it then needs an app restart, since the guest is one per process).

Why it was not implemented in this change (blocked by structure, not by time): on the device the xrizer host is created only when the immersive space opens (`VXImmersiveRenderer.start` -> `vx_xros_fixture_start`, `xrizer_xros_fixture.m:149`), and the loader waits for it before anything else (`loader.c:1682`, `vx_xros_fixture_wait_ready`, 30 s then `exit(1)`: "compositor geometry unavailable; refusing startup"), i.e. before the AOT modules are even opened (the "render scale" line is the fourth line of the runtime log, before the first `aot:` line). So with the space held closed, the game is held at its very first instruction, and nothing is preloaded. Preloading needs: (1) the xrizer host created before the space (device and queue from `MTLCreateSystemDefaultDevice`, not from the layer); (2) view geometry (FOV tangents, recommended size) answered without a layer, from values persisted by the previous run, which is wrong on a first run or after a geometry change; (3) a hold in the provider's `wait_frame`/`xrBeginSession` until Start, with the game silent (audio muted) and drawing nothing; (4) re-binding the compositor to the already running host when the space opens (the layer-reopen path `VXImmersiveRenderer.previous` already does this for an invalidated layer, so there is a precedent); (5) timeouts: `vx_xros_mailbox_wait(..., 2000)` in `wait_frame` and the 30 s ready wait both need to be longer than a user's dwell in the start window, and the device watchdog behaviour for an app with a window but no presenting immersive space must be checked on the device. None of it can be tested without the headset, and it changes the path that works. Recommendation: do it as its own piece after the foveation work has released the device, hold at the first frame (about 6.5 s cold-mac, 5.3 s warm) as the first cut and at "menu loaded" later (the runtime already reads the menu stack with `diag-rtti-array`), keep "Start automatically" as no hold. The Settings page already marks resolution as "applies the next time".

The latency gate is now live (`vx_xros_set_pairs_in_flight`), as requested; the game is not silenced or held because it is not started before Start.

### 8.4 For AVP Play (not wired)

The design leaves AVP Play room to prepare and install the game later (AOT module frameworks, shader set, game files) and launch with preset settings: it can write the same Info.plist keys (`KLRenderScaleDefault`, `KLHandMattingDefault`, `KLAutoBootDefault`, `VXLatencyDefault`, `VXStartWindow`), UserDefaults keys, or pass `VXRT_*` environment variables through `devicectl --environment-variables` (env beats saved beats plist, so a preset launch is never overridden by what the window saved). `XROS_START_WINDOW` and `XROS_DISPLAY_NAME` are Makefile variables for the build. Nothing in AVP Play was changed.

### 8.5 Deferred (user, 2026-11-10): preload while the start window is up

Start-while-loading (hold the booted game at its first frame or at "menu loaded", release on Start) is deferred; the user will take it up later. Notes for then: the numbers in 8.3 are from a cold Mac boot (before the shader cache merge) and must be re-timed from a warm boot (Mac `build/private/shadercache`; the headset has the embedded 10,807-shader set) before judging whether decoupling the xrizer host from the compositor (8.3, items 1 to 5) pays; keep the deferral if the warm gain is a few seconds. Record first fresh pair, main menu ready and audio start. "Start automatically" never holds. Nothing in this change prevents it: the gate is Swift-side (display window opened by Start), the latency gate is already live.

## 9. App name and icon (2026-11-10)

The app is "Skyrim VR": `CFBundleDisplayName` and `CFBundleName` are `$(VXRT_DISPLAY_NAME)` (project.yml default and `XROS_DISPLAY_NAME`, both "Skyrim VR"); bundle id (`gseddon.dev.vxrt.SkyrimVR` for `XROS_XRIZER_GAME=1`) and team are unchanged. The user's picture is committed (their approval, 2026-11-10) as `VXRuntime/xros/app/IconSource/skyrim-icon.jpeg` with `README.md` for its origin; `IconSource/make_icon.swift` generates the committed visionOS solid image stack `VXRuntime/xros/app/Icon/Assets.xcassets/AppIcon.solidimagestack` (Back plain black, Middle empty, Front the picture with its black keyed to transparency, 1024x1024 each). `project.yml` lists `Icon` as a source and sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; the fixture build links it into its generated project. To change the icon: replace the picture and rerun the command in the README. Verified on the simulator build: `Info.plist` has CFBundleDisplayName and CFBundleName "Skyrim VR", `Assets.car` holds AppIcon as a SolidImageStack with Back/Middle/Front at 1024 px. Not verified: how the icon looks on the Home View (device not used).

### Defaults changed (2026-11-10, branch `integrate`)

Render scale 0.75 with MetalFX upscaling and the smart pair gate are the defaults in the runtime and in the settings (`VXSettings.swift`: `renderScaleBuiltIn` 0.75, `VXUpscale` default metalfx, `VXLatency` default smart; `exports()` writes `VXRT_RENDER_SCALE`, `VXRT_UPSCALE`, `VXRT_GATE`). Evidence, headset, actual game, user-verified the same day: smart vs one gate on the cart ride 35.2 vs 29.1 fresh pairs/s, pair age 75.7 vs 72.1 ms (`/tmp/claude/perf/smartgate/STATUS.md`); 0.55 + MetalFX judged sharp enough (`/tmp/claude/perf/metalfx/STATUS.md`); 0.75 judged "much nicer" on the headset on 2026-11-11 (run4, 30-33 fresh pairs/s, GPU 31-33 ms per pair, not a cart window, `/tmp/claude/perf/device-combined/run4/`). Mac check: `make -C VXRuntime xros-settings-check` (defaults, persistence, env precedence, the old "smoother" value). The settings page itself was not looked at on the device in this change.
