# Klepton visionOS host: what was read, what was adopted

Klepton (MIT, Copyright (c) 2026 Max Thomas; license text `third_party/klepton_openxr/LICENSE`, SHA-256
`8705e40805c9267df365b89ceaa34a56498e34b7d3b6ebb95e9c12a7d3827a2b`, identical in both repositories below).

## Sources read (2026-11-10)

| Repository | Revision | Use |
| --- | --- | --- |
| `https://github.com/myMartek/Klepton` (the fork AVP Play builds the user's `gseddon.dev.klepton.target.*` apps from) | `a7bad301c10b03e7d615ae8d51033146c373bcb5` (2026-11-10, "Merge #122") | read in a shallow clone under the git-ignored `build/private/klepton-src/`; not vendored |
| `https://github.com/shinyquagsire23/Klepton` (upstream) | `1fe7e6caf6bb8bc90c1a5e61d5b9bfc6e110fa32` | the earlier pin of `third_party/klepton_openxr/SOURCE.md`; not fetched again |

Files read in the fork, `visionos/Sources/` (SHA-256 of the fork's copies): `KleptonControllers.swift`
`03b5603e0b2dc84aa6ee10949bf8a3a66be30e90d2518177e189438fb162b4e5` (3072 lines), `KleptonApp.swift`
`f3532650d3b0f6bb0abcae483d66096e513d373b1a68cfe42ff4ba0c6a3afb86`, `KleptonCompositor.swift`, `KleptonControllerRecovery*.swift`,
`KleptonControllerMode.swift`, and `visionos/Info.plist` `8448a9b6e0c4468ee9c40eab028e00163a6ec3dce55779174eaf674f75ef7ce0`.

## Adopted into `VXRuntime/xros/app/`

| Piece | Klepton origin | Local form |
| --- | --- | --- |
| Sense controller tuning, 50 ms prediction cap, grip correction | `KleptonControllers.swift` `KLSenseTune`, `sensePose` (pinned earlier at upstream `1fe7e6c`) | `VXSenseTune.swift` (already present, unchanged here) |
| CoreHaptics engine and continuous player per hand | `KleptonControllers.swift` haptics engine (same pin) | `VXSenseHaptics.swift` (already present, unchanged here) |
| Accessory session shape: `Accessory(device:)` per `GCProductCategorySpatialController`, one `AccessoryTrackingProvider`, the shared `ARKitSession` re-`run()` with a rebuilt provider list when a controller connects or disconnects, without stopping it (`makeAccessoryProvider`, `spatialControllersChanged`) | `KleptonControllers.swift` ~605-760 | `VXNativeXRTracking.swift` already followed it; this change starts it in the xrizer immersive build too and logs the paired set once per change |
| Info.plist privacy strings and controller profiles: `NSWorldSensingUsageDescription`, `NSBluetoothAlwaysUsageDescription` (spatial controllers), `NSAccessoryTrackingUsageDescription`, `NSHandsTrackingUsageDescription`, `GCSupportedGameControllers` (`SpatialGamepad`, `ExtendedGamepad`) | `visionos/Info.plist` | `xros/app/Sources/Info.plist` (the first two are new) |
| Scene conventions: `.persistentSystemOverlays(.hidden)` (lever `VXRT_OVERLAYS=1`) | `KleptonApp.swift` `Immersive.systemOverlays` | `VXApp.swift` |
| Backgrounding ends the process: a crown press (layer invalidated, then scene inactive) or the system backgrounding exits, every launch is a first launch (lever `VXRT_EXIT_ON_BACKGROUND=0`) | `KleptonApp.swift` `Lifecycle.scenePhaseChanged`, `leave()` | `VXApp.swift` `VXLifecycle` (xrizer immersive build only; no game-quit handshake, no audio) |
| The immersive space is the app: launch, space opens, game starts; no menu | `KleptonApp.swift` `Immersive.wanted` (default on) | `main.m` + Info.plist `VXDefaultLaunch` (`XROS_DEFAULT_LAUNCH`, set to `-game skyrimvr -xrizer -immersive` for `XROS_XRIZER_GAME=1`) |

Nothing is copied verbatim beyond the two pinned files above; the other items are reimplementations of the same behavior
with Klepton's file and symbol named as the reference.

## Not adopted, and why

* **`KleptonCompositor.swift` (6739 lines) and `KleptonStageConfiguration`.** The compositor is bound to Klepton's own runtime:
  its ANGLE-owned eye textures, `kl_app_*`/`kl_ovrp_*` C seam, guest fence, MetalFX/frame generation, chroma/boundary
  passes. Our loop (`VXImmersive.swift`) draws xrizer's D3D11 eye pairs through `native_vr_present.m` with the non-blocking
  submit (3dca360) and the fresh/repeat/stale counters, which Klepton does not have. The structure (query frame, update,
  predict timing, wait for the optimal input time, drawables, device anchor, submit; paused/invalidated handling) is the
  same as ours. `KleptonStageConfiguration`'s foveation (amplified single pass drawing through the rasterization rate map,
  `maxRenderQuality`) needs a composite that honors the rate map; ours does not, so foveation stays off. Its layered layout is
  not used for the same reason (our draw is per-eye, dedicated). Colour `bgra8Unorm_srgb` and depth `depth32Float` are already
  ours.
* **Mixed immersion with a black backdrop** (`Immersive.mixed`, `mixedBlack`): a 100 Hz versus 120 Hz decision made on Klepton's
  measurements; not measured here, the space stays `.full`.
* **Launcher and settings UI** (`KleptonLauncher.swift`, `KleptonShell.swift`, `KleptonTuning.swift`, `KleptonRendering`),
  **play area and recentre** (`KleptonBoundary.swift`, `KleptonRoomSpace.swift`, `pendingRecenter` via the Sense options
  button), **controller setup/recovery** (`KleptonControllerRecovery.swift`: a prompt window and one pinch after a system
  interruption; `KleptonControllerMode.swift`: Standard/Surreal), **Surreal Touch**, **hand matting** (`upperLimbVisibility`),
  **gamepad-only fallback** (`pollGamepad`), **steam cloud, audio, mic, web windows**. Out of scope for the first boot-into-Skyrim
  test by the user's decision; recorded as follow-ups in `plans/2026-11-10-skyrim-device-readiness.md`.
* **Klepton's default grip offsets** (ALVR 5.037 deg tilt, -37 deg hilt pitch, fixed offset): for Unity/OVR guests, not
  measured for Skyrim VR; the levers `VXRT_SENSE_*` remain.
* **Klepton's "unspecified chirality means right hand"** (`consumeAccessoryAnchors`): ours pairs `heldChirality` with inherent
  chirality and drops ambiguous pairs (`vxSpatialHandIndex`, `vxSpatialUnambiguousIndices`); kept.
* **`anchorUpdates` stream plus stored anchor**: ours polls `latestAnchors` and `predictAnchor` per sample; kept.
* **Klepton's device-anchor walk-back and hold-last-pose** (`displayAnchor`, `originFromDevice`): not adopted yet; ours
  passes no anchor to the drawable when ARKit answers nil. A candidate follow-up if the device log shows `queryDeviceAnchor`
  returning nil under frame hitches.

## Local changes since the earlier pin

See `git log -- VXRuntime/xros/app` on the branch `worktree-agent-af19bef3afdccd68f`; the controller session start, the
`xr_controllers` and `xr_controller_state` log events, `VXLifecycle`, `VXDefaultLaunch`, and the `-controllers` mode of the owned
guest are ours.

## Frame-loop discipline ported after device run 2 (2026-11-10)

Device run 2 was SIGKILLed by the system 2.7 s in (termination namespace `0x28`, no app fault, no jetsam). Compared with the fork
(`KleptonCompositor.swift` `renderFrame`, `csFrames`, `runARKit`, `startRenderLoop`) at `a7bad301`:

| Area | Klepton | Ours before | Ported (`VXImmersive.swift`, `VXNativeXRTracking.swift`) |
| --- | --- | --- | --- |
| Submission order | `queryNextFrame`, `startUpdate`/`endUpdate`, `predictTiming`, wait `optimalInputTime`, `queryDrawables`, command buffer, THEN `startSubmission`; every bail-out before that abandons the frame without opening a submission; `endSubmission` once, after commit | `startSubmission` BEFORE `queryDrawables`; an empty drawables list or a failed command buffer left a started submission behind | Klepton's order; bail-outs leave before `startSubmission` |
| ARKit and the loop | the loop thread waits for the layer, ARKit starts beside it; ONE `session.run([world, hands?, accessories])` | the loop thread was created only after ARKit runs (run 1); a head-only `run` followed by a second `run` that paused head queries (the gate) | loop thread first; on the xrizer path one `run` with the head and the Sense accessories (`VXNativeXRTracking.start` -> `refresh`), also when the accessory provider is unsupported (head only) |
| Drawable device anchor | `drawable.deviceAnchor = anchor` every frame (nil is a refusal the system understands), `encodePresent` every drawable | same | unchanged |
| Space style | `.immersionStyle`, `.upperLimbVisibility`, `.persistentSystemOverlays(.hidden)` | `.full`, overlays hidden | unchanged (mixed/black backdrop and hand matting not adopted) |
| Placeholder | black where there is no picture (`mixedBlack`) | near-black clear | pulsing grey-blue clear plus a head-locked 160 px square (blit from a buffer) until the first pair |

Not ported: the anchor walk-back/hold (`displayAnchor`), `waitForInflightFrame`, the RealityKit hand-over. Added here, not from Klepton:
`frame_trace` (first 8 frames), per-second `anchor_present/tracked/missing`, `submit_ms_*`, `input_wait_ms_max` in the `vr` event, and a
0.5 s main-thread `heartbeat` event in `host_log.jsonl`.

The 385 GB `Guard` region in the crash report is the system's own: `va_range` (mach_vm_range_create) returned 46 for all four candidates and
`va_guard_1gb` could not map (`alloc_kr` 3), so our `va_range_make` claimed none of it; `va_range_extended` only accounts the 63 GB
`0x7040000000-0x8000000000` app range for `VirtualAlloc`. The 52 GB shared region at `0x2ea000000` is the dyld shared cache.

## Run 7 reconciliation with the fork (2026-11-10)

Compared again with `KleptonApp.swift` (BootView `openImmersiveSpace(id: Immersive.id)`, `dismissWindow()` once `.opened`) and `KleptonCompositor.swift`
(`csFrames`, `attach(layer:)`, `afterOutputEnded`) at `a7bad301`:

* **Paused layer.** Klepton's `csFrames` handles `.paused` by `waitUntilRunning()` and carrying on (plus an audio rebuild). Ours declared the xrizer
  surface lost on the first pause, one-way, which xrizer answers with a panic. Ported: a pause is waited out and logged (`vr_pause`, `vr_resume`).
* **Invalidated layer.** Klepton breaks out of `csFrames` and `afterOutputEnded` waits (10 s) for a replacement layer on the same running compositor
  (`attach(layer:)` hands the new `LayerRenderer` to the loop's owner) while the guest keeps running. Ported in shape: on `.invalidated` the loop ends, the
  space is reopened (`VXLifecycle.layerInvalidated`, five tries), and the new `CompositorLayer` closure builds a renderer that reuses the running ARKit
  sessions, the Sense adapter and the xrizer provider (`VXImmersiveRenderer.previous`). Klepton keeps one compositor object; ours makes a new renderer and
  copies its state, because the Swift renderer owns per-layer queues and the fixture start flags.
* **Per-frame presentation.** Klepton composes every display frame from the newest complete guest stage and reprojects when there is no new one; ours does
  the same (`present_begin`: fresh, repeat, stale, none). Added `presentation_interval_ms` and `frame_total_ms_max` to the per-second `vr` event to see
  the system's cadence (device run 6: 39 compositor frames/s while loaded).
* **Start window.** Klepton calls `dismissWindow()` once the space is open. Not ported: our window hosts the game's DXGI swap chain (the runtime's flat
  display), which would be detached, and the reopen handler lives in that view. It stays, 160x90 at 2% opacity.
* **Info.plist.** Adding the `UISceneSessionRoleImmersiveSpaceApplication` entry with `UISceneInitialImmersionStyle` (as Klepton's plist has) made the
  simulator app die at launch ("given a scene with role UISceneSessionRoleImmersiveSpaceApplication but no scenes declared in your app body match this
  role"); our `ImmersiveSpace` is opened from the window, so the entry was reverted and `UISceneConfigurations` stays empty. The default role is the window role,
  as Klepton's.
* **Immersion style.** Klepton's `Immersive.id` space is `.mixed` (black backdrop drawn where there is no picture) unless the target wants `.full`; ours is
  `.full`.

## Settings store and start window (2026-11-10, option A+ of `plans/2026-11-10-klepton-frontend.md`)

Read again in the fork at `a7bad301` (SHA-256 of the fork's copies): `KleptonApp.swift` `f3532650d3b0f6bb0abcae483d66096e513d373b1a68cfe42ff4ba0c6a3afb86`,
`KleptonTuning.swift` `0cb132e4db4dcb772646ff6cb637efda5f4edf7de942e4fe6591bedb90eb9710`, `KleptonChroma.swift`
`b9ef748a3704906f6d54462a962603d9d13904727504c88917f3a78eeab84d6c`; also `KleptonText.swift`, `KleptonControllerMode.swift`, `Info.plist`.
Nothing copied verbatim; MIT header and the reference lines are in each new file.

| Piece | Klepton origin | Local form |
| --- | --- | --- |
| Render scale stored as `klepton.renderScale`, range 0.5 to 1.0, step 0.05, per-title default `KLRenderScaleDefault`, env alias `KL_OVRP_RENDER_SCALE` | `KleptonTuning.swift` `KleptonRendering` :252, :427-455, :525, :562 | `VXSettings.swift` (default 0.7; `VXRT_RENDER_SCALE` canonical) |
| Hand visibility as `handMatting` in the Codable blob `klepton.chroma`, default `KLHandMattingDefault`, env `KL_HAND_MATTING`; precedence environment, saved, plist, built-in | `KleptonChroma.swift` :21-122 | `VXSettings.swift` (default hidden when the plist has no key, unlike Klepton's shown; `VXRT_SHOW_HANDS` canonical); scene `.upperLimbVisibility` observed live in `VXApp.swift` |
| Start automatically (`KL_AUTOBOOT`, `KLAutoBootDefault`) | `KleptonApp.swift` :1142, :1573 | `VXSettings.swift` `vxrt.startAutomatically`, 5 s countdown with Cancel |
| `KL_OVERLAYS`, `KL_EXIT_ON_BACKGROUND` aliases | `KleptonApp.swift` :158, :196, :219 | `VXApp.swift` (VXRT_* canonical) |
| Start front (title, Start, Settings, status line, version stamp), settings page (NavigationStack, GroupBoxes, grey callouts, Advanced disclosure, Done), alignment sliders | `KleptonApp.swift` :1132-1300, :1342-1415, :719-840; `KleptonTuning.swift` :106 | `VXStartView.swift` (English only; text-only branding) |
| Latency choice, predict ms, stage eye height, log export | none (ours) | `VXSettings.swift` keys `vxrt.*` |

Not adopted in this change: play area/recentre, controller recovery prompt, frame-rate picker, localisation (`klT`), foveation.
