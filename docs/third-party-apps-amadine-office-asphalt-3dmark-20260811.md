# Third-party application milestone — 2026-08-11

This milestone covers production launches of Amadine, Microsoft Office and
Asphalt on the iPad13,6 macOS 13.4 chroot, plus the exact remaining 3DMark
installation boundary. All chroot GPU work uses `MACWS_AGX_NATIVE=1`; MTLSim
was not used. The iPad and MacBook watchdogs sampled every 300 seconds and
intervened only for an explicit `critical` thermal state. No reboot or
respring was performed.

## Result matrix

| Application | Production result | Runtime witness |
|---|---|---|
| Amadine | Launch, new document, trial panel and vector drawing work | Fresh canvas and rectangle tool remained responsive under the normal custom-path launcher; no new fatal report was produced |
| Word / Excel / PowerPoint | Installed with the user-provided Microsoft packages and LTSC serializer; blank documents and keyboard input work | Word accepted `MacWS Office production test`, Excel A1 accepted `MacWS Excel`, and PowerPoint accepted `MacWS PowerPoint` while each process remained live |
| Asphalt | The Mac Catalyst executable launches as a direct child of the existing foreground MacWSHost, resolves Gameloft endpoints, renders with native AGX, and now reaches Host through a zero-copy IOSurface path | `runtime-confirmed catalyst-drawable imported pid=36786 surface=581 size=1330x941 bpr=5376 metal-pf=80`, followed by `runtime-confirmed catalyst-drawable presented ... status=4 error=nil` |
| 3DMark | The MacBook download is not a Ventura Catalyst executable; it is Apple's “Designed for iPad” wrapper containing an encrypted iPhoneOS build. The compatible iPad variant must be installed by App Store on the iPad | Local bundle: `CFBundleSupportedPlatforms=(iPhoneOS)`, `MinimumOSVersion=26.0`, `LC_ENCRYPTION_INFO cryptid=1`; App Store product 1512372293 advertises an iPadOS 15-compatible device variant |

## Scoped mount and DNS compatibility

The first two application families exposed the same upstream invariant: an
application selected by a validated absolute path must see the chroot root
volume and container paths, not iOS host-volume identities. `macwshostd` and
the generic Catalyst carrier now set `MACWS_APP_MOUNT_COMPAT=1` only for that
validated child. `MacWSCatalystLauncher` explicitly removes
`MACWS_APP_MOUNT_COMPAT_DIAGNOSTIC`, preventing a foreground Host started from
a debug shell from leaking broad tracing into a production game.

Asphalt separately proved that macOS `getaddrinfo` could not resolve the two
Gameloft endpoints even though iOS-native curl could. `DNSBridge.c` first calls
the unmodified local resolver and only on failure asks `macwshostd` to perform
a bounded typed lookup. Runtime after deployment:

```text
DNS-BRIDGE node=eve.gameloft.com local=8 bridged=0
HTTP/1.1 200 OK
DNS-BRIDGE node=oct.tools.gameloft.com local=8 bridged=0
HTTP/1.1 200 OK
```

The fallback is quiet in production; `MACWS_DNS_DEBUG` is diagnostic-only.

## Asphalt black-client-area root cause boundary

The project's on-device LLDB tool stopped Asphalt at the real
`-[_MTLCommandBuffer presentDrawable:]` boundary. Runtime memory and exact
IOGPU getter disassembly established:

```text
drawable texture = 0x29956d950
pixelFormat       = 80 (BGRA8Unorm_sRGB)
width × height    = 1330 × 941
IOSurface         = 0x13f6e7d60
base address      = 0x16b104000
bytes per row     = 5376
```

The IOSurface was not black. Directly exporting its 5,058,816-byte pixel plane
produced the complete “PLEASE TELL US YOUR AGE” game screen. At the same time,
SkyLight's exact-window stream for window 312 published a 2048×1448 surface
whose client area was black while its AppKit title bar and traffic lights were
visible. This is runtime-confirmed attribution of the broken boundary: game
rendering, texture creation, command commit and drawable presentation work;
the missing pixels occur between that Catalyst CAMetalLayer and SkyLight's
captured client area.

Passing only `IOSurfaceGetID` was tested and rejected by evidence, not retained
as a timing workaround: Host received the records but
`IOSurfaceLookup(surfaceID)` returned null. The production path instead uses
the same ownership primitive as DisplayStream:

1. The foreground Host registers the bounded bootstrap service
   `com.macwsguide.catalyst-drawable` with a Mach receive right.
2. The Catalyst child attaches a completion handler before the original
   `presentDrawable:` implementation and waits for the real GPU completion.
3. It creates an IOSurface Mach port and sends one typed complex Mach message
   with `MACH_MSG_TYPE_MOVE_SEND`.
4. Host validates magic/version/size, exactly one port descriptor, owner PID,
   dimensions, stride, pixel format and Metal alignment before importing.
5. Host keeps the original SkyLight texture for title bar/traffic lights and
   draws the native game texture over the client region in the same Metal
   command buffer.

This is not a check bypass and does not fabricate a buffer. The producer's
real completed IOSurface is transferred with kernel-enforced Mach ownership,
then sampled directly by the iOS AGX device. Runtime completion status `4`
with `error=nil` is the downstream witness.

## 3DMark compatibility boundary

The 2.0-GiB `/Applications/3DMark.app` downloaded on the MacBook is an App
Store wrapper at `Wrapper/3DMark-iOS.app`, not a normal
`Contents/MacOS/...` application like Asphalt. Its current thinned payload is
an arm64 iPhoneOS executable with `MinimumOSVersion=26.0` and FairPlay
`cryptid=1`; the target iPad runs 16.3.1. Re-signing, changing the plist, or
extracting/decrypting that payload would neither supply the missing OS ABI nor
be a legitimate compatibility fix.

Apple's product page currently lists iPadOS 15.0 as the compatibility floor.
Therefore the lawful and technically correct next step is to let App Store on
the iPad request product ID `1512372293`, which selects the iPad-compatible
variant for that device and preserves its receipt. The product page has been
opened on the iPad; installation still requires the normal user App Store
authorization/tap. After that install lands, MacWS can test the device variant
without modifying FairPlay material.

## Control Center integration

Per the user's 2026-08-11 decision, 3DMark is no longer an active test target
and has no Control Center entry. The production Control Center now exposes
Amadine, Word, Excel, PowerPoint and Asphalt. Availability comes from each
exact executable's file-mode witness, so an uninstalled app remains disabled.

Amadine and the three Office applications enter the same typed allowlist and
scoped `MACWS_APP_MOUNT_COMPAT=1` launch transaction used for their successful
production tests. Asphalt is deliberately different: its button writes one
root-owned `0600` property-list request containing only the fixed executable,
bundle identifier and container home, then asks the already-foreground
MacWSHost to create the Catalyst child. The returned PID must have the exact
root-owned per-PID carrier marker before hostd accepts it. This preserves the
validated UIKit/FrontBoard ancestry and does not fall back to a bare chroot
spawn or create a second black iPadOS scene.
