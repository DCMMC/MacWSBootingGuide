# Cold Maps, native Desktop and QuartzCore tile validation

Date: 2026-08-09

Device: iPad13,6, iPadOS 16.3.1, Ventura 13.4 chroot, native AGX production
fullscreen workspace

Package: `com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb`

Package SHA-256:
`4718e4bde84ded3a7c120c1f7851017a1001d9faf291322c81c9e25fda00afd9`

QuartzCore compatibility artifact:

```text
bytes=1048304
sha256=909a864e28f22fd264598d2aaed29e0900ae89f562e9998d6cc31aedac36f4a9
fnv1a64=2939b64a5ca3cd91
functions=12/128
```

## Accepted visual witnesses

- `production-desktop-after-fnv-fix.png`: production desktop and wallpaper
  after exact artifact verification.
- `mission-control-after-fnv-fix.png`: Dock's native Mission Control UI
  rendered without replacing WindowServer.
- `native-space-created-via-cgs.png`: three real Desktop thumbnails after the
  bounded SkyLight creation diagnostic.
- `maps-live-after-hiservices-cold-trust.png`: Maps responds after restoring
  the exact HIServices executable CDHash.
- `maps-route-panel-after-tile-shader-fix.png`: the route panel that previously
  reached `tile_downsample_4` now renders its translucent native chrome.
- `maps-current-location-after-auth-readback.png`: populated stock map tiles
  plus the native blue current-location marker after authorization status `3`.
- `maps-current-location-after-launch-refresh.png`: the stronger final witness:
  a newly launched Maps process received its app-generation authorization
  refresh and handled the current-location control without a manual helper.

## Runtime acceptance

The exact installed package above was accepted with WindowServer PID `81749`
alive for more than 64 minutes, Maps PID `20475`, `macwsinteropd` PID `20375`,
and `macwslocationd` PID `20377`. The bridge recorded:

```text
MACWS-INTEROP refreshing Maps authorization for application pid=20475
MACWS-INTEROP Ventura location services and Maps authorization verified status=3
```

The final VNC framebuffer was `2388x1668`, displayed populated stock tiles and
the blue current-location marker, and changed after the current-location
button was pressed. No WindowServer, Dock, or Maps crash report was created in
the final 30-minute acceptance window, including the subsequent bounded
Mission Control and top-strip input probes. The watchdog's final five-minute
sample was `thermal-state=nominal`, `effective-temp-centic=3700` (37.00 C).

No coordinate-bearing unified log is committed. No iPad reboot or respring
was used. The thermal watchdog remains five-minute, Critical-only; final
temperature and process IDs are recorded after installing the final package.
