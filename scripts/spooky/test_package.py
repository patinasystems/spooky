"""Read-only admission checks for preview packaging; no signing or DMG creation."""
from pathlib import Path
import json
import hashlib
import plistlib
import runpy
import tempfile
import unittest


read_bundle = runpy.run_path(str(Path(__file__).with_name("package.py")))["read_bundle"]
read_file_search = runpy.run_path(str(Path(__file__).with_name("package.py")))["read_file_search"]


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

    def test_rejects_diagnostic_capture_and_private_index_settings(self):
        for key, value in [
            ("SpookyWindowCaptureEnabled", True),
            ("SpookyWindowCaptureDirectory", "/tmp/test-window"),
            ("SpookyWindowCaptureVideo", False),
            ("SpookyPerformanceDiagnostics", True),
            ("SpookyPerformanceDiagnosticsPath", "/tmp/test-ui.jsonl"),
            ("SpookyFileSearchDiagnosticsPath", "/tmp/test-index.jsonl"),
            ("SpookyFileSearchDiagnosticIndexDirectory", "/tmp/test-index"),
        ]:
            with self.subTest(key=key):
                self.info[key] = value
                self.write_info()
                with self.assertRaisesRegex(ValueError, "diagnostic"):
                    read_bundle(self.app)
                del self.info[key]
                self.write_info()

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

    def test_requires_pinned_names_only_helper_and_license(self):
        with self.assertRaisesRegex(ValueError, "missing.*helper"):
            read_file_search(self.app)
        helper = self.app / "Contents/Helpers/spooky-fsearch"
        helper.parent.mkdir()
        helper.write_bytes(b"fixture")
        helper.chmod(0o755)
        resources = self.app / "Contents/Resources/FSearch"
        resources.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "license"):
            read_file_search(self.app)
        source = Path(__file__).parent / "fsearch"
        (resources / "LICENSE.fsearch").write_bytes((source / "LICENSE.fsearch").read_bytes())
        (resources / "LICENSE.dependencies").write_bytes((source / "LICENSE.dependencies").read_bytes())
        pin = json.loads((source / "upstream.json").read_text())
        data = dict(revision=pin["revision"], content_indexing=False,
                    idle_keep_warm=False, architectures=["arm64"],
                    patch_sha256=hashlib.sha256((source / pin["patch"]).read_bytes()).hexdigest(),
                    cargo_lock_sha256=hashlib.sha256((source / "Cargo.lock").read_bytes()).hexdigest(),
                    dependency_licenses_sha256=hashlib.sha256((source / "LICENSE.dependencies").read_bytes()).hexdigest(),
                    adapter_source_sha256=hashlib.sha256((source / "Cargo.toml").read_bytes() + b"\0"
                                                       + (source / "src/main.rs").read_bytes()).hexdigest())
        manifest = resources / "fsearch-provenance.json"
        manifest.write_text(json.dumps(data))
        self.assertEqual(read_file_search(self.app), data)
        for key, value in [("content_indexing", True), ("idle_keep_warm", True),
                           ("revision", "wrong"), ("architectures", ["x86_64"]),
                           ("patch_sha256", "wrong"), ("cargo_lock_sha256", "wrong"),
                           ("adapter_source_sha256", "wrong")]:
            manifest.write_text(json.dumps(dict(data, **{key: value})))
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "provenance"):
                read_file_search(self.app)
        manifest.write_text(json.dumps(data))
        (resources / "LICENSE.dependencies").unlink()
        with self.assertRaisesRegex(ValueError, "dependency licenses"):
            read_file_search(self.app)


if __name__ == "__main__":
    unittest.main()
