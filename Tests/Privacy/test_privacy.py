import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCANNER = Path(__file__).resolve().parents[2] / "scripts/check-privacy.py"


class PrivacyTests(unittest.TestCase):
    def scan(self, *args, cwd=None):
        return subprocess.run(["python3", str(SCANNER), *map(str, args)], cwd=cwd,
                              capture_output=True, text=True)

    def test_binary_leaks_are_detected_without_echoing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            sensitive = ("/Users/" + "test-person/private/file").encode()
            path.write_bytes(b"\x00binary\x00" + sensitive + b"\x00")
            result = self.scan(path)
            self.assertEqual(result.returncode, 1)
            self.assertIn("user home path", result.stdout)
            self.assertNotIn(sensitive.decode(), result.stdout)

    def test_clean_examples_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            path.write_text("user@example.com 123+developer@users.noreply.github.com")
            self.assertEqual(self.scan(path).returncode, 0)

    def test_long_binary_symbol_does_not_cause_quadratic_email_search(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            path.write_bytes(b"a" * 1_000_000)
            result = subprocess.run(["python3", str(SCANNER), str(path)],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)

    def test_history_scan_checks_commit_and_annotated_tag_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = dict(os.environ)
            env.update(GIT_AUTHOR_NAME="Test", GIT_COMMITTER_NAME="Test",
                       GIT_AUTHOR_EMAIL="test@users.noreply.github.com",
                       GIT_COMMITTER_EMAIL="test@users.noreply.github.com")

            def git(*args):
                return subprocess.run(["git", *args], cwd=root, env=env, check=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            git("init", "-q")
            (root / "README").write_text("clean content")
            git("add", "README")
            git("commit", "-qm", "clean commit")
            self.assertEqual(self.scan("--history", cwd=root).returncode, 0)
            private_email = "test-person" + "@" + "gmail.com"
            env["GIT_COMMITTER_EMAIL"] = private_email
            git("tag", "-a", "v1", "-m", "tag fixture")
            tagged = self.scan("--history", cwd=root)
            self.assertEqual(tagged.returncode, 1)
            self.assertIn("Git tag", tagged.stdout)
            self.assertNotIn(private_email, tagged.stdout)
            git("tag", "-d", "v1")
            env["GIT_AUTHOR_EMAIL"] = private_email
            git("commit", "--allow-empty", "-qm", "identity fixture")
            committed = self.scan("--history", cwd=root)
            self.assertEqual(committed.returncode, 1)
            self.assertIn("Git commit", committed.stdout)
            self.assertNotIn(private_email, committed.stdout)


if __name__ == "__main__":
    unittest.main()
