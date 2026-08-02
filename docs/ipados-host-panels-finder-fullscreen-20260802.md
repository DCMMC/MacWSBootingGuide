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

## 2. Ventura's native in-process Open panel

The earlier Host build contained an AppKit-looking filesystem browser written
by MacWS. That was useful as a diagnostic scaffold, but it was not a macOS
native Open panel and therefore was not a valid product fix. It has been
removed in full.

RE-confirmed via the target macOS 13.4 AppKit
`-[NSLocalSavePanel _useRemotePanel]`: the `NSUseRemoteSavePanel` default
selects whether the public `NSOpenPanel` factory uses the remote
OpenAndSavePanel/ViewBridge service. That auxiliary service graph is not
available in the chroot. AppKit itself also ships the complete in-process
implementation with the runtime inheritance chain
`NSLocalOpenPanel → NSLocalSavePanel → NSPanel`.

The production constructor now performs one upstream selection only:

```text
[[NSUserDefaults standardUserDefaults]
    setBool:NO forKey:@"NSUseRemoteSavePanel"]
```

The target application still calls its ordinary `+[NSOpenPanel openPanel]`,
`runModal`/sheet APIs, delegates and URL accessors. MacWS does not replace the
class or factory, manufacture a modal result, duplicate Finder UI in UIKit, or
force a validation function to succeed.

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

Runtime-confirmed via the target iPad screenshot
`/tmp/macws-native-open-panel.png` (2388×1668, SHA-256
`ff224dbb4558a9090dcf835237ba141172132ec16b50d63eb970c2a2a458fcfc`):
the real Ventura Finder-style native `NSOpenPanel` appeared in the chroot
desktop. Escape closed the panel and the client process remained alive.
Production logs contained none of `####`, `MACWS_FILE_PANEL`, or per-input
tracing.

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

## 5. Native Scene creation, initial size, and immersive fullscreen

The old fullscreen implementation asked UIKit to activate a Scene again. That
could create or reconnect the wrong lifecycle object and was the source of the
black secondary window. It has been removed. Fullscreen is now a presentation
transition of the Scene the user is already operating:

1. Host changes that Scene from the exact-window stream to the complete desktop
   stream without creating a second `UISceneSession`.
2. Host writes a short-lived request containing the exact private FBS Scene ID.
3. A SpringBoard tweak verifies that ID still equals
   `activeDisplayWindowScene.sceneIdentifier`.
4. It follows the exact call sequence RE-confirmed in 20D67 SpringBoard
   `-[SpringBoard _handleMakeFullscreenKeyShortcut:]` at `0x1c7669964`:
   `switcherController` checks and performs keyboard shortcut action `0x0b`.
5. Host hides the status bar and Home Indicator in desktop-stream mode and
   verifies `UIWindowScene.isFullScreen` after the system animation.

This leaves Chamois, workspace validation, safe areas and animation under
SpringBoard ownership. There is no direct `UIWindow.frame` write, CALayer
stretch, forced condition or black placeholder Scene. An exact-ID mismatch is
rejected rather than accidentally maximizing another app.

New macOS top-level windows are also automatic. Runtime-confirmed via
`MacWSHost.log`: a Terminal catalog transition from one to two windows emitted
`window-auto-scene identity=25808:g:21`, followed by
`scene-activation requested` and `scene-connected ... window=21`. The identity
uses owner PID plus AppKit logical tab/window group, so one macOS window cannot
silently occupy two Host Scenes.

UIKit Scene activation exposes only discrete preferred size categories. To
preserve a small macOS utility window's real initial size, v6 sends its exact
FBS Scene ID and AppKit preferred frame to SpringBoard after connection.
RE-confirmed via
`-[SBItemResizeGestureSwitcherModifier
_responseForSceneSizeUpdateToSize:center:sceneUpdatesOnly:]` at `0x1c79cfaf4`
and the coordinator submit path at `0x1c79e67b8`: the tweak uses the same
`SBDisplayItemAttributedSizeInfer`, immutable layout-attribute mutation,
`SBMutableSwitcherTransitionRequest`, and `SBMainWorkspace` transaction as a
real Stage Manager resize.

The v6 binaries are installed on the target. The currently running SpringBoard
still reports the v3 loaded witness. Per the no-reboot/no-respring safety
constraint, this session did not force-load v6. Acceptance after the next
natural SpringBoard load requires both `isFullScreen=YES` with hidden system
bars and a small-window `resize-performed ... route=SBMainWorkspace` log whose
final Scene bounds match the system-clamped requested size. The final local
rootless package SHA-256 is
`2281aa4194b7b08b5e0458cfbb8d0922a53d56d688358e042fa1c06c2e1e8036`;
the target disk hashes are
`dc2c3ac3ae0f693b2425b617bcc8864724c34d9aaa24588633cb554a66d15ccb`
for Host and
`8d3f3d4f9a3140b6d287a68d768405f0c3bc745b25429f84525539f7b9b97ab6`
for the v6 tweak.

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
