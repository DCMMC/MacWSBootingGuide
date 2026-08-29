# Stray Steam performance work — 2026-08-21

## 2026-08-24 generic translation and 1400x900 update

This section supersedes performance-policy conclusions below. Historical A/B
results remain useful evidence, but they used different output/internal
resolutions, thermal histories, or runtime implementations.

The current production profile is 1400x900/pixel-format 80, fullscreen mode
0, High (`sg.*=2`), built-in 35% internal rendering, `t.MaxFPS=54`, hardware
occlusion queries enabled, and Steam's real top-left FPS overlay. The current
thermally valid gameplay result
`/tmp/macws-stray-v23-performance-nominal-20260824/result.json` recorded a
50.312-FPS median (50.224 mean, 49.737 minimum, 50.492 maximum) while all eight
measurement samples and the final sample reported iPadOS `nominal`. Its
1400x900/pf80 drawable, unchanged profile, real overlay PID binding and
top-left FPS HUD are preserved in the JSON and final screenshot. A 50-FPS cap
was slower, a 60-Hz completion diagnostic was slower and reached `fair`, and
suspending the Steam owner crashed the game; none was promoted.

Metal library compatibility is no longer an instruction-by-instruction
patch. The host service now performs a bounded MTLB container parse, exact
producer-target validation, generic target retargeting, complete output
validation and content-addressed caching for Stray's
`newLibraryWithData:` inputs. A capture audit covered all 430/430 valid
libraries. A previously unseen library converted in about 740 ms and the
cached result loaded in about 1.433 ms; real AGX pipeline creation then
succeeded. The converter neither forces a validation result nor substitutes a
fake library. Command-buffer object lifetime, ordering and hazard semantics
remain a separate compatibility layer; blindly rewriting unknown command
opcodes is not treated as a generic solution.

The exact gameoverlayrenderer event-wait experiment was rejected. Runtime log
`/tmp/macws-steam-runtime-current.log` recorded 80,000 semaphore operations in
86.558 seconds (924.234 calls/s), including 6,696 timed waits consuming
27.796 seconds. The thermally nominal result fell to 18.784 FPS and the RHI
thread remained blocked in the brokered `kevent` path. Production therefore
retains Valve's token and timeout semantics without this exact-callsite mode.

A separate preserving observer measured the unchanged production semaphore
path; it did not replace a wait, token, return value, or timeout.  In the
thermally nominal 1400x900/High/35% run
`/tmp/macws-stray-1400x900-steam-sem-production-timing2-20260824/result.json`,
Stray PID 55587 reported this exact runtime line:

```text
[MacWSSteamSemTiming] pid=55587 program=Stray-Mac-Shipping calls=48800 wall_ms=72110.182 calls_per_s=676.742 rpc_ms=4493.955 avg_us=92.089 failures=18097 eagain=18097 trywait=33447/3228.525ms post=15353/1265.430ms getvalue=0/0.000ms wait=0/0.000ms timed=0/0.000ms
```

This runtime-confirms about 4.494 seconds of accumulated broker round-trip
time over 72.110 seconds, or 6.23% of one wall-time core equivalent.  The run
averaged 47.636 FPS and remained `nominal`.  This is enough overhead to justify
designing and self-testing a shared authoritative fast path, but it does not
show that semaphore transport accounts for the full frame-time gap.  The
observer is diagnostic-only and is not enabled for manual Steam launches.

Protocol v23 implements that generic fast path without changing Valve's token
semantics. macwshostd retains the exact state-vnode descriptor for each POSIX
name generation. Uncontended `sem_trywait`, `sem_post` and `sem_getvalue`
perform one nonblocking `flock` plus fixed-size `pread`/`pwrite`; only a real
zero-value blocking waiter enters the existing AF_UNIX FIFO, and a post that
observes the authoritative waiter count delegates to hostd for ordered wake.
The legacy XPC diagnostics use the same locked state transaction, so there is
no second in-memory counter authority. The on-device host/protocol regression
returned this exact line:

```text
steam-sem-timed-wait protocol=23 generation=15207543551040131634 immediate-error=0 immediate-ms=0.246 timeout-error=35 timeout-ms=10.595 valid=yes
```

Runtime-confirmed via
`/tmp/macws-stray-v23-performance-nominal-20260824/result.json`: the production
path (no event-wait diagnostic) reached the 50.224-FPS mean above with no
thermal pressure or profile drift. Runtime-confirmed via
`/tmp/macws-stray-v23b-input-production-20260824/result.json`: the same build
survived a 961-sample 120-Hz hover, a 420-ms hold plus 120-sample drag, and a
five-second `W` movement. After each input, the exact PID remained live, frame
hashes changed, the present sequence advanced (3000→3600, 3720→4320 and
4680→5520), and the final fatal check was empty. That stress run averaged
49.205 FPS but entered `fair`/`serious`, so it is functional evidence rather
than a no-throttling performance result.

The Steam-owner quiesce A/B remains rejected. In
`/tmp/macws-stray-v23-quiesce-production-20260824/result.json`, presentation
stopped after sequence 840 and the unchanged game emitted:

```text
src/common/pipes.cpp (900) : fatal stalled cross-thread pipe.
src/common/pipes.cpp (900) : Fatal assert; application exiting
```

Therefore the production owner and overlay remain runnable. This failure was
not thermal-controlled: iPadOS was `nominal` while the present counter was
stalled, and the runner never sent a thermal-triggered signal.

The one-shot launcher retry is now generation-safe. Runtime-confirmed via
`steam-runtime.log` during the first v23 attempt: Steam PID 72328 contained
`-applaunch 1332010`, its UI-timeout retry PID 72981 did not, and the runner
then timed out waiting for a launch never requested from PID 72981. The retry
path now republishes the same validated AppID marker before every replacement
job load. The next retry run launched Stray PID 82264 through Steam's complete
`LaunchApp → CreatingProcess → Completed` transaction.

The intermittent visual artifact is still open. The stress artifact
`gameplay-host-hover-before.png` contains a small black scene rectangle which
is absent from `gameplay-host-long-drag-after.png`; the thermally valid final
frame has normal scene contrast and no such rectangle. This proves the block
is transient, not fixed. Generic MTLB retargeting solves shader target
compatibility, but resource lifetime, hazard/order and final-composite
synchronization remain separate investigation layers; no unknown command is
rewritten or check forced to suppress this symptom.

Hardware occlusion-query off/on was also rejected as a production change.
Off removed `FMetalRHIRenderQuery::GetResult` from the sample, but
`/tmp/macws-stray-1400x900-54-occlusion-off-20260824/result.json` fell to a
42.051-FPS median as `FRHICommandListBase::WaitForDispatch` increased. The
same-scene on control reached a 46.573-FPS median before later samples became
thermally invalid. Production remains `r.AllowOcclusionQueries=1`.

Stray's exact arm64 binary contains the early `-rhithread`/`-norhithread`
switch (`HandleRHIThreadEnableChanged` at `0x101a93184`). A first diagnostic
incorrectly wrote `r.RHIThread.Enable` to `Engine.ini`; Stray PID 43046
runtime-confirmed the error and aborted with:

```text
Console object named 'r.RHIThread.Enable' can't be replaced with the new one of different type!
```

The invalid key was atomically removed. The runner now passes the
RE-confirmed early argument only to the exact signed Stray runtime and removes
the launcher selector from the child environment. The RHI-off run
`/tmp/macws-stray-1400x900-54-rhithread-off-applaunch-20260824/result.json`
survived both real pointer movement and a five-second W input: present sequence
advanced after each, both before/after frame hashes changed, the process
remained live, and no UE fatal appeared. It is not a performance result because
iPadOS was `serious`; its 5-second sample placed 2,532/3,147 RenderThread
samples directly in `FMetalViewport::Present` and its FPS median was 29.452.

The RHI-on control
`/tmp/macws-stray-1400x900-54-rhithread-on-applaunch-control-20260824/result.json`
restored a real `RHIThread`. Its first nominal sample windows were 47.862 and
49.463 FPS, then iPadOS changed to `fair` and the next windows fell to 44.669
and 43.624 FPS. The whole run is therefore thermally invalid, but the actual
thread samples reject RHI-off as an optimization: RHI-on kept Present on the
RHI thread while the RenderThread waited in `WaitForDispatch`; RHI-off
serialized Present onto the RenderThread. Normal manual Steam launches remain
on the game's default behavior and receive no diagnostic RHI argument.

The test pipeline now has `--steam-applaunch`. It pre-arms logs, process
sampling, the Present witness and GUI transaction before starting a fresh
launchd-owned Steam process with its existing one-shot `-applaunch 1332010`
contract. Steam still performs LaunchApp, cloud, overlay and NSWorkspace game
ownership; only CEF Library navigation is omitted. This avoids the
runtime-confirmed false-ready case where login, WebSocket and AppStore logs
completed but the visible 1010x600 window remained on Steam's spinner. The
one-shot marker and all diagnostic environment variables are cleared on every
exit path. Thermal telemetry remains observation-only and never signals or
terminates Stray.

## 2026-08-23 gameplay-movement update

This section supersedes the production-policy conclusions below while retaining
the older A/Bs as historical evidence.  Production now leaves
`CAMetalLayer.displaySyncEnabled` unchanged (`MACWS_STRAY_DISABLE_DISPLAY_SYNC=0`).
The earlier sync-off result was not isolated from run order and thermal history.
With display sync enabled, a later 1400x900 fullscreen, High (`sg.*=2` except
the explicitly measured 40% internal resolution), `t.MaxFPS=50` run sustained
49.987 FPS for 45 seconds (49.774–50.152).  Its first- and second-half medians
were 49.995 and 49.992 FPS.  Every runtime thermal sample was `nominal`, from
30.79 C before launch to 31.50 C after cleanup; these numeric values are
telemetry, not admission or process-control thresholds.

The user's WASD failure was runtime-confirmed in Stray PID 64135.  The game
continued presenting 1400x900 at about 50 FPS through sequence 5520, then the
real AGX driver rejected one lazily created render pipeline:

```text
#### STRAY-PIPELINE-FAILURE-CAPTURE kind=render-options retained=2 written=2 errorDomain=AGXMetal13_3 errorCode=3 description=Target OS is incompatible.
#### RENDER-PIPELINE #308 ... vertex=Main_00004a1e_09f441ce fragment=Main_00003013_0fb264c4 colors=92,0,0,0 depth=260 stencil=260 samples=1 result=0x0 ...
Shader compilation failures are Fatal.
```

The byte-exact inputs were 15137/FNV `02642fe2b4ff75e4` (vertex) and
12316/FNV `436ed5cbd71a0a06` (fragment).  Each Ventura AIR module was rebuilt
for `air64-apple-ios19.0.0-macabi`; a standalone replay on the iPad's real
`AGXG13GFamilyDevice` used the exact logged functions, color/depth/stencil
formats, sample count, vertex attribute `0:29:0:30`, and layout `30:8:1:1`.
The unchanged descriptor returned a real `AGXG13GFamilyRenderPipeline` with no
NSError.  The two outputs are installed through the root-owned, byte-exact
dynamic mapping contract; no validation result, branch, or UE fatal path is
bypassed.

The post-install regression used Stray PID 66148.  It reached a visually
verified gameplay frame, held real `W` input for 8 seconds, then observed for
30 seconds: present sequence advanced from 3120 to 4920, the before/after
screen hashes differed, the process remained live, and no fatal appeared.  It
continued through the 45-second sample to sequence 8160.  The runner's new
pre-cleanup log check also returned `fatal_error=null`, closing the automation
blind window that had allowed PID 64135's late fatal to be reported as `OK`.
The retained result is
`/tmp/macws-stray-wasd-exactfix-20260823/result.json`; the standalone replay
and captured failure evidence are under `/tmp/macws-wasd-freeze-20260823/` on
the development Mac.  A device audit reported four retained captures, all
four covered, no invalid/missing capture, and 388 installed dynamic exact
identities.

A same-scene 54-FPS-cap A/B then tested whether the 50-FPS plateau came from
the CAMetalLayer switch.  Sync-on PID 67489 averaged 50.001 FPS
(49.953–50.036) and remained `nominal`.  Sync-off PID 68433 emitted the exact
`before=YES requested=NO after=NO` witness but averaged only 49.926 FPS; its
last four sample states were `fair`.  The switch therefore provided no
measured gain in this controlled pair and was not promoted.  The current
production setting remains sync-on; the source-of-50-FPS plateau is still a
THEORY, not attributed to CAMetalLayer by this evidence.

## Scope and result

The runner now reaches and visually proves the first real gameplay level; menu
and retained loading-black frames are no longer accepted as gameplay.  The
thermally valid baseline at native 1194x834 output, High (`sg.*=2`), fullscreen
mode 0, and effective 85% internal resolution averaged 53.6765 FPS
(51.386–55.208).  Steam's real game overlay was attached to the exact Stray PID
and its green counter was visible at the top left.  iPadOS remained `nominal`
at 33.59–34.00 C.

A narrow preserving A/B which changed the real `CAMetalLayer` property from
`displaySyncEnabled=YES` to `NO` improved the matching actual-scene sample to
56.269 FPS (54.643–57.058) while iPadOS remained `nominal` at 34.09–34.39 C.
This 4.8% gain was promoted to the Stray-only production environment after the
A/B.  The implementation sets Apple's public property immediately before the
unchanged `nextDrawable`; it does not skip a wait, force a return, or patch a
branch.  It is still not a claim of locked 60 FPS.  The deployed production
runtime witness was:

```text
STRAY-DISPLAY-SYNC policy=production-env layer=CAMetalLayer before=YES requested=NO after=NO
```

The final matching production run reached actual gameplay at 56.39575 FPS
(51.311–59.130), with no diagnostic markers and the production witness above.
All ten bounded thermal samples were `nominal`; the sampling temperature was
32.79 C and post-cleanup temperature was 33.09 C.  Its Performance-core active
cycle-rate proxy changed by only -2.76%, while FPS improved by 5.76% between
sample halves, so no thermal throttling was observed in the bounded interval.
The exact artifact is
`/private/tmp/macws-stray-final-production-high85-nominal-20260821/result.json`.
Its exact-window screenshot, `stray-window.png` in the same directory, shows
the bright vine/pipe gameplay scene and Steam's green `53 FPS` counter at the
upper left.

An earlier matching production run reached actual gameplay at 54.90075 FPS,
but remains excluded because iPadOS changed to `fair` at 35.79 C during
post-cleanup.  The runner correctly returned `THERMAL_ABORT` rather than
accepting its nominal sampling window.

A thermally valid native-internal-resolution run (`sg.ResolutionQuality=100`)
averaged 49.631 FPS (47.825–51.084) at native 1194x834 output and High, ending
`nominal` at 34.50 C.  Therefore the practical near-60 profile keeps the native
output mode and uses 85% internal rendering; 100% internal resolution is not
close to 60 FPS on the measured scene.

Actual-gameplay evidence artifacts:
`/private/tmp/macws-stray-gameplay-occlusion-off-sp85-20260821-1/result.json`
and
`/private/tmp/macws-stray-gameplay-displaysync-off-occlusion-off-sp85-20260821-1/result.json`.
Their exact witnesses include:

```text
texture=1194x834/pf80
ScreenPercentage=85
sg.ResolutionQuality=85.000000
FullscreenMode=0
sg.EffectsQuality=2
sg.TextureQuality=2
sg.ShadowQuality=2
sg.PostProcessQuality=2
mean_window_fps=53.676500000000004
mean_window_fps=56.269  # display-sync diagnostic A/B
thermal-state=nominal ... effective-temp-centic=3400
thermal-state=nominal ... effective-temp-centic=3439
GameOverlay: started '.../gameoverlayui' (...) for game process ...
```

The diagnostic run's exact-window screenshot is
`/private/tmp/macws-stray-gameplay-displaysync-off-occlusion-off-sp85-20260821-1/stray-window.png`.
It contains the bright vine/pipe opening scene and visibly shows `54 FPS` in
green at the upper left.  Host-side sampled image statistics were 67.745%
non-black pixels and brightness variance 10230.86; the retained loading-black
captures measured about 0.1% non-black and variance 15.76.

## Per-frame synchronous readback

Runtime-confirmed by the preserving, exact-Stray hooks in
`libmachook/Metal_hooks.x`.  The unchanged game performed one histogram eye
adaptation staging readback and explicit Metal wait per frame.  A representative
verbatim block from
`/tmp/macws-stray-preexposure-off-trace-20260821-1/result.json` is:

```text
STRAY-SURFACE-LOCK sequence=1 surface=0x16238e560 mip=0 slice=0 mode=0 singleLayer=NO caller=0x105c26c34 frames=16 begin
Stray-Mac-Shipping ... FMetalDynamicRHI::RHIMapStagingSurface(...) + 188
Stray-Mac-Shipping ... FRHIGPUTextureReadback::Lock(unsigned int) + 68
Stray-Mac-Shipping ... FSceneViewState::FEyeAdaptationManager::SwapTextures(...) + 564
Stray-Mac-Shipping ... AddHistogramEyeAdaptationPass(...) + 56
STRAY-SUBMIT-FLAGS sequence=9 flags=0x7 explicitWait=YES runtimeDebugLevel=0 caller=0x106454114
STRAY-WAIT sequence=1 ... begin
Stray-Mac-Shipping ... FMetalCommandList::Commit(...) + 1444
Stray-Mac-Shipping ... FMetalCommandEncoder::CommitCommandBuffer(unsigned int) + 504
Stray-Mac-Shipping ... FMetalRenderPass::Submit(EMetalSubmitFlags) + 416
STRAY-WAIT sequence=1 end
STRAY-SURFACE-LOCK sequence=1 result=0x135640000 stride=16 elapsedMS=63.511 end
```

This was not Metal validation or the Steam overlay: the runtime debug level was
zero and a bounded no-overlay A/B retained the same wait family.  Setting
`r.EyeAdaptationQuality=0`, `r.EyeAdaptation.MethodOverride=1`, and
`r.UsePreExposure=1` removed all 16/16 captured `FMetalSurface::Lock` blocks,
all wait traces, and the `flags=0x7` submits in the matching run.  It also
restored the intended menu brightness.  `MethodOverride=2` is not usable: the
actual game emitted `Shader compilation failures are Fatal.` after its first
frame.

## Actual-gameplay gate and launcher recovery

`--progress-to-gameplay` now captures the exact Stray window after every
input, classifies visible prompts with Vision OCR, and treats blank post-save
frames as loading rather than sending more blind Return keys.  A run is `OK`
only after two consecutive non-menu frames each have at least 5% non-black
pixels and brightness variance at least 100.  The regression artifact
`/private/tmp/macws-stray-gameplay-sp85-20260821-2/result.json` waited through
two actual black loading captures, then required the two bright opening-scene
captures.  It averaged 53.91275 FPS and finished `nominal` at 34.39 C.

The launcher path is also state-based.  It distinguishes Steam's real `PLAY`
token from `PLAY TIME`, reconciles a stale `Stray - Running` / `STOP` state
through Steam's own Confirm dialog, and handles the runtime-observed cloud
failure.  In the latter case Vision located `Play anyway` in the exact Steam
window and the runtime log confirmed:

```text
GameAction ... waiting for user response to SynchronizingCloud "syncfailed"
LaunchApp continues with user response "IgnoreCloud"
```

Warm reuse activates the retained Steam window without a synthetic click, so
activation cannot accidentally navigate away from the selected library item.
After launch the runner hides the Steam Library. The independent native
supervisor then gives the SteamAPI/overlay handshake a bounded startup grace,
SIGSTOPs the exact `steam_osx` session owner and retires only exact Steam
Helper executables. It resumes `steam_osx` when the game exits. This returns
CEF memory while preserving Steam Play and its overlay.

## Render-query and drawable waits after eye-adaptation fix

A preserving one-second macOS `sample` of the actual game is stored at
`/private/tmp/macws-stray-gameplay-sample-sp85-20260821-1/stray-process.sample.txt`.
Of 575 render-thread samples, 327 were in the unchanged path:

```text
FDeferredShadingSceneRenderer::Render
FDeferredShadingSceneRenderer::InitViews
FSceneRenderer::ComputeViewVisibility
FMetalDynamicRHI::RHIGetRenderQueryResult
FMetalRHIRenderQuery::GetResult
FMetalCommandBufferFence::Wait
```

Setting the real UE cvar `r.AllowOcclusionQueries=0` removed
`RHIGetRenderQueryResult` and `FMetalCommandBufferFence::Wait` from the matching
sample; no function was stubbed and no check was forced.  It did not improve
the matching FPS result by itself (53.6765 versus 53.91275 FPS), so it is not
claimed as a performance fix.  The new dominant render-thread stack in
`/private/tmp/macws-stray-gameplay-sample-occlusion-off-20260821-1/stray-process.sample.txt`
was 227/589 samples in:

```text
FMetalSurface::GetDrawableTexture
FMetalViewport::GetDrawable
-[CAMetalLayer nextDrawable]
dispatch_semaphore_wait
semaphore_timedwait_trap
```

This runtime evidence motivated the narrow `displaySyncEnabled` A/B reported
above.  The first thermally valid result gained about 4.8%, and the exact
Stray-only public-property policy is now shipped.  A later timing-only run was
discarded for FPS because iPadOS entered `fair`, but its preserving counters
still showed that after the gameplay sampling floor (calls 2400→2580), the
startup-history-subtracted `nextDrawable` average was 3.614 ms: 37/180 calls
exceeded 8 ms and 2/180 exceeded 16 ms.  The runner now calculates this window
automatically instead of reporting the misleading cumulative startup average.

## Launchd application class

RE-confirmed via the actual iPadOS 16.3 `/sbin/launchd` disassembly in
`launchd-performance-class-20260730/launchd-performance-class-disassembly.txt`:

```text
10000fc68 ... literal pool for: "Efficient"
10000fc80 str x8, [x21, #0x3a8]
10000f360 ... literal pool for: "UIKitApplication:"
10000f368 bl 0x100015a4c
10000f36c tbnz w0, #0x0, 0x10000f390
```

The old Steam job label was `com.macwsguide.steam`.  In a native-100% run its
Stray intervals had only about 12–22 million Performance-core cycles while
Efficiency-core cycles were 3.75–5.69 billion; the stable FPS mean was 48.687.
After changing the installed label to
`UIKitApplication:com.macwsguide.steam`, the next 2.347-second interval recorded
1,461,029,719 Performance-core cycles and 1,209,331,412 Efficiency-core cycles,
with 55.706 FPS.  The test stopped at the exact 36.00 C safeguard, so this is a
one-interval scheduler A/B rather than a long thermal result.

The production label is now shared by the runtime plist, GUI lifecycle cleanup,
host daemon, and benchmark verifier.  The full package built and installed
successfully on the device on 2026-08-21.  Post-install inspection returned:

```text
UIKitApplication:com.macwsguide.steam
Interactive
```

## Thermal and automation policy

`misc/stray_perf_loop.py` owns each bounded run. It verifies the live
fullscreen Host surface, exact Steam application-class job, High/fullscreen
profile, overlay PID binding, advancing presents, fatal markers, iPadOS thermal
state, P/E active-cycle counters, GUI background CPU, and per-run
`MTLCompilerService` cleanup. Per the current acceptance requirement, numeric
battery temperature and charging state are observation-only.  New bounded
performance runs wait for `thermal-state=nominal` before launch so samples are
comparable.  During a run, `fair`, `serious`, and `critical` are recorded and
invalidate a no-throttling performance claim, but never terminate Stray.

The runner thermally guards Steam UI startup, Steam Library readiness, Steam
Play launch, the menu delay, every inter-input interval, and the level warmup.
ControlCenter is unloaded before a bounded game run and restored in cleanup.
Legacy temperature-ceiling command-line values are retained only for artifact
compatibility and do not participate in the decision.

The legacy thermal-watchdog interface is now observe-only.  It does not send
TERM/KILL on thermal state, charging state, numeric temperature, or controller
heartbeat.  Bounded test cleanup still stops only the exact Stray PID it
launched; user-owned play is never under automated thermal process control.
The old heartbeat-kill behavior and its 35.50 C ceiling remain historical
artifact metadata, not current policy.

The first fixed-input implementation was rejected by its own screenshot.  In
`/tmp/macws-stray-gameplay-guarded-sp90-20260821-2/result.json`, all three Host
Return pairs were delivered and the measured menu interval was 55.6715 FPS at
1194x834, High, 90%.  However, host-side Vision OCR on the exact final window
returned `START GAME`, `SETTINGS`, `CREDITS`, and `QUIT`, so this is explicitly
menu-only evidence.  The replacement `--progress-to-gameplay` path takes an
exact CoreGraphics window capture at each step, runs macOS Vision OCR on the
development Mac, and uses the observed UI state to choose Return versus the
runtime-calibrated SLOT 1 tap.  A final recognized menu/save screen is reported
as `NOT_GAMEPLAY`, never `OK` gameplay.

A separate automation defect was also runtime-confirmed after `cleanup_all`:
three alleged ipctool recovery attempts appended no new
`[launchdchrootexec] ... ipcserver` generation line.  `Remote.sudo("A && B")`
had elevated only A, leaving B in the SSH user's shell context.  The wrapper
now executes the complete expression inside one privileged Procursus bash.
The unload/reload regression then returned `ensure=loaded`, with launchd
publishing PID 44423 in `user/501/com.valvesoftware.steam.ipctool`.

Runtime observation found the macOS ControlCenter process consuming 4.7–6.7%
CPU while idle.  The runner now includes that exact executable in its
background accounting, temporarily unloads it only during an actual game
sample, and restores the real workspace job on every normal or exceptional
exit.  This is a reversible gaming-mode lifecycle operation, not a stub or
protocol bypass.

After the package install, the fullscreen recovery preflight at
`/tmp/macws-postinstall-workspace-preflight-20260821/result.json` verified
MacWSHost, WindowServer, macwsinputd, the input socket, a live DisplayStream
surface, and the actual UIKit postcondition:

```text
scene-fullscreen foreground-reassert requested=YES
display-performance-snapshot ... base-stream=430 base-sequence=1 base-surface=139
scene-maximization UIKit-observation ... fills-screen=YES bounds={{0, 0}, {1389, 970}} screen={{0, 0}, {1389, 970}}
```

A later package cold start produced a current-generation nonzero direct first
frame (`status=2388×1668`) before the performance-snapshot request observed a
base surface.  The preflight now accepts that exact callback as an alternative
positive frame witness while still rejecting every zero-valued historical
snapshot.  The deployed cold-start regression is retained at
`/private/tmp/macws-post-timeout-workspace-preflight-20260821/result.json`; it
returned `OK`, `fills_screen=true`, and `first_frame_callback=true` at 33.39 C.

The unresponsive desktop/Maps symptom had a separate frontend race.  Runtime
logs showed MacWSHost spawning Maps helpers 77970 and 77991 and killing each
with SIGTERM about five seconds later; the third helper eventually succeeded.
Source inspection of the actual paths showed that
`MacWSCatalystLauncher::macws_exec_maps_from_existing_host` legitimately waits
up to 30 seconds for the location provider, while
`macwshostd::LaunchMapsViaUIKitCarrier` allowed only 3 seconds before reporting
failure.  Each frontend retry then called `RetireLegacyMapsUIKitCarrier`, which
killed the still-correct waiter.  The host now waits 35 seconds, matching the
30-second prerequisite plus bounded exec allowance.  The public frontend URL
regression (the same action used by the Maps button) then passed in 13.03
seconds with one process, a non-empty AppKit window catalog, input socket, and
fullscreen scene transition; its screenshot and JSON are in
`/private/tmp/macws-maps-carrier-regression-20260821/`.

After the final game cleanup, the public `enter-workspace` action again
produced the UIKit full-screen postcondition
`bounds={{0, 0}, {1389, 970}} screen={{0, 0}, {1389, 970}}`.  The live desktop
snapshot was nonzero and advancing (`base-stream=1 base-sequence=2430
base-surface=264`), WindowServer/input/display/ControlCenter were alive, Steam
and Stray were absent, and iPadOS remained `nominal` at 31.79 C.

## Start Game input consumption

The initial transport-only trials remained on the main menu, so successful
socket delivery was not treated as proof that UE consumed the input.  A
preserving exact-binary diagnostic was then installed at
`FMacApplication::ProcessKeyDownEvent`, `FSlateApplication::OnKeyDown`, and
`FSlateApplication::OnKeyUp`.  The hooks are gated by Stray's UUID and exact
function prologues and always call the originals with unchanged arguments and
return values.

Runtime-confirmed by
`/tmp/macws-stray-ue-consume-trace-20260821-2/result.json`: the generated Return
down and up reached Slate and both were handled.

```text
STRAY-INPUT-CONSUME installed ... slateUp=0x1018e1c5c/0x10dda8000
APP-INPUT KEY-EVENT pid=13109 serial=1 type=10 keycode=36
STRAY-INPUT-CONSUME mac-key-down ... keyCode=13 ... translated=36 deferring=0 begin
STRAY-INPUT-CONSUME slate-key-down ... keyCode=36 charCode=13 repeat=NO begin
STRAY-INPUT-CONSUME slate-key-down sequence=1 result=YES end
APP-INPUT KEY-EVENT pid=13109 serial=2 type=11 keycode=36
STRAY-INPUT-CONSUME slate-key-up ... keyCode=36 charCode=13 repeat=NO begin
STRAY-INPUT-CONSUME slate-key-up sequence=1 result=YES end
```

The exact-window capture from that run showed the game's
`Stray is best experienced with a game pad.` warning and the real Steam overlay
reported 56 FPS at the upper left.  A later wait returned to the menu, so this
frame verifies a visual response to the delivered input but does **not** by
itself verify Start Game or gameplay.

The subsequent preserving LLDB trace on PID 19036 resolved the actual custom
widget path.  At `UHKButton::Press(bool)`, `w1=0`; the unchanged
`UWidget::IsVisible()` returned `w0=1`, and the one bound delegate resolved to:

```text
x8 = ... TBaseUObjectMethodDelegateInstance<false, USaveSlotWidget,
     void (UHKButton&), ...>::ExecuteIfSafe(UHKButton&) const
Summary: Stray-Mac-Shipping`USaveSlotWidget::_OnStartPressed(UHKButton&)
```

The selected slot's `USaveSlotWidget+0x410` save pointer was zero, so the
unchanged empty-slot branch ran.  Breakpoints then fired in this exact order:

```text
USaveSlotWidget::_OnStartPressed(UHKButton&)
UE4Function_Private::TFunctionRefCaller<..._OnStartPressed...>::Call(void*)
UChapterSubsystem::Open(EChapter)                w1 = 0x00000001
AZoneManager::OpenZone(...)                      w2 = 0x00000006, w3 = 0
AZoneManager::_OpenLevel(...)
UGameplayStatics::OpenLevel(...)
```

This runtime-confirms that the particular macPad -> AppKit -> Slate -> UE event
which reached the selected empty-slot action requested the first gameplay
level without modifying any return value or branch.  It does **not** prove that
three blind Return pairs reproduce the necessary UI navigation.  Retained
first-run screenshots showed Return leaving SLOT 1 unchanged; that screen
requires selecting the card spatially before confirming it.  This distinction
is why the performance runner now follows screenshot/OCR state instead of a
fixed key count.  None of this converts the menu benchmark above into a
gameplay FPS result.

The long interactive LLDB session was deliberately excluded from performance
evidence.  After detach it had already heated the device to 36.69 C; immediately
after termination iPadOS reported `thermal-state=serious` at 37.50 C.  The
repository recovery script stopped the full GUI/debug stack, and testing
remained paused until the state returned to nominal and the temperature fell
below the 36.00 C gate.

## Generic macOS half-float texture-write compatibility

The intermittent black blocks were traced upstream of WindowServer and the
macPad transport. Runtime capture of Stray's real `RWShadowFactors` resource
showed a 246×158 `RG16Float` texture whose green channel contained 1,465
`0x7c00` values before the first render pass that generated the canonical-NaN
block. Its exact three compute producers were:

```text
Main_00001ee4_19e23a6d
Main_000003f1_d1adf174
Main_000054ef_c016cab8
```

RE-confirmed from the captured third function's AIR: writable texture
location 1 is named `RWShadowFactors`. The exact green-channel arithmetic is
the sampled scene depth transformed by `View_InvDeviceZToWorldZTransform`;
the captured clear-depth input produces a finite value near `1e8`, which is
then passed unchanged to `air.write_texture_2d.v4f32`. This is the upstream
producer of the infinity; no downstream render check or NaN test is bypassed.

A byte-identical native MSL A/B established the platform semantic difference:

```text
macOS Apple M1:     status=4 error=nil rg16=0x3c00,0x7bff
iPad Apple M1 GPU: status=4 error=nil rg16=0x3c00,0x7c00
```

Thus the finite float-to-`RG16Float` conversion saturates on macOS but becomes
infinity on this iOS AGX stack. This claim is runtime-confirmed by the two
native probes, rather than inferred from the later visual artifact.

The compatibility implementation is deliberately resource-format driven.
`misc/build_half_float_metal_variant.py` discovers real float texture-write
intrinsics, joins their direct pointer arguments to AIR resource metadata, and
emits a root-owned source/variant/function/write-slot index. The runtime keeps
both ordinary and mechanically saturated pipelines. At each compute dispatch
it selects the variant only if every indexed writable slot is actually bound
to `R16Float`, `RG16Float`, or `RGBA16Float`; `R/RG/RGBA32Float` and missing or
ambiguous bindings retain the ordinary pipeline. Adding another affected
shader is therefore an offline evidence/cache operation, not a new opcode or
function-name branch in `libmachook`.

The device's Procursus LLVM 16 is a load-bearing part of this conversion.
Runtime pipeline replay showed that a no-op AIR reassembly made by host LLVM
22.1.8 loads as a library but AGX returns `Code=3`; the same no-op and
saturated variants encoded by device LLVM 16 both create a real
`AGXG13GFamilyComputePipeline`. The integrated `newLibraryWithData:` probe
then runtime-confirmed the complete production chain:

```text
METAL-HALF-VARIANT index=... entries=1
METAL-HALF-VARIANT library source=14876/b6c8ed737d6da3db ordinary=... variant=...
METAL-HALF-VARIANT function=Main_000054ef_c016cab8 ... writeTextureMask=0x2
METAL-HALF-VARIANT compute-descriptor ... ordinary=... variant=... errorDomain=(nil)
```

The builder regression found and fixed two representation-independent cases
which the original captured UE AIR did not exercise: named LLVM formal
arguments (`%output.coerce`) and literal vector write operands. Writable
texture metadata is now joined through the function's real formal-argument
ordinal rather than assuming LLVM's printed identifier is a number. Ambiguous
or derived pointers still fail closed. `python3 -m unittest
misc/test_half_float_variant.py -v` covers named and numbered arguments,
indirect-pointer rejection, and literal-vector saturation. Rebuilding the
Stray source after this generalization remained byte-identical to the prior
verified variant (`15676/449477f78c137aa7`).

The optimized production selector caches the variant pipeline and write mask
when the ordinary pipeline is bound. Non-target compute dispatches no longer
scan the global pipeline table, record diagnostic dispatch history, or call
`access(2)` at encoder end; those operations remain available only under the
explicit full-render-trace mode.

Runtime-confirmed by an actual 8×8 AGX dispatch of Stray's captured third
producer after deployment:

```text
#### METAL-HALF-VARIANT dispatch-switch #1 encoder=0x13f040bc0 ordinary=0x13f035200 selected=0x13f035ed0 mode=half-float writeTextureMask=0x2
METAL_SOURCE_PROBE shadowHalfDispatch status=4 errorDomain=(nil) errorCode=0 description=(nil) userInfo=(nil) finiteMax=64 infinity=0 other=0 first=0x3c00,0x7bff
```

The same unmodified shader and resources with an `RG32Float` output retained
the ordinary pipeline (no dispatch-switch) and preserved the finite value:

```text
METAL_SOURCE_PROBE shadowControlDispatch status=4 errorDomain=(nil) errorCode=0 description=(nil) userInfo=(nil) first=1,1e+08
```

This closes the selector's GPU-execution and pixel-value witness: the
half-float binding has 64/64 finite maxima and zero infinities, while the
32-bit binding is not clamped. The first automated live-game validation after
deployment still did not launch Steam or Stray because the iPad remained at
`thermal-state=serious` throughout the nominal-only admission timeout. That
artifact is retained at
`/tmp/macws-stray-half-float-variant-live-20260824/result.json`. Visible
artifact removal and a thermally valid gameplay FPS result therefore remain
separate required witnesses.

Three later live-game attempts preserved that same admission invariant.  The
first and third exhausted independent 900-second waits and recorded `ERROR`;
the second was deliberately interrupted to deploy an idle-pacing A/B.  All
three had `pid=null`, so Steam and Stray were never launched under thermal
pressure.  The retained result directories are:

```text
/tmp/macws-stray-half-float-visual-input-nominal-20260824
/tmp/macws-stray-half-float-visual-input-nominal-20260824-r2
/tmp/macws-stray-half-float-visual-input-nominal-20260824-r3
```

The idle-pacing investigation gained a direct AGX witness rather than
attributing heat from process CPU alone.  Before the A/B, the static desktop's
`AGXAccelerator/PerformanceStatistics` reported:

```text
"Tiler Utilization %"=27
"Renderer Utilization %"=26
"Device Utilization %"=27
```

The completion scaffold's accepted diagnostic range was extended from 100 ms
to 500 ms, while the existing wake socket still selects 8.333 ms during real
desktop input and Stray's versioned render record still selects its 54-FPS
target.  The current session was explicitly restarted with
`--pace-us=500000`; its rootfs marker contains `500000`.  Twelve 10-second
idle samples reported device utilization
`15,17,17,24,10,11,70,12,70,11,11,10` (median 13.5%, with two periodic 70%
outliers).  A 120-event RFB pointer stream completed, the following Retina VNC
capture remained 99.831% nonblack with intact wallpaper, Dock glass/icons,
menu bar and Terminal, and the settled AGX sample returned to 14%.

This is runtime evidence that the slower idle cadence reduces the usual
background GPU duty cycle without breaking the tested desktop/input path.  It
does **not** prove that the prior 27% AGX duty cycle caused iPadOS thermal
pressure: iPadOS remained `serious` after the A/B, so that causal attribution
remains THEORY.  It also does not yet promote 500 ms as the production default;
passive non-input application animation still needs a controlled regression
before changing the ordinary 100-ms profile.

## 2026-08-25 remote-main integration, idle heat, and real gameplay

The local checkout and `origin/main` both resolve to
`97ee1ee64f26a0af5d6620c40df44e1661b0f85e` (`Formalize the metal2metal
translation layer`).  The remote-main implementation is therefore the code
under test, not an unpulled reference branch.  Its profile/manifest-based
QuartzCore, SkyLight, and MPSImage AIR translation is retained; MetalFX is not
used because the exact prior runtime failure was
`GPUANERegionOps.mm:419: failed assertion 'ANE compilation failed!'`.

An idle heat investigation found one CPU-side defect independently of the
game.  With Steam and Stray absent, `ps` reported `macwshostd` at 7.7% CPU.
A three-second `sample` of deployed PID 1789, symbolicated against the exact
device binary UUID, put the runnable supervisor frames in
`StartApplicationSessionSupervisor`, `FindRunningSteamExecutable`, and
`InspectJob`.  Source inspection of that exact path showed that its one-second
timer called `RetireConfirmedSteamOverlayOrphan`, which performed three global
process/path scans even after every Steam owner had exited.  The production
supervisor now performs one start-time discovery, discovers at a bounded
five-second cadence only while a tracked Steam owner is live, caches the exact
Stray/overlay PIDs, and performs one final transition discovery before orphan
retirement.  After targeted hostd deployment, five consecutive process samples
reported `macwshostd 0.0%`; simultaneous idle AGX samples were 20%, then
3%, 3%, 3%, 3%.  This runtime-confirms removal of that persistent CPU wakeup;
it does not attribute every prior GPU/thermal observation to hostd.

The retained real-game result is:

```text
/tmp/macws-stray-v23-profile-shared-agent-20260825/result.json
output texture: 1400x900 / pixel format 80
quality: High, internal resolution: 35%, cap: 54
gameplay W hold: 5 seconds
present sequence: 9240 -> 10080
process after observation: live
UE fatal: none
mean / median / max: 40.853 / 43.334 / 45.095 FPS
thermal before / sample / after: nominal / serious / serious
functional_result: OK
result: THERMAL_PRESSURE
```

The macPad hierarchy captures contain the real vine/pipe gameplay scene and
the Steam FPS HUD in the upper-left.  The before/after SHA-256 values differ,
and presentation advanced during W, so this is a visible-output witness rather
than process uptime.  The FPS value is explicitly not a no-throttling result:
AGX was 88% before the sample and 99% after it while iPadOS reported `serious`.
The CPU averages were Stray 90.25%, WindowServer 13.62%, MacWSHost 7.76%, and
macwsdisplayd 2.21%.

The automation failure from the immediately preceding attempt was also fixed
at its owning layer.  A dedicated, idle signal-agent SSH channel exited during
a device network stall, while the already-prearmed input agent remained alive
and successfully retired diagnostics plus the GUI lease.  Exact
`proc_pidinfo`/`proc_pidpath` status and bounded cleanup signals now share that
surviving input/control process.  An online same-UID test returned `match` for
MacWSHost, `mismatch` for a false Stray identity, and sent a harmless SIGCONT
only for the matching identity.  The live Stray run then confirmed TERM cleanup
with initial identity `match` and final identity `missing`.  Thermal telemetry
is observe-only and has no route to these operations.

The visual progression state machine previously waited 150 seconds immediately
after changing an empty slot from `NEW GAME` to `START GAME`; the game had not
started yet.  Captures `prompt-3.png` and `prompt-4.png` in the failed run prove
that exact state transition.  The delay now begins only after the second
confirmation actually activates `START GAME`, removing a deterministic
150-second menu heat soak from future runs.

Finally, remote-main's generic metal2metal router now caches a complete
negative function-set attribution per immutable `MTLLibrary` object.  Before
this change, every hooked `newFunctionWithName:` on an unrelated application
library rebuilt its entire `functionNames` set and walked all manifests.  This
is a code-path correction, not yet a claimed FPS improvement; deployment and a
nominal-state A/B remain required.

### Desktop start preflight and lazy System Settings preparation

The first production-controller recovery after the hostd rebuild rejected an
otherwise complete rootfs with this exact log:

```text
rootfs-probe ready=NO mask=0xc bash-errno=1 ws-errno=1 gui-errno=0 exec-errno=0
```

Both paths existed, were regular executable files, and the actual privileged
launcher subsequently executed `/bin/bash` inside that same rootfs and printed
`chroot-ok`, `bash-x=0`, and `ws-x=0`.  The preflight had asked unprivileged
hostd to `access(X_OK)` macOS binaries even though hostd never executes them;
`launchdchrootexec` does so after the privilege and chroot transition.  Hostd
now uses `stat` to validate that the two rootfs targets are regular files with
an execute bit, while retaining real `access` checks for the iOS-side launcher
and GUI script.  The later startup transaction still waits for real
WindowServer, input, and display endpoints.  After deployment the production
controller reached:

```text
rootfs=yes windowserver=yes busy=no phase=就绪
WindowServer=57075 macwsinputd=57069 macwsdisplayd=57165
Finder=57225 Dock=57282
```

That recovery took about 297 seconds.  Stage timing in the exact startup log
assigned 199 seconds to `ensure_settings_extensions_runtime.sh`, which rebuilt
48 System Settings pane carriers before WindowServer could start.  Desktop,
Steam, and Stray do not consume those carriers.  The ordinary desktop start
now verifies only the shared ViewBridge/ExtensionKit/HIServices proxy contract;
full per-pane verify/prepare/verify moved to hostd's `system-settings`
application launch boundary.  Source, shell syntax, build and targeted deploy
are verified.  A later production-controller stop/start measured 13 seconds to
stop and 111 seconds from `macwshost://start` to
`windowserver=yes busy=no`, versus about 297 seconds before lazy preparation.
The new session created WindowServer 70345, inputd 70339, displayd 70443,
Finder 70505, Control Center 70511, and Dock 70568.  Host runtime logs also
recorded `DisplayStream IOSurface 首帧已就绪` and the first 2388x1668 final
composite.  The remaining 111 seconds is still a performance problem: coarse
phase timestamps assign roughly 27 seconds to pre-launch repair and 51 seconds
to the system-service/WindowServer interval, followed by about 15 seconds for
workspace clients.  No further stage is skipped without a separate invariant.

### 2388x1668 Medium result and bounded MetalFX evaluation

The requested near-2440 output was exercised as 2388x1668 fullscreen, Medium,
35% internal resolution, built-in scaling, and a 54-FPS cap.  The retained
actual-game result is:

```text
/tmp/macws-stray-2388x1668-medium35-metal2metal-20260825/result.json
functional_result: OK
present sequence: 6600 -> 7200 after a real five-second W hold
mean / median / min / max: 26.2785 / 26.103 / 23.778 / 29.524 FPS
output texture: 2388x1668 / pixel format 80
AGX tiler / renderer / device after sample: 98% / 98% / 98%
thermal before / sample / after: nominal / serious / serious
```

The visible captures contain Stray gameplay and Steam's upper-left FPS HUD;
the game remained live and presenting after input.  A one-variable
`r.Upscale.Quality=1` control was worse (mean 24.6382, median 23.632 FPS) and
was atomically removed.  These measurements runtime-confirm that this output
profile saturates the GPU and is not close to 50 FPS.  They do not prove a
theoretical lower-overhead presentation path cannot reach the target.

Remote main does not include a MetalFX route.  The exact Ventura MetalFX
`default.metallib` was therefore translated offline through the same
profile/manifest tool:

```text
converted=31/31 lowerings=0 target=air64-apple-ios19.0.0-macabi
container_target=macabi bitcode=196128->210832 bytes
file=236280->250984
verified profile=ventura13-ios19-macabi translated=31
```

With the temporary manifest installed, `metal_source_probe` loaded the
translated output on the real `AGXG13GFamilyDevice` and created all 31
functions.  This is only a library/function witness.  A new bounded
`misc/metalfx_spatial_probe.m` then exercised the public spatial-scaler factory
for a single 320x180 to 640x360 frame.  Without non-WindowServer function
routing the factory returned nil.  With an explicit diagnostic-only routing
gate, the runtime accepted the complete manifest, loaded its companion, and
created `FSQuadVertexShader`, normalize, scale, and sharpen functions plus a
real `AGXG13GFamilyRenderPipeline`.

The scaler factory nevertheless failed to return.  The preserving two-second
sample at `/var/mnt/rootfs/tmp/metalfx-spatial-hang.sample.txt` located both
pipeline builds in the unchanged path:

```text
-[MTLFXSpatialScalerDescriptor newSpatialScalerWithDevice:]
-[_MFXSpatialScalingEffectEFFECT_NAME_V1 initWithDevice:descriptor:]
-[AGXG13GFamilyDevice newComputePipelineStateWithDescriptor:error:]
AGX::Compiler::compileProgram<AGX::ComputeProgramKey>
-[MTLCompiler compileFunctionRequestInternal:...]
xpc_connection_send_message_with_reply_sync
mach_msg2_trap
```

The result was identical after removing 24 old, idle compiler-service
instances and independently proving a fresh iOS-native service round trip with
`PingMTLCompilerService` (`Received synced event`, service PID 67710).  The
non-WindowServer route remains opt-in only through
`MACWS_METAL2METAL_NON_WS_DIAGNOSTIC`; the temporary MetalFX manifest/output
were deleted and the stuck exact probe PIDs were terminated.  This rejects
MetalFX as a production Stray optimization for now without bypassing a compile
check or leaving an experimental route installed.

The device was finally returned to the earlier runtime-proven playable
profile: 1400x900 fullscreen, High, 40% internal resolution, built-in scaling,
50-FPS game and engine caps, histogram eye-adaptation readback disabled by the
previously verified pre-exposure settings, and hardware occlusion queries on.
The current INI values were read back after the atomic write.  Steam's global
and account settings independently verify overlay enabled, top-left FPS corner,
and high contrast.  The retained comparison run
`/tmp/macws-stray-wasd-exactfix-20260823/result.json` measured 49.987 FPS mean,
remained nominal throughout, and advanced presentation after a five-second W
hold.  That earlier result is the current supported fallback; it is not
reported as a fresh post-metal2metal benchmark.
