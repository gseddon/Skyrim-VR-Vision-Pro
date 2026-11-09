#!/usr/bin/env python3
"""vxrt-aot must bound a jump table by the compare of the register its index was copied from (owned fixture: tests/aot_jump_bound.S).

usage: aot_jump_bound_check.py <vxrt-aot> <aot_jump_bound.exe>
Before the fix the table of 8 entries was bounded by an unrelated `cmpl $1, %eax` (bound 2), so five targets were left to the translator.
"""
import os, re, subprocess, sys

tool, exe = sys.argv[1:3]
out = subprocess.run([tool, 'analyze', exe], env=dict(os.environ, VXRT_AOT_JTDEBUG='1'), capture_output=True, text=True)
if out.returncode:
    sys.exit('analyze failed: %d\n%s' % (out.returncode, out.stderr[-400:]))
sites = [l for l in (out.stdout + out.stderr).splitlines() if l.startswith('jt ')]
mine = [l for l in sites if re.search(r'add_reg 11 table 0x[0-9a-f]+ add_base 0x140000000 ', l)]   # (the fixture's table: base in R11, image-relative entries)
bounds = [int(re.search(r'bound (-?\d+)', l).group(1)) for l in mine]
if bounds != [8]:
    sys.exit('aot_jump_bound: expected one fixture table with bound 8, got %r (%d jump table sites)' % (bounds, len(sites)))
print('aot_jump_bound: ok')
