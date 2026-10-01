# MacWSBootingGuide

Run a Ventura macOS userspace, WindowServer, and macOS GUI applications on a
jailbroken Apple-silicon iPad.

MacWS is an experimental compatibility stack, not a VM and not a remote desktop
product. macOS arm64 code runs natively in a chroot while iPadOS continues to
own the kernel, AGX GPU, display, audio, input, power management, and app-window
lifecycle. The companion [macPad](https://github.com/DCMMC/macPad) project
presents macOS windows as iPadOS windows.

> [!WARNING]
> This is a controlled research beta. It uses private frameworks,
> version-specific binary adapters, jailbreak trustcache facilities, and a full
> macOS filesystem. A wrong build or stale artifact can crash SpringBoard or
> leave the GUI stack in a restart loop. Keep a recoverable backup and read
> [AGENTS.md](AGENTS.md) before adapting or debugging the project.

## Current status

| Device and system | Jailbreak | macOS userspace | Status |
| --- | --- | --- | --- |
| iPad13,6 (M1), iPadOS 16.3.1 / 20D67 | Dopamine rootless | Ventura 13.4 / 22F66 | Primary target; broadest display, input, IME, power, VS Code, Steam, Office, and system-app coverage |
| iPad14,5 (M2), iPadOS 16.0 / 20A8372 | Dopamine rootless | Ventura 13.4 / 22F66 | M2 compiler adapter, native display, audio, VS Code, Steam, and arm64 Unity 7DTD paths validated; coverage is narrower than M1 |
| iPad13,7, iPadOS 16.6 | NathanLR | Ventura experiment | Unsupported: the current CoreTrust/signing path cannot admit the patched macOS shared-cache closure |
| Any other device or build | unknown | unknown | A porting target, not a supported configuration |

The installer deliberately fails closed when the Dopamine-compatible
<code>/var/jb/usr/bin/jbctl</code> trustcache backend is unavailable. Do not
remove that check or replace a user's jailbreak to make installation appear to
succeed.

Current user-visible capabilities include:

- iPadOS window mode and a full Aqua workspace.
- Native IOSurface/Metal presentation, with a safe final-composite or
  exact-window fallback and strict direct-drawable acceleration.
- 80–120 Hz adaptive presentation on validated ProMotion hardware.
- Touch, pointer, window move/resize, Mission Control gestures, Magic Keyboard,
  software shortcuts, and iOS Chinese IME committed into the exact AppKit
  window.
- Clipboard, files, drag and drop, open/save panels, location, audio, Retina
  Standard/Larger UI modes, lock/sleep coordination, and bounded thermal
  telemetry.
- Scoped compatibility for apps including VS Code/Electron, Steam, Office, and
  selected macOS system apps.

These are versioned, evidence-backed paths—not a promise that every macOS app
or every iPad works. Stock Steam 7 Days to Die is x86_64 beyond its launcher and
cannot be made executable by an <code>oahd</code> cache alone on iPadOS 16. The
tested game path uses an exact arm64 Unity 2022.3.62f2 player. See the dated
[evidence](docs/evidence/) before quoting performance or compatibility.

## How it works

~~~text
macOS app / WindowServer inside the Ventura chroot
  ├─ libmachook compatibility and exact AppKit input
  ├─ final-composite or exact-window IOSurface stream
  └─ validated completed direct drawable when eligible
                         │
                         ▼
macwsdisplayd / macwsinputd / macwsinteropd
                         │
                         ▼
MacWSHost + MacWSWindowing on iPadOS
  ├─ native Metal presentation
  ├─ one macOS window per UIWindowScene
  └─ UIKit touch, keyboard, IME, Stage Manager and lifecycle
~~~

Every supported app retains the composited IOSurface path. Direct drawables are
an optimization only when producer identity, owner, geometry, sequence, and GPU
completion all match. Resize or ownership changes invalidate the direct path
before fallback. Streams retain bounded latest state rather than an unbounded
frame queue.

The production target is the real iOS AGX driver. <code>MTLSimDriverHost</code>
is retained for legacy diagnostics and is not the preferred rendering path.
VNC is likewise a diagnostic/recovery observer, not the normal presentation
transport.

Architecture details:

- [Current architecture](docs/code-architecture-20260812.md)
- [Display and iPadOS host design](docs/displaystream-host-architecture.md)
- [Production-readiness boundaries](docs/production-readiness-20260912.md)
- [Metal-to-Metal profiles](docs/metal2metal.md)
- [Runtime switches](docs/runtime-switches.md)
- [Historical AGX milestones](docs/agx-native-milestones.md)

## Before you begin

You need:

- A supported Dopamine rootless device, or a separate test device you are
  prepared to port.
- SSH access, Procursus tools, <code>ldid</code>,
  <code>/var/jb/usr/bin/jbctl</code>, and enough free local storage.
- Theos at <code>/var/jb/var/mobile/theos</code> for on-device builds, or a
  working macOS cross-build setup.
- A legally obtained Ventura 13.4 / 22F66 filesystem from hardware or media you
  are entitled to use.
- For legacy simulator diagnostics only:
  <code>MTLSimDriver.framework</code>,
  <code>MTLSimImplementation.framework</code>, and
  <code>MetalSerializer.framework</code> from the matching Simulator runtime.
- A backup and a second SSH path if possible.

Apple binaries, macOS images, third-party applications, and game assets are not
included and must not be committed to this repository.

### Transfer a large rootfs safely

Keep the archive compressed while it is on a NAS. Transfer it directly to
device-local or suitable SSD-backed storage with rsync 3.x resumability,
verify its hash, then extract there. Do not unpack millions of small files on
a slow archive disk merely to send them again. Apple's bundled openrsync 2.6.9
does not support the command below; install a current rsync first.

~~~bash
rsync -a --partial --append-verify --info=progress2 \
  -e 'ssh -p <SSH_PORT>' \
  /path/to/ventura-rootfs.tar.zst \
  mobile@<DEVICE>:/path/with/enough/device-local-space/

shasum -a 256 /path/to/ventura-rootfs.tar.zst
ssh -p <SSH_PORT> mobile@<DEVICE> \
  'sha256sum /path/with/enough/device-local-space/ventura-rootfs.tar.zst'
~~~

The two hashes must match. Mount or prepare the target at
<code>/var/mnt/rootfs</code>, extract once on the device, then create the
Ventura Data/cryptex layout required by this project. The historical manual
layout notes remain in [AGENTS.md](AGENTS.md); exact automated setup still
depends on the source image and target build. Never copy an existing live
rootfs over an active WindowServer session.

## Build and deploy

First clone this source on the build Mac and on the device. Use placeholders or
environment variables for addresses and credentials; never save passwords in
scripts or Git.

### On-device build

~~~bash
ssh -p <SSH_PORT> mobile@<DEVICE> \
  'THEOS=/var/jb/var/mobile/theos \
   bash /var/jb/var/mobile/MacWSBootingGuide/misc/build_on_ios.sh'
~~~

The build script performs the package/install flow, platform-version repair,
signing, trustcache registration, and post-install synchronization. The
SpringBoard <code>MacWSWindowing</code> artifact has stricter arm64e/PAC
requirements: production packages must use the validated Apple-ld64 cross-build
artifact, not an apparently successful on-device lld substitute.

### Cross-build from macOS

~~~bash
gmake FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless package install \
  THEOS_DEVICE_IP=<DEVICE> THEOS_DEVICE_PORT=<SSH_PORT> \
  GO_EASY_ON_ME=1
~~~

After installation:

~~~bash
ssh -p <SSH_PORT> mobile@<DEVICE> \
  'sudo bash /var/jb/usr/macOS/bin/postinst.sh'
~~~

### Incremental development pipeline

Use the content-verified pipeline instead of overwriting installed signed
dylibs in place:

~~~bash
export MACWS_DEVICE=mobile@<DEVICE>
export MACWS_DEVICE_PORT=<SSH_PORT>

bash misc/device_pipeline.sh --sync-only
bash misc/device_pipeline.sh --component input
bash misc/device_pipeline.sh --component host --restart-workspace
bash misc/device_pipeline.sh --component full --restart-workspace
~~~

Supported component names are <code>runtime</code>, <code>display</code>,
<code>input</code>, <code>workspace</code>, <code>host</code>,
<code>hostd</code>, <code>compiler</code>, <code>libmachook</code>,
<code>metal</code>, and <code>full</code>. If
<code>MACWS_SUDO_PASSWORD</code> is unset, the script asks through an
interactive SSH session without writing it to disk.

Do not <code>scp</code> over a live signed dylib. Reusing its vnode can leave
the kernel code-signature cache attached to stale bytes. The pipeline stages
and installs fresh artifacts, validates hashes, and can restart the affected
workspace.

## Run and recover

Run these commands from the iOS shell, not from inside the chroot:

~~~bash
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh status
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh restart coexist
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh stop
~~~

Enter a CLI-only macOS shell:

~~~bash
sudo bash /var/jb/usr/macOS/bin/run_bash.sh
~~~

For non-interactive commands, set a macOS PATH explicitly so the chroot does not
accidentally execute iOS Procursus binaries:

~~~bash
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c \
  'export PATH=/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; echo hello'
~~~

The harmless <code>chdir: No such file or directory</code> message can appear
before output.

If the GUI enters a crash loop or a profiler/debug process is left running,
stop the whole stack before restarting it:

~~~bash
sudo bash /var/jb/var/mobile/MacWSBootingGuide/misc/cleanup_all.sh
~~~

This returns control to iPadOS and unloads project jobs. Do not repeatedly
restart WindowServer while it is already looping.

## Test and profile

Run focused tests for the subsystem you change, followed by the full contract
suite when feasible:

~~~bash
python3 -m unittest discover -s misc -p 'test_*.py'
python3 misc/audit_runtime_switches.py
clang -std=c11 -Wall -Wextra -Iinclude misc/macws_protocol_test.c \
  -o /tmp/macws_protocol_test
/tmp/macws_protocol_test
git diff --check
~~~

For frame pacing, heat, power, or memory work, use the existing profiling
helpers rather than judging only by feel:

~~~bash
python3 misc/macws_ui_profile.py --help
python3 misc/macws_frame_power_profile.py --help
# On the iOS shell: sample for 10 minutes at a 30-second interval.
bash misc/macws_power_memory_probe.sh 600 30
~~~

Use the same workload, duration, charge state, and starting thermal state for
A/B runs. Record producer, receipt, submit, completion, and panel-tick cadence.
Close TestUFO, Aquarium, video, and other benchmark tabs after each run;
multiple hidden pages are real GPU/CPU load.

Process uptime is not an acceptance witness. Require visible pixels, advancing
sequences, a completed protocol response, delivered input, an audio callback,
or the corresponding real endpoint.

## Porting with Codex or another coding agent

The repository includes an authoritative [AGENTS.md](AGENTS.md). It contains
the current compatibility matrix, architecture, hard-won rejected approaches,
build/deploy rules, evidence standards, and subsystem-specific invariants.
<code>CLAUDE.md</code> points to the same file so different agents do not drift.

A good first prompt is:

> Read AGENTS.md completely. Treat this device/build as an unverified port.
> Begin with read-only inventory of hardware, iPadOS/macOS builds, jailbreak
> trust backend, target Mach-O UUIDs/hashes, free space, rootfs, and the current
> runtime state. Reproduce one bounded failure, label FACT versus THEORY, and do
> not patch until the failing invariant is supported by exact-binary disassembly
> or a copied runtime witness. Add a narrow fail-closed fix, tests, dated
> evidence, device acceptance, cleanup, and synchronize both repositories.

For each port or feature:

1. Record exact device, OS/build, jailbreak, rootfs, binary UUIDs, hashes, and
   architectures before mutation.
2. Capture a bounded baseline and remove duplicate apps, benchmark tabs, log
   tails, samplers, and debugger leftovers.
3. Trace the invalid state upstream to its producer. A NOP, forced branch,
   blanket constant return, skipped assert, or zero-filled fake object is a
   diagnostic scaffold—not a fix.
4. Reverse-engineer the exact binary involved. Unknown UUIDs or instruction
   identities must fail closed.
5. Change one variable, add a focused regression test, and preserve rejected
   hypotheses in a dated file under [docs/evidence](docs/evidence/).
6. Build every affected architecture, deploy through the verified pipeline,
   accept on the real user-visible/protocol endpoint, and recheck crash and
   thermal state.
7. Keep shared source and documentation synchronized with
   [macPad](https://github.com/DCMMC/macPad); commit and push each repository
   separately.

Never paste passwords, private keys, public addresses, NAS credentials, or
user-specific hostnames into an agent prompt that will be committed. Prefer
temporary environment variables and redact runtime logs before publishing.

## Development rules that prevent false fixes

- A stopped crash is not proof of correctness. Verify frames, input, audio, or
  the actual protocol output.
- Do not bypass assertions or validation globally. Fix the upstream producer or
  explicitly label the code diagnostic-only and default-off.
- Do not special-case an app bundle when a route, capability, ABI, geometry, or
  ownership rule explains the behavior.
- Do not lower FPS first to hide heat. Measure duplicate work, blocking paths,
  lease counts, occlusion, and completion cadence.
- Preserve the universal composited fallback. Direct-drawable acceleration
  cannot become a requirement for app correctness.
- Keep queues and retained surfaces bounded. Slow consumers drop obsolete state
  rather than accumulating work.
- Do not publish new compatibility or performance claims without dated
  device-side evidence.

## Repository map

| Path | Purpose |
| --- | --- |
| <code>MacWSHost/</code> | iOS Scene UI, Metal presentation, gestures, keyboard/IME, performance telemetry |
| <code>MacWSWindowing/</code> | SpringBoard and Stage Manager integration |
| <code>libmachook/</code> | Injected macOS compatibility, Metal, AppKit input, and execution hooks |
| <code>macwsdisplayd/</code> | Authenticated IOSurface/final-composite receive boundary |
| <code>macwsinputd/</code> | Versioned input transport |
| <code>macwsinteropd/</code> | Clipboard, file, and drag interoperability |
| <code>macwshostd/</code> | Trusted lifecycle, launch, sleep, and recovery control |
| <code>macwsaudiooutd/</code> | iOS-native output for the shared PCM ring |
| <code>MTLCompilerBypassOSCheck/</code> | Exact-identity Metal compiler request adapter |
| <code>misc/</code> | Build/deploy scripts, profilers, probes, and contract tests |
| <code>docs/evidence/</code> | Dated runtime and reverse-engineering evidence |

## Reporting an issue

Include the exact device model, iPadOS version and build, jailbreak/version,
macOS version/build, repository commit, changed runtime switches, reproduction
steps, the smallest relevant log/crash excerpt, and whether visible output or
the protocol endpoint advanced. State explicitly whether each explanation is a
runtime/RE-confirmed fact or a theory.

Remove credentials and personal paths. Do not attach Apple binaries, an IPSW,
a macOS rootfs, commercial app assets, or game data.

## Credits

- [khanhduytran0/MacWSBootingGuide](https://github.com/khanhduytran0/MacWSBootingGuide)
- [zhuowei/iOS-run-macOS-executables-tools](https://github.com/zhuowei/iOS-run-macOS-executables-tools)
- [SongXiaoXi/Reductant](https://github.com/SongXiaoXi/Reductant)
- [Asahi Linux](https://asahilinux.org/)
