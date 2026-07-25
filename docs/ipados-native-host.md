# Native iPadOS host (M0)

`MacWSHost` is the first milestone toward presenting each chroot macOS window
as an iPadOS `UIWindowScene` instead of viewing the whole desktop through VNC.
It is an iOS application built by the root Theos aggregate.

## What M0 implements

- The application scene manifest sets `UIApplicationSupportsMultipleScenes`.
  The **New Window** button asks UIKit for another independent scene session.
- Every scene reads the existing WindowServer capture at
  `/var/mnt/rootfs/private/tmp/macws_vnc_fb` directly. No `OSXvnc-server`, RFB
  encoding, network socket, or VNC client is involved.
- When `MTLCreateSystemDefaultDevice()` succeeds, an iOS-native Metal render
  pipeline uploads the BGRA frame and presents an aspect-fitted quad.
- If the iOS process cannot enumerate a Metal device, an explicitly labelled
  UIKit/CoreAnimation fallback displays a stable snapshot. This is a recovery
  path, not evidence of an App-local Metal present.
- Touch and pointer coordinates are transformed from the aspect-fitted scene
  into physical macOS framebuffer pixels. M0 logs version-1 input records; it
  does not yet claim that these records reach macOS `CGEvent`/HID.
- Runtime evidence is appended to
  `/var/mobile/Library/Logs/MacWSHost.log`. A successful Metal presentation is
  only claimed after the corresponding iOS `MTLCommandBuffer` completion says
  `status=4 error=nil`.

The shared C layouts live in `include/macws_host_protocol.h`.

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
  running.

M0 is not the final per-application design. It still mirrors a full macOS
display into every iPadOS scene. The next milestones are:

1. deliver versioned input records to a narrow macOS event bridge and confirm
   real click/drag/key witnesses;
2. add a WindowServer-side window registry with stable window IDs, bounds,
   scale, z-order, and lifecycle events;
3. replace the whole-frame mmap with a producer-owned IOSurface ring plus
   generation/fence metadata, and determine the valid cross-environment port
   transfer direction with runtime evidence;
4. crop or render each registered macOS window into its own `UIWindowScene`,
   including independent resize and multiple simultaneous iPadOS windows;
5. preserve the existing native-AGX blur witness through that per-window path
   and run an interactive stability soak.
