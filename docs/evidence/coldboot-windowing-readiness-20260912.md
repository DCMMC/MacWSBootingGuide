# Cold-boot windowing readiness contract (2026-09-12)

## Scope and runtime-confirmed cause

Device: user's freshly rebooted/re-jailbroken M1 iPad Pro 11-inch,
192.168.1.7:2222, iPadOS 16.3.1. No device reboot, SpringBoard restart,
binary replacement, or production-audit deployment was performed for this fix.

The failed cold start stopped **before** WindowServer/trust restoration:

```text
[macos_gui] Refreshing the stale iPad windowing bridge (SpringBoard pid=2740)...
[macos_gui] ERROR: iPad windowing bridge did not publish a current observer witness within 20 seconds.
schema=macws-gui-start-v1
pid=3580
operation=start
mode=coexist
phase=windowing
started_at=1789221424
updated_at=1789221424
detail=verifying the current SpringBoard request bridge
```

The actual current SpringBoard was PID 3601; its witness was already valid:

```text
version=59 pid=3601 sizing=exact-live-proposal switcher-selection=scene-identity-rebind-at-model-publication presentation=workspace-detaches-appkit-sizing resize-gesture=exact-scene-native-end-notification fallback-step=10 minimum=150 observers=main-queue-after-dyld grid=exact-host-leaf-quantizer-and-programmatic-scope grid-storage=scoped-original-arrays-no-writeback constraints=exact-scene-response-appkit-springback fullscreen=exact-scene-activate-then-maximization-toggle-action-17 resize=whole-current-stage-membership-animation-disabled initial=preactivation-lower-per-item-calculator initial-size-protocol=1 group=stage-limit-without-item-policy diagnostics=per-item-frame-and-stage-limit exit=system-maximization-unzoom postcondition=current-stage-membership-and-model-size-not-visual
```

The installed and repository launchers instead required the retired
`initial=preactivation-generic-app-layout-grid` implementation description.
This is **runtime-confirmed via MacWSStartup.log and dense-grid.loaded**, not
a hypothesis that the tweak failed to inject. Restarting SpringBoard cannot
make the new producer emit the old string.

## Fix

Validate the existing stable `initial-size-protocol=1` token, with token
boundaries (reject `10`, `1extra`, missing or incompatible protocols). Keep
the exact current SpringBoard PID, minimum bridge version and fullscreen
capability requirements. The tweak still publishes readiness only after its
observers have been installed. No unconditional-success/check bypass.

Add read-only `macos_gui.sh windowing-status` using the same predicate as
startup, with no refresh/restart side effects.

Only the launcher was deployed atomically. The previous device launcher is
preserved at:
`/var/jb/usr/macOS/bin/macos_gui.sh.before-coldboot-20260912-2204`.
Deployed SHA-256:
`ff33fac7fb4390174297bca59908d4fdf27c6301e5e92e54e6220da4caed7476`.

## Acceptance

Local executable shell-contract tests: 10 pass. These extract the **current
producer's actual C string** and execute the real launcher predicate in bash;
they cover current producer acceptance, implementation-name independence,
stale/missing PID, missing witness, old version, missing/wrong protocol,
missing fullscreen capability, and read-only command behavior. Full existing
Python test discovery: 87 pass. `bash -n` and `git diff --check` pass.

Read-only device check:

```text
[macos_gui] WINDOWING-READY: current SpringBoard PID, bridge version, fullscreen capability and initial-size protocol verified.
 3601   06:16 /System/Library/CoreServices/SpringBoard.app/SpringBoard
```

Normal Host control `start` request:

```text
[macos_gui] iPad windowing bridge ready for the current SpringBoard generation.
[macos_gui] TIMING gui-start stage=windowing seconds=0 total=0
[macos_gui] PRODUCTION-PREFLIGHT: native AGX required; diagnostics/env traces/dump sentinels OFF.
```

The complete Host control request succeeded on that same freshly rebooted
system, without manually restoring a trust marker or skipping validation:

```text
[macos_gui] Application trust closure ready (bundles=12 Mach-O images=1067).
[macos_gui] Cold-boot trust closure ready (registered=309 existing CodeDirectories).
[macos_gui] TIMING gui-start stage=trust seconds=452 total=469
[macos_gui] TIMING gui-start stage=services seconds=57 total=526
ok=yes launched-pid=0 message=macOS 工作区、触控桥与窗口流已就绪
protocol=11 rootfs=yes windowserver=yes busy=no startup-retry=no startup-log-bytes=0 phase=就绪 error=
1789222371.185 launch-app id=terminal pid=20871 executable=/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
1789222375.727 launch-app window-ready id=terminal pid=20871 path=DisplayStream
 3601     1   16:52 /System/Library/CoreServices/SpringBoard.app/SpringBoard
20382     1   01:50 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
20871   416   01:06 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
20879 20871   01:04 /bin/bash
```

Bringing the existing Host forward with `macwshost://status` allowed its
pending default Terminal bootstrap to complete. A subsequent explicit
`macwshost://terminal` reused PID 20871 instead of creating another process.
Native iPadOS screenshot `tmp/coldboot-terminal-20260912.png` visibly shows
Terminal's title, shell startup text, working desktop and enabled control
center. `tmp/coldboot-terminal-ready-20260912.png` shows the user's WPS window
in front with the live Terminal window behind it. These captures were
inspected; they are deliberately not committed because other user content
is also visible. This was a launch/render acceptance, not an injected keyboard
test or a new full-app regression run.

The unchanged SpringBoard PID 3601 before/after is an independent witness
that the repaired launch path did not respring. No second iPad reboot was
initiated: acceptance used the user's actual failed cold-boot session.

## Remaining startup-performance issue

The first full launch took 526 seconds; 452 seconds were the existing
application trust restoration across 12 bundles/1,067 Mach-O images. That
latency is **not fixed here** and remains a production-readiness issue. The
next optimization must preserve nested-code trust across boot generations;
do not remove the trust walk or forge its successful completion marker.
