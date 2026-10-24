"""REMOTE synthetic guard metadata controls, never SDK/artifact qualification.

All named SDK fixture files below contain explicitly synthetic text, not native
archives, generated bindings or executable code. No installer success is mocked.
Git F/tree/lock/profile are real. This module must only run in remote preparation.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

from bounded_capture import capture

import sdk_profiles
import validate_local_sdk_profile as guard

SOURCE = os.environ['PROFILE_CONTROL_SOURCE_SHA']
RUN = os.environ['GITHUB_RUN_ID']
HERE = Path(__file__).resolve().parent


def sha(value):
    return hashlib.sha256(value).hexdigest()


def encoded(value):
    return json.dumps(value, indent=2) + '\n'


class LocalSdkProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / 'package'
        self.package.mkdir()
        self.make_fixture()

    def write(self, name, data):
        path = self.package / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def make_fixture(self, profile='default', platform='macos'):
        if self.package.exists():
            shutil.rmtree(self.package)  # Only this test's synthetic TemporaryDirectory.
        self.package.mkdir()
        tree, lock, release = sdk_profiles.trusted_source_identity(SOURCE)
        compiler = {'rustc': 'SYNTHETIC METADATA; NOT AN OBSERVED COMPILER',
                    'cargo': 'SYNTHETIC METADATA; NOT AN OBSERVED COMPILER'}
        payload = b'SYNTHETIC GUARD CONTROL ONLY; NOT AN SDK OR NATIVE ARCHIVE\n'
        slices = ['macos-arm64'] if platform == 'macos' else ['ios-arm64', 'ios-arm64-simulator']
        self.files = {'MarmotKit.swift': sha(payload), 'PrivacyInfo.xcprivacy': sha(payload)}
        for part in slices:
            for name in ['libmarmot_uniffi.a', 'Headers/marmot_uniffiFFI.h', 'Headers/module.modulemap']:
                relative = 'MarmotKit.xcframework/' + part + '/' + name
                self.files[relative] = sha(payload)
                self.write('Artifacts/' + relative, payload)
        self.files['MarmotKit.xcframework/Info.plist'] = sha(payload)
        self.write('Artifacts/MarmotKit.xcframework/Info.plist', payload)
        self.write('LOCAL_BUILD_INPUTS/MarmotKit.swift', payload)
        self.write('Sources/MarmotKit/MarmotKit.swift', payload)
        self.write('Sources/MarmotKit/Resources/PrivacyInfo.xcprivacy', payload)
        self.original = {'source_sha': SOURCE, 'builder_sha': SOURCE, 'cargo_lock_sha256': lock,
                         'features': sdk_profiles.features(profile), **compiler,
                         'artifacts': {key: {'sha256': value} for key, value in self.files.items()}}
        inputs = {part: {'part': part, 'source_sha': SOURCE, 'builder_sha': SOURCE,
                         'workflow_run_id': RUN, 'sdk_profile': profile, 'source_tree': tree,
                         'cargo_lock_sha256': lock, 'release_profile_sha256': release,
                         'feature_set': {'otlp_export': True, 'product_analytics_export': True,
                                         'experimental_device_sync': profile == 'experimental'},
                         **compiler} for part in sdk_profiles.PARTS}
        self.proof = {'synthetic_metadata_fixture_only': True, 'schema_version': 2,
                      'source_sha': SOURCE, 'builder_sha': SOURCE, 'workflow_run_id': RUN,
                      'source_tree': tree, 'cargo_lock_sha256': lock, 'release_profile_sha256': release,
                      'sdk_profile': profile, 'features': sdk_profiles.features(profile),
                      'compiler': compiler, 'uniffi_version': 'SYNTHETIC METADATA',
                      'input_provenance': inputs, 'platforms': {}}
        for target in ['macos', 'ios']:
            self.proof['platforms'][target] = {'manifest': copy.deepcopy(self.original),
                'bundle': f'SYNTHETIC-NOT-AN-ARTIFACT-{target}.zip', 'sha256': '0' * 64,
                'files': copy.deepcopy(self.files)}
        self.profile, self.platform = profile, platform
        self.save()

    def save(self):
        record = self.proof['platforms'][self.platform]
        record['manifest'] = copy.deepcopy(self.original)
        raw_q, raw_manifest = encoded(self.proof), encoded(self.original)
        receipt = {'qualification_json': raw_q, 'qualification_sha256': sha(raw_q.encode()),
                   'manifest_json': raw_manifest, 'manifest_sha256': sha(raw_manifest.encode()),
                   'platform': self.platform, 'bundle': record['bundle'], 'bundle_sha256': record['sha256'],
                   'original_swift_relative_path': 'LOCAL_BUILD_INPUTS/MarmotKit.swift'}
        self.local = dict(self.original, uniffi_version=self.proof['uniffi_version'],
                          sdk_profile=self.profile, workflow_run_id=RUN, qualification_receipt=receipt,
                          installation='Ephemeral hosted CI overlay; never commit',
                          installed_swift_sha256=guard.digest(self.package / 'Sources/MarmotKit/MarmotKit.swift'))
        self.write('LOCAL_BUILD.json', encoded(self.local).encode())
        self.write('MARMOT_VERSION', (f'mdk-sha: {SOURCE}\nmdk-branch: detached\nmdk-tag: local-{SOURCE}\n'
                   + 'features: ' + ','.join(sdk_profiles.features(self.profile)) + '\n').encode())

    def accept(self, private='0'):
        return guard.verified_profile(self.package, self.platform, self.profile, SOURCE, RUN, private)

    def test_default_synthetic_metadata_accepts_private_zero(self):
        self.assertEqual(self.accept(), 'default')
        self.assertNotIn('experimental-device-sync', self.local['features'])

    def test_ios_synthetic_inventory_accepts_two_slices(self):
        self.make_fixture(platform='ios')
        self.assertEqual(self.accept(), 'default')

    def test_current_experimental_metadata_accepts_private_one(self):
        self.make_fixture(profile='experimental')
        self.assertEqual(self.accept('1'), 'experimental')

    def test_legacy_experimental_original_checks_still_accept(self):
        self.make_fixture(profile='experimental')
        del self.local['qualification_receipt']
        self.write('LOCAL_BUILD.json', encoded(self.local).encode())
        self.assertEqual(guard.legacy_experimental(self.package, 'macos')['source_sha'], SOURCE)

    def test_default_rejects_private_one(self):
        with self.assertRaisesRegex(ValueError, '^Private flag differs from SDK profile$'):
            self.accept('1')

    def test_consistent_lock_spoof_rejected_against_git(self):
        self.proof['cargo_lock_sha256'] = 'f' * 64
        self.original['cargo_lock_sha256'] = 'f' * 64
        for part in self.proof['input_provenance'].values():
            part['cargo_lock_sha256'] = 'f' * 64
        for record in self.proof['platforms'].values():
            record['manifest']['cargo_lock_sha256'] = 'f' * 64
        self.save()
        with self.assertRaisesRegex(ValueError, '^Provenance differs from immutable Git F$'):
            self.accept()

    def test_modified_header_digest_rejected(self):
        self.write('Artifacts/MarmotKit.xcframework/macos-arm64/Headers/marmot_uniffiFFI.h', b'CHANGED SYNTHETIC HEADER\n')
        with self.assertRaisesRegex(ValueError, '^Installed SDK inventory digest differs$'):
            self.accept()

    def test_extra_inventory_file_rejected(self):
        self.write('Artifacts/MarmotKit.xcframework/extra.txt', b'EXTRA SYNTHETIC INPUT\n')
        with self.assertRaisesRegex(ValueError, 'missing or extra'):
            self.accept()

    def test_changed_original_swift_rejected(self):
        self.write('LOCAL_BUILD_INPUTS/MarmotKit.swift', b'CHANGED SYNTHETIC SWIFT\n')
        with self.assertRaisesRegex(ValueError, 'Original Swift differs'):
            self.accept()

    def test_changed_installed_swift_rejected(self):
        self.write('Sources/MarmotKit/MarmotKit.swift', b'CHANGED SYNTHETIC SWIFT\n')
        with self.assertRaisesRegex(ValueError, 'Installed Swift differs'):
            self.accept()

    def test_changed_privacy_digest_rejected(self):
        self.write('Sources/MarmotKit/Resources/PrivacyInfo.xcprivacy', b'CHANGED SYNTHETIC PRIVACY\n')
        with self.assertRaisesRegex(ValueError, 'inventory digest differs'):
            self.accept()

    def test_missing_explicit_source_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Explicit immutable SDK F'):
            guard.verified_profile(self.package, self.platform, self.profile, '', RUN, '0')

    def test_wrong_producer_run_rejected(self):
        with self.assertRaisesRegex(ValueError, 'producer run/features'):
            guard.verified_profile(self.package, self.platform, self.profile, SOURCE, RUN + '1', '0')

    def test_changed_qualification_bytes_rejected(self):
        self.local['qualification_receipt']['qualification_json'] += ' '
        self.write('LOCAL_BUILD.json', encoded(self.local).encode())
        with self.assertRaisesRegex(ValueError, 'Qualification receipt bytes changed'):
            self.accept()

    def test_boolean_schema_rejected(self):
        self.proof['schema_version'] = True
        self.save()
        with self.assertRaisesRegex(ValueError, 'provenance schema'):
            self.accept()

    def test_integer_feature_rejected(self):
        self.proof['input_provenance']['swift']['feature_set']['experimental_device_sync'] = 0
        self.save()
        with self.assertRaisesRegex(ValueError, 'strict booleans'):
            self.accept()


    def shell(self, overrides=None, arguments=(), empty=False):
        app = self.root / 'synthetic-app'
        (app / 'scripts').mkdir(parents=True)
        for name in ['local-device-sync-settings.sh', 'local-sdk-profile-settings.sh',
                     'validate_local_sdk_profile.py', 'sdk_profiles.py']:
            shutil.copy2(HERE / name, app / 'scripts' / name)
        platform = os.environ['PROFILE_CONTROL_APP_PLATFORM']
        relative = 'Vendored/MarmotKit' if platform == 'macos' else 'Packages/MarmotKit'
        if not empty:
            if self.platform != platform:
                self.make_fixture(profile=self.profile, platform=platform)
            target = app / relative
            target.parent.mkdir(parents=True)
            shutil.copytree(self.package, target)
            self.copied_overlay_has_receipt = 'qualification_receipt' in json.loads(
                (target / 'LOCAL_BUILD.json').read_text())
        env = dict(os.environ)
        for name in ['WN_SDK_PROFILE', 'WN_CURRENT_SDK_API', 'WN_EXPERIMENTAL_DEVICE_SYNC',
                     'OTHER_SWIFT_FLAGS', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'SWIFT_FLAGS',
                     'XCODE_XCCONFIG_FILE']:
            env.pop(name, None)
        env.update(WN_SDK_SOURCE_SHA=SOURCE, WN_SDK_RUN_ID=RUN)
        env.update(overrides or {})
        return capture(['bash', '-c',
            'set -e; repo_root=$1; shift; source "$repo_root/scripts/local-device-sync-settings.sh"; '
            'validate_sdk_build_arguments "$@"; '
            'printf "%s|%s|%s\\n" "$WN_CURRENT_SDK_API" "${WN_VERIFIED_SDK_PROFILE:-}" "${device_sync_settings[*]:-}"',
            'guard-control', str(app), *arguments], cwd=app, env=env, timeout=120)

    def test_historical_shell_needs_no_overlay_and_sets_no_flags(self):
        result = self.shell(empty=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '0||\n')

    def test_default_shell_emits_current_only(self):
        result = self.shell({'WN_SDK_PROFILE': 'default', 'WN_EXPERIMENTAL_DEVICE_SYNC': '0'})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '1|default|OTHER_SWIFT_FLAGS=$(inherited) -D WN_CURRENT_SDK_API\n')

    def test_new_experimental_shell_emits_both_flags(self):
        self.make_fixture(profile='experimental')
        result = self.shell({'WN_SDK_PROFILE': 'experimental', 'WN_EXPERIMENTAL_DEVICE_SYNC': '1'})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '1|experimental|OTHER_SWIFT_FLAGS=$(inherited) -D WN_CURRENT_SDK_API -D WN_EXPERIMENTAL_DEVICE_SYNC\n')

    def test_implicit_private_new_receipt_requires_explicit_source(self):
        self.make_fixture(profile='experimental')
        result = self.shell({'WN_EXPERIMENTAL_DEVICE_SYNC': '1', 'WN_SDK_SOURCE_SHA': '',
                             'WN_SDK_RUN_ID': '', 'SOURCE_SHA': '', 'SDK_RUN_ID': ''})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Explicit immutable SDK F required', result.stderr)

    def test_legacy_private_shell_does_not_require_new_receipt(self):
        self.make_fixture(profile='experimental', platform=os.environ['PROFILE_CONTROL_APP_PLATFORM'])
        del self.local['qualification_receipt']
        self.write('LOCAL_BUILD.json', encoded(self.local).encode())
        self.assertFalse('qualification_receipt' in json.loads((self.package / 'LOCAL_BUILD.json').read_text()))
        result = self.shell({'WN_EXPERIMENTAL_DEVICE_SYNC': '1', 'WN_SDK_SOURCE_SHA': '',
                             'WN_SDK_RUN_ID': '', 'SOURCE_SHA': '', 'SDK_RUN_ID': ''})
        self.assertFalse(self.copied_overlay_has_receipt)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '1|experimental|OTHER_SWIFT_FLAGS=$(inherited) -D WN_CURRENT_SDK_API -D WN_EXPERIMENTAL_DEVICE_SYNC\n')

    def test_current_flag_cannot_enable_without_profile(self):
        result = self.shell({'WN_CURRENT_SDK_API': '1'}, empty=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires verified profile provenance', result.stderr)

    def test_private_compilation_environment_rejected(self):
        result = self.shell({'WN_SDK_PROFILE': 'default',
                             'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG WN_EXPERIMENTAL_DEVICE_SYNC'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('refuses private compilation flags', result.stderr)

    def test_private_compilation_argument_rejected(self):
        result = self.shell({'WN_SDK_PROFILE': 'default'},
                            arguments=('OTHER_SWIFT_FLAGS=-DWN_EXPERIMENTAL_DEVICE_SYNC',))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('refuses unchecked compilation/configuration overrides', result.stderr)

    def test_configuration_override_rejected(self):
        result = self.shell({'WN_SDK_PROFILE': 'default', 'XCODE_XCCONFIG_FILE': 'UNCHECKED-NEVER-READ.xcconfig'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('refuses an unchecked Xcode configuration override', result.stderr)

    def test_required_root_inventory_members_rejected(self):
        for member in ['MarmotKit.swift', 'PrivacyInfo.xcprivacy', 'MarmotKit.xcframework/Info.plist']:
            self.make_fixture()
            del self.proof['platforms'][self.platform]['files'][member]
            self.save()
            with self.assertRaisesRegex(ValueError, 'Required SDK root inventory members missing'):
                self.accept()

    def test_symlinked_artifact_root_rejected(self):
        artifact = self.package / 'Artifacts'
        physical = self.package / 'physical-artifact-fixture'
        artifact.rename(physical)
        artifact.symlink_to(physical, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'root/ancestor symlink refused'):
            self.accept()

    def test_symlinked_package_rejected(self):
        linked = self.root / 'linked-package'
        linked.symlink_to(self.package, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'root/ancestor symlink refused'):
            guard.verified_profile(linked, self.platform, self.profile, SOURCE, RUN, '0')


if __name__ == '__main__':
    unittest.main(verbosity=2)
