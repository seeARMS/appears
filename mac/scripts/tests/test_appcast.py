import importlib.util
import pathlib
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("appcast", pathlib.Path(__file__).parents[1] / "make-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.release = {"tag_name": "v0.8.0", "draft": False, "prerelease": False,
                        "html_url": "https://github.com/seeARMS/appears/releases/tag/v0.8.0",
                        "body": "- Faster indexing & better recall\n- Treat <tags> as text\n![image](https://example.com/image.png)",
                        "published_at": "2026-10-15T20:00:00Z"}
        self.info = {"CFBundleShortVersionString": "0.8.0", "CFBundleVersion": "80", "LSMinimumSystemVersion": "26.0"}

    def make(self):
        return appcast.make_appcast("0.8.0", self.release, self.info, 1234, "test signature")

    def test_matching_github_notes_embedded_without_html_or_external_note_fetch(self):
        item = ET.fromstring(self.make()).find("channel/item")
        notes = item.find("description")
        self.assertEqual(notes.get(f"{{{appcast.SPARKLE}}}format"), "markdown")
        self.assertEqual(notes.text, "## Changelog\n\n" + self.release["body"])
        self.assertIsNone(item.find(f"{{{appcast.SPARKLE}}}releaseNotesLink"))
        self.assertEqual(item.find(f"{{{appcast.SPARKLE}}}version").text, "80")
        self.assertEqual(item.find(f"{{{appcast.SPARKLE}}}shortVersionString").text, "0.8.0")
        self.assertEqual(item.find("enclosure").get("url"), "https://appea.rs/downloads/v0.8.0/Appears.dmg")

    def test_wrong_tag_draft_prerelease_missing_notes_and_wrong_repo_are_rejected(self):
        for key, value in [("tag_name", "v0.7.0"), ("draft", True), ("prerelease", True),
                           ("body", " \n"), ("html_url", "https://github.com/other/appears/releases/tag/v0.8.0")]:
            with self.subTest(key=key):
                previous = self.release[key]
                self.release[key] = value
                with self.assertRaises(ValueError):
                    self.make()
                self.release[key] = previous

    def test_built_app_must_match_release(self):
        self.info["CFBundleShortVersionString"] = "0.7.0"
        with self.assertRaises(ValueError):
            self.make()


if __name__ == "__main__":
    unittest.main()
