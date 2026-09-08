# VS Code long-session CPU spin — 2026-09-04

## Runtime-confirmed failure

The production VS Code process had been open for 4.5 hours. Two `ps`
snapshots ten seconds apart measured 10.24 seconds of additional process CPU
time:

```text
BEFORE 44512 99.9 140:49.95 04:30:26
AFTER  44512 101.9 141:00.19 04:30:36
```

`misc/thread_cpu_probe.c` isolated the load to one thread:

```text
thread_id          cpu_ms  user_ms system_ms usage state name
6137278688          5005.1   2653.8    2351.3   991     1 Chrome_IOThread
```

An LLDB breakpoint on the actual installed `libmachook_arm64.dylib` captured
the call at `mach_msg_new` entry. The `MOJO` header, send-only timeout option,
zero timeout, and 220-byte message all came from the running process:

```text
* thread #9, name = 'Chrome_IOThread', stop reason = breakpoint 1.1
      x0 = 0x0000000110530000
      x1 = 0x0000000000000011
      x2 = 0x00000000000000dc
      x3 = 0x0000000000000000
      x4 = 0x0000000000000000
      x5 = 0x0000000000000000
0x110530000: 0x00000011 0x000000dc 0x00017e07 0x00000000
0x110530010: 0x00000000 0x4d4f4a4f 0x00000000 0x000000b8
```

A second stop at the real `mach_msg2_trap + 8` return instruction captured
`x0 = 0x10000004` (`MACH_SEND_TIMED_OUT`) on the same thread and a `MOJO`
message ID in `x4`. The backtrace returned through `mach_msg`,
`libmachook_arm64.dylib`'s transparent `mach_msg_new`, and the installed
Electron Framework:

```text
* thread #9, name = 'Chrome_IOThread'
    frame #0: libsystem_kernel.dylib`mach_msg2_trap + 8
      x0 = 0x0000000010000004
      x4 = 0x4d4f4a4f00000000
    frame #1: libsystem_kernel.dylib`mach_msg2_internal + 80
    frame #2: libsystem_kernel.dylib`mach_msg_overwrite + 604
    frame #3: libsystem_kernel.dylib`mach_msg + 24
    frame #4: libmachook_arm64.dylib`mach_msg_new + 2108
```

This matches Chromium's upstream `ChannelMac::MachMessageSendLocked`: a full
peer receive queue returns `MACH_SEND_TIMED_OUT`, and Chromium posts an I/O
task to retry the already serialized message. The source is
[`mojo/core/channel_mac.cc`](https://chromium.googlesource.com/chromium/src/+/HEAD/mojo/core/channel_mac.cc).

## Runtime-confirmed profile mismatch

The launch plist selected:

```text
--user-data-dir=/tmp/macws-vscode-profile-software-composite1
```

but `macos_gui.sh` copied the packaged settings to the obsolete directory:

```text
/tmp/macws-vscode-profile-agx-native-targetfix13
```

The selected profile had no `User/settings.json`. Its log therefore showed
that the Agent Host disabled by the packaged production settings was actually
started:

```text
2026-09-04 05:58:56.740 [info] AgentHostProcessManager: agent host started
```

The fix makes the asset target equal the plist's profile and makes production
preflight reject a future path or settings mismatch.

## Post-fix witness

After materializing the packaged settings into the selected profile and
restarting only VS Code, no Agent Host process or AgentHost log entry was
created. A ten-second per-thread measurement showed 1.8 ms of
`Chrome_IOThread` CPU instead of continuously occupying one core:

```text
thread_id          cpu_ms  user_ms system_ms usage state name
6135328992             1.8      1.2       0.6     0     3 Chrome_IOThread
```

No `mach_msg` result is rewritten and no protocol check or crash path is
bypassed by this change.
