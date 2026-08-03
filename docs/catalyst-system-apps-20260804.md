# Launchpad, System Settings and Maps production milestone (2026-08-04)

This milestone was validated on the iPadOS 16.3.1 iPad13,6 target with the
production native-AGX DisplayStream stack. No MTLSim path was enabled and no
device reboot or SpringBoard restart was used during the final validation.

## Launchpad is populated

The empty Launchpad was not an icon-grid or database-result problem. Runtime
tracing of Dock's stock importer showed its source validation comparing the
chroot-visible application directory with `fstatfs(2)`'s host mount name. The
kernel returned `/var/mnt/rootfs` for the macOS filesystem even though the
process sees that same filesystem at `/`. `libmachook` now rebases only this
filesystem identity for Dock/LaunchServices callers. The stock importer then
reported `apps=63`, `items=76` without forcing an import-success result.

The final production command was:

```text
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh launchpad
[launchdchrootexec] target=/usr/local/bin/macwsworkspacectl arch=arm64 insert=/usr/local/lib/libmachook_arm64.dylib
```

The VNC witness shows the real Launchpad page populated with Ventura apps,
including System Settings and Maps:

![Populated Ventura Launchpad](evidence/catalyst-system-apps-20260804/launchpad-populated.png)

## System Settings runs its real Appearance extension

System Settings launches through the normal MacWS Host application API. Its
visible page is the stock Ventura `Appearance.appex`, hosted by the real
ExtensionKit/ViewBridge service chain rather than a replica panel.

Final runtime output:

```text
ok=yes launched-pid=67656 message=已启动 system-settings，AppKit 窗口已进入 DisplayStream 列表
window pid=67656 id=133 layer=0 onscreen=yes alpha=1 name=Appearance bounds={
    Height = 625;
    Width = 715;
    X = 239;
    Y = 87;
}
window-count pid=67656 count=5
```

![Ventura Appearance extension](evidence/catalyst-system-apps-20260804/system-settings-appearance.png)

The underlying repairs preserve the stock extension contract: a freestanding
iOS first image enters the chroot before libSystem consumes the one-shot XPC
launch context, then execs the real macOS extension. Dedicated ExtensionKit
and Appearance entitlement profiles, bundle-local `libmachook` dependencies,
and reboot-volatile trustcache restoration are installed idempotently by
`ensure_appearance_runtime.sh` and both package postinstall paths.

## Maps uses a persistent UIKit carrier and a real FrontBoard identity

The original `POSIX_SPAWN_SETEXEC` carrier was not stable. Runtime evidence in
`/tmp/maps-run-20260804-040920.clean.log` was exact:

```text
SpringBoard ... Workspace connection invalidated.
Now flagged as pending exit for reason: workspace client connection invalidated
```

Keeping the real iOS `UIApplication` carrier alive and spawning Maps as a
separate chroot child removed that lifetime failure. The first child attempt
still had no scenes; `/tmp/maps-child-20260804-041511.clean.log` showed the
actual rejected identity:

```text
runningboardd: Resolved pid 70077 to [anon<Maps>:70077]
UIKitSystem: Client connected ... [anon<Maps>:70077]
Ignoring non-application [anon<Maps>:70077]
Denying scene request ... Client is not a UIKit application
```

Project LLDB against the loaded Ventura 13.4 FuseBoard image RE-confirmed the
exact identity boundary. The stock
`+[RBSProcessHandle(FuseBoard) fu_handleForIdentifier:]` does the following:

```text
0x224f843f8 <+60>:  bl 0x224fa65a0 ; objc_msgSend$fu_versionedPID
0x224f8443c <+128>: bl 0x224fa6620 ; objc_msgSend$handleForIdentifier:error:
0x224f84468 <+172>: bl 0x224fa65a0 ; objc_msgSend$fu_versionedPID
0x224f84470 <+180>: subs x8, x8, x0
0x224f84478 <+188>: tbnz w8, #0x0, 0x224f84498
```

`libmachook` therefore repairs this provider boundary only when all of these
conditions hold:

- the PID resolves to the exact live chroot Maps executable;
- UIKitSystem already constructed and cached a handle from the child's real
  audit token;
- the complete requested and cached versioned PIDs match;
- the cached handle still answers the native `fu_isApplication` predicate.

Every other process and every stock mismatch path retains the original result.
No assertion, application predicate, or scene-acceptance check is forced.

Final cold production launch through `macwshostd`:

```text
ok=yes launched-pid=270 message=地图已通过 UIKitSystem 启动，原生窗口已进入窗口列表
  257     1 root   Ss   0.0 00:10 .../UIKitSystem system_app_start
  265     1 mobile Ss   0.0 00:10 .../MacWSCatalystLauncher
  270   265 root   S   11.8 00:10 .../Maps.app/Contents/MacOS/Maps
window pid=270 id=156 layer=0 onscreen=yes alpha=1 name=Maps bounds={
    Height = 721;
    Width = 1024;
    X = 85;
    Y = 53;
}
window pid=270 id=157 layer=0 onscreen=yes alpha=1 name=Untitled bounds={
    Height = 600;
    Width = 482;
    X = 356;
    Y = 113;
}
window-count pid=270 count=2
```

The three-process chain remained alive after 6 minutes 38 seconds. The final
iPad sample was `thermal-state=nominal` with effective temperature 33.29 C.
Fresh UIKitSystem/Maps/carrier log ranges contained no `#### CATALYST` lines
with `MACWS_CATALYST_TRACE` absent.

![Maps native windows](evidence/catalyst-system-apps-20260804/maps-native-window.png)

`MACWS_CATALYST_REGISTER_APPLICATION=1`,
`MACWS_CATALYST_REQUEST_INITIAL_SCENE=1` and the private FrontBoard endpoint
name are scoped to the hidden Maps carrier child. `MACWS_CATALYST_TRACE`
remains off in production.

## Known limitation

Maps currently presents Ventura's first-run “What's New in Maps” window above
the live main map window. This milestone proves native Catalyst lifecycle,
FrontBoard/FuseBoard identity, AppKit windows, rendering and production cold
launch. It does not yet claim that every Maps network, location or first-run
interaction is complete.
