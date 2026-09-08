# iPadOS/macOS clipboard and drag interoperability evidence (2026-09-06)

## Scope

This validation used the mounted Ventura 13.4 rootfs binaries and live iPadOS
16.3.1 processes. It did not open, extract, or disassemble an IPSW.

## DesktopServices failure boundary

- **RE-confirmed via Ventura 13.4 DesktopServicesPriv,
  `TDSHelperContext::LaunchDesktopServicesHelper`**: the client resolves
  `com.apple.DesktopServicesHelper`; an invalid XPC reply is mapped to status
  `-8062` at `+0x248`.
- **RE-confirmed via Ventura 13.4 DesktopServicesHelper**: the helper reads the
  request audit token at `+0x1ec54`, calls `sandbox_check_by_audit_token` at
  `+0x1ec74`, and on the non-sandboxed path reads the caller's
  `com.apple.private.tcc.allow` array at `+0x1ed9c`. The array must contain
  `kTCCServiceSystemPolicyAllFiles`; the failed path reaches the invalid-use
  abort at `+0x23818`.
- **Runtime-confirmed via the temporary pass-through audit recorder**: the XPC
  message token was identical to Finder's task audit token,
  `ffffffff:00000000:00000000:00000000:00000000:000112d3:00000000:0002078c`,
  and the stock sandbox check returned `0`. The recorder did not alter either
  value and was removed from the production build after this measurement.
- **Runtime-confirmed via `ldid -e`**: the failing Finder generation had only
  `kTCCServiceListenEvent`; the repaired production signature contains both
  that value and `kTCCServiceSystemPolicyAllFiles`.

The production path therefore publishes the unmodified Ventura `authd` and
`DesktopServicesHelper` protocols on collision-free private Mach names and
restores the entitlement required by the helper's original handshake. It does
not synthesize an authorization result or bypass the helper check.

## Production runtime witnesses

After a full package build/install and a clean WindowServer desktop-generation
rebuild, the generated jobs were registered as
`com.macwsguide.authd` and `com.macwsguide.desktopserviceshelper`. The real
Ventura authd remained live, and a stock Authorization.framework probe returned:

```text
AuthorizationCreate status=0 auth=0x12de16e60
AuthorizationCopyRights status=0 granted=0x12de0b420 count=1
AuthorizationFree status=0
```

An iPadOS `NSItemProvider` file was then published and dropped into the real
Finder window. The Host/input witnesses were:

```text
interop-paste-route emit target=86081 window=0 view=(694.5,485.0) frame=(1193.5,833.5)
interop-drop-probe file=macws-drop-probe-1EE67F81-739A-4CAE-B3AC-87C4C0BD50D4.txt window=0 pid=86081 applied=YES error=nil
input-v5 transport=sent errno=0 scene=80000000 target=86081 kind=perform-paste source=5 point=(1193.50,833.50) frame=2388x1668 pressure=0.000 contact=0 sample=3 seq=4
```

The source text and Finder-created destination both hash to:

```text
36e42eb287f3924503e9f5f3dd7db77058bc507988b243d8b30b60af37ffe677
```

The iPadOS-to-macOS rich-pasteboard probe observed two items. The first retained
`public.utf8-plain-text`, `public.html`, `public.rtf`, and
`com.macwsguide.ios-probe`; the second retained a resolvable
`public.file-url`. In the reverse direction, the iOS Host observed:

```text
interop-pasteboard-probe read-ios items=2 reps=5 types=com.macwsguide.probe,public.html,public.rtf,public.utf8-plain-text | public.file-url
```

Finally, the Finder-to-iPadOS long-press source pipeline was exercised at the
visible file item's coordinate in a per-window macPad scene. Finder populated
its real drag pasteboard and the Host converted both advertised formats:

```text
interop-drag-source-probe window=30 pid=86081 point=(312.0,265.0) before=3 began=YES providers=1 types=public.file-url,com.apple.finder.node
```

After the probes, Finder, WindowServer, MacWSHost, and authd were still live;
no new relevant crash report or service error appeared, and the device thermal
state was `nominal` at 35.19 C.

## Physical cross-App test correction

The later manual Files/Notes/Photos test exposed a gap that the synthetic
probe did not cover. The real incoming gesture reached every existing bridge
boundary:

```text
interop-drop-target window=30 pid=86081 point=(629.5,325.5) providers=1 applied=YES error=nil
interop-status connected=YES message=iPadOS 剪贴板已同步到 macOS
input-v5 transport=sent ... target=86081 kind=perform-paste ...
```

The reverse Finder gesture also created a native UIKit drag, and the exact
Finder snapshot advertised `public.file-url,com.apple.finder.node`. Therefore
the failure is after gesture recognition, not an absence of the drag/drop
callbacks or the XPC transport.

The iPhoneOS 16.5 SDK contract in `Foundation/NSItemProvider.h` says that the
URL returned by `loadFileRepresentationForTypeIdentifier:` is deleted when
its completion handler returns and must be copied or moved *inside* that
handler. The tested implementation dispatched the copy to another queue and
returned first. The corrected implementation performs callback-scoped staging,
tries a promised file representation for Photos/Notes content, and creates a
real `public.file-url` alongside the original inline formats. In the reverse
direction it now uses `initWithContentsOfURL:` so UIKit advertises the staged
file's inferred content UTI rather than only the URL and Finder-private types;
its fallback registration no longer requests open-in-place access.

The same physical long press cannot reveal in advance whether the user intends
a macOS context click, an AppKit-internal drag, or a UIKit cross-App drag. The
production gesture policy now leaves UIKit's content drag disabled by default.
A per-window “Cross-App Drag (Next)” control arms exactly one UIKit drag and
temporarily suppresses MacWS direct-touch emission for that contact; session
end restores ordinary macOS right-click and internal dragging automatically.

## Post-correction runtime witnesses

The corrected package was built and installed on the iPadOS 16.3.1 target.
The data-only provider probe advertised only `public.utf8-plain-text`; its
promised file materialized successfully and Finder created the exact named
file. The staged source and Finder destination were both 45 bytes and both
hashed to:

```text
cb5b86225cefb9dcae4e164eda818e225afb4d24ae51b96ca1872d07f136ad8b
```

A real Files/DocumentManager drop then arrived with
`com.apple.DocumentManager.FPItem.File,com.adobe.pdf`. The callback-scoped PDF
materialization completed before the provider process invalidated its later
inline-PDF request:

```text
interop-provider-load item=0 kind=materialize type=com.adobe.pdf accepted=YES error=nil
interop-drop-target window=30 pid=86081 point=(681.0,295.5) providers=1 applied=YES error=nil
```

Finder created `cs336_spring2025_assignment1_basics.pdf`; both its 445845-byte
destination and the callback-staged source hashed to:

```text
5c798e7ec17aa2d861fa1e9e3a307db96835781d618f2416d59886d96bef6983
```

The reverse Finder source now advertises its inferred public content type as
well as the URL and Finder metadata. iOS-side file-representation loads read
both the 35-byte text fixture and the real 445845-byte PDF successfully:

```text
interop-provider-output name=(nil) types=public.plain-text,public.file-url,public.url,com.apple.finder.node
interop-drag-source-load type=public.plain-text file=文本.txt bytes=35 error=nil
interop-provider-output name=(nil) types=com.adobe.pdf,public.file-url,public.url,com.apple.finder.node
interop-drag-source-load type=com.adobe.pdf file=PDF文稿.pdf bytes=445845 error=nil
```

The physical one-shot drag also exposed a lifecycle bug: UIKit logged
`sessionWillBegin`, but the Host did not log its attempted end callback. The
iPhoneOS 16.5 `UIDragInteraction.h` contract names the callback
`dragInteraction:session:didEndWithOperation:`; the implementation had used
the unrelated drop-session spelling `sessionDidEnd:`. The callback was
corrected and the replacement package was installed. A new physical drag then
confirmed the complete cancellation lifecycle and immediate one-shot reset:

```text
interop-drag-arbitration window=30 pid=86081 cross-app=YES
interop-drag-session began window=30 pid=86081
interop-drag-session ended window=30 pid=86081 operation=0
interop-drag-arbitration window=30 pid=86081 cross-app=NO
```

A post-session UI snapshot showed “Cross-App Drag (Next)” rather than the
armed/cancel label, confirming that ordinary macOS long-press/right-click
handling was restored after cancellation.

## Multi-scene clipboard and cross-App file follow-up

The first physical retry disproved the assumption that application activation
was a sufficient clipboard-change witness. macPad had four live window-scene
clients, and the log showed a new scene becoming active without a matching
`UIApplicationDidBecomeActiveNotification`. The Notes clipboard remained at
change 20719 until the Host process was relaunched. The corrected client also
observes `UISceneDidActivateNotification` and polls only the pasteboard's cheap
`changeCount` metadata while the application is active. On the first launch of
that build, it detected and published the real Notes item while deferring the
older macOS event:

```text
interop-remote-deferred reason=newer-local change=20719 last=20718 pending=20719 ...
interop-local-publish change=20719 items=1 types=com.apple.flat-rtfd,com.apple.notes.richtext,com.apple.webarchive,iOS rich content paste pasteboard type,public.html,public.utf8-plain-text canonical-text=present
interop-local-publish-result change=20719 applied=YES current=20719 pending=-1
```

`/usr/bin/pbpaste` in the macOS chroot returned the exact four UTF-8 bytes
`73 33 33 36` (`s336`). This is a real Notes-to-macOS payload witness, not the
Host's internal clipboard fixture.

The same physical run provided a more precise boundary for Finder-to-iPadOS
drag failure. Files and Notes requested only the direct `public.file-url`, then
every session ended with `operation=0`; neither target requested the registered
PDF or PKCS#12 file representation:

```text
interop-provider-url-request file=cs336_spring2025_assignment1_basics.pdf
interop-drag-session began window=30 pid=86081
interop-drag-session ended window=30 pid=86081 operation=0
```

That URL names a file below `/var/mnt/rootfs`, which is not a valid transferable
URL for the receiving iPadOS sandbox. The next build therefore does not expose
the raw URL at all. It advertises only the inferred content-typed file
representation, whose default `NSItemProviderFileOptions` contract copies the
file before the load handler returns. The installed diagnostic now reports:

```text
interop-provider-output name=cs336_spring2025_assignment1_basics.pdf types=com.adobe.pdf,com.apple.finder.node
interop-provider-file-request type=com.adobe.pdf file=cs336_spring2025_assignment1_basics.pdf
interop-drag-source-load type=com.adobe.pdf file=cs336_spring2025_assignment1_basics.pdf bytes=445845 error=nil
```

This proves the revised source representation is readable; a new physical
drop is still required to establish whether Files accepts and commits it.

## Finder icon and Quick Look repair (2026-09-07)

Ventura's `QuickLookSatellite.xpc` declares `_MultipleInstances = 1`.
**RE-confirmed via Ventura 13.4 QuickLook,
`-[QLServerSatellite _connect]+0x68`**: the thumbnail agent creates an XPC
connection to `com.apple.quicklook.satellite`, assigns an instance UUID, and
then sends the stock setup and request dictionaries. MacWS maps that public
XPC-service activation to one pre-published private Mach listener because the
iOS launchd domain cannot activate the macOS XPC bundle. The first live trace
showed that forwarding the per-instance UUID across that transport change
invalidated the client before the satellite received a peer:

```text
satellite-client-instance ... uuid=4e802345-fd54-4f20-9a2a-f6498c1a4ffb
XPCErrorDescription = "Connection invalid"
```

The production interposer now tags only connections translated from
`com.apple.quicklook.satellite` and consumes only their one instance-activation
metadata call. Every setup/request/reply dictionary remains under the stock
Quick Look client and server. After a clean build, signed deployment, and
desktop-service repair, the same real requests completed:

```text
file-thumbnail-ready path=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.led-cinema-display-24.icns output=/tmp/macws-ql-clean-icns.png bytes=63245
file-thumbnail-ready path=/System/Library/CoreServices/OSDUIHelper.app/Contents/Resources/kBright.pdf output=/tmp/macws-ql-clean-pdf.png bytes=10393
file-icon-ready path=/System/Library/CoreServices/OSDUIHelper.app/Contents/Resources/kBright.pdf output=/tmp/macws-icon-clean-pdf.png points=32x32 pixels=1024x1024 bytes=18478 representations=32
```

Both Quick Look outputs were 512 by 512 pixels and were visually inspected:
the ICNS result contained the Cinema Display artwork and the PDF result
contained the brightness glyph. The two installed `libmachook.dylib` copies
had identical SHA-256
`73e562572a89cbb216a3fe1c55ec2dafdbe8fa4726b9d580f51283fe9963bd22`.
No IPSW was opened, extracted, or disassembled during this work.

Do not use `/usr/bin/open <folder>` as a Finder visual smoke test in this
chroot. **Runtime-confirmed via
`JetsamEvent-2026-09-07-042557.ips`**: the test process was PID 93402
(`open`), accumulated `cpuTime = 128.746061` and
`lifetimeMax = 572958` 16-KiB pages (about 8.7 GiB), and triggered
`vm-compressor-space-shortage`. The repository recovery script was run once;
afterward the compressor occupied 528 pages and load returned to 1.42. Future
Finder UI verification must use the existing display/input bridge or a manual
foreground Finder window, not LaunchServices `open`.

## Prepared drag URL race (2026-09-07)

A physical Finder-to-Files retry reached the real UIKit drag session but Files
rejected it before asking for any registered representation:

```text
interop-drag-prepare completed window=30 pid=2571 serial=8 source=two-finger-hold began=YES providers=1 urls=0 types=com.apple.property-list,public.file-url,public.url
interop-drag-source window=30 pid=2571 ... route=prepared-provider providers=1 types=clients.plist[com.apple.property-list,public.file-url,public.url]
interop-drag-session ended window=30 pid=2571 operation=0
```

This differs from the earlier accepted Files transaction, which used
`route=fresh-staged-url` and ended with `operation=2`. The provider builder
created a readable iOS-native staged URL, but returned only the provider. It
published that URL separately through an asynchronous delegate, while the
drag-preparation completion recovered URLs from the controller's shared
`_receivedMacOSFiles` state. Runtime logs above prove that this completion saw
zero URLs and consequently could not construct the fresh, session-local
`NSItemProvider` that Files accepts.

The production API now returns the providers and their exact staged URLs from
the same archive snapshot. The controller retains that pair through
`sessionDidTransferItems:` and constructs `initWithContentsOfURL:` providers
inside `itemsForBeginningSession:`. After deployment, both the real two-finger
preparation and the same-window diagnostic carried the URL synchronously:

```text
interop-drag-prepare completed window=30 pid=2571 serial=2 source=two-finger-hold began=YES providers=1 urls=1 types=com.rsa.pkcs-12,public.file-url,public.url
interop-drag-source-probe window=30 pid=2571 point=(186.0,123.5) before=60 began=YES providers=1 urls=1 types=com.apple.property-list,public.file-url,public.url
```

The installed arm64 Host contains
`-[MacWSInteropClient macOSDragItemProvidersAfterChangeCount:waitMilliseconds:stagedURLs:]`
and has CDHash `afda8437aa4edd2452893beb6099c0a08a59e61c`. Finder,
WindowServer, and the replacement Host remained live with no new MacWSHost
crash report. A physical Files drop is still required to record the final
`route=fresh-staged-url` / `operation=2` witness for this build.

## Files generic-content acceptance gate (2026-09-07)

The physical test after the URL-race repair disproved the assumption at the
end of the previous section. The exact staged URL reached the drag session,
but a PKCS#12 file was still rejected before Files requested any data:

```text
interop-drag-prepare completed window=30 pid=2571 serial=2 source=two-finger-hold began=YES providers=1 urls=1 types=com.rsa.pkcs-12,public.file-url,public.url
interop-drag-source ... route=fresh-staged-url providers=1 types=dcmmc. dcmmc cert 5.p12[com.rsa.pkcs-12,public.file-url,public.url]
interop-drag-session ended window=30 pid=2571 operation=0
```

**RE-confirmed via the installed iOS 16.3 Files executable**, without an IPSW
or shared-cache extraction: Files' `collectionView(_:canHandle:)` at file
offset `0x3731c` obtains each `UIDragItem.itemProvider`, loops over
`DOCAcceptableDragPasteboardTypes`, and calls
`-[NSItemProvider hasRepresentationConformingToTypeIdentifier:fileOptions:]`
at `0x37528`. The failed path returns `false` at `0x377d4`; its embedded log is
`dragging item ... does not have any representations we can accept`.

**Runtime-confirmed via LLDB disassembly of the already-loaded iOS 16.3
DocumentManagerExecutables image**: the acceptable array initializer at
`0x241a68ae4` creates 11 entries. The first three are
`com.apple.DocumentManager.FPItem.File`, `.Location`, and `.Favorite` (shown
by `DOCDragPasteboardType.typeIdentifier.getter` at `0x241a693f4`). The other
eight getter branch-island targets resolve to the public UTTypes `content`,
`directory`, `emailMessage`, `archive`, `zip`, `executable`, `database`, and
`diskImage`. In particular, neither `public.file-url` nor the generic
`public.data` is in Files' acceptance list.

The production provider now stays file-backed and registers the inferred file
type first, followed by `public.content` for a regular file or
`public.directory` for a directory. It does not claim the private FPItem
protocol and does not expose a raw file URL. Both file representations use
`fileOptions=0`; the iPhoneOS 16.5 SDK contract states that NSItemProvider
copies the file before the load handler returns in that mode. Inline Finder
data flavors are omitted from the drag provider so Files cannot select a text
payload and rename the imported file to `text`.

The deployed Host has CDHash
`681b37e08368154777312c079d03d558e10ea07f`. A same-window runtime probe
against the real Finder selection produced:

```text
interop-provider-container-stage .../clients.plist ... mode=file types=com.apple.property-list,public.content
interop-provider-output name=clients.plist types=com.apple.property-list,public.content conforms=item:YES data:YES file-url:NO content:YES directory:NO
interop-provider-file-request type=com.apple.property-list file=clients.plist
interop-drag-source-load type=com.apple.property-list file=clients.plist bytes=3479 error=nil
```

This establishes the repaired provider contract and a complete 3479-byte
source read. A physical Files drop is still required for the final
`operation=2` / receiver-visible-file witness.
