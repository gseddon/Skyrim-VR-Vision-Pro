# Workspace and source-control migration

8 November 2026. One repository is sufficient for the standalone project and its pinned source dependencies. The source, approved plan and all new implementation work are now in this repository.

| Location | Role |
| --- | --- |
| the main checkout of this repository | Integration checkout, branch `codex/standalone-import` |
| `build/worktrees/terra-guest-stereo` in this repository | Terra A: guest graphics/ABI, branch `codex/terra-guest-stereo` |
| `build/worktrees/terra-pose-input` in this repository | Terra B: poses/input, branch `codex/terra-pose-input` |
| `build/worktrees/terra-skyrim-aot` in this repository | Actual Skyrim/AOT checkout (parent orchestration while Terra C is stopped), branch `codex/terra-skyrim-aot` |
| `build/toolchains/xrizer-rust` in this repository (git-ignored) | Rust/Cargo toolchain (rustc 1.99.1); installed by `tools/setup_rust.sh`. Default of `XRIZER_RUST_ROOT`; scripts source `third_party/xrizer/rust-env.sh` |

The approved round starts from `8eb61b4` (implementation checkpoint `fc17152` plus the approved plan). The three new agents are Terra; historical workers remain idle. New tests/builds/evidence stay in each new worktree's ignored output paths. Private game inputs are copied only when needed and checked by hash; unchanged AOT modules may be reused by explicit immutable paths after matching descriptors/bases. No old worktree is reset, removed or repointed.

GitHub authentication for this repository uses its own `GH_CONFIG_DIR` under the integration checkout's `.git/gh-auth` and a repository-local HTTPS credential helper. No credentials are committed. Existing global/work account configuration is preserved. Use that environment for `gh` operations on this repository; ordinary Git uses the local helper.

The imported checkpoint has known failing broad runtime checks. Source control preserves this experimental state and its explicit limitations; it is not a compatibility or playability claim. Historical import verification follows.

## Import verification

The source checkpoint was checked in the new checkout: 18 root Python tests,
the AOT compiler build, native frame queue and FPCR unit checks, the five-case
AOT comparison tests, five device-run tool tests and five native-run tool tests
passed. `third_party/klepton_openxr/build-test.sh` passed its CPU/mock/UBSan
checks and compiled the visionOS simulator/device archives. Generated agent
rules are synchronized. No game or physical-headset run was made here.

The broad `check` / `check-arm64` failures remain unresolved in the active
checkout, including the D3D12 native object release failure; see the plans.
Imported upstream whitespace remains unchanged. This initial import excludes
the unexecuted joined guest/provider experiment and its in-progress build
hooks; verified increments will follow separately.

## Planning checkpoint after initial import

The follow-up source commit includes the executed joined guest Stage1 fixture,
its helper and opt-in build/scanner hooks. Its frozen source and artifact
identities are recorded in `provenance/checkpoint-2026-11-08-joined-stage1.json`.
It passes with 33 AOT entries and zero fallback, including real provider
initialization, matrix returns and cancellation/cleanup, without drawing.
Later provider action identity and xrizer failure controls have separate test
evidence; the artifact pins distinguish them from the frozen Stage1 build.
The latest root Python suite has 20 passing tests. The three original agents paused at safe checkpoints for planning. The user
then approved the next round: three new Terra agents now work in the new
repository as listed above. Stage2 guest stereo, poses/input and actual game
routing are active; this does not change the earlier acceptance scope.
