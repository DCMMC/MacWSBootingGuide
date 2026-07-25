# Native iPadOS host (M0/M1)

`MacWSHost` is the first milestone toward presenting each chroot macOS window
as an iPadOS `UIWindowScene` instead of viewing the whole desktop through VNC.
It is an iOS application built by the root Theos aggregate.

## What M0 implements

- The application scene manifest sets `UIApplicationSupportsMultipleScenes`.
  The **New Window** button asks UIKit for another independent scene session.
  The first scene is runtime-confirmed; iOS 16.3.1 SpringBoard currently
  rejects the second request with `SBSceneManagerCoordinatorDomain Code=1`,
  so multiple simultaneous scenes are not yet claimed.
- Every scene reads the existing WindowServer capture at
  `/var/mnt/rootfs/private/tmp/macws_vnc_fb` directly. No `OSXvnc-server`, RFB
  encoding, network socket, or VNC client is involved.
- When `MTLCreateSystemDefaultDevice()` succeeds, an iOS-native Metal render
  pipeline uploads the BGRA frame and presents an aspect-fitted quad.
- The dedicated entitlement set names only the two runtime-denied IOKit
  clients, `AGXDeviceUserClient` and `IOSurfaceRootUserClient`.  This changes
  the device result from nil to `Apple M1 GPU`; a completed render/present
  command buffer (`status=4 error=nil`) is the M1 witness.
- If the iOS process cannot enumerate a Metal device, an explicitly labelled
  UIKit/CoreAnimation fallback displays a stable snapshot. This is a recovery
  path, not evidence of an App-local Metal present.
- Touch and pointer coordinates are transformed from the aspect-fitted scene
  into physical macOS framebuffer pixels. M2 sends version-2 records to the
  chroot `macwsinputd` over a local Unix datagram and maps them into Quartz
  display coordinates. Two-point diagnostics confirm that posted mouse-move
  events change the observed system cursor; a physical touch on a known macOS
  control is still required before claiming complete interactive control.
- Runtime evidence is appended to
  `/var/mobile/Library/Logs/MacWSHost.log`. A successful Metal presentation is
  only claimed after the corresponding iOS `MTLCommandBuffer` completion says
  `status=4 error=nil`.

The shared C layouts live in `include/macws_host_protocol.h`.

## Current input ABI

MacWSHost sends packed 48-byte records to
`/var/mnt/rootfs/private/tmp/macws_host_input.sock`; inside the chroot,
`macwsinputd` binds the same vnode as `/private/tmp/macws_host_input.sock`.
Each record contains:

```text
uint32 magic = 0x4d574556  // "MWEV"
uint16 version = 2
uint16 kind                 // down/move/up/cancel/hover
uint64 sceneID
double timestamp
float  x, y, pressure
uint32 contactID
uint32 frameWidth, frameHeight
```

The source dimensions are load-bearing. The current producer is 2388x1668,
while the coexistence Quartz display is 1194x834; v1 lacked these fields and
incorrectly mapped the producer center to the display corner. No fixed Retina
scale is assumed in v2.

`macwsinputd` maps touch down/move/up/cancel to left mouse
down/drag/up and hover to mouse moved. It rejects malformed versions, sizes,
kinds, non-finite values, and out-of-bounds coordinates before creating a
CGEvent.

## Current framebuffer ABI

The file contains a 16-byte little-endian header followed by BGRA8 rows:

```text
uint32 magic = 0x564e4346  // "VNCF"
uint32 width
uint32 height
uint32 stride
uint8  pixels[stride * height]
```

This is intentionally only an M0 transport. It has no generation counter,
write-in-progress flag, damage rectangles, window identity, or atomic publish
operation. At 2388 x 1668 it is 15,932,752 bytes, so repeatedly copying the
whole display is unsuitable as the final interactive protocol.

## Build and launch

Build the project normally, or build only the application while iterating:

```bash
THEOS=/var/jb/var/mobile/theos make -C MacWSHost clean all \
  FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1
```

After package installation and `uicache`, launch it from the Home Screen or:

```bash
uiopen macwshost://
# Diagnostic: ask the running app to create another scene session.
uiopen macwshost://new
# Diagnostic: send one synthetic hover through the real M2 transport.
uiopen 'macwshost://test-input?x=1194&y=834&w=2388&h=1668'
```

To exercise the current capture path without VNC, create the existing capture
sentinels before starting WindowServer in coexist mode. These switches are
still diagnostic scaffolds, not production protocol fixes:

```bash
touch /var/mnt/rootfs/private/tmp/macws_vnc_share
touch /var/mnt/rootfs/private/tmp/macws_kcmd_fix
touch /var/mnt/rootfs/private/tmp/macws_cancel_completion
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist \
  --no-terminal --no-vnc
sudo launchctl start com.apple.WindowServer
```

The compressed PF550 one-shot read additionally uses
`/tmp/macws_capture_final`. The ordinary long-term transport must not depend on
that diagnostic; it should publish completed per-window IOSurfaces from a
producer-owned ring.

## Evidence and known boundaries

Runtime on iPad13,6 / iOS 16.3.1 confirmed that:

- the app registers as `com.macwsguide.host` and connects a
  `UIWindowSceneSessionRoleApplication` scene;
- using the WindowServer/backboardd entitlement set made UIKit abort during
  `_UIApplicationMainPreparations`, while the dedicated minimal entitlement
  set reaches the scene delegate;
- a fat arm64e build traps in libobjc `readClass()` because of the current
  on-device lld Objective-C fixup ABI, while the arm64-only application starts
  natively on the same M1 hardware;
- WindowServer can publish a nonzero 2388 x 1668 frame while no VNC server is
  running;
- the exact Metal registration inputs are present (`AGXAcceleratorG13G_B0`,
  `AGXMetal13_3`, and `AGXG13GDevice`), while the old nil result was caused by
  MACF denials for `AGXDeviceUserClient` and `IOSurfaceRootUserClient`;
- after granting just those two IOKit classes, the iPadOS-native Metal path
  presents the nonzero frame on `Apple M1 GPU` and completes with no error;
- `supportsMultipleScenes=YES` is not sufficient on this installation:
  SpringBoard accepts the first scene but rejects the second.  Public request
  variants and `platform-application` A/Bs do not change that result;
- two synthetic M2 records sent by MacWSHost reached `macwsinputd`, mapped
  `(240,300)` to `(120,150)` and `(1900,1300)` to `(950,650)`, and those exact
  Quartz locations were read back from the system cursor state after posting.

M0 is not the final per-application design. It still mirrors a full macOS
display into every iPadOS scene. The next milestones are:

1. inspect the failed SpringBoard scene request's real persistence identifier
   and mapping with a stable early-attach/runtime probe; do not force its
   success branch;
2. use physical UIKit touches to confirm a visible GlassDemo click/drag
   witness through the now-working v2 bridge, then add keyboard and scrolling;
3. add a WindowServer-side window registry with stable window IDs, bounds,
   scale, z-order, and lifecycle events;
4. replace the whole-frame mmap with a producer-owned IOSurface ring plus
   generation/fence metadata, and determine the valid cross-environment port
   transfer direction with runtime evidence;
5. crop or render each registered macOS window into its own `UIWindowScene`,
   including independent resize and multiple simultaneous iPadOS windows;
6. preserve the existing native-AGX blur witness through that per-window path
   and run an interactive stability soak.
