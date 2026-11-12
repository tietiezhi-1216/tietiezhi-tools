"""Exercise deployment decisions without a token, network, or repository writes."""
import base64
import contextlib
import io
import json
import os
import plistlib
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/github-release.py"
VERSION = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]


class ReleaseStateTests(unittest.TestCase):
    def state(self, release=None, deployed=None, failure=False):
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            environment = {
                "GITHUB_ACTIONS": "true", "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": "push", "GITHUB_REPOSITORY": "alice/untitled",
                "GITHUB_SHA": "a" * 40, "GITHUB_OUTPUT": str(output),
            }
            def invoke(command, **kwargs):
                calls.append(command)
                self.assertEqual(command[:4], ["gh", "api", "--method", "GET"])
                value = release if "/releases/tags/" in command[4] else (
                    {"content": base64.b64encode(json.dumps({"version": deployed}).encode()).decode()} if deployed else None)
                if failure:
                    return subprocess.CompletedProcess(command, 1, "", "GitHub unavailable (HTTP 503)")
                return subprocess.CompletedProcess(command, 0 if value is not None else 1,
                    json.dumps(value) if value is not None else "{}", "" if value is not None else "Not found (HTTP 404)")
            with patch.dict(os.environ, environment, clear=True), patch("sys.argv", [str(SCRIPT), "state"]), \
                 patch("subprocess.run", side_effect=invoke), contextlib.redirect_stdout(io.StringIO()):
                if failure:
                    with self.assertRaises(RuntimeError):
                        runpy.run_path(str(SCRIPT), run_name="__main__")
                    self.assertFalse(output.exists())
                    return
                with self.assertRaises(SystemExit) as result:
                    runpy.run_path(str(SCRIPT), run_name="__main__")
                self.assertEqual(result.exception.code, 0)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_new_version_prepares_release(self):
        state = self.state()
        self.assertEqual(state["publish"], "true")
        self.assertEqual(state["repair"], "false")

    def test_existing_release_is_immutable(self):
        state = self.state({"draft": False}, VERSION)
        self.assertEqual(state["publish"], "false")
        self.assertEqual(state["repair"], "false")

    def test_interrupted_deployment_repairs_only_catalog(self):
        state = self.state({"draft": False})
        self.assertEqual(state["publish"], "false")
        self.assertEqual(state["repair"], "true")

    def test_newer_deployment_prevents_out_of_order_release(self):
        state = self.state(deployed="999.0.0")
        self.assertEqual(state["publish"], "false")
        self.assertEqual(state["repair"], "false")

    def test_draft_can_resume(self):
        self.assertEqual(self.state({"draft": True})["publish"], "true")

    def test_server_failure_is_not_treated_as_missing_release(self):
        self.state(failure=True)

    def test_local_and_pr_invocations_never_contact_github(self):
        for environment in ({}, {"GITHUB_ACTIONS": "true", "GITHUB_REF": "refs/pull/1/merge"}):
            with self.subTest(environment=environment), patch.dict(os.environ, environment, clear=True), \
                 patch("sys.argv", [str(SCRIPT), "publish"]), patch("subprocess.run") as command:
                with self.assertRaises(AssertionError):
                    runpy.run_path(str(SCRIPT), run_name="__main__")
                command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
