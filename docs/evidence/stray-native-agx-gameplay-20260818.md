# Stray native-AGX first gameplay witness (2026-08-18)

## Scope

This witness uses the iPad's native AGX path (`MACWS_AGX_NATIVE=1`) and the
production coexist WindowServer.  It does not enable MTLSim.  The run drives
Stray's real first-launch UI, creates/accepts the first save slot, enters the
rendered game scene, holds `W` through the normal MacWS input ABI, and observes
the process after that active interval.

Commercial game images and raw render targets remain under `/tmp` and are not
committed.  The hashes below bind the reported visual results without adding
copyrighted assets to the repository.

## Root causes retired

### Semantic depth-clear corruption

The subtype-1 macOS record field at `+0x4d0` is the semantic `clearDepth`
value that moves to native iOS `+0x4b0` after ABI compaction.  It is not a
producer-version constant.  The paired PF260 iOS-native AGX probe in
`misc/MetalDescriptorABIProbe` produced this exact readback witness:

```text
clear=0 status=4 error=nil match=1024/1024
clear=1 status=4 error=nil match=1024/1024
```

Changing a legitimate zero to `1.0f` made every depth pixel read back as one.
The production translator now admits zero under the already-bounded Stray ABI
contract and preserves the word byte-for-byte while compacting the record.
The same probe run through the chroot without that contract reproduced
`clear=0 status=5 ... 0x102` while the 1.0 control completed.  Re-running the
identical installed binary with `MACWS_STRAY_AGX_COMPAT=1` completed both
values and read back 1024/1024 exact pixels.  This negative/positive control
keeps the claim narrow: the verified Stray record family is fixed; unknown
producer layouts are not globally accepted.

### Structured segment-list parsing

The remaining active-gameplay error was runtime-matched to Stray PID 12387,
submit serial 7558:

```text
reason=iogpu-raw-callback-error-unmatched-ok
requested_serial=7558 matched_serial=7558
sequence=4701 descriptor=0 fixed=0
commands=33648 segments=11024 matched=YES
```

The captured direct list has token `0xc149dce5`, 18 entries, encoded length
`0x80002b10`, and KCMD length `0x8370`.  Its first valid range
`[0,0x8e8)` also appears in opaque resource bytes.  The old whole-list
unique-byte search therefore rejected the entire valid batch.

The actual `IOGPUSegmentListHeader` Objective-C type encoding defines an
ordered variable-length array: each entry is a `0x20`-byte header followed by
`groupCount * 0x40` resource bytes.  The replacement parser validates every
entry boundary, ordered KCMD range, record type/span, per-group valid count
(`<= 6`), enclosing resource total, and exact list/KCMD coverage.  On the
failing capture it now decodes:

```text
segment=0  list_header=0x10   kcmd=0x0..0x8e8    resources=460 groups=77
segment=1  list_header=0x1370 kcmd=0x8e8..0x1128 resources=22  groups=4
...
segment=17 list_header=0x29b0 kcmd=0x7b18..0x8370 resources=30 groups=5
```

The walk ends exactly at list `0x2b10` and KCMD `0x8370`.  This fixes the
protocol parser rather than special-casing a Stray command or suppressing the
resulting Metal error.

## Automated production run

The reproducible driver is `misc/stray_first_run_pipeline.py`.  The final run
used no submit flight recorder, command-error dump, render-target capture, or
IOGPU error recorder:

```bash
MACWS_DEVICE_SUDO_PASSWORD=alpine \
python3 misc/stray_first_run_pipeline.py \
  --host 192.168.1.6 --render-trace --stat-fps \
  --game-arg=-windowed --game-arg=-ResX=1194 --game-arg=-ResY=834 \
  --accept-delay 3 --menu-delay 3 --prompt-delay 3 --prompt-steps 30 \
  --gameplay-movement-hold 30 \
  --launch-timeout 30 --catalog-timeout 90 --wave-timeout 180 \
  --max-waves 1 \
  --output /tmp/macws-stray-first-run-20260818am-production-fps
```

The pipeline uses macOS Vision OCR plus bounded RFB pointer/Return actions for
the first-run screens, then the normal per-application MacWS input socket for
the sustained gameplay key state.  It returned:

```text
result=STABLE_SCENE
scene_detected_at_prompt=5
process_exited=false
fatal_kind=null
stable_seconds=183.0
```

The VNC framebuffer was 2388x1668.  The Stray window was 1194x862, containing
a 1194x834 game surface below its title bar.  Vision/visual classification
measured the first game frame at colorful ratio `0.6576627034` and edge ratio
`0.0184026500`.

The 30-second active movement interval advanced present sequence 840 to 1200
between total-time samples 61.703444 and 94.399369 seconds:

```text
active_present_fps=11.0105464213
present_before average_fps=13.597 window_fps=13.876
present_after  average_fps=12.701 window_fps=9.865
```

This is a real rendering/interaction success, but about 11 FPS is not yet a
claim of smooth gameplay.

Visual evidence hashes:

```text
after-gameplay-movement.png
  rgba_sha256=33daba25f5e78a3f718b289c7e22d5014506c7c17e1f02cbb5a523a006780bf9
after-wait.png
  rgba_sha256=968ae7446c522df06caefc09195dd2d41ffa83f56ff7e6ece23cad89e983637f
```

No new `/private/tmp/macws_fast_submit_error_*` directory appeared; the only
remaining directory was the pre-fix PID-12387 capture.  At the final sample,
Stray used 1,184,976 KiB RSS and WindowServer used 262,320 KiB RSS.  The
five-minute thermal watchdog reported `thermal-state=nominal` and 35.00 C, so
the FPS witness was not taken under a Critical thermal intervention.

After collecting the witness, Stray was stopped explicitly so its idle render
loop would not keep heating the iPad.  The WindowServer and iOS GUI stack were
not restarted or resprung during installation or validation.
