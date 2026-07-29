# Current system-wide input and VNC transport witness

Device: iPad13,6, iOS 16.3, macOS 13.4 chroot, native AGX,
`start coexist --experimental`, Retina RFB 2388x1668. The tests below used
the currently installed `libmachook.dylib` and OSXvnc launch job on 2026-07-29.

## Ownership invariant

VNC pointer input has one owner: OSXvnc's original system-wide CoreGraphics
event path, with RFB physical coordinates divided by the measured Retina scale.
It is not broadcast to every AppInputBridge socket. This is required because
the menu bar, nested `NSMenu` trackers and NSWindow title drag are not owned by
one application process. AppInputBridge remains the native-host/process
fallback and its `NSApplication sendEvent:` hook is observational.

The generated GUI lifecycle also launches the real macOS `pboard` and `pbs`
processes. Runtime `launchctl print` showed the latter publishing an active
`com.apple.pbs.fetch_services` endpoint; Terminal created a connection to the
same Mach service instead of leaving the Services menu at `Building...`.

## Visual results

- `terminal-context-post-compression.png`: a complete Terminal contextual menu
  appeared in 0.295 s after the secondary click.
- `terminal-menubar-post-compression-2.png`: the Shell menu opened in 0.298 s.
- `terminal-menubar-hover-post-compression.png`: moving from Shell to Edit
  switched the active system menu in 0.028 s.
- `terminal-nested-submenu-post-compression.png`: hovering New Window opened
  its real nested profile submenu. This covers the nested `NSMenu` tracker,
  not just the top-level menu bar.
- `vscode-right-click-2.png` and `repeat-context/right-{1,2,3}.png`: the real
  VS Code 1.130.0 editor context menu opened visibly in three consecutive
  isolated rounds.
- `vscode-right-click-final.png`: after restarting the current VS Code job, the
  same complete editor-tab menu opened in 0.313 s on the newly created process.
- `vscode-menu-file-2.png` and `vscode-menu-edit-hover.png`: VS Code's
  WindowServer-owned menu opened and switched across top-level items.
- `terminal-title-drag-zlib-level1.png`: a held primary-button trajectory moved
  the Terminal window. The post-release visible update took 0.485 s versus
  1.949 s with the old Zlib work factor.
- `terminal-system-keyboard-post-compression.png`: a burst completed
  `echo system-menu-ok`, including Return and shell output. First visible
  feedback was 0.473 s; the retained 1.5-s result contains the complete command
  and output.

These are visual witnesses. The test's arbitrary framebuffer digest alone is
not treated as proof that a requested menu or command completed.

## Runtime event witnesses

A Terminal right click entered the real nested menu tracker. The 26-second
`sendEvent:` duration ended only when the later menu-selection/close event
returned control; it is not 26 seconds of dispatch CPU time:

```text
#### APP-INPUT MOUSE-EVENT pid=12753 serial=44 type=3 window=39 local=(369.00,269.00) pressed=0x2 at=327149.220341
#### APP-INPUT MOUSE-RETURN pid=12753 serial=44 type=3 pressed=0 elapsed=26145.780ms at=327175.366121
```

The system path performed Retina normalization for the same build:

```text
#### OSXVNC NATIVE-ALL event=17 buttons=0x4 rfb=(1100.0,1000.0) quartz=(550.0,500.0) scale=2
#### OSXVNC NATIVE-ALL event=19 buttons=0x1 rfb=(280.0,22.0) quartz=(140.0,11.0) scale=2
#### OSXVNC NATIVE-ALL event=23 buttons=0 rfb=(380.0,22.0) quartz=(190.0,11.0) scale=2
```

The bounded WindowServer log remained clean through the interaction pass:

```text
#### VNC-FLOW poll-result observed=19800 clean=19800 error=0 pf=80 submitSerial=0 status=4 code=0 polls=1
#### VNC-FLOW poll-result observed=20400 clean=20400 error=0 pf=80 submitSerial=0 status=4 code=0 polls=1
#### VNC-FLOW poll-result observed=21000 clean=21000 error=0 pf=80 submitSerial=0 status=4 code=0 polls=1
```

## RFB compression boundary

RE of the installed arm64 OSXvnc binary established the actual state fields:

- `rfbProcessClientNormalMessage+0x63c/+0x84c` stores negotiated compression
  levels at client `+0x26c` (Zlib) and `+0x558` (Tight).
- `rfbSendOneRectEncodingZlib+0x248` supplies `+0x26c` to `deflateInit2_`.
- `rfbSendRectEncodingTight+0x34` snapshots `+0x558` for every rectangle.

Before the clamp, one moved-window update spent 1583.618 ms in the real RFB
send boundary while mmap copying used 1.868 ms:

```text
#### OSXVNC RFB-SEND #471 encoding=6 regions=1 pixels=3983184 bounds=0,0 2388x1668 copy=1/3983184/1.868ms elapsed=1583.618ms result=1
```

The generated launch job now enables `MACWS_VNC_LOW_LATENCY_COMPRESSION=1`.
It preserves the client's selected encoding and clamps only Zlib/Tight's work
factor to level 1 before stream initialization:

```text
#### OSXVNC LOW-LATENCY-COMPRESSION encoding=6 requested=5 effective=1
#### OSXVNC RFB-SEND #4 encoding=6 regions=1 pixels=3820800 bounds=0,50 2388x1600 copy=1/3820800/1.215ms elapsed=116.163ms result=1
#### OSXVNC RFB-SEND #5 encoding=6 regions=1 pixels=2874200 bounds=232,250 2053x1400 copy=1/2874200/1.021ms elapsed=100.851ms result=1
```

Controlled Tight full-frame runs measured 343 ms at level 1, 544 ms at level
6 and 1184 ms at level 9. This is a latency/bandwidth tradeoff, not a change
to rendered pixels or the AGX path.

## Remaining boundary

Held title motion is accepted continuously, but the current compositor often
publishes only the post-release window location. Therefore the drag now
completes reliably and much faster, but it is not yet a live 60-fps window
outline. Large full-screen RFB updates can also retain a wireless/socket
backpressure tail. These remain presentation/transport work; they are not
evidence that the input event was lost.
