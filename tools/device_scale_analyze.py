#!/usr/bin/env python3
"""Summarise a tools/device_scale_sweep.sh output directory.

usage: device_scale_analyze.py <sweep-dir> [--w0 45] [--w1 95]

Window: [w0, w1] seconds after the FIRST FRESH GAME PAIR of each launch (the same point of the Helgen cart ride in
every arm). Only head-tracked compositor seconds count (anchor_tracked > 80% of frames).

Per arm: fresh pairs/s, GPU ms per pair, compositor fps, late frames, pair age, render target size, top passes.
  fresh pairs/s    mean of vr.imm_interval_fresh (one `vr` event per second)
  GPU ms per pair  the game's "GPU: busy N% of the last S s" lines (VXRT_STATS=1: union of the game's command-buffer
                   GPU times) inside the window, as busy ms/s divided by fresh pairs/s. Lines are placed in time by
                   the Mac receive time in console.txt vs the host_log launch time (clock skew of a second or so is
                   immaterial over a 50 s window); without console.txt they are placed by cumulative span (approximate).
  late frames      sum of mtp.cf_late (compositor frames whose GPU start missed their slot) per window
  pair age         vr.imm_age_ms_mean_fresh (age of a fresh pair when shown) and mtp_sample_to_target_ms
  render target    "native VR pair probe: eye 0 WxH" from vxrt.log (the size the game was given, after the scale)
Verdict rule: pixel-bound if the 0.5 arms give >= 1.5x the fresh pairs/s of the 0.7 arms (or GPU ms/pair scales close
to pixel count); not pixel-bound if < 1.15x; in between, partly.
"""
import json, os, re, statistics as st, sys, collections, glob


def load(path):
    out = []
    for l in open(path, errors="replace"):
        try:
            out.append(json.loads(l))
        except Exception:
            pass
    return out


def mean(v):
    v = [x for x in v if x is not None]
    return st.mean(v) if v else None


def fmt(x, p=1):
    return "n/a" if x is None else ("%.*f" % (p, x))


def arm_stats(d, w0, w1):
    ev = load(os.path.join(d, "last_run.jsonl"))
    vr = [e for e in ev if e.get("event") == "vr"]
    mtp = [e for e in ev if e.get("event") == "mtp"]
    launch = next((e for e in ev if e.get("event") == "launch"), None)
    first = next((e for e in vr if e.get("imm_interval_fresh", 0) > 0), None)
    r = {"dir": d}
    if not first or not launch:
        r["error"] = "no fresh pair"
        return r
    f0 = first["since_start"]
    r["first_fresh_s"] = f0
    last_t = max((e.get("since_start", 0) for e in ev), default=0)
    r["log_end_s"] = last_t
    lo, hi = f0 + w0, f0 + w1
    sel = [e for e in vr if lo <= e["since_start"] <= hi and e.get("anchor_tracked", 0) > 0.8 * max(1, e.get("frames", 1))]
    allw = [e for e in vr if lo <= e["since_start"] <= hi]
    r["secs_total"], r["secs_head"] = len(allw), len(sel)
    secs = {round(e["since_start"]) for e in sel}
    ms = [e for e in mtp if round(e["since_start"]) in secs]
    col = lambda k, src: [e.get(k) for e in src if e.get(k) is not None]
    r["fresh"] = mean(col("imm_interval_fresh", sel))
    r["repeat"] = mean(col("imm_interval_repeat", sel))
    r["fps"] = mean(col("frames", sel))
    r["interval"] = mean(col("presentation_interval_ms", sel))
    r["late"] = sum(col("cf_late", ms)) if ms else None
    r["late_per_s"] = (r["late"] / max(1, len(ms))) if ms else None
    r["cf_gpu"] = mean(col("cf_gpu_ms_mean", ms))
    r["age"] = mean(col("imm_age_ms_mean_fresh", sel))
    r["s2t"] = mean(col("mtp_sample_to_target_ms", ms))
    r["foot"] = mean(col("footprint_mb", sel))
    # per-second fresh series, for spread
    r["fresh_series"] = col("imm_interval_fresh", sel)
    # render target size
    sizes = collections.Counter()
    vl = os.path.join(d, "vxrt.log")
    cpath = os.path.join(d, "console.txt")
    gpu_lines = []
    # the runtime log: Documents/vxrt.log if copied, else the console stream (VXRT_LOG_TEE=1)
    log_src = vl if os.path.exists(vl) else cpath
    if os.path.exists(log_src):
        for l in open(log_src, errors="replace"):
            m = re.search(r"native VR pair probe: eye 0 (\d+x\d+)", l)
            if m:
                sizes[m.group(1)] += 1
            m = re.search(r"render scale ([\d.]+)", l)
            if m:
                r["scale_logged"] = m.group(1)
            m = re.search(r"GPU: busy (\d+)% of the last ([\d.]+) s", l)
            if m:
                gpu_lines.append((None, float(m.group(1)), float(m.group(2))))
    r["size"] = sizes.most_common(1)[0][0] if sizes else None
    # GPU busy lines with time
    t0 = launch["t"]
    timed = []
    cp = os.path.join(d, "console.txt")
    if os.path.exists(cp):
        for l in open(cp, errors="replace"):
            m = re.match(r"([\d.]+)\|.*GPU: busy (\d+)% of the last ([\d.]+) s", l)
            if m:
                timed.append((float(m.group(1)) - t0, float(m.group(2)), float(m.group(3))))
    busy_ms = None
    r["gpu_source"] = None
    if timed:
        r["gpu_source"] = "console (%d lines)" % len(timed)
        w = [(100 * b / 100.0, s) for (t, b, s) in timed if lo <= t <= hi]
        if w:
            busy_ms = 1000 * sum(b / 100.0 * s for (t, b, s) in timed if lo <= t <= hi) / sum(s for (t, b, s) in timed if lo <= t <= hi)
            r["gpu_lines"] = len(w)
    elif gpu_lines:
        # vxrt.log has no timestamps: the lines are contiguous in GPU time (each starts where the last ended), so the
        # last one is anchored at the last host_log event (the launch is terminated right after the window) and the
        # others placed backwards by their spans: accurate to about one line (2 s).
        r["gpu_source"] = "vxrt.log, anchored to the end of the run (+-2 s)"
        total = sum(s for (_, _, s) in gpu_lines)
        end_s = max((e["since_start"] for e in vr), default=0)
        t = end_s - total
        num = den = 0.0
        for (_, b, s) in gpu_lines:
            t += s
            if lo <= t <= hi:
                num += b / 100.0 * s
                den += s
        if den:
            busy_ms = 1000 * num / den
    r["gpu_busy_ms_per_s"] = busy_ms
    r["gpu_ms_per_pair"] = (busy_ms / r["fresh"]) if busy_ms is not None and r["fresh"] else None
    # per-pass profile (VXRT_GPU_PROFILE): "   12.3 ms/s   45/s  <sig>" blocks, 4 s each
    prof = collections.defaultdict(list)
    blocks = 0
    src = None
    if os.path.exists(cp):
        src = [(float(m.group(1)) - t0, m.group(2)) for m in (re.match(r"([\d.]+)\|(.*)", l) for l in open(cp, errors="replace")) if m]
    elif os.path.exists(vl):
        src = [(None, l) for l in open(vl, errors="replace")]
    if src:
        cur = None
        for t, l in src:
            if "GPU profile:" in l and "ms of passes" in l:
                cur = (t is None) or (lo <= t <= hi)
                if cur:
                    blocks += 1
                continue
            m = re.match(r"\s*\[?v?x?r?t?\]?\s*([\d.]+) ms/s\s+([\d.]+)/s\s+(.*)$", l.strip("\n"))
            if cur and m:
                prof[m.group(3).strip()].append(float(m.group(1)))
        if blocks:
            r["profile_blocks"] = blocks
            r["profile"] = sorted(((sum(v) / blocks, k) for k, v in prof.items()), reverse=True)[:10]
    return r


def main():
    a = sys.argv[1:]
    w0, w1 = 35.0, 75.0
    d = None
    i = 0
    while i < len(a):
        if a[i] == "--w0":
            w0 = float(a[i + 1]); i += 2
        elif a[i] == "--w1":
            w1 = float(a[i + 1]); i += 2
        else:
            d = a[i]; i += 1
    arms = []
    for p in sorted(glob.glob(os.path.join(d, "arm_*")), key=lambda x: int(os.path.basename(x).split("_")[1])):
        n, s = os.path.basename(p).split("_")[1:3]
        if os.path.exists(os.path.join(p, "last_run.jsonl")):
            r = arm_stats(p, w0, w1)
            r["n"], r["scale"] = int(n), float(s)
            arms.append(r)
    print("sweep %s  window %g..%g s after the first fresh game pair, head-tracked seconds only" % (d, w0, w1))
    hdr = "arm scale  target   fresh/s rep/s  GPUms/pair GPUbusy% comp_fps interval late/s  age_ms s2t_ms  secs(head/all)"
    print(hdr)
    for r in arms:
        if "error" in r:
            print("%3d %.2f   %s" % (r["n"], r["scale"], r["error"])); continue
        busy = (r["gpu_busy_ms_per_s"] / 10) if r["gpu_busy_ms_per_s"] is not None else None
        print("%3d %.2f  %-8s %6s %6s %9s %9s %8s %8s %6s %7s %6s  %d/%d" % (
            r["n"], r["scale"], r["size"] or "n/a", fmt(r["fresh"]), fmt(r["repeat"]), fmt(r["gpu_ms_per_pair"]), fmt(busy, 0),
            fmt(r["fps"], 1), fmt(r["interval"], 2), fmt(r["late_per_s"], 2), fmt(r["age"], 0), fmt(r["s2t"], 0), r["secs_head"], r["secs_total"]))
    by = collections.defaultdict(list)
    for r in arms:
        if "error" not in r:
            by[r["scale"]].append(r)
    print("\nPer scale (mean of the arms; spread = the two arms' fresh/s):")
    agg = {}
    for s in sorted(by):
        rs = by[s]
        fr = [r["fresh"] for r in rs if r["fresh"] is not None]
        g = [r["gpu_ms_per_pair"] for r in rs if r["gpu_ms_per_pair"] is not None]
        agg[s] = (mean(fr), mean(g))
        print("  %.2f: fresh/s %s (arms %s), GPU ms/pair %s, pixels vs 0.7: %.2fx" % (
            s, fmt(mean(fr)), ", ".join(fmt(x) for x in fr), fmt(mean(g)), (s / 0.7) ** 2))
    print("\nVerdict:")
    if 0.5 in agg and 0.7 in agg and agg[0.5][0] and agg[0.7][0]:
        ratio = agg[0.5][0] / agg[0.7][0]
        gr = (agg[0.7][1] / agg[0.5][1]) if agg[0.5][1] and agg[0.7][1] else None
        print("  fresh pairs/s at 0.5 / at 0.7 = %.2fx (pixel ratio 0.7^2/0.5^2 = %.2fx); GPU ms/pair 0.7 / 0.5 = %s" % (ratio, (0.7 / 0.5) ** 2, fmt(gr, 2) + "x" if gr else "n/a"))
        if ratio >= 1.5 or (gr and gr >= 1.4):
            v = "PIXEL-BOUND (>= 1.5x fresh pairs/s, or GPU ms/pair scaling close to pixel count)"
        elif ratio < 1.15:
            v = "NOT PIXEL-BOUND (< 1.15x fresh pairs/s)"
        else:
            v = "PARTLY PIXEL-BOUND (1.15x to 1.5x): pixels are part of the cost, not all"
        print("  " + v)
        if 1.0 in agg and agg[1.0][0]:
            print("  1.0 vs 0.7: fresh/s ratio %.2fx (pixel ratio %.2fx)" % (agg[1.0][0] / agg[0.7][0], (1.0 / 0.7) ** 2))
    else:
        print("  need 0.5 and 0.7 arms")
    for r in arms:
        if r.get("profile"):
            print("\nTop passes, arm %d scale %.2f (mean ms/s over %d profile blocks; divide by fresh/s %s for ms/pair):" % (r["n"], r["scale"], r["profile_blocks"], fmt(r["fresh"])))
            for ms_s, sig in r["profile"]:
                print("  %7.1f ms/s  %s" % (ms_s, sig))
    for r in arms:
        if r.get("gpu_source"):
            print("GPU source arm %d: %s%s" % (r["n"], r["gpu_source"], "" if r.get("gpu_lines") else " (no lines in window)"))


if __name__ == "__main__":
    main()
