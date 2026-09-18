# Installer / application process lifetime (2026-09-19)

## Observed unsafe boundary, intercepted before service reload

During the on-device package transaction, a read-only process snapshot showed:

```text
 PID   PPID  PGID
 8439 92633 92633 /Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word
13515 92633 92633 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
92633     1 92633 /var/jb/usr/macOS/bin/macwshostd
```

The installed hostd job did not specify an abandoned process group. The
maintainer script unconditionally unloaded/reloaded it. The confirmed facts
are the shared live group and the unconditional reload; loss of these user
applications was a risk, **not an observed outcome** or a proven explanation
of any earlier reported crash.

The dedicated installer group 63100 was stopped before the reload section.
Its actual maintainer 63119 was waiting for the Metal asset verifier, not
writing the package database. The already-started autosignd63368 was resumed
independently and its real RPC probe returned 0. Only the stopped maintainer
was sent SIGTERM and continued so it could exit; no SIGKILL was needed. Its
verification-only children completed, and dpkg63108 and supervisor63101
recorded the real failure:

```text
MACWS_FINAL_DPKG_STATUS=1
iF install ok half-configured
```

No old buffered maintainer shell was allowed to continue to the unsafe reload.
Hostd92633, the user's Terminal13515, Preview35128 and WindowServer99427
remained alive. There were no installer processes left stopped. The exact
transaction log is `/tmp/macws-install-e55eb2d-20260919.log` on the iPad.
This intermediate state is explicitly **not a successful package install**.

## Upstream lifetime repair

`SpawnMacOSApplication` now establishes the new application's own process
group atomically through `POSIX_SPAWN_SETPGROUP` and group 0. Its existing
signal-mask/default-signal and AppKit scheduling policy are retained, as is
normal child reaping. Any attribute error propagates before spawning. This
does not retroactively change an already-running application's group.

`misc/test_app_process_group_contract.py` compiles and runs the actual extracted
spawn function. It checks a real child's PID/group, parent-group preservation,
interactive signal masks/defaults and propagation of group-setup errors without
spawning. The independent native iPad harness, with only the already-existing
process-type setter stubbed, reported parent66934/group66927 unchanged and
children66935/66936 each in their own group, both exit0. SIGINT/SIGTERM were
unblocked and SIGINT had its default disposition. That probe affected no GUI
application or user process group.

The package-side lifecycle policy and completed replacement transaction are
recorded separately after their actual verification. A second process snapshot
alone cannot make an active launcher's restart safe: it can create another child
between the snapshot and unload. Installation must preserve running services
and user state, not depend on that race being unlikely.
