#!/usr/bin/env python3
"""Exercise aot_compare with fake runtimes; no Windows runtime is started."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNTIME = Path(__file__).resolve().parents[1]
SCRIPT = RUNTIME / "tools/aot_compare.sh"
SUMMARY = ("[vxrt] aot: 12 entries into recompiled code, 3 C function calls, 4 native calls, "
           "5 built-in export stubs followed, 0 fallbacks to the translator (0 addresses), "
           "6 ordered accesses across 16 bytes")


class CompareTest(unittest.TestCase):
    def setUp(self):
        (RUNTIME / "build").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=RUNTIME / "build", prefix="aot-compare-test-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.runner = root / "fake runner"
        self.runner.write_text('''#!/bin/sh
if [ "$VXRT_AOT_STRICT" != 1 ] && [ -n "${VXRT_AOT_DIR+x}" ]; then exit 8; fi
case "$0:$VXRT_AOT_STRICT" in
  *rosetta*) mode=rosetta ;;
  *:1) mode=aotb ;;
  *) mode=jit ;;
esac
printf '%s\\n' "${FAKE_OUTPUT:-suite: 0 failures}"
if [ "$mode" = aotb ] && [ "${FAKE_SUMMARY+x}" = x ]; then printf '%s\\n' "$FAKE_SUMMARY"; fi
if [ "$mode" = "$FAKE_FAIL" ]; then exit 7; fi
''')
        self.runner.chmod(0o755)
        self.rosetta = root / "fake rosetta"
        self.rosetta.symlink_to(self.runner)
        self.env = os.environ.copy()
        self.env.update(AOT_COMPARE_ROSETTA=str(self.rosetta), AOT_COMPARE_ARM64=str(self.runner),
                        AOT_COMPARE_OUT=str(root / "output with spaces"), VXRT_ROOT=str(root / "root"),
                        FAKE_SUMMARY=SUMMARY, AOT_EXPECTED_VERDICT="suite: 0 failures")
        self.env.pop("VXRT_AOT_STRICT", None)

    def run_compare(self, **changes):
        env = self.env.copy()
        for key, value in changes.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        return subprocess.run([str(SCRIPT), "fixture.exe", "argument with spaces"], env=env,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_success_and_optional_verdict(self):
        for verdict in ("suite: 0 failures", None):
            with self.subTest(verdict=verdict):
                result = self.run_compare(AOT_EXPECTED_VERDICT=verdict)
                self.assertEqual(result.returncode, 0, result.stdout)

    def test_inherited_aot_environment_is_cleared_for_reference_runs(self):
        result = self.run_compare(VXRT_AOT_STRICT="1", VXRT_AOT_DIR="inherited")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_each_child_failure_is_rejected(self):
        for mode in ("rosetta", "jit", "aotb"):
            with self.subTest(mode=mode):
                result = self.run_compare(FAKE_FAIL=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(f"{mode}: child failed", result.stdout)

    def test_identical_failure_verdict_is_rejected(self):
        result = self.run_compare(FAKE_OUTPUT="suite: 1 failures")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("expected verdict missing", result.stdout)

    def test_summary_is_required_and_valid(self):
        for summary in (None, "", SUMMARY.replace("0 fallbacks", "1 fallbacks"),
                        SUMMARY.replace("12 entries", "0 entries"), SUMMARY.replace("(0 addresses)", "(2 addresses)"), SUMMARY + " garbage",
                        SUMMARY + "\n" + SUMMARY):
            with self.subTest(summary=summary):
                result = self.run_compare(FAKE_SUMMARY=summary)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("invalid zero-fallback AOT summary", result.stdout)


if __name__ == "__main__":
    unittest.main()
