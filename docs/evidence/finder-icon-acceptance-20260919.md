# Finder file-icon acceptance (2026-09-19)

## Runtime result: not yet fixed

After the accepted namespace library and CoreImage compiler changes, the
actual Finder UI still fails the large PDF/TXT icon case. Two real iPadOS
screen captures show names with empty icon positions in **as Icons** view.
The same files have visible small document icons in **as List** view, and
Library folders have normal large blue icons. This distinguishes the
remaining problem from a general missing Finder framebuffer or all icon
lookup failures. It does not establish whether large thumbnail generation,
the persistent icon store, or display of its result is at fault.

Local evidence:

- `/tmp/macws-finder-icons-fixture-open-20260919.png`
- `/tmp/macws-finder-icons-second-icon-20260919.png`
- `/tmp/macws-finder-icons-list-20260919.png`
- `/tmp/macws-finder-icons-restored-20260919.png`

The test folder `/tmp/macws-icon-acceptance-20260919` inside the macOS
rootfs contains `document.pdf` copied from the disposable Preview acceptance
PDF, and a new 104-byte `notes.txt`. No original user document was modified.

## Controlled service and cache generation

Before the change, Finder321 had one ordinary window with Recents and
Library tabs. Three seconds of native disk-I/O counters were unchanged;
its 17 file descriptors contained no active user-file copy, and the real
Show Progress Window menu item was disabled. Normal AppInput PerformQuit
exited Finder in 0.726 seconds with launchd last-exit-code0. No signal was
sent to Finder. Only the verified iconservicesagent97323 job was booted out;
iconservicesd97319, WindowServer, Preview and the user's Terminal were left
running.

Exactly four Metal library-cache files, under the root user's known
`private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/C` directory, were
archived with the same inodes, SHA256, owners, modes and timestamps:

| Client | File | Old inode | Bytes |
|---|---|---:|---:|
| com.apple.finder | libraries.list | 53451156 | 156 |
| com.apple.finder | libraries.data | 53451157 | 65536 |
| com.apple.iconservicesagent | libraries.list | 53451759 | 828 |
| com.apple.iconservicesagent | libraries.data | 53451760 | 131072 |

Their common suffix is `com.apple.metal/31001/`. Original bytes remain at
`/private/var/mnt/rootfs/private/tmp/macws-finder-icons-before-20260919/`.
Both source and destination parent directories were fsynced. The complete
device receipt is `receipt.json` there; local copy is
`/tmp/macws-finder-icons-quarantine-20260919.json`. No general IconServices
store or QuickLook cache was cleared.

Normal load/kickstart created iconservicesagent46716 and Finder46722.
Both therefore used the newly installed canonical library, not the old
process mappings. Native UI actions created a Finder window and navigated
to the test folder. Screenshot acceptance was repeated in icon/list/icon
order. The original Library and Recents tabs were recreated afterward;
their 851x449 size was retained, but the newly created window position is
343,25 rather than the previous72,188. The final screenshot verifies that
no navigation dialog remains open. UI was handed to the next coordinated
test; no further Finder activation is needed for read-only icon diagnosis.

This failed case must remain separate from the successful16x16 CoreImage
readback and Preview markup acceptance. Those successes do not prove that
Finder's large generated thumbnails work.

## Producer discrimination before refreshing old QuickLook workers

The existing `macws_file_icon_probe` forced the same fixture files through
NSWorkspace into actual64x64 bitmaps, without activating an application:

```text
PDF: icon-probe rendered pixels=4096 visible=2500 colored=591
TXT: icon-probe rendered pixels=4096 visible=2500 colored=0
```

Both returned PNGs were visually checked: the document icons are normal.
This disconfirms a blanket claim that IconServices always returns transparent
large icons. Their physical local paths are
`/tmp/macws-fresh-pdf-icon64-20260919.png` and
`/tmp/macws-fresh-txt-icon64-20260919.png`.

A separate bounded, non-activating `macws_thumbnail_probe` calls the real
QLThumbnailGenerator for all representations of one selected file. Both
fixtures return a visible128x128 icon representation, but the TXT thumbnail
returns this failure chain:

```text
QLThumbnailErrorDomain Code=0 "Could not generate a thumbnail"
  QLThumbnailErrorDomain Code=102
    GSLibraryErrorDomain Code=7
    "no storage for file:///private/tmp/macws-icon-acceptance-20260919/notes.txt"
```

An existing non-temporary `/var/root/macws-internal-drag-probe.txt` returns
the same failure, with its own canonical `/private/var/root/...` URL.
PDF returns the normal icon and no-cached-thumbnail response but does not
complete its final thumbnail within the8-second limit; the request is then
canceled. This is evidence about QuickLook's returned result, not proof of
the complete cause.

Crucially, actual read-only mapped-image inspection found
ThumbnailsAgent97351 and QuickLookSatellite97373 still running the older
libmachook UUID `A0286FC6-B64B-3F42-A1F7-248ED2753A7F`, not the current
canonical `7C247FAD-482D-31F4-9008-04B4D4FC060C`. Both have the macOS
chroot root. The real GenerationalStorage image in97351 is Ventura UUID
`4153B80F-4624-37A1-A250-1B1A76556ABE`. These failures must be retested with
fresh workers before attributing them to the current namespace code.

Separately, the only running revisiond83032 is iPadOS-native, and launchd
publishes its public `com.apple.revisiond` and cache-delete endpoints.
The stock Ventura plist requests those same names, but no private MacWS
revisiond mapping/job exists in the current source. A namespace collision
is a **THEORY**, not yet a confirmed cause: actual request-routing or
framework/server evidence and a controlled fresh-worker comparison are
still required. No revision store or thumbnail cache has been deleted.

## Fresh QuickLook generation, before the later iPad reboot

After verifying each exact launchd label, plist bytes, executable path,
chroot root and unchanged disk-I/O counters, only the two QuickLook services
were normally booted out and loaded. No Finder, user application or
WindowServer restart was performed. The full local receipt remains at
`/tmp/macws-quicklook-refresh-20260919.json`.

Read-only remote Mach-O inspection, not an inference from a new PID,
confirmed ThumbnailsAgent67808 and QuickLookSatellite67810 both mapped
libmachook UUID `2BE0AD84-7995-373F-84F4-D38FB0583AE1`, the installed
on-device build. The same fixture requests then produced:

```text
TXT: type=0 image=128x128 visible=2500 colored=0 error=nil
TXT: type=2 image=0x0 QLThumbnailErrorDomain0 -> 102 -> GSLibraryErrorDomain7
     "no storage for file:///private/tmp/macws-icon-acceptance-20260919/notes.txt"
PDF: type=0 image=128x128 visible=2500 colored=594 error=nil
PDF: type=2 image=0x0 QLThumbnailErrorDomain0 -> 102 -> GSLibraryErrorDomain3
     "Generation not found"
```

Both requests completed with three callbacks but no visible final thumbnail;
the probe correctly returned failure status3. The PDF request no longer
timed out, yet its final result was still not usable. This establishes that
refreshing these two old worker generations alone does not solve the
remaining thumbnail problem. It does not establish which cache/provider/
GenerationalStorage boundary is responsible.

The device was subsequently rebooted by the user. All device-side temporary
paths and process IDs above are historical witnesses, **not current live
targets**. The screenshots, refresh receipt, normal icon PNGs and bounded
GenerationalStorage method-byte inspection survive on the development Mac.
Fresh installation/startup must establish new process and artifact identities
before further runtime comparison. No preview-option UI experiment has yet
been performed.

## Fresh-boot, new-file comparison

After the user reboot, the current `c3c8ec2` package was configured normally.
The non-activating helper generated a new 3,686-byte, one-page PDF (white
background and green rectangle) and a new 104-byte plain-text file in its
exclusively created `/tmp/macws-ql-fresh-20260919-1640` directory. It never
opened an original user document. The current service inventory was Finder
10130, ThumbnailsAgent9676 and QuickLookSatellite9686; both QuickLook jobs
had `runs = 1` and no previous exit. No service was restarted or cache/store
cleared for this comparison.

Actual volume witnesses for both files:

```text
statfs=0 type=apfs mount=/ from=/dev/disk1s2
bsize=4096 blocks=31232325 fsid=1000007:1a flags=0x14809098
NSURLVolumeURLKey = file:///
NSURLVolumeTotalCapacityKey = 127927603200
NSURLVolumeSupportsPersistentIDsKey = 1
NSURLVolumeSupportsJournalingKey = 1
NSURLVolumeSupportsVolumeSizesKey = 1
NSURLVolumeIsReadOnlyKey = 0
```

Modern `QLThumbnailGenerator` produced normal 128x128 icon representations
for both files, followed by `No cached thumbnail` and the same final
`QLThumbnailErrorDomain0 -> 102 -> GSLibraryErrorDomain7 / no storage`.
Both requests completed promptly, with three callbacks and no visible final
thumbnail. The public legacy `QLThumbnailImageCreate` API returned NULL for
both files. Exact logs survive on the development Mac:

- `/tmp/macws-ql-fresh-txt-modern-20260919.log`
- `/tmp/macws-ql-fresh-pdf-modern-20260919.log`
- `/tmp/macws-ql-fresh-txt-legacy-20260919.log`
- `/tmp/macws-ql-fresh-pdf-legacy-20260919.log`

This rules out reuse of the previous fixture's generation record as a
necessary condition. The successful volume-property requests disconfirm
the narrow theory that these calls fail or report a read-only/unsupported
volume. They do not prove every filesystem/storage invariant is correct.
The `no storage` error can describe an absent cached generation; by itself
it is **not proof** that the revisiond endpoint is the cause.

The stock `qlmanage -m plugins` catalog includes `com.adobe.pdf` mapped to
PDF.qlgenerator965.6 and `public.plain-text` to Text.qlgenerator965.6. A
bounded non-UI `qlmanage -t -z -s 64 -c com.adobe.pdf -g .../PDF.qlgenerator`
run did not produce a result within twelve seconds; only that newly spawned
diagnostic process group was sent SIGTERM. Its final exit status0 is not a
generation success witness.

### Separate singleton-routing hypothesis

RE-confirmed in the copied, actual Ventura QuickLookSatellite arm64e image:
the incoming peer handler at image+0x2de8 calls the singleton accessor at
image+0x2fa0, then sets its connection. The accessor uses `dispatch_once` and
stores one global QLSatellite instance. The event callback at image+0x2eb0
again retrieves that singleton before handling a message. The stock
connection setter at image+0x5684 stores into the singleton's +0x18 field.

The existing MacWS adapter publishes this `_MultipleInstances` service as
one persistent Mach listener and retains the last assigned connection.
**THEORY:** separate clients may replace each other's reply owner. The
binary singleton is established; causation for the current blank icons is
not. A bounded peer/request/reply identity trace or a correctly isolated
single-client control is still required before changing the adapter.

That first peer trace **did not reproduce replacement**. With the current
Satellite executable UUID `0128A54C-A3F3-35BE-A35A-DE59C0F9B803`, the event
callback read peer `0x13d107a20` from its captured block. Both subsequent
`sendOnConnection:queue:reply:` calls used exactly `0x13d107a20`. Neither
the incoming-peer nor the connection-setter breakpoint fired during these
failing requests. Thus this failure cannot presently be attributed to a
demonstrated overwritten connection. The trace detached successfully,
removed all its breakpoints, and verified that PID9686 was running with no
debugger/helper remaining. Local receipt:
`/tmp/macws-ql-peer-trace-20260919.log`.

The useful capture lasted approximately two seconds, but LLDB's initial
remote Objective-C/shared-cache discovery took roughly thirty seconds.
Future probes must not describe that whole session as a ten-second pause.
A self-only observer was subsequently used to avoid another shared-service
pause. The public legacy thumbnail API did not construct Satellite messages
inside that caller, so its observer recorded no reply contents. A separate
temporary observer in a newly spawned `qlmanage` recorded no calls to
`QLRequest checkAccess` or `setDiscardError:` before its eight-second alarm;
the deadline stack was `qlmanage -> NSRunLoop run -> CFRunLoop -> mach_msg`.
This is an incomplete generation witness, not evidence that access succeeded
or that a generator returned a particular error. The library was loaded
only for that individual command, with no persistent environment or flag.

As a file-validity sanity control, the same helper's tiny PDF generated a
normal thumbnail on the development Mac (macOS26.6.2), using stock
`qlmanage -t -z -s 64`: `Thumbnails produced: 1`, duration0.385051s.
This confirms the fixture is usable there; it does not substitute for
Ventura-on-iPad acceptance or prove its entire service contract matches.
