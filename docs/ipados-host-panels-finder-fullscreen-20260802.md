# Native Host: menu, file panel, Finder, launch, and fullscreen milestone

Date: 2026-08-02
Target: iPad13,6, iPadOS 16.3, macOS 13.4 rootfs, AGX-native production profile

This milestone fixes the user-visible failures reported after the first
DisplayStream Host implementation: VS Code's toolbar popup could not be
operated, Open File crashed Terminal/VS Code, Finder did not produce a usable
browser, repeated launches became slower, and the fullscreen transition closed
the native windows it was supposed to display.

## 1. Authoritative popup input

The Host pointer bridge now uses the same system CoreGraphics input boundary as
the working OSXvnc path for every non-VNC pointer transition. The original
OSXvnc binary was disassembled on the target and its pointer path was confirmed
to call `CGPostMouseEvent` at `__TEXT+0x9f24`. Process-local `NSEvent` and
`CGEventPost` experiments did not close a tracked Carbon menu; the
CGS-connected system path did.

Before the system down, AppInputBridge completes the real AppKit/SkyLight/LS
activation lifecycle when the selected process is not active/front. No active
predicate, hit-test, or menu validation function is forced to return success.

Runtime witnesses on VS Code PID 29717, window 414:

- a tap at the real toolbar ellipsis created popup window 421;
- a tap on the native `Split Editor Right` row removed 421 and left the base
  process/window alive;
- the resulting metrics returned to one entry: `[(414, 73, 414, 400, 270)]`.

The first tap after another app owned the front process can still be an
activation transaction; the next tap opens the native menu. This is a real
macOS lifecycle constraint rather than a duplicated local click.

## 2. Functional local Open panel

Ventura's stock `NSOpenPanel` construction enters the ViewBridge open/save
service. That service is not loadable in this chroot and the caller aborted
before a panel could be returned. The replacement lives at the construction
boundary (`+[NSOpenPanel openPanel]` and
`+[NSSavePanel _crunchyRawUnbonedPanel]`) and returns a real AppKit window with
real filesystem `NSURL` results.

Two arm64e invariants were found rather than bypassed:

1. `bash-2026-08-02-042833.ips` trapped in libobjc `readClass` while
   authenticating static `OBJC_CLASS_$_MacWSLocalFilePanelController` metadata.
   Both helper classes are now created by `objc_allocateClassPair`, so macOS
   libobjc owns/signs the class metadata.
2. `bash-2026-08-02-043543.ips` then trapped while `NSLog` consumed an
   authenticated `__CFConstantStringClassReference`. The panel implementation
   now creates its strings through the realized `NSString` runtime class.

The production arm64e smoke test now reaches the target command:

```text
[launchdchrootexec] target=/bin/bash arch=arm64e insert=/usr/local/lib/libmachook.dylib
MACWS_ARM64E_FINDER_WAIT_OK
```

The Host semantic-menu response path also normalizes an iOS-side reply address
from `/var/mnt/rootfs/private/tmp/...` to its chroot spelling
`/private/tmp/...`. Before this fix the app logged a successful menu snapshot
but the iOS client timed out on the untouched socket. After it, Terminal and VS
Code returned complete menu trees and accepted the exact Open actions:

```text
Terminal: item=25 title='Open…' shortcut='⌘O'
VS Code:  item=30 title='Open…' shortcut='⌘O'
action status=1
```

Exact screen captures showed the browser at `/Users/root` in both apps. Escape
closed each panel and both processes remained alive. Production logs contained
none of `####`, `MACWS_FILE_PANEL`, or per-input tracing.

## 3. Finder bootstrap

Launching Finder only starts its AppKit event loop; it does not necessarily
create a browser. `macwshostd` therefore asks that exact process to resolve and
send its enabled Command-N target/action, then waits for a visible window
metrics witness.

Runtime evidence from a clean production launch:

```text
launch-app id=finder pid=32726 executable=/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
finder-bootstrap pid=32726 action=appkit-command-n sent=YES errno=0
finder-bootstrap pid=32726 result=window-ready exit-status=-1
launch-app window-ready id=finder pid=32726 path=DisplayStream
```

Finder's default Recents view remained on `Loading…` because the stripped
environment cannot complete its metadata query. Merely writing
`NewWindowTarget=PfHm` did not change the runtime result and was reverted.
After the new browser becomes visible, AppInputBridge now performs Finder's
real enabled `Go > Home` target/action. The diagnostic witness was:

```text
APP-INPUT CREATE-INITIAL-WINDOW ... action=cmdNewFinderWindow: ... performed=YES
APP-INPUT FINDER-HOME ... item=Home action=cmdGoHome: performed=YES
```

An exact `screencapture -l <Finder window>` then showed the real `/Users/root`
listing (`Desktop`, `Documents`, `Downloads`, `Library`). Finder and Terminal
are launched with `-ApplePersistenceIgnoreState YES`, preventing restored test
windows/tabs from multiplying Host scenes. The production Finder metrics had
one visible browser entry.

## 4. Launch latency and child lifetime

`macwshostd` used to stop calling `waitpid` after the first window became
visible. Killed Terminal PID 6471 therefore remained `Z <defunct>` with hostd
as its parent. Each successful direct application launch now installs one
blocking utility-queue waiter only after the initial window transaction is
finished, avoiding a race with the readiness loop while guaranteeing later
reaping:

```text
launch-app reaped id=terminal pid=28095 result=signal-9
```

The production diagnostic sentinels were also removed. Terminal's spawn-to-real
window interval dropped from 3.30 s with input/panel tracing and restored state
to 1.50-2.38 s with one clean window.

VS Code launch now distinguishes `launchd` job states. An absent job is loaded
immediately; only a loaded-without-PID job receives `start`. The measured cold
path changed from approximately 4.9 s to 2.2 s:

```text
1785618596.954 spawned pid=29716 executable=/var/jb/usr/bin/launchctl wait=YES
1785618599.107 launch-app window-ready id=vscode pid=29717 path=DisplayStream
```

## 5. Fullscreen Scene lifecycle

The prior failure is runtime-confirmed by the Host log:

```text
scene-fullscreen preserve-mark count=0
scene-fullscreen requested
scene-reused mode=fullscreen
scene-close source=did-discard ...
```

The fullscreen request reconnects the current iPadOS Scene and can discard
other Stage Manager sessions. Those callbacks were incorrectly interpreted as
user window closes, so the transition closed the real Terminal/VS Code/Finder
windows and left a black workspace with only an empty menu layer.

Before requesting system fullscreen, the Host now enumerates every live
connected Scene and obtains its authoritative `streamRestorationActivity`
directly from the live `MacWSViewController`; persisted/session activities are
fallbacks only. A bounded persisted allowlist makes transition-driven
`didDiscardSceneSessions:` preserve the represented AppKit windows. Ordinary
red-X/discard behavior is unchanged outside that transaction.

The updated Host binary is installed on the target. Final on-device UI
validation is pending only because the lock-state probe currently reports:

```text
springboard port=3335 locked=1 passcode_enabled=1
notify name=com.apple.springboard.lockstate register=0 get=0 state=1
```

No lock-state bypass is attempted. After unlock, the acceptance witness is
`scene-fullscreen preserve-mark count>=1`, a fullscreen reconnect, advancing
fullscreen DisplayStream frames, and no close record for a marked Scene.

## Production switch state

- AGX-native compatibility remains enabled.
- `/tmp/macws_app_input_diagnostics`: off and removed by production preflight.
- `/tmp/macws_file_panel_diag`: off and removed by production preflight.
- `/tmp/macws_runtime_diagnostics`: off and removed by production preflight.
- `/private/tmp/macws_xpc_proxy_trace`: off and removed by production preflight.
- thermal sampling remains every 300 seconds; only Critical intervenes.
- the iOS memory guard remains disabled.

`python3 misc/audit_runtime_switches.py` passes with all source environment
variables and sentinel paths recorded in `docs/runtime-switches.tsv`.
