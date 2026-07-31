# Terminal tab identity follow — 2026-07-31

## Observed failure

In the native iPadOS Host, clicking a Terminal tab label appeared to do
nothing, while clicking the tab's close button worked. Repeating the tab click
made Terminal appear frozen.

This was not accepted as an input hit-test failure. A diagnostics-only
Terminal launch received one atomic Host v4 tap on the tab label and printed:

```text
#### APP-INPUT HIT pid=59415 gesture=1413562929 kind=6 window=23 screen=(639.00,759.00) local=(330.00,536.00) content=(330.00,536.00) view=nil frame-view=NSTabBar
#### APP-INPUT MOUSE-RETURN pid=59415 serial=1 type=1 pressed=0x1 elapsed=50.405ms at=52969.641762
#### APP-INPUT TAP-COMPLETE pid=59415 button=primary gesture=1413562929 window=23 screen=(639.00,759.00) local=(330.00,536.00)
#### APP-INPUT MOUSE-RETURN pid=59415 serial=2 type=2 pressed=0 elapsed=0.019ms at=52969.642079
```

Runtime-confirmed: AppKit hit the real `NSTabBar` and completed the mouse-down
in 50.405 ms. A `CGWindowListCopyWindowInfo(kCGWindowListOptionAll, ...)`
snapshot then showed window 24 on screen and window 23 off screen. Terminal
implements a tab selection by swapping which member `NSWindow`/CGWindowID is
on screen. The Host Scene was still subscribed to the old ID, so it presented
an unchanged surface and continued targeting input at the old native window.

An LLDB stop of the original apparently frozen Terminal (PID 55113) found the
main thread waiting normally in the AppKit event loop, not deadlocked. After
the fix and 42 automated native tab transitions, PID 72890 again stopped in:

```text
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGSTOP
  * frame #0: libsystem_kernel.dylib`mach_msg2_trap + 8
    frame #1: libsystem_kernel.dylib`mach_msg2_internal + 80
    frame #2: libsystem_kernel.dylib`mach_msg_overwrite + 604
    frame #3: libsystem_kernel.dylib`mach_msg + 24
    frame #4: libmachook.dylib`mach_msg_new + 1112
    frame #5: CoreFoundation`__CFRunLoopServiceMachPort + 160
    frame #6: CoreFoundation`__CFRunLoopRun + 1208
    frame #7: CoreFoundation`CFRunLoopRunSpecific + 612
    frame #8: HIToolbox`RunCurrentEventLoopInMode + 292
    frame #9: HIToolbox`ReceiveNextEventCommon + 648
    frame #10: HIToolbox`_BlockUntilNextEventMatchingListInModeWithFilter + 76
    frame #11: AppKit`_DPSNextEvent + 636
```

## Root fix

`AppInputBridge` now asks each real `NSWindow` for its `NSWindowTabGroup` and
publishes a stable process-local logical group ID in window-metrics protocol
version 2. The token is retained on the real tab-group and member objects; it
also remains stable when the member that supplied the initial window number is
closed, and when only one tab survives.

`macwsdisplayd` carries that identity in every selectable window descriptor.
The iPadOS Scene persists it with its restoration activity. After a completed
tap, secondary tap, touch-up, or key-up, the Host asks for the small on-screen
window catalog. If the exact old CGWindowID is gone but an on-screen member of
the same owner/group exists, it releases the old stream and subscribes to the
new native ID. No input validation, AppKit tracking behavior, or window
visibility check is bypassed.

The package maintainer script also copies signed bridge binaries and both
`libmachook` slices into the mounted chroot on fresh inodes. This fixes the
deployment split where `/var/jb/usr/macOS` contained protocol v2 while running
macOS processes still loaded protocol v1 from `/var/mnt/rootfs/usr/local`.

## Production validation

The production Terminal PID 72890 published window-metrics v2. Windows 4, 5,
6, and 7 all carried `logicalGroupID=4`. A real Host-routed tap then produced:

```text
1785487360.669 input-v4 synthetic kind=tap routed-through-controller scene=780000000 target=72890 point=(220.00,90.00) frame=1766x1168
1785487360.741 display-stream window-list count=1
1785487360.742 window-identity-follow owner=72890 group=4 old=7 new=4
```

The display service independently confirmed the new capture subscription:

```text
MACWS-DISPLAY stream-start id=4 mode=2 window=7
MACWS-DISPLAY stream-start id=5 mode=2 window=4
```

Eight directed transitions visited every member:

```text
old=4 new=7
old=7 new=5
old=5 new=6
old=6 new=4
old=4 new=5
old=5 new=7
old=7 new=6
old=6 new=4
```

A subsequent 32-transition stress run completed every requested switch. Across
all 42 post-fix transitions, the Host follow latency measured from input
routing to identity update was mean 84.881 ms, minimum 62 ms, maximum 244 ms.
There were no post-fix transport failures. `macwsdisplayd` RSS stayed exactly
30,608 KiB and MacWSHost moved only from 66,624 to 66,768 KiB. Terminal remained
alive and idle in its ordinary AppKit event loop. A deliberate restart of
`com.macwsguide.input` followed by another tab tap also succeeded (`old=4
new=7`), validating the Host's bounded Unix-datagram endpoint reconnection.

The iPadOS thermal state remained `nominal`; the final one-shot sample was:

```text
thermal-state=nominal raw=0 low-power=no battery-temp-centic=3669 virtual-temp-centic=3669 effective-temp-centic=3669 uptime=47990.569
```
