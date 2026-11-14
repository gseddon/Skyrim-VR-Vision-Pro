#!/usr/bin/env python3
"""Get the files of the chosen mod sets onto this Mac, the way AVP Play asks a toolchain to before it builds with mods.

    KLEPTON_GAME_MODS=core,skyland mods_fetch.py          fetch what is missing, then exit 0
    mods_fetch.py --check                                 only say what is missing (exit 0: nothing, 3: something)

AVP Play runs this before `run.sh device` when the player switched mods on, reads its standard output line by line
while it runs, and shows these lines in its own words (every other line is for the log):

    @@mods total|<n>                      n files belong to the chosen sets
    @@mods have|<name>|<how>              one is there (kept from before, picked up from Downloads, downloaded with the key)
    @@mods need|<name>|<page>             the player's turn: the page was opened in the browser, the Downloads folder is watched
    @@mods progress|<name>|<here>|<all>   a download with the key: bytes here and in all (0: not known), about once a second
    @@mods done|<n>                       all there
    !! mods: <why>                        it stopped (exit 1 failed, 2 the player did not download a file in time)

Ended with SIGTERM (the player cancelled) it ends the fetch it started and exits 130 without a further line.

The files come from Nexus Mods under the player's own account and its terms (personal use; nothing is redistributed),
and SKSE VR from its authors' site. Without a key each page is opened in the browser (VXRT_NEXUS_OPEN) and the
archive is taken from the Downloads folder once it is complete and has the pinned md5; with NEXUS_API_KEY in the
environment (a Premium account's personal API key, which AVP Play keeps in the Keychain and hands over only here) the
project's client downloads them. The key is never printed. KLEPTON_MODS_WAIT: seconds to wait for each download
(default 900). Runs with the Python that comes with Xcode (3.9).
"""
import os
import pathlib
import signal
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vx_mods                      # noqa: E402
import vx_paths                     # noqa: E402


def out(line):
    print(line, flush=True)


def main(argv):
    check = "--check" in argv[1:]
    paths = vx_paths.apply()
    try:
        sets = vx_mods.chosen()
    except ValueError as e:
        out("!! mods: %s" % e)
        return 1
    if not sets:
        out("@@mods total|0")
        out("@@mods done|0")
        return 0
    lst, _ = vx_mods.write_list(sets, paths)
    import json
    doc = json.loads(lst.read_text())
    wanted = [m for m in doc["mods"] if m.get("enabled") and ("nexus" in m or "external" in m)]
    # (two entries of the list come out of one archive, SKSE VR's: the player sees it once)
    names, by_id = [], {}
    for m in wanted:
        key = (m.get("external") or {}).get("md5") or m["id"]
        if key not in [k for k, _ in names]:
            names.append((key, m.get("name") or m["id"]))
        by_id[m["id"]] = dict(names)[key]                # (the name the player sees for this entry)
    out("@@mods total|%d" % len(names))
    try:
        wait = max(0, int(os.environ.get("KLEPTON_MODS_WAIT") or 900))
    except ValueError:
        wait = 900
    env = dict(os.environ, VXRT_LOCAL_ENV="/dev/null", VXRT_NEXUS_EVENTS="1", PYTHONUNBUFFERED="1")
    if not check:
        env["VXRT_NEXUS_OPEN"] = "1"
    cmd = [sys.executable, "-I", str(pathlib.Path(paths["REPO"]) / "tools" / "mods.py"), "fetch", "--list", str(lst), "--wait", str(0 if check else wait)]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env, text=True, errors="replace")

    def stop(signum, frame):                    # the player cancelled (AVP Play ends this script): end the fetch it started too
        try:
            p.terminate()
        except OSError:
            pass
        os._exit(130)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)
    have, seen, missing, last_need = 0, set(), [], None
    for line in p.stdout:
        line = line.rstrip("\n")
        if line.startswith("@@nexus "):
            kind, _, rest = line[8:].partition("|")
            name, _, detail = rest.partition("|")
            if kind == "have" and name not in seen:
                seen.add(name); have += 1
                out("@@mods have|%s|%s" % (name, detail))
            elif kind == "progress":
                got, _, total = detail.partition(" ")
                if not check and got.isdigit():
                    out("@@mods progress|%s|%s|%s" % (name, got, total if total.isdigit() else "0"))
            elif kind == "need":
                last_need = name
                if not check:
                    out("@@mods need|%s|%s" % (name, detail))
            continue
        out(line)
        if "cannot read the downloads folder" in line:
            p.terminate(); p.wait()
            out("!! mods: this Mac does not let the installer read your Downloads folder. Allow it under System Settings > Privacy & Security > Files and Folders, then start again.")
            return 1
        gone = "no matching archive appeared" in line or "no archive with md5" in line
        if gone:
            who = line.split(":", 1)[0].strip()
            missing.append(by_id.get(who) or last_need or who)
            if not check:                              # the player did not download this one: do not open the next pages
                p.terminate()
                break
    rc = p.wait()
    if check:
        for m in dict.fromkeys(missing):
            out("@@mods missing|%s" % m)
        return 3 if missing or rc not in (0,) else 0
    if missing:
        out("!! mods: %s was not downloaded within %d minutes. Start the installation again when you are ready; what is already here is kept." % (missing[0], max(1, wait // 60)))
        return 2
    if rc != 0:
        out("!! mods: fetching the mod files failed (see the lines above)")
        return 1 if rc != 2 else 2
    out("@@mods done|%d" % len(names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
