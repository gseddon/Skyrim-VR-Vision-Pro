#!/usr/bin/env python3
"""Game profiles: games/<Steam app id>.json (today: games/611670.json, Skyrim VR). A profile says how tools/vxrt_run.py
runs the game (its scenarios, seconds), the frozen baselines, what is known about it and, once confirmed, the settings
tuned for a Mac. The harness, the MCP server, the tuner and the playtest read them.

    tools/vxrt_games.py check          # every profile against the rules below (make check runs it)
    tools/vxrt_games.py list
"""
import json, os, re, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAMES_DIR = os.path.join(REPO, "games")
BASELINE_FIELDS = {"min_pairs_per_s": (int, float), "zero_fallback": bool, "non_black": bool}

def problems(profile, filename=None):
    """What is wrong with a profile."""
    out = []
    def need(obj, key, kind, at):
        if not isinstance(obj, dict) or not isinstance(obj.get(key), kind) or isinstance(obj.get(key), bool) and kind is not bool:
            out.append(f"{at}.{key}: missing or not {kind.__name__ if isinstance(kind, type) else kind}")
            return False
        return True
    for key, kind in (("appid", str), ("key", str), ("name", str), ("launcher", str), ("default_scenario", str),
                      ("scenarios", dict), ("status", dict), ("baselines", dict), ("known_issues", list), ("notes", list)):
        need(profile, key, kind, "$")
    if out:
        return out
    if not re.fullmatch(r"[0-9]+", profile["appid"]):
        out.append("appid: digits only")
    if filename and os.path.splitext(os.path.basename(filename))[0] != profile["appid"]:
        out.append(f"the file should be named {profile['appid']}.json")
    if not profile["scenarios"]:
        out.append("scenarios: needs at least one")
    for name, sc in profile["scenarios"].items():
        if not need(sc, "seconds", (int, float), f"scenarios.{name}") or not 10 <= sc["seconds"] <= 3600:
            out.append(f"scenarios.{name}.seconds: 10..3600")
        if "helgen" in sc and not isinstance(sc["helgen"], bool):
            out.append(f"scenarios.{name}.helgen: boolean")
    if profile["default_scenario"] not in profile["scenarios"]:
        out.append(f"default_scenario {profile['default_scenario']!r} is not in scenarios")
    st = profile["status"]
    need(st, "state", str, "status")
    if not isinstance(st.get("summary"), dict) or not isinstance(st["summary"].get("en"), str):
        out.append("status.summary.en: missing")
    for name, base in profile["baselines"].items():
        if name not in profile["scenarios"]:
            out.append(f"baseline {name!r}: no such scenario")
        for field, value in (base or {}).items():
            kind = BASELINE_FIELDS.get(field)
            if kind is None or not isinstance(value, kind):
                out.append(f"baseline {name!r}: unknown or mistyped field {field}")
    for i, k in enumerate(profile["known_issues"]):
        if not isinstance(k, dict) or not isinstance(k.get("summary"), str):
            out.append(f"known_issues[{i}].summary: missing")
    return out

def load_all():
    """{app id: profile} of every valid profile; invalid ones are left out (check reports them)."""
    out = {}
    if not os.path.isdir(GAMES_DIR):
        return out
    for f in sorted(os.listdir(GAMES_DIR)):
        if not re.match(r"[0-9]+\.json$", f):
            continue
        try:
            p = json.load(open(os.path.join(GAMES_DIR, f)))
        except ValueError:
            continue
        if not problems(p, f):
            out[p["appid"]] = p
    return out

def by_key(key):
    return next((p for p in load_all().values() if p["key"] == key or p["appid"] == key), None)

def main():
    if sys.argv[1:] == ["list"]:
        for p in load_all().values():
            print(f"{p['appid']:8} {p['key']:10} {p['status']['state']:9} {p['name']}  scenarios: {', '.join(p['scenarios'])}")
        return
    if sys.argv[1:] != ["check"]:
        sys.exit(__doc__)
    bad = 0
    for f in sorted(os.listdir(GAMES_DIR)) if os.path.isdir(GAMES_DIR) else []:
        if not f.endswith(".json"):
            continue
        try:
            p = json.load(open(os.path.join(GAMES_DIR, f)))
        except ValueError as e:
            print(f"games/{f}: not JSON: {e}"); bad += 1; continue
        for msg in problems(p, f):
            print(f"games/{f}: {msg}"); bad += 1
    keys = [p["key"] for p in load_all().values()]
    for k in {k for k in keys if keys.count(k) > 1}:
        print(f"key {k!r} is used by more than one profile"); bad += 1
    print(f"game profiles: {len(load_all())} valid, {bad} problems -> {'FAILED' if bad else 'ok'}")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
