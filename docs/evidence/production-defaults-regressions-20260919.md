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
