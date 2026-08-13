# Steam CEF bring-up — 2026-08-14

## Status

Steam client build `1785799196` is installed in the macOS rootfs. Its updater,
live client and top-level CEF Helper have all executed on the iPad. The final
interactive login-window witness is still pending because the iPad left the
LAN before the corrected semaphore transport could be deployed. Do not cite
process uptime alone as a successful Steam launch.

## Runtime-confirmed blockers

- `sharedfilelistd`: the Steam main thread blocked synchronously in
  `SFLLoginItemList` until Ventura's real
  `com.apple.coreservices.sharedfilelistd.xpc` service was loaded. The
  production GUI startup now treats a surviving daemon process as a required
  readiness witness before applications start.
- fork after Network/XPC initialization: crash report
  `steam_osx-2026-08-14-015741.ips` showed Valve's child entering the
  non-executable `xpc_dictionary_apply` data page from an atfork path.
  `libtier0_s.dylib +0xd91c` was disassembled from this exact client. The
  adapter preserves its argv/cwd, process-group and SIGCHLD-unblock contract
  with `posix_spawn`; the one top-level WebUI Helper retains Valve's native
  transport launch because an A/B run showed that replacing it left
  `transport_steamui.txt` uninitialized.
- CEF address space: the exact arm64 CEF 126 image UUID
  `4C4C44C4-5555-3144-A13E-0A3390079BB0` reserves two 16-GiB PartitionAlloc
  pools. `patch_steam_cef126_pa_ios_va.py` ports that verified image to the
  8-GiB geometry Chromium uses on iOS. It verifies the UUID, input SHA-256,
  six size sites, six mask materializations and all 54,298 inlined masks; it
  does not bypass an allocator validation.
- POSIX named semaphore transport: Helper sample/disassembly ended in
  `Steam Helper +0xb1090 -> +0x15714 -> +0x14dd0 -> sem_wait`. Exact logs for
  `/BSem/35926ed6` showed both processes opened hostd generation 6273 and the
  main process posted value 1, yet the Mach semaphore right previously sent
  through XPC did not wake Helper. The replacement keeps name/unlink/refcount
  ownership in hostd and stores the real count in a generation-specific state
  vnode. A waiter registers `EVFILT_VNODE` while holding `flock`, unlocks, then
  sleeps and rechecks the predicate; a 1,000-iteration host-side Darwin
  cross-process stress run completed without a lost wakeup. Target-device
  timing and the actual Steam login handshake still require the device witness
  described above.

## Production deployment

The package installs the on-demand job as
`/var/jb/usr/macOS/gui-launchd/com.macwsguide.steam.runtime.plist` and copies
the launcher atomically to `/usr/local/bin/macws-run-steam.sh` inside the
rootfs. It does not start Steam automatically. Before launching, the job
removes only the previous Steam FIFO/shared-memory and MacWS semaphore files.
The launcher creates one inherited `MACWS_STEAM_LAUNCH_EPOCH`, starts Valve's
outer bootstrap, disables only the CEF UI GPU path, and leaves games on native
Metal/AGX.

Diagnostics (`MACWS_STEAM_SEM_DIAGNOSTICS`,
`MACWS_STEAM_PROCESS_DIAGNOSTICS`, pipe/exit/native-exception/VA/volume
traces) are all off in the production plist and runtime manifest.
