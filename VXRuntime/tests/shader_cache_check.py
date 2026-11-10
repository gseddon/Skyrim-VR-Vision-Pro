#!/usr/bin/env python3
"""The shader library cache of the Direct3D 11 renderer (src/d3d11_draw.m, src/d3d12.m: vx_library_cache_*), on the
owned test build/draw.exe (make check):
  1. a first run with an empty cache folder keeps the compiled libraries (<key>.metallib) for the next start,
  2. a second run loads them (cache hits) and prints the same results,
  3. libraries that are garbage or empty are compiled again, replaced, and the results are the same,
  4. VXRT_SHADER_CACHE=0 writes nothing.
Cold and warm wall times are printed. Needs the offline compiler (xcrun metal); without it the test says so and passes.

    python3 tests/shader_cache_check.py build/vxrt"""
import glob, os, re, shutil, subprocess, sys, tempfile, time

failures = []
def check(cond, what):
    if not cond: failures.append(what); print("check failed:", what)

def run(runtime, exe, cache, **extra):
    env = dict(os.environ, **extra, VXRT_SHADER_CACHE=cache, VXRT_SHADER_CACHE_MIN_MS="0", VXRT_SHADER_CACHE_SYNC="1")
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
        rc1, out1, err1, cold = run(runtime, exe, cache)
        libs = sorted(glob.glob(os.path.join(cache, "*.metallib")))
        check(rc1 == 0 and "0 failed checks -> ok" in out1, "first run passes")
        check(len(libs) >= 5, "first run kept libraries (%d)" % len(libs))
        check("kept for the next start" in err1, "first run says it kept libraries")
        check("shader cache: MISS" in err1 and "shader cache summary:" in err1, "first run logs misses and a summary")
        check(not glob.glob(os.path.join(cache, "*.tmp.*")) and not glob.glob(os.path.join(cache, "*.metal")), "no temporary files are left")
        rc2, out2, err2, warm = run(runtime, exe, cache)
        hits2 = len(re.findall(r"metallib loaded", err2))
        check(rc2 == 0 and "0 failed checks -> ok" in out2, "second run passes")
        check(hits2 >= 3, "second run loads libraries from the cache (%d logged)" % hits2)
        check("kept for the next start" not in err2, "second run compiles nothing it should have kept")
        check(results(out1) == results(out2), "same results with a cold and a warm cache")
        print("shader_cache_check: %d libraries; cold run %.2f s, warm run %.2f s; %d hits logged" % (len(libs), cold, warm, hits2))
        check(re.search(r"summary: [1-9]\d* hits, 0 misses", err2) is not None, "second run's summary: hits only, no misses")
        # Fast math is another key (the draw test's IEEE checks fail under it, as they should): the safe-math libraries must not be loaded for it (and the other way round).
        nlibs = len(libs)
        rcf, outf, errf, _ = run(runtime, exe, cache, VXRT_D3D11_FAST_MATH="1")
        libsf = sorted(glob.glob(os.path.join(cache, "*.metallib")))
        check("shader cache: MISS" in errf and len(libsf) > nlibs, "fast math misses safe-math libraries and keeps its own (%d -> %d)" % (nlibs, len(libsf)))
        # Damaged files: garbage in some, an empty file, a truncated one.
        for i, f in enumerate(libs):
            if i % 3 == 0: open(f, "wb").write(b"not a metallib")
            elif i % 3 == 1: open(f, "wb").close()
            else: open(f, "wb").write(b"MTLB\x00\x00")
        rc3, out3, err3, _ = run(runtime, exe, cache)
        check(rc3 == 0 and "0 failed checks -> ok" in out3, "run over damaged libraries passes")
        check("unreadable" in err3, "damaged libraries are reported")
        check(results(out1) == results(out3), "same results over damaged libraries")
        bad = [f for f in libs if os.path.getsize(f) < 100]
        check(not bad, "damaged libraries were replaced (%d left)" % len(bad))
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
