#!/usr/bin/env python3
"""Write toolchain.json, the description AVP Play reads of a toolchain (ToolchainPackage.swift, ToolchainManifest):

    tools/avpplay_toolchain/make_manifest.py            from this checkout's git state
    tools/avpplay_toolchain/make_manifest.py --check    say whether the file matches the checkout (exit 1 if not)

`version` is the number of commits (a larger number is newer; AVP Play stamps it into the built app, and offers an
update when a newer toolchain is installed), `commit` the short hash, `ancestors` every state this one contains
(a recipe's `toolchain.minCommit` is looked up there). `modified` is set when the checkout has uncommitted changes
to tracked files: then it is not a published state, and AVP Play says so wherever it names it.

The file is git-ignored: it describes one state, and is written when a package is made or a checkout is used as
a toolchain. Runs with the Python that comes with Xcode (3.9).
"""
import datetime
import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT = HERE / "toolchain.json"


def git(*args):
    return subprocess.run(["/usr/bin/git", "-C", str(REPO)] + list(args), check=True, capture_output=True, text=True).stdout


def describe():
    ancestors = git("rev-list", "--abbrev-commit", "--abbrev=7", "HEAD").split()
    dirty = bool(git("status", "--porcelain", "--untracked-files=no").strip())
    m = {"format": 1, "kind": "vxruntime", "version": len(ancestors), "commit": ancestors[0], "ancestors": ancestors,
         "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
         "appRevision": len(ancestors)}
    if dirty:
        m["modified"] = True
    return m


def main(argv):
    want = describe()
    if "--check" in argv:
        try:
            have = json.loads(OUT.read_text())
        except (OSError, ValueError):
            print("toolchain.json is missing or unreadable")
            return 1
        same = all(have.get(k) == want.get(k) for k in ("version", "commit", "modified"))
        print("toolchain.json %s (%s, %s%s)" % ("matches" if same else "is stale", want["version"], want["commit"],
                                                ", modified" if want.get("modified") else ""))
        return 0 if same else 1
    OUT.write_text(json.dumps(want, indent=1) + "\n")
    print("%s: %s %s%s" % (OUT, want["version"], want["commit"], " (modified)" if want.get("modified") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
