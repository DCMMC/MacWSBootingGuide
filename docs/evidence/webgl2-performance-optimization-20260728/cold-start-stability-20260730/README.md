# Cold-start generation-0 stability and performance milestone

Date: 2026-07-30. Device: iPad13,6, iOS 16.3, macOS 13.4 chroot,
VS Code 1.130 / Chromium 148, native AGX, production coexist mode. Diagnostics
were enabled only for the bounded failure captures and disabled for both
performance runs.

## Runtime-confirmed cold-start failure

The first empty-profile diagnostic reproduced 1,609 `0x102` and 100 `0x103`
getter observations. The first mapped failure is retained in
`macws_fast_submit_error_32070_1/manifest.txt`:

```text
reason=iogpu-error-getter-102 pid=32070 command_buffer=0x600224980 requested_serial=2 matched_serial=2 oldest=1 newest=2 freeze_wait_ms=0
serial=2 life_event_serial=52 sequence=2 descriptor=0 fixed=0 descriptor_pointer=0x600aafcc0 command_buffer=0x600224980 storage=0x6001a9400 matched=YES same_shape=NO commands=2160 saved=2160 truncated=NO segments=328 saved=328 truncated=NO
```

The exact retained buffers are KCMD SHA-256
`fc015ead2db10ae6159a7968acf228a26a04daa1b9934d5bea1e841717e33d8b`
and segment-list SHA-256
`49ed566a7a72153320f2c79718de7df5e1f78e8b4b9c9bf73f0c42f335db41d5`.
The validated shape is one macOS subtype-1 record `[0,0x840)`, two identical
type-3 records with opcode `0x9903`, and an exact trailing-wrapper range
`[0x840,0x870)`. Both outer and tail generation fields are zero. The old
translator accepted the same structurally validated contract only for
generation 2 through 4, so it returned `fixed=0` before the real `0x102`.

After admitting only the observed generation 0, serials 2 through 9 completed
the translator with `fixed=1`. The next mapped failure is retained in
`macws_fast_submit_error_43328_1/manifest.txt`:

```text
reason=iogpu-error-getter-102 pid=43328 command_buffer=0x600edb280 requested_serial=12 matched_serial=12 oldest=1 newest=13 freeze_wait_ms=0
serial=12 life_event_serial=129 sequence=20 descriptor=0 fixed=0 descriptor_pointer=0x600cb4a10 command_buffer=0x600edb280 storage=0x6001adc00 matched=YES same_shape=NO commands=4248 saved=4248 truncated=NO segments=680 saved=680 truncated=NO
```

Its exact buffers are KCMD SHA-256
`91f75088a4ac78e4eb74a73cfe15d1cc7c4b8677927170c658a5caa5a38e01e3`
and segment-list SHA-256
`4fbc3c24df0ee68f86543ddb7042c3a50308b468ed0168713de0b4dc0ae656f7`.
They contain two subtype-1 records followed by one type-3 opcode `0x9b03`
record, with matching generation-0 wrapper range `[0x1080,0x1098)`. The
generalized walker had the same stale generation gate. It now accepts the
observed 0 and 2 through 4 while continuing to reject unobserved generation 1.
All magic, count, range, wrapper-type, opcode, segment-record and subtype
anchors remain mandatory; no completion or protocol check is bypassed.

## Production result

The production retest reached the 60,000-fish page in three seconds. In the
initial 13-second observation it logged one `0x102`, no `0x103`, no OOM and no
context loss. The two subsequent measurements did not add an error:

```text
before-round2 0x102=1 0x103=1 oom=0
after-round2 0x102=1 0x103=1 oom=0
```

Both runs used a 1,024 by 1,024 WebGL2 canvas, 60,000 verified model fish,
8-second warmup and 15-second measurement. Against the retained M1 baseline
of 37.6790755 FPS:

| Run | iPad FPS | M1 ratio | p50 | p95 | Context lost |
|---|---:|---:|---:|---:|---|
| round 1 | 32.6862784 | 86.75% | 29.1 ms | 34.0 ms | no |
| round 2 | 31.3247712 | 83.14% | 30.3 ms | 35.2 ms | no |
| mean | 32.0055248 | 84.94% | — | — | no |

The MacBook thermal guard reported nominal at 30.79 C and 30.78 C before the
two host-side measurements. The iPad watchdog's last five-minute sample was
`serious` at 40.89 C; per the production policy this was telemetry only and
only `critical` is allowed to intervene. Despite that conservative condition,
both runs independently exceeded the 80% milestone.

## Reboot trust-chain change

`postinst.sh` now walks every executable file in the existing VS Code bundle
and re-registers its persistent per-architecture CDHashes without re-signing
nested code. `macos_gui.sh` independently validates both `/bin/bash` execution
and the arm64 Electron Framework hash before starting WindowServer. If either
witness fails after reboot, it runs one full postinstall repair and requires
both witnesses to pass. This closes the observed state where bash and the main
VS Code executable ran but dyld rejected Electron Framework or Squirrel before
libmachook/autosignd could execute.

The on-device package used for the final multi-segment production result has
SHA-256 `54f816008225b90190162ad18d54c9337445f9cc48419f43e010af0cf50baa5c`.
The true post-reboot no-manual-`jbctl` verification is recorded separately
once the device has completed its first unlock and returned to the network.
