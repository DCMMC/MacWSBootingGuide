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
