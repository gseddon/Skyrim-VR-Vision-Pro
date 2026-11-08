# Skyrim strict-AOT no-image stop investigation

Date: 8 November 2026 (Europe/London)
Subject: actual prepared-image startup `runs/skyrim-feasibility/probe-skyrim-003`.
Status: loader-owned missing-import stub confirmed by owned red/green tests and a fresh game diagnostic. Narrow CRT telemetry compatibility implementation is under verification.

## Recorded observation

The sealed result reports exit 3 (`o1`), no timeout (`o2`), unchanged read-only inputs (`o3`), 2,537,167 AOT entries with one fallback request (`o4`), and missing target `0x10740c100` (`o5`). The log's last native return is EXE CRT `_initterm`, called from `0x14138ae75`; no menu, scene or VR checkpoint is established.

The runtime recorded by that result is `VXRuntime/build/vxrt-arm64`, SHA-256 `d47e49881d7824e8572eeb7e660ed2a5ee11107d5f709fc65b9f0a912cac5e80`. Preserve it and all existing modules/evidence. A diagnostic candidate must have a new basename; do not rebuild this path indirectly through the default ARM64 target.

## What “no image” establishes

`src/loader.c:vx_image_name_at` searches only loaded PE entries in `g_images`. It excludes synthetic builtin PE handles and missing-import allocations. Therefore “no image” is not evidence that the game generated code or that another game-code discovery pass is needed.

`translator/aot.c:xa_run` already recognizes synthetic builtin export jumps through `vx_builtin_stub` before attempting native thunk dispatch or declaring a fallback. A correctly formed builtin export jump should be followed without recompiled code. The sealed summary reports zero such jumps followed.

`src/loader.c:make_stub` separately allocates 16 KiB pages of 32-byte x86 missing-import stubs. Each places the `dll!function` label in RCX and jumps to `vx_unimplemented`. There is no corresponding AOT dispatch recognition. A missing import can therefore terminate at its anonymous stub address before the runtime prints its intended named API failure.

## Static discriminator for this run

Using the prepared EXE's original import order and the saved `runs/skyrim-feasibility/runtime-exports.txt`, canonicalizing `api-ms-win-crt-*` to `ucrtbase.dll` as the actual loader does, identifies 25 unresolved EXE imports. This equals the log's reported count. The log records one earlier unresolved Bink import. No other unresolved-import summary precedes them.

The first missing-import allocations, indexed from zero including Bink, are:

| Slot | Byte offset | Import |
| --- | --- | --- |
| 0 | `0x000` | earlier Bink unresolved import |
| 1 | `0x020` | `kernel32.dll!CompareFileTime` |
| 2 | `0x040` | `kernel32.dll!WritePrivateProfileStringA` |
| 3–5 | `0x060`–`0x0a0` | `xinput1_3.dll!#4`, `#3`, `#2` |
| 6 | `0x0c0` | `ws2_32.dll!#101` |
| 7 | `0x0e0` | `vcruntime140.dll!__telemetry_main_return_trigger` |
| 8 | `0x100` | `vcruntime140.dll!__telemetry_main_invoke_trigger` |

Read-only LLVM disassembly of the exact prepared PE independently shows:

- `_initterm` returns to `0x14138ae75`.
- The normal CRT continuation calls `0x14138bb14` from `0x14138aee4`.
- `0x14138bb14` is an import jump through IAT `0x14157f8e0`.
- Parsing that IAT entry names `vcruntime140.dll!__telemetry_main_invoke_trigger`, exactly the predicted stub at page offset `0x100`.

This makes a loader-owned missing-import stub the strongest explanation for target `0x10740c100`, and this telemetry symbol the strongest explanation for its API identity. The old run did not capture the missing-stub page base, target bytes or immediate caller. Those exact runtime facts remain inferred until a diagnostic candidate records them; the earlier `GetModuleHandleW = 0x107400000` is not sufficient to identify this allocation as a builtin image.

## Minimal next experiment

1. Build a repository-owned PE importing a uniquely named absent function from builtin `kernel32.dll`, with its own entry and no CRT startup. Generate its AOT module in a coordinated scratch build only.
2. Run the owned PE with the preserved runner and strict AOT. Expected current defect: anonymous strict missing-code failure instead of the named missing import. Preserve status, counters, command and artifacts.
3. Add bounded loader metadata for exact missing-import entry tokens and explicit strict-AOT dispatch to the existing API-failure diagnostic. Do not decode arbitrary anonymous memory or return success for missing functions. Reject interior/random addresses.
4. Build a uniquely named diagnostic runtime. Run the same owned module: require exact `kernel32.dll!<fixture symbol>` failure, exit 3, positive AOT execution, and no translator fallback. Keep deliberate missing-code fixture failure distinct.
5. Only after that reproducer passes, coordinate one fresh bounded Skyrim probe with unchanged prepared inputs/modules. Require direct evidence of the missing symbol/caller before implementing any API behavior.

The next compatibility implementation, if the predicted symbol is confirmed, is a narrowly scoped CRT telemetry hook. Its contract and actual callable ABI still need source/documentation and owned-test review; the diagnostic fix alone does not implement it or establish further game progress.

## Boundaries

The initial classification was read-only. Subsequent coordinated owned and game diagnostics are recorded below. No new game-code roots, unpacking changes, interpreter/JIT fallback or ownership responses are justified by this stop. The broad runtime baseline and XR lane remain separate work.

## Owned diagnostic reproducer

`VXRuntime/tests/aot_missing_import.c` is a CRT-free owned PE importing `kernel32.dll!VXRT_MissingImportFixture`, which intentionally does not exist. Its `@` argument calls one byte past the import token to distinguish registered entries from arbitrary anonymous addresses. The matching `.def` builds a private import library. `tests/aot_missing_import_check.py` requires the exact expected failure, positive AOT counters and distinct handling for the interior address; reaching its success sentinel is a failure.

- `missing-import-before`: preserved runner; exit 3 (`o1`), 2 AOT entries and 1 fallback (`o4`), anonymous missing target (`o5`). No named missing API appears. This reproduces the defect without Skyrim.
- `missing-import-after`: candidate `build/vxrt-arm64-diag-001`, SHA-256 `d4d7d918297c4c64d288a01e206006d64e72f694ea7d667d520e6f9169813c8d`; exit 3 (`o1`), 2 AOT entries/zero fallback (`o4`), no missing-code address (`o5`), and exact named API failure (`o6`). Caller is `aot_missing_import.exe+0x1039`.
- Automated entry/interior check passes. Its raw logs/process statuses are under `runs/skyrim-feasibility/missing-import-regression/check-after/`. The interior address still produces a strict missing-code failure and one fallback request, without being accepted as the missing API entry.

The runtime change records exact loader-created missing-import entries, published after initialization. The AOT dispatcher uses that metadata to print caller identity, preserve the AOT summary, and terminate with the existing explicit missing-function diagnostic. It does not decode arbitrary anonymous memory or pretend the API succeeded. Existing Rosetta/JIT stub behavior is unchanged.

## Actual game classification

`probe-skyrim-004` uses the same prepared PE, guest DLLs and preexisting `aot-code-pointers-v2` modules, with diagnostic runner `diag-001`:

- `o1`: exit 3; `o2`: no timeout; `o3`: read-only inputs unchanged.
- `o4`: 2,537,159 AOT entries, zero fallback requests. This is an API failure with available code, not a game execution pass.
- `o5`: no missing-code address.
- `o6` and its sealed log: `called an unimplemented function: VCRUNTIME140.dll!__telemetry_main_invoke_trigger`.
- Immediate caller: `0x14138aee9`, `SkyrimVR.exe+0x138aee9`; the stub is `0x102c84100`. This directly confirms the static callsite/import-slot prediction.

The earlier run's absolute addresses differ through ASLR. No attempt was made to reuse an old address as a discovery root.

## Narrow next compatibility behavior

Read-only inspection of the genuine local Microsoft `vcruntime140.dll` records SHA-256 `7f6d96ae6d9324ce0675d13a89d7bdc26e14a7301e79494ad42c5c30d1eb0596`. Both `__telemetry_main_invoke_trigger` and `__telemetry_main_return_trigger` export the same RVA `0x5a70`, whose complete instruction is `c2 00 00` (`ret 0`). This is observed original-DLL behavior; no Wine or ReactOS implementation was consulted or copied.

The export/RVA/byte inspection is saved in `runs/skyrim-feasibility/missing-import-regression/microsoft-telemetry-exports.json`. LLVM disassembly independently identifies the empty return. This supports empty compatibility hooks preserving last error and ignoring the instance argument; it is not an assertion about all versions of Microsoft's telemetry internals.

`tests/aot_telemetry.c` dynamically resolves both exports, calls each with null/image-like/owned-memory instance arguments, checks last error and owned memory, and requires its output plus a successful exit. `telemetry-before` with `diag-001` fails as expected: both exports are absent, exit 1 (`o1`), 4 AOT entries/zero fallback (`o4`).

Candidate `build/vxrt-arm64-diag-002`, SHA-256 `cd20e10356e442f69aaa42b94bc0e8843d72640a24c03e8456c5b0525e4c0adf`, adds these two empty compatibility exports. `telemetry-after` passes: exit 0 (`o1`), no timeout (`o2`), unchanged read-only inputs (`o3`), 21 AOT entries/zero fallback (`o4`), and `aot_telemetry: ok` in the sealed log. The named missing-import/interior-address regression also passes on `diag-002` (`missing-import-regression/check-diag-002/`). These are owned-fixture passes, not a new Skyrim checkpoint.

Required checks ran serially with both candidate target overrides, preserving the original binaries. Logs/statuses are under `missing-import-regression/required-checks-diag-002/`:

- `aot-suite`: exit 0. Callback discovery, missing-import entry/interior, unsplit suite and 11-part suite pass, with exact semantic verdicts and positive AOT entries/zero fallback.
- `check`: exit 2 at `kernelx.exe`, `ws[1].attributes == 0` (test line 135).
- `check-arm64`: exit 2 at `smc.exe+0x185d`, writing to a freed-page test address plus 100 bytes. This is earlier than the previous thread-test failure and is not implicitly treated as the same baseline failure.

One bounded original-versus-candidate comparison used four fresh roots, without rebuilding the preserved runners. Original ARM64 and candidate ARM64 both pass `smc.exe`; original Rosetta and candidate Rosetta both pass `kernelx.exe`. Raw logs, process statuses and runtime/fixture hashes are under `missing-import-regression/baseline-isolation/`. These isolated controls do not reproduce the broad failures, so their cause remains unresolved. The comparison loop stops here to avoid diverting into a separate baseline workstream. Broad acceptance remains red; the passing narrow regressions do not waive it.

Scoped source patches and source/runtime identities are saved as `diag-001-source.patch`, `diag-002-source.patch` and `source-runtime-identities.json` in the regression evidence directory. The ledger validates with 14 records after the owned and game diagnostics; the preserved original runtime remains at its original SHA-256.

## Next actual checkpoint: XInput ordinal

`probe-skyrim-005` uses `diag-002` and the unchanged prepared input/modules. It passes the telemetry call and reaches a different explicit API failure:

- `o1`: exit 3; `o2`: no timeout; `o3`: inputs unchanged.
- `o4`: 3,031,949 AOT entries/zero fallback requests; `o5`: no missing-code address.
- `o6` and the sealed log: `XINPUT1_3.dll!#4`, caller `SkyrimVR.exe+0xc5e2d2`.

Read-only disassembly shows that call's arguments are controller index 0, flags 1 and a capabilities output pointer. The original bundled `APR2007_xinput_x64.cab` was read with the existing `bsdtar` tool; only `xinput1_3.dll` was extracted into repository-local private evidence, with no installer or download. Its export table maps ordinal 4 to `XInputGetCapabilities`, ordinal 5 to `XInputEnable`, ordinal 2 to `XInputGetState` and ordinal 3 to `XInputSetState`. Do not infer ordinal names from memory or from another XInput version.

The original DLL SHA-256 is `756cad002e1553cfa1a91ebe8c1b9380ffabe0b4b1916c4a4db802396ddfbef8`. Cabinet hash, extraction command/status and the parsed export table are recorded under `missing-import-regression/xinput-original/`. The [Microsoft function contract](https://learn.microsoft.com/en-us/windows/win32/api/xinput/nf-xinput-xinputgetcapabilities) matches the observed three arguments, returns an error code directly and does not set last error.

The runtime already implements the named function in `src/input.m`; its shared XInput export table omits ordinary ordinal aliases. The minimal next change is ordinal 4 for `xinput1_3.dll` only, backed by an owned name/ordinal lookup and Windows guest-call fixture. Other XInput versions have not been audited and must not inherit this mapping implicitly. Controller hardware behavior is a separate gate.

`tests/aot_xinput_ordinal.c` dynamically resolves the exact name and ordinal, requires pointer identity, calls the normal user-0/gamepad query, accepts only actual success or disconnected-controller status, and checks guard words and last error. This does not synthesize hardware. `xinput-ordinal-before` on `diag-002` exits 1 because the ordinal lookup is absent. Candidate `diag-003` adds only ordinal 4 in a separate `xinput1_3.dll` alias table, reusing the existing function and generated ABI thunk. No input behavior or other version mapping changes.

`xinput-ordinal-after` passes on `diag-003`: exit 0 (`o1`), inputs unchanged (`o3`), 9 AOT entries/zero fallback (`o4`), exact `aot_xinput_ordinal: ok` verdict. The observed device status is `ERROR_DEVICE_NOT_CONNECTED`, not a fabricated connected device. The telemetry fixture and missing-import/interior regression also pass on this candidate. Runtime SHA-256: `f044ab6283c0c8c05baf9d161b88481aa87d5a6e3cdbfcf74fef81134dc894ca`.

`probe-skyrim-006` uses that candidate and unchanged private modules. It advances past ordinal 4, then stops explicitly at `XINPUT1_3.dll!#3`, caller `SkyrimVR.exe+0xc4ba46` (`o6`'s sealed log). Exit 3 (`o1`), no timeout (`o2`), unchanged inputs (`o3`), 3,301,003 AOT entries/zero fallback (`o4`), no missing-code address (`o5`). The original export table above proves ordinal 3 is `XInputSetState`, which is already implemented by name. Adding that alias is the next narrow candidate; ordinal 2 remains unexercised and unchanged. No scene or VR result is established.

Ordinal 3 was then added to the same version-specific table, with separate immutable fixture `tests/aot_xinput_ordinal3.c`. The fixture dynamically compares name/ordinal identity, submits zero vibration only, checks its surrounding guard words and last error, and accepts actual success/disconnected status. `xinput-ordinal3-before` fails on `diag-003`; `xinput-ordinal3-after` passes on `diag-004` with exit 0 (`o1`), 9 AOT entries/zero fallback (`o4`) and its exact verdict. The observed device status remains disconnected. Candidate SHA-256: `0a0ac53fdd3e56badbf3964e976eb1429cb8bc8bece90ba6133b51188591daa8`. Missing-import/interior regression passes; broader checks for this new stable checkpoint remain pending.

## Native dispatch failure after input initialization

`probe-skyrim-007` uses `diag-004` and the unchanged game modules. It reaches D3D11 device/swapchain and shader-creation calls, then fails differently:

- `o1`: exit 138; `o2`: no timeout; `o3`: read-only inputs unchanged.
- `o4`: no AOT summary. Executed entry/fallback totals are **unknown**, not zero. The current extractor's boolean `o7` is false from absence of a summary, not proof that no AOT code executed.
- `o5`: no strict missing-code diagnostic was captured.
- The sealed log at line 14795 reports native signal 10 at `vx_x86_call+0`. The old `o6` extractor did not classify that signal line; do not rewrite the sealed result to add it.

The native stack repeats `vx_x86_call`, `xa_run`, `vx_cb_tramp` and `vx_x86_invoke`. Static symbol/disassembly checks on the exact candidate identify `xa_run+876` as immediately after the native thunk's `blr x8`, corresponding to `thunk(c)` in `translator/aot.c`, rather than an AOT module instruction or shader-processing body. A different thread continues logging shader creation while the crash stack is printed, so those interleaved calls do not establish the renderer as the faulting subsystem.

Recursive native/callback dispatch exhausting the host stack is the leading suspicion. The failing dispatch RIP, thunk identity, callback target and depth were not recorded; the cause remains unresolved. The next bounded step is diagnostic capture of those identities before exhaustion, with an owned nested-callback control, before changing runtime dispatch or graphics behavior. No renderer edit or ordinal-2 alias is justified by this result.

Candidate `diag-005` adds opt-in `VXRT_CALLBACK_DEPTH_LIMIT` in `src/arm64.c`, accepted range 2–256; no value leaves normal callback execution unchanged. It records current nesting from the actual level chain, and allocates trace history only when enabled. Before exceeding the limit it logs each bounded callback target, interrupted dispatch/native thunk and guest caller/SP, plus thread ID, actual native pthread stack bounds/current SP and the sizes of the saved x86 context and level. It emits the real AOT summary and exits 3 explicitly as a diagnostic, not a compatibility fix. It does not modify the renderer or raise a thread's stack limit.

Owned `aot_callback_depth` uses synchronous `EnumSystemLocalesA` guest callbacks without UI, graphics or Steam. `tests/aot_callback_depth_check.py` demonstrates that the old runner has no limit, then that the new candidate preserves shallow callbacks, stops deeper callbacks at limit 2 with three identity records and positive AOT counters/zero fallback, permits the same deep callbacks at limit 8, and preserves unlimited default behavior. Evidence is under `missing-import-regression/callback-depth-before/` and `callback-depth-after/`. The missing-import/interior test also passes on this candidate. SHA-256: `4ea1971ccf5d7ea6e44bc61350ee85521953fe10aace90f01f0290e72735c136`.

The forthcoming game diagnostic must use a fresh result and explicitly record its depth limit. A diagnostic stop cannot be counted as successful normal game execution. Its purpose is to distinguish repeated dispatch of the same target from legitimate nesting or an unusually small requested host stack.

`probe-skyrim-008` records `--callback-depth-limit 4` and the diagnostic scope, but does not reach the limit. Its actual first fatal outcome is a guest access violation, not the earlier native stack fault:

- `o1`: exit 5; `o2`: no timeout; `o3`: unchanged inputs.
- `o4`: no summary, so AOT execution/fallback totals remain unknown; `o5`: no missing-code diagnostic.
- `o6`: access violation reading null at `SkyrimVR.exe+0xc53e1b`, with callers `+0x648bc2`, `+0x57d33c`, `+0xc484ed`.
- `o9`/`o10`: no native signal/backtrace captured; no depth-limit stop appears.

Read-only disassembly identifies the failing method at `0x140c53df0`: it loads `this+0x208` into RCX and then dereferences that member's vtable at the failing instruction. RCX is null. The preserved RAX vtable address `0x1417e6aa0` has an intact MSVC complete-object locator at `0x1419f10e8`; its type descriptor names `.?AVBSOpenVR@@`. This directly associates the object with OpenVR-dependent game code. It does not establish which interface member is missing or why initialization failed, and does not prove a CPU instruction semantic defect. No explicit OpenVR initialization error was captured in this log.

Do not patch the game's null access or manufacture an interface. Determine the actual initialization result before joining the game to the real native XR path. The old native stack failure remains unresolved separately; changing timing/diagnostic code may expose a different earlier failure. No increasing-limit trace loop or unbounded game retry has been started.

### Exact initialization provenance

Further private-PE disassembly identifies `BSOpenVR::init` at `0x140c53730`. It calls imported `VR_InitInternal2(error*, 1, NULL)` at `0x140c53754`. If the returned error is zero, it checks `VR_IsInterfaceVersionValid("IVRSystem_019")`, then calls `0x140c57a60`. That helper obtains and caches the real result of `VR_GetGenericInterface("IVRSystem_019", error*)`. Initialization stores the resulting pointer in `this+0x208` at `0x140c537e8`.

The crashing method remaps its game controller role to OpenVR left/right roles and tail-calls vtable slot 18. The pinned `openvr-1.3.22.h` System019 declaration maps that slot to `GetTrackedDeviceIndexForControllerRole`. Actual string references also establish `IVRCompositor_022` and `IVRRenderModels_005` in this executable. The missing member is therefore the System019 interface pointer; the actual failing initialization error/result still needs dynamic capture.

### Transparent initialization diagnostics

Candidate `diag-006` adds explicit `VXRT_TRACE_OPENVR_INIT=1`, exposed as the harness's `--trace-openvr-init`. It wraps the real guest exports at both normal IAT binding and dynamic `GetProcAddress`: `VR_InitInternal`, `VR_InitInternal2`, `VR_GetInitToken`, `VR_IsInterfaceVersionValid`, `VR_GetGenericInterface`, `VR_ShutdownInternal`. It logs real application type, caller/thread, token, error, interface request and returned pointer, preserving results and last error. It skips an already-wrapped target and does not invoke the older compositor/vtable-patching trace path. Records are bounded per export. These wrappers add native/guest callback boundaries, so a resulting stop is diagnostic evidence, not a normal execution acceptance.

Owned `aot_openvr_init` uses a separate repository-owned DLL with deliberately distinctive tokens/errors/pointers/last-error values. Its folder and modules are **never** added to actual game search roots. Direct import and dynamic lookup of the same export must retain identity, actual values and the expected output. Default execution must not trace or change behavior.

The original owned test DLL preferred `0x7000000000`, which the OS sometimes relocated. Strict AOT correctly rejected its mismatched base. Attempting to rebase that minimal DLL's descriptor then correctly failed because the all-RIP-relative fixture has no relocation directory. These two fixture-layout attempts were stopped and narrowed: a new owned DLL was linked directly at reserved arena base `0xf06000000` in `build/recomp/openvr-init-fixture-arena/`; the original PE/modules/evidence were preserved. The unchanged EXE was copied there and only the new DLL's module regenerated into a new `openvr-init-aot-fixed/` directory. No runtime mapping rule was weakened.

`tests/aot_openvr_init_check.py` passes for both default and traced execution under `diag-006`: exact fixture verdict, exit 0 and positive AOT entries/zero fallback. The traced run records 46 entries, actual tokens 257/514, errors 11/23/31, bool true/false and the actual `0xf06002000` pointer, with no recursion or interface patch. Evidence is under `missing-import-regression/openvr-trace-after-fixed/`; earlier red trace assertions and fixture-layout failures remain alongside it. Runtime SHA-256: `3e624c97f89f5f5bb5d69bf54481a8084d335ff92d5349c988deec11cdef8be1`. Source/runtime identities are under `diag-006-build-inputs/`.

## Actual OpenVR outcome and next boundary

`probe-skyrim-009` uses that candidate, `--trace-openvr-init`, the unchanged real prepared game/Valve modules and original DLL search roots. No owned diagnostic DLL is present in those roots. It does not set a callback-depth limit.

- `o6` and the sealed log directly record `VR_InitInternal2(type=1, startup=NULL)` returning token **0**, error **110**. Both pinned OpenVR headers label that error `VRInitError_Init_PathRegistryNotFound`.
- The game does not call `VR_GetGenericInterface("IVRSystem_019")` on this initialization-error branch. Static flow initializes the prospective pointer to null and stores it at `BSOpenVR+0x208`, explaining the later member value without inventing a returned System019 pointer.
- A later real `VR_GetGenericInterface("IVRCompositor_022")` returns null with error **109**, `VRInitError_Init_NotInitialized`, also captured in `o6`.
- The same null read at `SkyrimVR.exe+0xc53e1b` then occurs. Exit 5 (`o1`), no timeout (`o2`), unchanged inputs (`o3`). AOT summary absent (`o4`), so totals/fallback acceptance remain unknown. No native signal was captured (`o9`), and no missing-code diagnostic was captured (`o5`).

This identifies the current observed barrier as the real guest OpenVR runtime initialization/environment path. It does not justify another arbitrary code-discovery pass, a patched game null check, a fabricated VR success or installing an external SteamVR dependency into the accepted standalone design. The next game integration gate is the genuine native xrizer/provider path already under development, through correct Windows guest ABI exports and actual local presentation/input. Owned compiler/API/ABI regressions and unresolved broad baseline checks can proceed independently meanwhile. The separate native stack/callback failure in probe 007 remains unresolved; this diagnostic is not its fix.

All 25 native-startup ledger records validate after probe 009. Further game probes should answer a new bounded question rather than repeat the now-classified missing-runtime outcome.

### Candidate 006 required regression batch

The serial batch is preserved in `runs/skyrim-feasibility/missing-import-regression/required-checks-diag-006/`, using the unique ARM64 and Rosetta `diag-006` runners rather than rebuilding the sealed original runners. Owned missing-import/interior-address, callback-depth and OpenVR passthrough checks all exit 0. `aot-suite` exits 0, including the real MSVC-ABI suite and split-module strict-AOT comparison.

`check` and `check-arm64` both exit 2 in the D3D12 runtime test. Each reaches the cross-queue fence wait/signal verdict before a native SIGSEGV in `d3d_release` at address `0x9f`. Rosetta's caller is `obj_release` then `d3d12.exe+0x6505`; ARM64's is `vxt_obj_release`. This is a newly observed broad-check failure, not the earlier kernelx/SMC failure from the `diag-002` batch. No source-unmodified comparison has established whether this particular failure is baseline or regression. The broad runtime baseline remains red; no D3D12 source change or waiver is made in this lane.

### Arena warning in probe 005

The log begins with a failed initial reservation at `0xf00000000`, followed by a mapped-range diagnostic. `src/loader.c:main` retries by `execv` before PE loading when this reservation fails. Later lines load all seven actual PE subjects' AOT descriptors at their exact expected bases, including Bink at that same arena base, and the final summary reports zero fallback. There is no observed active guest module mismatch or missing code in this run. The source/log combination supports an earlier retry as the explanation; successful reservation/restart is not logged directly, so that mechanism remains an explicitly identified inference rather than a new raw observation. Preserve the warning in reports; it does not invalidate the direct missing-ordinal diagnostic.
