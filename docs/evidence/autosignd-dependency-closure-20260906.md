# autosignd dependency closure and signature validation (2026-09-06)

## Failure evidence

Terminal's environment already contained the intended macOS paths, but the
freshly installed executable failed before `main`:

```text
dyld[80294]: Library not loaded: /opt/local/lib/libncurses.6.dylib
Reason: ... code signature invalid ...
rc=134
```

This is **runtime-confirmed via the failing Terminal `htop` launch**.  It is a
signature/dependency problem, not PATH resolution.

## Implementation

`autosignd/main.c` now resolves the entry Mach-O's dependency closure before
replying to the exec hook.  It parses `otool -L` plus `LC_RPATH`, expands
`@loader_path`, `@executable_path`, and `@rpath`, and recurses only through
third-party roots under `/opt/local`, `/opt/homebrew`, and `/usr/local`.
Traversal is inode-deduplicated and depth/count bounded.

Entry executables retain the project entitlement profile.  Loaded libraries
receive a plain ad-hoc signature because iPadOS rejects executable-only
entitlements on non-main binaries.

The daemon no longer equates a trustcache hit with a valid on-disk signature.
For every thin or fat Mach-O slice it parses the CodeDirectory and verifies
each SHA-1, SHA-256, truncated-SHA-256, or SHA-384 code-page hash against the
current file bytes.  Its stat-keyed cache is populated only after validation,
and post-sign validation is mandatory before adding CDHashes or reporting
success.

## Device verification

The test deliberately invalidated a dependency signature and launched copies
with new names so the result could not come from the daemon's process cache:

```text
install_name_tool: warning ... invalidate code signature ...
RUN
...
htop 3.5.0
htopx-rc=0
AUTOSIGN_LOG
[00:37:26] signed+trusted (1 slice): /var/mnt/rootfs/opt/local/lib/libncursx.6.dylib
[00:37:26] signed+trusted (1 slice): /var/mnt/rootfs/opt/local/bin/htopx
DEPENDENCY_ENTITLEMENTS_AFTER
none
PROBES_REMOVED
```

This is **runtime-confirmed via the invalid-signature end-to-end test on
iPad13,6**: the dependency was repaired before the executable ran, `htop`
reported version 3.5.0 and exited 0, and the dylib carried no executable
entitlements afterward.
