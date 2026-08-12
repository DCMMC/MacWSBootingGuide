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
- `Transport/MacWSCatalystDrawableReceiver.*` owns the authenticated Catalyst
  drawable Mach service and emits validated notifications to the renderer.
- `Compatibility/MacWSMappedFrame.*` contains the legacy mmap framebuffer
  adapter. It is reachable only through the explicit
  `MacWSLegacyFramebufferFallback` preference; production uses DisplayStream
  IOSurfaces.
- `Testing/` is reserved for explicitly invoked profile/regression adapters.
  Test scenarios must not become a prerequisite of streaming, input routing,
  application launch or presentation.

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
