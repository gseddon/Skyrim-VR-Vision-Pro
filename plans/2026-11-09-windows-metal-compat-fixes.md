# Windows-vs-Metal compatibility fixes: ledger

Started 2026-11-09. Every renderer/runtime change made because Windows guarantees something Metal (or macOS) does not
is listed here, with what it costs and how to turn it off. If one turns out to cost too much frame time or load time,
this is where to look first to decide whether it can be dropped without hurting the game.

Source of the list: a read-only audit of the code at `558be7d` (18 gap groups, 30 OK items, 8 unknowns). The report
was written to `/tmp/claude/audit/windows-metal-guarantees.md`; its gap numbers are used below. Copy it into
`research/` if it needs to outlive the scratch directory.

How to read the columns:

- **Game evidence**: what an actual Skyrim VR run (or the D3D11 capture replay of one) showed. "None yet" means the
  fix is justified by the D3D11 specification and an owned reproducer only.
- **Cost**: measured, or "not measured". Per-frame costs matter most; creation-time costs show up as load time.
- **Off switch**: an environment variable that restores the old behaviour, so a fix can be A/B tested or dropped
  without a rebuild. "None" means a rebuild (revert) is needed today.

| # | Fix | D3D guarantee | Commit | Status | Off switch | Cost | Game evidence |
|---|-----|---------------|--------|--------|------------|------|---------------|
| — | Zero new depth-stencil textures | New resources read 0 | `558be7d` | merged | none | creation-time clear pass per new DSV texture; not measured | **Required**: without it the fade pass's stencil test fails and both eyes are black; with it the Helgen cart scene shows (89–96% non-black eye frames) |
| 5, 4 | Unbound SRVs and constant buffers read 0; undersized CBs zero-padded | Unbound/out-of-range reads return 0 | `db02f52` (merge `20c51f9`) | merged | none | 1×1 stand-in textures + one 64 KB zero buffer per device; undersized CBs copied each draw (setBytes ≤4 KB, temp buffer above); not measured | None yet. Owned test: undersized CB read leftover data before (8 vs 7). Unbound SRVs already read 0 on this Mac's GPU |
| 1 | Zero every texture created without initial data (colour, MSAA, UAV, compressed, 3D) | New resources read 0 | `0f11750` (branch `worktree-agent-ae48fb3840e9a4ef6`) | awaiting replay check | none | creation-time clear/blit per new texture; not measured | None yet. Owned test: MSAA fails before (8388608 nonzero), plain colour/UAV already zero on this Mac |
| 2 | `ClearUnorderedAccessViewFloat/Uint` on textures | Clears the view's mips/slices | `6040c1d` (branch `worktree-agent-ac034f1dbaf0b07a2`) | awaiting check-arm64 + replay check | none | per call, only when the game clears; not measured | None yet. Owned test fails 6 checks before |
| 3 | Safe math for D3D11 shaders (no fast math) | IEEE NaN/Inf behaviour | `82b282f` (branch `worktree-agent-a1f880ed1969adbf5`) | awaiting replay check | `VXRT_D3D11_FAST_MATH=1` | shader compile time within noise (≈5–7 ms either way); **GPU time per frame not measured** — the likeliest of these to cost frame time | None yet. Owned test: NaN self-compare folded to false under fast math |

## Not yet done (from the audit)

Gaps 6–18: depth-bias scale, depth-array clears and layered passes, `Map(WRITE)` on mipped/array staging textures,
stencil SRV channel, B8G8R8X8 alpha, pixel-shader `SV_Position.w`, sampler `MipLODBias`, `sample_c` reference clamp,
partial `UpdateSubresource` race, MSAA resolve store action, shader edge cases, copy/box/sample-mask API gaps, and
CPU-side zeroing (`TlsFree`/`FlsFree`/`HeapReAlloc`/`GlobalReAlloc`/`LocalReAlloc`). Add a row when one is fixed.

## Before dropping a fix

1. Measure: GPU frame time with the fix on and off (alternating runs, no other GPU load), or load time for
   creation-time fixes.
2. Check the game: replay the Skyrim capture (and the live game for anything the replay cannot show) with the fix off,
   and compare eye images.
3. Prefer narrowing (e.g. only zero textures the game reads before writing) over removing.
