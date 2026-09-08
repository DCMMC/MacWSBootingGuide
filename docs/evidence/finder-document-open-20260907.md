# Finder document-open bridge — 2026-09-07

## Scope

Fix Finder double-click document opening without bypassing Finder/AppKit
validation. The tested files in `/var/root` were:

- `clients.plist`
- `cs336_spring2025_assignment2_systems.pdf`
- `IMG_0120.png`

## Runtime failure boundary

Finder resolved the correct default application, but outer iPadOS
RunningBoard rejected LaunchServices' foreign macOS application request. The
device log contained these lines:

```text
Finder: Opening document ... '/private/var/root/clients.plist' with application ... '/Applications/Visual Studio Code.app'
runningboardd: Could not find attribute name LaunchRoleUserInteractive in domain plist com.apple.launchservicesd
Finder: RBSLaunchRequest FAILURE ... RBSAssertionErrorDomain Code=2
Finder: Launch failure with -10810/kLSUnknownErr
```

Finder then reported the failure at its real `QLSeamlessOpener` delegate:

```text
#### APP-INPUT SEAMLESS-OPEN-FAIL ... opener=QLSeamlessOpener ... error=Error Domain=QLSeamlessOpenerDomain Code=5
```

When the target application was already running, the same boundary reported
`QLSeamlessOpenerDomain Code=-600`. The bridge handles only these two
runtime-confirmed errors and always calls Finder's original delegate method
first.

## Target application boundary

Runtime Objective-C enumeration of the actual Ventura AppKit image found:

```text
_forAEOpenDocumentsEvent:populateReplyEvent:withURLs:documents: v48@0:8@16@24@32@40
_handleAEOpenContentsEvent:withReplyEvent: s32@0:8@16@24
_handleAEOpenDocumentsForURLs: s24@0:8@16
_handleAEOpenEvent: v24@0:8@16
```

Calling `_handleAEOpenDocumentsForURLs:` returned `0` but did not open the
file in VS Code. Runtime enumeration of the real Electron delegate explained
why:

```text
class=ElectronApplicationDelegate
application:openURLs: implemented=NO
application:openFiles: implemented=NO
application:openFile: implemented=YES types=B32@0:8@16@24
```

The implemented bridge therefore delivers the validated paths through the
target's standard `NSApplicationDelegate` boundary, in this order:

1. `application:openURLs:`
2. `application:openFiles:`
3. `application:openFile:` per path, respecting its Boolean result
4. AppKit's URL handler only when the delegate exposes none of the public
   methods

The target writes a nonce/PID/item-count ACK only after the handler accepts
the documents. Finder sends the request through `macwshostd`'s typed
`open-documents` operation; the sidecar is a bounded binary plist written
atomically with mode `0600`.

## Preview admission

Before the document endpoint could publish, AMFI rejected Preview itself:

```text
AMFI: '/System/Applications/Preview.app/Contents/MacOS/Preview': unsuitable CT policy 0x8 for this platform/device, rejecting signature.
AMFI: code signature validation failed.
```

After signing Preview with the project profile, dyld stopped first at Hydra,
then at Hydra's nested Alembic library. Registering the existing arm64e and
x86_64 CodeDirectories for every Mach-O in `Hydra.framework` let the unchanged
framework tree load. `postinst.sh` now restores those persistent hashes after
every reboot without re-signing Hydra's nested code.

Opening the PNG exposed a second exact AMFI boundary:

```text
AMFI: constraint violation .../CoreImage.framework/.../libWrapGL.dylib has entitlements but is not a main binary
AMFI: code signature validation failed.
Unable to load library: ... libWrapGL.dylib ...
-[CIContext initWithOptions:] No supported back-end renderer is usable.
```

Adding the old CodeDirectories alone did not change the failure. An
entitlement-free ad-hoc dylib signature plus its new CodeDirectories removed
the `libWrapGL` admission and `CIContext` no-backend errors. This exact repair
is persisted by `postinst.sh`; no validation method is overridden.

## End-to-end results

- Finder double-click on `clients.plist` reached
  `ElectronApplicationDelegate application:openFile:` and displayed the file
  in VS Code.
- Finder double-click on the CS336 PDF reached Preview's
  `PVApplicationDelegate application:openFiles:`; Preview visibly displayed
  page 1 and its thumbnail sidebar.
- Finder double-click on `IMG_0120.png` followed the same Finder → hostd →
  Preview delegate route and created the correctly titled Preview document
  window. The image view is still gray on this AGX configuration; the live
  log still says `Preview: No Metal renderer available`. A trial using the
  public `kCIContextUseSoftwareRenderer` option was removed because the image
  path did not call those public context factories and the pixels did not
  change. This is a separate Preview/ImageKit renderer limitation, not a
  document-open delivery failure.

The caught `-[NSPSMatrix makeIdentity]` exception is not the cause. LLDB
disassembly of the exact running AppKit method showed that the compatibility
category deliberately sends `doesNotRecognizeSelector:`, catches it, then
calls `reset`; the temporary witness was removed and no selector was forged.

## Installed-package regression

After installing `com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb` and completing
the full `postinst.sh`, Finder was killed and relaunched so it loaded the
installed dylib. Its PID changed from `47344` to `10759`, and its endpoint
reported protocol ABI 6:

```text
#### APP-INPUT READY pid=10759 socket=/private/tmp/macws_app_input.10759.sock abi=6 record=84
```

Fresh Finder double-clicks on all three files then produced accepted routes.
The plist was delivered to the existing VS Code PID `47391`; the PDF and PNG
were delivered to Preview PID `11534`:

```text
#### APP-INPUT FINDER-OPEN-ROUTE app=/Applications/Visual Studio Code.app documents=1 target=47391 result=appkit-accepted message=已由目标应用接收 1 个文稿
#### APP-INPUT FINDER-OPEN-ROUTE app=/System/Applications/Preview.app documents=1 target=11534 result=appkit-accepted message=已由目标应用接收 1 个文稿
#### APP-INPUT FINDER-OPEN-ROUTE app=/System/Applications/Preview.app documents=1 target=11534 result=appkit-accepted message=已由目标应用接收 1 个文稿
```

Preview independently acknowledged both deliveries after invoking its real
delegate:

```text
#### APP-INPUT OPEN-DOCUMENTS pid=11534 nonce=d25f0660ca1a11ae count=1 urls=1 handler=delegate.application:openFiles: status=0 ack=written
#### APP-INPUT OPEN-DOCUMENTS pid=11534 nonce=96635bdf204e71bf count=1 urls=1 handler=delegate.application:openFiles: status=0 ack=written
```

Visual verification showed the plist contents in VS Code, the PDF at page 1
of 37 in Preview, and a correctly titled `IMG_0120.png` Preview window with
the separate gray renderer limitation described above.
