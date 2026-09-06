# Drag, clipboard, and File Coordination evidence — 2026-09-06

This note records the device evidence behind the v2 iPadOS/macOS pasteboard
archive and window-mode drag bridge. The target was the project's iPad13,6
running iPadOS 16.3 with the Ventura 13.4 chroot.

## File Coordination root cause

A minimal AppKit probe using the stock `NSFileCoordinator` reproduced the
Finder copy failure before any Finder-specific code was involved. A temporary
diagnostic hook recorded libxpc's own fault payload verbatim:

```text
#### XPC_FAULT namespace=7 code=9 payload=0x0/0 flags=0 reason=System session daemon must not initiate XPC to the User session (rdar://77349945): endpoint = com.apple.macosbooter.FileCoordination
```

This is runtime confirmation that the failing invariant was the cross-session
connection, not a missing pasteboard type or a Finder validation check. Moving
Ventura `filecoordinationd` into the System session was also tested and rejected:
its stock DiskArbitration and cfprefsd dependencies are user-session services.

The production fix keeps stock Ventura `filecoordinationd` in `user/501` on
three private endpoints. Two iOS-native XPC bundles activate in the calling
application domain and relay `FileCoordination` and `ProgressReporting` with a
separate upstream connection per client. The temporary global fault hook was
removed after diagnosis.

After installing that route, the same minimal coordinated copy printed:

```text
#### XPC_TRACE file-coordination relay: 'com.apple.FileCoordination'
coordinate-copy accessor=yes copied=yes coordination_error=none copy_error=none
```

Both the source and destination were 38 bytes and had SHA-256:

```text
00b052c2e7356e4a2fd79ee064fd0c5f32e00d6ccb3437c4e42c2239009f3f07
```

The relay lifecycle witness was:

```text
[FileCoordinationBridge pid=64759] ready
[FileCoordinationBridge pid=64759] accepted client
[FileCoordinationBridge pid=64759] Connection invalid
```

The final line followed probe exit and represents the expected per-client
connection teardown. Production relay logging now suppresses that normal case.

## Pasteboard and drag witnesses

The protocol-v2 probes exercised two ordered iPadOS pasteboard items containing
UTF-8, UTF-16, RTF, HTML, a custom UTI, and a staged file URL. The reciprocal
macOS fixture returned two items and five representations to iPadOS. Reapplying
a remote archive did not increment into a publish loop.

For an actual Ventura Finder drag, `NSDragPboard` first exposed
`com.apple.finder.node`; the later drag generation added `public.file-url`.
The daemon resolved Finder's file-reference catalog object through
`fsgetpath(2)`, copied the real file into `MacWS Exports`, and the Host produced
an `NSItemProvider` whose file representation opened the staged file.

For the reverse iPadOS-to-macOS path, the ItemProvider probe decoded iPadOS 16's
binary-plist URL wrapper and staged the actual 35-byte source file rather than
the wrapper. macwsinteropd acknowledged the complete archive before Host sent
the paste request. The target Finder generation reported:

```text
#### APP-INPUT PASTE pid=64833 window=0 item=Command-V action=paste: target=nil performed=YES
```

This confirms the normal enabled AppKit menu action executed. The first final
Finder copy attempt targeted the read-only Recents smart folder, so it is not
claimed as a destination-file witness. A fresh writable-folder Finder matrix
remains part of release-candidate validation; the lower-level coordinated-copy
transaction above already passes without bypassing or stubbing any check.

## Build verification

After removing diagnostics and tightening shared-path validation, these targets
built locally with the iPhoneOS 16.5 Theos SDK:

- `MacWSHost`
- `macwsinteropd`
- `macwsinputd`
- `libmachook` (arm64 and arm64e)
- `FileCoordinationProxy`
- `ProgressReportingProxy`

The preceding device package build and install also completed successfully.
