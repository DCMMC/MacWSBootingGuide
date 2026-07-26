# Native iPadOS host (M0–M4)

`MacWSHost` is the first milestone toward presenting each chroot macOS window
as an iPadOS `UIWindowScene` instead of viewing the whole desktop through VNC.
It is an iOS application built by the root Theos aggregate.

## What M4 adds: target-process input and visible non-demo apps

M4 fixes two separate failures that previously made the native host look
ready while it was not usable:

- `macwsinputd` now routes input ABI v3 records to a PID-specific Unix socket
  owned by the selected AppKit process. `libmachook` converts the physical
  top-left framebuffer point to the AppKit bottom-left screen/window point and
  posts an `NSEvent` on that process's main CFRunLoop common modes. The run-loop
  choice is load-bearing because GlassDemo starts inside a nested menu-tracking
  loop that did not drain a libdispatch main-queue block.
- Directly executing Terminal does not create an untitled window. RE of the
  actual macOS 13.4 Terminal image found that
  `-[TTApplication applicationShouldOpenUntitledFile:]` returns `NO` and that
  the real New Shell action is `-[TTApplication newShell:]`. The injected hook
  now invokes that method after launch; runtime reports three windows and the
  shared frame contains a visible Terminal shell.

Touch is enabled only when the control service, WindowServer, global receiver,
an exact acknowledged frame, active application PID, and that PID's AppKit
socket are all present. A stale snapshot is therefore never presented as a
live interactive target.

The visible control witness is a GlassDemo checkbox: after the startup menu is
dismissed, one down/up pair changes exactly 760 pixels in bounding box
`(638,702)..(665,729)` of the 2388x1668 shared frame. This supersedes the M2
cursor-state observation, which did not prove AppKit event delivery.

Continuous move/hover diagnostics are rate-limited at each of the UIKit,
receiver, and AppKit layers. Down/up/cancel are always retained. This removes
the previous roughly 120-lines/s logging amplification during a drag.

## What M3 adds: an App-owned control plane

Version 0.3 makes the iPadOS app the normal entry point for the whole GUI
stack. The data/control path is now:

```text
MacWSHost (UIKit + iOS Metal)
    | typed XPC; fixed operations only
    v
macwshostd (root iOS LaunchDaemon, RunAtLoad)
    | macos_gui.sh / launchctl / launchdchrootexec
    v
WindowServer + macwsinputd + allowlisted macOS apps
    | completed BGRA frame + versioned input datagrams
    v
MacWSHost scene
```

The app shows the root service, rootfs, WindowServer PID, touch bridge, and
frame dimensions in a native glass control panel. From there the user can:

- initialize/start or stop the workspace;
- launch GlassDemo, Terminal, Activity Monitor, or Finder;
- refresh the completed GPU frame and interact with it using touch;
- run the full signing/trustcache repair, perform bounded safe recovery, view
  the three relevant logs, and export a diagnostic bundle;
- collapse the panel so the macOS canvas remains unobstructed.

The XPC service does not accept a command line, executable path, or shell
text. Its protocol in `include/macws_control_protocol.h` exposes only status,
start, stop, repair, recover, capture, logs, and an application identifier
checked against a compiled allowlist.

The package maintainer script now converts both libmachook slices from the iOS
build tag to macOS 13, splits the fat artifact into thin arm64e and arm64
injection libraries, signs each twice for the target ldid page-hash behavior,
and registers the resulting hashes. App-driven repair repeats those steps only
when needed and does not re-sign an already-correct thin library. This removes
the old mandatory SSH post-install sequence.

### First use after a restart

After the jailbreak/bootstrap is active, open **MacWS Host** and tap **Start
macOS workspace**. `macwshostd` is already loaded by launchd. Start probes a
real chroot command; if a full reboot cleared the volatile trustcache, it runs
the repair before launching WindowServer. A full repair scans the current
MacPorts tree and took about 145 seconds for 116 files on the test rootfs, so
the app deliberately remains in a visible busy state.

A userspace reboot was runtime-tested: initially only
`com.macwsguide.hostd` was present, then a cold `macwshost://start-experimental`
launch brought up WindowServer and the input bridge in about three seconds.
The watchdog ignores stale one-minute load for its first 90 seconds while
still enforcing its WindowServer restart-count limit.

A physical hardware reboot still requires Dopamine to reactivate the rootless
bootstrap before any `/var/jb` app or LaunchDaemon can run. That pre-bootstrap
step cannot be performed by this installed app. Once the bootstrap is active,
no SSH command is required for MacWS initialization, repair, launch, capture,
or recovery. A complete hardware reboot was not executed in the M3 validation
because it would require that external reactivation step.

The **Experimental compatibility mode** switch is intentionally explicit. It
enables the recorded `macws_kcmd_fix` and cancelled-swap completion diagnostic
scaffolds needed by the current native capture path; the UI states that these
are not root-cause fixes. The App always owns `macws_vnc_share` while running
because that mmap is its current frame transport, independent of the switch.
The CLI's explicit `--experimental` path groups all three flags for VNC tests.
The diagnostic run is capped at five minutes while the unchanged high-CPU and
restart-storm guards remain active.

M3 still mirrors one full macOS display inside one iPadOS scene. It does not
yet claim independent native iPad windows for each macOS `CGSWindow`; that
requires the window registry and per-window IOSurface transport milestones
listed below.

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
  into physical macOS framebuffer pixels. M4 sends version-3 records with the
  active target PID to `macwsinputd`, which prefers the matching target-process
  AppKit socket and uses CGEvent posting only as a fallback. A real checkbox
  state/pixel change now confirms click delivery.
- Runtime evidence is appended to
  `/var/mobile/Library/Logs/MacWSHost.log`. A successful Metal presentation is
  only claimed after the corresponding iOS `MTLCommandBuffer` completion says
  `status=4 error=nil`.

The shared C layouts live in `include/macws_host_protocol.h`.

## Current input ABI

MacWSHost sends packed 52-byte records to
`/var/mnt/rootfs/private/tmp/macws_host_input.sock`; inside the chroot,
`macwsinputd` binds the same vnode as `/private/tmp/macws_host_input.sock`.
Each record contains:

```text
uint32 magic = 0x4d574556  // "MWEV"
uint16 version = 3
uint16 kind                 // down/move/up/cancel/hover
uint64 sceneID
double timestamp
float  x, y, pressure
uint32 contactID
uint32 frameWidth, frameHeight
int32  targetPID
```

The source dimensions are load-bearing. The current producer is 2388x1668,
while the coexistence Quartz display is 1194x834; v1 lacked these fields and
incorrectly mapped the producer center to the display corner. No fixed Retina
scale is assumed.

`macwsinputd` rejects malformed versions, sizes, kinds, non-finite values,
out-of-bounds coordinates, and invalid target PIDs. For supported applications,
it forwards the unchanged validated record to
`/private/tmp/macws_app_input.<targetPID>.sock`. The target process maps touch
down/move/up/cancel to AppKit left-down/drag/up and hover to mouse-moved. If the
target endpoint is absent, the receiver retains a per-PID/global CGEvent
fallback, but runtime `CGPreflightPostEventAccess=NO` means that fallback is
not considered an interactive-control witness.

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

For a native-AGX package, the canonical build is on-device because that path
also produces the required chained fixups and thin injection libraries:

```bash
THEOS=/var/jb/var/mobile/theos bash misc/build_on_ios.sh
```

After package installation, normal use is entirely in the Home Screen app.
These URLs remain useful for automation and diagnostics:

```bash
uiopen macwshost://
uiopen macwshost://start-experimental
uiopen macwshost://glassdemo
uiopen macwshost://terminal
uiopen macwshost://activity-monitor
uiopen macwshost://finder
uiopen macwshost://capture
uiopen macwshost://repair
uiopen macwshost://recover
uiopen macwshost://stop
# Diagnostic: ask the running app to create another scene session.
uiopen macwshost://new
# Diagnostic: send one synthetic hover through the real M4 transport.
uiopen 'macwshost://test-input?x=1194&y=834&w=2388&h=1668'
# Diagnostic: send a complete down/up pair to the active application.
uiopen 'macwshost://test-input?kind=tap&x=640&y=703&w=2388&h=1668'
```

To exercise the current capture path without VNC, use the same explicit
experimental mode as the App. The script owns creation and cleanup of all
three sentinels, including cleanup after a watchdog stop:

```bash
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist \
  --experimental --no-terminal --no-vnc
```

The App's experimental capture button manages these sentinels automatically.
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
  Quartz locations were read back from the posting process's cursor state;
  later M4 A/B testing proved that this did **not** deliver a click to the
  GlassDemo control;
- runtime M4 records were received by the exact GlassDemo PID, executed on its
  main thread, posted to AppKit window 4, and changed the checkbox pixels;
- project LLDB showed the first GlassDemo tap is consumed by the demo's own
  startup context-menu nested event loop. The App reports this behavior rather
  than injecting a hidden bypass click;
- RE-confirmed Terminal's real startup action and runtime-confirmed a visible
  Terminal window in an acknowledged shared frame without restarting
  WindowServer.

M0 is not the final per-application design. It still mirrors a full macOS
display into every iPadOS scene. The next milestones are:

1. inspect the failed SpringBoard scene request's real persistence identifier
   and mapping with a stable early-attach/runtime probe; do not force its
   success branch;
2. add keyboard, modifiers, right-click/long-press, scroll, and Pencil
   semantics to the target-process bridge;
3. make Activity Monitor and Finder startup-window behavior evidence-backed in
   the same way as Terminal, without guessed selectors;
4. add a WindowServer-side window registry with stable window IDs, bounds,
   scale, z-order, and lifecycle events;
5. replace the whole-frame mmap with a producer-owned IOSurface ring plus
   generation/fence metadata, and determine the valid cross-environment port
   transfer direction with runtime evidence;
6. crop or render each registered macOS window into its own `UIWindowScene`,
   including independent resize and multiple simultaneous iPadOS windows;
7. preserve the existing native-AGX blur witness through that per-window path
   and run an interactive stability soak.
