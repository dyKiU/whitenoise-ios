#!/usr/bin/env python3
"""Build-time local SDK validation; never imported or invoked by the installed app."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re

# Reviewed source is vendored next to this script in each app, never imported
# through an environment-selected tooling path.
from sdk_profiles import features, validate_provenance


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def regular(path):
    require(path.is_file() and not path.is_symlink(), 'Expected regular SDK file')
    return path


def physical_root(root):
    require(root.is_absolute() and root.is_dir(), 'Absolute SDK directory required')
    for ancestor in [root, *root.parents]:
        require(not ancestor.is_symlink(), 'SDK root/ancestor symlink refused')
    require(root.resolve(strict=True) == root, 'SDK root physical identity differs')
    return root


def child(root, name):
    physical_root(root)
    require(isinstance(name, str), 'Invalid inventory path type')
    relative = PurePosixPath(name)
    require(not relative.is_absolute() and '..' not in relative.parts
            and relative.parts and relative.as_posix() == name, 'Unsafe SDK inventory path')
    path = root.joinpath(*relative.parts)
    for parent in [path, *path.parents]:
        require(not parent.is_symlink(), 'SDK symlink refused')
        if parent == root:
            break
    require(path.resolve(strict=True).is_relative_to(root), 'SDK file escaped physical root')
    return regular(path)


def legacy_experimental(package, platform):
    """Keep the original experimental validator's matching-artifact semantics."""
    manifest = json.loads((package / 'LOCAL_BUILD.json').read_text())
    require(manifest.get('features') == features('experimental'),
            'Experimental app requires the matched local device-sync artifact cohort')
    source = manifest.get('source_sha', '')
    require(re.fullmatch('[0-9a-f]{40}', source) and manifest.get('builder_sha') == source,
            'Experimental app requires full matching source/builder commits')
    require(f'mdk-sha: {source}\n' in (package / 'MARMOT_VERSION').read_text(),
            'Local binding source provenance does not match the artifact')
    require(digest(package / 'Sources/MarmotKit/MarmotKit.swift') == manifest.get('installed_swift_sha256'),
            'Local Swift bindings changed after matched installation')
    require((package / 'Artifacts/MarmotKit.xcframework/Info.plist').is_file(),
            'Matched local XCFramework is absent')
    native = {name: record for name, record in manifest.get('artifacts', {}).items()
              if name.startswith('MarmotKit.xcframework/') and name.endswith('.a')}
    require(len(native) == (1 if platform == 'macos' else 2),
            'Matched local manifest must identify the platform native archives')
    for name, record in native.items():
        require('..' not in Path(name).parts, 'Invalid native artifact path')
        require(digest(package / 'Artifacts' / name) == record.get('sha256'),
                'Local native archive changed after matched installation')
    return manifest


def verified_profile(package, platform, profile, source, run_id, private):
    require(private == ('0' if profile == 'default' else '1'), 'Private flag differs from SDK profile')
    require(re.fullmatch('[0-9a-f]{40}', source or ''), 'Explicit immutable SDK F required')
    require(re.fullmatch('[1-9][0-9]*', run_id or ''), 'Explicit producer run R required')
    require(os.environ.get('SDK_SOURCE_REPOSITORY'), 'Explicit immutable SDK Git repository required')
    physical_root(package)
    manifest = json.loads(regular(package / 'LOCAL_BUILD.json').read_text())
    receipt = manifest['qualification_receipt']
    require(set(receipt) == {'qualification_json', 'qualification_sha256', 'manifest_json',
                            'manifest_sha256', 'platform', 'bundle', 'bundle_sha256',
                            'original_swift_relative_path'}, 'Exact installer receipt schema required')
    raw_q = receipt['qualification_json'].encode('utf-8')
    raw_manifest = receipt['manifest_json'].encode('utf-8')
    require(hashlib.sha256(raw_q).hexdigest() == receipt['qualification_sha256'],
            'Qualification receipt bytes changed')
    require(hashlib.sha256(raw_manifest).hexdigest() == receipt['manifest_sha256'],
            'Original manifest receipt bytes changed')
    proof = json.loads(raw_q)
    # This checks real Git F tree, lock and release-profile bytes, as well as
    # strict profile schema and all four source/builder/compiler input records.
    validate_provenance(proof, profile, source, run_id)
    require('sdk_profile' in proof, 'Verified profile receipt requires current provenance')
    record = proof['platforms'][platform]
    required_members = {'MarmotKit.swift', 'PrivacyInfo.xcprivacy', 'MarmotKit.xcframework/Info.plist'}
    require(required_members <= set(record['files']), 'Required SDK root inventory members missing')
    original = json.loads(raw_manifest)
    require(record['manifest'] == original, 'Original package manifest differs from qualification')
    require(original['source_sha'] == original['builder_sha'] == source,
            'Packaged source/builder differs from F')
    require(receipt['platform'] == platform and receipt['bundle'] == record['bundle']
            and receipt['bundle_sha256'] == record['sha256'], 'Installer bundle/platform differs')
    expected = dict(original)
    expected.update(uniffi_version=proof['uniffi_version'], sdk_profile=profile,
                    installed_swift_sha256=manifest['installed_swift_sha256'],
                    installation='Ephemeral hosted CI overlay; never commit', workflow_run_id=run_id,
                    qualification_receipt=receipt)
    require(manifest == expected, 'Installed metadata differs from verified package')
    expected_features = features(profile)
    require(manifest['features'] == expected_features, 'Installed feature cohort differs')
    stamp = regular(package / 'MARMOT_VERSION').read_text()
    require(stamp == f'mdk-sha: {source}\nmdk-branch: detached\nmdk-tag: local-{source}\n'
            + 'features: ' + ','.join(expected_features) + '\n', 'Installed source/features stamp differs')
    require(receipt['original_swift_relative_path'] == 'LOCAL_BUILD_INPUTS/MarmotKit.swift',
            'Unexpected original Swift location')
    original_swift = child(package, receipt['original_swift_relative_path'])
    require(digest(original_swift) == record['files']['MarmotKit.swift'], 'Original Swift differs')
    normalized = '\n'.join(line.rstrip() for line in original_swift.read_text().splitlines()) + '\n'
    swift = child(package, 'Sources/MarmotKit/MarmotKit.swift')
    require(swift.read_bytes() == normalized.encode('utf-8')
            and digest(swift) == manifest['installed_swift_sha256'], 'Installed Swift differs')
    native_files = {}
    for name, expected_hash in record['files'].items():
        require(isinstance(expected_hash, str) and re.fullmatch('[0-9a-f]{64}', expected_hash),
                'Invalid inventory checksum')
        if name == 'MarmotKit.swift':
            path = original_swift
        elif name == 'PrivacyInfo.xcprivacy':
            path = child(package, 'Sources/MarmotKit/Resources/PrivacyInfo.xcprivacy')
        else:
            require(name.startswith('MarmotKit.xcframework/'), 'Unexpected package inventory member')
            path = child(package / 'Artifacts', name)
            native_files[name] = expected_hash
        require(digest(path) == expected_hash, 'Installed SDK inventory digest differs')
    framework = package / 'Artifacts/MarmotKit.xcframework'
    actual_files = set()
    for path in framework.rglob('*'):
        require(not path.is_symlink(), 'SDK framework symlink refused')
        if path.is_file():
            actual_files.add('MarmotKit.xcframework/' + path.relative_to(framework).as_posix())
    require(actual_files == set(native_files), 'Installed SDK inventory has missing or extra files')
    require(len([name for name in native_files if name.endswith('.a')]) == (1 if platform == 'macos' else 2),
            'Platform native archive inventory differs')
    require(any(name.endswith('/marmot_uniffiFFI.h') for name in native_files)
            and any(name.endswith('/module.modulemap') for name in native_files),
            'FFI header/modulemap inventory missing')
    return profile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--platform', choices=['macos', 'ios'], required=True)
    parser.add_argument('--profile', choices=['experimental', 'default'], required=True)
    parser.add_argument('--private', choices=['0', '1'], required=True)
    parser.add_argument('--source', default='')
    parser.add_argument('--run-id', default='')
    args = parser.parse_args()
    # Legacy experimental remains independently checked using the original
    # semantics. A new receipt can only use the stronger current validation.
    if args.profile == 'experimental':
        require(args.private == '1', 'Experimental SDK requires private opt-in')
        manifest = legacy_experimental(args.package, args.platform)
        receipt = manifest.get('qualification_receipt')
        legacy = receipt is None
        if receipt is not None and not legacy:
            legacy = 'sdk_profile' not in json.loads(receipt['qualification_json'])
        if legacy:
            require(manifest.get('sdk_profile', 'experimental') == 'experimental',
                    'Default profile cannot use legacy experimental route')
            print('experimental')
            return
    print(verified_profile(args.package, args.platform, args.profile,
                           args.source, args.run_id, args.private))


if __name__ == '__main__':
    main()
