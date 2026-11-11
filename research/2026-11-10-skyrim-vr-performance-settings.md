# Skyrim VR INI settings that can cut GPU cost on the Vision Pro port (2026-11-10)

Subject: static analysis only. No game run, no device, no files copied. Tags: **[exe]** = found as a `key:Section` string in the
user's prepared `SkyrimVR.exe` (`build/private/skyrimvr/6961efb4.../prepared/SkyrimVR.exe`, read with `strings -a`, output in /tmp/claude);
**[code]** = verified in our repository (file:line); **[web]** = from memory of community guides, NOT re-checked.
Web access was mostly blocked in this session: UESP, Nexus, PCGamingWiki, Reddit and the Beyond Skyrim wiki returned 403/404 or were
refused by the fetch tool. So **no default values or impact figures below are verified**; every "default" column entry is a
recollection and must be read from the device's real files (see section 3, `VXRT_TRACE_INI`). Candidate sources to read by hand:
https://en.uesp.net/wiki/Skyrim:Ini_Settings , https://www.pcgamingwiki.com/wiki/The_Elder_Scrolls_V:_Skyrim_VR ,
https://www.nexusmods.com/skyrimspecialedition (search "Skyrim VR performance"), https://www.reddit.com/r/skyrimvr (wiki, "performance").

## 1. Which INI files and sections the exe reads [exe]

* File names in the exe: `Skyrim.INI`, `SkyrimVR.INI`, `SkyrimPrefs.ini`, `SkyrimCustom.ini`, `Skyrim_default.ini`, and `.\Low.ini`, `.\Medium.ini`,
  `.\High.ini` (quality-preset files, location unknown; the install has 4 ini files per plans/2026-11-10-skyrim-device-readiness.md:71). The
  string `%sdata/%s.ini` also exists. `SkyrimPrefs.ini`/`SkyrimCustom.ini` are opened as `\My Games\Skyrim VR\.\%s`.
  Earlier trace (plans/2026-11-08-standalone-skyrim-terra-continuation.md:345): the game reads `C:\users\vxrt\Documents\My Games\Skyrim VR\SkyrimPrefs.ini`
  (and `SkyrimVR.INI`, `SkyrimCustom.ini`); `Skyrim.ini` is read from the game folder (device-readiness plan :72). Precedence between them is not
  verified here; classic Skyrim: Skyrim.ini, then SkyrimPrefs.ini, then SkyrimCustom.ini overrides [web]. Use `VXRT_TRACE_INI` to see which file answers each key.
* **Not in the exe at all (do not bother):** `bSAOEnable`, `bFloatPointRenderTarget`, `iTexMipMapSkip`, `iMultiSample`, `iMaxAnisotropy`,
  `bUseFoveated`, `bEnableReprojection`, `fRenderResolutionScaleFactor` (named in plans/2026-11-10-performance-handoff.md:70, wrong name),
  `bLensFlare`/`bDoLensFlare`, `iBlurDeltaMult`. Nothing in the exe provides foveation or ini-controlled reprojection; the real render-scale key is
  `fRenderTargetSizeMultiplier:VRDisplay` [exe]. Lens flare exists only as `fLensFlareGlobalIntensity`, `fLensFlareFalloffRange` [ImageSpace].
* In-game "VR Performance" menu [exe, Scaleform strings]: `iQualityPreset:VRPerformance` (Low/Medium/High), Supersampling, Min Dynamic Resolution,
  Shadow Quality, Shadow Distance, Rain Occlusion, Temporal AA, Tree Shadows, Disable Model LODs, Disable Tree LODs, Tree LOD Distance, Skinned Trees,
  Animated Trees, Actor/Item/Object/Grass Fade. These set ini values underneath, so the game has the knobs; the menu itself is the easiest
  human check but needs controllers.
* Dynamic resolution exists: `bEnableAutoDynamicResolution`, `fLowestDynamicWidthRatio`, `fLowestDynamicHeightRatio`, `fRatioIncreasePerSeconds`,
  `fRatioDecreasePerSeconds`, `iUnstableFrameTimeHistorySize`, `bCompensateUnstableFrameTime` [Display], `fDecreaseDRMilliseconds`, `fIncreaseDRMilliseconds`,
  `fDRClampOffset` [exe]. It reacts to frame time, so it would interact with our compositor/gate; measure with it off first.

## 2. Setting table (section / what / impact). Defaults: unverified [web], read them on device.

Impact classes: **PX** = per-pixel (scales with render scale), **SH** = shadow maps (independent of scale), **GEO** = geometry/draw calls, **CPU**.
All names below are present in the exe unless marked "absent".

| Setting | Section | Controls | Impact | Notes |
| --- | --- | --- | --- | --- |
| `fRenderTargetSizeMultiplier` | VRDisplay | game's own render-target scale on top of the runtime's recommended size | PX, ~1:1 (sweep: GPU ms ~ pixels) | Overlaps with `VXRT_RENDER_SCALE`; whether our `GetRecommendedRenderTargetSize` is multiplied by it is not checked. Prefer `VXRT_RENDER_SCALE` (compositor-side, already measured) |
| `iShadowMapResolution` | Display | sun shadow map size (SE/VR default 2048 [web]) | SH: fill and bandwidth, quartered at 1024 | Not scale-dependent; try 1024 |
| `fShadowDistance` | Display | distance the cascades cover (default ~8000 [web]) | SH + GEO (casters drawn) | Lower to ~3000-4000: fewer casters, higher texel density |
| `iNumSplits`/`iNumFocusShadow`/`fFirstSliceDistance`/`fSplitOverlap` | Display | cascade count and focus shadows | SH | `iNumSplits` default 3 [web]; focus shadows add casters for NPCs |
| `iShadowMaskQuarter` | Display | shadow mask at 1/4 area (default 4 [web]) | PX (mask resolution) | Already low; `bDirShadowMapFullViewPort` [Display] present too |
| `bShadowsOnGrass` | Display | grass receives shadows | PX in grass areas | Off = fewer shadow reads on grass |
| `bTreesReceiveShadows`, `bDisableHighTreeShadow`, `fMaxHeightShadowCastingTrees`, `bDrawLandShadows`, `bActorSelfShadowing` | Display | tree/land/actor shadow casting | SH + GEO | Land shadows and tree shadows are big casters; `bDrawShadows`=0 is the upper bound test |
| `fShadowBiasScale`, `fShadowClampValue`, `fShadowDirectionalBiasScale` | Display | depth bias only | none | Quality (acne), not cost |
| `bEnableVolumetricLighting`, `bVolumetricLightingEnableTemporalAccumulation`, `fVolumetricLightingTemporalAccumulationFactor` | Display | volumetric (god ray) lighting | PX (raymarch) if active in VR | Present in the exe but whether VR's renderer uses it is unknown. `bUseSunbeams` [Display] = screen-space sun rays |
| `bDoDepthOfField` | Imagespace | DoF image-space pass | PX | Also `bDynamicDOF`, `bDOFBilateralBlur`, `fDynamicDOF*`, `fDDOF*` [Display]; DoF is nauseating in VR, likely off by default [web] |
| `bDoRadialBlur`, `iRadialBlurLevel` | Imagespace | radial blur | PX | |
| `bScreenSpaceReflectionEnabled` | Display | SSR on water/wet | PX | Plus `bDownSampleNormalSSR`, `fWaterSSR*`, `fReflection*`. Vanilla Skyrim VR does not have SSR [web]; keys exist in the binary |
| `bUseWater`, `bUseWaterReflections`, `bUseWaterRefractions`, `bUseWaterDisplacements`, `bUseCubeMapReflections` | Water | water effects | PX + GEO (reflection pass re-draws the scene) | Reflection pass is a second scene render; `uMaxExteriorWaterReflections`, `uMaxInteriorWaterReflections` [Water] cap the count |
| `bReflectLODObjects/LODLand/LODTrees/Sky`, `bReflectExplosions`, `bForceHighDetailReflections`, `bForceLowDetailWater`, `fCubeMapRefreshRate` | Water | what the reflection draws | GEO / PX | `iWaterReflectWidth/Height` are **absent** in the exe (not read); reflection size is `iReflectionResolutionDivider` [Display] |
| `bUseTAA`, `bTAAWater`, `fTAA*` | Display | temporal AA | PX (resolve pass; cheap) | In the VR menu ("Temporal AA"). Probably cheap relative to the ~27 ms; but removing it also removes jitter/ghosting |
| `bFXAAEnabled` | Display | FXAA | PX (cheap) | |
| `bImageSpaceEffects` | Display | master switch of image-space pass chain | PX | Upper-bound test: off removes bloom, DoF, HDR tone passes |
| `bUse64bitsHDRRenderTarget`, `bUse16BitsDepthTarget`, `bUseFilmicCurve` | Display | HDR target format (RGBA16F vs 32-bit) | PX bandwidth | `bUse64bitsHDRRenderTarget`=0 halves HDR target bytes; may band. `bFloatPointRenderTarget` is absent |
| `bUseFullResDepthBuffer`, `bUseHiddenAreaMesh`, `bDepthBufferCulling` | VR / VRPerformance | hidden-area mesh culls pixels outside the lens; depth culling | PX / GEO | `bUseHiddenAreaMesh` needs xrizer to supply the mesh (`GetHiddenAreaMesh`); not checked. Possible free win: verify it is set and delivered |
| `bEnableParallaxOcclusion`, `bEnableSnowMask`, `bEnableSnowRimLighting`, `bSimpleLighting`, `bCharacterLighting`, `bEnableProjecteUVDiffuseNormals`, `bIndEnable` (indirect lighting), `bEnableStippleFade` | Display | shader-feature switches | PX | `bSimpleLighting`=1 is a large PX cut at a visible price; `bIndEnable`/`fIndIntensity` indirect-lighting pass |
| `iMaxDecalsPerFrame`, `iMaxSkinDecalsPerFrame` | Display | decal spawns per frame | GEO/PX, small | `uMaxDecals`, `uMaxSkinDecalPerActor` [Decals] (hard caps), `bDecals`, `bSkinnedDecals` |
| `bDrawShaderGrass`, `bAllowLoadGrass`, `bAllowCreateGrass`, `fGrassStartFadeDistance`, `fGrassMinStartFadeDistance`, `fGrassMaxStartFadeDistance`, `fGrassFadeRange`, `iGrassCellRadius`, `iMinGrassSize` | Grass | grass presence and distance | GEO + PX overdraw | Needs an exterior scene (menu has none); `iMinGrassSize` bigger = sparser |
| `fLODFadeOutMultObjects/Items/Actors`, `fObjectLODMin/Max`, `fItemLODMin/Max`, `fActorLODMin/Max`, `fLODMultTrees`, `fTreesMidLODSwitchDist`, `fMeshLODLevel1/2FadeDist`, `fBlockLevel0/1Distance`, `fBlockMaximumDistance`, `fSplitDistanceMult` | LOD / Display / TerrainManager | view distance for objects, actors, trees, terrain blocks | GEO | Cart ride and exterior only; `bAutoViewDistance`, `iAutoViewMinDistance`, `iAutoViewHiFrameRate` [Display] is an automatic view-distance governor |
| `iMaxDesired` | Particles | particle count cap | GEO + PX (overdraw) | Cart ride has fire/dust |
| `uLightCount`, `uLightExcessGeometry`, `fLightLODRange`, `fLightLODStartFade` | BudgetCaps / Display | dynamic light limits | PX in forward lighting | Fewer lights = fewer shaded passes |
| `fGamma`, `fGammaMin/Max` | Display | output gamma | none | No cost; ignore |
| `iVSyncPresentInterval`, `iPresentInterval` (absent) | Display | vsync | none here | Present is ours |
| `iFaderUITextureSize`, `iHudMenuTextureSize`, `iProjectedMenuTextureSize`, `iWorldUITextureSize`, `iVRWindowSize` | VRDisplay | UI render targets (Scaleform) | PX (UI compositing) | Menu scene is mostly this; lowering is quality loss on text |
| `bDisableParabolicLights`, `bDisableSkyLODSwap`, `bUsePrecipitationOcclusion` | VRDisplay / Display | misc. VR switches | PX/GEO | Rain occlusion is in the VR menu ("Rain Occlusion") |
| `bEnableFrontToBackPrepass`, `bLodZPrepass`, `bDisableZPrepassOutput` | Display | z prepass | GEO vs PX tradeoff | On a tiled GPU a prepass may cost more than it saves; try both. Unverified |

Community performance lore [web, unchecked]: "godrays off", "DoF off", "shadow distance and resolution down", "grass fade down", "ShadowsOnGrass=0",
"water reflections off", and SteamVR supersampling as the main lever. Treat as hypotheses only.

## 3. How the runtime supplies INI files [code]

* **Mac dev run:** `tools/play_skyrim_dev.sh:120` (`--helgen`) passes `--overlay-ini Skyrim.ini:General:sIntroSequence=`;
  `tools/vxrt_native_startup.py:250-280` writes a per-run copy of `Skyrim.ini` under the overlay with one key changed (CRLF, original untouched; spec
  `FILE:SECTION:KEY=VALUE`, repeatable, flag defined at :479). The Mac prefs seed is `tools/prefs_seed/611670/drive_c/users/vxrt/Documents/My Games/Skyrim VR/SkyrimPrefs.ini`
  (576 bytes: `[VR] bOneTimeCalibrationCompleted=1`, `[VRInput] bLeftHandedMode=0`, `[Display] iSize W/H=1024 ...`), copied into the private root by
  `--prefs-seed` (`vxrt_native_startup.py:235-248`, flag :478). So on the Mac, perf keys can be added as more `[Display]` lines in a variant seed
  directory, or via `--overlay-ini Skyrim.ini:Display:iShadowMapResolution=1024`.
* **Device:** `VXRuntime/xros/app/Sources/main.m:357-370` (`skyrimvr_start`): game dir `VXRT_SKYRIM_DIR` (default `<Documents>/root/SkyrimVR`), overlay
  `VXRT_OVERLAY=<game dir>:<root>/overlay_skyrimvr`. The runtime root is `<Documents>/root` (`VXRT_GAME_ROOT`). A listing of the device container
  (/tmp/claude/perf/pixeltest/fs.txt) shows `root/SkyrimVR/Skyrim.ini` (2 KB), and
  `root/drive_c/users/vxrt/Documents/My Games/Skyrim VR/SkyrimPrefs.ini` (576 bytes: the seed is already staged on the device), plus `root/overlay_skyrimvr/`.
* **Overlay reads win:** `VXRuntime/src/files.c:233-236`: a path under the overlaid tree is served from the overlay copy if one exists (and
  `vx_overlay_file`, :149). So a small `Documents/root/overlay_skyrimvr/Skyrim.ini` (copied with devicectl) overrides the 15 GB tree's `Skyrim.ini` with no
  redeploy. `SkyrimPrefs.ini` is outside the overlaid tree (drive_c), so replace that file directly (576 bytes; one `devicectl device copy to`, but file
  service stalls were seen, plans/2026-11-10-skyrim-device-readiness.md:260).
* **Built 2026-11-11 (branch `combined`):** `VXRT_SKYRIM_PRESET=p2|off` (the app sets p2 by default, `main.m`; unset elsewhere = off) and `VXRT_INI_SET="Section.Key=Value;..."` (wins over the preset) in `VXRuntime/src/client.c`, applied to the `Skyrim*.ini` files only, replacing exactly the named keys wherever the game reads them (so no file copy on the device). P2 = the keys of section 4 except the "half" particle/decal caps (defaults unknown). Each preset key, `iShadowMapResolution`, `fShadowDistance`, `bUseTAA` and `iQualityPreset` is logged once per launch as `skyrim_ini: [Section] Key = value (source)`; `VXRT_TRACE_INI=1` logs every key. Mac helgen run: the keys took effect (`bUseTAA = 1 (default)`, `iQualityPreset = 1 (default)`: neither is in the files). Below is the original proposal:
* **Best lever (proposal, now built as above):** an env-driven override applied where the ini text is read, `ini_read`/`ini_string`/`GetPrivateProfileInt`
  in `VXRuntime/src/client.c:203-260` (they already have a `VXRT_TRACE_INI` hook at :211, :257). Add `VXRT_INI_SET="Display.iShadowMapResolution=1024;Display.fShadowDistance=3000;..."`
  consulted before the file in `ini_find`. Then every arm of `tools/device_scale_sweep.sh` is just another `EXTRA_ENV` entry (script :14 and :70-72 already
  pass `EXTRA_ENV` into the launch `--environment-variables`), no file copy, no overlay state to forget. Verify with `VXRT_TRACE_INI=1` in the same launch (it logs
  every key asked for and whether found). Caveat to check first: if the game writes settings back (it did not on the Mac: "the game writes no setting through WritePrivateProfileString", plan 2026-11-08 :161), nothing persists.
* **First step before any arm:** one launch with `VXRT_TRACE_INI=1` listing every key the game asks for and the value found/default, which gives the real
  defaults and confirms which of the names above are consulted (the exe strings only show names exist, not that VR code reads them).

## 4. Headset A/B plan

Method: `tools/device_scale_sweep.sh` at a fixed `VXRT_RENDER_SCALE` (use `ORDER=0.7`, the user's default), measure GPU ms/pair via
`tools/device_scale_analyze.py` (baseline: main menu 0.7 = 27.0 ms/pair; plan :263 table). Alternate runs A B B A, sensor covered for
static pose, one launch per arm, arms back to back, headset worn. Always keep the baseline arm in the same sweep (menu GPU load varies by scene
time). Menu arms show only PX settings; SH/GEO settings need the Helgen cart ride (or Riverwood) and a repeatable pose, so for those use
the scripted input (`VXRT_XROS_TEST_HANDS`, plan :200) so every arm sees the same route, and compare GPU ms/pair over the same cart-ride seconds.

Presets (all `[Display]` unless stated):

* **P1 "VR performance"** (aim: the most GPU for the least visible loss; expect the PX keys to help in the menu):
  `bDoDepthOfField=0` [Imagespace], `bEnableVolumetricLighting=0`, `bUseSunbeams=0`, `bUseTAA=0` (test alone too), `bUse64bitsHDRRenderTarget=0`,
  `bScreenSpaceReflectionEnabled=0`, `bIndEnable=0`, `iShadowMapResolution=1024`, `fShadowDistance=3500`, `bShadowsOnGrass=0`,
  `bTreesReceiveShadows=0`, `bUseWaterReflections=0` / `uMaxExteriorWaterReflections=0` [Water], `bEnableParallaxOcclusion=0`,
  `fGrassStartFadeDistance=2500` [Grass], `iMaxDesired=` half [Particles], `iMaxDecalsPerFrame=` half.
* **P2 "balanced"**: P1 minus `bUseTAA`, `bIndEnable`, `bUse64bitsHDRRenderTarget`; shadows 1536/5000; water reflections kept at sky-only
  (`bReflectLODObjects/LODLand/LODTrees=0`, `bReflectSky=1`).
* **P3 "upper bound / diagnostic"** (not for play): `bImageSpaceEffects=0`, `bDrawShadows=0`, `bSimpleLighting=1`, `bUseWater=0`. It says how much of the 27 ms
  is the settings world at all; if P3 is still near 20 ms, the cost is in the base opaque/lighting pass and the translator, not in toggles.

Ordered single-key tests (menu first, one arm each; "needs scene" = effect mostly invisible on the menu):

| # | Arm | Where it shows |
| --- | --- | --- |
| 1 | `bDoDepthOfField=0` | menu (PX); the menu may use DoF blur behind panels |
| 2 | `bImageSpaceEffects=0` (diagnostic) then, if big, bisect: `bUseTAA`, `bEnableVolumetricLighting`, `bUseSunbeams`, `bDoRadialBlur` | menu |
| 3 | `bUse64bitsHDRRenderTarget=0` | menu (bandwidth) |
| 4 | `bUseTAA=0` | menu |
| 5 | `iShadowMapResolution=1024`, `fShadowDistance=3500`, `bDrawShadows=0` (separately) | **needs scene** |
| 6 | `bShadowsOnGrass=0`, `bTreesReceiveShadows=0`, `bDrawLandShadows=0` | **needs scene** (exterior) |
| 7 | `bUseWaterReflections=0`, `bUseWaterRefractions=0` | **needs scene** (cart ride passes water/the cart ride starts near rivers; check) |
| 8 | grass: `fGrassStartFadeDistance=2500`, `iMinGrassSize=` larger; LOD: `fLODFadeOutMultObjects/Items/Actors` down; `iMaxDesired` | **needs scene** |
| 9 | `bSimpleLighting=1`, `uLightCount` down | menu + scene |
| 10 | `bEnableFrontToBackPrepass` / `bLodZPrepass` toggled | scene |
| 11 | `bEnableAutoDynamicResolution=1` with `fLowestDynamicWidthRatio=0.6` | scene; measures the game's own governor against our gate |
| 12 | `bUseHiddenAreaMesh` and delivered mask: confirm in `VXRT_TRACE_INI` and by checking xrizer's `GetHiddenAreaMesh` output | menu |

Each result row records: arm, ini keys (and the `VXRT_INI_SET` string), scale, scene (menu/cart-ride second range), fresh pairs/s, GPU busy, GPU ms/pair,
and whether a key was actually asked for (trace), per the evidence rules in AGENTS.md. A visual check (the user, headset, same pose) goes with any
preset before recommending it; frame-time gain alone is not the verdict. The expected total is bounded: even if all PX effects vanish, the sweep
says GPU time is proportional to pixels (27 ms at 0.7), so a 11 ms budget needs about 2.5x; render scale 0.45-0.5 plus the cheapest
settings, foveation or MetalFX upscale, are more likely than ini toggles alone. That is a prediction, not a measurement.

## 5. Unverified / open

* All default values and impact sizes (web unreachable); real defaults come from the `VXRT_TRACE_INI` run.
* Whether VR rendering consults each Display-section key (e.g. volumetric, SSR) or only the SE-shared binary names them.
* `fRenderTargetSizeMultiplier` vs our `VXRT_RENDER_SCALE`: whether they multiply.
* Low.ini/Medium.ini/High.ini location and whether `iQualityPreset` overwrites ini keys at start.
* Precedence among Skyrim.ini, SkyrimVR.INI, SkyrimPrefs.ini, SkyrimCustom.ini on our file layer.
