# Windows/D3D11 guarantees that VXRuntime's Metal path relies on or fails to provide

Subject: **static analysis** of `/Users/gseddon/git/Skyrim-VR-Vision-Pro` at `558be7d`, the committed depth-stencil zeroing, plus game2's uncommitted trace edits in `d3d11.m`, `d3d11_draw.m` and `tests/draw.c`. Line numbers are from that working tree.

Nothing was built or run. A fixture or game run is needed to confirm each GAP.

Pipeline note: for D3D11, `dxbc.c` writes MSL directly. `gpu_ir*` only does binding, copies and fills. Per-draw binding is `d3d11_draw.m` `bind_stage` (around line 1595).

On "guarantee": the D3D11 documentation says a resource made without `pInitialData` has *undefined* contents (CreateTexture2D/CreateBuffer docs). In practice WDDM hands out zeroed video memory, and D3D12 documents committed resources as zeroed unless `D3D12_HEAP_FLAG_CREATE_NOT_ZEROED` is set. Games, Skyrim VR included (558be7d), depend on this. It is treated here as a de-facto guarantee.

Coordinator data point: a flat grey patch over the cart in eye 0 is already present in the fade pass's input, and there are grey "unstreamed" blocks on the left rock. GAPs that could plausibly produce flat grey regions are marked **[GREY]**.

---

## Ranked GAPs (most likely to affect Skyrim first)

### 1. [GREY] New colour render-target, UAV, MSAA and DEFAULT textures are not zeroed
- **Where:** `d3d11.m:1782`. The zero-init added in 558be7d covers only `BIND_DEPTH_STENCIL`. `make_mtl_texture` (`d3d11.m:367, 384`) makes every other texture Private (or Shared for DYNAMIC/STAGING) with `newTextureWithDescriptor`, whose contents are undefined.
- **Windows:** new allocations read as 0.
- **Ours:** any colour or G-buffer target, UAV texture, MSAA target or never-uploaded DEFAULT texture starts with whatever memory Metal hands back, often another freed texture's.
- **Lossless compression:** this is Apple's default for Private render targets. A never-written texture's compression metadata is also undefined, which can decode as constant-colour tiles. Flat grey blocks fit this.
- **Failure:** a pass that reads a target region nothing has written this frame (a G-buffer channel only some materials write, a cleared-by-assumption accumulation buffer, one eye's half of a double-wide target) sees stale or garbage data instead of black.
- **Fix:** generalise `zero_depth_texture`:
  - `MTLLoadActionClear` to 0 for every renderable texture made without init data.
  - For non-renderable formats (BC, Private UAV-only), a blit from a zeroed shared buffer per subresource.
  - Run it on the device queue before first use, as now.
- **Reproducer** (`tests/draw.c`, after `test_fresh_stencil`): make a 256x256 R8G8B8A8 and an R16G16B16A16_FLOAT render target, clear them to 0.5 grey, read back, release. Make a new one of the same description without init data, `CopyResource` it to staging, `Map(READ)`, expect all zeros. Repeat for UAV-only R32_UINT, 4x MSAA (via `ResolveSubresource`), and a BC1 DEFAULT texture read by `ld` in a pixel shader.

### 2. [GREY] `ClearUnorderedAccessViewFloat`/`Uint` on textures does nothing
- **Where:** `d3d11_draw.m:2641` (`clear_uav`: "not implemented (textures)") and `d3d11_draw.m:2727-2730` (`clear_uav_uint`). Both return after logging once through `d3d_not_implemented`.
- **Windows:** the UAV's subresource range is set to the value.
- **Failure:** compute or pixel-UAV passes that clear and then accumulate (histograms, light lists, volumetric or AO buffers) accumulate onto stale contents. Combined with GAP 1, a never-cleared UAV texture is garbage forever.
- **Fix:** for renderable formats, a render pass per mip/slice with `loadAction = Clear`, the clear value converted to the view format. For others, a small compute kernel per texture type, or a blit from a pattern buffer.
- **Reproducer** (`tests/compute.c`): R32_FLOAT and R8G8B8A8_UNORM 2D UAV textures. Write 7 with a CS, `ClearUnorderedAccessViewFloat(0.25)`, read back and expect 0.25. The Uint variant on R32_UINT: expect 0xdeadbeef.

### 3. [GREY] D3D11 shaders are compiled with Metal fast math
- **Where:** `d3d11_draw.m:66, 178-179, 1059, 1788, 2258, 2374` all pass `options:nil`, and Metal defaults to `fastMathEnabled = YES`. By contrast `d3d12.m:4072-4073` and `gpu_ir_metal.m:461-462` choose `MTLMathModeSafe`.
- **Windows:** IEEE-ish SM5 rules:
  - `min`/`max` return the non-NaN operand.
  - `rcp(0)` is infinity.
  - `ne`/`lt` on NaN behave by IEEE.
  - `saturate(NaN)` is 0.
  - no reassociation unless the compiler marked the instruction.
- **Ours:** fast math assumes no NaN or infinity. NaN guards (`ne r,r,r`) can be folded away and `fmin`/`fmax`/`saturate` lose NaN rules (`dxbc.c:1000-1001`). Contraction also makes depth-equal passes round differently.
- **Failure:** a NaN or infinity from a normalisation or divide survives into lighting, bloom or TAA as black, white or constant-colour blocks that TAA spreads. A pre-pass and a main pass at `EQUAL`/`LESS_EQUAL` z-fight.
- **Fix:** an `MTLCompileOptions` with `mathMode = MTLMathModeSafe` (`fastMathEnabled = NO` before macOS 15) for every D3D11 library, matching d3d12.
- **Reproducer** (owned HLSL under `tests/shaders`, run through the existing compute harness): a CS that computes
  - `max(asfloat(0x7fc00000), 1.0)` (expect 1.0)
  - `saturate(NaN)` (expect 0)
  - `x != x ? 1 : 0` for NaN (expect 1)
  - `rcp(0) == +inf`

  with the NaN taken from a constant buffer so it cannot be folded at compile time.

### 4. [GREY] Unbound SRVs, and SRVs hidden as render targets, bind `nil`
- **Where:** `shader_texture(NULL)` returns nil (`d3d11_draw.m:1244-1245`), and `bind_stage` binds it for every declared slot (`d3d11_draw.m:1631`). `readable_srv` (`d3d11_draw.m:1590-1597`) deliberately returns NULL when the SRV is also a bound RTV/DSV. Its log says "it reads 0, as in Direct3D", but a nil Metal texture read is undefined, not 0.
- **Windows:** `sample`/`ld`/`gather`/`resinfo` on an empty slot return 0, and the runtime unbinds hazarding SRVs so they read 0.
- **Also affected:** typed `Buffer<>` loads check `get_width()` on nil, and slots t64..t127 are never bound.
- **Failure:** a shader reading a slot the game left empty, or reading its own target, gets undefined data, which may be the previous texture at that index on some GPUs. Likely a flat colour.
- **Fix:** keep 1x1 (or 1-element) zero textures per Metal texture type (1D, 1D array, 2D, 2D array, cube, cube array, 3D, 2D MS, buffer, depth) and bind the matching one for nil slots.
- **Reproducer** (`tests/draw.c`): a PS that returns `t3.Sample(s, uv) + t4.Load(int3(0,0,0)) + float4(0,0,0,1)` with t3/t4 unbound. Expect exactly (0,0,0,1). A second draw where t0 is the bound RTV expects (0,0,0,1).

### 5. [GREY] Unbound constant buffers, and fixed-index reads past a small bound CB
- **Where:** `bind_stage` binds `nil` for a NULL CB (around `d3d11_draw.m:1620`). Fixed-index `cbN[k]` reads are not bounds-checked.
- **What does work:** the zero-padded copy for "smaller than declared" runs only when the declared size is ≤ 4 KB and the buffer is shared storage (`d3d11_draw.m:1604-1615`). Dynamic indexing is guarded (`dxbc.c:292`) and covered by `tests/shaders/cbounds_cs.hlsl`.
- **Windows:** reads beyond the bound range, or of an unbound CB, return 0.
- **Failure:** null-buffer reads, or neighbouring draws' constants, as material colours or matrices.
- **Fix:** treat a NULL CB as size 0 and bind a zero buffer of the declared size. Extend the padded path to every case where the declared size exceeds the bound size: a zeroed scratch slice, not just `setBytes` ≤ 4 KB.
- **Reproducer** (`tests/draw.c`): a PS returning `cb2[0] + cb2[300]` with cb2 unbound, then bound with 16 bytes. Expect 0 for the unbound reads.

### 6. Constant depth bias divided by 2^24
- **Status (2026-11-11): WON'T FIX** (GPU +2.0% in replay, inside about 4% noise, so not shown negligible; p1300 eyes byte-identical). The discarded fix (was `33aa27e`, ledger row 6) used `(float)DepthBias`, times 256 for D16; no scale for D24 because D32F's step is 2^-24 for z in [0.5, 1). Replay of `p1300.cap`: no pixel changed.
- **Where:** `d3d11_draw.m:2010`: `setDepthBias:(int32_t)DepthBias / 16777216.0f`. The other paths pass the integer straight through: `d3d12.m:6577` (`p->bias = (float)desc->raster.depth_bias`) and `vk_command.m:1071`.
- **Windows:** for UNORM24 depth, bias = `DepthBias * 2^-24`. For float depth, `DepthBias * 2^(e-23)`.
- **Metal:** like Vulkan (MoltenVK passes `depthBiasConstantFactor` straight through), Metal applies the constant in units of the format's minimum resolvable difference. The division leaves an effective bias of about `DepthBias * 2^-47`, which is zero.
- **Failure:** shadow acne on cascades. Decals that rely on constant bias z-fight. Only slope-scaled bias remains.
- **Fix:** pass `(float)DepthBias`. D24 is emulated as D32F, so optionally scale by about 0.5 to match the 24-bit unit near z=1.
- **Reproducer** (`tests/draw.c`): two coplanar quads at z=0.5 on a D24 target. The second has `DepthBias=1000` and `LESS` with a different colour. Expect the second visible on Windows semantics; today it fails.

### 7. Depth-stencil clear of an array DSV clears only slice 0; layered passes lack `renderTargetArrayLength`
- **Where:**
  - In `clear_pass` (`d3d11.m:889-899`), `renderTargetArrayLength` is set only in the colour branch (`d3d11.m:888`). A DSV with `ArraySize > 1` (cube or cascaded shadow arrays) is cleared at `first_slice` only.
  - The draw render pass (`d3d11_draw.m:1441-1462`) never sets `renderTargetArrayLength`, although `dxbc.c:1499, 1565` emit `[[render_target_array_index]]` for `SV_RenderTargetArrayIndex`.
- **Windows:** `ClearDepthStencilView` clears every slice in the view, and layered rendering selects among the view's slices.
- **Failure:** stale depth in cascades/cube faces 1..n (missing or garbage shadows). GS/VS-layered draws all land in one slice.
- **Fix:** set `rp.renderTargetArrayLength = v->slices` in the depth branch. In `render_pass`, set it to the minimum `slices` of the bound RTV/DSV when any view spans more than one slice.
- **Reproducer:** a 4-slice R32_TYPELESS/D32 array DSV. Clear to 1.0, read every slice with a CS, expect 1.0. A VS writing `SV_RenderTargetArrayIndex = 2` into a 4-slice RTV expects colour only in slice 2.

### 8. [GREY, possible] `Map(WRITE)` on a tiled staging texture does not preserve contents
- **Where:** `ctx_map`, `d3d11.m:1700-1704`. Only `MAP_READ` (type & 1) or READ_WRITE (3) read the texture back into `t->cpu`. The buffer is `malloc` (uninitialised) or stale from an earlier Map. `ctx_unmap` (`d3d11.m:1709-1719`) then `replaceRegion`s the whole subresource.
- **Scope:** this affects staging textures that are not the single-mip 2D buffer-backed kind: mip chains, arrays, 3D, depth. Buffer-backed staging is OK.
- **Windows:** `D3D11_MAP_WRITE` keeps the existing contents, so a partial write keeps the rest.
- **Failure:** a texture streamed through a mip-chained staging texture, written in part (only the rows of a sub-box), then `CopySubresourceRegion`'d to the DEFAULT texture, uploads garbage blocks. Whether Skyrim streams this way is UNKNOWN; logging `Map` type, usage and mip count during the intro would settle it.
- **Fix:** for type 2 (WRITE), read back exactly as for READ_WRITE.
- **Reproducer:** a 2-mip staging texture with init data 0x11. `Map(WRITE)` mip 0, write only row 0, Unmap, `Map(READ)`, expect rows 1..n still 0x11.

### 9. Stencil SRV returns stencil in `.r`, D3D in `.g`
- **Where:** formats 47 and 22 (`X24_TYPELESS_G8_UINT`, `X32_TYPELESS_G8X24_UINT`) map to `MTLPixelFormatX32_Stencil8` (`d3d11.m:148, 160`) and are viewed without a swizzle (`d3d11_draw.m:1253, 1263`; there is no `MTLTextureSwizzle` anywhere in `d3d11*.m`).
- **Windows:** the stencil value is in the G channel.
- **Metal:** stencil views return it in R.
- **Failure:** stencil-reading shaders (FXC loads `.g`/`.y`) get 0, so masks such as sky, first-person or water fail.
- **Fix:** create the stencil SRV view with `swizzle:{R,R,ZERO,ONE}`, or patch the load in the translated shader when the bound view is a stencil format.
- **Reproducer:** draw with stencil ref 0x5A REPLACE, then a PS with `Texture2D<uint2> s; return s.Load(int3(x,y,0)).g;`. Expect 0x5A.

### 10. B8G8R8X8 alpha is not forced to 1
- **Where:** formats 88, 92 and 93 map to `BGRA8Unorm` (or `_sRGB`) (`d3d11.m:166-168`) with no alpha swizzle.
- **Windows:** sampling an X channel returns 1.0. Destination-alpha blend factors on an X8 render target behave as alpha = 1.
- **Failure:** wherever uploaded X bytes are 0, `.a` reads 0. Premultiplied or alpha-tested sprites vanish, and DEST_ALPHA blends go black.
- **Fix:** SRV views with alpha swizzle ONE. For RTVs, a write mask without alpha and DEST_ALPHA factors replaced with ONE.
- **Reproducer:** a BGRX texture with init bytes `(10,20,30,0)`, PS returns `.a`. Expect 1.0.

### 11. Pixel-shader `SV_Position.w` is 1/w
- **Where:** `dxbc.c:1539` binds the PS input straight to `float4 v%d [[position]]`. The MSL spec gives `[[position]]` as (x, y, z, 1/w); D3D gives clip-space w. DXVK inverts it for the same reason.
- **Failure:** shaders that read `pos.w` for linear depth (soft particles, fog, water edges) get the reciprocal.
- **Fix:** emit `v%d.w = 1.0 / v%d.w` after the input copy when the position register's .w is read.
- **Reproducer:** VS outputs w = 4. PS returns `pos.w / 8`. Expect 0.5, not 0.03125.

### 12. `MipLODBias` ignored
- **Where:** `make_sampler` (`d3d11_draw.m:357-375`) never reads `d[4]`, and Metal samplers have no bias field.
- **Windows:** the sampler bias is added to the computed LOD.
- **Failure:** blurrier or sharper textures than intended (TAA negative bias, VR supersampling). Possibly mis-read as streaming. Not grey.
- **Fix:** carry the bias in the per-draw sizes/aux buffer and emit `bias(...)` in `sample` when the bound sampler's bias ≠ 0. Alternatively, a pipeline key bit.
- **Reproducer:** a mip-coloured texture where each mip is a different colour. Sampler `MipLODBias=+1`, a 1:1 draw. Expect mip-1 colour.

### 13. `sample_c` reference is not clamped for D24/D16 emulated as D32F
- **Where:** `dxbc.c:477` emits `sample_compare(s, xy, ref)`. D24 and D16 typeless depth (44-46, 19-21) become Depth32Float(_Stencil8) (`d3d11.m:147, 157`).
- **Windows:** for UNORM depth formats the reference is clamped to [0,1] before comparing.
- **Failure:** a reference of 1.0001 against a cleared 1.0 with `LESS_EQUAL` comes out shadowed. Dark rims or bands appear at cascade or far edges.
- **Fix:** emit `saturate(ref)` when the bound SRV's D3D format is UNORM depth: a bound-format flag per slot.
- **Status (2026-11-11): WON'T FIX** (GPU +2.0% in replay, inside about 4% noise, so not shown negligible; p1300 eyes byte-identical). The discarded fix (was `33aa27e`, ledger row 13) used `saturate` for every compare, not by bound format (the translator has no per-slot format input). Replay of `p1300.cap`: no pixel changed.
- **Reproducer:** shadow-compare fixture with ref = 1.01, stored 1.0, `LESS_EQUAL`. Expect 1 (lit).

### 14. Partial `UpdateSubresource` on a buffer with pending GPU writes copies stale CPU contents
- **Where:** `ctx_update_subresource` with `rename_buffer(..., keep=1)` (`d3d11.m:1598-1612, 1632`) `memcpy`s `old.contents` straight away. Only `BIND_UNORDERED_ACCESS` buffers take the ordered blit path (`d3d11.m:1627`).
- **Exposed buffers:** a non-UAV buffer that is the destination of a recorded but unfinished `CopyResource`/`CopySubresourceRegion` (`d3d11.m:1395-1409, 1458-1465`) or of stream output.
- **Windows:** the update is applied in order after the earlier GPU work, so the rest of the buffer holds the GPU result.
- **Failure:** vertex or index data written by GPU copies reverts to old contents, which shows as flicker or misplaced geometry.
- **Fix:** if `o->gpu_seq > completed`, use the ordered blit path (as for UAVs) instead of renaming.
- **Reproducer:** buffer A=0x11, B=0x22. `CopyResource(B, A)`, then immediately `UpdateSubresource(B, box 0..4, 0x33)`, read B. Expect `33 11 11...`.

### 15. `ResolveSubresource` leaves the multisampled source undefined
- **Where:** `d3d11_draw.m:2866`: `storeAction = MTLStoreActionMultisampleResolve`, not `StoreAndMultisampleResolve`. `format` is ignored (`d3d11_draw.m:2844`).
- **Windows:** the source is unchanged.
- **Failure:** rendering more into the MSAA target after a mid-frame resolve, then resolving again. On TBDR the memory is probably kept in practice, but Metal does not promise it. Skyrim VR's MSAA use is UNKNOWN.
- **Fix:** use `MTLStoreActionStoreAndMultisampleResolve`.
- **Reproducer:** a 4x target. Draw red, resolve, draw a green quad over half, resolve. Expect half red, half green.

### 16. Lower-likelihood shader-semantics gaps
From the delegated shader audit; spot-checked here for fast math, `[[position]]` and min/max.

| Gap | Where | D3D behaviour | Ours | Fix |
|---|---|---|---|---|
| `ubfe`/`ibfe` edges | `dxbc.c:592` | width 0 gives 0 | returns the source; `extract_bits` past 32 bits is undefined | handle width 0 and offset + width ≥ 32 |
| `bfi` | `dxbc.c:586` | defined | `insert_bits` undefined when width + offset > 32 | same |
| `iadd`/`imul`/`imad`/`ineg`/`ishl` | `dxbc.c:1022-1037` | wraps | MSL signed overflow is undefined | do the maths in `uint` |
| `icb[i]` dynamic index | `dxbc.c:295` | out of range reads 0 | no bounds check | add a bounds check |
| Typed UAV atomics | `dxbc.c:727-757` | out of range ignored or 0 | no bounds check | add a bounds check |
| `SV_CullDistance`, `SV_ClipDistance` | `dxbc.c:1500, 1566` | applied | cull distance ignored; only the first clip register is used | apply them |
| Border colour | `d3d11_draw.m:370` | arbitrary colour | only three presets | — |
| MSAA `ld` sample index | `dxbc.c:516` | out of range reads 0 | wraps | — |

### 17. Copies, boxes and other low-likelihood API gaps
- **Copies between format families are dropped silently** (`d3d_format.c:29-33`, used at `d3d11.m:1391, 1434`). Since D3D10.1, D3D allows BC1↔R32G32_UINT and R16G16B16A16_UINT, and BC2/3/5↔R32G32B32A32_UINT. Fix: map to a raw Metal copy through a buffer. Reproducer: copy BC1 to R32G32_UINT and compare the bytes.
- **An empty or inverted `D3D11_BOX` underflows** in `region()` (`d3d11.m:1366`): `MIN(box[3],w) - MIN(box[0],w)` with right < left. D3D treats it as a no-op; ours gives a huge `NSUInteger` size and a huge staging allocation in `upload_texture`. Fix: return when right ≤ left (and the same for the other axes).
- **The OM sample mask is ignored**: no `sampleMask` anywhere in `d3d11*.m`. **Logic ops** (11.1) and **MIN/MAX reduction filters** (filter bits 0x100/0x180) are also ignored.
- **Clear UAV on structured buffers** uses `first*4` (`d3d11_draw.m:2643`). This is correct only for 4-byte elements; check against the view's stride.

### 18. CPU side (minor)
- **`TlsFree`** (`kernel32.c:701-705`) does not zero the slot in every thread. Windows zeroes it in all threads, so a reused index reads NULL there; ours reads a stale pointer.
- **`FlsFree`** (`sync.c:1887-1893`) clears and calls back only for the calling thread.
- **`HeapReAlloc(HEAP_ZERO_MEMORY)`** (`kernel32.c:1499-1505`) zeroes from `malloc_size(p)`, the rounded allocation, not the old requested size, so bytes between them stay dirty. `malloc_size` on a `vx_heap_owns` block may be 0 or wrong.
- **`GlobalReAlloc`** (`extras.c:810-812`) and **`LocalReAlloc`** (`services.c:580`) ignore `GMEM_ZEROINIT`/`LMEM_ZEROINIT` (0x40) when growing.
- **Fixes:** a per-thread generation sweep for TLS/FLS, keeping the requested size for ReAlloc, and honouring 0x40.

### 19. Windows API gaps seen in Skyrim's run logs (parked tasks)

These come from the run logs, not from static analysis. Each line appears in a Mac play log (`build/play-034735/startup.log`, 2026-11-10) and in the visionOS simulator start-up log (`/tmp/claude/sim/run2/vxrt.log`). The game runs past all of them on the Mac. Add a row when a log shows a new gap. Remove one only after a run shows it's gone.

| Gap | Log line | Effect | Status |
|---|---|---|---|
| XAudio2 2.7 reverb and effect chains | `CoCreateInstance: class {6A93130E-...} is not available` (`CLSID_AudioReverb`); `IXAudio2Voice::SetEffectChain (effects) is not implemented yet` | **Fixed on branch `reverb` (2026-11-11), not merged.** Skyrim creates three 2-channel 48 kHz submix voices, each with a one-effect chain: the first holds the built-in reverb; the other two hold a **guest XAPO of the game's own, "Monitor"** (CLSID E2CB584D-B516-49B1-..., 1 in / 1 out). `SetEffectChain`, `Enable/DisableEffect`, `GetEffectState` and `Set/GetEffectParameters` are implemented and the reverb runs on our own DSP (`src/xaudio2_reverb.h`, 8-line FDN). The Monitor XAPOs are kept and **pass the sound through unchanged; their `Process` is never called** (guest ABI call not built), so whatever the game reads back from them stays at zero (effect unknown). Off switch `VXRT_XAUDIO2_NO_EFFECTS=1`. Cost: 0.114 s CPU per 185 s of stereo audio at 48 kHz (0.06 % of a core) per reverb voice; an idle tail costs about nothing. See the compat-fix ledger. | Done, see ledger. |
| 6 unimplemented imports in `SkyrimVR.exe` | `6 imported functions are not implemented yet (stubs stop the program if called)` | None seen: none was called on the Mac. | Not investigated. The next step is to list the six from the loader's summary. |

**XAudio2 effects task (parked).**
1. Log what Skyrim requests:
   - each `SetEffectChain` call: the voice, the effect count, each XAPO and its CLSID;
   - the XAPO creation calls (`CoCreateInstance` `CLSID_AudioReverb` / `CLSID_AudioVolumeMeter` from xaudio2_7, and `XAudio2CreateReverb`/`CreateFX` if used);
   - the `SetEffectParameters` payloads (`XAUDIO2FX_REVERB_PARAMETERS`, I3DL2 conversion);
   - whether the game uses custom XAPOs of its own. Those run as guest code and need the generated guest ABI stubs, not native function pointers.
2. Implement what's used:
   - `SetEffectChain`/`EnableEffect`/`DisableEffect`/`Set`/`GetEffectParameters`, processed in the voice render path (`VXRuntime/src/xaudio2.m`);
   - the built-in reverb, following Microsoft's documented parameter semantics, with the DSP written by us from published algorithms (Schroeder/Freeverb or FDN);
   - the volume meter, if Skyrim uses it.

   Adapting third-party code such as FAudio's zlib FAudioFX needs a download and the user's approval first. Wine and ReactOS terms are as in `AGENTS.md`.
3. Add an off switch `VXRT_XAUDIO2_NO_EFFECTS=1` and log once which effects are active.
4. Tests:
   - an impulse gives a decaying tail with an RT60 near `DecayTime`;
   - wet/dry mix;
   - a disabled effect is a bit-exact passthrough;
   - no NaN or denormal blow-up;
   - an owned CPU-cost benchmark (for reference, the WMA decoder costs about 0.12 s of CPU per 185 s track);
   - a live run, with output clips with and without effects saved privately so the user can listen.

### 20. Renderer CPU improvements (estimated, not implemented)

Estimates only: nothing here is built or timed. Subject: replay of `p1300.cap` on a Mac M4 Pro (not the game, not the headset). Raw counts and scripts are private (`/tmp/claude/perf/cpuest/`).

**Method.**
- **Time:** Time Profiler samples of frames 2000-3000 (`/tmp/claude/perf/idea1/tp_samples.xml`, with stacks), 1000 frames, attributed by caller.
- **Counts:** an instrumented private copy of the replay counted Metal calls and Maps over 11 frames starting at 2401 (1534 draws/frame). Samples and counts come from different frames, so treat the per-call costs as +-20%.
- **Per-call costs** are sample time divided by call counts (no micro-benchmark).

**Live basis.** The profile's main thread has 6.27 s per 1000 frames. About 2.78 s of it is work the live game's D3D11 layer also does (`call_record` 2.39 s, `ctx_map` 0.31 s, flush and texture records 0.09 s), minus 0.23 s of `getenv` already fixed in `1b8aec5`. That leaves about **2.5 ms/frame of D3D11-layer CPU** on the M4 Pro. The rest is replay-only:
- capture reads: `fread` 2.78 s;
- `unmap_record` other than `ctx_map`, 0.53 s: two copies of capture data plus `free`, since the live game writes its constant buffers itself.

On an M2 multiply every figure by about 1.3-1.6 (inferred from public single-core benchmarks, not measured).

**What the layer already does.** `bind_buffer`/`bind_texture`/`bind_sampler` already skip a bind of the same object and offset, and the same holds for pipeline, depth-stencil, blend, raster and viewport state. Constant-buffer renames already come from 4 MB chunks in 256-byte slices (`take_slice`). So the Metal calls that remain are mostly real changes. Counts per frame:

| Item | Count/frame | Skipped as same | Issued |
|---|---|---|---|
| Constant-buffer binds | 9884 | 64% | 34% offset-only, 1% new buffer |
| Texture binds | 2534 | 69% | 31% |
| Sampler binds | 2381 | 95% | 5% |
| Vertex-buffer binds | 3069 | 51% | 49% |
| Pipeline-state checks | 1534 | 90% | 10% |
| Sizes `setBytes` (`uses_sizes`) | 2038 | none skipped | 96% byte-identical to the stage's previous one |
| `bind_stage` calls | 2578 | | 17% issue no bind at all |
| Constant-buffer Map(DISCARD) | 3707 | | all <= 4 KB, 52% <= 256 B, average 794 B, 2.94 MB/frame |

There are no VB/IB/SRV discards, no read Maps and no texture Maps in this window. 3.6 buffer `UpdateSubresource` calls per frame, all constant buffers.

**Where the time goes, ms/frame** (inclusive samples):
- `draw_indexed` 2.23: `prepare` 1.08, `gpu11_draw` 0.55, `trace_draw` 0.23 (fixed), `render_pass` 0.19, `pipeline` 0.08. Inside `bind_stage` (0.69), 0.31 is its own loop work.
- Metal's own set calls are cheap, about 10-15 ns each (all `set*` entry points together about 0.15). `drawIndexedPrimitives` is 0.47, mostly Metal's lazy state emit.
- `objc_retain`/`objc_release`: 0.63 leaf in total. By caller: binding path 0.45, Map/rename 0.12, end-of-frame flush 0.04, the rest 0.02.
- `_platform_memmove`: 0.59 leaf in total. Replay-only: `unmap_record` 0.23 and `fread` 0.22. Metal-internal state loads 0.05. The layer's own memmove is about 0.08 (`gpu11_draw` zero-initialising `gpu_ir_draw_info` 0.02, `pipeline` 0.015, `upload_texture` 0.014, `prepare` 0.013, `bind_stage` 0.011).

| # | Candidate | Saving, ms/frame (low-high) | Method and evidence | Risks | Prerequisite and order |
|---|---|---|---|---|---|
| 1 | No ObjC retain/release on the hot path (`__unsafe_unretained` in binding tables, bind taking raw pointers) | **0.28-0.40** standalone. Map-side ARC (0.12) is counted in 3. | The binding path has 0.45 ms of retain/release samples: `bind_buffer` 0.18 (12 ns per call over 12.9 M calls/1000 frames), `bind_stage` 0.12, `prepare` 0.10, `view_texture` 0.02, others 0.03. Low = 62% removable, high = 90%. Calls that need an owner (Metal's own `set*` retains) stay. | Raw pointers need the object to outlive the encoder use, which the `CFBridgingRetain` on `d3d_*->mtl` already gives. Touches many call sites. | None. Do first (cheap, mechanical). |
| 2 | Rebind only what changed (dirty bits per stage and slot) | **0.20-0.45** standalone; **0.10-0.25** after 1 | The Metal calls are already deduped, so the saving is the per-slot evaluation that finds "same": 11.9 k same-visits/frame (CB 6.3 k, texture 1.7 k, sampler 2.3 k, VB 1.6 k) at about 35 ns each before 1 and about 20 ns after it. Plus 2.0 k identical sizes `setBytes`/frame (0.03). A per-stage flag is not enough: only 17% of `bind_stage` calls are quiet, because a Map moves a constant buffer's offset on most draws. | `Set*` calls and `rename_buffer` must mark exactly the slots bound to the renamed buffer (a buffer-to-slot back-list). A missed mark is a stale bind, so build a debug mode that compares with the full path. Saves less in scenes with few repeated binds. | After 1 (they share `bind_stage`; take 2 at 1's reduced per-visit cost). |
| 3 | Constant buffers: a ring without ObjC, mutex or autorelease; `setBytes` for small ones; fewer memmoves | **0.12-0.25** for the ring clean-up (includes the 0.02 draw-struct memset). The `setBytes` variant nets **-0.05 to +0.10**. | `ctx_map` is 0.31 ms (84 ns per Map) for 3.7 k Maps/frame. A ring already exists (`take_slice`), so "one ring with offsets" is mostly done. What remains is ObjC overhead around it: `[MTLBuffer contents]` autoreleases (0.07), `take_slice` mutex (0.04), `CFRelease`/`CFBridgingRetain` (0.03), `drop_slice` (0.01). Use the chunk's cached `base`, a lock-free bump pointer per device, and a refcount only on chunk change. `setBytes` would save the offset bind (3.4 k/frame at about 30 ns) but costs a 0.8 KB copy plus a `setBytes` at every change, per stage, and the Map still needs a shadow: all Maps are <= 4 KB, so it is eligible, but it nets about zero. **Layer memmove is small (0.08 ms live):** the rest of the profile's 0.59 ms is replay-only or Metal-internal, so "fewer memmoves" has nothing to find beyond the 0.02. | Slice reuse depends on the `dev->submitted`/`completed` sequence numbers; a lock-free scheme must keep the "draws recorded so far may read it" rule. `setBytes` conflicts with the worker design (5) unless the shadow is versioned. | Independent of 1-2. Do second or third. Skip the `setBytes` variant. |
| 4 | Argument buffers / bindless | **-0.10 to +0.15** (not worth doing) | After 2 about 6 k Metal set calls remain per frame at 10-15 ns (0.07 ms), plus resource-list adds in `IOGPUResourceListAddResource`/`MTLResourceListAddResource` (0.13 ms), which `useResource` would replace, not remove. An argument buffer shifts work to us: writing GPU addresses and resource IDs per changed slot, and a `useResource` per resource per encoder. Some of `drawIndexedPrimitives`' state emit (0.34 ms) could shrink, but it is not separable from Metal's own cost. | The DXBC-to-MSL generator would have to emit argument structs (large change). Needs argument-buffer tier 2 for texture and sampler arrays: visionOS device vs simulator tier is unverified (query `argumentBuffersSupport`). Residency via `useResource`/heaps; lifetime of resources written into the buffer. | After 2; only if a headset measurement shows Metal-side bind cost far above this. |
| 5 | Metal encoding on a worker thread | **0.9-1.4** standalone; **0.4-0.8** after 1-3 | Movable (draw path only): `bind_stage` 0.69 + `bind_texture`/`bind_sampler`/VB 0.14 + `gpu11_draw` 0.55 + `render_pass` 0.19 + set-state calls 0.04, about 1.6 ms. Stays on the game thread: `prepare` validation, view and `pipeline` lookup (about 0.25 ms) and every `Set*` and Map. Recording and hand-off per draw (a snapshot of changed slots, a retain of each changed object, an SPSC push) is estimated at 100-200 ns/draw = 0.15-0.30 ms/frame. Standalone = 70-90% of 1.6 moves, minus that. After 1-3 the movable part is about 1.0 ms. | Map(READ/RW) and `wait_gpu` must drain the worker (none here; a game with staging readbacks would stall). Queries and `GetData` likewise. Present and eye-frame submission must be ordered after the worker's last draw. Shared resources (cross-process, IOSurface) need a fence before handover. Slice and buffer recycling use `dev->submitted`, which would then count encoded, not recorded, draws. Clears, copies and dispatches must use the same queue or draw order breaks. Costs one more core (the headset also runs the game's threads; contention not measured). No total CPU saving, only critical-path. | Last, after 1-3: 2's dirty snapshot is what makes the hand-off cheap. Largest and riskiest. |

**Overlap.**
- 1 and 2 both cut `bind_stage`: 2 is counted at the per-visit cost left after 1, so add the "after 1" figure.
- The rename-path ARC (0.12 ms) is counted only in 3.
- 5's movable part shrinks as 1-3 land; its "after" figure accounts for that.
- 4 is excluded from the totals.

**Achievable total (non-overlapping), 1+2+3:** about **0.50-0.90 ms/frame**, 20-36% of the 2.5 ms live basis, i.e. about 0.65-1.4 ms on an M2. Adding 5: **0.9-1.7 ms/frame** (36-68%).

**Recommended order:** 1, 3, 2, then decide on 5 from a headset measurement. The replay is not the limit at 1024^2 on the Mac, so these matter on the headset only if the M2's CPU turns out to be the bottleneck; that is not measured. The counts come from one 11-frame window, so a different scene would shift the binding numbers.

**Not checked.** Per-call costs on the M2; the live game's Set*/Map call mix (the replay reproduces the call stream but not the game's own cost); the effect of fewer binds on Metal's draw-time state emit, which would add to 1 and 2.

---

## OK: verified in code

- **Buffers:** every buffer is `newBufferWithLength` on shared storage (`d3d11.m:55, 1820`), which Apple documents as zero-filled. Recycled renamed buffers (`take_buffer`, `take_slice`) are handed out only for WRITE_DISCARD or full UpdateSubresource, where D3D says the contents are undefined anyway. A partial update copies the old contents (`keep`).
- **Buffer-backed staging textures** are zeroed by the same allocator (`d3d11.m:378-382`).
- **Depth-stencil textures without init data** are zeroed (558be7d, `d3d11.m:1749-1774`), with a reproducer (`tests/draw.c` `test_fresh_stencil`).
- **Render passes:** every attachment is Load/Store (`d3d11_draw.m:1451-1461`), so contents are preserved across passes and partial viewport or scissor draws. There is no memoryless storage.
- **Clears and discards:**
  - `DontCare` is used only for D3D Discard* calls (`d3d11.m:928-937`), where D3D also says undefined.
  - Pending clears are folded into the next pass's load action, or flushed before any other GPU use (`context_cmd`, `d3d11.m:559`). Clears ignore scissor, as in D3D.
  - The internal no-DSV depth attachment is DontCare, which is correct because D3D drops that depth.
- **Fixed-function state:**
  - Defaults with NULL states: depth LESS with write, stencil off (`d3d11_draw.m:1519-1525`); solid, back-face cull, clockwise front, depth clip on, scissor off (`d3d11_draw.m:2001-2002`); blending off, write all.
  - Depth-stencil mapping: compare functions, stencil ops, read/write masks, front/back faces (`d3d11_draw.m:301-330`).
  - `FrontCounterClockwise` and cull mode map correctly, and `DepthClipEnable` maps to Metal's clip/clamp mode (`d3d11_draw.m:2005-2012`).
  - Scissor default and clamping are correct.
  - Blend: blend factors including BLEND_FACTOR (`d3d11_draw.m:873-893`), independent blend (`d3d11_draw.m:1160`), the dual-source SRC1 mapping, alpha-to-coverage, and unbound-RT write masks are all correct.
  - Read-only DSV planes are honoured when the depth texture is also bound as an SRV (`d3d11_draw.m:1579-1588`).
- **Map and uploads:**
  - `Map`: WRITE_DISCARD on buffers renames, NO_OVERWRITE writes in place, READ waits (`d3d11.m:1667-1681`).
  - Dynamic textures flush and wait before Map.
  - UpdateSubresource on textures handles boxes and pitches, including BC blocks (`d3d11.m:1473-1499`), ordered on the context.
  - Initial-data uploads are committed before the context's later command buffer.
  - Same-family CopySubresourceRegion and box clamping (`d3d11.m:1419-1452`) are correct.
- **Shader out-of-bounds handling:** raw and structured SRV/UAV load, store and atomic; texture `ld` coordinates, mip and layer; typed UAV load and store; indexable temps; dynamic CB indexing. All are checked (`dxbc.c:281, 292, 357, 430, 629-686, 763`) and covered by `tests/shaders/bounds_cs.hlsl` and `cbounds_cs.hlsl`.
- **Shader arithmetic:**
  - `udiv`/`urem` by 0 gives 0xFFFFFFFF (`dxbc.c:1086`), and shifts are masked with `&31` (`dxbc.c:1038-1040`).
  - `countbits` and `firstbit*` of 0 give 0xFFFFFFFF (`dxbc.c:1044-1048`).
  - `movc` is a bit test; `round_*` uses `rint`/`floor`/`ceil`/`trunc`; `f16tof32` masks with `& 0xffff`; discard is correct.
  - These depend on safe math being enabled (GAP 3).
- **System values:**
  - SV_InstanceID excludes StartInstanceLocation (`dxbc.c:1578, 1609`).
  - SV_VertexID includes BaseVertex, as in D3D.
  - Interpolation modifiers map correctly (`dxbc.c:1236-1245, 1541-1545`).
  - The pixel centre and the 0..1 clip-space depth range match D3D.
- **Default sampler** matches the D3D default (`d3d11_draw.m:1527-1531`). Address modes and anisotropic detection (`(filter & 0x7f) == 0x55`) are correct.
- **CPU memory:**
  - `HeapAlloc`, `LocalAlloc` and `GlobalAlloc` honour the zeroing flags (`kernel32.c:1494, 1529`; `desktop.c:155`).
  - `VirtualFree(MEM_DECOMMIT)` gives zero pages on recommit (`kernel32.c:1262-1278`).
  - `MEM_RESET` gives fresh zero pages (`kernel32.c:930-935`).
  - The TLS expansion block is calloc'd (`kernel32.c:708`).
  - `FlsAlloc` slots start NULL (thread-local statics).

**Count: 30 OK items.**

## UNKNOWN (what would settle it)

1. **`ftoi`/`ftou` of NaN and out-of-range values** (`dxbc.c:1041-1042`, plain `int(x)`/`uint(x)`): a CS fixture with NaN, ±1e10 and -1 read from a constant buffer. D3D expects 0, clamp, clamp and 0.
2. **What a nil Metal texture actually returns** on M-series and visionOS (whether GAP 4 is visible today): an owned fixture reading an unbound slot after a slot that held a white texture.
3. **Whether `MapViewOfFile` of pagefile-backed sections reads zero** (`section.c`, not read in detail): a fixture that calls `CreateFileMapping(INVALID_HANDLE_VALUE)` and maps a view.
4. **Read-only DSV with a depth state that writes:** D3D drops the writes; ours writes depth while the same texture is sampled (`d3d11_draw.m:1986` does not consult `dsv->flags`). A fixture would show whether the depth changes.
5. **`SV_Depth` outside the viewport range** with a D32F stand-in for D24. D3D clamps to [MinDepth, MaxDepth]; does Metal for shader-written depth?
6. **Depth↔colour typeless copies** (an R32_TYPELESS DSV becomes Depth32Float, an SRV-only one R32Float) through Metal blits with different pixel formats (`d3d11.m:1267, 1288`): a CopyResource fixture under Metal validation.
7. **sRGB or format views of compressible (MSAA or depth) render targets** fall back silently to the base texture (`d3d11.m:363-364`, `d3d11_draw.m:1265-1269`). Grep the Skyrim log for "no %lu view of a %lu texture".
8. **Per-instance step rate > 1 with a non-zero StartInstanceLocation** (`d3d11_draw.m:1148-1150`): an instancing fixture.

**Count: 8 UNKNOWN items.**

## Suggested order for the grey patch
1. Do GAP 1 first: zero colour RT and UAV textures, generalising 558be7d.
2. Do GAP 2 alongside it.
3. Grep the existing intro run's log for `not implemented: ID3D11DeviceContext::ClearUnorderedAccessView` (GAP 2) and for `reads t%d, which is bound as a render target` (GAP 4). Their presence decides priority without a new run.
4. Then GAP 3 (safe math): a one-line change with broad effect.
