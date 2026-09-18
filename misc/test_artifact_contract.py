"""Exercise stale cross-build and stale/missing Debian payload rejection."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import macws_artifact_contract as contract


class ArtifactContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name, contents in {
            'Makefile': 'all:\n',
            'config/production.mk': 'OPTFLAG ?= -O2\n',
            'MacWSWindowing/Makefile': 'MacWSWindowing_FILES = Tweak.x\n',
            'MacWSWindowing/Tweak.x': '#include "../include/shared.h"\n',
            'include/shared.h': '#include "capability.h"\n',
            'include/capability.h': '#define ABI 1\n',
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        self.binary = self.root / 'MacWSWindowing.dylib'
        self.binary.write_bytes(b'cross-linked-Apple-ld64-artifact')
        self.manifest = self.root / 'MacWSWindowing.build.json'
        self.manifest.write_text(json.dumps(contract.manifest(self.root, self.binary)))

    def test_exact_source_and_binary_are_accepted(self):
        contract.verify(self.root, self.binary, self.manifest)

    def test_source_migration_rejects_self_consistent_old_binary_and_hash(self):
        (self.root / 'include/capability.h').write_text('#define ABI 2\n')
        with self.assertRaisesRegex(ValueError, 'include/capability.h'):
            contract.verify(self.root, self.binary, self.manifest)

    def test_changed_binary_is_rejected(self):
        self.binary.write_bytes(b'another-build')
        with self.assertRaisesRegex(ValueError, 'binary differs'):
            contract.verify(self.root, self.binary, self.manifest)

    def test_edit_during_build_cannot_label_old_object_with_new_source(self):
        snapshot = self.root / 'before-build.json'
        snapshot.write_text(json.dumps({'schema': contract.SCHEMA,
                                       'sources': contract.source_hashes(self.root)}))
        (self.root / 'include/capability.h').write_text('#define ABI 2\n')
        with self.assertRaisesRegex(ValueError, 'changed during cross-build'):
            contract.manifest(self.root, self.binary, snapshot)

    def test_missing_transitive_header_is_rejected(self):
        (self.root / 'include/capability.h').unlink()
        with self.assertRaisesRegex(ValueError, 'unresolved local include'):
            contract.verify(self.root, self.binary, self.manifest)

    def package(self, omitted=None):
        staging = self.root / 'staging'
        for name in contract.PACKAGE_PATHS:
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(self.binary.read_bytes() if name == contract.WINDOWING_PATH
                             else name.encode())
        (staging / 'DEBIAN').mkdir()
        (staging / 'DEBIAN/postinst').write_text('true\n')
        (staging / 'DEBIAN/postinst').chmod(0o755)
        payload = self.root / 'payload'
        shutil.copytree(staging, payload)
        if omitted:
            (payload / omitted).unlink()
        (payload / 'DEBIAN/control').write_text(
            'Package: artifact-contract-test\nVersion: 1\nArchitecture: all\n'
            'Maintainer: MacWS test\nDescription: payload contract fixture\n')
        package = self.root / 'test.deb'
        subprocess.run(['dpkg-deb', '--build', str(payload), str(package)],
                       check=True, capture_output=True)
        return package, staging

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_actual_debian_payload_matches_staging(self):
        package, staging = self.package()
        contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_new_staging_does_not_validate_old_archive(self):
        package, staging = self.package()
        (staging / contract.PACKAGE_PATHS[0]).write_bytes(b'new-host')
        with self.assertRaisesRegex(ValueError, 'package differs from staged runtime'):
            contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_missing_audio_job_stops_installation(self):
        name = 'var/jb/usr/macOS/gui-launchd/com.macwsguide.audio-output.plist'
        package, staging = self.package(omitted=name)
        with self.assertRaisesRegex(ValueError, 'missing runtime payload'):
            contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_old_staged_startup_script_is_rejected(self):
        package, staging = self.package()
        for name, source in contract.SOURCE_PAYLOADS.items():
            path = self.root / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((staging / name).read_bytes())
        (self.root / 'layout/usr/macOS/bin/postinst.sh').write_text('new-audio-trust\n')
        with self.assertRaisesRegex(ValueError, 'staged runtime differs from current source'):
            contract.verify_package(package, staging, self.binary, self.root)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_old_archived_installation_logic_is_rejected(self):
        package, staging = self.package()
        (staging / 'DEBIAN/postinst').write_text('new-installation-logic\n')
        with self.assertRaisesRegex(ValueError, 'package postinst differs'):
            contract.verify_package(package, staging, self.binary)


if __name__ == '__main__':
    unittest.main()
