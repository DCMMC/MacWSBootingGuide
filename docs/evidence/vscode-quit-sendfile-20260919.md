# VSCode normal-Quit SIGSYS, 2026-09-19

## Actual failure, not inferred from disappearing windows

The normally launched, current-boot VSCode PID 13102 displayed the real
Example Domain page. The iPad screenshot
`/tmp/macws-vscode-13102-before-quit.png` was inspected. Its enabled menu item
26, `Quit Visual Studio Code`, was selected through the actual menu protocol
for focused window 34. This was not `kill`, a simulated successful quit, or
an unobserved launchctl restart.

LLDB ignored Mach `EXC_BAD_ACCESS` and passed Unix SIGBUS/SIGSEGV through to
V8, while stopping on and passing SIGSYS. The exact supported setting was
`platform.plugin.darwin.ignored-exceptions EXC_BAD_ACCESS`, set before
attachment. An earlier attempt missing the Unix handling stopped on V8's
ordinary fault machinery and is **not** used to attribute the quit failure.

Runtime-confirmed via `/tmp/macws-vscode-sigsys-13102-20260919.log`:

```
thread #27, name = 'libuv-worker', stop reason = signal SIGSYS
pc  = 0x18058ef6c  libsystem_kernel.dylib`sendfile + 8
lr  = 0x10f32fe74  Electron Framework`node::BufferValue(...) + 5788
x0  = 0x4e       input descriptor 78
x1  = 0          output descriptor 0
x2  = 0          offset
x3  = 0x171b8abd0 pointer to transfer length
x4  = 0          no headers/trailers
x16 = 0x151      syscall 337

sendfile + 0: mov x16, #0x151
sendfile + 4: svc #0x80
sendfile + 8: b.lo ...
```

After detachment with the signal still passed, launchctl reported
`-  -12  UIKitApplication:com.macwsguide.vscode`. The exact descriptor kinds
and pointed-to length were not captured before that exit. File-to-file copy
is a plausible caller operation, **not an established property of this
particular invocation**.

## Actual caller requires a real compatibility contract

RE-confirmed from the device's actual Electron Framework, reading only the
Mach-O header and a 448-byte instruction range. The symbol/slide correlation
places the call at preferred address `0x8cfe70`; its return address is
`0x8cfe74`. The following code accepts a nonzero transferred prefix for
EAGAIN/EINTR, and branches to its existing pread/write fallback for EINVAL,
EIO, ENOTSOCK and EXDEV. It does **not** take that fallback on ENOSYS:

```
+0x8cfe70: bl    ...                 // sendfile
+0x8cfe80: cmp   w8, #0x23          // EAGAIN
+0x8cfe90: cmp   w8, #4             // EINTR
+0x8cfea8: cmp   w8, #0x16          // EINVAL
+0x8cfeb8: cmp   w8, #5             // EIO
+0x8cfec8: cmp   w8, #0x26          // ENOTSOCK
+0x8cfed8: cmp   w8, #0x12          // EXDEV
+0x8cfee0: ...                     // real fallback
+0x8cfef0: mov   w1, #0x2000        // 8 KiB buffer
+0x8cff5c: bl    ...                // pread
```

The official [libuv implementation](https://github.com/libuv/libuv/blob/v1.x/src/unix/fs.c)
also excludes iOS from its Darwin sendfile path and provides a copying
fallback. Apple's [syscall table](https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.61.2/bsd/kern/syscalls.master)
conditionally maps syscall 337 to sendfile or nosys. These corroborate the
captured failure; they do not substitute for the actual device trace.

## Default adapter and bounded verification

`Compatibility/MacWSSendfile.c` adds a static dyld interpose, without an
environment/marker gate, executable-text patch or signal override. It
validates real descriptors; regular-file output produces the actual
ENOTSOCK result needed by the caller's existing copy implementation. Valid
regular-file to connected-stream transfers use bounded pread/send loops.

The adapter preserves offsets, transferred byte counts, partial progress,
EINTR/EAGAIN, headers and trailers. It uses native VM copy operations for
metadata EFAULT behavior instead of dereferencing arbitrary caller pointers
or installing a signal handler. Header/trailer behavior follows Apple's
[implementation](https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.61.2/bsd/kern/uipc_syscalls.c)
and is independently compared against stock macOS: complete headers are sent
even when longer than the requested budget; that budget limits headers plus
file data, while trailers are additional. Input descriptor position is not
modified. Memory allocation occurs only for supplied vectors and valid
file-to-stream data, not the ordinary file-output fallback.

An additional stock macOS comparison caught a subtle error-ordering detail:
the final length copyout is best-effort. An invalid output-length pointer
does not replace an earlier EBADF/ENOTSOCK, and a readable but readonly length
at EOF does not turn success into EFAULT. The implementation and executable
tests retain this observed behavior; invalid input metadata still returns
EFAULT when that read is actually reached.

`python3 -m unittest misc.test_sendfile_compat -v`: **4 tests passed** on
the macOS host. The executable includes the actual production C adapter.
The same standalone probe, cross-compiled for arm64 iOS, signed/admitted,
and run on the iPad with a 10-second alarm, exited 0 and printed:

```
PASS basic offset/EOF/length/input-position
PASS adapter headers/file-budget/trailers
PASS descriptor-validation/real-libuv-copy-fallback/no-side-effects
PASS EFAULT metadata/payload/vector-bounds/best-effort-length-copyout
PASS adapter error-priority/early-length-update/readonly-copyout
PASS EINTR/partial-prefix/resume/header-EAGAIN/no-hidden-retry
PASS real-nonblocking-EAGAIN/196608-exact-bytes/resume/input-offset
SENDFILE CONTRACT PASS
```

The probe uses only its own temporary files/socketpairs; it neither changes
system services nor loads a candidate into a user process. Its stock-reference
mode is compile-time refused on iOS to avoid invoking the unsupported syscall.

## Combined library, isolated consumers

The frozen IOSurface ABI repair plus sendfile were cross-built together with
Apple ld64, using `ADDITIONAL_CFLAGS=-DLIBMACHOOK_ON_DEVICE_BUILD=1` and a
distinct `THEOS_OBJ_DIR_NAME=sendfile-combined-20260919`. Both slices were
split, given the macOS platform tag, signed/admitted, and staged only at
`/var/mnt/rootfs/private/tmp/macws-sendfile-combined-{arm64,arm64e}-20260919.dylib`.
No canonical library was replaced by this test.

| Slice | UUID | Signed file SHA-256 |
| --- | --- | --- |
| arm64 | FA6DD2E7-725A-3F61-9C53-72D9AECEA929 | ed48eed85b15471707e1b3a82792c6b1e6f5b5e00ec30da9282dacd9c2368026 |
| arm64e | C7BB4C27-2B6E-37CB-9839-CEB8A2A15040 | 5a4cf120eb46161e02888be9878debfd8d12dd58aad56100946fdb324c9a7460 |

The separate macOS `macws_sendfile_api_probe.c` calls the public symbol;
it does not compile/link a copy of the adapter. Both slices reported the
correct isolated dylib path, `public-symbol-interposed=1`, ENOTSOCK on real
file-output, and byte-exact header/offset/trailer data on the socket. Logs:
`/tmp/macws-sendfile-combined-api-20260919.log`.

Both slices also passed all CF/NSURL/statfs/fsgetpath namespace queries
before and after fork, using ordinary `MACWS_CHROOT_HOST_ROOT` namespace
metadata, no feature flag. Logs:
`/tmp/macws-sendfile-combined-namespace-20260919.log`.

The real native-Metal/fork probes, PIDs 17228 (arm64e) and 17233 (arm64),
completed all 4×4 pixels as BGRA `(191,128,64,255)`, kept the superclass
authentication instruction unchanged, and reaped their fork children with
exit 0. Logs: `/tmp/macws-sendfile-combined-metal-{e,arm64}-20260919.log`.

**Acceptance boundary:** these establish isolated integrated-library/API
behavior, not yet a successful normal VSCode Quit. That final consumer test
and installed/mapped identities must be recorded before calling the
application regression fixed.

## Independent boundary review

Host-only differential checks against stock macOS found one additional errno
contract difference: after closing the peer of an AF_UNIX stream socketpair,
`getpeername` returns EINVAL but stock `sendfile` returns ENOTCONN. The adapter
now maps that EINVAL only after SO_TYPE has established a real stream socket;
all other peer-query errors remain untouched. The regression executes both
implementations with no vectors, headers, trailers, and SO_NOSIGPIPE. Each
returns `-1`, ENOTCONN, and zero transferred bytes. Existing invalid input and
output descriptor EBADF and regular-file-output ENOTSOCK are also checked in
the stock-reference path. No socket state, flags, or user signal handlers are
changed by the adapter.

An additional temporary host differential probe
`/tmp/macws-sendfile-review.c` matched stock behavior for sixteen cases,
including zero-length vectors, NULL vectors with ignored counts, total-vector
overflow, O_EVTONLY regular input, and EFAULT in a later header/trailer vector.
The trailer-EFAULT case preserves eight already-sent file bytes. With the
sender SHUT_WR, file data returns EPIPE without SIGPIPE, headers/trailers
return EPIPE with one SIGPIPE, and SO_NOSIGPIPE suppresses that signal in both
implementations. This is actual host I/O evidence, not an inference from the
adapter's comments. It does not replace installed iPad public-API or VSCode
normal-Quit acceptance after the final build.

The namespace transition was separately reviewed without changing it. Its
250 retained entries plus five canonical entries and terminator fit the
256-entry array exactly; the next retained entry fails with exit 119 rather
than truncating XPC data. The existing executable fixture verifies both
boundaries, preservation of unknown XPC entries, and replacement of stale
root metadata. A temporary arm64 host probe included the actual production
`ViewBridgeChrootProxy/main.c` checked syscall function: open returned fd 3,
F_GETPATH returned `/private/tmp`, fcntl on its closed fd returned -9, and
opening an absent directory returned -2 without accidentally closing fd 2.
Thus the carry-to-negative-errno behavior was exercised, not only matched by
a source assertion. These tests establish the transition's local boundary
contract, not QuickLook thumbnail success or all descendant launch routes.
