# Native resize lifecycle and four-window acceptance, v51

Status: partial acceptance on iPadOS 16.3.1/20D67. Actual native corner gestures
and full 2778×1940 iPadOS screenshots were used. This is NOT a claim that all
resize animation or rendering defects are fixed.

Update: [v53 acceptance](window-v53-acceptance-20260912.md) records the v52
failure, subsequent implementation, four-window retest and remaining failures.
The v52-pending statements below are historical, not current acceptance.

## v50 pause test falsified the quiet-time assumption

v50's continuous Terminal shrink completed, but holding the SAME contact still
for 450 ms halfway through the drag failed. Runtime-confirmed via
`MacWSHost.log` and `tmp/v50-terminal-paused-width-1/frame-011.png`:

```text
1789181038.920 window-configuration ack ... sequence=19 ... requested=556.8x203.2 applied=549.0x199.0 ... result=constrained
1789181039.047 window-configuration scene-follow armed ...
1789181039.173 host-drawable-policy ... bounds=673.50x254.00 ...
```

The reverse transaction started before the physical contact ended; the resumed
half no longer followed. Those excerpt ellipses omit unrelated identity fields,
not timing. Quiet bounds are not a native gesture-end witness.

## Actual-binary lifecycle boundary

RE-confirmed in this device's SpringBoard shared cache, bounded class metadata
and function reads only:

```text
SBItemResizeGestureSwitcherModifier
handleGestureEvent:                         0x1c79cf048
_responseForGestureUpdateAtGestureEnd:       0x1c79cf33c  @20@0:8B16
0x1c79cf108 stores selectedAppLayout
0x1c79cf128 stores selectedLayoutRole
0x1c79cf290 calls phase
0x1c79cf294 cmp ... #3
0x1c79cf298 cset w2, eq
0x1c79cf2a0 calls _responseForGestureUpdateAtGestureEnd:
```

v51 retains the original response and exact selected FBS Scene. A per-Scene
Darwin notification state carries writer PID and contact-active state. Host
reads current state, checks writer liveness, and keeps a constrained settlement
pending through pauses. The native end edge resumes settlement after the last
UIKit update. Catalog and autonomous-follow paths use the same ownership check.
Stock iOS app gestures neither publish nor consume this macPad state.

No check or native gesture response is bypassed. Only one SpringBoard reload
was used to install this lifecycle hook. WindowServer stayed PID76954. New
SpringBoard PID158 and Host PID183 used these exact signed bytes:

| Artifact | SHA-256 |
|---|---|
| Host | f7f7180d4df13a2c118fb90d806e8408513eac9abfe3ef277d7e2dfd867952ba |
| Windowing | 3aa2f8735ae2c6449c21043a3f7727d6c9f658576ede43e9cd2344e283b56802 |

The previous binaries are in
`/var/mobile/Media/macws-v51-native-gesture/backups`. v50 AppInput libraries
remain installed. Finder PID98948/window310 and Terminal PID97632/window304
were used, not older processes carrying an earlier library.

## Passed cases

- **Paused native Terminal shrink**: `tmp/v51-terminal-paused-width-1/frame-011.png`.
  Contact stayed down for 0.8 seconds of movement plus a 0.45-second pause.
  It resumed, continued receiving new ACKs, and reached Terminal's true
  230-point minimum rather than learning an arbitrary intermediate minimum.
- **About first visible size**: `tmp/v51-about-open-1/frame-006.png` is the
  first visible frame; it already has the target 376×456 Scene size. Frame009
  still has Finder and Terminal alongside it. There was no large black
  opening container followed by a second size in this sequence.
- **Get Info opening and General expansion**:
  `tmp/v51-getinfo-open-1/frame-010.png` and
  `tmp/v51-getinfo-expand-general/frame-011.png` show four coexisting windows.
  The expansion transaction retained all four exact Scene identifiers.
- **Get Info maximum width**: `tmp/v51-getinfo-maxwidth/frame-011.png`.
  A native corner drag continued beyond the limit, but Scene width stayed
  500 at density1.25; AppKit ACK and metrics both report width400. Fixed
  height followed the content's reflow (555→541), not the finger's Y position.
  All four windows remained; no persistent side bands in the final capture.
- **Terminal can grow after reaching its minimum**:
  `tmp/v51-terminal-grow/frame-011.png`, four windows retained, readable final
  Terminal without persistent bands. Transient mismatch is NOT a passed gate.
- **Focus without macOS-content click**:
  `tmp/v51-terminal-chrome-focus.png`, selected through Host/iOS chrome;
  native metrics marked exactly window304 Focused, and native traffic lights
  and cursor became active. No native content click was injected.
- **150% selection**: `tmp/v51-density150-terminal.png` shows actual larger
  Terminal text; source900×766 and drawable900×767 remain native-sampling
  peers. Other existing Scenes did not acquire Terminal's logical size.

Verbatim runtime witnesses:

```text
1789181542.200 native-resize-gesture scene=sceneID:com.macwsguide.host-A7B7CAE3-B791-4140-B8A2-9AA73C37A80E window=304 active=YES
1789181543.408 native-resize-gesture scene=sceneID:com.macwsguide.host-A7B7CAE3-B791-4140-B8A2-9AA73C37A80E window=304 active=NO
1789181956.222 window-configuration ack window=317 pid=98948 sequence=12 request-time=86568.490528 requested=400.0x541.0 applied=400.0x541.0 queued=400.0x541.0 result=applied
1789181956.335 resize-policy springback scene=sceneID:com.macwsguide.host-9A6BCA5F-3B0A-4BAC-BE90-92B50AFB5931 proposed=554.5x714.0 constrained=500.0x724.0 result=500.0x724.0 fixed=NOxYES
1789182164.708 scene-focus request reason=_UIWindowDidBecomeApplicationKeyNotification scene=A7B7CAE3-B791-4140-B8A2-9AA73C37A80E window=304 pid=97632 application-key=YES issued=YES
1789182379.814 host-drawable-policy window=304 bounds=675.00x575.00 previous=915x792 source=900x766 drawable=900x767 display-scale=2.000 backing=2.000 density=1.500 policy=source-native-auto fullscreen-canvas=NO
```

## Failed or still pending gates

1. **General collapse transient black bands**. Frame003 of
   `tmp/v51-getinfo-collapse-general` shows smaller native content inside the
   still-large UIKit window. Frame011 is correct and retains the four
   windows, but final convergence is insufficient acceptance.
2. **Premature Scene-follow completion**. Runtime-confirmed:

   ```text
   1789182049.613 window-configuration scene-follow reached window=317 pid=98948 logical=400.0x410.0 after-deadline=NO
   1789182049.711 host-drawable-policy window=317 bounds=500.00x513.00 previous=800x1082 source=800x820 drawable=800x821 display-scale=2.000 backing=2.000 density=1.250 policy=source-native-auto fullscreen-canvas=NO
   ```

   `scheduleWindowConfiguration` compared its fixed-axis-overridden proposal
   with the target, not the actual UIKit bounds. v52 changes that comparison
   to physical bounds with 1.5 UIKit-point rounding tolerance. Tests reject
   the real 500×676 old content extent and accept 500×513. v52 visual
   acceptance is pending; this alone does not prove removal of black frames.
3. **SpringBoard model versus UIKit postcondition**. The paused Terminal test
   briefly reported model288×271 against target288×268 even after UIKit
   content was 288×220 plus48 chrome. That triggered one redundant native
   transaction. Do not weaken the postcondition to hide this discrepancy.
4. **Host restoration startup**. `tmp/v51-reload-state.png` contains a brief
   oversized restored container; `tmp/v51-settled-stage.png` is correct. The
   successful About first-open case does not prove restoration is flicker-free.
5. **Window-mode final composition and Weather** remain unverified. The new
   bounded selective-capture probe stopped at `preflight-denied`, exit77,
   before allocating a stream. Its permission check was not bypassed. No
   selective-composite pixels were obtained or integrated into production.

38 Python source-contract tests and causal-ACK/Scene-bounds C tests pass after
the v52 bounds correction. These tests are contract checks, not visual proof.
