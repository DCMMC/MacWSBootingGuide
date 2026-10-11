"""Bounded on-device deployment of the location/watchdog standby fix.

No credentials are accepted or stored. Run with an existing root session.
Backups stay outside the repository; only the two affected jobs restart.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]
BACKUP = Path('/var/jb/var/mobile/ipad-standby-diagnostics/20261011')
GUI_SOURCE = PROJECT / 'layout/usr/macOS/bin/macos_gui.sh'
GUI_INSTALLED = Path('/var/jb/usr/macOS/bin/macos_gui.sh')
LOCATION_INSTALLED = Path('/var/jb/usr/macOS/bin/macwslocationd')
LOCATION_BUILT = PROJECT / '.theos/obj/arm64/macwslocationd'
OLD = '        sleep "$WD_POLL"\n        now=$SECONDS\n'
NEW = '''        sleep "$WD_POLL"
        # hostd publishes the real SpringBoard lock state and suspends the
        # owned applications. Leave launchd's KeepAlive jobs in charge while
        # locked; spawning launchctl/awk and rewriting PID files on each poll
        # makes the recovery observer an unnecessary standby workload.
        # Recovery resumes within one poll after unlock. Explicit bounded
        # automation retains its original deadline policy.
        if [ "$WD_MAX_RUNTIME" -eq 0 ] &&
           [ -n "$last_pid" ] && kill -0 "$last_pid" 2>/dev/null &&
           [ -f "$ROOTFS/private/tmp/macws_workspace_sleeping" ]; then
            continue
        fi
        now=$SECONDS
'''
PREVIOUS = NEW.replace(
    '           [ -n "$last_pid" ] && kill -0 "$last_pid" 2>/dev/null &&\n', '')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_install(source, destination, mode):
    fd, staging = tempfile.mkstemp(prefix=destination.name + '.standby-',
                                   dir=destination.parent)
    os.close(fd)
    try:
        shutil.copyfile(source, staging)
        os.chown(staging, 0, 0)
        os.chmod(staging, mode)
        os.replace(staging, destination)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)


def prepare():
    BACKUP.mkdir(parents=True, exist_ok=True)
    for name, source in [('macos_gui.source.before', GUI_SOURCE),
                         ('macos_gui.installed.before', GUI_INSTALLED),
                         ('macwslocationd.before', LOCATION_INSTALLED)]:
        destination = BACKUP / name
        if not destination.exists():
            shutil.copy2(source, destination)
    text = GUI_SOURCE.read_text()
    if NEW not in text:
        old = PREVIOUS if text.count(PREVIOUS) == 1 else OLD
        if text.count(old) != 1:
            raise RuntimeError('Watchdog source does not match the reviewed loop')
        staged = BACKUP / 'macos_gui.source.fixed'
        staged.write_text(text.replace(old, NEW, 1))
        atomic_install(staged, GUI_SOURCE, 0o755)
    run('/var/jb/usr/bin/bash', '-n', str(GUI_SOURCE))
    print('Standby source prepared; original artifacts preserved', flush=True)


def build():
    env = dict(os.environ, LC_ALL='C', THEOS='/var/jb/var/mobile/theos',
               THEOS_PROJECT_DIR=str(PROJECT), THEOS_BUILD_DIR=str(PROJECT))
    run('/var/jb/usr/bin/make', '-C', str(PROJECT / 'macwslocationd'),
        'FINALPACKAGE=1', 'STRIP=0', 'OPTFLAG=-O2',
        'THEOS_PACKAGE_SCHEME=rootless', 'GO_EASY_ON_ME=1', env=env)
    if not LOCATION_BUILT.is_file():
        raise RuntimeError('Location build artifact is absent')


def deploy():
    if NEW not in GUI_SOURCE.read_text():
        raise RuntimeError('Run prepare and tests first')
    if b'native client suspended reason=' not in LOCATION_BUILT.read_bytes():
        raise RuntimeError('Location artifact lacks the standby change')
    run('/var/jb/usr/bin/bash', '-n', str(GUI_SOURCE))
    # Sign and trust the staged image before replacing the running image.
    # The rename gives it a fresh vnode, preserving the AMFI cache contract.
    signed = BACKUP / 'macwslocationd.fixed'
    shutil.copy2(LOCATION_BUILT, signed)
    run('/var/jb/usr/bin/ldid',
        '-S' + str(PROJECT / 'layout/usr/macOS/bin/locationd-native-entitlements.plist'),
        '-M', str(signed))
    output = subprocess.check_output(
        ['/var/jb/usr/bin/ldid', '-arch', 'arm64', '-h', str(signed)],
        text=True, stderr=subprocess.STDOUT)
    hashes = [line.split('=', 1)[1].strip() for line in output.splitlines()
              if line.startswith('CDHash=')]
    if len(hashes) != 1 or len(hashes[0]) != 40:
        raise RuntimeError('Could not verify the arm64 CodeDirectory')
    run('/var/jb/usr/bin/jbctl', 'trustcache', 'add', hashes[0])
    atomic_install(signed, LOCATION_INSTALLED, 0o755)
    atomic_install(GUI_SOURCE, GUI_INSTALLED, 0o755)
    for label in ('com.macwsguide.locationbridge', 'com.macwsguide.watchdog'):
        run('/var/jb/usr/bin/launchctl', 'kickstart', '-k', 'system/' + label)
    result = {'deployed_at': time.time(), 'source_gui_sha256': digest(GUI_SOURCE),
              'installed_gui_sha256': digest(GUI_INSTALLED),
              'installed_location_sha256': digest(LOCATION_INSTALLED)}
    (BACKUP / 'deployment.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)


def rollback():
    atomic_install(BACKUP / 'macwslocationd.before', LOCATION_INSTALLED, 0o755)
    atomic_install(BACKUP / 'macos_gui.installed.before', GUI_INSTALLED, 0o755)
    atomic_install(BACKUP / 'macos_gui.source.before', GUI_SOURCE, 0o755)
    for label in ('com.macwsguide.locationbridge', 'com.macwsguide.watchdog'):
        run('/var/jb/usr/bin/launchctl', 'kickstart', '-k', 'system/' + label)
    print('Original location provider and watchdog restored', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'build', 'deploy', 'rollback'])
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run in an authenticated root session')
    globals()[args.action]()
