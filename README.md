# Skyrim VR on Vision Pro

Experimental work toward running an owned Windows x86-64 Skyrim VR build locally on Apple Vision Pro: ahead-of-time ARM64 recompilation, VXRuntime Windows compatibility and D3D11→Metal, with native xrizer and a Klepton-derived OpenXR provider.

## Current status

This is a development checkpoint, not a working game release.

- A private prepared executable is available and mostly discoverable. Native strict-AOT startup reaches original game/OpenVR initialization; the observed blocker is Valve error110 (missing OpenVR runtime path registry). The separate native callback fault and broad runtime regression failures remain unresolved.
- Owned native fixtures initialize actual xrizer, submit real Metal stereo images into the native frame queue and verify pixels, pose/frame identities, resource lifetime and four failure/retry paths. Host tracking/lifecycle are injected test data.
- Actual Windows MSVC callers pass static thunk tests for scalar, float and large matrix returns; a separate guest control forwards into the actual native xrizer factory and preserves its default initialization failure.
- Windows guest integration with the real provider, nonzero pose arrays/input, Sony PS VR2 Sense tracking, physical headset execution and an actual Skyrim scene remain open.

The plans are the source of truth: [main plan](plans/2026-11-08-skyrim-vr-native-darwin-aot.md), [AOT feasibility](plans/2026-11-08-skyrim-vr-prepared-input-aot-feasibility.md), [xrizer/Klepton](plans/2026-11-08-xrizer-klepton-native-openxr.md).

## Source layout

| Directory | Purpose |
| --- | --- |
| `VXRuntime/` | Windows compatibility, x64→ARM64 compiler, Metal renderer, visionOS host, owned fixtures |
| `third_party/xrizer/` | Pinned GPL xrizer source and Apple port |
| `third_party/klepton_openxr/` | Pinned/adapted MIT OpenXR provider and owned native Metal fixtures |
| `tools/`, `tests/` | Static audits, reproducible AOT pipeline, native startup evidence and unit tests |
| `plans/`, `research/` | Decisions, verified results, provenance and remaining risks |

Other VeRantyx directories are retained as upstream reference and build context. The target here is standalone headset execution. See [UPSTREAM.md](UPSTREAM.md) for source provenance and [MIGRATION.md](MIGRATION.md) for the active workspaces.

## Initial checks

On an Apple silicon Mac with Xcode and the visionOS SDK installed:

```sh
mkdir -p build
make -C VXRuntime build/vxrt-aot build/native_vr_test
VXRuntime/build/native_vr_test
python3 -m unittest discover -s tests -p 'skyrim*_test.py'
python3 -m unittest discover -s tests -p 'vxrt_native_startup_test.py'
third_party/klepton_openxr/build-test.sh
```

The full runtime also requires the existing MinGW cross-compiler. Rust checks use the repository-local toolchain selected by `XRIZER_RUST_ROOT`; component scripts document targets/features. The experimental `owned-apple-test` route is for owned integration fixtures. Ordinary Apple initialization remains unavailable while required behaviors are incomplete.

## Private inputs and artifacts

This repository contains source and owned test inputs. Game executables/data, Microsoft/Valve runtime DLLs, prepared images, translated game code, toolchains, downloaded tool packages, build outputs and raw run directories remain local and ignored. Do not redistribute them. Private-input tools require local hashes/paths and preserve original installations.

## Licensing

VeRantyx's original MIT notice is retained in [LICENSE](LICENSE). xrizer is GPL-3.0-or-later; Klepton and Khronos/OpenVR headers retain their own licenses and notices. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and each component's source record. The original project README is retained under `docs/VERANTYX_UPSTREAM_README.md`.
