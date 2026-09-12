# Dead native owner must retire its independent Scene

Status: v49c deployed. A normal Terminal Quit was visually accepted on the
three-Finder-window stage; the other lifecycle cases below remain unverified.

## Runtime-confirmed cause

After the authorized Finder restart (old PID 43902, new PID 61319), the running
Host copied these lines to `/var/mobile/Library/Logs/MacWSHost.log`:

```text
1789161045.785 runtime-confirmed stale-window-generation owner=43902 window=280 catalog=0 recovery=desktop
1789161045.800 scene-reused mode=fullscreen previous-window-activated=NO system-fullscreen-requested=YES
1789161045.800 runtime-confirmed stale-window-generation owner=43902 window=282 catalog=0 recovery=desktop
1789161045.803 scene-reused mode=fullscreen previous-window-activated=NO system-fullscreen-requested=YES
1789161047.859 fullscreen-target-candidates final=YES catalog=[61319/290/0x20f/endpoint=YES] layers=[]
1789161047.859 presentation-target-change previous=0 next=61319 direct-heartbeat=0/0 fullscreen-canvas=0/0 mode=1
```

`tmp/window-v49-new-finder.png` is the parent's compositor screenshot of the
result. The former `receivedWindows:` death branch cleared the independent
Scene's identity and called `openFullscreenWorkspace`. Thus two closed Finder
panels became separate desktop workspaces and requested fullscreen activation.
The old native window's death is not an instruction to activate a desktop.

## Correct ownership boundary

- Independent window Scenes retain their exact PID/window/group until their
  presentation is retired. A confirmed missing owner can enter this path even
  when a restored Scene never received its first healthy catalog entry.
- The existing 650-ms retirement interval, refreshed catalog request, and
  pending-successor connection guard remain. An unanswered catalog request
  alone cannot confirm disappearance; two ESRCH observations independently
  prove the owner exited. EPERM is never interpreted as death.
  The catalog revision advances only in MetalView's native catalog receiver;
  its local cached-catalog callbacks after layer reordering do not count.
- Exact and logical-group matching both require the same owner PID. Delayed
  callbacks also recheck mode, PID, window ID, group ID and identity serial.
  This prevents a late callback from retiring a newly rebound Scene. This is
  not a claim that a PID alone identifies a process generation: a reused PID
  is considered live, and requires fresh exact-window catalog reconciliation.
- Retirement marks the session as preserving its macOS window, records a
  no-close tombstone, removes stale restoration bindings, and suspends its
  stream. It never sends CloseWindow, enters immersive presentation, requests
  maximization, or activates a scene. Pending focus/resize work is invalidated.
- Failed UIKit destruction retains no-close tombstones; a genuinely new window
  binding clears them. Connected startup pruning uses the same confirmation
  path. A connected fullscreen workspace still uses its existing return-history
  detachment path, preserving the desktop instead of retiring it. Dormant,
  unconnected fullscreen sessions with dead return owners are a pre-existing
  startup-pruning edge case outside this independent-window change.
- The final input boundary also rejects ConfigureWindow and ActivateTarget
  while retirement is pending: suspension alone does not cancel already queued
  configuration retries. Touch cancellation and key-up cleanup are retained.

## Required acceptance

1. With a native app's main window and two panels on the current Stage, close
   that app through its normal Quit action; record the screenshot and Scene
   membership before/after. Its independent Scenes disappear, other apps remain.
2. Confirm no `recovery=desktop`, fullscreen activation, or action-17 request is
   emitted from those old window identities, and no CloseWindow is sent during
   programmatic Scene destruction.
3. Reopen the app and verify its new PID/window identities survive delayed
   old-Scene disconnect/discard callbacks.
4. Keep a fullscreen desktop open while its former return app exits: the desktop
   survives and only the invalid return identity is detached.
5. Switch native tab-group members and temporarily interrupt catalog delivery:
   a live exact/group replacement or an unanswered query must not close a Scene.

## Parent's controlled device acceptance

Host v49c PID94116 handled Terminal PID95352/window298's production Quit menu
action. `tmp/v49c-terminal-quit-retirement/frame-007.png` shows its Scene gone
and Finder/About/Get Info all still visible, with independent dimensions.

```text
1789180252.822 runtime-confirmed mac-window-removed id=AD125108-F1D2-45AF-BA24-1B14D960DFA4 owner=95352 window=298 group=298 catalog-count=3 owner-missing=YES refreshed-catalog=YES recovery=retire-scene mac-window=preserved
1789180254.064 scene-discard duplicate-only id=AD125108-F1D2-45AF-BA24-1B14D960DFA4 mac-window=preserved
1789180254.692 scene-disconnect preserved id=AD125108-F1D2-45AF-BA24-1B14D960DFA4 mac-window=preserved
```

No desktop promotion or fullscreen request was issued by that retired identity.
WindowServer remained PID76954. The screenshot also exposes a separate known
same-PID tooltip overlay duplication; it is not claimed fixed by retirement.
