# Workspace and source-control migration

8 November 2026. One repository is sufficient for the standalone project and its pinned source dependencies.

| Location | Role |
| --- | --- |
| `/Users/gseddon/git/Skyrim-VR-Vision-Pro` | New source repository, `codex/standalone-import` |
| `/Users/gseddon/git/VeRantyx/build/worktrees/native-darwin-aot` | Active agents/builds/private evidence during this uninterrupted source migration |
| `/Users/gseddon/git/VeRantyx` | Original main checkout with mirrored plans |
| `.../build/worktrees/skyrim-vr` | Earlier Skyrim experiment, preserved |
| `.../build/worktrees/native-darwin-{mac,headset,contract}` | Earlier parallel port checkouts, preserved |

Agents continue their current work in the implementation checkout while source snapshots are checked into the new repository. No old worktree is reset, removed or repointed. At a natural checkpoint, agents can move to the new source checkout after private build/input paths are configured and existing evidence remains valid. Until then, new verified source increments are synchronized independently of private artifacts.

GitHub authentication for this repository uses its own `GH_CONFIG_DIR` under `.git/gh-auth` and a repository-local HTTPS credential helper. No credentials are committed. Existing global configuration is preserved. Use that environment for `gh` operations on this repository; ordinary Git uses the local helper.

The imported checkpoint has known failing broad runtime checks. Source control preserves this experimental state and its explicit limitations; the import is not a compatibility or playability claim.

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
The latest root Python suite has 20 passing tests. All three agents are paused
at safe checkpoints for a planning review; Stage2 has not started. Next
implementation assignments should use Terra for the user's cost preference.
