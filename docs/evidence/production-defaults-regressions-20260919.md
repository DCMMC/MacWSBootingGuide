# Production-default and deployment regressions (2026-09-19)

## Runtime evidence, not inferred causes

### Window sizing

The running SpringBoard (PID 381) had the Sep-15 Windowing binary. Its strings
and live readiness record used `/var/mobile/Library/Preferences`, while the
new Host expected `/tmp`. The About Finder request logged:

```text
scene-native-size unavailable id=25E3D763-AD4D-490B-A717-79C043148862 requested=301.0x374.0 reason=windowing-bridge-not-loaded
window-size follows-appkit window=818 pid=4270 reason=pre-visible-connect logical=301.0x326.0 density=1.000 chrome=0.0x48.0 scene=301.0x374.0 fixed=YESxYES requested=NO
```

The actual iOS scene was 1004x807. Restoring the matching old Host changed the
same request to `requested=YES` without changing the macOS size policy. This
confirmed the mismatched deployment/communication contract; it did not, by
itself, prove visual resize acceptance.

The replacement publishes a shared, versioned notifyd capability state after
the real observers/hooks are ready. Consumers validate ABI, required bits and
the live publisher's process identity. Per-scene request plists remain IPC
payloads, not feature flags. No `.loaded` file enables windowing. Startup and
package installation no longer trigger an automatic respring on missing state.

### VS Code audio

The installed old startup/repair scripts lacked the current CoreAudio trust
closure. A real output AudioUnit probe returned `instance status=-1 unit=0x0`.
The device oslog contained:

```text
AMFI: '/System/Library/Components/CoreAudio.component/Contents/MacOS/CoreAudio' has no CMS blob?
Unrecoverable CT signature issue, bailing out
```

Neither CoreAudio CodeDirectory hash was in the dynamic trustcache. Registering
the existing CoreAudio/AudioDSP hashes, without replacing images or restarting
applications/services, made the same probe return instance/init/start/stop
status 0. The existing VS Code audio PID 53509 then advanced the ring from
3251200 frames / 3175 callbacks to 3489099 / 3917. Native output logged:

```text
output start status=0 preroll=4800
```

A second negative control on the old library, with its audio opt-in absent,
rendered 141 callbacks but published zero frames. Production playback is now
default-on. Only real output AudioUnits publish; GenericOutput/offline units
and audio server processes do not. `misc/macws_audio_smoke.c` checks both sides
of this distinction using actual AudioUnits, not a fabricated ring payload.

## Systematic changes and verification boundary

- `docs/runtime-switches.tsv` classifies every discovered gate. Production
  command ABI, completion, owned scanout and final-composite paths no longer
  consume enable files. Native AGX/class registration default on without env.
- Diagnostic flags are exact `/tmp` paths, default off. The cleanup list and
  forbidden launch environment list are generated from the inventory; IPC,
  user settings, artifact manifests and validated caches are separate classes.
- Settings' RunningBoard bridge also uses live capability state rather than
  constructor-written readiness files. Its hook must exist before publication.
- The package checker ties cached Windowing to its source and transitive
  headers, verifies actual archive payloads against staging/current scripts,
  and rejects unsafe arm64e static objects in the on-device Catalyst tweak.
- Device-only source changes were archived and SHA-verified before git sync.

Host-side protocol/notification fault-injection and source regression tests
are necessary checks, not substitutes for device screenshots or audio frames.
The isolated notifyd tests on the iPad confirmed both cross-UID directions,
live process identity lookup, refresh delivery and registration lifetime.
Final installed-package and visual/audio results are recorded below only after
they have actually run. A respring is not a full iPad cold-boot test.

## Installed candidate and upgrade migration

The complete on-device package build and archive/source contract passed. The
user-authorized single respring changed SpringBoard from PID 381 to 78270;
there was no Safe Mode marker. RunningBoard was separately reloaded from
PID 382 to 78311 to load its new bridge, with SpringBoard remaining 78270.
Both actual capability readers returned:

```text
windowing ready=yes abi=1 pid=78270 capabilities=0x1f
settings-bridge ready=yes abi=1 pid=78311 capabilities=0x01
```

Strict startup preflight caught an optional old Chrome job outside the current
package payload that still forced `MACWS_PIN_FALLBACK=1`. The upgrade migration
now validates the six exact managed job identities and removes only this
retired shipped setting, atomically preserving other settings and file
metadata. Other real diagnostic settings still fail preflight. After the
script-only correction was rebuilt, package-verified and installed:

```text
[macos_gui] Migrated retired production environment: /var/jb/Library/LaunchDaemons/com.macwsguide.chrome150.plist (MACWS_PIN_FALLBACK)
[macos_gui] PRODUCTION-PREFLIGHT: native AGX required; diagnostics/env traces/dump sentinels OFF.
```

That build/install did not perform another respring. The subsequent application
trust walk paused at the existing thermal admission check (`fair`, raw 1,
38.69 C), before WindowServer started. No thermal guard was bypassed; this
intermediate attempt is not counted as a completed GUI startup.

The next real startup exposed a separate existing shell contract error: all
three audio jobs loaded/listed successfully, but bare-label `launchctl
kickstart` returned 64 with `Unrecognized target specifier.` The verified
target is `user/foreground/com.apple.macosbooter.audio.AudioComponentRegistrar`;
`launchctl print` resolved it to the actual `user/501` domain. Startup now uses
that target and reports a failed launch visibly. Its executable shell-block
regression tests cover both success and propagated failure.

After that correction, ordinary Host startup completed without enabling any
diagnostic flags. `WindowServer` PID 99427 produced the first frame; startup
logged `TIMING gui-start stage=first-frame seconds=0 total=97`, and control
status became `busy=no`, `windowserver=yes`, phase `就绪`.

The exact obsolete VS Code job under `/var/jb/Library/LaunchDaemons` also
contained an invalid XML comment and the retired PIN setting. Its recognized
original bytes were moved, not discarded, to the content-addressed
`/var/jb/usr/macOS/retired-launch-jobs/*.plist.disabled` quarantine. The actual
generated VS Code job was unchanged. The quarantine is outside auto-loading
directories and is never consumed by the production launcher.

## Installed geometry and audio acceptance

On 2026-09-19 the user independently confirmed both audio and window sizing
work correctly. Automated/runtime witnesses supplement that acceptance:

- The complete iPadOS composite capture (2778x1940, native capture helper)
  shows About Finder correctly fitted, without the former oversized black
  margins, alongside other Stage Manager windows.
- About Finder window 62 was discovered at time 1789763558.827. Its first
  scene geometry at 1789763559.681 was already 301x374 (301x326 AppKit content
  plus 48 points of Host chrome). The postcondition was `landed=YES`,
  `action=keep-initial-layout`; four window scenes remained foreground.
- Get Info window 73 advertised width 265...400, fixed height 342. Its
  configure acknowledgement applied the requested 265x342 logical size.
  The sidecar is a constraints/ACK witness, not itself a screenshot.
- The real native audio smoke ran without `MACWS_AUDIO_RENDER_BRIDGE`:
  GenericOutput rendered one offline callback without taking ring ownership;
  DefaultOutput returned status 0, rendered 140 callbacks and published
  71,680 frames (probe/owner PID 99677), exit 0.
- A fresh VS Code launch returned PID 4696. Audio helper PID 5921 had no
  audio opt-in variable. Bounded WebAudio playback reported a running 48 kHz
  context and advanced the ring by 115,456 frames / 451 callbacks. Native
  output logged `output start status=0 preroll=4800`, then returned to idle.

Read-only flag audit found zero present paths among 86 inventoried
diagnostic/retired paths in each of the iOS and rootfs namespaces (172 checks),
and zero among 19 exact old persisted/readiness paths. All six active managed
job configurations were free of forbidden diagnostic environment settings.
The source inventory covered 275 environment names and 77 currently consumed
flag files (423 total ledger records). Host Python regressions passed 218
tests with 7 tool-dependent skips; device archive-contract tests separately
passed all 12 cases. Protocol and notifyd fault-injection tests passed.

No complete iPad reboot was performed. The initial package required one
authorized respring; later script-only fixes did not. The physical Magic
Keyboard double-click recognizer is not claimed as a new hardware acceptance
result; its downstream indirect-pointer transport was verified separately.

## Native test-harness admission on iPad

The first broad device run (`/tmp/macws-device-regressions-20260919.log`)
reported 189 tests, 7 failures, 7 errors and 1 skip. That run is **not a device
suite pass**. Its host-oriented fixtures compile temporary Mach-O programs and
libraries, then immediately execute or `dlopen` them without the native
signing/trustcache step used by the project's device probes.

Three library fixture groups were rejected by the loader, for example:

```text
OSError: dlopen(/tmp/macws-compute-abi-2vy6q_3u/translator.dylib, 0x0006): tried: '/tmp/macws-compute-abi-2vy6q_3u/translator.dylib' (file system sandbox blocked mmap() of '/private/var/tmp/macws-compute-abi-2vy6q_3u/translator.dylib')
```

Ten executable fixture invocations ended with SIGKILL 9 rather than an
assertion failure. Separately, `test_live_service_response_is_accepted`
assumed `/usr/bin/true`; read-only inspection found no such iOS file, while
`/var/jb/usr/bin/true` was present. No historical kernel signature log was
available for those individual failed invocations, so SIGKILL alone was not
treated as proof of their cause.

A bounded admission A/B then compiled the existing, unchanged
`misc/macws_protocol_test.c` directly on the iPad:

```text
source SHA-256: 5e3ef559ab3911fda4a3327f5112353f6fdede81f848269cad78a69951b6b732
artifact: /tmp/macws-native-test-ab.irD2DA/protocol-test
initial CodeDirectory flags=0x20002(adhoc,linker-signed)
initial CDHash=3df6d12be915de515766f53ceb54e1ce00228035
/var/jb/usr/bin/bash: line 1: 84227 Killed: 9               /tmp/macws-native-test-ab.irD2DA/protocol-test
unadmitted_exit=137
```

That exact artifact was signed with the installed project entitlements and its
new CDHash admitted through `jbctl trustcache add`. No source, assertion or
compiled instruction was changed. The SHA-256 of its `otool -s __TEXT __text`
dump was identical before and after signing:

```text
fbdf32ca9cebb2f180ad48e4c012e0846d7489556d4b0f8016d489b9709021f4
admitted CDHash=f9d28068ed5a042f35f4cf9cc62738de551c27fe
macws protocol validators: PASS
admitted_exit=0
```

This runtime A/B confirms the missing admission step can produce the observed
SIGKILL in a pure protocol harness and that the admitted protocol tests pass on
the actual iPad. It does not retroactively pass every failed executable or
library fixture. Those remaining host harnesses were not rerun on the device;
native application, geometry and audio acceptance remain separate checks.

## Bounded heat observation and startup-only diagnostic overhead

A read-only, three-sample observation on the iPad at device UTC
2026-09-18 20:56:18/28/38 used cumulative `ps` CPU time, not only its smoothed
instantaneous percentage. Over those 20 seconds, WindowServer PID 99427
advanced from 6:51.65 to 6:54.96 CPU seconds; Host PID 1698 from 2:25.54 to
2:27.49; Weather PID 9917 from 0:16.78 to 0:18.76. These correspond to 16.6%,
9.8% and 9.9% of one core respectively. Finder, ControlCenter, Activity
Monitor and displayd averaged 4.3%, 3.7%, 3.5% and 2.5%. No compiler, test
probe or debugger appeared among the highest-CPU processes.

AppleSmartBattery reported raw `Temperature=3829` then `3839`,
`IsCharging=No`, and raw `PowerTelemetryData.SystemLoad=12301` then `10398`.
These raw observations are not a calibrated temperature/power measurement.
There may have been user interaction, so this was **not an idle baseline**.
`ps` also reported zero cumulative time for protected iPadOS services such as
SpringBoard/backboardd; those entries cannot rule out system-side work. No
continuous CPU hot loop or cause of sustained heat was established.

Source review identified startup-only observation work that still ran before
the diagnostic stderr filter: the AGXBuffer class lookup, the first six
class-name/registration queries, an unused `objc_duplicateClass` symbol
lookup, and five IOGPU symbol-availability queries. Their results only feed
diagnostic output. The observations themselves now use the existing
off-by-default diagnostic gate. A host test compiles the actual guarded
blocks with counted query stubs and verifies zero calls when diagnostics are
off, while explicit diagnostics still execute the expected queries.

This does **not** disable native AGX, move IOGPU preload, change driver-class
registration/fixup ordering, or remove the AGXBuffer allocation witness. It
removes unnecessary startup observations, not a measured per-frame hot loop;
the heat complaint is **not claimed fixed by this change**.

## Source, package, installed and mapped identity are separate witnesses

The independent read-only audit began while both checkouts named `842b2a0`;
the device checkout was clean and the Mac had the follow-up fixes in progress.
The device's 04:32 candidate package passed `macws_artifact_contract.py
verify-package`, including the Windowing source/header manifest. This proves
the checked source payloads and staged/archive bytes, not that every live
process has remapped those bytes. Non-Windowing binary UUIDs do not encode a
Git commit, so they are not a substitute for build provenance.

Archive/staging/installed whole-file SHA-256 agreed for Host, Windowing,
hostd, inputd, displayd, allocd, autosignd and audiooutd. Catalyst and the
compiler tweak had differing whole-file hashes after installation, but both
architecture slices retained identical UUIDs and `__text` hashes. Those
differences therefore do not establish differing executable instructions.
For example, the compiler's arm64e slice was UUID
`fa98b3abb0e730f0b60166fadae1a865`, `__text` SHA-256
`737ddf6607923717157f3454d6353eed5eae6bdb264618189e0c887a1405a0ef`
in both the archive and installed tweak.

`misc/macws_runtime_image_identity.c` reads only allowlisted image headers and
at most 8 MiB of instruction bytes from allowlisted processes, without
attaching, suspending or writing to them. It reports UUID and `__text` hash,
not a fictitious whole-mapped-file checksum. It has a 15-second deadline,
bounded image/load-command counts, and tests that exercise the actual parser
against malformed synthetic images. The following is a point-in-time ledger
during the explicitly coordinated library replacement, not a claim that the
final deployment was already complete:

| Component / PID | Independently verified live evidence | Limitation |
| --- | --- | --- |
| Host / 1698 | UUID `f68c490943173964841712c039f55fa2`, text `ee75fabe3c1f63e6d0d4e10985aed59a9ce67885557b8daa60f54c02fb7c8c28` matched installed/archive | Instruction identity, not all mutable runtime state |
| Windowing / SpringBoard 78270 | Live capability reply `ready=yes abi=1 pid=78270 capabilities=0x1f`; installed bytes matched manifest/archive | `task_for_pid=5`; mapped UUID/hash unavailable |
| Settings bridge / RunningBoard 78311 | Live capability reply `ready=yes abi=1 pid=78311 capabilities=0x01`; installed text matched archive | `task_for_pid=5`; mapped UUID/hash unavailable |
| inputd / 12779 | Main UUID `72af80e8b82e3054814d8fae41919e8b`, text `e9d1e65cdda9a7021065216c38749a675b8fb006eca296ef35b27bd3c089787c` matched archive/installed | Still mapped the prior libmachook generation below |
| displayd / 222 | Main UUID `41b0f1d8c66f3dde917dda077645f90e`, text `dc97fe0126e0167257203c5175ff358527fd0934ccf308de6e6fa2f0e7e86b55` matched archive/installed | Still mapped the prior libmachook generation below |
| WindowServer / 99427 | Mapped prior arm64 libmachook UUID `213837045f0a31229cad6069105f913a`, text `3e56c2f614446546ae29d58268ef78cefbe7e2c09ec8bba30dfdd6787b25f39d` | Replacing the file did not update this live process |
| OSXvnc / 13078 | Mapped replacement libmachook UUID `208309ba53be3e0dab9643196f810071`, text `400b16249c1a684e862f2437ded18d3211e7b76b12e2f0eab5c3a81296fe54fa` matched replacement disk | Main executable UUID matched disk but text differed; its explicit delivery hooks modify executable instructions, so equality is not assumed |
| hostd / 92633 | Mapped UUID `8f1a531c1d9d37b5b747ed5a496019a8` matched installed UUID | UUID comparison only |
| autosignd / 90005 | Mapped UUID `38bb7d6ba3da341ca0bff693cccbac45` matched installed UUID | UUID comparison only |
| allocd / 438 | Installed bytes matched archive | `proc_pidpath` returned errno 2 despite a visible process record; mapped identity unverified |
| Compiler / 576, 78327 | Installed tweak UUID/text matched archive | Both returned `task_for_pid=5`; their mapped generations remain unverified |

The same prior libmachook UUID/text was read from inputd and displayd. The
fresh CoreImage request worker 13338 had already exited before identity
sampling (`proc_pidpath` errno 3); its request/adapter logs are a separate
witness, not evidence of a mapped hash. No protected-process permissions were
changed to bypass these limitations, and this audit performed no restart.

## Audit beyond the source flag inventory

The subsequent read-only installed-policy audit inspected 66 installed plists,
53 loaded jobs, 70 related running processes and 191 exact flag/legacy paths.
All 70 running-process environments were free of forbidden diagnostic keys,
and none of the 191 paths existed. This did **not** mean the installation was
clean: idle loaded jobs and old files were additional authorities that a
running-process-only audit would miss. The complete point-in-time receipt is
`/tmp/macws-installed-policy-audit-20260919.json` on the controlling Mac.

In particular, the unused system-launch-directory copy of locationd still set
`MACWS_LOCATIOND_MIG_TRACE=1`; the actual PID 268 and its generated GUI job
were clean. The old Chrome debug job was still registered in user/501 with:

```text
state = not running
MACWS_SUSPEND_AT_EXEC => 1
MACWS_JIT_MPROTECT_TRACE => 1
```

The exact historical locationd copy, sandbox-audit-probe and spaceprobe files
were subsequently archived outside the autoload trees. Their original bytes,
inode, owner and mode were preserved, just like the nine previously archived
outer boot jobs. The retirement helper verifies their observed SHA-256 values
before acting; an unknown revision fails without guessing its identity.
The final helper check reported `LEGACY-BOOT current`.

Four idle registrations were then independently revalidated against the exact
archived plist's label, program arguments and former path, `active count = 0`,
`state = not running`, and absence of a PID before explicit bootout:

- `user/501/com.macwsguide.chrome150`
- `user/501/UIKitApplication:com.macwsguide.chrome150`
- `user/501/com.macwsguide.rootdir-ios-probe`
- `user/501/com.macwsguide.steam`

Every bootout returned 0 and the subsequent print returned 113 (absent).
The current `UIKitApplication:com.macwsguide.steam` job was not targeted.
The raw before/after receipt is
`/tmp/macws-retired-idle-jobs-20260919.json`. No active application was killed.
Earlier, the same idle-state/identity discipline was used for the cpu-fp,
jitprobe and rootdir-macos-probe registrations. This is an upgrade cleanup,
not a feature gate or a general policy of unloading arbitrary jobs.

## Why isolated symptom fixes were insufficient

The failures do not all have one cause, and the flag migration is not proven
to have introduced every one. The reproducible shared-contract failures are:

| Broken boundary | Concrete evidence | Repair and acceptance boundary |
| --- | --- | --- |
| Producer/consumer deployment identity | Old Windowing published persistent readiness while new Host read `/tmp`; actual `bridge-not-loaded` and 1004x807 scene | Versioned live capability, source-bound cross-build and actual package checks; user accepted window sizes |
| Global runtime mutation across fork | Terminal child faulted on the executable page altered by the obsolete global superclass-auth patch | Remove obsolete runtime instruction rewrite; real native GPU then fork passes for both slices, real new Terminal tabs run shells |
| Coordinate units across input adapters | Fullscreen native point was converted twice before focus selection | Shared activation-record coordinate contract; two real drags retained the intended focused window |
| Shared GPU compiler target and old cache ABI | Actual CoreImage graph produced zero pixels; native AGX rejected the wrong target OS | Correct DAG producer target, preserve consumer checks, version recoverable caches; real CoreImage output and separate Preview visual tests |
| Inconsistent filesystem root across consumers | Preview FileCache finalization recursed to the stack guard; direct CF query passed while actual NSURL still returned the host volume | Shared chroot namespace contract covering CF and Foundation without executable-page hooks; see Preview evidence for exact candidate and UI results |
| Validation treated intermediate success as completion | Source/package equality did not imply a running process mapped it; automatic gate allowed pending manual checks | Separate automated outcome from release acceptance; reject stale test targets; require fresh mapped identity and visible output where accessible |

These are the reasons to test shared boundaries and representative consumers,
not to add more application-name exceptions or force success past an error.
The Weather Mission Control failure and sustained heat complaint remain
separate open acceptance items; no process-uptime result closes either one.
