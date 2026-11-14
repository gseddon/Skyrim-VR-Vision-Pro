#!/usr/bin/env python3
"""Prepare the player's own SkyrimVR.exe for the AOT pipeline: remove the SteamStub wrapper with Steamless, check the
result against the pinned hash, and collect the pipeline's input DLLs.

    tools/skyrim_prepare.py status          what is there, what is missing (changes nothing)
    tools/skyrim_prepare.py fetch-tools     download Steamless (source) and the .NET SDK into <private root>/skyrim-tools and
                                            build Steamless (prints what it downloads and goes ahead;
                                            --confirm asks first). The only step that downloads.
    tools/skyrim_prepare.py unpack          copy SKYRIM_ASSET_ROOT/SkyrimVR.exe, unpack the copy, verify, install as
                                            <skyrim dir>/prepared/SkyrimVR.exe
    tools/skyrim_prepare.py inputs          copy binkw64/openvr_api/steam_api64 (game folder) and msvcp140 (SteamVR's
                                            bin/vrwebhelper/win64) to <skyrim dir>/inputs, and the d3dx9_42 / X3DAudio1_7
                                            redistributables to <skyrim dir>/redist; every file is checked against the pins
                                            in tools/skyrim_aot_skyrimvr.json
    tools/skyrim_prepare.py all             unpack, then inputs

Inputs: SKYRIM_ASSET_ROOT (the folder with SkyrimVR.exe; read only), STEAMVR_WIN64_DLLS, VXRT_PRIVATE_ROOT (default
build/private). The original game folder is never written. The input must be exactly the pinned Steam build
(vxrt_env.ORIGINAL_EXE_SHA256) or the script refuses; the unpacked result must be exactly the pinned hash
(PREPARED_EXE_SHA256) before it is installed, because the pipeline's modules are keyed by it. A different Steamless build or
.NET runtime that gives another hash is kept under prepared-unverified/ and reported, never used.

Tools. Steamless (https://github.com/atom0s/Steamless, commit vxrt_env.STEAMLESS_COMMIT, CC BY-NC-ND 4.0) is built
here, unmodified, for your own use, from its source with generated SDK-style projects for .NET 8 (the original projects
target .NET Framework 4.5.2 with Windows UI; the UI-only ViewModelBase.cs and NavigatedEventArgs.cs are left out, the
CLI's checksum option stays off). Nothing of it is committed or redistributed; it lives under the git-ignored private root.
The .NET SDK (8.0.427) is installed with Microsoft's dotnet-install.sh into the private root only, nothing global.
The generated projects follow research/2026-11-08-skyrim-preparation.md and have not been run by a fresh clone yet: if the
Steamless source layout differs, `fetch-tools` stops with the compiler's message.
Does not establish anything about the game itself: a prepared image is an input, not a result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vxrt_env as E

STEAMLESS_URL = 'https://github.com/atom0s/Steamless/archive/%s.tar.gz' % E.STEAMLESS_COMMIT
DOTNET_INSTALL_URL = 'https://dot.net/v1/dotnet-install.sh'
DOTNET_VERSION = '8.0.427'
UI_ONLY = {'ViewModelBase.cs', 'NavigatedEventArgs.cs'}
CONFIG = E.REPO / 'tools' / 'skyrim_aot_skyrimvr.json'


class Refuse(Exception):
    pass


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def tools_dir():
    return E.private_root() / 'skyrim-tools'


def dotnet():
    return tools_dir() / 'dotnet' / 'dotnet'


def tool_env():
    t = tools_dir()
    env = dict(os.environ, DOTNET_CLI_HOME=str(t / 'home'), NUGET_PACKAGES=str(t / 'nuget'), TMPDIR=str(t / 'tmp'),
               DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1', DOTNET_ROOT=str(t / 'dotnet'))
    for k in ('DOTNET_CLI_HOME', 'TMPDIR'):
        Path(env[k]).mkdir(parents=True, exist_ok=True)
    return env


def asset_exe():
    root = os.environ.get('SKYRIM_ASSET_ROOT')
    if not root:
        raise Refuse('SKYRIM_ASSET_ROOT is not set: point it at the folder holding your SkyrimVR.exe (local/env.sh)')
    exe = Path(root) / 'SkyrimVR.exe'
    if not exe.is_file():
        raise Refuse('no SkyrimVR.exe in %s' % root)
    return exe


def steamless_cli():
    return tools_dir() / 'steamless-bin' / 'Steamless.CLI.dll'


def csproj(name, refs=(), extra=''):
    items = ''.join('    <ProjectReference Include="%s" />\n' % r for r in refs)
    return ('<Project Sdk="Microsoft.NET.Sdk">\n  <PropertyGroup>\n    <TargetFramework>net8.0</TargetFramework>\n'
            '    <AssemblyName>%s</AssemblyName>\n    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>\n'
            '    <Nullable>disable</Nullable>\n    <ImplicitUsings>disable</ImplicitUsings>\n    <LangVersion>latest</LangVersion>\n'
            '    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>\n    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>\n'
            '    <NoWarn>SYSLIB0021;SYSLIB0022;CS8981</NoWarn>\n%s'
            '  </PropertyGroup>\n  <ItemGroup>\n    <Compile Include="**/*.cs" Exclude="obj/**;bin/**;%s" />\n%s'
            '  </ItemGroup>\n</Project>\n') % (name, extra, ';'.join('**/' + n for n in sorted(UI_ONLY)), items)


def fetch_tools(confirm=False):
    t = tools_dir()
    print('This downloads, into %s only:' % t)
    print('  1. %s   (Steamless source at the pinned commit; CC BY-NC-ND 4.0)' % STEAMLESS_URL)
    print('  2. %s   (Microsoft, MIT) and through it the .NET SDK %s for macOS arm64 (MIT)' % (DOTNET_INSTALL_URL, DOTNET_VERSION))
    print('  3. NuGet packages that restore pulls for the build, into %s' % (t / 'nuget'))
    if confirm and input('Download and build? [y/N] ').strip().lower() != 'y':
        raise Refuse('not confirmed')
    for d in ('src', 'tmp', 'home', 'nuget', 'steamless-bin'):
        (t / d).mkdir(parents=True, exist_ok=True)
    tarball = t / 'tmp' / 'steamless.tar.gz'
    run(['curl', '-fsSL', '-o', str(tarball), STEAMLESS_URL])
    src = t / 'src'
    shutil.rmtree(src); src.mkdir()
    run(['tar', '-xzf', str(tarball), '-C', str(src), '--strip-components=1'])
    meta = {'steamless_commit': E.STEAMLESS_COMMIT, 'steamless_tarball_sha256': sha(tarball), 'dotnet_version': DOTNET_VERSION}
    if not dotnet().is_file():
        script = t / 'tmp' / 'dotnet-install.sh'
        run(['curl', '-fsSL', '-o', str(script), DOTNET_INSTALL_URL])
        meta['dotnet_install_sh_sha256'] = sha(script)
        run(['bash', str(script), '--version', DOTNET_VERSION, '--install-dir', str(t / 'dotnet'), '--no-path'], env=tool_env())
    api = next(src.rglob('Steamless.API'), None)
    cli = next(src.rglob('Steamless.CLI'), None)
    plugins = sorted(p for p in src.rglob('Steamless.Unpacker.Variant3*.x64') if p.is_dir() and ('Variant30' in p.name or 'Variant31' in p.name))
    if not (api and cli and plugins):
        raise Refuse('Steamless source layout not as expected (API %s, CLI %s, plugins %s); see research/2026-11-08-skyrim-preparation.md'
                     % (api, cli, plugins))
    (api / 'Steamless.API.vxrt.csproj').write_text(csproj('Steamless.API'))
    for p in plugins:
        (p / (p.name + '.vxrt.csproj')).write_text(csproj(p.name, ['%s/Steamless.API.vxrt.csproj' % os.path.relpath(api, p)]))
    (cli / 'Steamless.CLI.vxrt.csproj').write_text(
        csproj('Steamless.CLI', ['%s/Steamless.API.vxrt.csproj' % os.path.relpath(api, cli)], '    <OutputType>Exe</OutputType>\n'))
    out = t / 'steamless-bin'
    run([str(dotnet()), 'build', str(cli / 'Steamless.CLI.vxrt.csproj'), '-c', 'Release', '-o', str(out)], env=tool_env())
    for p in plugins:
        run([str(dotnet()), 'build', str(p / (p.name + '.vxrt.csproj')), '-c', 'Release', '-o', str(out / 'Plugins')], env=tool_env())
    meta['cli_sha256'] = sha(steamless_cli())
    (t / 'tools-manifest.json').write_text(json.dumps(meta, indent=2) + '\n')
    print('built', steamless_cli())


def run(cmd, **kw):
    print('+', ' '.join(cmd), flush=True)
    subprocess.run(cmd, check=True, **kw)


def unpack():
    exe = asset_exe()
    got = sha(exe)
    if got != E.ORIGINAL_EXE_SHA256:
        raise Refuse('%s is %s, not the pinned Steam build %s: this pipeline is pinned to one build of SkyrimVR.exe '
                     '(update it in Steam, or ask about another build)' % (exe, got, E.ORIGINAL_EXE_SHA256))
    dest = E.skyrim_dir() / 'prepared' / 'SkyrimVR.exe'
    if dest.is_file() and sha(dest) == E.PREPARED_EXE_SHA256:
        print('prepared exe already in place and verified:', dest); return
    if not steamless_cli().is_file():
        raise Refuse('Steamless is not built: run  tools/skyrim_prepare.py fetch-tools  (or tools/vxrt_build.py toolchain)')
    work = E.skyrim_dir() / 'work'
    shutil.rmtree(work, ignore_errors=True); work.mkdir(parents=True)
    shutil.copyfile(exe, work / 'SkyrimVR.exe')       # the copy is unpacked; the original is only read
    log = work / 'steamless.log'
    with log.open('wb') as f:
        r = subprocess.run([str(dotnet()), str(steamless_cli()), str(work / 'SkyrimVR.exe')],   # default options
                           env=tool_env(), stdout=f, stderr=subprocess.STDOUT, cwd=work)
    out = work / 'SkyrimVR.exe.unpacked.exe'
    if r.returncode or not out.is_file():
        raise Refuse('Steamless failed (exit %d); see %s' % (r.returncode, log))
    got = sha(out)
    if got != E.PREPARED_EXE_SHA256:
        keep = E.skyrim_dir() / 'prepared-unverified'; keep.mkdir(exist_ok=True)
        shutil.move(str(out), keep / 'SkyrimVR.exe')
        raise Refuse('the unpacked exe is %s, the pinned result is %s. Not installed (kept in %s). A different Steamless '
                     'build or .NET runtime gives different bytes; the AOT modules are keyed by this hash.'
                     % (got, E.PREPARED_EXE_SHA256, keep))
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(out), dest)
    os.chmod(dest, 0o600)
    shutil.rmtree(work)
    print('prepared exe verified (%s) and installed: %s' % (got, dest))


def pins():
    cfg = json.loads(CONFIG.read_text())
    return {Path(d['path']).name: d['sha256'] for d in cfg['dlls']}


def place(src, dst, want, recorded=False):
    """Copy src to dst after checking its hash. recorded: any genuine x86-64 PE is taken (a different hash than `want` is noted, not refused)."""
    src, dst = Path(src), Path(dst)
    if not src.is_file():
        raise Refuse('missing %s' % src)
    got = sha(src)
    if recorded:
        import skyrim_aot_pipeline as P
        try:
            P.pe_layout(src)
        except ValueError as e:
            raise Refuse('%s is not a usable x86-64 DLL (%s); use the one from SteamVR\'s bin/vrwebhelper/win64 folder' % (src, e))
        if got != want:
            print('note: %s is %s, not the %s this build was made with. That is fine (SteamVR updates this DLL): the AOT compiles the one you '
                  'have and records its hash.' % (src, got, want))
        want = got
    elif got != want:
        raise Refuse('%s is %s, the config pins %s (another build of the game or SteamVR?)' % (src, got, want))
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not dst.is_file() or sha(dst) != want:
        shutil.copyfile(src, dst)
    print('ok', dst)


def inputs():
    pin = pins()
    game = asset_exe().parent
    inp, red = Path(E.variables()['VXRT_AOT_INPUTS']), Path(E.variables()['VXRT_REDIST_DIR'])
    for n in ('binkw64.dll', 'openvr_api.dll', 'steam_api64.dll'):
        place(game / n, inp / n, pin[n])
    vr = os.environ.get('STEAMVR_WIN64_DLLS')
    if not vr:
        raise Refuse('STEAMVR_WIN64_DLLS is not set: point it at SteamVR\'s bin/vrwebhelper/win64 folder (msvcp140.dll)')
    place(Path(vr) / 'msvcp140.dll', inp / 'msvcp140.dll', pin['msvcp140.dll'], recorded=True)
    missing = [n for n in ('d3dx9_42.dll', 'X3DAudio1_7.dll') if not (red / n).is_file()]
    if missing:    # opened from the DirectX redistributable cabinets inside the game's _CommonRedist, nothing run
        env = dict(os.environ, VXRT_REDIST=str(red))
        run([sys.executable, str(E.REPO / 'tools' / 'vxrt_redist.py'), 'collect', '--from', str(game)], env=env)
    for n in ('d3dx9_42.dll', 'X3DAudio1_7.dll'):
        place(red / n, red / n, pin[n])


def status():
    ok = True
    for label, path in (('original exe', os.environ.get('SKYRIM_ASSET_ROOT', '<SKYRIM_ASSET_ROOT unset>') + '/SkyrimVR.exe'),
                        ('Steamless', steamless_cli()), ('prepared exe', E.skyrim_dir() / 'prepared' / 'SkyrimVR.exe'),
                        ('inputs/', E.variables()['VXRT_AOT_INPUTS']), ('redist/', E.variables()['VXRT_REDIST_DIR'])):
        here = Path(path).exists()
        ok &= here
        print('%-13s %-8s %s' % (label, 'present' if here else 'MISSING', path))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['status', 'fetch-tools', 'unpack', 'inputs', 'all'])
    ap.add_argument('--confirm', action='store_true', help='fetch-tools: ask before downloading (default: print the list and go ahead)')
    ap.add_argument('--yes', action='store_true', help=argparse.SUPPRESS)    # accepted for old callers; now the default
    a = ap.parse_args()
    for k, v in E.load_local_env().items():
        os.environ.setdefault(k, v)
    try:
        if a.command == 'status':
            return status()
        if a.command == 'fetch-tools':
            fetch_tools(a.confirm and not a.yes)
        if a.command in ('unpack', 'all'):
            unpack()
        if a.command in ('inputs', 'all'):
            inputs()
    except Refuse as e:
        print('skyrim_prepare: ' + str(e), file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as e:
        print('skyrim_prepare: command failed (%d): %s' % (e.returncode, ' '.join(map(str, e.cmd))), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
