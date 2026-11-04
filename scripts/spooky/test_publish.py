"""Publisher admission tests; no network requests or uploads."""
import hashlib
import json
from contextlib import contextmanager
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import publish


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dmg = self.root / 'Spooky-0.1-123456789-arm64.dmg'
        self.dmg.write_bytes(b'fixture disk image')
        self.path = self.dmg.with_suffix('.json')
        self.data = dict(product='Spooky', bundle_identifier='com.patinasystems.spooky',
                         architecture='arm64', version='0.1', source_commit='123456789abcdef',
                         upstream_updates_disabled=True, release_kind='preview', notarized=False,
                         dmg=dict(file=self.dmg.name, sha256=hashlib.sha256(self.dmg.read_bytes()).hexdigest(),
                                  bytes=self.dmg.stat().st_size))
        self.write()

    def write(self):
        self.path.write_text(json.dumps(self.data))
        (self.root / 'SHA256SUMS').write_text('\n'.join([
            f'{publish.digest(self.dmg)}  {self.dmg.name}',
            f'{publish.digest(self.dmg)}  Spooky.dmg',
            f'{publish.digest(self.path)}  {self.path.name}',
        ]) + '\n')

    def notarized(self):
        receipt = dict(id='12345678-1234-1234-1234-123456789012', status='Accepted',
                       stapled=True, gatekeeper_accepted=True)
        self.data.update(notarized=True, release_kind='release', notarization=dict(app=receipt, dmg=receipt))
        self.write()

    def test_preview_requires_explicit_override(self):
        with self.assertRaisesRegex(ValueError, '--allow-unnotarized-preview'):
            publish.artifacts(self.path)
        self.assertEqual(len(publish.artifacts(self.path, allow_unnotarized_preview=True)), 5)

    def test_notarized_boolean_alone_is_not_evidence(self):
        self.data.update(notarized=True, release_kind='release')
        self.write()
        with self.assertRaisesRegex(ValueError, 'notarization receipt'):
            publish.artifacts(self.path)

    def test_notarized_release_requires_real_local_signature_and_ticket_checks(self):
        self.notarized()
        with patch.object(publish.notarization, 'verify_developer_signature', return_value='ABCDEFGHIJ') as signature, patch.object(
                publish.notarization, 'verify_ticket') as ticket, patch.object(publish, 'verify_contained_app') as contained:
            self.assertEqual(len(publish.artifacts(self.path)), 5)
        signature.assert_called_once_with(self.dmg, runtime=False)
        ticket.assert_called_once_with(self.dmg, disk_image=True)
        contained.assert_called_once_with(self.dmg, self.data, 'ABCDEFGHIJ')

    def test_preview_override_cannot_bypass_a_false_notarized_claim(self):
        self.notarized()
        with patch.object(publish.notarization, 'verify_developer_signature'), patch.object(
                publish.notarization, 'verify_ticket', side_effect=subprocess.CalledProcessError(1, ['stapler'])):
            with self.assertRaises(subprocess.CalledProcessError):
                publish.artifacts(self.path, allow_unnotarized_preview=True)

    def test_modified_dmg_fails_before_apple_checks(self):
        self.notarized()
        self.dmg.write_bytes(b'changed')
        with patch.object(publish.notarization, 'verify_ticket') as ticket:
            with self.assertRaisesRegex(ValueError, 'does not match'):
                publish.artifacts(self.path)
        ticket.assert_not_called()

    def test_invalid_version_or_commit_cannot_become_object_names(self):
        for key, value in [('version', '1?secret'), ('source_commit', '../bad')]:
            with self.subTest(key=key):
                old = self.data[key]
                self.data[key] = value
                self.write()
                with self.assertRaisesRegex(ValueError, 'invalid source commit or version'):
                    publish.artifacts(self.path, allow_unnotarized_preview=True)
                self.data[key] = old

    def test_dry_run_validates_but_never_uploads(self):
        with patch.object(publish, 'remote_digest', return_value=None), patch.object(
                publish.subprocess, 'run') as upload:
            publish.publish(self.path, True, allow_unnotarized_preview=True)
        upload.assert_not_called()

    def test_default_rejection_precedes_network_and_upload(self):
        with patch.object(publish, 'remote_digest') as network, patch.object(publish.subprocess, 'run') as upload:
            with self.assertRaisesRegex(ValueError, 'must be notarized'):
                publish.publish(self.path, True)
        network.assert_not_called()
        upload.assert_not_called()

    def test_contained_app_is_verified_and_detached_even_on_a_nested_failure(self):
        app = self.root / 'Spooky.app'
        main = app / 'Contents/MacOS/ghostty'
        helper = app / 'Contents/Helpers/spooky-fsearch'
        for path in (main, helper):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(path.name.encode())
        (self.root / 'Applications').symlink_to('/Applications')
        info = dict(CFBundleShortVersionString='0.1', CFBundleVersion='1', LSMinimumSystemVersion='13.0',
                    CFBundleExecutable='ghostty')
        self.data.update(build_number='1', minimum_macos='13.0', packaged_executable_sha256=publish.digest(main),
                         file_search=dict(packaged_executable_sha256=publish.digest(helper), upstream_revision='fixture'))
        state = {'detached': False}

        @contextmanager
        def mounted(_):
            try:
                yield self.root
            finally:
                state['detached'] = True

        with patch.object(publish.notarization, 'mounted_image', side_effect=mounted), patch.object(
                publish.packager, 'read_bundle', return_value=info) as admission, patch.object(
                publish.packager, 'read_file_search', return_value={'revision': 'fixture'}), patch.object(
                publish.packager, 'run', return_value=subprocess.CompletedProcess([], 0, 'arm64', '')), patch.object(
                publish.packager, 'signing_targets', return_value=[main, helper, app]), patch.object(
                publish.notarization, 'verify_developer_signature') as signature, patch.object(
                publish.notarization, 'verify_ticket') as ticket:
            publish.verify_contained_app(self.dmg, self.data, 'ABCDEFGHIJ')
            self.assertTrue(state['detached'])
            admission.assert_called_once_with(app)
            self.assertEqual(signature.call_count, 3)
            self.assertEqual(signature.call_args_list[1].kwargs, {'team': 'ABCDEFGHIJ'})
            ticket.assert_called_once_with(app)
            state['detached'] = False
            signature.side_effect = ValueError('Nested helper lacks Hardened Runtime')
            with self.assertRaisesRegex(ValueError, 'Hardened Runtime'):
                publish.verify_contained_app(self.dmg, self.data, 'ABCDEFGHIJ')
            self.assertTrue(state['detached'])
            ticket.reset_mock()
            helper.write_bytes(b'changed helper')
            with self.assertRaisesRegex(ValueError, 'manifest hashes'):
                publish.verify_contained_app(self.dmg, self.data, 'ABCDEFGHIJ')
            ticket.assert_not_called()

    def test_disk_image_cannot_redirect_app_or_install_shortcut_outside_its_contract(self):
        @contextmanager
        def mounted(_):
            yield self.root

        app = self.root / 'Spooky.app'
        outside = self.root / 'outside'
        outside.mkdir()
        app.symlink_to(outside)
        with patch.object(publish.notarization, 'mounted_image', side_effect=mounted), patch.object(
                publish.packager, 'read_bundle') as admission:
            with self.assertRaisesRegex(ValueError, 'real Spooky.app'):
                publish.verify_contained_app(self.dmg, self.data, 'ABCDEFGHIJ')
            app.unlink()
            app.mkdir()
            with self.assertRaisesRegex(ValueError, 'Applications shortcut'):
                publish.verify_contained_app(self.dmg, self.data, 'ABCDEFGHIJ')
            (self.root / 'Applications').symlink_to('/tmp')
            with self.assertRaisesRegex(ValueError, 'Applications shortcut'):
                publish.verify_contained_app(self.dmg, self.data, 'ABCDEFGHIJ')
        admission.assert_not_called()


if __name__ == '__main__':
    unittest.main()
