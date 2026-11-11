#!/usr/bin/env python3
"""The Skyrim harness (tools/vxrt_run.py): profile, log parsing, derivation/validation rules and refusals, on synthetic data."""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
import vxrt_games
import vxrt_run


def check(condition, message):
    if not condition:
        raise SystemExit("vxrt run test failed: " + message)


# the tracked profile is valid and has the scenarios the launcher flags map to
profile = vxrt_games.by_key("skyrim")
check(profile and profile["appid"] == "611670" and not vxrt_games.problems(profile, "611670.json"), "games/611670.json invalid")
check(profile["scenarios"]["helgen"]["helgen"] is True and not profile["scenarios"]["boot"]["helgen"], "scenarios do not map to --helgen")
check(vxrt_games.problems(dict(profile, scenarios={}), "611670.json"), "empty scenarios accepted")
check(vxrt_games.problems(dict(profile, baselines={"nope": {}}), "611670.json"), "baseline of an unknown scenario accepted")
check(vxrt_games.problems(dict(profile, baselines={"boot": {"fps": 1}}), "611670.json"), "unknown baseline field accepted")

# the launcher command: harness-owned flags, helgen only when the scenario says so, settings as --diag-env
cmd = vxrt_run.launch_command(profile["scenarios"]["helgen"], 180, "/x/native", ["--mods-config", "p/m.json"], {"VXRT_SKYRIM_PRESET": "p2"}, 0)
check(cmd[0].endswith("play_skyrim_dev.sh") and "--helgen" in cmd and "--mute" in cmd and cmd[cmd.index("--out") + 1] == "/x/native", "launch command")
check(cmd[cmd.index("--") + 1:][-4:] == ["--diag-env", "VXRT_SKYRIM_PRESET=p2", "--mods-config", "p/m.json"], "settings/args order")
check("--helgen" not in vxrt_run.launch_command(profile["scenarios"]["boot"], 120, "/x/native", [], {}, 0), "boot scenario sends helgen keys")

# refusals that need no game: untunable setting, harness-owned argument
checks = {c["code"]: c for c in vxrt_run.preconditions(profile, None, ["--out", "/tmp/x"], {"VERANTYX_BITRATE_MBPS": "1"})}
check(not checks["settings_allowed"]["ok"] and not checks["args_allowed"]["ok"], "untunable setting or owned argument accepted")
check(not checks["game_installed"]["ok"], "missing game not refused")

# concurrency: overlapping harness runs (separate runs/<id>) are allowed and counted; a hand-started play session is the user's; same root conflicts
def rec(pid, run):
    return {"pid": pid, "owner": "harness", "run": run, "root": run + "/root"}
def session_survey(concurrent, conflicts=(), user=()):
    return lambda own, *a, **k: {"user": list(user), "conflicts": list(conflicts), "concurrent": list(concurrent)}
real = (vxrt_run.sessions.survey, vxrt_run.active_skyrim_runs)
try:
    vxrt_run.active_skyrim_runs = lambda: [(11, "x"), (12, "y")]
    vxrt_run.sessions.survey = session_survey([rec(11, "/r/runs/A/native"), rec(12, "/r/runs/B/native"), rec(13, "/r/runs/C/native")])
    others, play = vxrt_run.other_skyrim_sessions(["/r/runs/D"])
    check([r["pid"] for r in others] == [11, 12] and not play, "concurrent harness runs must be allowed and counted (non-Skyrim runtimes not counted)")
    check(vxrt_run.concurrent_skyrim_count(["/r/runs/D"]) == 2, "concurrent count")
    vxrt_run.sessions.survey = session_survey([rec(11, "/r/build/play-101010")])
    check([r["pid"] for r in vxrt_run.other_skyrim_sessions(["/r/runs/D"])[1]] == [11], "hand-started play_skyrim_dev session must count as the user playing")
    c = {c["code"]: c for c in vxrt_run.preconditions(profile, {"folder": "/g", "exe": "/g/SkyrimVR.exe"}, [], {}, "/r/runs/D")}
    check(not c["no_user_play_session"]["ok"], "play session not refused by preconditions")
    vxrt_run.sessions.survey = session_survey([rec(11, "/r/build/worktrees/agent/build/play-101010")])
    check(not vxrt_run.other_skyrim_sessions(["/r/runs/D"])[1], "an agent's worktree launcher run must not count as the user playing")
    vxrt_run.sessions.survey = session_survey([rec(11, "/r/runs/A/native")])
    c = {c["code"]: c for c in vxrt_run.preconditions(profile, {"folder": "/g", "exe": "/g/SkyrimVR.exe"}, [], {}, "/r/runs/D")}
    check(c["no_user_play_session"]["ok"] and c["user_not_playing"]["ok"] and c["run_paths_unshared"]["ok"], "a concurrent harness run refused a run")
finally:
    vxrt_run.sessions.survey, vxrt_run.active_skyrim_runs = real
# sessions module itself: the same root is a conflict, a different one is concurrent, an unmarked default-root runtime is the user's
import vxrt_runtime_sessions as S
def info(root, run):
    return ("/x/vxrt-arm64", ["vxrt-arm64", "SkyrimVR.exe"], {"VXRT_ROOT": root, "VXRT_HARNESS_RUN": run})
procs = lambda: [(21, "vxrt-arm64", "vxrt-arm64 SkyrimVR.exe"), (22, "vxrt-arm64", "vxrt-arm64 SkyrimVR.exe")]
args = {21: info("/r/runs/A/native/root", "/r/runs/A/native"), 22: info("/r/runs/B/native/root", "/r/runs/B/native")}
s = S.survey(["/r/runs/C"], ps=procs, args=lambda pid: args[pid], cwd_of=lambda pid: None, alive_of=lambda pid: True, user_roots=[], checkouts=["/r"])
check(len(s["concurrent"]) == 2 and not s["conflicts"] and not s["user"], "separate run directories must be concurrent")
s = S.survey(["/r/runs/A"], ps=procs, args=lambda pid: args[pid], cwd_of=lambda pid: None, alive_of=lambda pid: True, user_roots=[], checkouts=["/r"])
check(len(s["conflicts"]) == 1 and len(s["concurrent"]) == 1, "the same run directory/root must conflict")
args[21] = ("/x/vxrt-arm64", ["vxrt-arm64", "SkyrimVR.exe"], {})
s = S.survey(["/r/runs/C"], ps=procs, args=lambda pid: args[pid], cwd_of=lambda pid: None, alive_of=lambda pid: True, user_roots=[], checkouts=["/r"])
check(len(s["user"]) == 1, "a runtime on the default root is the user's session")

with tempfile.TemporaryDirectory() as directory:
    log = os.path.join(directory, "startup.log")
    with open(log, "w", encoding="utf-8") as stream:
        stream.write("[vxrt] 22:49:19.456 xrizer dev keyboard: title: VXRuntime dev keyboard | game 60 fresh pairs/s | host 60 Hz | frame avg 16.6 ms\n"
                     "[vxrt] 22:49:29.455 xrizer dev keyboard: title: VXRuntime dev keyboard | game 55 fresh pairs/s | host 55 Hz\n"
                     "[vxrt] 22:49:22.837 xr submit ring: submitted 13200 completed 13199 failed 0 blocked-at-bound 66\n"
                     "[vxrt] 22:49:58.855 xrizer dev host: dump frame 15360 eye 1 1024x1024 mean rgb 63.6 55.5 39.5, 100.0% pixels differ from pixel 0, 90.0% non-black\n"
                     "[vxrt] 22:50:00.000 signal 11 at 0x1234 (address 0x0)\n"
                     "[vxrt] 22:50:01.000 called an unimplemented function: Foo.Bar\n"
                     "[vxrt] 22:50:02.000 ExitProcess(0) from SkyrimVR.exe+0x1\n"
                     "[vxrt other.exe:5] unhandled exception in a helper\n")
    pairs, ring, eye = vxrt_run.log_series(log)
    check(pairs == [60.0, 55.0] and ring == (13200, 13199, 0) and eye == [90.0], "log_series")
    facts = vxrt_run.game_log_facts(log)
    check(facts["signals"] == 1 and facts["unhandled"] == 0 and facts["unimplemented"] == {"Foo.Bar": 1} and facts["exit"].startswith("ExitProcess(0)"), "game_log_facts (helper lines are not the game's)")
    check(facts["first_problem"]["line"] == 5, "first problem")

# derive/level/validate rules over recorded values: absent AOT counters fail, a baseline decides pairs
def evidence(**values):
    ev = vxrt_run.Evidence()
    base = dict(exited_early=False, read_only_inputs_unchanged=True, source_unchanged=True, aot_executed=True, zero_fallback_reported=True,
                              missing_code=[], pairs_per_s_median=58.0, xr_submit_ring={"submitted": 10, "completed": 10, "failed": 0},
                              eye_non_black_percent_median=90.0, native_signals=[], xrizer_panics=[], unhandled_exceptions=0)
    base.update(values)
    for metric, value in base.items():
        ev.observe(metric, value)
    return ev

def claims(ev, base):
    vxrt_run.derive(ev, base, "t")
    return {d["claim"]: d["holds"] for d in ev.derived}

good = claims(evidence(), {"min_pairs_per_s": 30, "non_black": True})
check(all(good.values()) and "pairs_meet_baseline" in good and "frame_not_black" in good, "healthy run should hold every claim")
check(vxrt_run.level(evidence()) == "runs", "level of a healthy run")
check(not claims(evidence(aot_executed=False, zero_fallback_reported=False), {})["aot_zero_fallback"], "missing AOT counters must fail, not count as zero")
check(not claims(evidence(pairs_per_s_median=12.0), {"min_pairs_per_s": 30})["pairs_meet_baseline"], "low pairs/s passed a baseline")
check(not claims(evidence(exited_early=True), {})["ran_for_the_whole_scenario"], "early exit")
check(not claims(evidence(native_signals=[{"signal": 11}]), {})["no_crash_signals"], "native signal")
check(vxrt_run.level(evidence(xr_submit_ring={"submitted": 5, "completed": 5, "failed": 1})) == "starts", "failed submits reach 'draws'")
check(vxrt_run.level(evidence(aot_executed=False)) is None, "no AOT, no level")

result = {"game": "skyrim", "scenario": "helgen", "baseline": "x", "observed": evidence().observed, "derived": [], "inferred": [], "level": "starts"}
check(any("level says" in p for p in vxrt_run.validate(result)), "validate should recompute the level")
print("vxrt run: Skyrim profile, launcher command, refusals, log parsing, derivation and level rules: ok")
