---
name: vxrt-support-game
description: Make Skyrim VR run on VXRuntime's Mac dev host (strict AOT, xrizer) — measure with the harness, find what stops it, implement the missing behaviour, prove it with a run. Use when asked to make the game run, or when it crashes, exits, falls back to the translator or draws nothing.
---

# Making Skyrim VR run on VXRuntime

Read AGENTS.md first; its rules always apply (no DRM or anti-cheat work, game files untouched, commit only what a
run shows). The harness runs the actual game through `tools/play_skyrim_dev.sh` (Mac, strict AOT, xrizer dev host,
keyboard dev controllers, muted, saves isolated per run). A result is a dev-host result: never a headset claim and
never "playable".

## The loop

1. **Measure first.** `tools/vxrt_run.py skyrim [boot|helgen]` (MCP: `run_game`). It refuses unfair runs with a typed
   reason (`user_not_playing`, `no_other_skyrim_run`, `private_inputs`, `game_installed`, `settings_allowed`,
   `args_allowed`): report the reason and stop; never stop another session (wait for it). Use `--check` first.
2. **Find the first blocker** in the result, in this order: `first_problem` (with its log line), `native_signals`,
   `unhandled_exceptions`, `unimplemented_calls`, `xrizer_panics`, `xrizer_bridge_stops`, `missing_code` and
   `aot_summaries` (fallbacks or missing addresses: strict AOT acceptance needs real AOT entries and zero fallback;
   absent counters are a failure, not zero), then `xr_submit_ring` (nothing submitted) and
   `eye_non_black_percent_median` (frames submitted but black). Read around it: the evidence is in
   `runs/<run_id>/native/startup.log` (MCP `read_log` with `file: "native/startup.log"`, `pattern`).
3. **Fix it where it belongs** (AGENTS.md and VXRuntime/RECOMP.md), the way Windows behaves (return values, last
   error, reference counts). Add a test in `VXRuntime/tests` when it is not trivial; `make -C VXRuntime check`.
4. **Measure again** and compare (`compare_runs`). Then `make -C VXRuntime vr-check` so the profile's baselines hold.
   Report with run ids and observation ids; say what is still unknown.
5. **Record it** in `games/611670.json`: status, known issues, a baseline only with a run id behind it. **Stuck?**
   After three attempts without progress, `tools/vxrt_issue.py draft` (MCP `prepare_issue`) with what you tried; show
   the user the draft and stop (only they post it).

`vxrt_doctor` / `analyze_game` lists functions the executable imports that vxrt lacks: a static list. Most are never
called; implement what a run shows being called.

## Finding out more (there is no debugger on the accepted path)

- **Who calls what:** `--trace-calls N` (MCP `trace_calls`) logs the first N calls of every runtime function with
  arguments and the return address (`image+offset`); it costs about 20 % CPU, so do not take timings from such a run.
  The last calls before a crash are usually the answer.
- **Native code at an offset:** `xcrun llvm-objdump -d --start-address=0x<imagebase+rva> --stop-address=... <dll>`
  (image base: `xcrun llvm-objdump -p`). Crash reports print `image+0xRVA` frames.
- **Where a message comes from:** find the string's address in `.rdata`, then the `lea reg, [rip+X]` that loads it
  in `.text` (search the disassembly for the address).
- **Eye images:** the run keeps raw eye files under `runs/<run_id>/native/eyes` (every 3000th frame); the log has
  statistics for every 30th frame. They are game-derived and private: never commit them.
- **abort() and stack overflows** print a backtrace naming the program's frames.

## Things to keep in mind

- Only one Skyrim run at a time on this Mac: the user's session or another agent's run makes the harness refuse.
- Fresh producer pairs/s (`pairs_per_s_median`) are not compositor repeats; the host window runs at 60 Hz.
- Streaming, SteamVR, Alyx and the other Windows games of the old harness are gone; do not look for their launchers.
