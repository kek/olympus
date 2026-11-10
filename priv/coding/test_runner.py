import importlib.util
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

    def test_path_validation_is_structural(self):
        for path in ["../main.py", "/main.py", "a//b", "./main.py", ".git/config", "a/../b", "a\\b"]:
            self.assertFalse(runner.safe_path(path))
        self.assertTrue(runner.safe_path("src/main.py"))


if __name__ == "__main__":
    unittest.main()
