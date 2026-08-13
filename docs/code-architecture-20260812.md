# MacWS source architecture — 2026-08-12

This milestone reduces coupling at the two hottest trust and presentation
boundaries without changing the wire protocol or the native-AGX rendering
path. The protocol validator remains authoritative for ABI compatibility.

## Production modules

### WindowServer final composite

- `libmachook/Metal_hooks.x` is the Metal interception adapter. It identifies
  the process-owned completed BGRA scanout and provides its IOSurface.
- `libmachook/MacWSFinalCompositePublisher.*` owns content admission, the
  one-deep completion observer, launchd Mach-service lookup, service
  replacement recovery, record construction and bounded failure witnesses.
- `macwsdisplayd/MacWSFinalCompositeReceiver.*` owns the untrusted Mach receive
  boundary. It validates the message envelope, audit-token PID, exact
  WindowServer executable path, record and IOSurface metadata.
- `macwsdisplayd/main.m` receives only an accepted `(surface, record)` pair and
  owns subscriber backpressure/presentation.

No RFB encoding or CPU framebuffer copy is introduced by this split.

### MacWSHost

- `Support/MacWSHostDiagnostics.*` owns runtime diagnostic selection, timestamp
  conversion and file logging.
- `Support/MacWSHostRuntime.*` owns the Unix input transport, shared-frame ACK
  compatibility reader, endpoint readiness checks and one-shot Metal registry
  witness. None of those process/transport details remain in the Scene
  controller.
- `Input/MacWSKeyMapping.*` owns the pure macOS virtual-key, X11 keysym and
  ASCII translation tables. UIKit event lifecycle and transport remain in the
  view/controller; adding a keyboard layout no longer grows that controller.
- `Transport/MacWSCatalystDrawableReceiver.*` owns the authenticated Catalyst
  drawable Mach service and emits validated notifications to the renderer.
- `Rendering/MacWSCatalystDrawableCompositor.*` owns Catalyst IOSurface/Metal
  texture lifetime, newest-sequence admission and the geometry-only draw
  primitive. The view chooses whether a producer is relevant; it no longer
  implements Mach delivery, texture ownership and vertex construction in one
  method.
- `Rendering/MacWSMetalView.*` owns the DisplayStream/Metal presentation view
  and its touch, pointer, keyboard and gesture state machines. `main.m` now
  coordinates UIKit Scenes, window lifecycle and control-center presentation;
  it no longer also contains the 4,000-line renderer/input implementation.
- `Launch/MacWSCatalystLaunchCoordinator.*` owns the two foreground-carrier
  Darwin notifications, fixed launcher argv and child reaping. The UI app
  delegate only installs this boundary; hostd and the launcher still validate
  the exact application request and identity.
- `Compatibility/MacWSMappedFrame.*` contains the legacy mmap framebuffer
  adapter. It is reachable only through the explicit
  `MacWSLegacyFramebufferFallback` preference; production uses DisplayStream
  IOSurfaces.
- `Testing/` is reserved for explicitly invoked profile/regression adapters.
  `MacWSPerformanceGestureScenario` owns synthetic scenario timing while the
  view supplies narrow callbacks into the real input boundary. Test scenarios
  must not become a prerequisite of streaming, input routing, application
  launch or presentation.

### AppInputBridge

- `libmachook/Diagnostics/MacWSInputLatency.*` is the opt-in latency recorder.
  Its marker files and JSONL output are absent from the production input path
  unless a regression explicitly sets `MacWSInputFlagLatencyDiagnostic`.
- `AppInputBridge.m` retains event construction, native Dock modal routing and
  the bounded main-thread queue. Continuous pointer/scroll/configure samples
  may coalesce, but magnification deltas remain discrete because AppKit
  consumes them as incremental ratios.
- Scroll delivery has two framework-capability routes. Electron windows use
  process-local pixel NSEvents with native phase/momentum fields; windows that
  do not consume that path use WindowServer's integral remote-wheel API with a
  runtime-calibrated 40-logical-pixel accumulator and preserved residual. The
  decision is based on the real `ElectronNSWindow` class contract, never a
  VSCode bundle identifier or fixed screen coordinate. The bounded CDP probe
  `misc/cdp_scroll_transport_probe.mjs` observes Chromium state without
  synthesizing input, while `misc/host_scroll_delivery.py` emits the same v4
  records as the UIKit boundary.
- `libmachook/Compatibility/MacWSCatalystKeychain.*` owns the narrowly scoped
  Catalyst Security compatibility adapter. It first calls the stock Ventura
  Security API and falls back only for unavailable/MDS statuses. The fallback
  sends property-list requests to `macwskeychaind`; it contains no local or
  plaintext credential database.
- `libmachook/Compatibility/MacWSCatalystInputPolicy.*` owns the generic
  Catalyst client-area classification. A real `_UINSWindow` client point uses
  the process-local responder chain; its title bar and traffic lights retain
  the verified WindowServer pointer route. This policy is class/geometry based
  and contains no application or coordinate allowlist.
- `libmachook/Diagnostics/MacWSRandomDiagnostics.*` and
  `MacWSIdentityDiagnostics.*` contain observation-only Asphalt bring-up
  witnesses. The launcher clears their environment for every production child
  and enables them only when an explicit rootfs sentinel exists.
- `macwskeychaind/` is a mobile-session iOS-native Security adapter. It accepts
  only uid 501 requests from Asphalt's exact executable path, only generic
  passwords, and only the two original Gameloft access groups. Unsupported
  reference result types fail closed.

This organization makes the top-level files coordinators rather than owners
of unrelated policy. `MacWSMetalView.m` is intentionally still one cohesive
state machine: its gesture recognizers, coordinate mapping and rendering
admission share ordering-sensitive state. The next split should extract one
state machine behind an explicit protocol, not scatter coupled ivars across
categories. Scene lifecycle and control-center UI remain the corresponding
targets in `main.m`.

## Invariants

1. Native AGX remains the only production GPU target.
2. The final-composite producer publishes only after the existing sampled
   content-ready witness.
3. The receiver accepts only the audit-token-authenticated WindowServer
   executable and matching IOSurface metadata.
4. The producer and receiver remain latest-state streams; no frame FIFO can
   accumulate during an animation.
5. Production diagnostics stay disabled unless an explicit environment value
   or sentinel enables them.
6. Legacy mmap transport never silently replaces DisplayStream.
7. Final-composite mode remains authoritative for native SkyLight effects,
   except a focused Host-carried Catalyst client whose real completed drawable
   is absent from SkyLight capture; only that exact window rectangle is
   replaced.

## Verification before device deployment

```text
gmake -C libmachook clean all ...        PASS (arm64 + arm64e)
gmake -C macwsdisplayd clean all ...     PASS (arm64)
gmake -C MacWSHost clean all ...         PASS (arm64)
gmake clean all OPTFLAG=-O2 ...          PASS (complete aggregate build)
cc -std=c11 -Wall -Wextra -Werror \
  -Iinclude misc/macws_protocol_test.c -lm ...
                                            PASS
git diff --check                           PASS
```

The next milestone must run the installed-package release gate before changing
Mission Control pointer latency, magnification coalescing or third-party game
launch behavior. That keeps structural changes and behavioral optimization
separately attributable.

## Post-split runtime regression

The structural refactor was deployed without restarting WindowServer or iOS.
The native `mission-select` scenario passed against the final composite:

```text
visible active average      109.824 FPS
visible p50 / p95 / p99     8.337 / 16.674 / 16.674 ms
visible 1% low              59.975 FPS
thumbnail Tap -> visible    37.161 ms
hitches / >50 ms stalls     0 / 0
Metal command errors        0
thermal                     nominal, 35.50 C
```

This is runtime-confirmed via
`/tmp/macws-mission-after-refactor.json`. Mission selection is consumed by
Dock's native modal controller, so Tap-to-first-visible-final-composite is the
correct endpoint; waiting for an AppKit `mouseDown` in the selected process
would measure an event that macOS does not deliver.

Maps magnification had one source-confirmed discontinuity: the bridge added
multiple incremental ratio deltas into one queued record. Magnify was removed
from continuous coalescing while ordinary motion remains bounded. The real
Maps follow-up passed at 90.77 visible FPS, 47.98 FPS 1% low, no hitch/stall,
and no Metal error under nominal temperature.

Asphalt exposed a separate presentation regression after final-composite was
enabled. Runtime logs proved that its completed 1330x910 IOSurface was imported,
while source inspection showed the final-composite branch skipped every
Catalyst drawable. The new compositor preserves final SkyLight pixels and
replaces only the focused Catalyst window client rectangle. A fresh process
then logged:

```text
runtime-confirmed catalyst-drawable imported pid=9000 surface=686 size=1330x910 bpr=5376 metal-pf=80
runtime-confirmed catalyst-drawable presented pid=9000 surface=686 sequence=4 size=1330x910 status=4 error=nil
```

VNC remains intentionally unable to see that Host-only overlay, so a VNC black
client area is no longer a valid witness for the iPad Host presentation of a
Catalyst game. Registration/gameplay and a sustained in-race FPS record remain
open until the visible Host UI can be driven through onboarding.

The explicitly invoked test probe subsequently sampled the current process
PID 11918 at sequence 7960: 51,274 of 65,536 stratified bytes were nonzero and
the digest remained `b74f9a321e64e472`. Its exported frame showed Asphalt's
own `CONNECTION ERROR` page rather than a transport-black frame. A bounded
synthetic Retry tap was runtime-confirmed by unified logging to enter the real
Catalyst `UIWindow`; it did not change the frame digest. Network A/B then found
that four Gameloft endpoints completed DNS/TLS/HTTP on iOS, while
`gameoptions.gameloft.com` alone failed certificate verification. The server
presented a Sectigo leaf plus an unrelated Entrust intermediate; OpenSSL
reported `unable to verify the first certificate`. Adding the actual
`Sectigo Public Server Authentication CA OV R36` intermediate to a scoped
test bundle changed the same chroot request from curl error 60 to HTTP 302.
This is the current upstream boundary for Asphalt launch; production must fix
the missing CA material for this validated child, not disable peer validation.
