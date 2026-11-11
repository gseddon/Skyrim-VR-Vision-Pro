"""Where the Skyrim VR path finds its private inputs: one place for the defaults, the pins and the local wrapper.

Nothing here is personal. A person's settings (Apple team, bundle prefix, device id, where their game and toolchain
live) go in the git-ignored local/env.sh (copy local.example.sh); `load_local_env` reads it. Everything derived from the
player's game lives under one private root: VXRT_PRIVATE_ROOT, default <checkout>/build/private. See docs/SETUP_SKYRIM.md.
"""
import os
from pathlib import Path
import re
import subprocess

REPO = Path(__file__).resolve().parents[1]

# The pinned game identity: the Steam build of SkyrimVR.exe (Steam depot, SteamStub 3.1) and what Steamless 3.1.0.x
# (upstream commit STEAMLESS_COMMIT) makes of it (research/2026-11-08-skyrim-preparation.md).
ORIGINAL_EXE_SHA256 = '6961efb4f4775a307b0fc9a3d637542c1e090be207d3b09467eab216b7f87971'
PREPARED_EXE_SHA256 = '8daf05196ecad57963be61614ce4a4cd5c4dc27d222db14e01c262b36b3d46d4'
STEAMLESS_COMMIT = 'cd770bf9749d3e4f438d23ac643917ad1a804257'
SPLITS_NAME = 'splits-1022-at-0x140000000.txt'
SPLITS_SHA256 = '46e8ff7d13cd2968763b14acea1ebbf0a297519911063a890fad20d8838766c9'    # the profile committed in tools/profiles (the 1022-address profile of the earlier builds plus a 600 s recording); yours is pinned in <file>.sha256 by tools/skyrim_splits.py


def private_root(env=None):
    env = os.environ if env is None else env
    return Path(env.get('VXRT_PRIVATE_ROOT') or REPO / 'build' / 'private').expanduser().resolve()


def skyrim_dir(env=None):
    """<private>/skyrimvr/<original exe sha>: the prepared exe, the redistributable DLLs and the pipeline's inputs."""
    env = os.environ if env is None else env
    return Path(env.get('VXRT_SKYRIM_DIR') or private_root(env) / 'skyrimvr' / ORIGINAL_EXE_SHA256).expanduser()


def variables(env=None):
    """The ${NAME} substitutions of the pipeline config, with their defaults; None for a variable that has none."""
    env = os.environ if env is None else env
    sk = skyrim_dir(env)
    inputs = Path(env.get('VXRT_AOT_INPUTS') or sk / 'inputs')
    redist = Path(env.get('VXRT_REDIST_DIR') or sk / 'redist')
    splits = Path(env.get('VXRT_SPLITS_FILE') or inputs / SPLITS_NAME)
    side = splits.with_name(splits.name + '.sha256')
    return {
        'VXRT_SPLITS_SHA256': env.get('VXRT_SPLITS_SHA256') or (side.read_text().split()[0] if side.is_file() else SPLITS_SHA256),
        'REPO': str(REPO),
        'XRIZER_RUST_ROOT': env.get('XRIZER_RUST_ROOT') or str(REPO / 'build' / 'toolchains' / 'xrizer-rust'),
        'VXRT_PRIVATE_ROOT': str(private_root(env)),
        'VXRT_SKYRIM_DIR': str(sk),
        'VXRT_AOT_INPUTS': str(inputs),
        'VXRT_REDIST_DIR': str(redist),
        'VXRT_PREPARED_EXE': env.get('VXRT_PREPARED_EXE') or str(sk / 'prepared' / 'SkyrimVR.exe'),
        'VXRT_SPLITS_FILE': env.get('VXRT_SPLITS_FILE') or str(inputs / SPLITS_NAME),
        'SKYRIM_ASSET_ROOT': env.get('SKYRIM_ASSET_ROOT') or None,
        'STEAMVR_WIN64_DLLS': env.get('STEAMVR_WIN64_DLLS') or None,
    }


class Unset(ValueError):
    """A ${NAME} in a config has no value."""
    def __init__(self, name):
        super().__init__('%s is not set (export it, or put it in local/env.sh; docs/SETUP_SKYRIM.md)' % name)
        self.name = name


def expand(text, env=None):
    vals = variables(env)

    def one(m):
        v = vals.get(m.group(1))
        if v is None:
            raise Unset(m.group(1))
        return v
    return re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', one, text)


def load_local_env(path=None, env=None):
    """Variables the local wrapper (a shell file; default $VXRT_LOCAL_ENV or <checkout>/local/env.sh) exports.
    Returns {name: value} for what it adds or changes; {} when there is no wrapper. Sourced by bash with `set -a`."""
    env = dict(os.environ if env is None else env)
    path = Path(path or env.get('VXRT_LOCAL_ENV') or REPO / 'local' / 'env.sh')
    if not path.is_file():
        return {}
    r = subprocess.run(['bash', '-c', 'set -a; . "$1" >/dev/null; env -0', 'bash', str(path)], env=env,
                       capture_output=True)
    if r.returncode:
        raise ValueError('%s failed: %s' % (path, r.stderr.decode(errors='replace').strip()))
    got = dict(item.split('=', 1) for item in r.stdout.decode(errors='replace').split('\0') if '=' in item)
    skip = {'_', 'SHLVL', 'PWD', 'OLDPWD'}
    return {k: v for k, v in got.items() if k not in skip and env.get(k) != v}


def sha256_file(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()
