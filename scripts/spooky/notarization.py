"""Developer ID preflight and fail-closed notarization for Spooky releases.

Only a caller-supplied Keychain profile is used. This module never reads or
prints passwords, API private keys, or Keychain credential contents.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid


def run(*args: str | Path, check: bool = True, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(arg) for arg in args], check=check, text=True,
                          capture_output=True, timeout=timeout)


def developer_id(identity: str | None) -> dict:
    """Resolve an exact public certificate name or SHA-1; never export a key."""
    result = run('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning')
    identities = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', result.stdout, re.MULTILINE)
    available = [(digest, name) for digest, name in identities if name.startswith('Developer ID Application: ')]
    if not available:
        raise ValueError('No usable Developer ID Application identity is available. The Apple Developer '
                         'Account Holder must create/import that certificate with its private key on this Mac. '
                         'Apple Development and Apple Distribution certificates cannot substitute.')
    if not identity:
        raise ValueError('Choose a Developer ID Application identity explicitly with --identity '
                         '(the exact certificate name or its SHA-1 from security find-identity -v -p codesigning).')
    matches = [(digest, name) for digest, name in available
               if identity.upper() == digest.upper() or identity == name]
    if len(matches) != 1:
        raise ValueError('--identity must select exactly one available Developer ID Application certificate.')
    digest, name = matches[0]
    return {'sha1': digest.upper(), 'authority': name}


def preflight(identity: str | None, profile: str | None, *, check_credentials: bool = False) -> dict:
    certificate = developer_id(identity)
    if not profile or not profile.strip():
        raise ValueError('Supply --notary-profile with a profile you configured interactively using '
                         'xcrun notarytool store-credentials <profile-name>. No profile is assumed.')
    run('/usr/bin/xcrun', '--find', 'notarytool')
    run('/usr/bin/xcrun', '--find', 'stapler')
    if check_credentials:
        # Read-only authentication probe. Suppress both history and raw errors:
        # neither past submissions nor credential/account details are needed.
        result = run('/usr/bin/xcrun', 'notarytool', 'history', '--keychain-profile', profile,
                     '--output-format', 'json', check=False)
        if result.returncode:
            raise ValueError('Notary profile is missing, inaccessible, or its credentials were rejected. '
                             'Configure/repair it with xcrun notarytool store-credentials <profile-name> '
                             'and rerun preflight. No credentials or account history were printed.')
    return {**certificate, 'credentials_validated': check_credentials}


def reject_debug_entitlement(path: Path) -> None:
    value = run('/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', path).stdout
    if value and plistlib.loads(value.encode()).get('com.apple.security.get-task-allow') not in (None, False):
        raise ValueError(f'Debugging entitlement is not allowed in release code: {path.name}')


def verify_developer_signature(path: Path, *, team: str | None = None, runtime: bool = True) -> str:
    details = run('/usr/bin/codesign', '--display', '--verbose=4', path).stderr
    authorities = [line.partition('=')[2] for line in details.splitlines() if line.startswith('Authority=')]
    actual_team = next((line.partition('=')[2] for line in details.splitlines()
                        if line.startswith('TeamIdentifier=')), None)
    if not authorities or not authorities[0].startswith('Developer ID Application: '):
        raise ValueError(f'Expected Developer ID Application signing on {path.name}')
    if not actual_team or actual_team == 'not set' or (team is not None and actual_team != team):
        raise ValueError(f'Release code has a missing or inconsistent signing team: {path.name}')
    flags = re.search(r'^CodeDirectory .*?flags=0x([0-9a-fA-F]+)', details, re.MULTILINE)
    if runtime and (not flags or not (int(flags[1], 16) & 0x10000)):
        raise ValueError(f'Hardened Runtime is missing from {path.name}')
    if not re.search(r'^Timestamp=.+', details, re.MULTILINE):
        raise ValueError(f'Secure signing timestamp is missing from {path.name}')
    reject_debug_entitlement(path)
    return actual_team


def submit(artifact: Path, profile: str, log_dir: Path, label: str) -> dict:
    """No Accepted status, no release. Keep sanitized receipts even on failure."""
    log_dir.mkdir(parents=True, exist_ok=True)
    result = run('/usr/bin/xcrun', 'notarytool', 'submit', artifact,
                 '--keychain-profile', profile, '--output-format', 'json', '--wait', '--timeout', '20m',
                 check=False, timeout=1320)
    try:
        response = json.loads(result.stdout)
        submission_id = str(uuid.UUID(response['id']))
    except (ValueError, KeyError, TypeError) as error:
        raise ValueError('Notary submission did not return a valid receipt. No release was produced; '
                         'check the supplied profile and Apple service status.') from error
    receipt = {'id': submission_id, 'status': response.get('status'), 'artifact': artifact.name}
    receipt_path = log_dir / f'{label}-{submission_id}-submission.json'
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    log_path = log_dir / f'{label}-{submission_id}-log.json'
    if receipt['status'] in {'Accepted', 'Invalid', 'Rejected'}:
        log_result = run('/usr/bin/xcrun', 'notarytool', 'log', submission_id,
                         '--keychain-profile', profile, log_path, check=False)
        if log_result.returncode:
            raise ValueError(f'Could not retrieve the notary log; receipt saved at {receipt_path}')
    if result.returncode or receipt['status'] != 'Accepted':
        raise ValueError(f'Notarization was not accepted (status {receipt["status"]!r}); '
                         f'no release was produced. Inspect {receipt_path}. '
                         'A timed-out submission may still be processing; do not assume it failed or resubmit blindly.')
    return receipt


def staple_and_validate(path: Path, *, disk_image: bool = False) -> None:
    run('/usr/bin/xcrun', 'stapler', 'staple', path)
    verify_ticket(path, disk_image=disk_image)


def verify_ticket(path: Path, *, disk_image: bool = False) -> None:
    run('/usr/bin/xcrun', 'stapler', 'validate', path)
    if disk_image:
        run('/usr/sbin/spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature',
            '--verbose=2', path)
    else:
        run('/usr/bin/codesign', '--verify', '--strict', '--deep', path)
        run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', path)


@contextmanager
def mounted_image(path: Path):
    """Mount only for inspection; never browse, launch, or mutate its contents."""
    work = Path(tempfile.mkdtemp(prefix='spooky-release-verify-'))
    mount = work / 'image'
    mount.mkdir()
    attached = False
    try:
        run('/usr/bin/hdiutil', 'attach', path, '-readonly', '-nobrowse', '-noautoopen',
            '-mountpoint', mount, '-plist')
        attached = True
        yield mount
    finally:
        # Also detect a partial attach before an hdiutil error. Never recursively
        # clean the temporary directory while a mounted volume remains there.
        if attached or os.path.ismount(mount):
            result = run('/usr/bin/hdiutil', 'detach', mount, check=False)
            if result.returncode:
                raise ValueError(f'Could not detach read-only verification image at {mount}; '
                                 'it was left mounted and no temporary tree was deleted.')
        shutil.rmtree(work)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', help='Exact Developer ID Application certificate name or SHA-1')
    parser.add_argument('--notary-profile', help='An explicitly configured notarytool Keychain profile')
    parser.add_argument('--check-credentials', action='store_true',
                        help='Authenticate read-only with Apple; do not upload or display account history')
    args = parser.parse_args()
    try:
        print(json.dumps(preflight(args.identity, args.notary_profile,
                                   check_credentials=args.check_credentials), indent=2))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        if isinstance(error, subprocess.SubprocessError):
            parser.exit(1, 'Preflight failed: an Apple tool failed or timed out. No signing or upload was performed.\n')
        parser.exit(1, f'Preflight failed: {error}\n')


if __name__ == '__main__':
    main()
