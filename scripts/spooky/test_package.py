"""Read-only admission checks for preview packaging; no signing or DMG creation."""
from pathlib import Path
import plistlib
import runpy
import tempfile
import unittest


read_bundle = runpy.run_path(str(Path(__file__).with_name("package.py")))["read_bundle"]


class PackageAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Spooky.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {
            "CFBundleIdentifier": "com.patinasystems.spooky",
            "CFBundleDisplayName": "Spooky",
            "CFBundleExecutable": "ghostty",
            "CFBundleShortVersionString": "0.1",
            "SpookyNativeInputEnabled": True,
            "SpookyDisableUpstreamUpdates": True,
            "SUEnableAutomaticChecks": False,
        }
        self.write_info()

    def write_info(self):
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)

    def test_accepts_normal_identity_without_changing_metadata(self):
        before = (self.app / "Contents/Info.plist").read_bytes()
        self.assertEqual(read_bundle(self.app), self.info)
        self.assertEqual((self.app / "Contents/Info.plist").read_bytes(), before)

    def test_rejects_candidate_identity_and_unsafe_update_settings(self):
        for key, value in [
            ("CFBundleIdentifier", "com.patinasystems.spooky.rendercheck"),
            ("SpookyNativeInputEnabled", False),
            ("SpookyDisableUpstreamUpdates", False),
            ("SUEnableAutomaticChecks", True),
            ("SUFeedURL", "https://release.files.ghostty.org/appcast.xml"),
            ("CFBundleExecutable", "../../outside"),
            ("CFBundleShortVersionString", "../outside"),
        ]:
            with self.subTest(key=key):
                old = self.info.copy()
                self.info[key] = value
                self.write_info()
                with self.assertRaises(ValueError):
                    read_bundle(self.app)
                self.info = old
                self.write_info()

    def test_rejects_test_and_symbol_residue(self):
        for name in ["GhosttyTests.xctest", "GhosttyTests.xctest.dSYM"]:
            with self.subTest(name=name):
                residue = self.app / "Contents" / name
                residue.mkdir()
                with self.assertRaisesRegex(ValueError, "residue"):
                    read_bundle(self.app)
                residue.rmdir()

    def test_preserves_internal_framework_symlinks_but_rejects_external_ones(self):
        actual = self.app / "Contents/Actual"
        actual.mkdir()
        link = self.app / "Contents/Current"
        link.symlink_to("Actual")
        self.assertEqual(read_bundle(self.app), self.info)
        link.unlink()
        link.symlink_to(Path(self.temporary.name))
        with self.assertRaisesRegex(ValueError, "external symlink"):
            read_bundle(self.app)


if __name__ == "__main__":
    unittest.main()
