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

The plane fix compiled, packaged and installed successfully. A later bounded
production run did obtain post-fix screenshots, but they still show severe
green/magenta colour mapping. Consequently the earlier plane-field mismatch
was real, but it was not the only presentation fault. Bilibili correct-colour
playback and the first seconds of Apple's product animation remain runtime
acceptance tests. The Apple symptom is a THEORY in the same
IOSurface/NV12/compiler-target family until a post-fix frame capture proves or
disproves it.

## Generation-1 command wrapper follow-up

The first bounded run after Safari's compiler-service isolation produced an
IOGPU error archive for Code Helper GPU PID 86614. Its manifest matched error
`0x102` to serial 2 and recorded:

```text
serial=1 fixed=1 commands=2080 segments=304
serial=2 fixed=0 commands=2160 segments=328 matched=YES
serial=3 fixed=0 commands=2136 segments=328
```

The archived serials have the following SHA-256 witnesses:

```text
serial 2 KCMD     c34d36f1026f945224bd266ce67eff689878bdcdbcb4925afb2df710d99b1f43
serial 2 segments 83b185979a96adebe2de007a53827c93962e7ce4f10aea6cf0a84280cb221d76
serial 3 KCMD     ba26f85576b4b1220552a3e3dd1f676d57560740b1e1f57fc94ca35f4df9f3eb
serial 3 segments 640ae8d1b1b0e0f1c0e7200a27300742c099bd835034d2c2f16fb98b54dc410f
```

`parse_agx_segment_list.py` runtime-decodes both records as trailing-wrapper
generation 1, with equal outer/tail generation fields, exact subtype-1
payload range `0x0..0x840`, and type-3 opcode `0x9b03`. Serial 2 carries two
wrapper records over `0x840..0x870`; serial 3 carries one over
`0x840..0x858`. Generations 0 and 2 through 4 already had independent runtime
witnesses, so the translator now admits the bounded, fully observed family
0 through 4 while retaining every structural/range/opcode validation. This is
an upstream ABI adaptation, not a return-value or error-check bypass.

The updated library was built on-device with the project's FAST_FORCE path,
installed without reboot/respring, and passed the chroot smoke test. In the
next 15-second Bilibili probe, decode/presentation counters advanced as
follows:

```text
sample 0:  currentTime=4.005  totalVideoFrames=124 dropped=3
sample 15: currentTime=12.088 totalVideoFrames=366 dropped=3
sample 30: currentTime=20.244 totalVideoFrames=611 dropped=3
```

All samples had `readyState=4`, `paused=false`, `error=null`, and
`corruptedVideoFrames=0`. This runtime-confirms that the generation-1 miss was
a real freeze/completion blocker. It does not validate colour correctness.

The same run also logged a separate Skia shader failure:

```text
Internal error while linking shader. MSL compilation error:
This library format is not supported on this platform (or was built with an old version of the tools).
```

A standalone source-library probe still returned real `_MTLLibrary` and
`_MTLFunctionInternal` objects, so the compiler bridge is not globally dead.
The failure is currently isolated to the complex Chromium worker/library
path. Reintroducing the former global target-OS or renamer NOPs is explicitly
not an acceptable fix: they caused Safari's native compiler service to fail
and violate the request-scope invariant. The next fix must establish the
correct target/runtime module upstream and remain request-scoped.
