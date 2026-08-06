# Cold-start stability milestone — 2026-08-07

This milestone replaces the old “wait, then force-scan everything” startup
behaviour with a bounded, verified LaunchServices recovery transaction.  The
tests below used the real Ventura 13.4 binaries and databases on the iPad.  No
device reboot or respring was used during the investigation.

## Root cause: persisted records lose their mounted-volume state

The application database was not absent or corrupt.  The isolated session
store was seeded and readable:

```text
Database is seeded.
Seeded System Version:      13.4 (22F66)
Path: .../macws-lsd-session/com.apple.LaunchServices-4035-v2.csstore
Bundle:                     214 units
Plugin:                     310 units
```

LLDB stopped the real session `lsd` while an NSWorkspace lookup was in flight.
`_LSCopyLocalDatabase` returned a non-null database and no error:

```text
frame #0: LaunchServices`_LSCopyLocalDatabase
frame #1: LaunchServices`_LSServer_GetServerStoreForConnectionWithCompletionHandler + 112
...
x0 after step-out = 0x000000015a00a000
error pointer       = 0x0000000000000000
```

The decisive A/B used the same csstore and changed only the session `lsd`
generation:

```text
after lsregister -kill -seed:
  bundle id: Terminal
  mount state: mounted
  verify-launchservices-catalog: rc=0

after unloading and reloading session lsd:
  bundle id: Terminal
  mount state: not mounted
  resolvedURL=<nil>
  verify-launchservices-catalog: rc=1
```

On a normal macOS login, volume notifications reactivate persisted records.
The bind-mounted rootfs has no equivalent notification in the chroot session,
so NSWorkspace correctly filters records whose persisted mount state is no
longer active.  Retrying the same lookup cannot change that state.

## Production recovery path

When the rootfs fingerprint and catalog schema match, startup now performs one
read-only verification.  If records are inactive, it uses Ventura's stock
`lsregister -f` operation on every application bundle already present in the
four catalog roots, then re-registers the 48 Settings ExtensionKit records and
verifies exact platform-1 paths.

On-device measurements:

```text
applications=184
reactivation elapsed=3s
csstore before=8011776 bytes
csstore after =8011776 bytes
verification rc=0
```

This restores arbitrary application search/launch, not only Terminal and the
four validation sentinels.  It also avoids duplicate records: the database did
not grow during the full 184-application reactivation.

When the rootfs fingerprint or schema really changes, startup uses one clean
`lsregister -kill -seed` transaction.  It completed in 6 seconds in the
controlled run and immediately passed the five application and 48 Settings
extension witnesses.  The retired repeated `-f -apps system,local,user` path
had grown one store to 148,717,568 bytes and made `_LSDatabaseClean` consume
roughly 50–60 seconds on each daemon launch.

## First-generation QuartzCore pipeline

Once the catalog path stopped hiding startup progress, LLDB caught a separate
WindowServer abort during the first Terminal generation.  The real
`abort_with_payload` message was:

```text
Metal failed to build render pipeline
Target OS is incompatible
specialization=Pw40aXm_TatcA2S1Xhf
```

The exact Ventura QuartzCore functions at that pipeline were
`path_blit_vert_lph` and `attachment_clear_frag_lph`.  Their AIR modules have
no function-constant metadata, so the existing specialized-function redirect
could not cover them.  The byte-validated secondary QuartzCore library now
rewrites the target triple for these two base functions in addition to the
three already confirmed `fixed_*` functions.  The original system metallib
remains the process-wide default; no pipeline validation or abort path is
bypassed.  The installed artifact's size, FNV-1a value, and SHA-256 are checked
before it is published.

## Other cold-start invariants

- Package post-install now runs the Settings runtime deep verifier after its
  one-time preparation pass.  This writes the current-bootsession dependency
  witness and persistent trust-hash manifest before the first interactive
  launch.
- Rootless package extraction preserved the build account's `501:501`
  ownership on `com.macwsguide.alloc.plist`.  iPadOS launchd rejected that
  system-domain job with `Path had bad ownership/permissions`, while the old
  post-install pipeline hid the error behind a pipe and printed a false
  success message.  Both post-install layers now normalize the exact packaged
  launchd plist sets to `root:wheel 0644`; the allocator load is checked
  directly and aborts installation on failure.  Runtime verification after
  package installation showed the plist as uid/gid `0:0` and launchd reported
  the live `com.macwsguide.alloc` Mach service.
- Every `start`, `restart`, and `stop` owns an atomic PID-backed transaction
  lock.  A controlled concurrent-start test returned exit 75 and left the
  existing WindowServer PID unchanged.  Stale locks are reclaimed only when
  their exact owner PID no longer exists.
- Startup publishes an atomically replaced phase journal at
  `/var/jb/var/mobile/macos_gui_start.state`.  A UI can show meaningful phases
  such as `trust`, `services`, `first-frame`, and `ready` without parsing logs.
- The launch path still requires the real WindowServer clean-producer witness,
  the native AGX production preflight, exact application/extension records,
  and the critical-only five-minute thermal watchdog.  No assertion, protocol,
  or record-validation bypass was added.

## Terminal cold-state A/B

The first production capture was non-black but exposed another real cold-state
failure: Terminal restored only its auxiliary Inspector panel.  WindowServer's
window list and Terminal's own AppKit saved-state plist agreed exactly:

```text
window pid=42843 id=18 layer=3 onscreen=yes name=Inspector
window-count pid=42843 count=5

/var/root/Library/Saved Application State/com.apple.Terminal.savedState/windows.plist:
  NSTitle = Inspector
  NSUIPersistenceIsKey = 1
```

Terminal's launch contract now opts out of AppKit window restoration with the
native `-ApplePersistenceIgnoreState YES` argument.  It does not delete or
rewrite Terminal preferences, profiles, or history.  A same-rootfs restart
changed the concrete WindowServer witness to:

```text
window pid=45025 id=18 layer=0 onscreen=yes
name=Terminal — bash -i — 80×24
window-count pid=45025 count=5
```

The before/after Retina captures are
[`terminal-inspector-before.png`](evidence/cold-start-stability-20260807/terminal-inspector-before.png)
and
[`terminal-shell-after.png`](evidence/cold-start-stability-20260807/terminal-shell-after.png).

## Runtime result

After a session-daemon cold reload, the production start logged:

```text
Reactivating persisted LaunchServices records for the mounted chroot...
LaunchServices catalog reactivated and verified.
WindowServer graphics ready (... clean producer observed).
Starting VNC server ...
Starting Terminal ...
Started in coexist mode.
```

WindowServer, VNC, and Terminal remained alive, the final catalog verifier
returned zero, and a raw RFB client captured the expected 2388x1668 Retina
desktop with 3,978,919 of 3,983,184 pixels non-black.  The production start
completed while the iPad reported `serious` at 39.19 degrees C; the subsequent
same-rootfs A/B completed at `nominal` around 38.1 degrees C.  Per the shipped
policy, the five-minute thermal watchdog intervenes only at `critical`.

The final self-contained package was installed before the last validation:

```text
com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb
sha256=699cdad1348431370e4f55e6d51ed9c1cdb245ce258b57a1248d15b213bddcea
```

That installed-package start reached `phase=ready` in 76 seconds.  Its current
WindowServer generation contained no `Target OS is incompatible`, render-
pipeline abort, assertion-failure, or `abort_with_payload` record.  The device
reported `fair` at 38.59 degrees C after the final record/window/frame checks.

Two pre-fix stores were retained for recoverable comparison rather than
deleted:

- `com.apple.LaunchServices-4035-v2.csstore.bloated-cold-clean-20260807`
- `macws-lsd-session.pre-kill-seed-20260807`
