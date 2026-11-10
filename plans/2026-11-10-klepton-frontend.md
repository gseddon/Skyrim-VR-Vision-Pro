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
| `VXRT_RENDER_SCALE` | 0.7, valid 0.3-1.5 else 0.7 | `xrizer_xros_fixture.m:210-216`, `static`, first geometry query | next launch (first query of the process) | Yes (user request). Slider; Klepton's minimum is 0.5 and its step 0.05; propose 0.5-1.0. |
| `VXRT_SHOW_HANDS` | hidden | `VXApp.swift:48`, scene modifier evaluated at scene build from `ProcessInfo` | live if it becomes an observed value (Klepton's `chroma.upperLimbVisibility` pattern) | Yes (user request). Toggle "Show my real hands over the game". |
| `VXRT_PAIRS_IN_FLIGHT` | 1 (0 = no gate, max 4) | `xrizer_xros_host.m:105-111`, cached on first use | next launch | Yes, as a labelled trade-off (Latency: lower latency vs smoother game pace), 0 or 1 only. Evidence: readiness plan runs A to D (1 in flight: 77 ms pose-to-shown, 25 fresh pairs/s; no gate: 137 ms, 28/s). |
| `VXRT_PREDICT_MS` | follows the measured delay (starts 60 ms, cap 140) | `VXImmersive.swift:39-45`, instance init | next launch | Advanced only (diagnostic): Auto or a fixed ms. |
| `Documents/vxrt_sense.txt` ("pitch= yaw= roll= pos=x,y,z", re-read each second) and `VXRT_SENSE_*` | aim base, zero offsets | `VXSenseTune.swift` `refresh()` | live, within 1 s | Yes, Advanced > Controller alignment (Klepton `TuningView` equivalent): sliders write the same values; the file stays as the developer/live-copy route. |
| `VXRT_STAGE_EYE_HEIGHT` | 1.6 m | `xrizer_xros_fixture.m:165-173` | to be checked whether live (read on a lazy path) | Advanced (standing/seated height). |
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
