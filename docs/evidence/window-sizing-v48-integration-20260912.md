# Window sizing integration: v48 deployed; v49 follow-up in progress

## Actual device observations

On 2026-09-12 the v46 failure was reproduced through Finder's production menu
socket and inspected in a complete iPadOS composite, including the system Dock,
status bar, and window chrome. `tmp/window-size-v46-before.png` shows the large
Finder. `tmp/window-size-v46-about-settled.png` shows both Finder and About at
approximately 301×378 points, with the main Finder clipped. The Host's old
`landed=YES` / foreground-count logs did not establish visible correctness.

v47 and the independent drawable-resolution correction were deployed together
using one SpringBoard restart and one Host relaunch. WindowServer and Finder
were not restarted. `tmp/window-size-v47-current.png` visibly shows a large
Finder with small About and Get Info windows together. The user confirmed a
substantial improvement, but reported occasional stage ejection on new-window
activation, missing Get Info width ceiling, and slow/incorrect rapid Terminal
resize. These remaining reports are not marked resolved by that screenshot.

## Integration fixes prepared in v48

- Restore preactivation size publication. Runtime witness v47 advertised
  `initial=preactivation-lower-per-item-calculator`, while Host accepted only
  `initial=preactivation-generic-app-layout-grid`. Host now recognizes a stable
  `initial-size-protocol=1` capability and both older compatible route labels.
- Coalesce automatic activation when the exact Scene is already foreground.
  Runtime Terminal 193 creation at `1789154726.157` was followed by another
  existing-session activation at `1789154726.272`. Also serialize creation of
  the same PID/window-group identity before UIKit exposes its session. Explicit
  picker/URL foreground requests remain available.
- Carry logical maximum size through stream metadata, activity restoration,
  window/fullscreen return state, Host limits and per-Scene SpringBoard policy.
  Convert logical AppKit size to Scene size once, using density and real chrome.
  The Scene request's 4096-point wire ceiling must not reject AppKit's much
  larger unbounded sentinels.
- Deliver producer ACKs after native limits, with exact request timestamp,
  sequence, requested size, and applied size. Check both entry and exit pending
  state before treating a catalog size as an autonomous AppKit resize.
- A new policy while geometry is pending is published as metadata only. It
  must not cancel a queued configure, initiate reverse geometry, or replace an
  in-flight SpringBoard geometry nonce. Policy and geometry queues are separate.

The upstream findings and protocol compatibility are documented in
`windowing-native-limits-and-configure-ack-20260912.md`; the request-correlation
invariant is in `window-configuration-ack-correlation-20260912.md`. The original
whole-stage policy leak is in
`windowing-stage-wide-limit-policy-leak-20260912.md`.

## Local verification (not visual acceptance)

Host, libmachook arm64/arm64e, displayd, hostd and Tweak v48 compile successfully.
Protocol validators, drawable-resolution regression tests, configure-ACK
classification tests, and the evidence script's self-tests pass. Tweak's
arm64e CFString class references retain authenticated DA bindings (158) and no
plain bindings. Staged libraries/services have valid ad-hoc signatures and
unchanged entitlement dictionaries; see `tmp/macws-v48-staged/manifest.json`.

The user subsequently authorized autonomous application restarts. All nine
v48 installed paths were independently backed up, signed bytes were trusted
and verified, and the coordinated generation was activated. SpringBoard became
43824, displayd 43819, hostd 43821; WindowServer remained **76954**. Finder
43902 and Terminal 43918 loaded the new AppInput bridge. No full postinst or
WindowServer restart was used.

Actual iPadOS captures `tmp/window-size-v48-live.png` and
`tmp/window-size-v48-about-current.png` show independent main Finder, About,
Get Info and Terminal windows. Get Info V3 metrics publish the actual native
400-point width ceiling and changing fixed height. This is partial progress,
**not acceptance of all resizing behavior**. The user reported that Get Info
disclosures and manual Terminal resize can still eject siblings, and that
Terminal becomes incorrectly difficult to shrink.

The latter is runtime-confirmed: Terminal's published minimum changed from
230×176 to 1055×176 during resizing. The bridge previously promoted a single
constrained resize result to a permanent minimum. That heuristic was removed;
only native min/max and required root content constraints remain. The
separately backed-up v48b library update passed chroot smoke, and a new Terminal
57774 opened window 283 with minimum 230×176. Its Scene was subsequently
discarded (`1789159533.599 scene-close source=did-discard ... window=283`),
so this is **not** a completed rapid-resize test.

The v49 whole-stage transaction correction and its actual SpringBoard RE are
documented in `windowing-programmatic-resize-stage-membership-20260912.md`.
It still requires full iPadOS visual acceptance after deployment; compilation
and model postconditions do not establish that siblings stayed visible.

## Next device acceptance

1. Preserve each installed path separately: the old package-storage arm64e
   libmachook and live rootfs arm64e libmachook are different versions. Retain
   the working rootfs generation for rollback.
2. Publish the signed thin libraries, displayd, hostd, Host, and v48 Tweak as
   one coordinated generation. Do not restart WindowServer or run full postinst.
   Reopen only approved target applications to load new AppInput metrics/ACKs.
3. Capture full iPadOS composition before, through, and after opening About,
   alongside Finder and Get Info. Verify first visible geometry and preservation
   of sibling windows; repeat instead of judging one settled frame.
4. Check actual new Get Info metrics contain the native width ceiling, then
   observe a real corner drag past it and disclosure-height changes. Confirm no
   persistent black margin and independent fixed height.
5. Rapidly resize Terminal and correlate exact configure ACKs with observed
   source/Scene dimensions. Check no old snapshot initiates reverse geometry,
   no stuck pending transaction, and no post-gesture clipping.
6. Record any remaining unsupported behavior explicitly. Existing log-only
   evidence tool deliberately returns visual acceptance as UNVERIFIED.

The frozen screenshot tool is `misc/capture_ipados.sh` with device helper
`/var/mobile/Media/macws_ipados_capture-v9`; it records real composition.
The separate `ios_hid_touch_probe` v2 is deployed. A bounded read-only observer
identified physical digitizer sender `0x1000007ea`. **Its orientation mapping
is not yet calibrated and no Stage Manager corner drag has been accepted.**
It requires coordinate calibration before any injection. Do not substitute
macOS input-broker/VNC gestures for native iPadOS corner-drag acceptance.
