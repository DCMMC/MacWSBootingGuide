# Settings, stock application admission, Safari — 2026-09-13

Device: iPad13,6, iPadOS 16.3.1, `192.168.1.7:2222`. This is a **partial
repair**, not acceptance of every Settings pane, Launchpad application or Safari.

## Later activation update (supersedes the initial deployment checkpoint)

The schema-2 bridge and launch integration were subsequently activated. The
live RunningBoard is PID 57946; the latest own broker is PID 11424. The
paragraphs below describing PID 416 and pending activation are the earlier
checkpoint, not the present deployment state. No iPad reboot, respring or
WindowServer restart was used; RunningBoard was restarted once in that earlier
activation step, not repeatedly during the later acceptance work.

General remains **unaccepted after activation**, not just awaiting the new
adapter. Runtime-confirmed via
`tmp/apps-acceptance-20260913/settings-general-live-2.log` (verbatim message):

```text
Sandbox: hook..execve() killing com.apple.systempreferences.GeneralSettings[pid=59632, uid=501]: (err=2) failed to set executable path
```

That is the observed rejection, not proof of the precise underlying sandbox
cause. The user deferred the remaining incompatible applications. Safari's
experimental routing remains inactive. Current Open-In, Launchpad, command
latency and benchmark acceptance is recorded separately in
[interoperation-launchpad-geekbench-20260913.md](interoperation-launchpad-geekbench-20260913.md).

## Initial checkpoint (before the activation above)

At this checkpoint no reboot, respring, WindowServer or RunningBoard restart
had been performed.

## Deployment boundary

- Active: the first Settings raster optimization in all four installed
  libmachook copies; Calculator's original calcview CodeDirectories registered;
  TextEdit main image converted using the existing MacWS chroot profile.
- `macws_system_app_prepare.py` is installed. Its complete launch integration
  passed a one-shot probe compiled from the actual candidate macwshostd source.
  The live broker is still PID 416 and does **not** call this helper yet.
- Built, **not activated**: RunningBoard bridge schema 2, embedded Settings
  extension proxy/identity support, updated verifier/preparation scripts and
  candidate macwshostd. Loading that bridge requires a controlled RunningBoard
  restart; user confirmation is pending. Do not install the schema-2 host and
  then open Settings accidentally: its readiness repair can restart that service.
- Safari's experimental routing was rolled back. All four original WebKit /
  SandboxBroker executables were restored, and the four added proxy bundles were
  moved recoverably to `/var/mobile/Media/macws-webkit-20260913/retired`.
  The experiment is not in the aggregate build or default XPC routing.

## Settings raster work

Runtime-confirmed via `tmp/settings-sidebar-baseline-stack-20260912.txt` and
same-boot address symbolication: the Settings main thread repeatedly entered
`ISGraphicSymbolResource`, `CI::GLContext::quad`, and
`glvmInterpretFPTransformFourInner`. Actual call sites include CoreImage
`+0x1d54e0` (`CI::GLContext::quad+0x270`), IconServices `+0x362bc`
(`-[ISGraphicSymbolResource imageForSize:scale:]+0x10c`) and IconServices
`+0x18084` (placeholder generation `+0xf0`).

The previous compatibility path produced the expensive original graphic and
placeholder before discarding them for replacement. The revised path retains
the real upstream resource/descriptor/vector geometry and composes at CoreUI's
final raster boundary. It retains Apple's IFImage wrapper and cache, and falls
back to the original implementation on actual resource/geometry failure. It
does not supply invented pane icons or suppress a failed rendering check.

Runtime launch witness, `/var/mobile/Library/Logs/MacWSHostd.log`:

```text
1789228747.652 launch-app id=system-settings pid=37824 executable=/System/Applications/System Settings.app/Contents/MacOS/System Settings
1789228748.026 application-reopen pid=37824 sent=YES errno=0
```

Window readiness followed at 1789228751.438 (about 3.8 seconds after spawn).
This is **not** the entire first request after a library update: required
dependency reconciliation ran beforehand. Inspected screenshots
`tmp/settings-raster-first-20260913.png` and
`tmp/settings-appearance-focused-20260913/frame-003.png` show real Appearance
controls and complete sidebar icons. The latter is approximately 1.5 seconds
into the focused click sequence, not a statistically established latency bound.

## General is an omitted extension root, not merely slow rendering

Runtime-confirmed via `tmp/settings-general-navigation-20260913.txt`:

```text
Failed to create extensionProcess for extension 'bundleID: com.apple.systempreferences.GeneralSettings instance ID: (null)'
Error Domain=OSLaunchdErrorDomain Code=2 "No such file or directory"
```

The actual General bundle is
`/System/Applications/System Settings.app/Contents/PlugIns/GeneralSettings.appex`.
The old adapter covered only `/System/Library/ExtensionKit/Extensions/` (48
panes). `include/macws_settings_paths.h` now shares strict two-root validation
between RunningBoard, the freestanding proxy and macOS bundle identity lookup.
Preparation and verification enumerate both roots and filter the actual
Settings UI extension point; the unrelated embedded `csimporter.appex` is not
converted. Readiness generation 2 prevents the old loaded bridge from passing.

The General screenshot `tmp/settings-general-focused-20260913/frame-011.png`
still shows a blank pane. **General has not passed device acceptance**; its
new adapter is not loaded. A live extension PID alone will not count as success.

## Calculator: preserve and admit dynamic plugin code

RE-confirmed in the actual Ventura Calculator binary (`tmp/Calculator-ventura`,
`tmp/calculator-dyld-disasm-20260913.txt`): `loadView:asPrefetch:` at `0xbe48`
loads the plugin principal class (`0xc098`). With no plugin, the subsequent
`normalSize:` result is zero; the real CalcWindow is created with zero content
size (`0x54ec..0x57cc`). Changing the saved frame alone did not fix it.

Runtime NSBundle probe before admission:

```text
exists=1 loaded=0 class=none
NSCocoaErrorDomain Code=3587
have 'x86_64,arm64e', need 'arm64'
```

After registering the **unchanged** BasicAndSci and Hexadecimal plugin hashes:

```text
loaded=1 class=BasicAdvancedController error=none
```

The registration result reported two added hashes and 0.057 seconds total.

The misleading architecture error did not require a CPU-subtype rewrite.
The real Calculator window (PID 42935, window 483) is 232 × 321 logical points;
`tmp/calculator-after-plugin-trust-20260913.png` visibly shows its controls.
Launch probe was about 3.6 seconds. Do not cite `calculator-five-...png` as an
arithmetic witness: the plus-key injection was unsupported and that image
shows 3, not 5. Only launch/rendering and digit entry were established.

## TextEdit: trust membership is not execution-profile compatibility

Runtime-confirmed via `tmp/textedit-launch-system-20260913.log`:

```text
System Policy: launchdchrootexec(48624) deny(1) process-exec* /private/var/mnt/rootfs/System/Applications/TextEdit.app/Contents/MacOS/TextEdit
Sandbox: hook..execve() killing com.apple.TextEdit[pid=48624, uid=0]: (err=1) failed to apply exec policy
```

Its existing native CDHash was already trusted. `ldid -arch arm64e -e` showed
the stock sandbox profile but not the established MacWS chroot profile. A
backed-up, new-inode merge of the existing project profile admitted the same
application; no code instructions or sandbox validation functions were patched.

The new helper separately checks main-image execution policy and plugin trust.
Already converted mains are never re-signed. Dynamic libraries/plugins retain
their original signatures. Only a first-party main missing the existing
profile gets an atomic, backed-up conversion. The live trustcache is checked
on every preparation, including after cache hits. No third-party bundle or
whole-rootfs scan is added. Concurrent preparation is serialized per main image.

An end-to-end test restored the backed-up stock TextEdit main, then launched
through the **actual candidate host code**, with no manual signing step:

```text
SYSTEM-APP-ADMISSION {"added": 0, "backend": "already-trusted", "cached": 0, "converted": true, "files": 1, "images": 1, "resource_hits": 0, "seconds": 0.201}
LAUNCH-PROBE app=/System/Applications/TextEdit.app ready=yes pid=49594 seconds=2.703 message=
```

Inspected `tmp/textedit-production-admission-20260913.png` shows the actual
TextEdit editing window. Warm helper check was 0.067 seconds and did not rewrite
the executable. Original image backup:
`/var/mobile/Media/macws-textedit-20260913/TextEdit.original`; helper conversion
also preserves the original under `/var/mnt/rootfs/var/db/macws/system-app-admission/`.
This does not establish that every Launchpad app now works.

## Safari: real WebContent launch reached, allocator port still required

The original failure was an unavailable WebProcess (PID 0) and invalid
SandboxBroker XPC connection. An explicit, unshipped transport experiment using
the existing first-image chroot proxy model started the real macOS SandboxBroker
(45160) and WebContent (45154). Native XPC per-instance service context was
preserved; this was not an iOS WebKit substitute.

WebContent then crashed during initialization. Runtime-confirmed via
`tmp/webcontent-010104-20260913.ips`:

- Actual JavaScriptCore UUID: `BA8242B1-8248-3A35-93DE-F769B83B3746`.
- Runtime PC `0x1b8c224dc`, slide `0x1e2c8000`, unslid `0x19a95a4dc`.
- The call-once function is `Gigacage::ensureGigacage` initialization.
- x19 = 96 GiB, x22 = 32 GiB; disassembly adds these before `mmap`, requesting
  a **128 GiB virtual reservation**, not 128 GiB of resident RAM.

RE-confirmed via bounded reads of the actual installed cache,
`tmp/gigacage-init-disasm-20260913.txt`:

```text
0x19a95a154: add x20, x22, x19
0x19a95a158: mov x0, #0
0x19a95a15c: mov x1, x20
0x19a95a160: mov w2, #3
0x19a95a164: mov w3, #0x1002
0x19a95a168: mov w4, #0x3f000000
0x19a95a4dc: brk #0xc471
```

The error path's actual static string at `0x19bd6b32d`:

```text
FATAL: Could not allocate gigacage memory with maxAlignment = %lu, totalSize = %lu.
(Make sure you have not set a virtual memory limit.)
```

The crash report labels the trap PAC_EXCEPTION, but disassembly establishes
an intentional fatal `brk`, not evidence of a bad authenticated pointer.
The precise iOS VM rejection boundary is still unproven. Reducing only one
allocation constant, disabling Gigacage, or skipping this trap would not be a
correct allocator port: address masks, inline users and geometry must agree.
Extended-virtual-addressing is already present in the project profile.

**Safari webpages still do not work.** Default routing and original service
executables were restored and experimental processes closed. No assertion,
allocator invariant or browser security feature was bypassed to claim success.

## Validation and next activation

- 136 local tests pass (`PYTHONPATH=misc python3 -m unittest discover -s misc
  -p 'test_*.py'`). Covers admission ordering, atomic failure rollback, original
  signature preservation, fresh trust checks, both extension roots and missing
  General detection, plus existing regression suites.
- arm64 macwshostd, libmachook, MacWSCatalystLaunch and the production
  SettingsExtensionChrootProxy build successfully. Experimental WebKit branches
  are compile-time excluded from production proxy builds.
- Final health read: SpringBoard 3601, WindowServer 20382, RunningBoard 387,
  host 416 unchanged; thermal state nominal, 35.79 °C.
- Pending permission: activate the coherent Settings/host candidate and restart
  RunningBoard once, then visually test General/Appearance/Displays, app launch
  and input without repeatedly restarting the desktop. Full Safari allocator
  compatibility remains a separate unfinished implementation.

Raw screenshots and process captures contain device context and stay under
untracked `tmp/`; do not include them in a blanket Git add.
