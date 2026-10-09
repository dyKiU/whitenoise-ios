"""Exercise local installation/provenance with isolated synthetic build tools."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "sync-local-bindings.sh"
SWIFTC = Path("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")


class LocalMarmotKitInstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.mdk = self.root / "mdk"
        tools = self.mdk / "crates/marmot-uniffi"
        tools.mkdir(parents=True)
        (tools / "Cargo.toml").write_text('uniffi = { version = "0.29.4" }\n')
        (self.mdk / ".gitignore").write_text("crates/marmot-uniffi/output/\n")
        self.executable(tools / "xcframework.sh", """#!/usr/bin/env python3
from pathlib import Path
output = Path(__file__).parent / 'output'
(output / 'MarmotKit.xcframework').mkdir(parents=True)
(output / 'MarmotKit.xcframework/fixture.a').write_bytes(b'isolated synthetic artifact')
(output / 'MarmotKit.swift').write_text('// isolated generated binding fixture\\n')
(output / 'PrivacyInfo.xcprivacy').write_text('isolated privacy fixture')
""")
        self.executable(tools / "validate-ios-artifact.sh", "#!/bin/sh\nexit 0\n")
        self.executable(tools / "package-ios-artifacts.sh", """#!/usr/bin/env python3
import json, os, pathlib, sys
release, tag, sha, destination, builder = sys.argv[1:]
features = ['otlp-export', 'product-analytics-export']
if os.environ.get('EXPERIMENTAL_DEVICE_SYNC') in {'1', 'true'}:
    features.append('experimental-device-sync')
if os.environ.get('BUILD_TEST_LEGACY_FEATURES') == '1':
    features.remove('experimental-device-sync')
sha = os.environ.get('BUILD_TEST_MANIFEST_SOURCE_SHA', sha)
root = pathlib.Path(destination)
root.mkdir(parents=True, exist_ok=True)
(root / f'marmotkit-ios-{release}.manifest.json').write_text(json.dumps(
    {'source_sha': sha, 'builder_sha': builder, 'features': features}))
""")
        self.git("init", "--quiet", "--initial-branch=feat/device-sync-fixture")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "isolated build fixture")
        self.sha = self.git("rev-parse", "HEAD").strip()
        self.ios = self.root / "ios"
        package = self.ios / "Packages/MarmotKit"
        (package / "Sources/MarmotKit").mkdir(parents=True)
        (package / "Package.swift").write_text(
            'let marmotKitLocalPath: String? = nil\npath: "Sources/MarmotKit",\n')
        copied_script = self.ios / "scripts/sync-local-bindings.sh"
        copied_script.parent.mkdir()
        shutil.copy2(SCRIPT, copied_script)
        self.script = copied_script
        binaries = self.root / "bin"
        binaries.mkdir()
        self.executable(binaries / "xcodebuild", "#!/bin/sh\necho 'Xcode isolated fixture'\n")
        self.executable(binaries / "xcrun", "#!/bin/sh\necho '26.2 isolated fixture'\n")
        self.env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}")

    def executable(self, path, contents):
        path.write_text(contents)
        path.chmod(0o755)

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.mdk), *arguments], text=True)

    def install(self, experimental):
        result = subprocess.run(["bash", str(self.script), str(self.mdk), self.sha],
                                env=self.env | {"EXPERIMENTAL_DEVICE_SYNC": experimental},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.ios / "Packages/MarmotKit"

    def compiled_features(self, package):
        if not SWIFTC.is_file():
            self.skipTest("host Swift compiler is required for compiled provenance evidence")
        main = self.root / "main.swift"
        main.write_text("print(MarmotKitVersion.features)\n")
        binary = self.root / "compiled-provenance"
        env = self.env | {"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                      env=env, text=True).strip()
        compiler = subprocess.run([str(SWIFTC), "-sdk", sdk,
                                   "-target", "arm64-apple-macosx15.0",
                                   "-module-cache-path", str(self.root / "swift-cache"),
                                   str(package / "Sources/MarmotKit/MarmotKitVersion.swift"),
                                   str(main), "-o", str(binary)], env=env, capture_output=True, text=True)
        self.assertEqual(compiler.returncode, 0, compiler.stderr)
        return subprocess.check_output([str(binary)], text=True).strip().split(",")

    def test_experimental_manifest_matches_installed_compiled_provenance(self):
        package = self.install("1")
        manifest = json.loads((package / "LOCAL_BUILD.json").read_text())
        self.assertEqual(self.compiled_features(package), manifest["features"])
        metadata = dict(line.split(": ", 1) for line in (package / "MARMOT_VERSION").read_text().splitlines()
                        if ": " in line)
        self.assertEqual(metadata["features"].split(","), manifest["features"])

    def test_local_metadata_records_the_actual_source_branch(self):
        package = self.install("0")
        metadata = dict(line.split(": ", 1) for line in (package / "MARMOT_VERSION").read_text().splitlines()
                        if ": " in line)
        self.assertEqual(metadata["mdk-branch"], "feat/device-sync-fixture")
        self.assertEqual(metadata["mdk-sha"], self.sha)

    def assert_refused_without_replacing_artifact(self, **environment):
        artifact = self.ios / "Packages/MarmotKit/Artifacts/MarmotKit.xcframework/previous.a"
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"previous isolated artifact")
        result = subprocess.run(["bash", str(self.script), str(self.mdk), self.sha],
                                env=self.env | {"EXPERIMENTAL_DEVICE_SYNC": "1"} | environment,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(artifact.read_bytes(), b"previous isolated artifact")
        self.assertFalse((self.ios / "Packages/MarmotKit/LOCAL_BUILD.json").exists())

    def test_stale_feature_profile_does_not_replace_existing_artifact(self):
        self.assert_refused_without_replacing_artifact(BUILD_TEST_LEGACY_FEATURES="1")

    def test_wrong_manifest_source_does_not_replace_existing_artifact(self):
        self.assert_refused_without_replacing_artifact(BUILD_TEST_MANIFEST_SOURCE_SHA="f" * 40)


if __name__ == "__main__":
    unittest.main()
