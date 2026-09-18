# Preview namespace diagnosis, 2026-09-19

Only `/tmp/macws-preview-acceptance-20260919.pdf` inside the rootfs was opened.
The original `/var/root/cs336_spring2025_assignment2_systems.pdf` was not edited.
No SpringBoard or global service restart was performed. Initial probes used
separate candidate libraries; the final, visually accepted artifact was later
installed through the verified new-inode procedure recorded below.

## Actual fault, before a UI gesture

Two isolated Preview launches with the existing production library failed
without any input. On-device LLDB captured PID 17356, thread 7,
`NSPersistentUI Encoding (QOS: UNSPECIFIED)`:

```
EXC_BAD_ACCESS (code=2, address=0x16fa8bfd0)
pc = 0x1974795b8 _FileCacheReleaseContents + 4
lr = 0x197459d00 _FileCacheFinalize + 76
sp = 0x16fa8c010
stp x24, x23, [sp, #-0x40]!
```

The 48-frame bounded backtrace repeats this seven-frame cycle:

```
_FileCacheReleaseContents
_FileCacheFinalize
_CFRelease
__CFURLDeallocate
_CFRelease
__CFBasicHashDrain
_CFRelease
```

This proves recursive cache finalization reaching the stack guard. It is not
evidence that a pen stroke or a GPU instruction caused the first failure.
The shell's later `Illegal instruction: 4` is not the first fault. The complete
local transcript is `/tmp/macws-preview-sigill-lldb2-20260919.log`.

## Namespace A/B and independent diagnostic crash

PID 17619 was launched with the same document and the legacy process-local
`MACWS_APP_MOUNT_COMPAT=1` plus mount tracing. The running library reported:

```
APP-MOUNT volume namespace rebase process=Preview input=/tmp/macws-preview-acceptance-20260919.pdf hostVolume=/private/var visibleVolume=/ fsid=(16777219,26)
APP-MOUNT process root has no parent process=Preview fsid=(16777219,26)
```

The process progressed through showing Markup but later aborted when the
diagnostic window-metrics publisher queried an optional selector:

```
-[NSPopoverFrame resizeIncrements]: unrecognized selector sent to instance
MacWSPublishWindowMetrics + 2112
__MacWSScheduleWindowMetricsPublish_block_invoke + 28
```

The optional query was inside the runtime-diagnostics branch, not the
production constraint path. This A/B is **not** a successful pen-rendering
acceptance result. The complete local transcript is
`/tmp/macws-preview-mount-ab-20260919.log`.

## Static CF interpose alone is insufficient

The first namespace candidate used static interposes for statfs, fstatfs,
fsgetpath, and `CFURLCopyResourcePropertyForKey`. It removed the process
allowlist and derived the namespace from the real chroot metadata/root fsid.
It was deployed only to a distinct `/tmp` dylib, not the canonical library.

The bounded native probe PID 19680 reported:

```
foundation result=1 volume=/private/var error-domain=<none> error-code=0
namespace pid=19680 statfs=/ fstatfs=/ root-fileid=/ fileid-matches=1 root-parent-nil=1 cf-volume-root=1 ns-volume-root=0 result=FAIL
```

Reading at most 256 bytes from the probe's own actual NSURL method established
the reason, not a theory about caching:

```
-[NSURL getResourceValue:forKey:error:] = CoreFoundation + 0x68f5c
method + 0x50: bl __CFURLBeginResourcePropertyCacheAccess
method + 0x64: bl CFURLCopyResourcePropertyForKey (CoreFoundation + 0x53fc0)
method + 0x70: bl __CFURLEndResourcePropertyCacheAccess
```

The NSURL implementation calls the CF provider through a same-image direct
branch, so dyld's public-symbol interpose does not cover this call. A passing
direct-CF probe cannot establish the Foundation consumer contract. The
candidate must cover this actual boundary and pass both NSURL and CF queries,
the native-Metal-to-fork smoke for both slices, and real Preview interaction
before installation or any claim of completion.

## Corrected protocol candidate: native non-UI checks

The second candidate keeps the public CF single/bulk APIs as static
interposes and adapts NSURL's actual single/bulk and promised-item methods by
changing runtime IMP data, not shared executable code. Only the real chroot
root and same-filesystem leaked host-volume properties change. Other values,
provider errors and API ownership remain native. Native macOS was also queried
to establish that the root's parent is nil and omitted from bulk dictionaries.

The isolated Apple-ld64 build has `Metal_hooks.x` SHA-256
`6d3987ad7a95b56bba91b0e75829ee572d38a65c70ab63a633c3bbdcbd3ae501`.
No `MACWS_APP_MOUNT_COMPAT` or diagnostic feature opt-in was supplied. Both
arm64e PID 21562 and arm64 PID 21567 passed statfs, fstatfs, root/document
fsgetpath, CF/NSURL single and bulk queries, promised-item queries and the
CF-bridged NSURL path. Each returned from fork in an async-signal-safe child;
the parent repeated the complete metadata query successfully. Both actual SSH
exit statuses were zero, not inferred from a later `tail` command.

The separate native-Metal/fork smoke also passed for arm64e PID 21577 and
arm64 PID 21581: real Apple M1 device, command status 4, BGRA readback
`191,128,64,255`, child exit 0, unchanged superclass-auth instruction
`0xdac11a30`, and actual SSH exit status zero. The artifact receipt is
`/tmp/macws-namespace-candidate-6d3987.json` on the controlling Mac.

These are **not yet** a Preview visual/pen acceptance result, nor proof that
every production process has loaded the candidate. Canonical production
libraries were not replaced during these checks.

## GUI lifetime must be measured independently of SSH

The candidate Preview PID 21823 displayed the test PDF and Markup toolbar but
disappeared before the next injected pointer event. Its SSH session returned
255, without an app crash report or an application exit-status witness. That
result does **not** establish a crash in the candidate, and must not be counted
as a repeat of the earlier LLDB-confirmed FileCache failure.

The isolated launcher's full source and actual imported symbols contain no
alarm, timer or signal handler; it only chroots, sets launch data and performs
`POSIX_SPAWN_SETEXEC`. Its deployed SHA-256 is
`08fa0935eed6b07fc40e4f3ffcd8280f189cf5f8d4d9ca29fa5664a733d4e865`.
For the next launch, a separate native iOS parent detached from the SSH session
and used `waitpid` to record the actual child exit/signal. This observer sets no
alarm, resets the child's inherited signal defaults and observes for at most
180 seconds; it never kills the child on deadline. Its log is
`/tmp/macws-preview-wait-witness-20260919.log` on the iPad. No change to the
application's signal handler, error handling or production behavior is made.

The resulting Preview PID 28300 loaded the exact candidate: a bounded,
non-suspending memory read verified UUID
`7C247FAD-482D-31F4-9008-04B4D4FC060C` and runtime `__text` SHA-256
`09f2f1f4c0e218ab6fca29b7f0aa4541362338a76a2ec1a186b337cc47a59646`.
Its lifetime and visual output are separate acceptance checks; pending results
must not be described as a production fix.

The detached observer completed with:

```
observation-ended child=28300 elapsed=180.100 still-running=yes action=none
```

A subsequent `ps` showed the same Preview PID alive at 3 minutes 13 seconds,
now parented by PID 1. There was no child exit or signal during the bounded
`waitpid` observation. This rules out treating the earlier SSH 255 as a
reproduced candidate crash; it does not prove why that SSH session ended or
replace visual acceptance. The only application log warning in this interval
was an `NSFileVersion` missing-backup-file error for the disposable test PDF's
`~.pdf` path, after which the process remained alive.

## Actual drawing, zoom, save and reopen acceptance

The controlling agent exercised real Preview UI on PID 28300, not a synthetic
rendering probe. A new green stroke appeared above the document heading while
the original annotations remained visible. It stayed visible while zooming
in, zooming out and reducing the page size. After deselection and the real
Save action, the selection handles/popover and the title's Edited indicator
were gone; both the new stroke and original annotations remained visible at
high zoom. Full iPadOS captures were inspected:

- `/tmp/macws-preview-detached-stroke.png`
- `/tmp/macws-preview-detached-zoom-in.png`
- `/tmp/macws-preview-detached-zoom-out.png`
- `/tmp/macws-preview-detached-smaller.png`
- `/tmp/macws-preview-detached-saved-deselected.png`
- `/tmp/macws-preview-detached-highzoom.png`

After the real Quit action exited PID 28300, the same saved test PDF was
reopened as PID 34613, native window 369. The new stroke persisted, the title
was not Edited, and the originals remained visible in the inspected capture
`/tmp/macws-preview-saved-reopened.png`. The second real Quit was witnessed
independently by its native parent:

```
wait-result child=34613 elapsed=65.740 raw-status=0 exited=1 exit-code=0 signaled=0 signal=-1 core=0
```

## Exact canonical installation and fresh production consumers

Only after that visual/save/reopen acceptance, the two already tested signed
slices were installed at both canonical library directories:
`/var/jb/usr/macOS/lib` and `/var/mnt/rootfs/usr/local/lib`. All four old files
were hash-checked first; each candidate was staged and fsynced in its target
directory, and each old inode was retained through an explicit no-clobber
hard link named `.libmachook.dylib.before-namespace-6d3987-20260919` or
`.libmachook_arm64.dylib.before-namespace-6d3987-20260919`.
Replacement used new inodes, not writes into mapped executable files. All four
final hashes matched the previously tested signed artifacts:

| Slice | SHA-256 of both canonical copies |
| --- | --- |
| arm64e | `2ada4ab11fee427837521efcc55c660c0ba1083349d9780714a2e23377032708` |
| arm64 | `a71494cbef57a0fb7fa73b3c85a0f12b2a8f101b013aca3c471e172e06d4a9b0` |

The complete pre/post inode, ownership, mode, hash and rollback paths are in
`/tmp/macws-namespace-canonical-install-20260919.json` on both the controlling
Mac and iPad. No service or other user's application was restarted.

Fresh Preview PID 35128 was then launched through the ordinary installed
`launchdchrootexec`, without a candidate DYLD path, root-metadata override or
feature/debug opt-in. Its launcher recorded
`insert=/usr/local/lib/libmachook.dylib`. A bounded non-suspending memory read
verified canonical UUID `7C247FAD-482D-31F4-9008-04B4D4FC060C` and the exact
tested `__text` hash. The actual full iPadOS capture
`/tmp/macws-preview-canonical-reopen-20260919.png` shows the saved green strokes,
original annotations and readable document text. Preview was left open on the
disposable test copy.

A separate fresh Terminal PID 35281 used that same normal production launch
path. Two real New Tab menu actions created bash children 35381 and 35507.
The inspected full capture `/tmp/macws-terminal-namespace-two-tabs-20260919.png`
shows both tabs and a live prompt; the second bash and Terminal itself each
mapped exactly one canonical library with the same accepted UUID/text hash.
The test Terminal was then closed through its real Quit action; the native
observer recorded `raw-status=0 exited=1 exit-code=0 signaled=0`. The user's
existing Terminal PID 13515 and its three shells were left untouched. These
checks establish the actual metadata→AppKit/Metal→fork/exec consumer path;
they do not claim that already running, untouched processes remapped the new
library, or that unrelated outstanding rendering issues are solved.
