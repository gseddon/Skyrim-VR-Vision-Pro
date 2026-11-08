# Windows guest ABI boundary for native xrizer

Date: 8 November 2026. Subject: owned fixture and static source/assembly analysis, not Skyrim or real xrizer execution. Status: actual MSVC guest/static native thunk controls pass on ARM64 macOS.

## Boundary

The pinned xrizer frontend exports native `extern "C"` factories (`third_party/xrizer/upstream/src/lib.rs`, `VRClientCoreFactory`). Its generated object vtables and C FnTables also use native `extern "C"` functions (`openvr/build.rs`, `generate_vtable`). Those native pointers cannot be placed directly in a Windows guest table: they have neither the guest register/return convention nor an entry in VXRuntime's static thunk registry.

`VXRuntime/tools/vx_thunks.py` already generates C glue for positional Windows integer, pointer and float arguments and float returns. Large aggregate returns are rejected by that generator; it must not silently guess a native ABI. A narrow route is a static C wrapper with an explicit Windows return-buffer argument, a normal native call to the actual backend, a copy to that buffer and the buffer address returned in RAX. This requires different wrappers for MSVC C++ members and C FnTables. It requires no runtime-generated code or generator extension.

## Independent MSVC caller evidence

`VXRuntime/tests/xrizer_guest_abi.cpp` is compiled with `clang -target x86_64-pc-windows-msvc`, not MinGW C++. Its COFF object is linked without a CRT by MinGW's linker and existing kernel32 import library. The source uses the pinned `openvr-1.3.22.h` classes, whose version constants are System019 and Compositor022. `tests/xrizer_guest_abi_header.py` creates a freestanding build-only header view: it removes only unused `CVRSettingHelper`/`string` and the external inline API wrappers. Interface/type declarations and packing remain unchanged. It checks the exercised method names against their indexes and records original/view hashes.

The owned `guest-msvc.s` assembly establishes the actual calls:

| Method | Guest arguments at callee entry |
| --- | --- |
| System019 slot 1 `GetProjectionMatrix` member | RCX=self; RDX=64-byte output; R8=eye; XMM3=near; `[RSP+40]`=far |
| System019 slot 4 `GetEyeToHeadTransform` member | RCX=self; RDX=48-byte output; R8=eye |
| C FnTable projection, same logical return | RCX=64-byte output; RDX=eye; XMM2=near; XMM3=far |
| C FnTable eye transform | RCX=48-byte output; RDX=eye |

The member projection's caller writes far to `[RSP+32]` before `call`; its return address makes that `[RSP+40]` in the callee. Matching record sizes alone would miss this difference. The broad positional register/stack and indirect aggregate-return rules are documented in [Microsoft's x64 calling convention](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170); the member-specific ordering here is directly observed in this compiler's owned assembly.

## Owned static thunk fixture

`tests/xrizer_guest_abi_host.c` is linked only through the test runner's extra-source hook. It registers the uniquely named `vxrt_guest_abi_fixture.dll`, never `openvr_api.dll`. Tables contain Windows-shaped wrappers registered through the existing generated C thunks. The backend is an independently specified native callee returning nonsymmetric matrices and a distinctive float. It is not a VR implementation and does not establish xrizer semantics, projection correctness or presentation.

The positive guest exercises factory/init errors and tokens; self identity; System019 scalar/output methods and role slot 18; native Matrix44/Matrix34 returns copied through member and C FnTable adapters; Compositor022 slot 10 float return; guard words; and last error. The negative mode deliberately puts the unregistered native projection pointer in a separate fixture object. Strict AOT must reject it before native execution; reaching the sentinel is failure.

Use a unique runtime `build/vxrt-arm64-guest-abi-001` with `VXRT_ARM64_EXTRA_SRC=tests/xrizer_guest_abi_host.c` and `VXRT_ARM64_THUNKS_ROOT=build/xrizer-guest-abi`. Ordinary runner defaults and the shared thunk registry remain unchanged. AOT scratch is serialized with other compiler work. The immutable fixture, generated header/assembly/thunks, runtime hash, source/patch identity, command, roots, exits and actual counters must accompany a result. The fixture is CPU-only; no game probe is needed to prove this boundary.

## Observed result

`runs/skyrim-feasibility/missing-import-regression/guest-abi-001-check-final/` contains the actual commands, separate roots/logs/exits and immutable subject hashes. The positive control exits 0 with its exact guest verdict, **28 AOT entries, 28 native calls and zero fallback**. The explicit output-buffer calls also check that RAX returns the buffer address and guard words remain intact. The negative raw-pointer control exits 3, with **11 AOT entries and one missing target** classified `no image`; it reaches neither the native fixture assertion nor the guest success sentinel. This increments the existing fallback counter but strict mode stops before calling the translator. It is an expected negative control, not standalone acceptance.

`guest-abi-001-build-inputs/` records hashes of 345 source/generated/artifact inputs plus source and assembly copies and the tracked patch. Native ARM64 assembly independently shows the wrappers setting X8 to their local aggregate buffer before calling the normal native callee, then copying into the guest-provided buffer. Runtime SHA-256: `9046d477be063088daafc740023bbf87be65378782c8db7445cd63b6382f1cc8`. The original ARM64 and Rosetta runner hashes remain unchanged. `guest-abi-001-check/` retains the first pass; the final check reruns the current check script against the same immutable runtime, EXE and module.

No production adapter, generator, renderer or game image was changed for this proof. The preceding `diag-006` regression batch passes owned diagnostics and `aot-suite`, while both broad runtime checks remain red in D3D12 resource release; see the no-image investigation for the exact unclassified failure. Fixture success does not waive that result.

## Remaining integration gate

After the owned ABI proof, real xrizer's versioned factory/object lifetimes and real backend errors must be forwarded through equivalent static guest stubs. Cover required methods and structure layouts from the actual version definitions, rather than exposing Rust tables or expanding `native_openvr.m`. The eventual joined fixture must demonstrate real xrizer plus the native OpenXR/Metal provider. Owned matrix goldens do not satisfy that gate; physical-headset execution and actual Skyrim remain unverified.

## Real native xrizer forwarding control

The shared toolchain dylib did not have trustworthy feature/source identity, so it was not used. `guest-real-001-xrizer/` contains a separate 130-file source snapshot, verified against the implementation source before compiling. A fresh isolated Cargo target built that snapshot with `--lib --no-default-features --target aarch64-apple-darwin --locked --offline`. The resulting library was copied to the evidence directory before loading, SHA-256 `2ad3f7868b4efc3d3f4f464a783704adbcbe10b9b18543ed3aeae07cde702598`. It registers no provider and has no owned-Apple test feature. The native `apple_init.c` reference exits 0 after observing the actual unavailable-backend error 150.

New `tests/xrizer_guest_real_host.c` forwards to that real native library, retaining its raw Rust ClientCore object on the host. A guest object contains only generated-thunk-registered wrappers. The real factory's output/error are preserved. `tests/xrizer_guest_real.cpp` is another actual MSVC-target COFF caller, using the original `ivrclientcore_003.h` declaration in addition to the pinned type header. Its strict run verifies:

- Actual factory returns a non-null native core with error 0, wrapped without exposing the native table.
- System019 and Compositor022 version queries return 0; an unknown System999 returns actual `Init_InvalidInterface` 106.
- Native `BIsHmdPresent` returns false before and after failed initialization.
- Invalid application type returns 130; scene initialization returns actual `AppleBackendUnavailable`/`VRServiceStartupFailed` 150.
- Windows last error remains unchanged through the forwarded member calls.

The System019-era header predates the enum name for error 150; the current xrizer `openvr-2.12.14.h` defines it. The guest compares the actual numeric code, without converting it to an older error. It does not call `GetGenericInterface` or `Cleanup` after failed initialization: the inspected native implementation assumes an initialized OpenXR state in those methods. There is no dummy System/Compositor object and no VR success claim.

`guest-real-001-check/` records exit 0, the exact guest verdict, **15 AOT entries, 15 native calls and zero fallback**; the actual native log explicitly reports `AppleBackendUnavailable`. `guest-real-001-build-inputs/` records the host/guest sources, MSVC assembly, generated thunks, runtime/EXE/module/library hashes and source patch. The runner is the separate `build/vxrt-arm64-guest-real-001`; the first ABI fixture runner remains immutable. This verifies real factory/member/error forwarding through static guest thunks on ARM64 macOS. A successful real-provider init, versioned System matrix calls, stereo submission and visionOS execution are the next joined-fixture gates.

## Joined real provider, matrices and clean cancellation

The next owned fixture uses `tests/xrizer_guest_join_host.m`, `xrizer_guest_join.cpp` and `xrizer_guest_join_check.py`. The headset worker supplied component-only `third_party/klepton_openxr/tests/xrizer_guest_host.{h,m}`, reusing the verified native provider/Metal/session/frame helpers. This is an explicit owned provider with injected frame/tracking samples, not a physical host. No production loader route or old `VXRT_NATIVE_VR` path is enabled. Native core/System/FnTable pointers remain private behind static registered wrappers, with the exact System019 47-slot and Compositor022 44-slot layouts.

`guest-join-001-build/` preserves the component/xrizer/helper source snapshot, native-object commands/exits, an isolated offline `owned-apple-test` Cargo build, copied native library, runtime link command and unique candidate. Only the two owned wrapper/caller files were refreshed before thunk generation to add genuine unsupported-input checks; the frozen provider/Rust snapshot was unchanged. Native provider/helper objects compile with `-Werror`. The Makefile's opt-in extra include/object/link hooks and ABI scanner's `shlex`-parsed `VXRT_ABI_SCAN_EXTRA_CFLAGS` permit this test composition; ordinary defaults remain empty. The runtime already links `native_vr.c`, so the helper link does not duplicate it.

`guest-join-001-check/` records the actual strict MSVC guest result:

- Native xrizer scene initialization returns **0**, and actual System019, Compositor022 and System019 C FnTable requests return non-null native objects/tables that are wrapped for the guest.
- Recommended eye dimensions are 8×8. Both eyes' member and C FnTable Matrix44 projections and Matrix34 eye transforms match independently calculated asymmetric FOV/near/far and ±32 mm eye-offset goldens, with guarded guest outputs.
- Actual `IsInputAvailable` returns false. All three actual nonzero-pose methods (`WaitGetPoses`, `GetLastPoses`, `GetLastPoseForTrackedDeviceIndex`) return `RequestFailed`, leave sentinel outputs intact and acquire no frame ticket. These are honest refusal checks, not pose/controller support.
- `WaitGetPoses(NULL,0,NULL,0)` latches the owned frame **101**, pose **201** and positive predicted timestamp. Matrices are queried only while that sample is valid.
- Actual `PostPresentHandoff` submits an empty layer list. The provider consumes exactly one cancellation ticket and publishes **zero pictures**; no source is acquired, copied or released.
- Actual ClientCore cleanup acknowledges one begin/exit/end lifecycle and one create/destroy session. The helper finishes with no outstanding ticket/readers.
- Guest exit **0**, exact verdict, **33 AOT entries, 33 native calls, zero fallback**.

This closes the real provider-bound guest initialization/matrix/cancellation gate on ARM64 macOS. It does not draw, submit a texture, implement nonzero pose arrays/controllers, run on visionOS, or establish Skyrim compatibility. Real Windows D3D11 handles, source producer completion, stereo pixels and resource leases remain the next fixture gate. The broad runtime checks remain red as previously recorded.
