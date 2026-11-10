#!/usr/bin/env python3
"""The shader library cache of the Direct3D 11 renderer (src/d3d11_draw.m, src/d3d12.m: vx_library_cache_*), on the
owned test build/draw.exe (make check):
  1. a first run with an empty cache folder compiles in process and queues each distinct source in pending/ (<key>.metal
     and .flags), without running the offline compiler,
  2. tools/shadercache_fill.sh makes <key>.metallib of them and removes them,
  3. a second run loads those libraries (cache hits, no misses) and prints the same results,
  4. fast math is another key, libraries that are garbage or empty are compiled again, queued, replaced by the fill,
  5. VXRT_SHADER_CACHE=0 writes nothing; VXRT_D3D11_LIBRARY_REUSE=0 gives the same results.
Cold and warm wall times are printed. Needs the offline compiler (xcrun metal); without it the test says so and passes.

    python3 tests/shader_cache_check.py build/vxrt"""
import glob, os, re, shutil, subprocess, sys, tempfile, time

failures = []
def check(cond, what):
    if not cond: failures.append(what); print("check failed:", what)

def run(runtime, exe, cache, **extra):
    env = dict(os.environ, **extra, VXRT_SHADER_CACHE=cache, VXRT_SHADER_CACHE_SYNC="1")
    env.pop("VXRT_D3D12_SHADER_CACHE", None)
    if "VXRT_ROOT" in env: env["VXRT_ROOT"] = os.path.abspath(env["VXRT_ROOT"])
    t = time.time()
    p = subprocess.run([runtime, exe], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
    return p.returncode, p.stdout, p.stderr, time.time() - t

def results(out):
    # (the run's own timing-dependent lines, such as how many polls a read-back needed, are not results)
    return [l for l in out.splitlines() if not re.search(r"polls|\d+(\.\d+)? ?ms", l)]

def main():
    runtime = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "build/vxrt")
    exe = os.path.abspath("build/draw.exe")
    if subprocess.run(["xcrun", "-sdk", "macosx", "-f", "metal"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        print("shader_cache_check: no offline Metal compiler (xcrun metal) here: nothing to check"); return 0
    cache = tempfile.mkdtemp(prefix="vxshc")
    try:
        fill = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "shadercache_fill.sh")
        def pending(): return sorted(glob.glob(os.path.join(cache, "pending", "*.metal")))
        def libraries(): return sorted(glob.glob(os.path.join(cache, "*.metallib")))
        def do_fill(): return subprocess.run(["sh", fill, cache], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=600)
        rc1, out1, err1, cold = run(runtime, exe, cache)
        check(rc1 == 0 and "0 failed checks -> ok" in out1, "first run passes")
        check(not libraries(), "the game run itself makes no libraries (%d)" % len(libraries()))
        npend = len(pending())
        check(npend >= 5, "first run queued its sources in pending/ (%d)" % npend)
        check(len(glob.glob(os.path.join(cache, "pending", "*.flags"))) == npend, "each with its flags")
        check("queued in pending/" in err1, "first run says it queued sources")
        check("shader cache: MISS" in err1 and "shader cache summary:" in err1, "first run logs misses and a summary")
        check(not glob.glob(os.path.join(cache, "*.tmp.*")), "no temporary files are left")
        f = do_fill()
        libs = libraries()
        check(f.returncode == 0 and len(libs) == npend and not pending(), "the fill script compiled all pending (%d libraries, %d left)" % (len(libs), len(pending())))
        rc2, out2, err2, warm = run(runtime, exe, cache)
        hits2 = len(re.findall(r"metallib loaded", err2))
        check(rc2 == 0 and "0 failed checks -> ok" in out2, "second run passes")
        check(hits2 >= 3, "second run loads libraries from the cache (%d logged)" % hits2)
        check("queued in pending/" not in err2 and not pending(), "second run queues nothing")
        check(results(out1) == results(out2), "same results with a cold and a warm cache")
        print("shader_cache_check: %d libraries; cold run %.2f s, warm run %.2f s; %d hits logged" % (len(libs), cold, warm, hits2))
        check(re.search(r"summary: [1-9]\d* hits, 0 misses", err2) is not None, "second run's summary: hits only, no misses")
        # Every request for a source this process already has a library for is answered from it, with the same results.
        rcr, outr, errr, _ = run(runtime, exe, cache, VXRT_D3D11_LIBRARY_REUSE="0")
        check(rcr == 0 and results(outr) == results(out1), "VXRT_D3D11_LIBRARY_REUSE=0 gives the same results")
        # Fast math is another key (the draw test's IEEE checks fail under it, as they should): the safe-math libraries must not be loaded for it.
        rcf, outf, errf, _ = run(runtime, exe, cache, VXRT_D3D11_FAST_MATH="1")
        check("shader cache: MISS" in errf and len(pending()) > 0, "fast math misses safe-math libraries and queues its own (%d)" % len(pending()))
        do_fill()
        libsf = libraries()
        check(len(libsf) > len(libs), "and the fill makes them (%d -> %d)" % (len(libs), len(libsf)))
        # Damaged files: garbage in some, an empty file, a truncated one.
        for i, f in enumerate(libs):
            if i % 3 == 0: open(f, "wb").write(b"not a metallib")
            elif i % 3 == 1: open(f, "wb").close()
            else: open(f, "wb").write(b"MTLB\x00\x00")
        rc3, out3, err3, _ = run(runtime, exe, cache)
        check(rc3 == 0 and "0 failed checks -> ok" in out3, "run over damaged libraries passes")
        check("unreadable" in err3, "damaged libraries are reported")
        check(results(out1) == results(out3), "same results over damaged libraries")
        check(len(pending()) >= len(libs) // 2, "damaged libraries were queued again (%d)" % len(pending()))
        do_fill()
        bad = [f for f in libs if os.path.getsize(f) < 100]
        check(not bad, "the fill replaced damaged libraries (%d left)" % len(bad))
        rc4, out4, err4, _ = run(runtime, exe, cache)
        check("unreadable" not in err4 and len(re.findall(r"metallib loaded", err4)) >= 3, "and loaded again afterwards")
        # Off.
        rc5, out5, err5, off = run(runtime, exe, "0")
        print("shader_cache_check: no cache %.2f s" % off)
        check(rc5 == 0 and results(out5) == results(out1), "VXRT_SHADER_CACHE=0 runs the same")
        check("shader cache" not in err5, "VXRT_SHADER_CACHE=0 uses no cache")
    finally:
        shutil.rmtree(cache, ignore_errors=True)
    if failures:
        print("shader_cache_check: %d failed" % len(failures)); return 1
    print("shader_cache_check: ok"); return 0

sys.exit(main())
