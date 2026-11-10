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
