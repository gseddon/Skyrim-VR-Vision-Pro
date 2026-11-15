#!/usr/bin/env python3
"""Put the Skyrim VR game tree into the app's data container on the Vision Pro, the way AVP Play asks a toolchain to.

    stage_sync.py --phase all --device <udid> --dry-run    build the mirror, say what it holds
    stage_sync.py --phase all --device <udid>              build the mirror and copy it

AVP Play (Installer.swift, the tree sync) runs the dry run first, lists the mirror to know how much belongs on the
headset, then runs the copy, up to six times when the connection drops. Environment:

    KLEPTON_TARGET      skyrimvr
    KLEPTON_BUNDLE_ID   the app's bundle id (default: targets.py's `bundle`)
    KL_LX_GAME          the SkyrimVR folder (read only)
    KL_LX_MIRROR        where the mirror goes: a directory of its own, emptied and filled here
                        (default visionos/build/lxstage/<target>/lx)

The mirror is a tree of hard links (no space, no copying) of exactly what the app reads from
Documents/root/SkyrimVR: Data/, the .ini files, the PREPARED SkyrimVR.exe (the one the compiled modules were made
from; the game's code runs from the signed app, the exe is data for the image mapping) and the DLLs the exe loads
(tools/skyrim_device_stage.py, plan). A hard link cannot leave its volume: what lies on another volume than the
mirror (the prepared exe and the DLLs, a few dozen MB) is copied.

`devicectl device copy to` skips files that are already there unchanged, so an interrupted run is resumed by
running it again; nothing on the headset is deleted. Runs with the Python that comes with Xcode (3.9).
"""
import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import targets as targets_mod       # noqa: E402
import vx_paths                     # noqa: E402

PATHS = vx_paths.apply()
os.environ.setdefault("VXRT_LOCAL_ENV", "/dev/null")
sys.path.insert(0, str(pathlib.Path(PATHS["REPO"]) / "tools"))
import skyrim_device_stage as S     # noqa: E402
import vxrt_env as E                # noqa: E402


def link(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(src, dst)
    except OSError:
        shutil.copyfile(src, dst)


def build_mirror(game, mirror):
    """{relative path: size} of what was put into the mirror."""
    v = E.variables()
    files = S.plan(game, v["VXRT_PREPARED_EXE"], v["VXRT_AOT_INPUTS"], v["VXRT_REDIST_DIR"])
    shutil.rmtree(mirror, ignore_errors=True)
    mirror.mkdir(parents=True)
    sizes = {}
    for rel, src in files.items():
        link(src, mirror / rel)
        sizes[rel] = src.stat().st_size
    return sizes


def copy(device, bundle, source, destination):
    return subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", device,
                           "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                           "--source", str(source), "--destination", destination]).returncode


def parts_of(mirror):
    """What goes in one devicectl call each: the loose files first, then Data's own files, then each folder of Data,
    so that an interrupted run has finished whole parts and the long ones come last."""
    loose = sorted(p.name for p in mirror.iterdir() if p.is_file())
    data = mirror / "Data"
    inside = sorted(("Data/" + p.name for p in data.iterdir()), key=lambda r: ((mirror / r).is_dir(), r)) if data.is_dir() else []
    other = sorted(p.name for p in mirror.iterdir() if p.is_dir() and p.name != "Data")
    return loose + other + inside


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--phase", choices=("base", "start", "all"), default="all")
    ap.add_argument("--device")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    try:
        row = targets_mod.resolve(os.environ.get("KLEPTON_TARGET") or "skyrimvr")
    except KeyError as e:
        print("!! this toolchain has no target %s" % e, file=sys.stderr)
        return 1
    bundle = os.environ.get("KLEPTON_BUNDLE_ID") or row["bundle"]
    dest = row["devicetree"]
    game = os.environ.get("KL_LX_GAME") or ""
    if not (pathlib.Path(game) / "Data").is_dir():
        print("!! KL_LX_GAME does not point at a SkyrimVR folder (no Data/ in '%s')" % game, file=sys.stderr)
        return 1
    mirror = HERE / "build" / "lxstage" / row["name"] / "lx"
    if os.environ.get("KL_LX_MIRROR"):
        mirror = pathlib.Path(os.environ["KL_LX_MIRROR"])

    try:
        sizes = build_mirror(game, mirror)
    except S.Missing as e:
        print("!! %s" % e, file=sys.stderr)
        return 1
    print("[stage] %d files, %.1f GB -> %s" % (len(sizes), sum(sizes.values()) / 2**30, dest))
    if args.dry_run:
        print("[stage] dry run - the mirror is at %s" % mirror)
        return 0

    device = args.device or os.environ.get("KLEPTON_DEVICE")
    if not device:
        print("!! no physical Vision Pro - pass --device", file=sys.stderr)
        return 1
    t0 = time.time()
    for part in parts_of(mirror):
        print("[stage] -> %s/%s" % (dest, part), flush=True)
        if copy(device, bundle, mirror / part, "%s/%s" % (dest, part)) != 0:
            print("!! staging %s failed - run this again to resume" % part, file=sys.stderr)
            return 1
    print("[stage] done in %.0f s" % (time.time() - t0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
