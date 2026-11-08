# Klepton native provider → real Metal frame → native queue

8 November 2026. Owned offscreen fixture, macOS ARM64. This report does not credit xrizer, a Windows/AOT guest, simulator/device presentation, physical tracking/controllers or Skyrim execution.

## Result and boundary

`third_party/klepton_openxr/tests/frame_metal.m` passes through the actual extracted provider dispatch, Metal session and array swapchain, Apple resource/image-sync adapter and `VXRuntime/src/native_vr.c` queue. It injects deterministic host lifecycle, poses and clock values. `KL_NATIVE_TEST_METAL_PARTIAL` is required; production Metal advertisement remains withheld.

The fixture performs real GPU writes and readback. Each provider array layer is cleared, then an interior 4×3 subrect at (2,1) is filled red for the left eye and green for the right. On accepted end-frame publication, the host blits the actual submitted layer/subrect into separate retained 2D Metal textures, commits and waits for successful GPU completion, and only then completes one atomic native-queue stereo frame. This is a same-queue fixture; it does not establish source-D3D producer ordering across other queues.

Verified by assertions:

- Four actual stereo pairs preserve source frame/pose IDs, monotonic nanosecond sample time converted to seconds, valid tracking, submitted FOVs and render-eye transforms.
- LOCAL and independently specified rotated/translated STAGE projection submissions produce hard-coded expected transforms. The host derives head-from-render-eye using the sample head pose and the **submitted** render-eye pose, not the sample's nominal eye offsets. OpenXR FOV radians map to signed native tangents as left, right, negative-up, negative-down.
- A release with no recorded producer writes fails; the real committed write buffer is then registered and the image-sync adapter waits for actual completion before release.
- An injected publication failure after retaining the first eye cancels/drains the partial native frame and publishes nothing. Retrying the same provider end-frame succeeds.
- Reusing provider image index 0 with blue/yellow pixels does not alter the held older red/green frame. Provider swapchain-image teardown while the latest native reader is held also leaves independent copied-eye pixels valid.
- A repeat acquisition preserves the same source IDs and pixels. Reader leases drain before end-session; strong retain/release counts balance after reset and teardown.
- Final fixture also waits/begins an explicitly non-rendering, invalid-tracking frame, cancels its unique ticket without publication, and confirms the queue has no frame.

Full session end intentionally occurs **after** reader release/reset, consistent with `session_host.h`'s drain contract. The held-reader teardown test concerns the provider's image/swapchain references, not permission to destroy a session while readers remain.

## Commands and immutable evidence

`third_party/klepton_openxr/test-metal-frame.sh --build-only` snapshots all needed component C/Objective-C/header sources, the fixture/runner, and native queue sources into a fresh ignored directory. It verifies sources did not change during snapshot, writes SHA-256 identities, and builds with `-arch arm64 -Wall -Wextra -Werror`. Both successful snapshots used Apple clang 17.0.0 and macOS SDK 26.1. GPU execution was separately reserved with the parent and bounded to 30 seconds; both exact artifacts exited 0 in under one second. The slot was then released.

Evidence directories, relative to `third_party/klepton_openxr/build/`:

| Snapshot | Subject | Exit |
| --- | --- | --- |
| `metal-frame-rjPThL/` | Four real pairs, crop/transform/ownership/partial-failure checks | 0 |
| `metal-frame-QnQCLq/` | Same proof plus non-render invalid-tracking ticket cancellation | 0 |

Each directory contains `source/`, `source-manifest.json`, `environment.txt`, `artifact.sha256`, `metal-frame`, `run.log` and `run.status`. These ignored artifacts remain local and do not travel with a normal commit. One earlier compile-only snapshot (`metal-frame-Crjukv`) failed because Objective-C properties cannot have their address taken; using a local sample value fixed it. No GPU execution was attempted for that failing build.

| Artifact | rjPThL SHA-256 | QnQCLq SHA-256 |
| --- | --- | --- |
| source manifest | `6f0a1ca82c9e228e9356f82ba81025970182391d411470d097e97184fb0d5066` | `93602a6250a7550e00dbcaf1a8289f44f831f8a08950fca151a2c978de774ef5` |
| binary | `94bca672900e07224bd3a78bb8ae22b2836d0c822e31a6f627b1d7ec6c282ec4` | `8703ed38afe56f00027864dedf56656ae99bac92853f8b5c26672cbdfd357d2d` |
| run log | `9452f197fef353e1815cd8c0b0086f9f3a0df3fed523c72488103707d8fc798f` | `9452f197fef353e1815cd8c0b0086f9f3a0df3fed523c72488103707d8fc798f` |
| exit record | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |

Shared source identities in both snapshots:

- Provider `src/core.c`: `76584fab951313674f6f5d4ff7cf30b50c0721fbfcbccd626554121519bdfe85`.
- Apple adapter `src/metal_host.m`: `f4aee6cc939a51dfd4bc01b46ccc32095b07642a96bbbdcb3d0d1a032f424063`.
- Pose math `src/pose_math.c`: `841bcc2b80e86435c25e81fe7d4138da49746cde86433eec9f8d27a63aa4dbdc`.
- Native queue `VXRuntime/src/native_vr.c`: `44b9652fa43a37f502909fa78d60f87661c7903308949995d6db12450501788e`.
- Final fixture: `2a71533209fcd0f3635fca1fc5ebb7861a58fc6ed5f8dad9e9b3e33347d8d414`.
- Runner: `465b414f4385b084c3e0d67c7476115c106202bc245a15ea745246311b59b8ee`.

## Next integration gap

This fixture enters the provider directly through native C OpenXR calls. The next proof must connect actual xrizer initialization/submission and, separately, the Windows guest ABI/AOT boundary. Keep unsupported view/action/input APIs honest, propagate copy/acquire/frame errors, and preserve source color interpretation and completion ownership. A native provider fixture pass cannot be promoted into an xrizer or guest result.

## Actual xrizer native frontend refusal checkpoint

A subsequent owned fixture (`tests/xrizer_frontend.m`, runner `test-xrizer-frontend.sh`) loads the actual xrizer native library built with explicit non-default `owned-apple-test`, registers the extracted provider entry and real Apple Metal resource/image-sync host, and calls the actual `VRClientCoreFactory("IVRClientCore_003")` and native-ABI Init. It traces provider dispatch and the actual view-configuration call. It does not patch in successful provider answers.

Snapshot `third_party/klepton_openxr/build/xrizer-frontend-ctnWF2/` contains the complete xrizer Rust workspace plus provider sources/headers, native fixture/bridge, SHA-256 manifest, Rust/clang environment, isolated Cargo target and build/run logs. Offline locked Rust build and native executable both exit 0. Actual OpenVR Init returns 150, correctly exposing `RequiredViewConfiguration(ERROR_FUNCTION_UNSUPPORTED)` from one provider `xrEnumerateViewConfigurationViews` call (result -7). Session poll/begin, frame wait and texture acquire/copy counters are all zero. No panic or GPU command occurs. The fixture's successful exit means the expected refusal is verified, **not** that Init or VR succeeds. Resolvable action/view API pointers in the dispatch trace include refusal-only functions and do not establish those features.

Build command:

```sh
XRIZER_RUST_ROOT=/Users/gseddon/git/VeRantyx/build/toolchains/xrizer-rust third_party/klepton_openxr/test-xrizer-frontend.sh
```

Toolchain: Rust/Cargo 1.99.1; native target `aarch64-apple-darwin`; `--no-default-features --features owned-apple-test --offline --locked`; provider built with `KL_NATIVE_TEST_METAL_PARTIAL`; Apple clang 17.0.0. The default xrizer Apple initialization remains unavailable. Source is captured independently of any later concurrent provider/frontend edits.

| ctnWF2 artifact | SHA-256 |
| --- | --- |
| source manifest | `d3e16cc9251edc57054da0345a9ff04219d569dcec5232de572cad1841701d07` |
| native frontend fixture | `967181df655f990ec91976007939cb390b78760095beccebb7c20682bc463fa1` |
| actual xrizer dylib | `e1691108211def011d07728e905bfd89293567c75219f9b8176f0bd7ef26784d` |
| run log | `4a99988c3151fedc9927a524736a49f5ad7c88478272603ded2b5090b4c2438d` |
| exit record | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| environment | `f7c6699bd008f4669c2829b19d838b6fc3a35b8ffba79c0a6777a94e1e1f1335` |

The exact next gate is host-supplied stereo view metadata. Supply deliberate owned-fixture dimensions/limits via an explicit provider host contract, then advance real Init/session requirements without guessing physical display properties. Existing xrizer session/frame `unwrap`/`expect` paths need real error propagation before production use. This native bootstrap does not establish Windows guest-callable vtables, AOT execution, xrizer eye submission or physical tracking/input.

## View metadata and positive native bootstrap

Snapshot `xrizer-frontend-2dahPs` supplies explicit owned 8×8 stereo metadata after verifying a real provider-owned Metal array allocation. Its native Init reaches a real Metal session/reference spaces, then returns 150 with `SessionCreationFailed(PollEventFailed(ERROR_SESSION_NOT_READY))` because no READY event was injected. The fixture asserts one session poll and zero begins/frames/copies, exits 0, and releases all provider objects. This is a verified explicit refusal, not a timeout or successful initialization.

Snapshot `xrizer-frontend-bwwk2x` then supplies explicit injected READY/begin acknowledgement and request-exit/STOPPING/drained-end/EXITING lifecycle. Actual native xrizer Init returns 0; native `IVRSystem_019` returns the owned 8×8 dimensions; `IVRCompositor_022` is retrieved; actual Cleanup completes; provider configuration resets and the real Apple resource host destroys successfully. The fixture exits 0 without panic. Frame waits, texture acquisitions and copies remain zero: this establishes native frontend/provider initialization and clean lifecycle only, not a stereo frame, Windows guest ABI, AOT guest entry, physical headset/controller behavior or Skyrim. Production Apple initialization remains unavailable without the explicit test feature.

The frontend runner now uses a worker-owned serialized stable Cargo/source cache for dependency reuse. Every run still captures a complete immutable source manifest/snapshot, verifies staged bytes, and copies its final xrizer dylib and native executable into the unique evidence directory before execution. Previous artifacts are never mutated. Both builds are offline/locked and use only the repository-local toolchain.

### xrizer-frontend-2dahPs

| Artifact | SHA-256 |
| --- | --- |
| `source-manifest.json` | `41d9c4f4ad88504f1d4b97e1f640fee1bbeacb8ef47d14c892eb1631f8b02401` |
| `xrizer-frontend` | `16d7bc64e64666e61c4ae76e757edc81ba71e019934b11ffb7bd67f33de6ae46` |
| `target/aarch64-apple-darwin/debug/libxrizer.dylib` | `4a8729e813dc9ff045872849391422061fe28b131ef2d855ba0a72b1d8210549` |
| `run.log` | `952c8525c683c66c8b53d983bcb70b4950f0b593a6004de70e87372dcc939c07` |
| `run.status` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `environment.txt` | `d321a8034aa43ff4eb0e9ecf4b44d6911f84ac9d0868ea7f8a36ff2800a978e2` |

### xrizer-frontend-bwwk2x

| Artifact | SHA-256 |
| --- | --- |
| `source-manifest.json` | `d064ec06e081cfa9633adc19b7eee97d3e709773369060e4a779be63075590a0` |
| `xrizer-frontend` | `68bce51f68492d91b6b0cdad11cae23c147d5697201251dcad4eca0514bac17a` |
| `libxrizer.dylib` | `29e9da72b8992d8b296d138d0d71bf326455c56252ed983204e7c38646e04b61` |
| `run.log` | `3beead640e29dc80ed37e9bd634ee18fe09fb6012253ac4cb90dec1019b06775` |
| `run.status` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `environment.txt` | `2ea76be7c11bd631134369b0a0795cebdb0244dd9f1ae17c5c3c1470af4869bc` |


## Actual native xrizer two-eye Metal submission

Snapshot `xrizer-frontend-Xx6XXs` executes the real xrizer frontend/compositor/Metal backend and selected provider, using the versioned `openvr-1.0.17.h` native C++ System019/Compositor022 interfaces. Two explicit `WaitGetPoses(nullptr,0,nullptr,0)` calls latch valid injected host samples before the fixture encodes each pair of source GPU writes. The actual source acquire/release bridge retains Metal resource leases, waits for producer completion, copies the requested source crop into the provider array eye, records the committed target writes and waits for real completion. The provider then publishes through the shared host helpers into the actual native queue. No copy/submit success is fabricated.

The bounded parent-reserved GPU run exits 0. Readback checks red/green then blue/yellow pairs, dimensions/crop/color, source frame/pose IDs 101/201 then 102/202, independently expected head/eye transforms and FOV tangents, old-pair retention and compositor repeats. A single real session is traced: create/destroy 1/1, begin/request-exit/end 1/1/1. Source acquire/release counts are 12/12 and four source copies complete. Cleanup, provider reset and Apple host destruction pass. The session is promoted before the first wait rather than restarted after game texture submission.

Scope: native fixture-owned Metal texture tokens, not Windows guest ID3D11Texture handles or AOT guest execution. Pose-array output counts are deliberately zero; no head/controller caller-array, action API, physical tracking, display, headset or game acceptance follows. Known geometry/pixel/resource assertions validate offscreen native integration. The positive result does not establish timeout/copy/release failure behavior; those require separately injected tests.

The reusable fixture-only Metal publication/readback implementation is now `tests/metal_frame_host.inc`, shared with `tests/frame_metal.m`. `test-xrizer-stereo.sh --build-only` selects the stereo native caller through the isolated frontend runner; GPU execution was separately authorized for the exact captured artifact. One earlier C++ compile failed on assigning const CFTypeRef to a mutable lease pointer; an explicit ARC retained bridge fixed it. No GPU run used that failing build.

| Xx6XXs artifact | SHA-256 |
| --- | --- |
| `source-manifest.json` | `e669488d2b509e8804b3b6277d6d44ac383e8621c1f8e6d99dad2695d0ce6bf6` |
| `xrizer-frontend` | `67d340227c7724e9253888fff3241d46e3186bc68b3eb32bd7dc13063c9dca72` |
| `libxrizer.dylib` | `190d2e16be9acedebd5b0a788229e1a9505b279ce15ee9d0d7fb46423915856d` |
| `run.log` | `1ce35ebbb50ac130cf2ddd05da726da8bac4101b6b56848c3a3ab821ee57ce58` |
| `run.status` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `environment.txt` | `3d25ba750a07c7865acdab8f618beabbad58b1b09aeb967a24c142d3b5834afc` |

## Actual native stereo failure retry controls

Snapshot `xrizer-frontend-LaE3DK`, mode `failure-retries`, includes the current source-host writer-epoch fix and xrizer success-only raw Apple swapchain dispatch. The parent-reserved bounded GPU run exits 0. It injects four failures through real native call paths, then recovers each by the explicit supported retry:

- Raw image wait returns `XR_TIMEOUT_EXPIRED` once: Submit returns RequestFailed, no copy/pair occurs, and the next attempt waits on the same acquisition rather than acquiring another image.
- Source copy callback fails before submitting target GPU work: Submit returns InvalidTexture; same-eye retry then performs the actual copy.
- Producer completion callback refuses right-eye release once: Submit returns RequestFailed; PostPresentHandoff publishes nothing; retrying SubmitRight retries release only, with no second eye copy.
- End-frame host publication refuses once: no queue pair is available and the frame ticket remains outstanding; retrying PostPresentHandoff publishes the same completed frame.

Assertions establish no publication before recovery, exact source/frame/pose/FOV/pixel results for two accepted pairs, retained/repeated frame safety, two total image acquisitions / three waits / three release calls, four completed source GPU copies, source leases 16/16 and single-session begin/exit/end 1/1/1. Teardown succeeds **after recovery and reader drain**. Abandoned-image cancellation, cleanup while pending, nonzero caller pose arrays, controller APIs, Windows guest ABI/D3D11 sources and physical presentation remain unverified. Positive-only Xx6XXs did not establish these retry controls.

| LaE3DK artifact | SHA-256 |
| --- | --- |
| `source-manifest.json` | `cb187f37f3301c855804968c109d9aa4db9cd9b3bb49de9f9c3a1fe3b87e9491` |
| `xrizer-frontend` | `35d358c509b116261cecc43051d3ef061cea32b338079d0f876fc4728228ad98` |
| `libxrizer.dylib` | `6962a6fbcc80e07879cdba87e804d12e52e2069a559bb3909aea5c0b930050ba` |
| `run.log` | `ff9d9909df867a04c0000ba09bee4ed6dc97ceb2485d0f81118df469644bd79a` |
| `run.status` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `environment.txt` | `5666f335c085e820bb36797f113ab5491b06e6fed2b6685f4ce84ba45e05d70a` |

Source `third_party/xrizer/upstream/src/compositor.rs`: `0c1ef677b7b18812ee9a2978bb910b301d7261575d6689618d9202c4af8226b0`.

Source `third_party/xrizer/upstream/src/openxr_data.rs`: `e3db86f76cb35cfe64741d1a0d673535d4691ab31add0d363391c135e8ce3d04`.

Source `third_party/klepton_openxr/src/core.c`: `ab5f6d26f07487cf4291ae5134d2b2aceee108f7384ce37cd34968f6526ccb22`.

Source `third_party/klepton_openxr/src/metal_host.m`: `7cfe011c5db866da56fdc4f8d348c364169916444e5c8ce778d4f5a28755d161`.

Source `third_party/klepton_openxr/tests/xrizer_stereo.m`: `4448de91e7315ebf5ae83066199038535d4328057c1809e61d778a482ac09761`.

Source `third_party/klepton_openxr/tests/metal_frame_host.inc`: `8925aa977e73765b9dfcbb9df457c6ddd254e45c97557738be35cbeb47ac9fc1`.

## Nonzero caller-pose failure and runner correction

Snapshot `xrizer-frontend-CPAE5M` calls the exact native Compositor022 `WaitGetPoses(&pose,1,nullptr,0)` in an isolated bounded child, before any source producer commands or Submit. It fails with SIGABRT (child return -6). The source-matched backtrace reaches `Input::new` → `PoseData::new` → grip-pose `xrCreateAction`, whose provider returns `ERROR_FUNCTION_UNSUPPORTED`; an xrizer `unwrap` at `input.rs:1689` aborts. The full backtrace is preserved in run.log. This is a real unsupported required call and unsafe error propagation, not a successful or normal API refusal. Zero-array stereo acceptance does not cover it. No GPU source copy, controller or physical tracking is credited.

| CPAE5M artifact | SHA-256 |
| --- | --- |
| `source-manifest.json` | `165e7b4621747f28a9f8df9ce39f95e660ef23119c5a2f26be381e84e7356bd6` |
| `xrizer-frontend` | `1d3856df0c3afeabd84faae2b4a368549b39b34161413bc7d971d70564028578` |
| `libxrizer.dylib` | `a4a9f5a0d1aee0a780f22848b5276828272548f1d7be9dbf903a78e7b66755f1` |
| `run.log` | `de3faeea0dcfbf8cfc2ec337b4b18a8572ab528146aeedf68e9f9724d1dc03f7` |
| `run.status` | `d7b906a85360766ca93a7f2a3391ddc205bb248d2ec6e045769e67889fc1ebd5` |
| `environment.txt` | `8413f8e26db15c1fd2367d31d9c95e3bf2f8fbbd31016b78e1d8cd9312834f24` |

Harness correction: the runner exports repository-local XDG state/config paths, but manual exact-artifact subprocesses after `--build-only` did not inherit those child-shell exports. Xx6XXs, LaE3DK and CPAE5M therefore allowed xrizer to route its ordinary logger to the default `~/.local/state/xrizer` location. Their separately captured stdout/stderr, binaries and source manifests remain as recorded, but log confinement was not satisfied. No game files were touched; external state was not cleaned or modified afterwards. Both owned xrizer fixture entry points now require explicit `XDG_STATE_HOME` and `XDG_CONFIG_HOME` before loading xrizer, so a missing manual environment fails early. Future runs must use the runner directly or explicitly pass per-snapshot XDG directories in the child environment.

## Honest nonzero-pose guard after the observed abort

Terra added a temporary owned-Apple-test guard while provider pose-action lifecycle remains absent. Snapshot `xrizer-frontend-7rjgkc` verifies the actual native one-pose WaitGetPoses returns RequestFailed (1) before a frame ticket is acquired; the output remains disconnected/invalid. The fixture then performs actual Cleanup and provider/resource-host teardown. It exits 0 with no GPU producer commands or Submit. This accepts safe refusal only; pose-array, action and controller support remain unavailable. The earlier CPAE5M abort remains the recorded pre-guard failure.

This execution explicitly supplies per-snapshot XDG directories in its child environment and records them in `execution-environment.json`; `state/xrizer/xrizer.txt` is present inside the evidence directory. Both fixture entry points now reject a missing XDG environment before loading xrizer.

| 7rjgkc artifact | SHA-256 |
| --- | --- |
| `source-manifest.json` | `3754ded16cfed149ec0d0a5902a394e92c0dda5b437b4e23d78c7caf13906846` |
| `xrizer-frontend` | `2895c795f93892fc8bf696d6eafc48f2d6dc6c0c60adbd9e1e7b89b23d054e65` |
| `libxrizer.dylib` | `bde22ed0e500d5fc5d752b9a0e4f76f58253ed4359b8c7d3951e43888c9c353c` |
| `run.log` | `e92f8f2dd52df7fca08b9387d2dd6fad1894283c16094db0f6b858492a273880` |
| `run.status` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `execution-environment.json` | `48a743b3028a7ad18a635651f0789259ce1e8564d5d4c6f2fdb8f3acb61016e6` |
| `state/xrizer/xrizer.txt` | `dbac82372587273eff157f1508aacbaf313dc8951da532b999d0b470088d97c1` |

## Refreshed retry proof with captured local log environment

Snapshot `xrizer-frontend-ZPnd9A` reruns the actual native `failure-retries` stereo path against source with full source-dimension/format revalidation, success-only raw swapchain dispatch, and the current completed-writer epoch reset. Both runner and bounded child exit 0. The four injected failures and retry-to-success assertions pass again: two accepted pairs, two waits, two publications, four completed source copies, balanced source leases 16/16, and single-session begin/request-exit/end 1/1/1. Exact GPU pixels, queue frame/pose IDs, independently expected transforms/FOV, retained old-eye resources and repeat behavior pass. Provider POSE_INPUT action-identity code is compiled into this snapshot but is not exercised by its zero-pose stereo calls.

This execution uses the runner directly. It captures actual `XDG_STATE_HOME` and `XDG_CONFIG_HOME` in `execution-environment.json`, verifies both resolve inside this immutable run directory before executing, and preserves the real local xrizer log at `state/xrizer/xrizer.txt`. This is the corrected confined execution proof; earlier manual-run confinement failures remain documented above. The claim remains native owned texture tokens, injected tracking, zero caller pose-array counts, and retry-to-success only. Windows guest ABI/D3D11 sources, pose/action/controller support, abandoned-image cleanup, headset presentation and Skyrim remain unverified.

| ZPnd9A artifact | SHA-256 |
| --- | --- |
| `source-manifest.json` | `58b9f0fba533a916ea115c4fd27627694097ea05b49a65fd572af690d2c77963` |
| `xrizer-frontend` | `371f8f91a14a8abac023fb8c0174e2eb89555fb6c15674467054bf2afb8d5f09` |
| `libxrizer.dylib` | `bde22ed0e500d5fc5d752b9a0e4f76f58253ed4359b8c7d3951e43888c9c353c` |
| `run.log` | `6b020bb47c932932fa1d7aa251f037ad6c8fd890431fefdb82535a705598e0a9` |
| `run.status` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `runner.status` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `environment.txt` | `5666f335c085e820bb36797f113ab5491b06e6fed2b6685f4ce84ba45e05d70a` |
| `execution-environment.json` | `6477c65c764cf58d1b6817d9abf8071bf6e44f1bbe7961a8d87c24d9ee295d50` |
| `state/xrizer/xrizer.txt` | `0084bffa5bf7ef209e60f07c69e7b9c4f2b51788abdb68687668b1a4ce229e9e` |

Selected snapshotted production sources:

- `third_party/xrizer/upstream/src/compositor.rs`: `ba1f5f193e90f8114ed0ad825282a444f4a9f7cb37d525a90b2085a505fcb396`
- `third_party/xrizer/upstream/src/openxr_data.rs`: `e3db86f76cb35cfe64741d1a0d673535d4691ab31add0d363391c135e8ce3d04`
- `third_party/xrizer/upstream/src/graphics_backends/metal.rs`: `8bcc4587e27e44b31c26b6dd19933aa73db2ba792583d9d03f93e0662a839a04`
- `third_party/klepton_openxr/src/core.c`: `4473056b06bc510f058105a63d8eef4cdc446f5b06cc00ef5827ff292342ba25`
- `third_party/klepton_openxr/src/metal_host.m`: `7cfe011c5db866da56fdc4f8d348c364169916444e5c8ce778d4f5a28755d161`
