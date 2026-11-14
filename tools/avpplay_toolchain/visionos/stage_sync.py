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
running it again; nothing on the headset is deleted.

Mods (vx_mods.py; KLEPTON_GAME_MODS at the build): after the game tree, the pack of the last build goes beside it
under Documents/root, straight from the pack (it is not part of the mirror): mods.json, Plugins.txt, the SKSE files
and the merged Data tree into the game's overlay, and mods-files.txt, the list of exactly the files this pack put
into the overlay. The app removes at its next start what an earlier list named and this one does not (devicectl
cannot delete; VXRuntime/xros/app/Sources/vx_prune.h), so a smaller pack, or none, leaves nothing of the larger one
behind. A build without mods sends an empty pack once, when this Mac put mods on that headset before.

Runs with the Python that comes with Xcode (3.9).
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
import vx_mods                      # noqa: E402
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


ROOT = "Documents/root"            # the runtime's root in the app's container: SkyrimVR/, overlay_skyrimvr/, drive_c/
PLUGINS_TXT = ROOT + "/drive_c/users/vxrt/AppData/Local/Skyrim VR/Plugins.txt"


def deployed_marker(device, bundle):
    safe = "".join(c if c.isalnum() or c in "-._" else "_" for c in "%s-%s" % (bundle, device))
    return vx_mods.work_dir(PATHS) / ("mods-deployed-%s.json" % safe)


def mods_plan(device, bundle):
    """What of the mods goes to the headset: (steps, bytes, sets), steps = [(source path, destination)] in the order they
    are copied. No steps when the last build had no mods and none were put on this headset from here."""
    import json
    sets = vx_mods.read_state(PATHS)["sets"]
    stage = vx_mods.work_dir(PATHS) / "deploy"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    listing = stage / "mods-files.txt"
    if not sets:
        if not deployed_marker(device or "", bundle).is_file():
            return [], 0, []
        # an empty pack: no plugin, no SKSE plugin, and a list that names nothing
        (stage / "mods.json").write_text(json.dumps(dict(version=1, profile="none", plugins=[], mods=[], skse_plugins=[], overlay_root_files=[]), indent=1))
        (stage / "Plugins.txt").write_bytes(b"")
        listing.write_bytes(b"")
        return [(stage / "mods.json", ROOT + "/mods.json"), (stage / "Plugins.txt", PLUGINS_TXT), (listing, ROOT + "/mods-files.txt")], 0, []
    pack = vx_mods.pack_dir(PATHS)
    doc = json.loads((pack / "mods.json").read_text())
    data = pack / "merged" / "Data"
    names, total = [], 0
    steps = [(pack / "mods.json", ROOT + "/mods.json"), (pack / "Plugins.txt", PLUGINS_TXT)]
    for f in doc.get("overlay_root_files", []):
        src = pack / "overlay_root" / f["name"]
        names.append(f["name"]); total += src.stat().st_size
        steps.append((src, "%s/overlay_skyrimvr/%s" % (ROOT, f["name"])))
    for q in sorted(data.rglob("*")):
        if q.is_file():
            names.append("Data/" + q.relative_to(data).as_posix()); total += q.stat().st_size
    for e in sorted(data.iterdir(), key=lambda q: (q.is_dir(), q.name)):
        steps.append((e, "%s/overlay_skyrimvr/Data/%s" % (ROOT, e.name)))
    listing.write_text("".join(n + "\n" for n in names))
    steps.append((listing, ROOT + "/mods-files.txt"))      # last: the list is true once its files are there
    return steps, total, sets


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
    device = args.device or os.environ.get("KLEPTON_DEVICE")
    try:
        mod_steps, mod_bytes, mod_sets = mods_plan(device, bundle)
    except (OSError, ValueError, KeyError) as e:
        print("!! the mod pack of the last build cannot be read (%s) - build again" % e, file=sys.stderr)
        return 1
    if mod_steps:
        print("[stage] mods (%s): %d parts, %.2f GB -> %s" % (", ".join(mod_sets) or "none any more", len(mod_steps), mod_bytes / 2**30, ROOT))
    if args.dry_run:
        print("[stage] dry run - the mirror is at %s" % mirror)
        return 0

    if not device:
        print("!! no physical Vision Pro - pass --device", file=sys.stderr)
        return 1
    t0 = time.time()
    for part in parts_of(mirror):
        print("[stage] -> %s/%s" % (dest, part), flush=True)
        if copy(device, bundle, mirror / part, "%s/%s" % (dest, part)) != 0:
            print("!! staging %s failed - run this again to resume" % part, file=sys.stderr)
            return 1
    for src, to in mod_steps:
        print("[stage] -> %s" % to, flush=True)
        if copy(device, bundle, src, to) != 0:
            print("!! staging the mods failed at %s - run this again to resume" % to, file=sys.stderr)
            return 1
    if mod_steps:
        marker = deployed_marker(device, bundle)
        if mod_sets:
            marker.write_text('{"sets": ["%s"]}\n' % '", "'.join(mod_sets))
        else:
            marker.unlink(missing_ok=True) if sys.version_info >= (3, 8) else None
    print("[stage] done in %.0f s" % (time.time() - t0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
