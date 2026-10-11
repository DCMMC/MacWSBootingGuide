"""Finite, read-only observation of a real unplugged, locked-screen interval.

IOKit reads avoid spawning ioreg on every sample. Powerlog ID boundaries
avoid the wall-clock offset observed on this device. No settings are changed.
"""
import argparse
import ctypes as c
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import statistics
import subprocess
import time

DIRECTORY = Path('/var/jb/var/mobile/ipad-standby-diagnostics/20261011')
DATABASE = None


class Device:
    def __init__(self):
        self.cf = c.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.io = c.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
        self.system = c.CDLL('/usr/lib/libSystem.B.dylib')
        signatures = [
            (self.io, 'IOServiceMatching', [c.c_char_p], c.c_void_p),
            (self.io, 'IOServiceGetMatchingService', [c.c_uint, c.c_void_p], c.c_uint),
            (self.io, 'IORegistryEntryCreateCFProperty',
             [c.c_uint, c.c_void_p, c.c_void_p, c.c_uint], c.c_void_p),
            (self.io, 'IOObjectRelease', [c.c_uint], c.c_int),
            (self.cf, 'CFStringCreateWithCString',
             [c.c_void_p, c.c_char_p, c.c_uint], c.c_void_p),
            (self.cf, 'CFNumberGetValue', [c.c_void_p, c.c_int, c.c_void_p], c.c_bool),
            (self.cf, 'CFBooleanGetValue', [c.c_void_p], c.c_bool),
            (self.cf, 'CFRelease', [c.c_void_p], None),
            (self.system, 'notify_register_check', [c.c_char_p, c.POINTER(c.c_int)], c.c_uint),
            (self.system, 'notify_get_state', [c.c_int, c.POINTER(c.c_uint64)], c.c_uint),
            (self.system, 'notify_cancel', [c.c_int], c.c_uint),
        ]
        for library, name, args, result in signatures:
            fn = getattr(library, name)
            fn.argtypes, fn.restype = args, result
        self.service = self.io.IOServiceGetMatchingService(
            0, self.io.IOServiceMatching(b'AppleSmartBattery'))
        if not self.service:
            raise RuntimeError('Battery service unavailable')
        self.tokens = {}
        for name in ('lockstate', 'hasBlankedScreen'):
            token = c.c_int()
            if self.system.notify_register_check(
                    ('com.apple.springboard.' + name).encode(), c.byref(token)):
                raise RuntimeError('Screen state unavailable')
            self.tokens[name] = token.value

    def number(self, name, boolean=False):
        key = self.cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
        value = self.io.IORegistryEntryCreateCFProperty(self.service, key, None, 0)
        self.cf.CFRelease(key)
        if not value:
            raise RuntimeError('Missing battery field ' + name)
        try:
            if boolean:
                return bool(self.cf.CFBooleanGetValue(value))
            out = c.c_int64()
            if not self.cf.CFNumberGetValue(value, 4, c.byref(out)):
                raise RuntimeError('Invalid battery field ' + name)
            return out.value
        finally:
            self.cf.CFRelease(value)

    def screen(self):
        values = {}
        for name, token in self.tokens.items():
            out = c.c_uint64()
            if self.system.notify_get_state(token, c.byref(out)):
                raise RuntimeError('Screen state read failed')
            values[name] = out.value
        return values

    def sample(self):
        data = dict(timestamp=time.time(), **self.screen())
        for name in ('CurrentCapacity', 'AppleRawCurrentCapacity',
                     'AppleRawMaxCapacity', 'InstantAmperage', 'Temperature', 'Voltage'):
            data[name] = self.number(name)
        for name in ('ExternalConnected', 'IsCharging'):
            data[name] = self.number(name, True)
        return data

    def close(self):
        for token in self.tokens.values():
            self.system.notify_cancel(token)
        self.io.IOObjectRelease(self.service)


def sql(query, parameters=()):
    global DATABASE
    if DATABASE is None:
        groups = Path('/var/containers/Shared/SystemGroup')
        for group in groups.iterdir():
            metadata = group / '.com.apple.mobile_container_manager.metadata.plist'
            try:
                with metadata.open('rb') as stream:
                    identity = plistlib.load(stream).get('MCMMetadataIdentifier')
            except (OSError, plistlib.InvalidFileException):
                continue
            if identity == 'systemgroup.com.apple.powerlog':
                DATABASE = str(group / 'Library/BatteryLife/CurrentPowerlog.PLSQL')
                break
        if DATABASE is None:
            raise RuntimeError('Powerlog system group unavailable')
    with sqlite3.connect('file:' + DATABASE + '?mode=ro', uri=True) as db:
        db.row_factory = sqlite3.Row
        return [dict(row) for row in db.execute(query, parameters)]


def observe(args):
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    path = DIRECTORY / (args.name + '.json')
    device = Device()
    data = {'status': 'waiting-for-lock', 'samples': [], 'created': time.time()}

    def save():
        staging = path.with_suffix('.tmp')
        staging.write_text(json.dumps(data, indent=2) + '\n')
        os.replace(staging, path)
        os.chown(path, 501, 501)

    try:
        save()
        print('Waiting for an unplugged, locked, blanked screen', flush=True)
        deadline = time.time() + args.wait_minutes * 60
        locked_since = None
        while time.time() < deadline:
            sample = device.sample()
            ready = (sample['lockstate'] == sample['hasBlankedScreen'] == 1
                     and not sample['ExternalConnected'] and not sample['IsCharging'])
            if ready:
                if locked_since is None:
                    locked_since = time.time()
                if time.time() - locked_since >= args.settle_seconds:
                    break
            else:
                locked_since = None
            time.sleep(10)
        else:
            raise RuntimeError('No settled locked interval within the waiting period')
        data['status'] = 'measuring'
        data['start_id'] = sql('SELECT max(ID) AS id FROM PLSleepWakeAgent_EventForward_PowerState')[0]['id']
        data['start'] = time.time()
        print('Measuring real standby for', args.minutes, 'minutes', flush=True)
        deadline = data['start'] + args.minutes * 60
        while True:
            sample = device.sample()
            if sample['lockstate'] != 1 or sample['hasBlankedScreen'] != 1:
                raise RuntimeError('Screen became active during measurement')
            if sample['ExternalConnected'] or sample['IsCharging']:
                raise RuntimeError('Charging state changed during measurement')
            if sample['CurrentCapacity'] < 15:
                raise RuntimeError('Battery too low for continued measurement')
            data['samples'].append(sample)
            save()
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            time.sleep(min(args.interval_seconds, remaining))
        data['end_id'] = sql('SELECT max(ID) AS id FROM PLSleepWakeAgent_EventForward_PowerState')[0]['id']
        data['powerlog_records_advanced'] = data['end_id'] > data['start_id']
        data['wake_reasons'] = sql('''SELECT r.value, count(DISTINCT p.ID) AS events
            FROM PLSleepWakeAgent_EventForward_PowerState p
            JOIN PLSleepWakeAgent_EventForward_PowerState_Array_Reason r ON r.FK_ID=p.ID
            WHERE p.ID>? AND p.ID<=? AND p.Event=0 AND p.State=0 GROUP BY r.value''',
            (data['start_id'], data['end_id']))
        first, last = data['samples'][0], data['samples'][-1]
        duration = last['timestamp'] - first['timestamp']
        data.update(status='complete', elapsed_seconds=duration,
            displayed_percentage_drop=first['CurrentCapacity'] - last['CurrentCapacity'],
            capacity_drop_mAh=first['AppleRawCurrentCapacity'] - last['AppleRawCurrentCapacity'],
            average_discharge_mA=(first['AppleRawCurrentCapacity'] - last['AppleRawCurrentCapacity']) * 3600 / duration,
            median_sample_mA=-statistics.median(x['InstantAmperage'] for x in data['samples']))
    except Exception as error:
        data.update(status='incomplete', reason=str(error))
    finally:
        device.close()
        data['finished'] = time.time()
        save()
        print(json.dumps({k:v for k,v in data.items() if k != 'samples'}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--name', default='after', choices=['before', 'after', 'overnight'])
    parser.add_argument('--minutes', type=float, default=10)
    parser.add_argument('--wait-minutes', type=float, default=30)
    parser.add_argument('--settle-seconds', type=float, default=120)
    parser.add_argument('--interval-seconds', type=float, default=30)
    parser.add_argument('--detach', action='store_true')
    args = parser.parse_args()
    if min(args.minutes, args.wait_minutes, args.interval_seconds) <= 0:
        parser.error('Durations must be positive')
    if os.geteuid() != 0:
        parser.error('Root is required to read Powerlog at the interval boundaries')
    if args.detach:
        DIRECTORY.mkdir(parents=True, exist_ok=True)
        import sys
        command = [sys.executable, str(Path(__file__).resolve())] + [
            x for x in sys.argv[1:] if x != '--detach']
        with (DIRECTORY / (args.name + '.log')).open('a') as output:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        print('Finite standby observer PID', child.pid, flush=True)
    else:
        observe(args)
