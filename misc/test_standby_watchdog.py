"""Run the real watchdog loop against a simulated lock/unlock lifecycle."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'layout/usr/macOS/bin/macos_gui.sh').read_text()
BODY = SOURCE.split('run_watchdog() {', 1)[1].split('\n}\n', 1)[0]
BASH = shutil.which('bash')


class StandbyWatchdog(unittest.TestCase):
    def exercise(self, unlock=False, cap=0, cached=True):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'private/tmp').mkdir(parents=True)
            marker = root / 'private/tmp/macws_workspace_sleeping'
            marker.touch()
            if cached:
                (root / 'ws-pid').write_text('123\n')
            harness = '''
ROOTFS=$1
WD_PIDFILE=$ROOTFS/pid
WD_READY=$ROOTFS/ready
WD_WS_PIDFILE=$ROOTFS/ws-pid
WD_THERMAL_POLL=300
WD_POLL=5
WD_MAX_RUNTIME=$3
WD_RESTART_LIMIT=12
WD_WINDOW=45
ticks=0
sleep() {
    ticks=$((ticks+1))
    if [ "$ticks" = 2 ] && [ "$UNLOCK" = 1 ]; then
        rm "$ROOTFS/private/tmp/macws_workspace_sleeping"
    fi
    [ "$ticks" -lt 4 ] || exit 0
}
UNLOCK=$2
watchdog_pidfile_cleanup() { :; }
thermal_snapshot() { THERMAL_LINE=nominal; return 0; }
record_thermal_snapshot() { :; }
log() { :; }
ws_pid() { echo query >> "$ROOTFS/queries"; echo 123; }
record_ws_pid() { :; }
kill() { [ "$*" = '-0 123' ]; }
trip_watchdog() { echo unexpected-trip; exit 1; }
recover_ws_dependents() { echo unexpected-recovery; exit 1; }
run_watchdog() {
''' + BODY + '\n}\nrun_watchdog\n'
            result = subprocess.run([BASH, '-c', harness, 'standby-test',
                str(root), '1' if unlock else '0', str(cap)],
                capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            queries = root / 'queries'
            return len(queries.read_text().splitlines()) if queries.exists() else 0

    def test_locked_workspace_does_not_spawn_launchd_queries(self):
        self.assertEqual(self.exercise(), 0)

    def test_unlock_resumes_recovery_on_the_next_poll(self):
        self.assertEqual(self.exercise(unlock=True), 2)

    def test_explicit_runtime_cap_keeps_the_original_monitoring_policy(self):
        self.assertEqual(self.exercise(cap=600), 3)

    def test_missing_cached_server_still_checks_launchd_while_locked(self):
        self.assertEqual(self.exercise(cached=False), 1)


if __name__ == '__main__':
    unittest.main()
