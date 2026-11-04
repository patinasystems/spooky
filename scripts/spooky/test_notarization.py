"""Release-policy checks use mocked Apple tools; never submit or sign software."""
from pathlib import Path
import json
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import notarization


DIGEST = 'A' * 40
AUTHORITY = 'Developer ID Application: Example Company (ABCDEFGHIJ)'
IDENTITIES = f'  1) {DIGEST} "{AUTHORITY}"\n  2) {"B" * 40} "Apple Distribution: Example (ABCDEFGHIJ)"\n'
SUBMISSION = '12345678-1234-1234-1234-123456789012'


def result(stdout='', stderr='', code=0):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class NotarizationTests(unittest.TestCase):
    def test_development_and_distribution_are_not_developer_id(self):
        with patch.object(notarization, 'run', return_value=result(
                f'1) {DIGEST} "Apple Development: Example (ABCDEFGHIJ)"\n'
                f'2) {"B" * 40} "Apple Distribution: Example (ABCDEFGHIJ)"')):
            with self.assertRaisesRegex(ValueError, 'No usable Developer ID Application'):
                notarization.developer_id(DIGEST)

    def test_resolves_exact_certificate_name_or_fingerprint_only(self):
        with patch.object(notarization, 'run', return_value=result(IDENTITIES)):
            self.assertEqual(notarization.developer_id(DIGEST.lower())['authority'], AUTHORITY)
            self.assertEqual(notarization.developer_id(AUTHORITY)['sha1'], DIGEST)
            for identity in [None, 'Example', 'B' * 40]:
                with self.subTest(identity=identity), self.assertRaises(ValueError):
                    notarization.developer_id(identity)

    def test_preflight_requires_explicit_profile(self):
        with patch.object(notarization, 'run', return_value=result(IDENTITIES)):
            with self.assertRaisesRegex(ValueError, 'No profile is assumed'):
                notarization.preflight(DIGEST, None)

    def test_credential_probe_is_read_only_and_does_not_echo_errors(self):
        calls = []

        def tool(*args, **kwargs):
            calls.append(args)
            if args[0] == '/usr/bin/security':
                return result(IDENTITIES)
            if 'history' in args:
                return result(stderr='private authentication response', code=1)
            return result('/tool')

        with patch.object(notarization, 'run', side_effect=tool):
            with self.assertRaises(ValueError) as error:
                notarization.preflight(DIGEST, 'explicit-profile', check_credentials=True)
        self.assertNotIn('private authentication response', str(error.exception))
        self.assertTrue(any('history' in call for call in calls))
        self.assertFalse(any('submit' in call or 'store-credentials' in call for call in calls))

    def test_signature_requires_runtime_timestamp_and_matching_team(self):
        details = f'CodeDirectory v=20500 flags=0x10000(runtime)\nAuthority={AUTHORITY}\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Today\n'
        with patch.object(notarization, 'reject_debug_entitlement'), patch.object(
                notarization, 'run', return_value=result(stderr=details)):
            self.assertEqual(notarization.verify_developer_signature(Path('Spooky.app')), 'ABCDEFGHIJ')
            with self.assertRaisesRegex(ValueError, 'inconsistent signing team'):
                notarization.verify_developer_signature(Path('Nested.xpc'), team='OTHERTEAM1')
        for old, new, message in [('flags=0x10000(runtime)', 'flags=0x0(none)', 'Hardened Runtime'),
                                  ('Timestamp=Today', 'Signed Time=Today', 'Secure signing timestamp'),
                                  (AUTHORITY, 'Apple Distribution: Example', 'Developer ID Application')]:
            with self.subTest(message=message), patch.object(notarization, 'run', return_value=result(
                    stderr=details.replace(old, new))):
                with self.assertRaisesRegex(ValueError, message):
                    notarization.verify_developer_signature(Path('Spooky.app'))

    def test_rejects_nested_debug_entitlement(self):
        for value in [True, 1, 'true']:
            with self.subTest(value=value), patch.object(notarization, 'run', return_value=result(
                    plistlib.dumps({'com.apple.security.get-task-allow': value}).decode())):
                with self.assertRaisesRegex(ValueError, 'Debugging entitlement'):
                    notarization.reject_debug_entitlement(Path('Nested.xpc'))

    def test_accepted_submission_keeps_receipt_and_fetches_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            log_dir = Path(temporary)
            with patch.object(notarization, 'run', side_effect=[
                result(json.dumps({'id': SUBMISSION, 'status': 'Accepted'})), result()
            ]) as tool:
                receipt = notarization.submit(Path('Spooky.zip'), 'explicit-profile', log_dir, 'app')
            self.assertEqual(receipt['status'], 'Accepted')
            self.assertEqual(json.loads(next(log_dir.glob('*-submission.json')).read_text()), receipt)
            self.assertIn('log', tool.call_args_list[1].args)

    def test_rejected_or_incomplete_submissions_never_become_releases(self):
        for status in ['Invalid', 'In Progress', 'Rejected', None]:
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                with patch.object(notarization, 'run', side_effect=[
                    result(json.dumps({'id': SUBMISSION, 'status': status})), result()
                ]):
                    with self.assertRaisesRegex(ValueError, 'not accepted'):
                        notarization.submit(Path('Spooky.dmg'), 'explicit-profile', Path(temporary), 'dmg')
                self.assertTrue(list(Path(temporary).glob('*-submission.json')))

    def test_invalid_receipt_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(notarization, 'run', return_value=result(
                json.dumps({'id': '../../bad', 'status': 'Accepted'}))):
            with self.assertRaisesRegex(ValueError, 'valid receipt'):
                notarization.submit(Path('Spooky.dmg'), 'explicit-profile', Path(temporary), 'dmg')

    def test_stapling_failure_prevents_gatekeeper_claim(self):
        with patch.object(notarization, 'run', side_effect=subprocess.CalledProcessError(1, ['stapler'])) as tool:
            with self.assertRaises(subprocess.CalledProcessError):
                notarization.staple_and_validate(Path('Spooky.dmg'), disk_image=True)
        self.assertEqual(tool.call_count, 1)

    def test_dmg_ticket_validation_uses_disk_image_gatekeeper_policy(self):
        with patch.object(notarization, 'run', return_value=result()) as tool:
            notarization.verify_ticket(Path('Spooky.dmg'), disk_image=True)
        self.assertIn('validate', tool.call_args_list[0].args)
        self.assertIn('context:primary-signature', tool.call_args_list[1].args)

    def test_read_only_mount_detaches_when_validation_throws(self):
        with patch.object(notarization, 'run', return_value=result()) as tool:
            with self.assertRaisesRegex(ValueError, 'fixture failure'):
                with notarization.mounted_image(Path('Spooky.dmg')) as mount:
                    parent = mount.parent
                    raise ValueError('fixture failure')
        self.assertFalse(parent.exists())
        self.assertIn('-readonly', tool.call_args_list[0].args)
        self.assertIn('-nobrowse', tool.call_args_list[0].args)
        self.assertIn('-noautoopen', tool.call_args_list[0].args)
        self.assertEqual(tool.call_args_list[-1].args[:2], ('/usr/bin/hdiutil', 'detach'))

    def test_failed_detach_never_recursively_deletes_a_mounted_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / 'verify'
            work.mkdir()
            with patch.object(notarization.tempfile, 'mkdtemp', return_value=str(work)), patch.object(
                    notarization, 'run', side_effect=[result(), result(code=1)]):
                with self.assertRaisesRegex(ValueError, 'left mounted'):
                    with notarization.mounted_image(Path('Spooky.dmg')):
                        pass
            self.assertTrue(work.exists())


if __name__ == '__main__':
    unittest.main()
