import importlib.util
import os
import sys
import time
from pathlib import Path
import tempfile
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("coding_runner", Path(__file__).with_name("runner.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PatchTests(unittest.TestCase):
    def test_patch_roundtrips_newlines_unicode_and_additions(self):
        for before, after in [
            ("old\n", "new\n"), ("old", "new"), ("old\n", ""),
            ("x\u2028y\n", "x\u2028z\n"), ("a\r\nb\r", "a\r\nc\r"),
        ]:
            patch = runner.make_patch({"main.py": before}, {"main.py": after})
            with tempfile.TemporaryDirectory() as root:
                Path(root, "main.py").write_bytes(before.encode())
                patchfile = Path(root, "patch.diff")
                patchfile.write_bytes(patch.encode())
                subprocess.run(["git", "apply", str(patchfile)], cwd=root, check=True, capture_output=True)
                self.assertEqual(Path(root, "main.py").read_bytes(), after.encode())

        patch = runner.make_patch({}, {"new.py": "new\n"})
        with tempfile.TemporaryDirectory() as root:
            patchfile = Path(root, "patch.diff")
            patchfile.write_text(patch)
            subprocess.run(["git", "apply", str(patchfile)], cwd=root, check=True, capture_output=True)
            self.assertEqual(Path(root, "new.py").read_text(), "new\n")

    def test_empty_additions_are_present_in_delivered_tree(self):
        patch = runner.make_patch({"main.py": "old\\n"}, {"main.py": "new\\n", "package/__init__.py": ""})
        with tempfile.TemporaryDirectory() as root:
            Path(root, "main.py").write_text("old\\n")
            patchfile = Path(root, "patch.diff")
            patchfile.write_text(patch)
            subprocess.run(["git", "apply", str(patchfile)], cwd=root, check=True, capture_output=True)
            self.assertEqual(Path(root, "main.py").read_text(), "new\\n")
            self.assertTrue(Path(root, "package/__init__.py").is_file())
            self.assertEqual(Path(root, "package/__init__.py").read_bytes(), b"")

    def test_closed_cases_and_duplicate_keys(self):
        for cases in [[], [{"stdin": "", "stdout": "", "exit_code": 125}],
                      [{"stdin": "", "stdout": "", "exit_code": True}],
                      [{"stdin": "", "stdout": "", "exit_code": 0, "command": "true"}]]:
            with self.assertRaises(runner.Invalid):
                runner.validate_cases(cases)
        with self.assertRaises(runner.Invalid):
            runner.unique_object([("main.py", "good"), ("main.py", "bad")])

    @unittest.skipUnless(os.environ.get("OLYMPUS_CONTAINER_ENGINE") == "docker" and
                         os.environ.get("OLYMPUS_CONTAINER_TESTS") == "1", "requires Docker integration")
    def test_external_watchdog_expires_an_unattended_container(self):
        image = os.environ.get("OLYMPUS_TEST_IMAGE", "docker.io/library/python:3.12-alpine")
        container_id = subprocess.check_output([
            "docker", "create", "--network=none", "--user=65534:65534", "--cap-drop=ALL",
            "--security-opt=no-new-privileges", "--memory=256m", "--pids-limit=64",
            "--entrypoint", "python3", image, "-c", "import time; time.sleep(30)"
        ], text=True).strip()
        timer = subprocess.Popen([
            sys.executable, "-I", "-B", str(Path(runner.__file__).resolve()),
            "--watchdog", "docker", container_id, str(time.monotonic() + 1.5)
        ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
           start_new_session=True)
        try:
            subprocess.run(["docker", "start", container_id], check=True, capture_output=True)
            self.assertEqual(timer.wait(timeout=10), 0)
            inspected = subprocess.run(["docker", "inspect", container_id], capture_output=True)
            self.assertNotEqual(inspected.returncode, 0)
        finally:
            if timer.poll() is None:
                timer.terminate()
                timer.wait(timeout=2)
            subprocess.run(["docker", "rm", "--force", container_id], capture_output=True)

    def test_path_validation_is_structural(self):
        for path in ["../main.py", "/main.py", "a//b", "./main.py", ".git/config", "a/../b", "a\\b"]:
            self.assertFalse(runner.safe_path(path))
        self.assertTrue(runner.safe_path("src/main.py"))


if __name__ == "__main__":
    unittest.main()
