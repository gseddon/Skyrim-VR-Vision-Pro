# Hidden-area mesh for Skyrim VR on Vision Pro (2026-11-10)

Goal: Skyrim VR skips shading eye-image pixels the lenses cannot show. The headset is pixel-bound (GPU ms per pair scales about 1:1 with pixels, `research/` render-scale sweep), so every hidden pixel is saved work.

## What was missing

- xrizer `IVRSystem::GetHiddenAreaMesh` returns an empty mesh unless the OpenXR provider has `XR_KHR_visibility_mask` enabled. The Klepton provider advertised no such extension (only `openxr.h` had it).
- Skyrim VR reads `bUseHiddenAreaMesh` from the `[VR]` section (exe string `bUseHiddenAreaMesh:VR`); no default is stored in any shipped ini. Observed on the Mac dev host: the game calls `GetHiddenAreaMesh` once per eye (about 4 s after the process starts), with the key absent from every ini, so the mesh is used by default.
- visionOS gives apps no lens-visibility mask, so the shape has to come from calibration.

## What was built

- `third_party/klepton_openxr`: `XR_KHR_visibility_mask` (advertised once a host registers `kl_native_configure_visibility`, enabled by xrizer at instance creation because it copies the supported set). `xrGetVisibilityMaskKHR` returns HIDDEN_TRIANGLE_MESH, VISIBLE_TRIANGLE_MESH and LINE_LOOP per eye in tangent space (x = tan horizontal, y = tan vertical, y up, counter-clockwise), from a parametric rounded rectangle (`src/vismask.h`, `include/visibility_host.h`). Disabled, no geometry (immersive space ended) or no host parameters: a successful empty mesh, never an error (xrizer unwraps the call). Test: `tests/vismask.c` (in `build-test.sh`): extension plumbing, size-insufficient two-call, winding, hidden + visible area equals the eye rectangle exactly.
- Levers (`VXRuntime/src/vismask_shape.h`; default off; read at launch):
  - `VXRT_VISMASK=off|on` (or `mask=` in `Documents/vxrt_vismask.txt`, environment wins)
  - `VXRT_VISMASK_SHAPE=l,r,u,d,radius`: fraction of the eye image width/height hidden at the left, right, top and bottom of the LEFT eye (0..0.45), corner radius 0..1 of the smaller half-extent; the right eye mirrors left/right (so `l` is temporal, `r` nasal). Default when on and unset: `0.03,0.03,0.03,0.03,0.5` (placeholder until calibrated).
  - `VXRT_VISMASK_PROBE=1|2` (or `probe=`): the compositor draws the calibration pattern (1: pattern only, 2: over the game).
- Guest bridge (`VXRuntime/src/xrizer_guest_bridge.c`, `hidden_area_mesh`): a nonempty mesh used to abort ("unsupported nonempty hidden mesh"); it now copies the mesh to a stable buffer the guest reads. An empty mesh from xrizer is a dangling non-null pointer (0x4) with 0 triangles; it is now passed on as NULL/0 (found by the Mac run with the mask off).
- `tools/vxrt_native_startup.py`: the three levers are allowed `--diag-env` names.

## Calibration probe

`VXRT_VISMASK_PROBE=1` replaces each eye with: nested rectangles at 2 % steps from the drawable's edge (cyan and yellow alternating, white every 10 %), the inset in percent printed (4, 8, ... 28) at the middle of each edge for even rings and along each corner diagonal (4 to 20), and the current mask outline in magenta. The user reports, per eye, the outermost ring or label visible at top, bottom, left, right and at each corner. Those readings (percent inset per edge, with the corner reading deciding the radius) become the default shape. Offline render: `/tmp/claude/perf/vismask/probe1_L.png` (image not committed).

## Calibration (headset, 2026-11-10) and the default

Probe readings (left eye, outermost ring seen): top 10 %, outer/temporal 28 %, bottom 24 %, nasal about 8 % with a strongly curved border; the right eye mirrored. Cart rides with the mask on cut those back: the first shape (temporal 0.24, bottom 0.20, hid 49.9 %) showed the mask at the left and bottom; 0.16/0.16 (hid 41.2 %) still a little; final default `0.13,0.05,0.07,0.14,0.4` (l,r,u,d,radius of the left eye) hides about 38.5 % of each eye image (rounded rectangle area). The mask is ON by default; `VXRT_VISMASK=off` disables it.

## Evidence so far

- Mac dev host, title scene, 1024x1024 per eye, headless: mask off 59.7 pairs/s, 13.5 ms GPU per pair; mask on (0.15,0.05,0.25,0,0.5, about 43 % hidden) 80.6 pairs/s, 9.2 ms (-32 %); eye dump non-black 100 % -> 56.9 %.
- Headset: the probe drew on the device; the game asked for the mesh on both eyes; wearer's readings above. No cart measurement of the mask-only effect was obtained (the app went to the background before the cart in arms B and C).
