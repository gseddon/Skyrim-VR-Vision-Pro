#!/usr/bin/env python3
"""vxrt run: runs Skyrim VR on this Mac the way the dev launcher does (tools/play_skyrim_dev.sh: strict AOT, xrizer dev
host, seeded prefs, keyboard dev controllers) for a bounded scenario, measures it, and writes what it saw as evidence:
runs/<run id>/result.json, sealed into runs/ledger.jsonl. The launcher starts tools/vxrt_native_startup.py, whose own
evidence (runs/<run id>/native/) the observations here point at, each with the file and its SHA-256.

    tools/vxrt_run.py skyrim                       # the default scenario (see --list): helgen, 180 s
    tools/vxrt_run.py skyrim boot --seconds 90     # a scenario, shorter
    tools/vxrt_run.py 611670 helgen --json         # by Steam app id; the result on stdout
    tools/vxrt_run.py --list | --check skyrim | --validate runs/<id> | --verify-ledger | --baselines

Subject of every result: the actual game on the Mac dev host. Not SteamVR, not a headset, no physical tracking or
controllers, no audio (muted), and never "playable": only a person in a headset establishes that (tools/vxrt_playtest.py).

The result keeps apart what was observed (each value with the file it comes from and that file's SHA-256), what is
derived from observations (only by rule, against the game profile games/<app id>.json), what is inferred (marked as
a suspicion, with the observations it rests on) and what is not known. A run that cannot be a fair measurement is
refused before it starts, with a typed reason (the user is playing, this run's own directories are in use, a private input
is missing, ...). Several runs may overlap, each in its own runs/<id>; how many others were active is recorded
(concurrent_skyrim_runs) because timing then is noisy. The harness only ever stops the processes it started itself.

Exit status: 0 pass, 1 fail, 2 no baseline to compare with, 3 refused, 4 error.
"""
import argparse, json, os, re, signal, statistics, subprocess, sys, threading, time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vxrt_doctor as doctor                                    # noqa: E402
import vxrt_env as env_defaults                                 # noqa: E402
import vxrt_ledger as ledger                                    # noqa: E402
import vxrt_games as profiles_db                                # noqa: E402
import vxrt_native_startup as native                            # noqa: E402
import vxrt_runtime_sessions as sessions                        # noqa: E402

REPO = doctor.REPO
PLAY = os.path.join(REPO, "tools", "play_skyrim_dev.sh")
AOT_MODULES = "aot-fpcr-d5b2320/modules"                        # (the launcher's default module set under the Skyrim dir)
# Settings a run may set: renderer and Skyrim knobs the native startup accepts as --diag-env; recorded in the result.
# Anything else is refused.
TUNABLES = {"VXRT_SKYRIM_PRESET", "VXRT_INI_SET", "VXRT_XR_SUBMIT_INFLIGHT", "VXRT_XR_SYNC_SUBMIT", "VXRT_FLUSH_DRAWS", "VXRT_STATS"}
# Options the harness owns: a run's extra arguments (passed to tools/vxrt_native_startup.py) may not override them.
OWNED_ARGS = {"--out", "--seconds", "--saves-dir", "--exe", "--runtime", "--aot-dir", "--asset-root", "--dll-dir", "--appid",
              "--experimental-xrizer", "--xrizer-dylib", "--validate", "--diag-env", "--dump-eyes", "--stay-active", "--audio"}
GRACE_S = 900                                                   # beyond the scenario: hashing the inputs before and after, the launcher's start

def profiles():
    return {p["key"]: p for p in profiles_db.load_all().values()}

def launcher_env():
    """The environment the launcher sees: ours plus the player's local wrapper (local/env.sh or $VXRT_LOCAL_ENV)."""
    return dict(os.environ, **env_defaults.load_local_env())

# ---- what is installed ------------------------------------------------------------------------------------------------
def installed():
    """{app id: game} for the owned Skyrim VR install the launcher reads (SKYRIM_ASSET_ROOT), or {}."""
    root = launcher_env().get("SKYRIM_ASSET_ROOT")
    exe = os.path.join(root, "SkyrimVR.exe") if root else None
    return {"611670": {"appid": "611670", "name": "Skyrim VR", "folder": root, "exe": exe}} if exe and os.path.isfile(exe) else {}

def resolve(game):
    """(key, profile, installed game or None) for a profile's key or a Steam app id."""
    p = profiles_db.by_key(str(game))
    return (p["key"], p, installed().get(p["appid"])) if p else (game, None, None)

def private_inputs(env):
    """The launcher's private inputs that are missing (it checks the same ones and exits 2)."""
    base = env.get("SKYRIM_AOT_BASE") or str(env_defaults.skyrim_dir(env))
    aot = env.get("SKYRIM_AOT_DIR") or os.path.join(base, AOT_MODULES)
    wanted = {"prepared SkyrimVR.exe": os.path.join(base, "prepared", "SkyrimVR.exe"), "AOT modules": aot,
              "redist DLLs": os.path.join(base, "redist"), "SteamVR win64 DLLs (STEAMVR_WIN64_DLLS)": env.get("STEAMVR_WIN64_DLLS") or ""}
    return {name: path for name, path in wanted.items() if not path or not os.path.exists(path)}

# ---- preconditions ----------------------------------------------------------------------------------------------------
def active_skyrim_runs():
    """Runtime processes running SkyrimVR.exe (anyone's): [(pid, command)]."""
    return [(pid, cmd[:200]) for pid, comm, cmd in sessions.list_processes()
            if sessions.VXRT_COMM.fullmatch(os.path.basename(comm.strip("()"))) and "SkyrimVR" in cmd and pid != os.getpid()]

def is_user_session(rec):
    """A session the user started by hand: its evidence is neither in a runs/<id> directory (the harness) nor in a git
    worktree's build/ (agents' own launcher runs, build/worktrees/<name>/build/play-*); it is in the main checkout."""
    parts = os.path.normpath(rec.get("run", "")).split(os.sep)
    return "runs" not in parts and "worktrees" not in parts

def other_skyrim_sessions(own_paths):
    """([concurrent Skyrim runs that write elsewhere], [live sessions that are not harness runs]) as session records.
    Several runs may overlap (each has its own runs/<id> directory, root, overlay and saves); a session started with
    tools/play_skyrim_dev.sh by hand in the main checkout (evidence outside any runs/ directory and any worktree)
    counts as the user playing."""
    survey = sessions.survey(own_paths)
    skyrim = {pid for pid, _ in active_skyrim_runs()}
    others = [r for r in survey["concurrent"] if r["pid"] in skyrim]
    return others, [r for r in others if is_user_session(r)]

def concurrent_skyrim_count(own_paths):
    """How many other Skyrim runs are active besides one writing into own_paths."""
    return len(other_skyrim_sessions(own_paths)[0])

def preconditions(spec, game, args, settings, run_dir=None, concurrent=None):
    """Checks that make a run a fair measurement; each failed one is a typed refusal."""
    checks = []
    def check(code, ok, detail):
        checks.append({"code": code, "ok": bool(ok), "detail": detail})
    check("game_installed", spec and game, f"owned install: {game['folder']}" if game else
          "no SkyrimVR.exe at SKYRIM_ASSET_ROOT (set it in local/env.sh or $VXRT_LOCAL_ENV; docs/SETUP_SKYRIM.md) or unknown game")
    check("launcher_present", os.path.isfile(PLAY), os.path.relpath(PLAY, REPO))
    missing = private_inputs(launcher_env())
    check("private_inputs", not missing, "all present" if not missing else "missing: " + "; ".join(f"{n} ({p or 'not set'})" for n, p in missing.items()))
    # SteamVR, a Wine game, or any runtime not provably harness/fixture-owned is the user's: it refuses the run, as does
    # a runtime writing where this run will (tools/vxrt_runtime_sessions.py).
    own = run_dir or os.path.join(REPO, "runs", "_check")
    session_checks, owned = sessions.preconditions([own])
    checks.extend(session_checks)                  # user_not_playing, run_paths_unshared (this run's directory, root, overlay, TMPDIR)
    others, play = other_skyrim_sessions([own])
    check("no_user_play_session", not play, "no hand-started tools/play_skyrim_dev.sh session" if not play else
          "playing: " + "; ".join(f"pid {r['pid']} {r.get('run', '')}" for r in play) + " (never stopped by the harness)")
    if concurrent is not None:
        concurrent.extend(owned)
    bad = sorted(set(settings) - TUNABLES)
    check("settings_allowed", not bad, "only " + ", ".join(sorted(TUNABLES)) if not bad else "not tunable: " + ", ".join(bad))
    owned_args = sorted({a.split("=")[0] for a in args} & OWNED_ARGS)
    check("args_allowed", not owned_args, "extra arguments go to tools/vxrt_native_startup.py" if not owned_args else "the harness owns: " + ", ".join(owned_args))
    return checks

# ---- reading what happened --------------------------------------------------------------------------------------------
PAIRS = re.compile(r"game (\d+) fresh pairs/s")                 # the dev host window title, logged every 10 s
RING = re.compile(r"xr submit ring: submitted (\d+) completed (\d+) failed (\d+)")
EYE = re.compile(r"dump frame \d+ eye \d \d+x\d+ mean rgb [\d. ]+, [\d.]+% pixels differ from pixel 0, ([\d.]+)% non-black")

def median(xs):
    return round(statistics.median(xs), 1) if xs else None

def sample_concurrency(stop, counts, own_paths):
    """How many other Skyrim runs are active, every 10 s (timing under concurrency is noisy: recorded, not refused)."""
    while not stop.is_set():
        try: counts.append(concurrent_skyrim_count(own_paths))
        except Exception: pass
        stop.wait(10)

def sample_gpu(stop, samples, log):
    """GPU utilisation every 2 s while the startup log is growing (the game is running)."""
    while not stop.is_set():
        if os.path.exists(log) and time.time() - os.path.getmtime(log) < 5:
            out = subprocess.run(["ioreg", "-r", "-d1", "-c", "IOAccelerator"], capture_output=True, text=True).stdout
            m = re.search(r'"Device Utilization %"=(\d+)', out)
            if m:
                samples.append((time.time(), int(m.group(1))))
        stop.wait(2)

def game_log_facts(path, exe="SkyrimVR.exe"):
    """Counts from the game's own lines of the startup log (not helper processes it started)."""
    facts = {"unhandled": 0, "signals": 0, "unimplemented": {}, "first_problem": None, "exit": None}
    if not path or not os.path.exists(path):
        return facts
    for n, line in enumerate(open(path, errors="replace"), 1):
        other = re.match(r"\[vxrt ([^\]:]+):\d+\]", line)
        if other and other.group(1).lower() != exe.lower():
            continue
        problem = None
        if "unhandled exception" in line or "unwind did not reach" in line:
            facts["unhandled"] += 1; problem = line
        elif re.search(r"\bsignal \d+ at 0x", line):
            facts["signals"] += 1; problem = line
        elif "called an unimplemented function:" in line:
            fn = line.split("called an unimplemented function:", 1)[1].strip()
            facts["unimplemented"][fn] = facts["unimplemented"].get(fn, 0) + 1; problem = line
        elif "has no recompiled code" in line or "[vxrt] abort:" in line:
            problem = line
        m = re.search(r"(ExitProcess\(\d+\) from \S+)", line)
        if m: facts["exit"] = m.group(1)
        if problem and not facts["first_problem"]:
            facts["first_problem"] = {"line": n, "text": problem.strip()[:300]}
    return facts

def log_series(path):
    """(fresh pairs/s samples, (submitted, completed, failed) of the last submit-ring line or None, eye non-black %)."""
    text = open(path, errors="replace").read() if path and os.path.exists(path) else ""
    ring = RING.findall(text)
    return [float(x) for x in PAIRS.findall(text)], tuple(int(x) for x in ring[-1]) if ring else None, [float(x) for x in EYE.findall(text)]

# How far a run got, lowest to highest. "playable" is never derived from a run: only a person in the headset says so.
LEVELS = ["starts", "draws", "runs", "playable"]

def level(ev):
    """The highest level the run's observations show (None: it did not even start under AOT)."""
    ring = ev.value("xr_submit_ring") or {}
    checks = [("starts", bool(ev.value("aot_executed"))),
              ("draws", (ring.get("submitted") or 0) > 0 and ring.get("failed") == 0),
              ("runs", not ev.value("exited_early") and ev.value("pairs_per_s_median") not in (None, 0)
                       and not ev.value("unhandled_exceptions") and not ev.value("native_signals"))]
    reached = None
    for name, ok in checks:
        if not ok:
            break
        reached = name
    return reached

# ---- the evidence -----------------------------------------------------------------------------------------------------
def rel(path):
    return os.path.relpath(path, REPO)

class Evidence:
    def __init__(self):
        self.observed, self.derived, self.inferred, self.unknown, self.limits = [], [], [], [], []
    def observe(self, metric, value, artifact=None, **extra):
        item = {"id": "o%d" % (len(self.observed) + 1), "metric": metric, "value": value}
        if artifact and os.path.exists(artifact):
            item["artifact"] = rel(artifact); item["sha256"] = ledger.sha256_file(artifact)
        item.update(extra)
        self.observed.append(item)
        return item["id"]
    def ref(self, metric):
        return next((o["id"] for o in self.observed if o["metric"] == metric), None)
    def value(self, metric):
        return next((o["value"] for o in self.observed if o["metric"] == metric), None)

def baseline_for(key, scenario):
    """(name, baseline, its place) from the game's profile, or (None, None, None)."""
    p = profiles_db.by_key(str(key))
    table = p["baselines"] if p else {}
    return (scenario, table[scenario], f"games/{p['appid']}.json#{scenario}") if scenario in table else (None, None, None)

def derive(ev, base, src=None):
    """Claims that follow from observations by rule, each naming the observations and the baseline it used. The
    strict-AOT, submit, whole-scenario and no-crash claims are asked of every run, with a baseline or not."""
    base = base or {}
    src = src or "tools/vxrt_run.py (every run)"
    def add(claim, holds, rule, *metrics):
        ev.derived.append({"id": "d%d" % (len(ev.derived) + 1), "claim": claim, "holds": bool(holds), "rule": rule,
                           "from": [ev.ref(m) for m in metrics], "baseline": src})
    pairs = ev.value("pairs_per_s_median")
    ring = ev.value("xr_submit_ring") or {}
    if "min_pairs_per_s" in base:
        add("pairs_meet_baseline", pairs is not None and pairs >= base["min_pairs_per_s"], f"pairs_per_s_median >= {base['min_pairs_per_s']}", "pairs_per_s_median")
    if base.get("non_black"):
        nb = ev.value("eye_non_black_percent_median")
        add("frame_not_black", nb is not None and nb > 5, "eye_non_black_percent_median > 5", "eye_non_black_percent_median")
    if base.get("zero_fallback", True):
        add("aot_zero_fallback", ev.value("aot_executed") and ev.value("zero_fallback_reported") and not ev.value("missing_code"),
            "AOT entries seen, every counter line reports 0 fallbacks and 0 addresses, no missing code (absent counters fail)",
            "aot_executed", "zero_fallback_reported", "missing_code")
    add("frames_submitted", (ring.get("submitted") or 0) > 0 and ring.get("failed") == 0, "the last submit-ring line: submitted > 0 and failed = 0", "xr_submit_ring")
    add("ran_for_the_whole_scenario", not ev.value("exited_early"), "exited_early is false (the time limit ended it)", "exited_early")
    add("no_crash_signals", not ev.value("native_signals") and not ev.value("unhandled_exceptions") and not ev.value("xrizer_panics"),
        "no native signals, unhandled exceptions or xrizer panics in the log", "native_signals", "unhandled_exceptions", "xrizer_panics")
    add("inputs_and_source_unchanged", ev.value("read_only_inputs_unchanged") and ev.value("source_unchanged"),
        "read-only inputs and the source identity are the same after the run", "read_only_inputs_unchanged", "source_unchanged")

def infer(ev):
    """Suspicions, never facts: each says what it rests on and how sure it is."""
    def add(claim, basis, refs, confidence="low"):
        ev.inferred.append({"id": "i%d" % (len(ev.inferred) + 1), "claim": claim, "basis": basis, "from": [r for r in refs if r], "confidence": confidence})
    pairs, gpu = ev.value("pairs_per_s_median"), ev.value("gpu_utilization_median")
    failed = {d["claim"] for d in ev.derived if not d["holds"]}
    if "pairs_meet_baseline" in failed and gpu is not None:
        if gpu >= 90:
            add("GPU-bound", f"{pairs} pairs/s below baseline with the GPU {gpu}% busy", [ev.ref("pairs_per_s_median"), ev.ref("gpu_utilization_median")])
        elif gpu < 60:
            add("limited by the CPU, synchronisation or pacing rather than the GPU", f"{pairs} pairs/s below baseline with the GPU only {gpu}% busy",
                [ev.ref("pairs_per_s_median"), ev.ref("gpu_utilization_median")])
    if ev.value("concurrent_skyrim_runs"):
        add("pairs/s and GPU numbers are affected by other Skyrim runs on this Mac", f"{ev.value('concurrent_skyrim_runs')} other Skyrim runtime(s) active during the run",
            [ev.ref("concurrent_skyrim_runs"), ev.ref("pairs_per_s_median")], "medium")
    if ev.value("exited_early"):
        add("the game stopped before the end of the scenario", "the process exited by itself; see first_problem and native_signals",
            [ev.ref("exited_early"), ev.ref("first_problem"), ev.ref("native_signals")], "medium")
    if "frames_submitted" in {d["claim"] for d in ev.derived if d["holds"]} and "frame_not_black" in failed:
        add("frames reach the host but are black (rendering or the scene is not drawn yet)", "frames submitted, eye images (almost) all black",
            [ev.ref("xr_submit_ring"), ev.ref("eye_non_black_percent_median")])
    if "aot_zero_fallback" in failed and ev.value("aot_executed"):
        add("code outside the compiled module set ran or was requested: the AOT set does not cover this path", "AOT ran, but the counters report fallbacks or missing addresses",
            [ev.ref("aot_summaries"), ev.ref("missing_code")], "medium")

def validate(result):
    """Problems with a result: claims resting on observations that are not there, derived claims that do not follow
    from the recorded values, artifacts that changed, native evidence that no longer validates. [] means valid."""
    problems = []
    obs = {o["id"]: o for o in result.get("observed", [])}
    for kind in ("derived", "inferred"):
        for item in result.get(kind, []):
            refs = item.get("from") or []
            if not refs or any(r not in obs for r in refs):
                problems.append(f"{kind} {item.get('id')} ({item.get('claim')}) rests on no recorded observation: {refs}")
    for o in obs.values():
        if o.get("artifact") and o.get("sha256"):
            p = os.path.join(REPO, o["artifact"])
            if not os.path.exists(p) or ledger.sha256_file(p) != o["sha256"]:
                problems.append(f"observation {o['id']} ({o['metric']}): {o['artifact']} changed or gone")
    # Recorded values against what they come from: a median against its samples, the samples against the file.
    for o in obs.values():
        if o["metric"] == "pairs_per_s_median" and o.get("samples") is not None:
            if median(o["samples"]) != o["value"]:
                problems.append(f"observation {o['id']} (pairs_per_s_median): {o['value']} is not the median of its samples ({median(o['samples'])})")
            p = os.path.join(REPO, o.get("artifact", ""))
            recorded = {float(x) for x in PAIRS.findall(open(p, errors="replace").read())} if o.get("artifact") and os.path.exists(p) else set()
            missing = [x for x in o["samples"] if float(x) not in recorded]
            if missing:
                problems.append(f"observation {o['id']} (pairs_per_s_median): samples not in {o.get('artifact')}: {missing[:5]}")
    nat = result.get("native", {}).get("result")
    if nat and os.path.exists(os.path.join(REPO, nat)):
        problems += ["native evidence: " + p for p in native.validate(json.load(open(os.path.join(REPO, nat))))]
    # Re-derive: the same rules over the recorded values must give the same answers.
    if result.get("observed"):
        ev = Evidence(); ev.observed = list(obs.values())
        _, base, src = baseline_for(result["game"], result["scenario"])
        if base or not result.get("baseline"):
            derive(ev, base, src)
            again = {d["claim"]: d["holds"] for d in ev.derived}
            for d in result.get("derived", []):
                if d["claim"] in again and again[d["claim"]] != d["holds"]:
                    problems.append(f"derived {d['id']} ({d['claim']}) says {d['holds']}, the recorded values give {again[d['claim']]}")
        if "level" in result and level(ev) != result["level"]:
            problems.append(f"level says {result['level']}, the recorded values give {level(ev)}")
    return problems

# ---- a run ------------------------------------------------------------------------------------------------------------
def git_state():
    head = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "-C", REPO, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True).stdout.strip())
    return head, dirty

def stop_launched(p):
    """Stops the process this harness started and what it started (the game runs in a session of its own): only
    descendants of p, found by parent pid; never anything by name."""
    kids = [int(x) for x in subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()]
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in kids + [p.pid]:
            try: os.killpg(os.getpgid(pid), sig)
            except (ProcessLookupError, PermissionError): pass
        try: p.wait(15)
        except subprocess.TimeoutExpired: continue
        break

def launch_command(scenario_spec, seconds, native_dir, args, settings, trace_calls, no_build=True):
    cmd = [PLAY] + (["--no-build"] if no_build else []) + ["--mute", "--seconds", str(int(seconds)), "--out", native_dir]
    if scenario_spec.get("helgen"):
        cmd.append("--helgen")
    if trace_calls:
        cmd += ["--trace-calls", str(int(trace_calls))]
    # (the eye statistics are logged every 30th frame; raw eye files only every 3000th, to keep a run small)
    cmd += ["--", "--dump-eyes", "--diag-env", "VXRT_XRIZER_DEV_DUMP_EVERY=3000"]
    for k, v in sorted(settings.items()):
        cmd += ["--diag-env", f"{k}={v}"]
    return cmd + list(args)

def run(game, scenario=None, seconds=None, extra_args=(), trace_calls=0, build=True, quiet=False, settings=None):
    key, spec, inst = resolve(game)
    scenario = scenario or (spec or {}).get("default_scenario", "helgen")
    sc = (spec or {}).get("scenarios", {}).get(scenario)
    args = list(extra_args)
    seconds = seconds or (sc or {}).get("seconds", 180)
    started = time.time()
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{key}-{scenario}"
    run_dir = os.path.join(REPO, "runs", run_id)
    logs = os.path.join(run_dir, "logs")
    native_dir = os.path.join(run_dir, "native")               # (created by the native startup, which refuses an existing one)
    if os.path.exists(run_dir):                                # (same run id: never write into another run's directory)
        return {"run_id": run_id, "game": key, "status": "refused", "refused": ["run_id_unique"],
                "preconditions": [{"code": "run_id_unique", "ok": False, "detail": "runs/%s already exists; start again in a second" % run_id}]}
    os.makedirs(logs)
    head, dirty = git_state()
    settings = dict((spec or {}).get("settings", {}), **(settings or {}))
    result = {"run_id": run_id, "game": key, "appid": (spec or {}).get("appid"), "scenario": scenario, "exe": "SkyrimVR.exe", "arguments": args, "seconds": seconds,
              "subject": "actual game (Skyrim VR) on the Mac dev host: strict AOT, xrizer dev host, keyboard-driven synthetic controllers; "
                         "not SteamVR, not a headset, no physical tracking or input, audio muted",
              "started": datetime.fromtimestamp(started, timezone.utc).isoformat(), "settings": settings,
              "environment": {"commit": head, "uncommitted_changes": dirty, "machine": doctor.machine_info(), "python": sys.version.split()[0],
                              # (settings already in the environment reach the game too: recorded, so a result says what ran)
                              "inherited": {k: v for k, v in os.environ.items() if k.startswith("VXRT_")}}}
    say = (lambda *a: None) if quiet else (lambda *a: print(*a, file=sys.stderr))
    concurrent = []
    checks = preconditions(spec, inst, args, settings, run_dir, concurrent)
    concurrent_peers = other_skyrim_sessions([run_dir])[0]
    if concurrent:
        result.setdefault("diagnostic", {})["concurrent_runtime"] = {"processes": concurrent,
            "scope": "owned runtime processes running when this run started; timing and fps may be affected"}
    if sc is None and spec:
        checks.append({"code": "scenario_known", "ok": False, "detail": f"{scenario}: not one of {sorted(spec['scenarios'])}"})
    result["preconditions"] = checks
    if not all(c["ok"] for c in checks):
        result["status"] = "refused"
        result["refused"] = [c["code"] for c in checks if not c["ok"]]
        return finish(result, run_dir, say)

    env = launcher_env()
    env["SKYRIM_SAVES_DIR"] = os.path.join(run_dir, "saves")   # (isolated: the player's saves are never used)
    if build:                                                   # (the launcher's incremental builds; not part of the measurement)
        say(f"vxrt run {run_id}: building (tools/play_skyrim_dev.sh --build-only)")
        built = subprocess.run([PLAY, "--build-only"], env=env, capture_output=True, text=True)
        open(os.path.join(logs, "build.log"), "w").write(built.stdout + built.stderr)
        if built.returncode:
            result["status"] = "refused"; result["refused"] = ["launcher_builds"]
            result["preconditions"].append({"code": "launcher_builds", "ok": False, "detail": f"tools/play_skyrim_dev.sh --build-only exit {built.returncode}: logs/build.log"})
            return finish(result, run_dir, say)
    cmd = launch_command(sc, seconds, native_dir, args, settings, trace_calls)
    result["command"] = " ".join(os.path.relpath(c, REPO) if c == PLAY else c for c in cmd)
    startup_log = os.path.join(native_dir, "startup.log")
    stop, gpu, others_seen = threading.Event(), [], [len(concurrent_peers)]
    sampler = threading.Thread(target=sample_gpu, args=(stop, gpu, startup_log), daemon=True)
    watcher = threading.Thread(target=sample_concurrency, args=(stop, others_seen, [run_dir]), daemon=True)
    say(f"vxrt run {run_id}: {result['command']}")
    with open(os.path.join(logs, "launcher.log"), "w") as out:
        p = subprocess.Popen(cmd, env=env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    sampler.start(); watcher.start()
    try:
        p.wait(timeout=seconds + GRACE_S)
    except subprocess.TimeoutExpired:
        result.setdefault("diagnostic", {})["harness_stopped_launch"] = f"still running {GRACE_S} s after the scenario; the harness stopped its own process tree"
        stop_launched(p)
    except BaseException:
        stop_launched(p)
        raise
    finally:
        stop.set()
    ended = time.time()
    result["launcher_exit"] = p.returncode

    nat_path = os.path.join(native_dir, "result.json")
    if not os.path.exists(nat_path):
        result["status"] = "error"
        result["error"] = "no native evidence; see logs/launcher.log"
        return finish(result, run_dir, say)
    nat = json.load(open(nat_path))
    result["native"] = {"result": rel(nat_path), "sha256": ledger.sha256_file(nat_path), "status": nat["status"], "source_identity": nat.get("source_identity"),
                        "artifacts": {k: nat["artifacts"][k] for k in ("runtime", "exe", "xrizer_dylib") if k in nat.get("artifacts", {})},
                        "module_count": len(nat.get("artifacts", {}).get("modules", [])), "command": nat.get("command"),
                        "execution_mode": {k: v for k, v in nat.get("environment", {}).items() if k in ("VXRT_AOT_STRICT", "VXRT_MUTE", "VXRT_XRIZER_DEV_KEYBOARD", "VXRT_XINPUT_SCRIPT")},
                        "diagnostic": nat.get("diagnostic")}
    if nat["status"] == "refused":
        result["status"] = "refused"
        result["refused"] = ["native_" + c["code"] for c in nat.get("preconditions", []) if not c["ok"]]
        result["preconditions"] += [dict(c, code="native_" + c["code"]) for c in nat.get("preconditions", []) if not c["ok"]]
        return finish(result, run_dir, say)

    ev = Evidence()
    process_json, nat_obs = os.path.join(native_dir, "process.json"), {o["metric"]: o["value"] for o in nat["observed"]}
    window = max(10.0, min(60.0, seconds / 2))                 # measured: the last part of the run (after loading)
    pairs, ring, eye = log_series(startup_log)
    recent = pairs[-max(1, int(window / 10)):]
    ev.observe("exited_early", not nat_obs["timed_out"], process_json, **({"returncode": nat_obs["returncode"]} if not nat_obs["timed_out"] else {}))
    ev.observe("read_only_inputs_unchanged", nat_obs["read_only_inputs_unchanged"], process_json)
    ev.observe("source_unchanged", nat_obs.get("source_unchanged"), process_json)
    ev.observe("aot_executed", nat_obs["aot_executed"], startup_log)
    ev.observe("zero_fallback_reported", nat_obs["zero_fallback_reported"], startup_log)
    last = (nat_obs["aot_summaries"] or [None])[-1]
    ev.observe("aot_summaries", {"counter_lines": len(nat_obs["aot_summaries"]), "last": last}, startup_log,
               note="the runtime's periodic 'aot:' counter lines; fallback_requests and missing_addresses must be 0 in every one")
    ev.observe("missing_code", nat_obs["missing_code"], startup_log)
    ev.observe("pairs_per_s_median", median(recent), startup_log, samples=recent, window_s=window,
               source="the dev host's 'game N fresh pairs/s' (producer pairs, not compositor repeats), 10 s averages")
    ev.observe("xr_submit_ring", dict(zip(("submitted", "completed", "failed"), ring)) if ring else None, startup_log, note="last 'xr submit ring' line")
    ev.observe("eye_non_black_percent_median", median(eye[-120:]), startup_log, note="share of non-black pixels of the published eye images, last 120 statistics lines (both eyes)")
    ev.observe("concurrent_skyrim_runs", max(others_seen), None, at_start=others_seen[0], samples_taken=len(others_seen),
               note="most other Skyrim runtimes seen running (10 s samples) while this run ran; >0 makes pairs/s and GPU numbers noisy")
    ev.observe("gpu_utilization_median", median([v for t, v in gpu if t >= ended - window - 5]), None, window_s=window)
    for metric in ("native_signals", "xrizer_panics", "xrizer_bridge_stops", "xrizer_unsupported_interfaces"):
        ev.observe(metric, nat_obs.get(metric), startup_log)
    facts = game_log_facts(startup_log)
    ev.observe("unhandled_exceptions", facts["unhandled"], startup_log)
    ev.observe("unimplemented_calls", facts["unimplemented"], startup_log)
    ev.observe("first_problem", facts["first_problem"], startup_log)
    ev.observe("exit", facts["exit"], startup_log)

    _, base, base_src = baseline_for(key, scenario)
    result["baseline"] = base_src
    derive(ev, base, base_src)
    infer(ev)
    ev.unknown += [
        {"item": "whether the scene reached is the intended one (Helgen cart, main menu)", "reason": "the eye images are only checked for not being black; look at runs/%s/native/eyes" % run_id},
        {"item": "frame-to-frame timing (stutter)", "reason": "pairs/s are 10-second averages"},
        {"item": "audio", "reason": "the run is muted"},
        {"item": "behaviour with a real headset, tracking and hands", "reason": "head and controllers are the dev host's synthetic ones, driven by a pad script"},
        {"item": "whether the game can be played", "reason": "a person decides 'playable' in a physical headset session; this harness never does"},
        {"item": "run-to-run variation", "reason": "one run; compare settings in alternating runs (A B B A)"},
    ]
    ev.limits += ["Mac dev host: not the standalone Vision Pro runtime and not SteamVR", "other programs on the Mac, and other Skyrim runs (concurrent_skyrim_runs), change timing and GPU numbers"]
    result.update({"observed": ev.observed, "derived": ev.derived, "inferred": ev.inferred, "unknown": ev.unknown,
                   "limits": ev.limits, "duration_s": round(ended - started, 1)})
    result["status"] = "fail" if not all(d["holds"] for d in ev.derived) else "pass" if base else "no_baseline"
    result["level"] = level(ev)
    return finish(result, run_dir, say)

def finish(result, run_dir, say):
    result["validation"] = validate(result)
    path = os.path.join(run_dir, "result.json")
    with open(path, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    row = ledger.append({"run_id": result["run_id"], "game": result["game"], "scenario": result["scenario"],
                         "status": result["status"], "commit": result["environment"]["commit"], "result": rel(path),
                         "result_sha256": ledger.sha256_file(path)})
    result["ledger"] = {"row": row["i"], "sha": row["sha"]}
    say(summary(result))
    return result

def summary(r):
    lines = [f"{r['run_id']}: {r['status']}" + (f" (refused: {', '.join(r['refused'])})" if r.get("refused") else "") +
             (f", level {r['level']}" if r.get("level") else "")]
    for c in r.get("preconditions", []):
        if not c["ok"]: lines.append(f"  precondition {c['code']}: {c['detail']}")
    for o in r.get("observed", []):
        lines.append(f"  observed {o['id']} {o['metric']} = {json.dumps(o['value'], ensure_ascii=False)[:160]}")
    for d in r.get("derived", []):
        lines.append(f"  derived {d['id']} {d['claim']}: {'yes' if d['holds'] else 'NO'} ({d['rule']})")
    for i in r.get("inferred", []):
        lines.append(f"  inferred {i['id']} ({i['confidence']}): {i['claim']}")
    if r.get("validation"): lines.append("  validation: " + "; ".join(r["validation"]))
    lines.append(f"  result: runs/{r['run_id']}/result.json")
    return "\n".join(lines)

def parse_settings(pairs):
    return dict(kv.split("=", 1) for kv in pairs)

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game", nargs="?", help="skyrim, or its Steam app id 611670")
    ap.add_argument("scenario", nargs="?")
    ap.add_argument("--seconds", type=float)
    ap.add_argument("--args", nargs=argparse.REMAINDER, default=[], help="more arguments for tools/vxrt_native_startup.py (last), e.g. --mods-config P/mods.json")
    ap.add_argument("--trace-calls", type=int, default=0, help="log the first N calls per runtime function (costs ~20%% CPU)")
    ap.add_argument("--set", action="append", default=[], metavar="NAME=VALUE", help="a tunable setting (TUNABLES in this file), repeatable")
    ap.add_argument("--no-build", action="store_true", help="skip the launcher's incremental builds (they are not part of the measurement)")
    ap.add_argument("--json", action="store_true", help="the result on stdout")
    ap.add_argument("--list", action="store_true"); ap.add_argument("--check", action="store_true", help="preconditions only")
    ap.add_argument("--baselines", action="store_true", help="every scenario with a baseline in the game profile")
    ap.add_argument("--validate", metavar="RUN_DIR"); ap.add_argument("--verify-ledger", action="store_true")
    a = ap.parse_args()
    if a.verify_ledger:
        r = ledger.verify(); print(json.dumps(r, ensure_ascii=False, indent=2)); sys.exit(0 if r["ok"] else 1)
    if a.validate:
        problems = validate(json.load(open(os.path.join(a.validate, "result.json"))))
        print(json.dumps({"valid": not problems, "problems": problems}, ensure_ascii=False, indent=2)); sys.exit(0 if not problems else 1)
    if a.list:
        inst = installed()
        for key, spec in profiles().items():
            print(f"{key:10} {spec['appid']:7} {'installed' if spec['appid'] in inst else 'not installed':14} {spec['status']['state']:9} scenarios: {', '.join(spec['scenarios'])}")
        return
    if a.baselines:                                            # (make -C VXRuntime vr-check)
        worst = 0
        for key, spec in profiles().items():
            if a.game and a.game not in (key, spec["appid"]):
                continue
            for scenario in spec["baselines"]:
                r = run(key, scenario, a.seconds, a.args, a.trace_calls, not a.no_build, settings=parse_settings(a.set))
                code = {"pass": 0, "fail": 1, "no_baseline": 2, "refused": 3}.get(r["status"], 4)
                if code == 3: sys.exit(3)                      # (refused: the rest would be too)
                worst = max(worst, code)
        sys.exit(worst)
    if not a.game:
        ap.error("which game? (--list)")
    if a.check:
        key, spec, inst = resolve(a.game)
        checks = preconditions(spec, inst, a.args, parse_settings(a.set))
        print(json.dumps(checks, ensure_ascii=False, indent=2)); sys.exit(0 if all(c["ok"] for c in checks) else 3)
    try:
        r = run(a.game, a.scenario, a.seconds, a.args, a.trace_calls, not a.no_build, quiet=a.json, settings=parse_settings(a.set))
    except Exception as e:                                    # (an error in the harness itself, not the game's)
        print(f"vxrt run: error: {e}", file=sys.stderr); sys.exit(4)
    if a.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
    sys.exit({"pass": 0, "fail": 1, "no_baseline": 2, "refused": 3}.get(r["status"], 4))

if __name__ == "__main__":
    main()
