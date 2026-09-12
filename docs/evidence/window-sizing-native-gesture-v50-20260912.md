# Native corner gestures: constraint completion and reverse-settlement race

Status: v50 continuous resizing improved, but the same-contact pause/resume
test failed. The quiet-time approach was superseded by the actual native
lifecycle in v51. See [v51 acceptance and remaining failures](window-resize-native-lifecycle-v51-20260912.md).
The historical implementation and evidence below are retained, not a current
claim that all window-sizing issues are resolved.

## Real iPadOS gesture and screenshot boundary

Device 192.168.1.7, iPadOS 16.3.1/20D67, full composite 2778×1940 pixels,
screen 1389×970 points. HID sender 0x1000007ea. Mapping runtime-confirmed by
Host touch logs, not guessed from CGWindow coordinates:

```text
1789161919.884 (.5,.5) -> local (187.5,285.0)
1789161920.058 (.52,.5) -> local (187.5,265.5)
1789178936.166 (.5,.5) -> local (670.5,406.0)
1789178936.346 (.5,.52) -> local (698.5,406.0)
```

Therefore rawX = 1 − screenY/970, rawY = screenX/1389. The v2 HID helper
delivers a bounded down/move/up transaction; it does not send macOS fake corner
events. No IPSW extraction or WindowServer restart was used.

## Runtime-confirmed: an early ACK disagreed with actual native geometry

Finder PID61319/window290 was dragged from a 1341×909 Scene to 511×549.
`tmp/v49c-finder-native-resize-1` records ten native full-screen composites.
Frame009 and the later `tmp/window-v49c-after-native-resize.png` both show
persistent left-side cropping. The last ACK was:

```text
1789178975.092 window-configuration ack window=290 pid=61319 sequence=25 request-time=83587.269578 requested=408.8x400.8 applied=409.0x401.0 queued=408.8x400.8 result=applied
```

The separately run, read-only native catalog at 1789179434.027349 reported:

```json
{"kCGWindowNumber":290,"kCGWindowOwnerPID":61319,"kCGWindowBounds":{"X":785,"Y":25,"Width":445,"Height":401}}
```

The metrics sidecar still reported minimum 0×24 and the identified 409×401
ACK. Thus synchronous `setFrame` return was not final layout completion. This
is not evidence of a dropped frame or a reason to stretch the captured image.

## RE-confirmed: native constraint solver and layout completion

Actual macOS 13.4 AppKit methods, identified through runtime method metadata
and disassembled from bounded ranges of the device's real dyld cache:

```text
0x184110e00 _getConstrainedWindowMinSize:maxSize: -> w4=0 (changingOnlySlightly=NO)
0x184110e34 bl _fromConstraintsGetWindowMinSize:maxSize:allowDynamicLayout:changingOnlySlightly:
0x184110e3c bl minSize
0x184110e4c bl maxSize
0x184110e50..0x184110e6c intersects solver bounds with public min/max
0x184110f8c cbz w22,0x184110ff4
0x184110f90..0x184110fec YES path instead bounds around current nsis_frame +/-2
0x184110ff8 bl optimize
0x1841124b0 bl updateConstraintsIfNeeded
0x1841124bc bl performPendingChangeNotifications
0x184112524 bl withDelegateCallsDisabled: (layoutIfNeeded's normal block)
0x184112574 b _changeWindowFrameFromConstraintsIfNecessary
0x184111f24 bl _fromConstraintsSetWindowFrame:
0x184112540 bl _layoutViewTree
```

v50 uses the native full-window min/max solver, with the NO wrapper, in
addition to the public/root-content limits. It does not infer a minimum from
the last accepted size. It completes `layoutIfNeeded` before reading the ACK
frame, including after an anchor correction. No constraint, assertion, or
AppKit method is bypassed. Actual v50 minimum/ACK/CG agreement still needs the
new-process device test.

The former ad-hoc cache query accidentally included the adjacent `.map` text
file and exited with MemoryError while parsing its header. It was not rerun.
`misc/macws_dyld_range_query.py` now validates cache magic, mapping count,
table/file bounds and a 32-KiB read ceiling, excludes `.map`/`.symbols`, and
closes every file. Device processes remained responsive; no iPad restart.

## Runtime-confirmed: Terminal reverse sync interrupted a live gesture

`tmp/v49c-terminal-shrink-1` records a real 700-ms iPadOS corner drag with
Finder, About and Get Info on the same stage. All four remain visible in the
final capture, but the native window stopped following partway through:

```text
1789179563.847 window-configuration ack window=298 pid=95352 sequence=5 request-time=84176.034610 requested=814.0x439.2 applied=813.0x429.0 queued=814.0x439.2 result=constrained
1789179563.850 window-configuration scene-follow armed window=298 pid=95352 target-logical=813.0x429.0
1789179563.866 host-drawable-policy window=298 bounds=996.00x517.00 previous=1628x878 source=1692x950 drawable=1594x827 display-scale=2.000 backing=2.000 density=1.250 policy=source-native-auto fullscreen-canvas=NO
1789179564.054 host-drawable-policy window=298 bounds=931.50x421.00 previous=1514x707 source=1626x858 drawable=1490x674 display-scale=2.000 backing=2.000 density=1.250 policy=source-native-auto fullscreen-canvas=NO
1789179565.078 window-configuration scene-follow reached window=298 pid=95352 logical=812.8x428.8 after-deadline=NO
```

An ACK in an inter-sample gap is not a gesture-end event. v50 coalesces reverse
settlement for 120 ms and revalidates exact identity, transaction generation,
bounds, density, pending configure and suspension. Forward resizing continues
throughout this interval. The controller treats the pending settlement as
busy so a catalog callback cannot bypass that boundary. The test still needs
rapid continuous motion and stop/resume motion; quiet time alone is not proof
that a physical finger was released.

## v49c partial visual acceptance achieved before v50

- About creation: `tmp/v49c-about-open-1/frame-004.png` shows the 376×456 Scene
  beside the independent main Finder. It did not first open a large black box.
- Get Info creation: `tmp/v49c-getinfo-open-1/frame-005.png` shows all three
  independent windows on the same stage.
- General disclosure collapse:
  `tmp/v49c-getinfo-collapse-general/frame-008.png` shows the shorter inspector
  and both siblings still visible. Runtime at 1789179489.930 submitted the
  complete three-item current stage; 1789179490.034 preserved its members.
- These do not establish all reopen/width/rapid-resize/density cases. Persistent
  main-Finder cropping is explicitly a failure in this generation.

## v50 installed artifacts

Five installed paths were independently backed up to
`/var/mobile/Media/macws-v50-layout-settlement/backups`, then replaced using
new inodes and final trusted/signed bytes. No respring or service restart.

| Artifact | SHA-256 |
|---|---|
| Host | d89e445a7965fd929876a821ad8c1b6d6353a9f369c6bc68ea4f56dca57b3a3d |
| libmachook arm64e | 44b256e549271d56e509e10d8fb7a3d0e2028f7cad1aa5408e464cbacb550898 |
| libmachook arm64 | 88b3552d7a2602e1635368caf448197a9506ade54bbb85ea1fa61dadf247cf5a |

Local Host and both library architectures built; 32 Python contract tests,
causal ACK/settlement C tests, drawable-resolution C tests and strict code
signature verification passed. Chroot smoke printed `v50-smoke` with exit0.
