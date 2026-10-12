"""Regression checks for bundle validation and the scheduled-build gate."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from pip._vendor.packaging.tags import Tag

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wheelhouse", ROOT / "check-wheelhouse.py")
wheelhouse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wheelhouse)


class WheelhouseTests(unittest.TestCase):
    def test_dotted_and_normalized_names(self):
        for filename in ("ruamel.yaml-0.18.16-py3-none-any.whl",
                         "ruamel_yaml-0.18.16-py3-none-any.whl"):
            self.assertEqual(wheelhouse.missing_wheels(
                "ruamel.yaml==0.18.16", [filename], {Tag("py3", "none", "any")}), [])

    def test_wrong_version_or_platform_is_missing(self):
        for filename in ("ruamel_yaml-0.18.15-py3-none-any.whl",
                         "ruamel_yaml-0.18.16-cp313-cp313-linux_x86_64.whl"):
            self.assertEqual(wheelhouse.missing_wheels(
                "ruamel.yaml==0.18.16", [filename], {Tag("py3", "none", "any")}),
                ["ruamel.yaml==0.18.16"])


class GateTests(unittest.TestCase):
    def test_history_gate(self):
        scenarios = [
            ([], False, 0, False),
            ([{"status": "completed", "conclusion": "success"}], False, 0, False),
            ([{"status": "completed", "conclusion": "failure"}], False, 0, True),
            ([{"status": "completed", "conclusion": "cancelled"}], False, 0, True),
            ([{"status": "completed", "conclusion": "timed_out"}], False, 0, True),
            ([{"status": "in_progress"}], True, 0, True),
            ([{"status": "queued"}], False, 0, True),
            ([{"status": "completed", "conclusion": "failure"}], True, 0, False),
            ([], True, 1, True),
        ]
        for runs, force, api_exit, expected in scenarios:
            with self.subTest(runs=runs, force=force, api_exit=api_exit), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp)
                shim = path / "gh"
                shim.write_text('#!/bin/sh\nprintf "%s" "$RUNS"\nexit "$API_EXIT"\n')
                # Use this host's shell; Android has no /bin/sh.
                shim.write_text(shim.read_text().replace("/bin/sh", subprocess.check_output(
                    ["sh", "-c", "command -v sh"], text=True).strip(), 1))
                shim.chmod(0o755)
                output = path / "output"
                output.touch()
                env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"],
                           RUNS=json.dumps(runs), API_EXIT=str(api_exit), OURS="test/repo",
                           FORCE=str(force).lower(), GITHUB_OUTPUT=str(output),
                           GITHUB_STEP_SUMMARY=str(path / "summary"))
                subprocess.run(["bash", str(ROOT / "watch-build-gate.sh")], env=env, check=True)
                self.assertEqual("paused=true" in output.read_text(), expected)


if __name__ == "__main__":
    unittest.main()
