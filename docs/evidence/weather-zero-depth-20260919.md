# Weather subtype-1 zero-depth admission (2026-09-19)

## What is established

Runtime-confirmed in `/tmp/macws-weather-shanghai-full-20260919.log`, copied
from Weather PID21575:

```text
#### IOGPU-ERROR-GETTER observation=1 commandBuffer=0x13e7e4ed0 class=AGXG13GFamilyCommandBuffer submitSerial=2 fixed=0 domain=MTLCommandBufferErrorDomain code=1 description=Internal Error (00000102:Internal Error)
#### AGX_FAST_RING dumped reason=iogpu-error-getter-102 commandBuffer=0x13e7e4ed0 requested=2 matched=2 entries=2 byteEntries=2 range=1..2 path=/tmp/macws_fast_submit_error_21575_1
```

The local capture `/tmp/macws-weather-fast-submit-21575/manifest.txt` records
serial2 as matched, with all6408 command bytes and880 list bytes saved,
neither truncated. SHA256:

```text
s2_q2_d0_post_kcmd.bin
e7204ba6b15f529ab638ffbdcf7d6da09a1a02b915b822db5cdbab648fd00fe7
s2_q2_d0_post_segments.bin
1c045ab427c0c24d63ae1f94c59bb6b53c8e22e7365624376b72ce0df9b93e72
```

The actual runtime-derived IOGPU list decoder validates a direct list,
count3, encoded length`0x80000370`, and three contiguous command ranges:

| List entry | Command range | Resource count | Groups |
|---|---|---:|---:|
| `0x10` | `0..0x858` | 24 | 4 |
| `0x130` | `0x858..0x10b0` | 24 | 4 |
| `0x250` | `0x10b0..0x1908` | 23 | 4 |

All group valid counts sum to their entry's resource count. The walk consumes
both buffers exactly. The resource event ledger contains all28 referenced
resource IDs at the manifest's `life_event_serial=132`; the later active
snapshot must not be substituted for that submission-time state. This does
not prove every resource's contents or GPU lifetime correct, but no absent
resource ID or malformed list framing was found in this capture.

Each command remains an unnormalized macOS subtype-1 record:

```text
+00=00010000 +04=00000858 +28=00000818 +2c=000007e8 +30=30 +34=1
+d8=03006b0012003a00
+1c0..1cf=00 (all sixteen bytes)
+1e0=1 +1e8=1c +1f8..203=ff (all twelve bytes)
+4c0..4cf=00 (all sixteen bytes)
+4d0=0 +4d4=300 +4e8..4f3=ff (all twelve bytes)
```

Source-confirmed: the complete structured-range walk accepts this framing;
all subtype-1 anchors match except the zero-payload application/diagnostic
restriction. Its `+0x4d0=0` was admitted only for Stray or with the diagnostic
`macws_kcmd_field_4d0_diag`. Weather met neither condition. Replaying these
exact bytes through the actual extracted C translator before the change
returns `fixed=0`, independently reproducing the omission without inferring
an undocumented meaning for error`0x102`.

## Why zero is not a different producer layout

The retained historical runtime witness is
`docs/evidence/stray-native-agx-gameplay-20260818.md`, commit`0b43997`.
Its paired32×32 PF260 depth-clear/readback reports native zero and one both
`status=4 error=nil match=1024/1024`. The same chroot binary without admission
failed zero, while admission preserved both values and returned exact pixels.
Forcing zero to one instead corrupted the requested depth output. The probe
source remains `misc/MetalDescriptorABIProbe/main.m`.

That evidence identifies macOS`+0x4d0` / normalized iOS`+0x4b0` as semantic
clearDepth data. The original native/macOS producer binaries and raw paired
logs were not available in this bounded offline review; this document does
**not** claim a newly repeated producer disassembly or depth GPU test.

The minimal source change permits the already-proven zero/one pair in all
four existing subtype-1 entry paths independent of application name. It does
not accept arbitrary field values, alter the existing Stray-only`0xffff`
case, remove structural anchors, or write any substitute semantic value.
The obsolete marker no longer has a consumer and remains in exact cleanup.

## Executed local checks

`misc/test_agx_zero_depth.py` embeds SHA-bound, compressed copies of the exact
two small command/list captures and compiles the real source translator:

- Exact Weather capture: `fixed=3`, KCMD`0x1908 -> 0x18a8`.
- Expected transformation matches every output byte: remove only each
  record's existing zero windows`[0x1c0,0x1d0)` and`[0x4c0,0x4d0)`, update
  the existing size fields and every affected list range.
- Zero arrives unchanged at`+0x4b0`; already-normalized output is unchanged
  by a second translation.
- Leading/trailing wrappers preserve both zero and one and existing tails.
- Actual linear-entry predicate admits zero/one without either opt-in.
- Damaged record anchors and list count/length/ranges remain rejected.

Six tests passed, as did the existing seven compute-ABI tests. Runtime-switch
inventory reports275 environment names,76 source file switches,423 recorded
entries. No device action or deployment was performed by this offline review.

### Existing parser limitation found, not silently fixed

Changing a structured list's resource count/group count/valid count can make
the structured parser fail but still enter the older unique-range fallback.
The same malformed fixtures are accepted when their depth word is the
previously accepted one. This is pre-existing behavior, not a new relaxation
by zero admission. A differential test records that it does not depend on
zero versus one. This change deliberately does not redesign that fallback,
and must not be described as proving all malformed resource lists fail closed.

## Visual causality is still bounded

The parent agent's same-installed-binary diagnostic run with zero admission
showed Shanghai with a normal blue background. However, weather conditions
changed during the comparison, and the subsequent correctly activated
**no-flag reverse control also rendered blue without a new0x102**. Therefore
this is not a conclusive single-variable proof that the earlier magenta
background or heat was caused only by zero admission. The exact captured
untranslated command is proven; candidate GPU/render regression acceptance
is still required separately. No broad Weather graphics completion claim is
made here.

## No-sentinel production-route candidate acceptance

The final combined candidate was published using new inodes at all four
canonical library paths. Each rename was atomic, **not** one cross-volume
transaction. `/tmp/macws-same-abi-live-install-20260919.json` retains the
per-file hashes, original-inode backups and verified unchanged mappings of
user PowerPoint19000, WindowServer16900 and Terminal17280. None was restarted.
The old Weather23673 exited through ordinary Quit, then the normal foreground
Host route launched Weather27054/window122. Read-only image inspection found
the actual mapped arm64e library:

```text
uuid=c094e3e4327a349f9282bea000e34766
text-sha256=0c973fe87f6b69ffc6806f13ce77a05723c1b2d7315508b5bb59afb68784ddc1
matched=1 requested=1 no-suspend=yes
```

No fast-ring, command-error or zero-depth diagnostic marker was present.
The main agent inspected these full iPadOS captures:

- `/tmp/macws-weather-final-shanghai-active-20260919.png`: Shanghai Drizzle,
  dark background with visible precipitation effect, forecast and map.
- `/tmp/macws-weather-final-shanghai-mc-20260919.png`: settled Mission Control
  contains the actual Weather view, not a black card; the user's PowerPoint
  and Terminal windows remain present.
- `/tmp/macws-weather-final-beijing-20260919.png`: Beijing forecast visible
  after returning from Mission Control; its map was still loading, so that
  map is not recorded as accepted.
- `/tmp/macws-weather-final-shanghai-return-20260919.png`: Shanghai content
  and map visible again after switching cities.

The new PID's log through this sequence contains no command-buffer 0x102.
Initial launch's empty `--` city page and a first nonselecting tap were not
counted as passes; explicit activation, actual city labels and visible
content were verified. This is bounded no-flag candidate acceptance, not a
claim that all weather conditions or Office image paths are fixed. The
reverse-control limitation above still applies.
