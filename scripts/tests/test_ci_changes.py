import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ci_changes", Path(__file__).parents[1] / "ci-changes.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class SelectionTests(unittest.TestCase):
    def test_only_known_site_and_documentation_paths_skip_native(self):
        self.assertFalse(ci.needs_native(["web/src/site.ts", "docs/releasing.md", "brand/mark.svg", "README.md"]))
        for path in ("mac/App/Sources/AppModel.swift", "demo/scenarios.json", "LICENSE",
                     ".github/workflows/ci.yml", "scripts/ci-changes.py", "new-input.txt",
                     "mac/Packages/AppearsKit/Package.resolved"):
            with self.subTest(path=path):
                self.assertTrue(ci.needs_native(["web/src/site.ts", path]))
        self.assertTrue(ci.needs_native([]))

    def test_manual_new_branch_and_invalid_revisions_run_native(self):
        head = "a" * 40
        self.assertTrue(ci.select_native("workflow_dispatch", {}, head))
        self.assertTrue(ci.select_native("push", {"before": "0" * 40}, head))
        self.assertTrue(ci.select_native("pull_request", {}, head))
        self.assertTrue(ci.select_native("push", {"before": "--option"}, head))


class GitDiffTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "CI Fixture")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        self.write("mac/source.swift", "native\n")
        self.write("web/site.ts", "site\n")
        self.base = self.commit()
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL).decode().strip()

    def write(self, path, content):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-m", "Synthetic change")
        return self.git("rev-parse", "HEAD")

    def select_push(self, head):
        return ci.select_native("push", {"before": self.base}, head)

    def test_full_push_includes_native_change_before_latest_site_commit(self):
        self.write("mac/source.swift", "changed\n")
        self.commit()
        self.write("web/site.ts", "changed\n")
        self.assertTrue(self.select_push(self.commit()))

    def test_native_deletion_and_rename_into_docs_cannot_skip(self):
        self.git("mv", "mac/source.swift", "web/source.swift")
        self.assertTrue(self.select_push(self.commit()))
        (self.root / "web/source.swift").unlink()
        self.assertTrue(self.select_push(self.commit()))

    def test_site_changes_handle_unusual_names_and_more_than_api_page_limit(self):
        for number in range(305):
            self.write(f"web/{number}.ts", "site\n")
        self.write("docs/two\nlines.md", "docs\n")
        (self.root / "web/site.ts").unlink()
        self.assertFalse(self.select_push(self.commit()))

    def test_pr_merge_uses_full_diff_against_base(self):
        self.git("checkout", "-b", "feature")
        self.write("mac/source.swift", "feature\n")
        self.commit()
        self.write("web/site.ts", "feature\n")
        self.commit()
        self.git("checkout", "main")
        self.write("README.md", "base advanced\n")
        base = self.commit()
        self.git("merge", "--no-ff", "feature", "-m", "Synthetic PR merge")
        event = {"pull_request": {"base": {"sha": base}}}
        self.assertTrue(ci.select_native("pull_request", event, self.git("rev-parse", "HEAD")))

    def test_missing_history_and_empty_diff_run_native(self):
        self.assertTrue(self.select_push("f" * 40))
        self.assertTrue(self.select_push(self.base))

    def test_writes_action_output_and_summary(self):
        self.write("web/site.ts", "changed\n")
        head = self.commit()
        event = self.root / "event.json"
        event.write_text('{"before": "' + self.base + '"}')
        output = self.root / "output"
        summary = self.root / "summary"
        with patch.dict(os.environ, GITHUB_EVENT_NAME="push", GITHUB_EVENT_PATH=str(event),
                        GITHUB_SHA=head, GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary)):
            ci.main()
        self.assertEqual(output.read_text(), "native=false\n")
        self.assertIn("Only site/documentation", summary.read_text())


if __name__ == "__main__":
    unittest.main()
