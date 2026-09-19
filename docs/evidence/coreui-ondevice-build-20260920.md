# CoreUI fix: on-device package verification, 2026-09-20

The iPad checkout was clean at `acb058419c541afac29aa573f52788e9903657f7`.
HTTPS fetch and fast-forward-only merge synchronized it to the clean published
source commit `ec780f7a2a277bd3e134f204a06d517ab4ab80e7`; no reset was needed.

The device ran `THEOS=/var/jb/var/mobile/theos bash misc/build_on_ios.sh
--package-only`. Its validated Apple-ld64 Windowing artifact passed the source
manifest check. The complete clean build, staging and archive checks finished:

```text
==> Host ABI invariant: packaged selector contract verified
MacWS artifact contract: verify-package passed
==> Verified package candidate: packages/com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb
==> Package-only build complete; nothing was installed or restarted.
```

Device log: `/tmp/macws-ondevice-package-ec780f7-20260920.log`.
Package beneath `/var/jb/var/mobile/MacWSBootingGuide`:
`packages/com.kdt.macosbooter_0.3.4_iphoneos-arm64.deb`, SHA-256
`484b15685ce89a55bb4e4ad92a3ffd4eee7ff409f990277616f63006de356ea0`.
Both checkouts were independently checked clean at `ec780f7` after packaging.
`MAKEFLAGS=-j2` did not impose a global two-compiler bound: recursive dual-arch
Theos builds briefly ran four clang processes. No memory-safety conclusion is
inferred from this build succeeding.

This is **package-only**, not a full-package installation or cold-start test.
The separately deployed and visually tested compiler remained SHA-256
`164652ab63384b51c30d094cabe95b912aad877b6992a369057f001d4aaf8cc9`.
The v3 cache-migration script was separately deployed atomically, SHA-256
`9caf8a10e5643e94486b5f62af3e458c855f760a6123b0d6a508ce973e37c362`;
its predecessor is retained in the non-autoload compiler rollback directory.
Its real `--defer-if-running` call reported live macOS clients and correctly
left the committed schema at `macws-macabi-dag-v2`. Neither diagnostic marker
`/tmp/macws_mtlcompiler_diagnostics` nor `/tmp/macws_mtlcompiler_hold` remained.

The subsequent [ordinary Word cache test](word-default-cache-acceptance-20260920.md)
still failed. Safe shared-cache migration and default-path visual acceptance
remain outstanding; successful compilation and the fresh private-cache Word
pass must not be described as complete production acceptance.
