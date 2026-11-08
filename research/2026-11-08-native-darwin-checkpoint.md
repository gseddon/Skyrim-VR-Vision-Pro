# Native Darwin checkpoint — 8 November 2026

This user-requested local checkpoint preserves a partial implementation, not a finished XR runtime or Skyrim port. Main documentation and implementation are on separate branches/checkouts identified by the plan; old Skyrim work is preserved.

Verified on this implementation's source/artifacts:

- Mac runtime builds and owned D3D11 stereo diagnostic fixture: Rosetta, ARM64 translation, strict AOT; expected pixels/verdicts, strict AOT zero fallback.
- Owned recomp semantic suite: normal and split AOT modules, zero fallback.
- Native frame queue, FPCR native-call regression, comparison/evidence/device-runner tests; offscreen Metal presenter pixels, eye bounds, color and rotation checks.
- Unsigned visionOS device fixture app builds. Generic owned recomp suite executes in visionOS simulator with `VXRT_TILED_STAGING=1`, including D3D11 pixel checks, 8167 AOT entries and zero fallback.
- Vendored xrizer frontend builds native ARM64 macOS and visionOS simulator/device libraries. Host C factory smoke test validates explicit unavailable-backend initialization failure, not functional VR.
- Instruction synchronization and whitespace checks pass.

Known failures and unverified work:

- Broad `make check` fails an intermittent kernelx released-memory assertion also reproduced in the source-unmodified Rosetta baseline. `check-arm64` fails in threads.exe, also observed in the fresh baseline. Broad baseline is not accepted.
- Default buffer-backed staging textures abort in Metal simulator; the successful suite uses the existing tiled-staging option.
- xrizer Apple initialization deliberately returns AppleBackendUnavailable. Metal backend, native OpenXR provider, guest Windows ABI integration and xrizer frame delivery are not implemented/proven.
- No Skyrim game run, physical-headset install/launch/playtest, or performance claim. Static discovery leaves 78.98% of exe code-section bytes unexplained; classification and earliest reachable strict-AOT execution are the next investigation.

Detailed commands, scopes and source pins: current plan; `research/2026-11-08-avp-play-xrizer.md`; `third_party/xrizer/README.md` and `SOURCE.md`. Local evidence: `runs/native-darwin-integration/` and `runs/native-darwin-bootstrap/` (ignored artifacts, not game profiles). Original PE/game files and toolchain caches are not committed.
