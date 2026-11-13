"""Read-only admission checks for preview packaging; no signing or DMG creation."""
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import package as packager


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

    def test_uses_system_index_without_a_bundled_helper(self):
        self.assertEqual(read_file_search(self.app), {"backend": "spotlight", "app_owned_index": False})

    def test_rejects_legacy_search_files_in_incremental_builds(self):
        for relative in ("Contents/Helpers/spooky-fsearch", "Contents/Resources/FSearch"):
            with self.subTest(relative=relative):
                residue = self.app / relative
                residue.parent.mkdir(parents=True, exist_ok=True)
                residue.write_bytes(b"legacy fixture")
                with self.assertRaisesRegex(ValueError, "Legacy filename-search residue"):
                    read_bundle(self.app)
                residue.unlink()
                residue.symlink_to(self.app / 'missing')
                with self.assertRaisesRegex(ValueError, "Legacy filename-search residue"):
                    read_file_search(self.app)
                residue.unlink()

    def test_incremental_cleanup_removes_only_legacy_bundle_files(self):
        clean = runpy.run_path(str(Path(__file__).with_name("clean-legacy-file-search.py")))["clean"]
        helper = self.app / "Contents/Helpers/spooky-fsearch"
        resources = self.app / "Contents/Resources/FSearch"
        helper.parent.mkdir()
        helper.write_bytes(b"legacy executable")
        resources.mkdir(parents=True)
        (resources / "LICENSE").write_text("legacy notice")
        other = helper.with_name("other-helper")
        other.write_bytes(b"keep me")
        clean(self.app / "Contents")
        clean(self.app / "Contents")
        self.assertFalse(helper.exists())
        self.assertFalse(resources.exists())
        self.assertEqual(other.read_bytes(), b"keep me")
        self.assertEqual(read_bundle(self.app), self.info)

    def test_incremental_cleanup_does_not_follow_symlinks(self):
        clean = runpy.run_path(str(Path(__file__).with_name("clean-legacy-file-search.py")))["clean"]
        outside = Path(self.temporary.name) / "unrelated"
        outside.mkdir()
        (outside / "keep").write_text("untouched")
        resources = self.app / "Contents/Resources/FSearch"
        resources.parent.mkdir()
        resources.symlink_to(outside, target_is_directory=True)
        clean(self.app / "Contents")
        self.assertFalse(resources.is_symlink())
        self.assertEqual((outside / "keep").read_text(), "untouched")


class PackageNotarizationFlowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'Spooky.app'
        for relative in ['Contents/MacOS/ghostty']:
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'executable fixture')
        self.info = dict(CFBundleExecutable='ghostty', CFBundleShortVersionString='0.1', CFBundleVersion='1')
        self.args = SimpleNamespace(app=self.app, output_dir=self.root / 'output', source_commit='a' * 40,
                                    identity='Developer ID Application: Fixture', notary_profile='explicit-profile',
                                    preflight=False, overwrite=False)
        self.calls = []

    def tool(self, *args):
        self.calls.append(args)
        if args[:2] == ('/usr/bin/ditto', '-c'):
            Path(args[-1]).write_bytes(b'zip fixture')
        elif args[0] == '/usr/bin/ditto':
            shutil.copytree(args[1], args[2])
        return subprocess.CompletedProcess(args, 0, 'arm64' if args[0] == '/usr/bin/lipo' else '', '')

    def staple(self, path, **kwargs):
        if path.suffix == '.app':
            (path / 'Contents/stapled-ticket').write_text('ticket')
        else:
            path.write_bytes(path.read_bytes() + b' stapled')

    def image(self, path, volume, **kwargs):
        self.assertTrue((Path(kwargs['defines']['app']) / 'Contents/stapled-ticket').exists())
        Path(path).write_bytes(b'dmg containing stapled app')

    def execute(self, fail_second=False):
        receipts = [dict(id='12345678-1234-1234-1234-123456789012', status='Accepted')]
        receipts.append(ValueError('DMG notarization rejected') if fail_second else
                        dict(id='23456789-1234-1234-1234-123456789012', status='Accepted'))
        with patch.object(packager.sys, 'platform', 'darwin'), patch.object(
                packager.importlib.metadata, 'version', return_value='1.6.7'), patch.dict(
                packager.sys.modules, {'dmgbuild': SimpleNamespace(build_dmg=self.image)}), patch.object(
                packager, 'read_bundle', return_value=self.info), patch.object(
                packager, 'read_file_search', return_value=packager.FILE_SEARCH.copy()), patch.object(
                packager, 'signing_targets', side_effect=lambda app: [app]), patch.object(
                packager, 'sign_app'), patch.object(packager, 'signing_details', return_value={}), patch.object(
                packager, 'run', side_effect=self.tool), patch.object(packager.notarization, 'preflight',
                return_value={'sha1': 'A' * 40}), patch.object(packager.notarization, 'reject_debug_entitlement'), patch.object(
                packager.notarization, 'verify_developer_signature', return_value='ABCDEFGHIJ'), patch.object(
                packager.notarization, 'submit', side_effect=receipts), patch.object(
                packager.notarization, 'staple_and_validate', side_effect=self.staple):
            return packager.package(self.args)

    def test_notarized_manifest_hashes_final_stapled_dmg_and_source_is_unchanged(self):
        source_before = (self.app / 'Contents/MacOS/ghostty').read_bytes()
        manifest = self.execute()
        self.assertTrue(manifest['notarized'])
        self.assertEqual(manifest['release_kind'], 'release')
        self.assertEqual(manifest['file_search'], {'backend': 'spotlight', 'app_owned_index': False})
        image = self.args.output_dir / manifest['dmg']['file']
        self.assertTrue(image.read_bytes().endswith(b' stapled'))
        self.assertEqual(manifest['dmg']['sha256'], packager.sha256(image))
        self.assertEqual(image.read_bytes(), (self.args.output_dir / 'Spooky.dmg').read_bytes())
        self.assertEqual((self.app / 'Contents/MacOS/ghostty').read_bytes(), source_before)
        self.assertFalse((self.app / 'Contents/stapled-ticket').exists())

    def test_second_notarization_failure_publishes_no_release_artifacts(self):
        with self.assertRaisesRegex(ValueError, 'DMG notarization rejected'):
            self.execute(fail_second=True)
        self.assertFalse(list(self.args.output_dir.glob('*.dmg')))
        self.assertFalse(list(self.args.output_dir.glob('*.json')))
        self.assertFalse((self.args.output_dir / 'SHA256SUMS').exists())

    def test_empty_profile_cannot_silently_fall_back_to_preview(self):
        self.args.notary_profile = ''
        with patch.object(packager.sys, 'platform', 'darwin'):
            with self.assertRaisesRegex(ValueError, '--notary-profile'):
                packager.package(self.args)


if __name__ == "__main__":
    unittest.main()
