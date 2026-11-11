# Skyrim VR gameplay INI settings for the launcher (2026-11-11)

Subject: static analysis of the user's prepared `SkyrimVR.exe` (sha256 8daf0519..., read as data with `strings -a`; path in `tools/skyrim_aot_skyrimvr.json`) plus
repository code. **[exe]** = present as a `Key:Section` string in the exe (the game builds its settings from these). **[code]** = our repository.
Not verified by any run: default values, and which exact behaviour each key gives in play.

## Keys used (all [exe])

| Launcher setting | Key | File / section | Type | Written value |
| --- | --- | --- | --- | --- |
| Turning: Snap | `bGamepadLookAngleSnapping` | SkyrimPrefs.ini `[VRInput]` | bool | 1 (and `bGamepadLookAngleSnapSmoothing` 0) |
| Turning: Smooth | `bGamepadLookAngleSnapping` | `[VRInput]` | bool | 0 |
| Snap angle | `fGamepadLookAngleSnapAmount` | `[VRInput]` | float, degrees | 10..90 |
| Turn speed | `fGamepadLookAngleSnapSmoothingSpeed` | `[VRInput]` | float, unit unknown | 0.1..10 (placeholder range) |
| Movement: Walk | `bDirectMovementWithWands` | `[VRInput]` | bool | 1 |
| Movement: Teleport | `bDirectMovementWithWands` | `[VRInput]` | bool | 0 |

Related keys in the exe: `fGamepadLookAngleSnapAmountMin/Max` and `fGamepadLookAngleSnapSmoothingSpeedMin/Max` in `[VR]` (limits of in-game sliders, so the
game has a menu with a snap-angle slider and a smoothing-speed slider), `bGamepadLookRecalibrate`, `bUseWandDirectionalMovement` (walking direction follows the wand,
not the head), `bEnableAutoTeleport:VRInput`, `bAutoTeleportEnabled:VRTeleport`, and the calibration strings `Calibration - Locomotion Text` and
`Calibration - Turning Type Text`: the choices are the VR calibration/settings screens' own, and the same keys are read from SkyrimPrefs.ini
(plans/2026-11-08-standalone-skyrim-terra-continuation.md:345 [code]: the game reads `bDirectMovementWithWands`, `bUseWandDirectionalMovement`,
`bEnableAutoTeleport`, `bGamepadLookAngleSnapping`, `[VRComfort]` there, with the seeded `bOneTimeCalibrationCompleted=1` skipping the calibration).

Defaults: not in the exe's strings (they are compiled in); the first Mac or device launch logs them (`skyrim_ini: [VRInput] ... = value (default)`, see below).
Community memory says snap turn 30 degrees and teleport are the defaults; not checked. Unverified meaning: whether `bGamepadLookAngleSnapSmoothing` 1 with Snapping 1 is
an animated snap and whether `fGamepadLookAngleSnapSmoothingSpeed` also drives continuous turning when Snapping is 0. That is the first headset check.

## Interaction with the game's own saved choice [code]

* The game's in-game choice is saved with `WritePrivateProfileString` into SkyrimPrefs.ini. Our layer does not keep those writes (`VXRuntime/src/extras.c:825-831`,
  logged "not kept"), so on the device the game's own choice does not persist between launches at all, and a stored launcher choice does not fight it.
* Even so the design is tri-state: "Game default" writes nothing, so the key comes from the file exactly as before. A key is overridden only when the player picked it
  (`ini_override` in `client.c` runs before the file; it replaces the value on every read, so a game-side change in a session is read back as the launcher's value).
* A value picked in the game menu in one session is therefore lost at exit if the launcher also sets that key; leave it on "Game default" to take the game's own.

## Delivery

`VXSettings` exports the keys as `VXRT_INI_SET` (`Section.Key=Value;...`; first match wins in `ini_override`, so a launch's own `VXRT_INI_SET` entries come first and the
launcher's follow). Inputs: `VXRT_TURN=game|snap|smooth`, `VXRT_SNAP_ANGLE`, `VXRT_TURN_SPEED`, `VXRT_MOVE=game|teleport|walk`; UserDefaults `vxrt.turn`, `vxrt.snapAngle`,
`vxrt.turnSpeed`, `vxrt.move`; Info.plist defaults `VXTurnDefault`, `VXMoveDefault`. The values are logged once per launch by the runtime
(`skyrim_ini: [VRInput] bDirectMovementWithWands = 1 (VXRT_INI_SET)`), which is how to see that the game read the override.

## Other settings (all implemented 2026-11-11 as tri-state launcher settings, default "Game default"; keys [exe])

| Idea | Key | Section | Note |
| --- | --- | --- | --- |
| Left-handed | `bLeftHandedMode` | `[VRInput]` | already in our seeded prefs (0) [code]; sheathing and weapon hand swap |
| Walk direction | `bUseWandDirectionalMovement` | `[VRInput]` | direction from the wand instead of the head; natural pair of Walk |
| Comfort vignette | `bComfortModeWhileTurning`, `bComfortModeWhileMoving`, `fComfortModeSize` | `[VRComfort]` | the tunnel vignette |
| Height | `fCharacterHeightOffset`, `fDefaultEyeHeight` | `[VR]` | the game's own height; distinct from VXRT_STAGE_EYE_HEIGHT |
| Subtitles | `bGeneralSubtitles`, `bDialogueSubtitles` | `[Interface]` | also `bShowSubtitleSpeakerName` |
| Compass / crosshair | `bShowCompass`, `bShowCrosshair` | `[Interface]` | HUD clutter |
| HUD messages / tutorials | `bShowHUDMessages`, `bShowTutorials` | `[Interface]` | |
| Hands when sheathed | `bShowHandsWhileSheathed`, `bAlwaysShowHands` | `[VRInput]`, `[VR]` | |
| Sneak comfort | `bComfortSneak` | `[VR]` | |
| Teleport fade / lerp | `bTeleportFade`, `bLerpTeleportEnabled`, `fMaxTeleportDistance` | `[VRTeleport]` | |
| Roomscale | `bEnableRoomscaleMovement` | `[VR]` | relevant to a seated or standing start |
| Always run | `bAlwaysRunByDefault` | `[Controls]` | |
