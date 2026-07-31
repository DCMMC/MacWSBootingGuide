# Native Host popup, tab, menu, and Terminal-shell milestone (2026-07-31)

This milestone fixes the application/window integration issues reported after
the first usable DisplayStream Host build. It keeps the existing AGX-native
WindowServer alive and changes only Host, per-application bridges, and the
Terminal child-shell launch contract.

## Changes

- Exact-window Scenes now request a real AppKit window position anchored to the
  top-left or top-right of `NSScreen`. The Host retries the same bounded request
  after 350, 1200, and 3000 ms because Electron restores its saved frame after
  initial activation. AppKit popup windows are therefore constrained inside the
  represented window capture instead of opening beyond its right edge.
- Popup discovery uses the actual CoreGraphics popup level and scans the union
  of `orderedWindows` and `application.windows`. The latter is required because
  Electron's `NSMenuWindowManagerWindow` is absent from `orderedWindows`.
  Outside taps cancel an AppKit menu through AppKit's tracker; non-AppKit
  transient windows receive a normal Escape down/up pair.
- Tap injection now preserves a single atomic down/up transaction across
  AppKit's synchronous tracking loop. Synthetic hit testing also exposes the
  same mouse location and pressed-button state through `NSEvent`, which is
  required for Terminal tab hover, switching, and close-control realization.
- Window metrics use a stable logical group. Terminal's inactive tab backing
  windows are deduplicated in the control center, and a Scene following an
  inactive tab switches to the focused/on-screen member of the same group.
- Menu protocol v2 carries AppKit's resolved light/dark appearance. The iPadOS
  menubar and popovers consequently follow the represented macOS application,
  not the unrelated iPadOS Scene appearance.
- Host menu popovers use a compact native table (29-point command rows), build
  the complete snapshot before presentation, and acknowledge an action before
  dispatching AppKit `sendAction:to:from:`. This removes partial two-row menus
  and lets terminating actions such as Quit complete after the reply is sent.
- Terminal's direct Bash child is repaired at the exec boundary. Only a
  `/bin/bash` whose kernel PPID resolves to Terminal and whose environment says
  `TERM_PROGRAM=Apple_Terminal` is adapted. The bridge supplies the standard
  chroot HOME/USER/SHELL/PATH, explicitly sources `/Users/root/.bashrc`, then
  execs the real interactive Bash. Later Bash commands and non-interactive
  scripts are not rewritten.

## Runtime evidence

All statements below were copied from the running iPad13,6 at
`192.168.1.6`.

- **Popup containment — runtime-confirmed:** VS Code base window was
  `[190,25,1004,757]`; its live menu was `[1012,87,176,186]`, so the popup's
  right edge (1188) remained inside the base window's right edge (1194).
- **Correct popup level — runtime-confirmed:** querying CoreGraphics level keys
  returned `{10: 8, 11: 101, 12: 500}`. Key 11 is popup level 101; key 12 is
  the unrelated dragging level. The live VS Code popup was class
  `NSMenuWindowManagerWindow`, level 101.
- **Outside cancellation — runtime-confirmed:** the application bridge logged
  `POPUP-OUTSIDE ... route=appkit-menu-cancel`, after which the level-101 menu
  disappeared. Repeating with a second menu produced the same result.
- **Terminal tab identity — runtime-confirmed:** metrics exposed several CG
  window IDs with one `logicalGroupID`; selecting another tab changed the
  on-screen member while retaining the logical group. The Host catalog now
  emits one representative for that group.
- **Tab hover state — runtime-confirmed:** after the `NSEvent` mouse-location
  bridge, Terminal logged the synthetic event coordinates through
  `MOUSE-LOCATION ... original=(0.00,834.00) event=(...)`, and the native tab
  hover close control became visible. A direct tab selection changed the
  on-screen window ID within the same group.
- **Menu snapshot — runtime-confirmed:** Terminal returned protocol-v2
  appearance `1` (light), 166 nodes, and top-level titles Terminal, Shell,
  Edit, View, Window, Help. The snapshot contained `Quit Terminal` with `⌘Q`.
- **Quit action — runtime-confirmed:** action response status was 1, the bridge
  logged `APP-MENU op=2 ... status=1`, and the old Terminal PID exited with its
  launchd job left stopped instead of hanging before the reply.
- **Terminal bashrc — runtime-confirmed:** before the fix, `ps eww` showed
  `/bin/bash` with no HOME/USER/SHELL/PATH. After the production package and a
  Terminal-only reload it showed:

  ```text
  /bin/bash -i ... GIGACAGE_ENABLED=0 ... HOME=/Users/root USER=root
  SHELL=/bin/bash PATH=/usr/local/bin:/opt/local/bin:...
  SSL_CERT_FILE=/etc/ssl/cert.pem
  ```

  `GIGACAGE_ENABLED` and `SSL_CERT_FILE` are exported by the existing
  `/Users/root/.bashrc`, so their presence is the witness that the requested
  file actually ran, rather than merely being mentioned by a profile.
- **Scope and stability — runtime-confirmed:** every test reloaded only Terminal,
  VS Code, or Host. WindowServer remained PID `95375`; the runtime-diagnostics
  sentinel was absent in the final state.

## Production verification

The rootless `com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb` package was built,
installed, followed by the full `postinst.sh` signing/trustcache pass. The final
production state had WindowServer, one Terminal process, VS Code, and MacWS Host
running with diagnostics disabled. No iPad reboot, userspace reboot, respring,
or WindowServer restart was performed.

Final locally built package SHA-256:

```text
74c099faf73cf02175b789bd96084ce820b959fb6a761b1861e36b33d611bbbe
```
