#!/usr/bin/env python3
"""Where this toolchain keeps things, for run.sh and stage_sync.py (one rule, so both agree).

    vx_paths.py            prints shell assignments: REPO, TOOLCHAIN, VXRT_PRIVATE_ROOT, XRIZER_RUST_ROOT

The repository is two levels above this toolchain folder (tools/avpplay_toolchain). Everything derived from the
player's game goes under VXRT_PRIVATE_ROOT (docs/SETUP_SKYRIM.md):

  * set in the environment: used as it is;
  * a full git checkout (someone working on the project): the project's default, <checkout>/build/private, so the
    stages run by hand and the ones AVP Play runs share their results;
  * anything else - the single commit AVP Play fetches for a recipe (a shallow repository), or an unpacked archive:
    ~/.avpplay/vxruntime/private, outside the toolchain's folder, so a newer state of the toolchain does not have
    to translate the game again (about 40 GB live there; the path has no blanks, which make does not survive).

Runs with the Python that comes with Xcode (3.9).
"""
import os
import pathlib
import shlex
import sys

HERE = pathlib.Path(__file__).resolve().parent
TOOLCHAIN = HERE.parent
REPO = TOOLCHAIN.parent.parent


def state_root():
    return pathlib.Path(os.environ.get("AVPPLAY_VXRT_STATE") or pathlib.Path.home() / ".avpplay" / "vxruntime")


def paths(env=None):
    env = os.environ if env is None else env
    checkout = (REPO / ".git").exists() and not (REPO / ".git" / "shallow").exists()
    private = env.get("VXRT_PRIVATE_ROOT") or (str(REPO / "build" / "private") if checkout else str(state_root() / "private"))
    rust = env.get("XRIZER_RUST_ROOT") or (str(REPO / "build" / "toolchains" / "xrizer-rust") if checkout
                                            else str(state_root() / "xrizer-rust"))
    return {"REPO": str(REPO), "TOOLCHAIN": str(TOOLCHAIN), "VXRT_PRIVATE_ROOT": private, "XRIZER_RUST_ROOT": rust}


def apply(env=None):
    """Put the paths into the environment (for the project's own tools, which read them there)."""
    p = paths(env)
    os.environ["VXRT_PRIVATE_ROOT"] = p["VXRT_PRIVATE_ROOT"]
    os.environ["XRIZER_RUST_ROOT"] = p["XRIZER_RUST_ROOT"]
    return p


if __name__ == "__main__":
    for k, v in paths().items():
        print("%s=%s" % (k, shlex.quote(v)))
    sys.exit(0)
