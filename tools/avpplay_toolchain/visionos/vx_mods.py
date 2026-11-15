#!/usr/bin/env python3
"""The mods this toolchain can build Skyrim VR with, for run.sh, mods_fetch.py and stage_sync.py (one rule for all three).

AVP Play's switch is KLEPTON_GAME_MODS: a comma-separated list of the set ids of mods.json ("core", "skyland"), empty or
unset for the plain game. A set is a group of entries of the project's own mod list (mods/default.json: names,
versions, Nexus ids, md5s; no mod files). The list the stages work from is that file with exactly the chosen sets'
entries enabled, written to <private root>/avpplay/mods-list.json.

    vx_mods.py sets            the chosen sets, one per line (what KLEPTON_GAME_MODS means here)
    vx_mods.py list            writes the list and prints its path
    vx_mods.py state           what the last build was made with (run.sh records it; stage_sync.py reads it)

Runs with the Python that comes with Xcode (3.9).
"""
import hashlib
import json
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vx_paths                     # noqa: E402

VARIABLE = "KLEPTON_GAME_MODS"


def description():
    return json.loads((HERE / "mods.json").read_text())


def known_sets():
    return {s["id"]: s for s in description()["sets"]}


def chosen(env=None):
    """The chosen set ids, in mods.json's order; an id this toolchain does not have is an error (ValueError)."""
    env = os.environ if env is None else env
    asked = [x.strip() for x in (env.get(VARIABLE) or "").split(",") if x.strip()]
    known = known_sets()
    bad = [x for x in asked if x not in known]
    if bad:
        raise ValueError("this toolchain has no mod set %s (it has: %s)" % (", ".join(bad), ", ".join(known)))
    return [k for k in known if k in asked]


def work_dir(paths=None):
    p = paths or vx_paths.paths()
    return pathlib.Path(p["VXRT_PRIVATE_ROOT"]) / "avpplay"


def pack_dir(paths=None):
    """Where the project's stages build and look for the mod pack (tools/vxrt_build.py: mods, skse-capture, app)."""
    p = paths or vx_paths.paths()
    return pathlib.Path(p["VXRT_PRIVATE_ROOT"]) / "mods-pack"


def write_list(sets, paths=None):
    """The project's default list with the chosen sets' entries enabled and every other entry disabled. Returns
    (path, sha256 of its text). The file is rewritten only when its text changes, md5s pinned by a fetch are kept."""
    p = paths or vx_paths.paths()
    source = pathlib.Path(p["REPO"]) / "mods" / "default.json"
    doc = json.loads(source.read_text())
    known = known_sets()
    on = set()
    for s in sets:
        on.update(known[s]["entries"])
    listed = set()
    for s in known.values():
        listed.update(s["entries"])
    out = work_dir(p) / "mods-list.json"
    old = {}
    if out.is_file():
        try:
            old = {m["id"]: m for m in json.loads(out.read_text()).get("mods", [])}
        except (ValueError, KeyError, TypeError):
            old = {}
    for m in doc["mods"]:
        m["enabled"] = m["id"] in on
        if m["id"] not in listed:
            m["enabled"] = False                     # (the project's diagnostic entries stay off)
        pinned = (old.get(m["id"]) or {}).get("nexus") or {}
        if "nexus" in m and not m["nexus"].get("md5") and pinned.get("md5"):
            m["nexus"]["md5"] = pinned["md5"]
    doc["profile"] = "avpplay-" + ("-".join(sets) or "none")
    doc["comment"] = ["Written by tools/avpplay_toolchain/visionos/vx_mods.py from mods/default.json for AVP Play's mod sets: %s." % (", ".join(sets) or "none")]
    text = json.dumps(doc, indent=1) + "\n"
    out.parent.mkdir(parents=True, exist_ok=True)
    if not out.is_file() or out.read_text() != text:
        tmp = out.with_name(out.name + ".tmp")
        tmp.write_text(text)
        os.replace(tmp, out)
    return out, hashlib.sha256(text.encode()).hexdigest()


def state_path(paths=None):
    return work_dir(paths) / "mods-state.json"


def read_state(paths=None):
    """{"sets": [...], "list_sha256": ...} of the last build, or {"sets": []} when there was none with mods."""
    try:
        d = json.loads(state_path(paths).read_text())
        return d if isinstance(d.get("sets"), list) else {"sets": []}
    except (OSError, ValueError):
        return {"sets": []}


def write_state(sets, list_sha, paths=None):
    f = state_path(paths)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps({"sets": list(sets), "list_sha256": list_sha}, indent=1) + "\n")


def main(argv):
    if len(argv) != 2 or argv[1] not in ("sets", "list", "state"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        sets = chosen()
    except ValueError as e:
        print("!! mods: %s" % e, file=sys.stderr)
        return 1
    if argv[1] == "sets":
        print("\n".join(sets))
    elif argv[1] == "list":
        print(write_list(sets)[0])
    else:
        print(json.dumps(read_state()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
