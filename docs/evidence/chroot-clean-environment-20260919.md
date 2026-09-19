# Namespace metadata lost by a clean child environment, 2026-09-19

## Scope and actual control

This production boundary defect was **not fixed** by the new ViewBridge
root-environment producer alone. The isolated candidate acceptance below now
establishes a repair; it does not claim publication to canonical paths or
mapping by already running applications. Two parent-authorized read-only
probes ran through the ordinary installed `run_bash.sh` on the iPad. Both used
the already present `/tmp/macws-namespace-sendfile-arm64-20260919` executable
and existing `/System/Library/CoreServices/SystemVersion.plist`; no fixture,
Metal operation, application restart, service change, or UI input was needed.
The probe has its own eight-second alarm; each command finished in about one
second. It queries statfs/fstatfs, file IDs, and actual CF/NSURL properties.

The ordinary inherited-environment command was:

```sh
bash /var/jb/usr/macOS/bin/run_bash.sh -c 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin; /tmp/macws-namespace-sendfile-arm64-20260919 /System/Library/CoreServices/SystemVersion.plist'
```

Runtime-confirmed stdout, PID 26244, exit 0:

```text
foundation-root-values parent=<nil> volume=file:///
foundation result=1 volume=/ error-domain=<none> error-code=0
resource-protocols ns-bulk=1 cf-bulk=1 promised-single=1 promised-bulk=1 bridged-url=1
namespace pid=26244 statfs=/ fstatfs=/ root-fileid=/ fileid-matches=1 root-parent-nil=1 cf-volume-root=1 ns-volume-root=1 result=PASS
namespace fork-child-reached-main
foundation-root-values parent=<nil> volume=file:///
foundation result=1 volume=/ error-domain=<none> error-code=0
resource-protocols ns-bulk=1 cf-bulk=1 promised-single=1 promised-bulk=1 bridged-url=1
namespace pid=26244 statfs=/ fstatfs=/ root-fileid=/ fileid-matches=1 root-parent-nil=1 cf-volume-root=1 ns-volume-root=1 result=PASS
namespace-after-fork child=26254 status=0 result=PASS
```

The negative command preserves the required executable search path and hook
library, but deliberately supplies no MacWS root metadata:

```sh
bash /var/jb/usr/macOS/bin/run_bash.sh -c 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin; /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook_arm64.dylib /tmp/macws-namespace-sendfile-arm64-20260919 /System/Library/CoreServices/SystemVersion.plist'
```

Runtime-confirmed stdout, PID 26276, exit 1:

```text
foundation-root-values parent=file:///private/var/mnt/ volume=file:///
foundation result=1 volume=/ error-domain=<none> error-code=0
resource-protocols ns-bulk=0 cf-bulk=0 promised-single=1 promised-bulk=0 bridged-url=1
namespace pid=26276 statfs=/private/var fstatfs=/private/var root-fileid=/ fileid-matches=0 root-parent-nil=0 cf-volume-root=1 ns-volume-root=1 result=FAIL
```

The actual root parent escapes to `/private/var/mnt/`, and the mount point
reverts to the host mount. This is not merely a missing environment key or a
synthetic failure code. The single volume query still returns `/`; that
passing sub-result does not imply a coherent complete resource protocol.
The old `fileid-matches=0` field is **not valid evidence of a path mismatch**:
the probe combined an earlier failing mount check and `realpath` in one
short-circuited expression, so `canonical` was never populated. The probe
source now evaluates that independent query unconditionally. Root-parent and
mount observations above are unaffected; both were computed independently.

## Source boundary and next discriminating check

Source-confirmed: `exec_hooks.c`'s `env_select_insert` copies the supplied
environment and selects the architecture-correct inserted library, but does
not restore kernel namespace identity. `Metal_hooks.x`'s
`macws_initialize_chroot_mount_namespace` exits early when
`MACWS_CHROOT_HOST_ROOT` is missing. `env -i` therefore reaches a real
unrepaired namespace even though the hook library remains injected.

Do not fix this by assuming `/private/var/mnt/rootfs`, enabling a debug flag,
or adding an application allowlist. Also, the negative probe still prints
`root-fileid=/`: obtaining a root file ID and calling fsgetpath alone has not
been shown to recover the host root path on this device.

Preferred candidate (not yet implemented or accepted): query the current
process's kernel root vnode using the existing libproc
PROC_PIDVNODEPATHINFO contract. The repository's Metal-cache migrator already
uses this ABI to identify chroot clients from outside them. A bounded
same-process query from a clean-env chroot client is still required to prove
that the host path is available there; validate complete record length,
termination, root identity, and native non-chroot controls before using it.
The alternate producer repair would export cached verified root metadata
through exec, not reread an environment that `env -i` has already erased, but
that alone does not cover a first injected process lacking launch metadata.

## Kernel self-root witness and raw path control

The next parent-authorized experiment used a tiny C executable, not the
currently unreliable Python installation. No Metal, GUI, service changes,
user files, or process attachment were involved. The same source was locally
compiled for arm64 iOS and macOS. Host SDK `_Static_assert`s established the
actual Apple `proc_vnodepathinfo` size 2352 and the root vnode's dev/inode/fsid/
path offsets 1176/1184/1320/1328 before the iOS build (whose SDK omits that
private header). Each executable queried only its own 2352-byte record and
stat metadata under an eight-second alarm. New signed/admitted artifacts live
only in the owned temporary directories:

- iOS `/tmp/macws-self-root-20260919.xx33lE/`
- chroot `/tmp/macws-self-root-20260919.9s04Y9/`

Native iOS control, no library insertion, PID 27575, exit 0:

```text
self-root pid=27575 metadata=<absent> proc-bytes=2352 errno=0 stat=0 stat-dev=838860801 stat-inode=2
self-root vnode-dev=0 vnode-inode=0 fsid=0,0 terminated=1 path= identity-match=0
raw-path input=/ fsid=838860801,26 inode=2 return=2 path=/
raw-path input=/System/Library/CoreServices/SystemVersion.plist fsid=838860801,26 inode=1152921500312014935 return=49 path=/System/Library/CoreServices/SystemVersion.plist
```

Clean-env chroot, using the newly published canonical library, PID 27584,
exit 0:

```text
mapped-image=/usr/local/lib/libmachook_arm64.dylib UUID=DC73423CA25A3231B3D5E8F1A4F627FB
self-root pid=27584 metadata=<absent> proc-bytes=2352 errno=0 stat=0 stat-dev=16777223 stat-inode=22434439
self-root vnode-dev=16777223 vnode-inode=22434439 fsid=16777223,26 terminated=1 path=/ identity-match=1
raw-path input=/ fsid=16777223,26 inode=22434439 return=2 path=/
raw-path input=/System/Library/CoreServices/SystemVersion.plist fsid=16777223,26 inode=23357312 return=49 path=/System/Library/CoreServices/SystemVersion.plist
```

The raw path control calls BSD syscall 427 directly, using the matching
SYS_fsgetpath value from both actual SDKs and the checked carry-return ABI.
It does not accidentally retest an interposed symbol. The result disproves
the proposed use of root fsgetpath to discover a host prefix: it already
returns the correct process-visible `/`. Likewise, querying one's own kernel
root vnode returns `/`, not the externally observed host path. But that
record does supply a nonzero root vnode whose dev/inode/fsid match the real
process root, while both native iOS and native macOS controls have an empty
root-vnode record. It therefore supports automatic **identity-based**
namespace initialization without inventing a host-prefix string.

Minimal proposed repair at this stage of the investigation:
validate the complete self-root record against actual root stat/statfs once
per process; enable the coherent statfs/CF/NSURL root protocol for that
verified chroot identity, independently of inherited environment metadata.
Keep native empty-rdir processes unchanged and retain host-prefix rewriting
as a separately guarded operation only when a real prefix is available. No
new application list, production opt-in, or per-query root inspection is
needed. Final acceptance must rerun the clean-env negative case, inherited
case, and native controls against the actual candidate.

## Implemented candidate and exact acceptance

`macws_chroot_identity.h` validates the complete versioned kernel record,
directory mode, nonzero device/inode/fsid, terminated absolute root path, and
identity equality with current `/` stat/statfs. Empty native rdir and partial,
failed, malformed or mismatched records never enable compatibility. The host
SDK's formal struct definitions statically verify the ABI offsets; the header
also compiles with the actual iPhoneOS16.5 SDK that omits the private header.

`Metal_hooks.x` caches this identity once per process with `dispatch_once`.
The block uses only stat/statfs/proc_pidinfo and C data handling, not CF,
notifications, or method installation, so an early distributed-notification
call can initialize identity without recursively invoking CF. Both namespace
initialization and the existing single-name distributed-notification mapping
consume this same cached identity. There is no new marker, environment opt-in,
application list, per-frame scan, or success fallback on a failed query.

The optional host prefix is kept only for the existing guarded fsgetpath path
translation. Invalid/absent prefix metadata no longer disables the actual
namespace protocol. The existing `f_mntonname == "/"` early return for mount
rebasing is retained: these runtime tests concern the established target
mount `/private/var`, not every possible chroot topology. Consumer search
found the two enable guards above; launchdchrootexec, ViewBridge and Steam's
child-overlay producer supply metadata rather than selecting compatibility.

The candidate was built locally with Apple ld64 in a separate object directory
(`kernel-root-20260919`), split, macOS-tagged, signed/admitted, and staged only
in the owned chroot temporary directory above. A small iOS launcher passes
an explicit environment directly through chroot + SETEXEC so the ordinary
canonical slice selector cannot accidentally inject a second library into
an isolated candidate. Every real probe prints its mapped image UUID:

| Slice | Candidate UUID | Clean env PID | Inherited metadata PID | Invalid prefix PID |
| --- | --- | --- | --- | --- |
| arm64 | E569F15E-EAD9-349D-BFBC-3F92E896D327 | 28985 | 29047 | 29052 |
| arm64e | 6184F3A0-0330-3214-AA72-C8A2EBD13CB0 | 29061 | 29065 | 29069 |

All six freshly launched candidates exited 0. Each printed all resource
protocols as 1, root parent nil, statfs/fstatfs `/`, matching file paths, and
PASS both before and after a reaped successful fork child. Clean environments
contained only PATH and DYLD_INSERT_LIBRARIES, and reported metadata absent.
Inherited metadata was `/private/var/mnt/rootfs`; invalid metadata was
`relative/../bad`. The arm64 clean candidate's principal output was:

```text
namespace launch metadata=<absent>
namespace mapped-image=/private/tmp/macws-self-root-20260919.9s04Y9/libmachook-kernel-root-arm64-20260919.dylib UUID=E569F15EEAD9349DBFBC3F92E896D327
foundation-root-values parent=<nil> volume=file:///
resource-protocols ns-bulk=1 cf-bulk=1 promised-single=1 promised-bulk=1 bridged-url=1
namespace pid=28985 statfs=/ fstatfs=/ root-fileid=/ fileid-matches=1 root-parent-nil=1 cf-volume-root=1 ns-volume-root=1 result=PASS
namespace-after-fork child=28987 status=0 result=PASS
```

The identical corrected witness was rerun against the unchanged canonical
library, proving the negative remains discriminating:

```text
namespace launch metadata=<absent>
namespace mapped-image=/usr/local/lib/libmachook_arm64.dylib UUID=DC73423CA25A3231B3D5E8F1A4F627FB
foundation-root-values parent=file:///private/var/mnt/ volume=file:///
resource-protocols ns-bulk=0 cf-bulk=0 promised-single=1 promised-bulk=0 bridged-url=1
namespace pid=29095 statfs=/private/var fstatfs=/private/var root-fileid=/ fileid-matches=1 root-parent-nil=0 cf-volume-root=1 ns-volume-root=1 result=FAIL
```

Native iOS control PID 28982, without a compatibility library, exercised the
same real CF/NSURL protocols and fork witness and passed with no metadata.
No system distributed notification was posted during these probes; the
notification mapper is instead executed directly by the local source fixture
with controlled center/name inputs, checking private-name mapping for verified
chroot identity, unchanged names for native/unrelated cases, and one root
inspection across repeated calls.

Eighteen focused host tests passed (namespace, proxy environment, sendfile,
success logging and diagnostic hot-path suites). `git diff --check` passed.
These results do not claim QuickLook thumbnails, Office content, or arbitrary
already running applications were repaired. No user application, service,
canonical library, GUI session, or document was restarted or overwritten.
