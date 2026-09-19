# Preserve live applications during package installation (2026-09-19)

Runtime process inventory showed hostd92633 and the user's Word8439,
Excel9132, Activity Monitor9593 and Terminal13515 in process group92633.
The installed hostd launchd job did not set AbandonProcessGroup. The old
maintainer script unconditionally unloaded/reloaded this job, which is not
a safe way to activate an update while its GUI descendants remain open.
The installation was stopped before that operation; this evidence does not
claim that the user's documents were actually killed.

`macws_refresh_managed_job.py` now preserves **every already-loaded** hostd,
keychain, input and Dock job, including jobs without a current PID. Even an
apparently isolated old hostd might spawn a same-group child immediately
after a process snapshot, so the helper contains no unload, kill or
kickstart operation. New package bytes take effect at the next normal
service lifecycle, and the installer clearly reports that deferral. No
flag file controls this policy.

Only absent hostd/keychain jobs may be loaded, after validating the exact
root-owned plist and two launchd/process inventories with no orphan daemon.
Absent input/Dock jobs stay stopped. Unknown, malformed, denied or timed-out
state reads cause no service mutation and report an installation error.
An initial load failure likewise reports an error without an unload or retry.
The generated Dock plist may legitimately be absent on first installation:
only a proved-absent, non-autostart GUI job permits that missing-file case.

Fifteen executable lifecycle fixtures cover the actual shared process
group, the isolated-daemon spawn race, all four loaded jobs, no-PID jobs,
absent GUI/daemon jobs, orphan daemons, changing snapshots, malformed
configuration, unsafe permissions, symlinks, status failure and timeout.
The package artifact contract also requires the exact new helper payload.

The actual iOS Python3.9 helper was run through an execution adapter that
refused every command except launchctl list and `/bin/ps`; all four current
jobs deferred successfully. Its exact hostd result included:

```text
com.macwsguide.hostd upgrade activation DEFERRED: job is already loaded (PID 92633); shared PGID 92633 contains Microsoft Word(pid=8439), Microsoft Excel(pid=9132), Activity Monitor(pid=9593), Terminal(pid=13515).
```

The independent hostd child-spawn correction places future GUI processes
in their own process groups. That does not retroactively isolate existing
children, so the conservative installer policy is still necessary.

## Completed replacement installation on the subsequent boot

The device had already rebooted before this test resumed; the test did not
initiate that reboot. With the GUI stack stopped, source commit `c3c8ec2`
and the clean device checkout were verified against package SHA256
`e323c43b713a76d70bba133069b24a825ff797914477310183f33f2f3d86e674`.
The independent installer receipt
`/tmp/macws-install-c3c8ec2-20260919-newboot.json` records:

```text
dpkg_returncode: 0
Status: install ok installed
MACWS_FINAL_DPKG_STATUS=0
```

The actual maintainer output deferred loaded hostd342 and kept the absent
input/Dock jobs stopped. It did not restart the existing services. This
completed transaction supersedes the earlier intentionally aborted,
half-configured transaction; the latter is retained as historical evidence.

Separately, to exercise the new launcher while no GUI applications existed,
hostd342 alone was stopped and a fresh inventory confirmed no other live
process-group members or children. Only then was its exact job reloaded,
creating hostd8928. This quiescent diagnostic activation is not an automatic
installer operation. A normal Host launch subsequently produced:

```text
 PID   PPID  PGID
 8928     1  8928 /var/jb/usr/macOS/bin/macwshostd
11054  8928 11054 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
```

The ordinary startup checked 172 native/rootfs sentinel paths with none
present, reported production diagnostics OFF, and reached the first frame
in 105 seconds without a retry. The native iPadOS capture
`/tmp/macws-first-gui-20260919-newboot.png` was inspected: Finder's desktop,
Dock and the Host control center were visible. This is a real no-flag GUI
startup acceptance in an already-booted device session, not proof of an
unattended full iPad reboot or a claim that its startup time is optimized.
