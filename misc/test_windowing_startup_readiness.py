"""Execute the real shell readiness predicate, without an iPad or respring.

The producer fixture is extracted from the current tweak, so changing a
capability on only one side of the launch boundary fails this regression.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "layout/usr/macOS/bin/macos_gui.sh").read_text()
TWEAK = (ROOT / "MacWSWindowing/Tweak.x").read_text()


def producer_witness(pid=3601):
    observer = TWEAK.split('static void MacWSInstallRequestObservers(', 1)[1]
    section = observer.split('dprintf(fd, "version=', 1)[1].split('getpid());', 1)[0]
    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', '"version=' + section)
    text = ''.join(bytes(value, 'utf-8').decode('unicode_escape') for value in literals)
    return text % pid


class WindowingStartupReadiness(unittest.TestCase):
    def ready(self, witness, pid="3601"):
        predicate = 'windowing_bridge_ready() {' + SCRIPT.split(
            'windowing_bridge_ready() {', 1)[1].split('\n}', 1)[0] + '\n}'
        version = re.search(r'^WINDOWING_REQUIRED_VERSION=(\d+)$', SCRIPT, re.M).group(1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'witness'
            if witness is not None:
                path.write_text(witness)
            result = subprocess.run(['bash', '-c',
                'set -eu\nWINDOWING_READY_WITNESS="$1"\n'
                'WINDOWING_REQUIRED_VERSION="$2"\n'
                'test_pid="$3"\n'
                'current_springboard_pid() { printf "%s" "$test_pid"; }\n' +
                predicate + '\nwindowing_bridge_ready',
                'readiness-test', str(path), version, pid], capture_output=True)
            return result.returncode == 0

    def test_current_producer_is_accepted(self):
        self.assertTrue(self.ready(producer_witness()))

    def test_description_is_not_a_protocol(self):
        witness = re.sub(r'initial=[^ ]+', 'initial=future-hook-implementation',
                         producer_witness())
        self.assertTrue(self.ready(witness))

    def test_stale_publisher_rejected(self):
        self.assertFalse(self.ready(producer_witness(pid=2740)))

    def test_missing_publisher_rejected(self):
        self.assertFalse(self.ready(producer_witness(), pid=""))

    def test_missing_witness_rejected(self):
        self.assertFalse(self.ready(None))

    def test_old_version_rejected(self):
        self.assertFalse(self.ready(re.sub(r'^version=\d+', 'version=1',
                                          producer_witness())))

    def test_missing_protocol_rejected(self):
        self.assertFalse(self.ready(producer_witness().replace('initial-size-protocol=1', '')))

    def test_other_protocol_rejected(self):
        for version in ('0', '2', '10', '1extra'):
            with self.subTest(version=version):
                self.assertFalse(self.ready(producer_witness().replace(
                    'initial-size-protocol=1', 'initial-size-protocol=' + version)))

    def test_missing_fullscreen_rejected(self):
        self.assertFalse(self.ready(re.sub(r'fullscreen=[^ ]+', '', producer_witness())))

    def test_readonly_command_cannot_respring(self):
        command = SCRIPT.split('    windowing-status)', 1)[1].split(';;', 1)[0]
        self.assertIn('windowing_bridge_ready', command)
        self.assertNotIn('ensure_windowing_bridge', command)
        self.assertNotIn('killall', command)


if __name__ == '__main__':
    unittest.main()
