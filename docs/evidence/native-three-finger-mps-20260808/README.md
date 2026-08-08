# Native three-finger / MPS evidence (2026-08-08)

This directory contains the bounded device artifacts used by
`docs/fullscreen-native-three-finger-gesture-20260808.md`.

## Command ABI

- `native-ios-statistics/`: iOS-native `MPSImageStatisticsMean` command and
  subtype-3 segment reference (`0x218` command, `0xf0` segment dump).
- `macos-mps-failure/`: the matching two-segment macOS WindowServer command
  before translation, the old partial post-translation output, and the
  captured segment.
- `WindowServer.err` and `dock.log`: earlier bounded input/controller and
  render-path witnesses. Logs append across sessions; use the PID and marker
  boundaries documented in the main report.

## Final visual witness

The authoritative production captures are:

| File | SHA-256 | Meaning |
|---|---|---|
| `production-validation/production-baseline-final.png` | `bdeea7a10624fda1312392ac8d145981ade3dd95ea6e5f32f949e996d5880e03` | Stable desktop before the gesture |
| `production-validation/production-held-final.png` | `198652adb3f8178d5db39d8d47b672fbf73f54e6a5c4b6818c5b53129f7a42be` | Gesture held at progress `-0.42`; native Spaces strip is visible |
| `production-validation/production-after-cancel-final.png` | `bdeea7a10624fda1312392ac8d145981ade3dd95ea6e5f32f949e996d5880e03` | Exact restoration after cancel |

The baseline and post-cancel PNGs are byte-identical. During this run the
process witnesses stayed WindowServer `79678`, Dock `79945`, Terminal `80022`,
and OSXvnc `79999`. The final thermal sample was nominal at 31.19 °C.

The `diagnostic-*fixed.png` files are the preceding diagnostic-mode witness at
progress `-0.42` and `-0.80`. Earlier files without `fixed` preserve the
failure progression and should not be interpreted as the final result.

## Installed exact assets

- QuartzCore selective macabi library: 1,047,040 bytes, SHA-256
  `0cc979fb9a44ca2b7675bb73fcae02bbfa472f7498aa51bd543229927392f8e2`.
- SkyLight selective macabi library: 707,456 bytes, SHA-256
  `990803db710c494ff98155983cc9d3134c131e1ddbf3ce9e4468a3013134ffd6`.
- Final package: SHA-256
  `d3c0e4d1e47f20a0a38b1180f2f5c56d9d3c47c667e4eaf0572274bf15468820`.
- Installed fat `libmachook.dylib` at both the iOS staging path and chroot
  runtime path: SHA-256
  `fd1e5a873a553c4587979fd0c089908204c370ce781c86de0f8238251c41cfc2`.
