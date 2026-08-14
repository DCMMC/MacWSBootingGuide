# Steam CEF 126 bring-up (2026-08-15)

## Outcome

Steam build `1785799196` now reaches its fully rendered **Sign in to Steam**
WebUI on the iPad macOS desktop.  The top-level CEF Browser and its GPU,
Network, Storage and Renderer children stayed live for more than 60 seconds;
the post-fix diagnostic log contained zero attempts to move the guarded task
port.  The retained host screenshot was 4,458,903 bytes at 2778x1940 and showed
the account, password, sign-in and QR controls.

This milestone does not claim that a game has been installed or run.  It only
establishes a stable, interactive Steam login client.

## Root causes and evidence

### 1. Import rebinding froze every existing CEF thread

Runtime-confirmed in Steam Helper PID 90074:

```text
#### SUSPEND-TRACE pid=90074 op=thread_suspend caller-thread=82259 target=259 result=0 caller=0x1015af80c
```

The same caller suspended 32 peer threads with no matching resumes.  LLDB
resolved `0x1015af80c` to:

```text
CydiaSubstrate`merged ellekit.stopAllThreads() -> () + 540
```

The immediately following MacWS record was the `_CreateSimpleProcess` import
rebind in `steamclient.dylib`.  The only `MSHookMemory` at that call site wrote
a pointer-sized import slot.  It was replaced with the project's
`ModifyExecutableRegion`, whose two-pass thread enumeration first proves the
current thread is present, then pairs every successful peer suspension with a
resume.  The data-slot write itself remains an atomic pointer store.

### 2. Valve's native WebUI fork is unsafe after Network/XPC initialization

Runtime-confirmed by
`/var/mobile/Library/Logs/CrashReporter/steam_osx-2026-08-15-045104.ips`:

```text
EXC_BAD_ACCESS / SIGBUS / KERN_PROTECTION_FAILURE
fork -> _pthread_atfork_child_handlers
     -> nw_settings_child_has_forked
     -> xpc_dictionary_apply
```

The production launcher therefore keeps the top-level Steam Helper on the same
atomic `posix_spawn` adapter used for Valve-owned child launches.  The retired
`MACWS_STEAM_NATIVE_BROWSER_LAUNCH` switch is no longer part of production.

### 3. Chromium requested an immovable iOS task port

The actual universal CEF binary reports `Chrome/126.0.6478.183`; its undefined
import table contains `___sandbox_ms`, not `___mac_syscall`.  Its embedded
source path and warning string are:

```text
../../content/browser/child_process_task_port_provider_mac.cc
AppleMobileFileIntegrity is disabled. The browser will not collect child process task ports.
```

An iOS-native probe called both exported policy entry points with a sentinel
output value.  Neither entry point wrote the output:

```text
symbol=__mac_syscall result=-1 errno=78 (Function not implemented) status=0xfeedfacefeedface
symbol=__sandbox_ms result=-1 errno=78 (Function not implemented) status=0xfeedfacefeedface
```

Before the fix, every CEF child ended with the following exact `MOJO` message
and an `EXC_GUARD/ILLEGAL_MOVE` crash:

```text
#### MACH-MSG-SEND ... id=0x4d4f4a4f ...
  d0={name=515,disp=17,type=0,rights=0x10000,type_kr=0x0}
```

The native special-port probe independently identified port name `515`:

```text
task=515 host=2307 thread=259 bootstrap=2055
```

Chromium 126's upstream policy code calls
`__sandbox_ms("AMFI", 0x60, &status)` and treats status bit 2 as the
`amfi_get_out_of_my_way` / immovable-task-port condition.  Its child-process
provider skips `GetTaskPort()` when that bit is set.  See Chromium's
[`task_port_policy.cc`](https://chromium.googlesource.com/chromium/src/+/refs/tags/126.0.6478.183/content/common/mac/task_port_policy.cc)
and
[`child_process_task_port_provider_mac.cc`](https://chromium.googlesource.com/chromium/src/+/refs/tags/126.0.6478.183/content/browser/child_process_task_port_provider_mac.cc).

`MACWS_AMFI_IMMOVABLE_TASK_PORT_COMPAT=1` now handles only the exact `AMFI`,
operation `0x60` query through both historical `__sandbox_ms` and newer
`__mac_syscall` entry points.  It reports bit 2 and leaves all other policies
and operations untouched.  This fixes Chromium's upstream decision; it does
not rewrite a Mach message, fabricate a task port, or suppress a guard crash.

## Post-fix runtime witnesses

The stable run used main PID 97068, Browser PID 97133, GPU PID 97145, Network
PID 97146, Storage PID 97147 and Renderer PID 97166.  The Browser and all four
functional children remained live past 68 seconds.  The exact CEF warning was:

```text
[97133:259:0814/141113.201741:WARNING:child_process_task_port_provider_mac.cc(54)] AppleMobileFileIntegrity is disabled. The browser will not collect child process task ports.
```

The diagnostic `name=515,disp=17` count for this run was `0`.
WindowServer's catalog independently reported:

```text
window pid=97133 id=1536 layer=0 onscreen=yes alpha=1 name=Sign in to Steam
    Height = 440; Width = 700; X = 247; Y = 173;
```

The production plist leaves all Steam process, semaphore, XPC and Mach-message
diagnostics disabled.  It enables only the two W^X adapters and the narrow AMFI
task-port policy compatibility switch required by the shipped CEF.

## Shared application regression

After rebuilding the low-overhead dylib, new processes were launched through
the same Control Center path used by the iPad UI.  Each passed the process,
window-catalog, input-socket, host-scene-transition and screenshot witnesses:

| Application | PID | Ready time | Screenshot bytes |
|---|---:|---:|---:|
| Amadine | 99056 | 6.70 s | 5,124,015 |
| Microsoft Word | 99120 | 9.41 s | 5,027,181 |
| Microsoft Excel | 99206 | 9.05 s | 4,532,743 |
| Microsoft PowerPoint | 99296 | 12.86 s | 4,583,614 |
