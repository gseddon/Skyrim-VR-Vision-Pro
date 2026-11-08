# xrizer Darwin build spike

`upstream/` is Supreeeme/xrizer commit `0989a7fac2d1efb7ea82f5fe1a8ed30c3eeb9596`, GPL-3.0-or-later; retain its `LICENSE`, copyright notices, bundled header notices, and transitive dependency notices. See the adjacent research report for provenance, scope and follow-up. AVP Play's separate three patches are not applied.

The source has narrow Apple build adaptations. Its OpenVR frontend remains upstream-derived with local fallible copy and Apple presence changes; default Apple initialization deliberately reports `AppleBackendUnavailable`. This is a build-port experiment, not a working VR runtime. The Apple path currently excludes GLX/UI and the Vulkan overlay shader pipeline; it has a Metal backend and explicit provider registration under development, but no verified real-provider initialization or frame path and must not be used for a game.

To build using an already-installed repository-local Rust toolchain, set `XRIZER_RUST_ROOT` to the directory containing `cargo/` and `rustup/`, then run `./build-macos.sh`. This stores compiler output under that directory, does not install tools or touch global configuration, and may download dependencies into its Cargo home. A successful archive does not validate guest ABI or frame presentation.

`./test-macos.sh` runs the host-only fail-closed initialization smoke test. `./build-visionos.sh sim` and `./build-visionos.sh device` cross-compile with the corresponding installed Rust target and Xcode SDK; the simulator bindgen command explicitly selects Clang's xros simulator target. Both use per-SDK target directories and local XDG state/config. These are build checks only; they do not launch a simulator or prove guest ABI, GPU submission or device behavior. See `SOURCE.md` and `apple-port.patch` for the source pin and local changes.

On 2026-11-08, Rust 1.99.1 / Xcode visionOS 26.1, the unoptimized archive checksums were:

- `build-visionos.sh sim`: `61d74fde1b09feb5f45dd5c27cfaad7fcf67dab86e8884e8ce05b11efd92b50c`
- `build-visionos.sh device`: `f9381936371f1e2dfb97433e10a86d54eff88b6428ffe0c98f78960f03e5e828`

These identify the observed local artifacts; builds are not asserted to be reproducible bit-for-bit.

`./test-metal-binding.sh` exercises the Metal binding with mock OpenXR dispatch on macOS; it checks binding structure types, command queue and image enumeration and error propagation, without a GPU or a real provider. The binding does not retain Metal objects or synchronize GPU work.

The separate `include/metal_host_bridge.h` defines a versioned native host callback table and an isolated fail-closed bridge in the Apple port. Its synchronous copy callback must wait for GPU completion; the host acquires and releases guest texture leases and validates device/format/color. It is not registered, no host implementation is supplied, and the mock tests do not exercise Metal. `test-metal-binding.sh` also checks C/Rust host layouts and mocked bridge error/lifetime paths.

An explicit `owned-apple-test` Cargo feature is for the repository-owned native frontend integration fixture only. It requires registered Metal host/provider callbacks and preflights actual stereo view configuration; the default build continues to refuse Apple initialization. Test registration alone, compiled archives and mock callbacks do not prove session, pixels, guest ABI or VR. The current DirectX path conservatively rejects ambiguous source colour conversions, unsupported flags, overlays and non-pixel-aligned bounds.
