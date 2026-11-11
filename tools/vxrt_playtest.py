#!/usr/bin/env python3
"""vxrt playtest: you play Skyrim VR on the Mac dev host (tools/play_skyrim_dev.sh: keyboard dev controllers, your own
sound and a run-private copy of the saves directory unless --saves-dir says otherwise) and this records where it goes
wrong. This is NOT a "playable" verdict: only a human physical-headset session establishes playable (AGENTS.md), and
this tool never drives or records one. It records a dev-host playtest: marks, rates, crashes and a checklist.

    tools/vxrt_playtest.py skyrim                # start the dev launcher with evidence in runs/<id>/native
    tools/vxrt_playtest.py skyrim --minutes 5
    tools/vxrt_playtest.py --show skyrim         # the playtests recorded for the game
    tools/vxrt_playtest.py --apply runs/<id>     # put a playtest's summary into games/<appid>.json ("playtests")

While you play: press Enter in this Terminal where something goes wrong (type a note first if you like); each mark
keeps the last lines of the startup log. When the game ends (or Ctrl-C) it asks a short checklist. The record:
runs/<id>/playtest.json, sealed in runs/ledger.jsonl.

Removed with the streaming path: the Vision Pro input recorder (tracking, triggers, both-sticks marks, per-second
input), because there is no streamed headset to read; the dev host's keys are the Mac keyboard's.

The checklist counts as "dev_host_ok" when picture, input, menus and movement were answered yes, the game did not
crash and the session lasted --minutes (default 10). That is a dev-host result only.
"""
import argparse, json, os, select, signal, subprocess, sys, threading, time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vxrt_doctor as doctor                                    # noqa: E402
import vxrt_games as profiles_db                                # noqa: E402
import vxrt_ledger as ledger                                    # noqa: E402
import vxrt_run as harness                                      # noqa: E402

REPO = doctor.REPO
REQUIRED = ["picture", "head", "hands", "buttons", "movement"]
QUESTIONS = [("picture", "Did the picture show correctly in the dev window"), ("head", "Did the picture follow the (mouse) head"),
             ("hands", "Were the hands (keyboard controllers) in the game, moving with your keys"),
             ("buttons", "Did trigger and grip (keys) work"), ("movement", "Could you move and turn"),
             ("menu", "Could you use menus and on-screen controls"), ("audio", "Was there sound")]
FREE = [("reached", "How far did you get (scene, chapter)"), ("notes", "Anything else that went wrong (Enter: none)")]

class Recorder:
    def __init__(self, log):
        self.log, self.marks, self.stop, self.t0 = log, [], threading.Event(), time.time()
    def mark(self, note=""):
        t = round(time.time() - self.t0, 1)
        tail = open(self.log, errors="replace").read().splitlines()[-25:] if os.path.exists(self.log) else []
        self.marks.append({"at_s": t, "how": "Enter", "note": note, "startup_log_tail": [line[:300] for line in tail]})
        print(f"  mark {len(self.marks)} at {t:.0f} s{(': ' + note) if note else ''}", file=sys.stderr)
    def watch_terminal(self):
        if not sys.stdin.isatty():
            return
        while not self.stop.is_set():
            r, _, _ = select.select([sys.stdin], [], [], 0.3)
            if r:
                self.mark(sys.stdin.readline().strip())

def ask():
    if not sys.stdin.isatty():
        return None
    answers = {}
    print("\nPlaytest checklist (y / n / s = not sure):")
    for key, q in QUESTIONS:
        while True:
            a = input(f"  {q}? [y/n/s] ").strip().lower()[:1]
            if a in ("y", "n", "s"):
                answers[key] = {"y": "yes", "n": "no", "s": "unsure"}[a]; break
    for key, q in FREE:
        answers[key] = input(f"  {q}: ").strip()
    return answers

def playtest(game, minutes=10.0, saves_dir=None):
    key, spec, inst = harness.resolve(game)
    checks = harness.preconditions(spec, inst, [], {})
    bad = [c for c in checks if not c["ok"]]
    if bad:
        sys.exit("Not starting: " + "; ".join(f"{c['code']}: {c['detail']}" for c in bad))
    pid = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-playtest-{key}"
    run_dir = os.path.join(REPO, "runs", pid)
    os.makedirs(os.path.join(run_dir, "logs"))
    native_dir, log = os.path.join(run_dir, "native"), os.path.join(run_dir, "native", "startup.log")
    env = harness.launcher_env()
    if saves_dir:                                                # (default: the launcher's saves directory, i.e. the player's own)
        env["SKYRIM_SAVES_DIR"] = saves_dir
    cmd = [harness.PLAY, "--out", native_dir]                    # (the player's launcher: sound on, up to the launcher's time limit)
    rec = Recorder(log)
    print(f"playtest {pid}: {spec['name']} on the Mac dev host. Click the 'VXRuntime dev keyboard' window and play.\n"
          f"  Something wrong? Press Enter here (with a note). End: quit the game or Ctrl-C.", file=sys.stderr)
    with open(os.path.join(run_dir, "logs", "launcher.log"), "w") as out:
        p = subprocess.Popen(cmd, env=env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    t = threading.Thread(target=rec.watch_terminal, daemon=True); t.start()
    ended_by = "game"
    try:
        p.wait()
    except KeyboardInterrupt:
        ended_by = "Ctrl-C"
        harness.stop_launched(p)                                 # (our own process tree only)
    rec.stop.set()
    duration = time.time() - rec.t0
    facts = harness.game_log_facts(log)
    pairs, ring, _ = harness.log_series(log)
    slow = [i * 10 for i, f in enumerate(pairs) if f < 0.75 * 60]
    answers = ask()
    crashed = bool(facts["unhandled"] or facts["signals"] or (facts["exit"] and not str(facts["exit"]).startswith("ExitProcess(0)")))
    problems = [{"what": "mark", **{k: m[k] for k in ("at_s", "how", "note")}} for m in rec.marks]
    problems += [{"what": f"answered no: {k}"} for k, v in (answers or {}).items() if v == "no"]
    if facts["first_problem"]: problems.append({"what": "first problem in the startup log", "line": facts["first_problem"]})
    if crashed: problems.append({"what": "the game crashed or quit by itself", "exit": facts["exit"]})
    if facts["unimplemented"]: problems.append({"what": "unimplemented Windows functions called", "calls": facts["unimplemented"]})
    if slow: problems.append({"what": "fresh pairs/s under 45", "at_s": slow[:20], "windows": len(slow)})
    verdict = {"answered": answers is not None, "required_yes": answers is not None and all(answers.get(k) == "yes" for k in REQUIRED),
               "no_crash": not crashed, "long_enough": duration >= minutes * 60}
    verdict["dev_host_ok"] = all(verdict.values())
    record = {"playtest_id": pid, "game": key, "appid": spec["appid"], "venue": "Mac dev host (keyboard controllers); not a headset", "machine": doctor.machine_info(),
              "started": datetime.fromtimestamp(rec.t0, timezone.utc).isoformat(), "minutes": round(duration / 60, 1), "ended_by": ended_by,
              "commit": harness.git_state()[0], "answers": answers, "verdict": verdict, "problems": problems, "marks": rec.marks,
              "pairs_per_s": {"source": "the dev host's 'game N fresh pairs/s', 10 s averages", "series": pairs}, "xr_submit_ring": ring,
              "native_result": os.path.relpath(os.path.join(native_dir, "result.json"), REPO) if os.path.exists(os.path.join(native_dir, "result.json")) else None,
              "startup_log": os.path.relpath(log, REPO) if os.path.exists(log) else None,
              "game_log": {"exit": facts["exit"], "first_problem": facts["first_problem"], "unimplemented_calls": facts["unimplemented"]},
              "rule": f"dev_host_ok: {', '.join(REQUIRED)} answered yes, no crash, at least {minutes:g} minutes. Never 'playable': that needs a physical-headset session"}
    path = os.path.join(run_dir, "playtest.json")
    json.dump(record, open(path, "w"), ensure_ascii=False, indent=2)
    ledger.append({"playtest_id": pid, "game": key, "dev_host_ok": verdict["dev_host_ok"], "result": os.path.relpath(path, REPO),
                   "result_sha256": ledger.sha256_file(path)})
    return record

def apply(run_dir):
    """Adds a playtest to its game's profile ("playtests"). The status and level are not changed: a dev-host playtest is not playable."""
    rec = json.load(open(os.path.join(run_dir, "playtest.json")))
    f = os.path.join(REPO, "games", f"{rec['appid']}.json")
    p = json.load(open(f))
    p.setdefault("playtests", []).append({"date": rec["started"][:10], "venue": rec["venue"], "machine": f"{rec['machine']['chip']}, {rec['machine']['gpu_cores']}-core GPU",
                                          "minutes": rec["minutes"], "dev_host_ok": rec["verdict"]["dev_host_ok"], "reached": (rec["answers"] or {}).get("reached", ""),
                                          "problems": len(rec["problems"]), "source": f"tools/vxrt_playtest.py {rec['playtest_id']}"})
    problems = profiles_db.problems(p, f)
    if problems:
        raise ValueError("; ".join(problems))
    open(f, "w").write(json.dumps(p, indent=2, ensure_ascii=False) + "\n")
    return f

def show(game):
    p = profiles_db.by_key(game)
    if not p: sys.exit(f"{game}: no profile")
    runs = os.path.join(REPO, "runs")
    tests = sorted(d for d in os.listdir(runs) if d.endswith(f"-playtest-{p['key']}")) if os.path.isdir(runs) else []
    for d in tests:
        r = json.load(open(os.path.join(runs, d, "playtest.json")))
        print(f"{d}: dev_host_ok {r['verdict']['dev_host_ok']}, {r['minutes']} min, {len(r['problems'])} problems"
              + (f", reached: {r['answers'].get('reached')}" if r.get("answers") else ""))
        for pr in r["problems"][:8]:
            print(f"   - {pr['what']}" + (f" at {pr['at_s']} s" if isinstance(pr.get('at_s'), (int, float)) else "") + (f": {pr['note']}" if pr.get("note") else ""))
    if not tests: print("no playtests yet")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game", nargs="?")
    ap.add_argument("--minutes", type=float, default=10.0, help="the shortest session that can count as dev_host_ok")
    ap.add_argument("--saves-dir", help="saves directory (default: the launcher's, i.e. build/private/saves/611670: the player's own)")
    ap.add_argument("--show", action="store_true"); ap.add_argument("--apply", metavar="RUN_DIR")
    a = ap.parse_args()
    if a.apply:
        print(f"written: {os.path.relpath(apply(a.apply), REPO)}"); return
    if not a.game:
        ap.error("which game? (tools/vxrt_run.py --list)")
    if a.show:
        show(a.game); return
    r = playtest(a.game, a.minutes, a.saves_dir)
    v = r["verdict"]
    print(f"\n{r['playtest_id']}: dev_host_ok {v['dev_host_ok']} ({r['minutes']} min); not a playable verdict")
    for k, ok in v.items():
        if k != "dev_host_ok": print(f"  {k}: {'yes' if ok else 'NO'}")
    for pr in r["problems"]:
        print(f"  problem: {pr['what']}" + (f" at {pr['at_s']} s" if isinstance(pr.get('at_s'), (int, float)) else ""))
    print(f"  record: runs/{r['playtest_id']}/playtest.json  (tools/vxrt_playtest.py --apply runs/{r['playtest_id']} puts it in the profile)")

if __name__ == "__main__":
    main()
