# Third-party application installation smoke test (2026-08-10)

This milestone records the installation and signing work for CleanMyMac X,
Microsoft Office, and Valheim.  GUI validation is deliberately **not** marked
complete here: the iPad stopped answering the LAN during the second CleanMyMac
launch, so visible and interactive witnesses for all three applications are
still required after the device is reachable again.

## Installed payloads

| Application | Installed path | Version | Installed/signing witness |
|---|---|---:|---|
| CleanMyMac X | `/Applications/CleanMyMac X.app` | 4.15.8 | final scanner: `newly-trusted=0 already-trusted=140` |
| Microsoft Word | `/Applications/Microsoft Word.app` | 16.91.24111020 | final scanner: `newly-trusted=0 already-trusted=199` |
| Microsoft Excel | `/Applications/Microsoft Excel.app` | 16.91.24111020 | final scanner: `newly-trusted=0 already-trusted=193` |
| Microsoft PowerPoint | `/Applications/Microsoft PowerPoint.app` | 16.91.24111020 | final scanner: `newly-trusted=0 already-trusted=176` |
| Microsoft OneNote | `/Applications/Microsoft OneNote.app` | 16.91.24111020 | final scanner: `newly-trusted=0 already-trusted=124` |
| Microsoft Outlook | `/Applications/Microsoft Outlook.app` | 16.91.24111020 | final scanner: `newly-trusted=0 already-trusted=218` |
| Valheim | `/Applications/Valheim.app` | 0.220.5 | final scanner: `newly-trusted=2 already-trusted=20`; the two newly found mode-0644 images were `libDiskSpacePlugin.dylib` and `PlayFabPartyMacOS` |

The Microsoft package payloads were installed without OneDrive or Defender.
The exact choices file is `misc/office-core-no-cloud-choices.xml`.  Microsoft
DFonts, Frameworks and Proofing Tools postinstall logs each reported zero
`Error copying` / `Not installing` matches after the private macOS cfprefsd
contracts were published.

The Valheim DMG had SHA-256
`d66721967fad14c0ee9e791639162969d0e739266af90af0c99577c5cc9292e1` on
both the Mac and iPad.  Its extracted main executable had SHA-256
`5947131a93a251844e8231c0e4031c31055405697f04fdb9ddf3ff3777ae0a59`.

## Cold-boot trust closure bug

The old signing and postinstall scans treated the executable permission bit as
the code predicate.  Runtime inspection of Valheim 0.220.5 disproved that
assumption:
`Contents/PlugIns/PlayFabPartyMacOS.bundle/Contents/MacOS/PlayFabPartyMacOS`
is a 57 MB universal Mach-O shipped with mode 0644.  Office demonstrated the
opposite problem by marking thousands of non-code resources executable.

`sign_installed.sh` and `postinst.sh` now inspect the first four bytes of every
regular file in one Python walk and emit only Mach-O/fat images.  The scripts
also read Dopamine's real trustcache inventory with `jbctl trustcache info`;
the target's `jbctl trustcache list` returned an empty result.

## CleanMyMac launch failure and root fix

The first production `launch-path` attempt began at `04:07:49.8099` and was
reported by macwshostd at `04:07:53.287` as terminated by signal 11 before an
AppKit window was published.

Runtime evidence is the on-device report:

`/var/mobile/Library/Logs/CrashReporter/CleanMyMac X-2026-08-10-040810.ips`

It records `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE` at the main-thread stack
guard (`0x16bc5ff60`).  The triggered thread contains 511 frames alternating
between CleanMyMac's `macked.app.dylib` and
`libmachook_arm64.dylib!sysctlbyname_new` at `mac_hooks.m:8567`.  This
runtime-confirms recursion in the compatibility interpose: it called
`sysctlbyname` by name and rebound to itself.

The interpose now resolves the name with `sysctlnametomib` and invokes the
lower-level `sysctl` wrapper, retaining the real kernel result and the existing
macOS product-version translation.  An on-device FAST production build for
both arm64 and arm64e completed and installed successfully.  A second launch
outlived the original 3.48-second failure window, but the iPad then disappeared
from the LAN.  No causal claim is made for that loss until crash, panic,
thermal, and watchdog logs can be collected.

## Remaining acceptance witnesses

- a visible Retina frame and repeatable input action for each application;
- Word document create/type/save/reopen (and launch coverage for the other
  Office applications);
- Valheim title/menu rendering through native AGX and a sampled interactive
  frame rate;
- device versus M1 MacBook Air launch/interaction comparison at a comparable
  resolution and quality setting;
- post-test crash-log and Critical-only thermal-watchdog audit.
