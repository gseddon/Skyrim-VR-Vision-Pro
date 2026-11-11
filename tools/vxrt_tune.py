#!/usr/bin/env python3
"""vxrt tune: finds the richest Skyrim setting that holds the dev host's rate on this Mac, by running the game with the
harness (tools/vxrt_run.py: Mac dev host, strict AOT, evidence) up a ladder of settings, cheapest to richest, and
confirming the choice in alternating runs.

    tools/vxrt_tune.py skyrim                   # the profile's tune scenario and ladder (or the default ladder)
    tools/vxrt_tune.py skyrim --plan            # what it would run, and about how long it takes; runs nothing
    tools/vxrt_tune.py skyrim --max-runs 6 --apply   # write the choice into games/611670.json ("tuned", this Mac)
    tools/vxrt_tune.py --show skyrim            # the launch command tuned for this Mac, if there is one

A candidate holds when every run of it is healthy (strict AOT with zero fallback, frames submitted, the whole scenario,
no crash signals) and the median of its runs' pairs_per_s_median is at least 95 % of the host rate (60). The tuner
climbs while candidates hold; the highest one that holds is run again, alternating with the next one up when that one
came within 10 % (B A A B), until each has --repeats runs; a candidate that stops holding sends it one step down. It
stops when the choice is confirmed, at --max-runs, or when the harness refuses a run (the user started playing,
another Skyrim run is active, ...): it never works around a refusal. Everything is written to runs/<tune id>/tune.json
(each run's id and the observation the rate comes from), sealed into runs/ledger.jsonl.

The settings are Skyrim ini overrides and the dev host's submit knobs (TUNABLES in tools/vxrt_run.py). Removed with the
streaming path: render-scale and quality presets, display Hz, encoder and bitrate settings (nothing natively
corresponds). What it does not know: how the picture looks and feels in a headset (the harness has none) and picture
quality beyond the settings named; the 60 Hz host rate is the dev window's, not a headset's.

Exit status: 0 a confirmed choice, 1 none holds, 2 not confirmed (runs ran out), 3 refused, 4 error.
"""
import argparse, json, os, statistics, subprocess, sys, time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vxrt_doctor as doctor                                    # noqa: E402
import vxrt_games as profiles_db                                # noqa: E402
import vxrt_ledger as ledger                                    # noqa: E402

REPO = doctor.REPO
HOST_HZ = 60                            # the dev host's display rate (its window title: "host 60 Hz")
HOLD, NEAR = 0.95, 0.90                 # of the host rate: holds; close enough to deserve a second look
DEFAULT_LADDER = [                      # cheapest to richest (research/2026-11-10-skyrim-vr-performance-settings.md; unmeasured here)
    {"settings": {"VXRT_SKYRIM_PRESET": "p2"}},
    {"settings": {}},
    {"settings": {"VXRT_INI_SET": "Display.iShadowMapResolution=2048;Display.fShadowDistance=8000"}},
]
OVERHEAD_S = 90                         # a run's start and stop around its scenario (hashing the inputs, the launch)

# ---- candidates -------------------------------------------------------------------------------------------------------------
def label(c):
    extra = " ".join(f"{k}={v}" for k, v in sorted(c.get("settings", {}).items()))
    return extra or "dev-host defaults"

def ladder_for(profile):
    """The profile's ladder (games/<appid>.json "tune"), cheapest first, or the default."""
    return (profile or {}).get("tune", {}).get("ladder") or DEFAULT_LADDER

# ---- what a run says ----------------------------------------------------------------------------------------------------------
def run_facts(result):
    """{run_id, status, fps (pairs/s), fps_ref, healthy, why} from a harness result. Healthy: every derived claim but the pairs
    baseline holds (the baseline belongs to another setting)."""
    obs = {o["metric"]: o for o in result.get("observed", [])}
    fps = obs.get("pairs_per_s_median", {}).get("value")
    bad = [d["claim"] for d in result.get("derived", []) if d["claim"] != "pairs_meet_baseline" and not d["holds"]]
    return {"run_id": result["run_id"], "status": result["status"], "fps": fps, "fps_ref": obs.get("pairs_per_s_median", {}).get("id"),
            "healthy": result["status"] != "refused" and not bad and fps is not None, "why": bad or ([] if fps is not None else ["no fps"])}

def verdict(c, runs):
    """untested / holds / fails, and the median fps of the candidate's runs."""
    if not runs:
        return "untested", None
    fpss = [r["fps"] for r in runs if r["fps"] is not None]
    med = statistics.median(fpss) if fpss else None
    ok = all(r["healthy"] for r in runs) and med is not None and med >= HOLD * HOST_HZ
    return ("holds" if ok else "fails"), med

def near(c, runs):
    v, med = verdict(c, runs)
    return v == "fails" and all(r["healthy"] for r in runs) and med is not None and med >= NEAR * HOST_HZ

def next_step(ladder, runs, repeats):
    """The index of the candidate to run next, or None when done. runs: {index: [run facts]}."""
    held = [i for i in range(len(ladder)) if verdict(ladder[i], runs.get(i))[0] == "holds"]
    if not held:
        r0 = runs.get(0, [])
        if not r0 or (near(ladder[0], r0) and len(r0) < repeats):
            return 0
        return None
    h = held[-1]
    up = h + 1
    if up < len(ladder) and not runs.get(up):
        return up                                            # climb
    if len(runs[h]) < repeats:
        return h                                             # confirm the choice
    if up < len(ladder) and near(ladder[up], runs[up]) and len(runs[up]) < repeats:
        return up                                            # one more look at the one just out of reach
    return None

def choice(ladder, runs, repeats):
    """(index or None, confirmed)."""
    held = [i for i in range(len(ladder)) if verdict(ladder[i], runs.get(i))[0] == "holds"]
    if not held:
        return None, True
    h = held[-1]
    return h, len(runs[h]) >= repeats

def command_for(key, c):
    """The player's launch command for a candidate (the dev launcher; settings as renderer/ini overrides)."""
    flags = " ".join(f"--diag-env {k}={json.dumps(v) if ' ' in v or ';' in v else v}" for k, v in sorted(c.get("settings", {}).items()))
    return f'cd "{REPO}" && tools/play_skyrim_dev.sh --no-build' + (f" -- {flags}" if flags else "")

def machine_key(mi=None):
    mi = mi or doctor.machine_info()
    return f"{mi['chip']}, {mi['gpu_cores']}-core GPU"

# ---- the tune -------------------------------------------------------------------------------------------------------------------
def tune(game, scenario=None, max_runs=8, repeats=2, seconds=None, runner=None, tune_id=None, say=print, write=True):
    """Runs the ladder; returns the record (also written to runs/<tune id>/tune.json after every run)."""
    import vxrt_run
    key, profile, inst = vxrt_run.resolve(game)
    if not profile:
        raise ValueError(f"{game}: unknown game (tools/vxrt_run.py --list)")
    scenario = scenario or profile.get("tune", {}).get("scenario") or profile["default_scenario"]
    ladder = ladder_for(profile)
    runner = runner or (lambda c: vxrt_run.run(key, scenario, seconds, settings=c.get("settings"), quiet=True))
    tune_id = tune_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-tune-{key}"
    path = os.path.join(REPO, "runs", tune_id, "tune.json")
    rec = {"tune_id": tune_id, "game": key, "appid": profile["appid"], "scenario": scenario, "machine": machine_key(),
           "rule": {"holds": f"every run healthy and median pairs_per_s_median >= {HOLD} x host rate ({HOST_HZ})", "near": f">= {NEAR} x host rate",
                    "repeats": repeats, "max_runs": max_runs},
           "ladder": [{"candidate": label(c), **c} for c in ladder],
           "runs": [], "status": "running", "started": datetime.now(timezone.utc).isoformat()}
    runs = {}

    def save():
        if write:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            json.dump(rec, open(path, "w"), ensure_ascii=False, indent=2)

    save()
    while len(rec["runs"]) < max_runs:
        i = next_step(ladder, runs, repeats)
        if i is None:
            break
        say(f"tune {tune_id}: run {len(rec['runs']) + 1}/{max_runs}: {label(ladder[i])}")
        try:
            result = runner(ladder[i])
        except Exception as e:                                # (the harness itself failed)
            rec["status"], rec["error"] = "error", str(e); save(); return rec
        f = run_facts(result)
        rec["runs"].append({"candidate": i, **f})
        save()
        if f["status"] == "refused":
            rec["status"], rec["refused"] = "refused", result.get("refused", [])
            say(f"tune {tune_id}: refused ({', '.join(rec['refused'])}); stopped")
            break
        runs.setdefault(i, []).append(f)
        v, med = verdict(ladder[i], runs[i])
        say(f"  {f['run_id']}: fps {f['fps']} ({'healthy' if f['healthy'] else 'not healthy: ' + ', '.join(f['why'])}) -> {v} (median {med})")

    rec["candidates"] = []
    for i, c in enumerate(ladder):
        v, med = verdict(c, runs.get(i))
        rec["candidates"].append({"candidate": label(c), "verdict": v, "median_fps": med, "runs": [r["run_id"] for r in runs.get(i, [])]})
    if rec["status"] == "running" and not rec["runs"]:
        rec["status"] = "no_runs"                             # (--max-runs 0)
    if rec["status"] == "running":
        best, confirmed = choice(ladder, runs, repeats)
        if best is None:
            rec["status"] = "none_holds"
            fastest = max(((i, verdict(ladder[i], runs[i])[1]) for i in runs if all(r["healthy"] for r in runs[i])), key=lambda x: x[1] or 0, default=None)
            if fastest:                                       # (not a choice: what came closest)
                rec["closest"] = {"candidate": label(ladder[fastest[0]]), "median_fps": fastest[1], "target_fps": HOLD * HOST_HZ}
        else:
            c = ladder[best]
            rec["status"] = "confirmed" if confirmed else "unconfirmed"
            rec["choice"] = {"candidate": label(c), "settings": c.get("settings", {}), "host_hz": HOST_HZ, "median_fps": verdict(c, runs[best])[1],
                             "runs": [{"run_id": r["run_id"], "fps": r["fps"], "observation": r["fps_ref"]} for r in runs[best]],
                             "command": command_for(key, c)}
    rec["unknown"] = ["the picture and its smoothness in a headset (the harness has none; the 60 Hz is the Mac dev window's)",
                      "picture quality beyond the settings named", "other scenes of the game than the scenario measured"]
    rec["ended"] = datetime.now(timezone.utc).isoformat()
    save()
    if write:
        row = ledger.append({"tune_id": tune_id, "game": key, "status": rec["status"], "runs": [r["run_id"] for r in rec["runs"]],
                             "result": os.path.relpath(path, REPO), "result_sha256": ledger.sha256_file(path)})
        rec["ledger"] = {"row": row["i"], "sha": row["sha"]}    # (returned only: the sealed file stays as sealed)
    return rec

def apply(rec):
    """Writes a confirmed choice into the game's profile under "tuned" for this machine."""
    if rec.get("status") != "confirmed":
        raise ValueError("only a confirmed choice is written to the profile")
    f = os.path.join(REPO, "games", f"{rec['appid']}.json")
    p = json.load(open(f))
    ch = rec["choice"]
    p.setdefault("tuned", {})[rec["machine"]] = {
        "settings": ch["settings"], "scenario": rec["scenario"], "median_fps": ch["median_fps"],
        "host_hz": ch["host_hz"], "checked": rec["ended"][:10],
        "source": f"tools/vxrt_tune.py {rec['tune_id']} (runs {', '.join(r['run_id'] for r in ch['runs'])})"}
    problems = profiles_db.problems(p, f)
    if problems:
        raise ValueError("; ".join(problems))
    open(f, "w").write(json.dumps(p, indent=2, ensure_ascii=False) + "\n")
    return f

def tuned_for(game, machine=None):
    """(profile key, the "tuned" entry for this machine) or (key, None)."""
    p = profiles_db.by_key(str(game))
    if not p:
        return game, None
    return p["key"], p.get("tuned", {}).get(machine or machine_key())

# ---- a self-test of the climbing and choosing (make -C VXRuntime check) ----------------------------------------------------------
def selftest():
    def fake(fps_by_quality, healthy=True):
        n = [0]
        def runner(c):
            n[0] += 1
            fps = fps_by_quality[label(c)]
            fps = fps.pop(0) if isinstance(fps, list) else fps
            return {"run_id": f"r{n[0]}", "status": "no_baseline", "observed": [{"id": "o1", "metric": "pairs_per_s_median", "value": fps}],
                    "derived": [{"claim": "frames_submitted", "holds": healthy}]}
        return runner
    ladder = ladder_for(None)
    L = [label(c) for c in ladder]
    def go(fps, **kw):
        import vxrt_run
        real = vxrt_run.resolve
        vxrt_run.resolve = lambda g: ("t", {"appid": "1", "default_scenario": "s", "key": "t"}, None)
        try:
            return tune("t", runner=fake(fps, **{k: v for k, v in kw.items() if k == "healthy"}), say=lambda *a: None, write=False,
                        **{k: v for k, v in kw.items() if k != "healthy"})
        finally:
            vxrt_run.resolve = real
    checks = []
    # holds up to the 3rd... (3 rungs): climbs, stops at the top, confirms it (B A then B)
    r = go({L[0]: 60, L[1]: 59, L[2]: 20})
    checks.append(("climbs and confirms", r["status"] == "confirmed" and r["choice"]["candidate"] == L[1] and len(r["runs"]) == 4))
    # the richest just out of reach (55 >= 54): looked at twice, alternating with the choice
    r = go({L[0]: 60, L[1]: 59, L[2]: [55, 55]})
    checks.append(("near one gets a second look", r["choice"]["candidate"] == L[1] and [x["candidate"] for x in r["runs"]][-3:] == [2, 1, 2]))
    # the choice does not hold on its second run: one step down
    r = go({L[0]: 60, L[1]: [59, 40], L[2]: 30})
    checks.append(("steps down", r["choice"]["candidate"] == L[0] and r["status"] == "confirmed"))
    # nothing holds
    r = go({L[0]: 30, L[1]: 20, L[2]: 10})
    checks.append(("none holds", r["status"] == "none_holds" and len(r["runs"]) == 1))
    # unhealthy runs never hold
    r = go({x: 60 for x in L}, healthy=False)
    checks.append(("unhealthy", r["status"] == "none_holds"))
    # run budget
    r = go({x: 60 for x in L}, max_runs=3)
    checks.append(("budget", r["status"] == "unconfirmed" and len(r["runs"]) == 3))
    bad = [n for n, ok in checks if not ok]
    print(f"vxrt tune self-test: {len(checks) - len(bad)}/{len(checks)} -> {'ok' if not bad else 'FAILED: ' + ', '.join(bad)}")
    return not bad

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game", nargs="?", help="skyrim or 611670 (tools/vxrt_run.py --list)")
    ap.add_argument("scenario", nargs="?", help="default: the profile's tune scenario, else its default scenario")
    ap.add_argument("--max-runs", type=int, default=8)
    ap.add_argument("--repeats", type=int, default=2, help="runs the choice needs (default 2)")
    ap.add_argument("--seconds", type=float, help="per run (default: the scenario's)")
    ap.add_argument("--plan", action="store_true", help="show the ladder and the time it may take; run nothing")
    ap.add_argument("--apply", action="store_true", help="write a confirmed choice into the game's profile (\"tuned\", this Mac)")
    ap.add_argument("--show", action="store_true", help="the tuned launch command for this Mac, from the profile")
    ap.add_argument("--id", help="the tune id (default: time and game)")
    ap.add_argument("--json", action="store_true", help="the record on stdout")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(0 if selftest() else 1)
    if not a.game:
        ap.error("which game? (tools/vxrt_run.py --list)")
    if a.show:
        key, t = tuned_for(a.game)
        if not t:
            sys.exit(f"{a.game}: not tuned for {machine_key()} yet (tools/vxrt_tune.py {a.game})")
        print(command_for(key, t)); print(f"# {t['median_fps']} pairs/s; {t['source']}", file=sys.stderr)
        return
    p = profiles_db.by_key(a.game) or next((x for x in profiles_db.load_all().values() if x["appid"] == a.game), None)
    if a.plan:
        if not p:
            sys.exit(f"{a.game}: no profile")
        sc = a.scenario or p.get("tune", {}).get("scenario") or p["default_scenario"]
        secs = a.seconds or p["scenarios"][sc]["seconds"]
        print(f"{p['name']}, scenario {sc}: up to {a.max_runs} runs of about {round((secs + OVERHEAD_S) / 60, 1)} min "
              f"(at most {round(a.max_runs * (secs + OVERHEAD_S) / 60)} min); the ladder:")
        for c in ladder_for(p):
            print(f"  {label(c)}  target {HOLD * HOST_HZ:.0f} fps")
        return
    try:
        rec = tune(a.game, a.scenario, a.max_runs, a.repeats, a.seconds, tune_id=a.id, say=(lambda *x: print(*x, file=sys.stderr)))
    except ValueError as e:
        sys.exit(str(e))
    if a.apply and rec["status"] == "confirmed":
        print(f"written: {os.path.relpath(apply(rec), REPO)}", file=sys.stderr)
    if a.json:
        print(json.dumps(rec, ensure_ascii=False, indent=2))
    else:
        for c in rec.get("candidates", []):
            print(f"  {c['candidate']:42} {c['verdict']:9} median {c['median_fps']}  runs {', '.join(c['runs'])}")
        print(f"{rec['tune_id']}: {rec['status']}" + (f" -> {rec['choice']['candidate']}\n  {rec['choice']['command']}" if rec.get("choice") else ""))
        print(f"  record: runs/{rec['tune_id']}/tune.json")
    sys.exit({"confirmed": 0, "none_holds": 1, "unconfirmed": 2, "refused": 3}.get(rec["status"], 4))

if __name__ == "__main__":
    main()
