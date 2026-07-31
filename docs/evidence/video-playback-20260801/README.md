# VSCode/Bilibili video playback evidence — 2026-08-01

This folder records the bounded run that separated video decode/playback from
the remaining Metal presentation failure.

## Runtime-confirmed playback

`macws-bili-layoutfix.json` navigated VSCode's current Chromium target to
`https://www.bilibili.com/video/BV1ps4y18729/` and requested muted playback.
The first sample reported `readyState=4`, `paused=false`, `error=null`, video
time `0.491010`, and 216 total frames. The final sample reported video time
`4.676808` and 339 total frames, with zero dropped or corrupted frames. This
runtime-confirms that network fetch, MSE, demux and decode were advancing; it
does not by itself prove correct displayed colors.

`macws-bili-textrace.json` is the shorter texture-trace run. The legacy
`macws-bili-probe.json` is retained because it shows the earlier page state in
which media time advanced but the frame counter remained unchanged.

## Runtime-confirmed NV12 texture shape

The device's 106 MiB `/var/jb/var/mobile/vscode.log`, lines
2477905–2477933, captured the same `420v` IOSurface used for both Chromium
textures:

```text
#### MTL_TEX/iosurf.IN pfmt=10 type=2 w=852 h=480 ... plane=0 ios=0x60003b960
####     ios: w=852 h=480 bpr=896 fmt=0x34323076(420v) elemSz=1 allocSz=657408 planes=2
#### IOSURFACE-COMPAT baseAddress plane=0 original=0x110b5c380 base=0x110b5c000 propertyOffset=0 corrected=0x110b5c000 recovery=11
#### MTL_TEX/iosurf.OUT -> 0x601ed4b00 (label=(nolabel))
#### MTL_TEX/iosurf.IN pfmt=30 type=2 w=426 h=240 ... plane=1 ios=0x60003b960
####     ios: w=852 h=480 bpr=896 fmt=0x34323076(420v) elemSz=1 allocSz=657408 planes=2
#### IOSURFACE-COMPAT baseAddress plane=1 original=0x110b5c380 base=0x110b5c000 propertyOffset=442368 corrected=0x110bc8000 recovery=12
#### MTL_TEX/iosurf.OUT -> 0x601ed4600 (label=(nolabel))
```

RE-confirmed in this tree: the pre-fix type-`0x82` translator wrote constant
zero to the iOS `args+0x38` plane field. The actual call above asks for RG8
plane 1, so the translator discarded a real semantic input even though both
texture constructors returned non-nil. `Metal_hooks.x` now carries
IOSurfaceID, plane and compression span as one lock-protected scope, and
`mac_hooks.m` writes the scoped plane at `args+0x38`. Adjacent per-plane
IOSurface getters are recovered from explicit creation properties because
disassembly of the macOS 13.4 and iOS 16.3 IOSurface binaries shows their
field offsets differ.

## Validation boundary

The fix compiled, packaged and installed successfully. WindowServer remains
stopped after the system memory reset, so no post-fix screenshot is claimed
here. Bilibili correct-color playback and the first seconds of Apple's product
animation remain runtime acceptance tests. The Apple symptom is a THEORY in
the same IOSurface/NV12 metadata family until a post-fix frame capture proves
or disproves it.
