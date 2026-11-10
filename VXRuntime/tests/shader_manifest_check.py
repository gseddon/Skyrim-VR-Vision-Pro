#!/usr/bin/env python3
"""The offline shader manifest build (tools/shader_manifest_build + build/vxrt-shader-manifest), on owned fixtures
(tests/shaders/*.dxbc) in a made-up install: one shader pack inside a BSA (v105, uncompressed), one loose .fxp, one in an .exe.
  1. every manifest entry is found in the install and translated; a manifest without keys passes unchecked,
  2. the sources queued are <key>.metal + <key>.flags ("0 0 1": Metal 3.1, safe math), the keys are the ones the runtime's
     cache computes (the tool uses the runtime's own writer); the same manifest with the keys it just produced passes,
  3. a wrong recorded key fails (the translator or options changed), and so does a hash the install does not hold.
Nothing here needs a game; with the Metal compiler present the fill step is run on one of them too.

    python3 tests/shader_manifest_check.py"""
import glob, hashlib, os, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOL = os.path.join(ROOT, "build", "vxrt-shader-manifest")
BUILD = os.path.join(ROOT, "..", "tools", "shader_manifest_build")
failures = []
def check(cond, what):
    if not cond: failures.append(what); print("check failed:", what)

def bsa(files):
    """A minimal v105 BSA (one folder 'shadersfx', no compression) holding files {name: bytes}."""
    names = sorted(files)
    fnames = b"".join(n.encode() + b"\0" for n in names)
    folder = b"shadersfx\0"
    hdr_size = 36
    folder_rec = 24
    file_block = 1 + len(folder) + 16 * len(names)
    data_off = hdr_size + folder_rec + file_block + len(fnames)
    out = struct.pack("<4sIIIIIIII", b"BSA\0", 105, 36, 3, 1, len(names), len(folder), len(fnames), 0)
    out += struct.pack("<QIIQ", 0, len(names), 0, hdr_size + folder_rec + len(fnames))
    out += bytes([len(folder)]) + folder
    off = data_off
    recs = b""
    for n in names:
        recs += struct.pack("<QII", 0, len(files[n]), off); off += len(files[n])
    # (the file names sit between the folder records and the data, after the file blocks)
    return out + recs + fnames + b"".join(files[n] for n in names)

def main():
    if not os.path.exists(TOOL): print("shader_manifest_check: %s not built" % TOOL); return 1
    fixtures = sorted(glob.glob(os.path.join(HERE, "shaders", "*.dxbc")))[:6]
    codes = [open(f, "rb").read() for f in fixtures]
    shas = [hashlib.sha256(c).hexdigest() for c in codes]
    tmp = tempfile.mkdtemp(prefix="vxmanifest")
    try:
        game = os.path.join(tmp, "game"); os.makedirs(os.path.join(game, "Data", "loose"))
        junk = b"\x02\0\0\0\x02\0\0\0D3\"\x11" + b"\xaa" * 37
        pack = lambda cs: b"".join(junk + c for c in cs)
        open(os.path.join(game, "Data", "Fake - Main.bsa"), "wb").write(bsa({"pack_a.fxp": pack(codes[0:2]), "other.txt": b"DXBC nope"}))
        open(os.path.join(game, "Data", "loose", "pack_b.fxp"), "wb").write(pack(codes[2:4]))
        open(os.path.join(game, "Fake.exe"), "wb").write(b"MZ" + b"\0" * 100 + pack(codes[4:6]))
        def manifest(name, keys=None, extra=()):
            p = os.path.join(tmp, name)
            with open(p, "w") as f:
                f.write("# vxrt-shader-manifest 1\n# translator=1\n")
                for i, s in enumerate(shas):
                    f.write("%s\tps\tbase\t\t1%s\n" % (s, ("\t" + keys[i]) if keys else ""))
                for e in extra: f.write(e + "\n")
            return p
        def build(m, out):
            return subprocess.run([sys.executable, BUILD, "--game", game, "--manifest", m, "--out", out, "--no-fill", "--tool", TOOL],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        out1 = os.path.join(tmp, "o1")
        r = build(manifest("m1.tsv"), out1)
        check(r.returncode == 0, "first build exits 0: " + r.stdout[-400:])
        check("%d of %d DXBC found" % (len(set(shas)), len(set(shas))) in r.stdout, "every DXBC found in the bsa, the loose pack and the exe")
        rep = [l.split("\t") for l in open(os.path.join(out1, "report.tsv")).read().splitlines()]
        keys = [x[2] for x in rep]
        pend = sorted(glob.glob(os.path.join(out1, "pending", "*.metal")))
        check(len(pend) == len(set(keys)), "one source queued per distinct key (%d, want %d)" % (len(pend), len(set(keys))))
        for k in set(keys):
            fl = os.path.join(out1, "pending", k + ".flags")
            check(os.path.exists(fl) and open(fl).read() == "0 0 1\n", "flags of %s: Metal 3.1, safe math" % k)
        m2 = manifest("m2.tsv", keys)
        r = build(m2, os.path.join(tmp, "o2"))
        check(r.returncode == 0 and "0 key differs" in r.stdout, "recorded keys match: " + r.stdout[-300:])
        bad = list(keys); bad[0] = "0" * 16
        r = build(manifest("m3.tsv", bad), os.path.join(tmp, "o3"))
        check(r.returncode != 0 and "1 key differs" in r.stdout, "a wrong recorded key fails: " + r.stdout[-300:])
        r = build(manifest("m4.tsv", extra=["%s\tps\tbase\t\t1" % ("ab" * 32)]), os.path.join(tmp, "o4"))
        check(r.returncode != 0 and "1 DXBC missing" in r.stdout or "not in the install" in r.stdout, "a hash the install lacks fails: " + r.stdout[-300:])
        if subprocess.run(["xcrun", "-sdk", "macosx", "-f", "metal"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            fill = os.path.join(ROOT, "..", "tools", "shadercache_fill.sh")
            subprocess.run([fill, out1, "macosx"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            libs = glob.glob(os.path.join(out1, "*.metallib"))
            check(len(libs) == len(set(keys)), "the fill made a library per key (%d of %d)" % (len(libs), len(set(keys))))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("shader_manifest_check: %s" % ("ok" if not failures else "%d check(s) failed" % len(failures)))
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main())
