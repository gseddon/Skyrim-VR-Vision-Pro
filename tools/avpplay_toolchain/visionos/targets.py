#!/usr/bin/env python3
"""The targets this toolchain builds, in the shape AVP Play reads (it parses TARGETS with `ast`, plain strings only,
and calls `targets.py <target> <key>` for single values).

    targets.py skyrimvr kind          vxruntime
    targets.py skyrimvr bundle        <user>.dev.klepton.target.skyrimvr   (AVP Play's default naming)
    targets.py skyrimvr devicetree    Documents/root/SkyrimVR

`kind` "vxruntime" tells AVP Play that this is not a Klepton (Android or Linux) target: the game is a Windows
program, recompiled ahead of time on the Mac (tools/vxrt_build.py). Runs with the Python that comes with Xcode (3.9).
"""
import getpass
import re
import sys

TARGETS = {
    "skyrimvr": {
        "kind": "vxruntime",
        "display": "Skyrim VR",
        # Where stage_sync.py puts the game tree in the app's data container, and where the game keeps what it
        # writes (saves, settings): AVP Play reads these two to show progress and to find the saved games.
        "devicetree": "Documents/root/SkyrimVR",
        "saves": "Documents/root/overlay_skyrimvr",
    },
}


def bundle_scope(user):
    """The user name as AVP Play puts it in front of a bundle id (BundleNaming.swift, bundleScope)."""
    return re.sub(r"[^A-Za-z0-9-]", "-", user).strip("-").lower()


def bundle_for(target, user=None):
    scope = bundle_scope(user or getpass.getuser())
    return ".".join(p for p in (scope, "dev.klepton.target", target) if p)


def resolve(target):
    if target not in TARGETS:
        raise KeyError(target)
    row = dict(TARGETS[target], name=target)
    row["bundle"] = bundle_for(target)
    return row


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        row = resolve(argv[1])
    except KeyError:
        return 1
    value = row.get(argv[2])
    if not isinstance(value, str) or not value:
        return 1
    print(value)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
