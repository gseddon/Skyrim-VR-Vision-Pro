---
name: vxrt-tune-game
description: Tune Skyrim VR on VXRuntime's Mac dev host for this Mac — settings only, measured with the harness in alternating runs, reported with evidence. Use when asked to optimize, raise the rate, or pick the best Skyrim settings.
---

# Tuning Skyrim VR on VXRuntime (settings only)

Read AGENTS.md first. A tune changes settings, never the runtime's code. Every number here is the Mac dev host's
(60 Hz window, synthetic head), not a headset's.

## Start with the auto-tuner

`tools/vxrt_tune.py skyrim` (MCP: `tune_game`, then `read_tune` now and then; `--plan` shows the ladder and the time
first). It runs the harness up the profile's ladder (`games/611670.json` `tune.ladder`: the p2 preset, the defaults,
bigger shadows; cheapest first), stops climbing where a candidate no longer holds 95 % of the host rate (60 fresh
pairs/s) with healthy runs, and confirms the richest one that holds in alternating runs. A confirmed choice goes into
the profile's `tuned` entry for this Mac with `--apply`. It stops on a refusal (the user is playing, or other Skyrim runs are active: it refuses its own measurement runs
then, because concurrent timing is noisy): report that and do not restart it while they play.

## Measure by hand (settings outside the ladder)

- `tools/vxrt_run.py skyrim [scenario] --set NAME=VALUE ...` (MCP: `run_game` with `settings`). Only the tunables in
  `tools/vxrt_run.py` are accepted (`VXRT_SKYRIM_PRESET`, `VXRT_INI_SET`, `VXRT_XR_SUBMIT_INFLIGHT`,
  `VXRT_XR_SYNC_SUBMIT`, `VXRT_FLUSH_DRAWS`, `VXRT_STATS`); others are refused (`settings_allowed`).
- `pairs_per_s_median` is over the last part of the run (after loading), from the dev host's fresh producer pairs.
  `gpu_utilization_median` tells GPU-bound (>= 90 %) from paced or CPU-bound (< 60 %).
- Use the scenario that matters: `boot` is the menu; `helgen` reaches the cart intro.
- There is no render-scale, quality-preset or encoder/bitrate setting any more: those belonged to the streaming path.

## Compare fairly

- One run per setting is not a comparison: run A B B A (or more) and compare medians (`compare_runs`).
  Differences of a few pairs/s are noise unless they repeat.
- Check `uptime`/`top` first: other programs change GPU numbers. Never measure while compiling or while other Skyrim runs are going (`concurrent_skyrim_runs` > 0 marks a run noisy; `compare_runs` lists such runs under `noisy_runs`).

## Report

A table: setting -> pairs/s (run ids, observation ids), GPU %. The best combination as a launch command
(`tools/play_skyrim_dev.sh -- --diag-env NAME=VALUE`). Mark suspicions (`inferred`, i#) as such, and list what was
not measured (frame pacing, a real headset, audio, other scenes).
