# Desktop session invariants and regression matrix — 2026-08-22

This document is the acceptance contract for the macPad desktop session.  A
process staying alive, an `NSWindow` existing, or a launch API returning zero
is not by itself a success witness.

## User-visible regressions in scope

- Desktop Dock and menu-bar materials lose their native backdrop blur.  The
  same Dock looks correct while Launchpad supplies a full-screen blurred
  background.
- Choosing Quit from Dock or the menu bar can leave the running indicator
  below the application icon.  A later Dock click then does nothing, so the
  application cannot be reopened.
- Steam currently exhibits that stale-session state: its main process and
  Stray can be gone while helper processes and the Dock representation remain.
- VS Code can publish a correctly sized window whose entire content is black.
- Steam/Stray can publish a window that later stops advancing on macPad even
  though processes remain alive.
- Failed game/helper sessions can keep substantial CPU load after the owning
  application exits, heating the iPad and invalidating performance results.
- Desktop wallpaper, Dock, menu bar, icons and their materials have repeatedly
  diverged after partial service restarts.

## Runtime evidence captured on 2026-08-22

### Post-Stray recovery regression (14:14–15:38 local time)

- The apparent Stray crash was runtime-confirmed as a safety termination, not
  an unobserved game exception. The persistent native supervisor recorded:

  `trip reason=thermal-fair action=TERM game-pid=24249`

  followed by its bounded `KILL` and Steam-main resume. The device later
  returned to `thermal-state=nominal`; no Steam, helper, overlay or Stray
  process remained.

- The grey Control Center application buttons were not caused by a stuck
  transaction. macwshostd reported `busy=NO`, while a typed status probe
  reported every application as unavailable. The previously deployed daemon
  was RE-confirmed with `codesign -dvvv` as `adhoc,linker-signed` and `ldid -e`
  returned zero entitlement lines. After installing the project-signed daemon,
  its own filesystem witness logged:

  `rootfs-probe ready=YES mask=0xf bash-errno=0 ws-errno=0 gui-errno=0 exec-errno=0`

  and the typed status probe returned `rootfs=yes`, `busy=no`, and `yes` for
  GlassDemo, Terminal, Activity Monitor, Finder, VS Code, System Settings,
  Maps, Amadine, Word, Excel, PowerPoint, Steam, Weather and Sublime Text.

- The broken Dock/menu material was runtime-confirmed as a loss of the
  authoritative base, not a Dock-process failure:

  `final-composite-obsolete producer=12584 sequence=27124 ... mutation=layer-content fallback=window-iosurface-composite`

  displayd's later replay sends succeeded, but WindowServer emitted no matching
  receive records during the loaded game generation. Source inspection showed
  the authenticated replay Mach receive source sharing the same serial queue
  as the bounded AGX command-status observer. The receiver now owns a separate
  control queue.

- A receiver restart exposed a second ordering defect. It accepted an old
  replay, set the global accepted flag, and cancelled the newer topology
  request even though the old record predated that request. The receiver now
  validates `record.completionTime >= ReplayMinimumCompletionTime`. The fresh
  generation produced explicit rejects such as:

  `final-composite-rejected stage=freshness ... fresh=NO`

  followed by a validated newer frame rather than silently cancelling the
  request.

- `repair-desktop` now restarts only displayd first, rebuilds the session-owned
  services, and requires two stable samples from
  `/private/tmp/macws_final_composite.state` for the same WindowServer PID.
  The damaged generation failed that witness and returned typed exit code 2;
  macwshostd then performed one controlled full-session rebuild. The new
  generation reached:

  `state=ready producer=46035 sequence=564 reason=validated-final-composite`

  A second one-click repair was the preserving regression: it returned
  `Dock、图标、桌布、菜单服务与最终合成已验证；当前应用已保留`, kept WindowServer
  PID 46035 unchanged, and advanced the final sequence to 4638. The resulting
  full-resolution macPad screenshot is
  `/tmp/macws-after-repair-regression.png`; Dock and menu materials, wallpaper
  and icon tiles are visibly present. Thermal state remained `nominal`.

- The final post-repair control-service restart did not disturb the desktop:
  WindowServer remained PID 46035 while the final-composite witness advanced
  to sequence 16947 with `state=ready`. A protocol-v7 status request returned
  `rootfs=yes windowserver=yes busy=no phase=就绪 error=` and every declared
  application availability bit was `yes`. The independent native thermal
  probe returned `thermal-state=nominal raw=0`.

- displayd after an independent restart reported:

  `workspace-start id=1 display=1194x834 scale=1.000 transport=window-iosurface-composite`

  Its catalog then transported menu bar, Dock, wallpaper and application
  windows as separate IOSurface layers.  A macPad UI snapshot showed sharp
  wallpaper pixels through the desktop Dock.  A Launchpad snapshot showed the
  same Dock over Launchpad's already blurred full-screen layer.

- The Steam launchd job reported `state = not running`, `active count = 0`,
  and `last exit code = 1`; the Steam and Stray main PIDs were absent.  The
  process list still contained:

  `11489 1 R ... gameoverlayui -pid 11479 -steampid 5656 ...`

  It consumed roughly 44 percent CPU and ignored SIGTERM.  This is a concrete
  orphan-cleanup failure, not evidence that Steam itself was still usable.

- macwshostd recorded the stale reopen transaction:

  `application-reopen pid=5656 sent=YES errno=0`

  followed by:

  `application-reopen pid=5656 result=no-visible-window ...`

- WindowServer and macPad screenshots both showed the current VS Code window
  with a completely black client area.  The owning GPU helper simultaneously
  logged repeated lines of the form:

  `mtl_command_buffer.mm:693 (onCommandBufferCompleted): Completed MTLCommandBuffer failed, and error is Internal Error (00000102:Internal Error)`

  and the same failure with `00000103`.  displayd had already accepted real
  first frames for the correctly sized VS Code layers.  Therefore the black
  window originates upstream in Electron/ANGLE command execution, not in the
  macPad presentation copy.

- During Stray launch, the still-hidden Steam CEF tree retained about 1.3 GB
  RSS: the largest renderer was 655264 KB, while the other Steam helpers were
  258688, 159216, 76976, 69824 and 105744 KB. Stray itself was 686400 KB.
  At that point an independent shell probe returned exactly:

  `zsh:1: cannot allocate memory: ps`

  This is runtime-confirmed resource exhaustion. It explains why a stale
  Steam session can simultaneously heat the iPad, prevent Dock relaunches and
  make new diagnostic/application processes appear unresponsive; it is not a
  claim that every historical black window had this one cause.

- The old shell thermal loop also failed at the same boundary. Its retained
  log contains `date: Cannot allocate memory`, repeated `fork: retry: Resource
  temporarily unavailable`, and `ps: Cannot allocate memory`. The replacement
  native supervisor uses `NSProcessInfo`, `stat(2)`, `proc_listpids`,
  `proc_name`, `kill(2)` and `nanosleep` without child processes.

- Runtime `macwsthermal scan` as root returned
  `pid=60758 name=WindowServer path=<unavailable>`. This confirms that
  `proc_pidpath` alone cannot identify cross-chroot processes from the native
  launchd context. The supervisor now prefers a full exact path and falls back
  to the bounded kernel process name; the fallback is not a guessed path.

## Required architecture

### 1. One session supervisor

`macwshostd` owns a session record for every app launched from either Dock or
Control Center.  A record contains the exact executable identity, launchd job
identity when applicable, main PID, owned helper PIDs, latest visible-window
generation, latest content-ready generation, and lifecycle state.

Dock and Control Center must enter the same idempotent transaction:

1. reconcile the previous record against process and launchd truth;
2. reopen only a live, content-ready instance;
3. retire a windowless, failed, or orphan-only instance;
4. launch exactly one production definition;
5. return success only after the app-specific content-ready witness.

No caller may treat a stale LaunchServices success or a live helper PID as a
successful application launch.

### 2. Transactional quit and convergence

A quit transaction targets the exact main PID, asks the application's normal
AppKit lifecycle to terminate, and observes process death.  When the app owns
a launchd job, that job must reach the not-running state.  Only after a bounded
cooperative grace may the supervisor retire exact orphan helpers.  The Dock
running indicator and the session record must converge to stopped before the
transaction completes.

The compatibility layer must repair the missing macOS-to-iOS lifecycle
notification centrally.  Per-app “remove the dot” patches are forbidden.

### 3. Two rendering readiness levels

- `window-ready`: a current visible/resizable window generation exists.
- `content-ready`: that generation has delivered changing, non-placeholder
  pixels and its renderer has no fatal command-buffer failure.

Ordinary AppKit applications may satisfy both at once.  Electron and games
must use the stronger content-ready witness.  Black, frozen, or stale frames
must fail readiness even while the process and window remain alive.

### 4. Authoritative desktop composite

Native SkyLight materials, shadows and backdrop effects are accepted only from
WindowServer's completed final composite.  Exact-window IOSurfaces remain a
recovery path and mutation witness, not an equivalent visual result.

WindowServer and displayd are independently restartable.  On receiver restart,
displayd must request a fresh snapshot of WindowServer's latest completed
scanout through an authenticated, bounded replay handshake.  It must not wait
for accidental future damage, and a static desktop must not expire merely
because it is static.

### 5. Thermal validity

The supervisor continuously reconciles orphan helpers whose declared owner
PID no longer exists.  Cleanup is scoped to a known session and executable;
there is no class-wide `killall` policy.  Performance results are valid only
when the device thermal state is normal and no unrelated process is consuming
sustained CPU.

## Automated regression matrix

Each row must be exercised through both Control Center and Dock when the route
exists.

| Case | Required witnesses |
|---|---|
| Static desktop | final-composite transport; wallpaper present; native Dock and menu-bar backdrop pixels |
| Launchpad toggle | Dock material remains correct before, during and after toggle |
| App launch | one main PID; current window generation; content-ready frame |
| App quit | main PID gone; production job stopped; owned helpers gone; Dock indicator gone |
| App relaunch | new or valid reused PID; click produces a visible content-ready window |
| VS Code | non-black content entropy; no continuing ANGLE command-buffer failure |
| Steam | Dock and Control Center enter the same production launch transaction |
| Stray intro | macPad frame sequence advances throughout the 3–4 minute intro |
| Stray gameplay | first mouse movement does not stop frame advancement; FPS and thermal samples remain valid |
| Service restart | displayd reacquires final composite without restarting applications |

## Patch discipline

No assertion bypass, forced success return, synthetic zero buffer, fixed-color
window, or validation suppression satisfies this contract.  Diagnostics must
remain explicitly labeled and outside production frame paths.
