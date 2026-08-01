# Safari MTLCompilerService isolation — 2026-08-01

## Outcome

The production `MTLCompilerBypassOSCheck` tweak no longer installs MacWS cache
hooks or global compiler bypasses in stock iOS `MTLCompilerService` instances.
Safari recovered from an all-black-page failure without rebooting or
respringing the iPad.

This milestone fixes process isolation. It does **not** claim to fix the
separate VSCode/ANGLE command-buffer errors `0x102` and `0x103`.

## Runtime evidence before the fix

Safari's GPU helper repeatedly terminated with CoreAnimation compiler errors:

```text
com.apple.WebKit.GPU-2026-08-01-114127.ips
termination namespace=COREANIMATION code=4
spec=Pb3a8BsovXmw_Tpc1A3Xhf
Compiler encountered an internal error
CA::OGL::MetalContext::create_pipeline_state +5028
```

Six further reports between 11:42:52 and 11:45:51 have the same termination
namespace and fail in either `create_pipeline_state` or
`create_fragment_shader`.

The bounded unified-log capture
`/var/jb/var/mobile/macws_video_oslog.capture` ties the failure to compiler
services in the `com.apple.mobilesafari` coalition. The relevant lines are:

```text
11:43:02 MTLCompilerService[86182]: metal-cache adapter installed ...
11:43:02 MTLCompilerService[86182]: readModule OS check ... b.ne -> nop
11:43:02 MTLCompilerService[86182]: %ctor: OS-check patched; running renamer patch now
11:43:02 MTLCompilerService[86182]: renamer-patch: NOPed BL ... OK
11:43:02 MTLCompilerService[86182]: Cache loaded with 5274 pre-cached in CacheData and 58 items in CacheExtra.
11:43:02 MTLCompilerService[86182] Corpse allowed 1 of 5
11:43:02 MTLCompilerService[86181] Corpse allowed 2 of 5
11:43:02 ASI found [libsystem_c.dylib] (safe) 'stack buffer overflow'
11:43:02 MobileSafari: have not received a commit 10.25s after visible content rect update
```

ReportCrash explicitly attributed the dead compiler to Safari:

```text
coalitionName=com.apple.mobilesafari
process=MTLCompilerService
exceptionCodes=EXC_CRASH SIGABRT
```

The log limit prevented those two reports from being saved. An earlier saved
report, `MTLCompilerService-2026-08-01-112734.ips`, supplies the exact failing
frame:

```text
__stack_chk_fail
MetalCacheUnlinkAt +312
```

This is runtime confirmation that the MacWS libc interposition was executing
inside Safari's compiler service. It was not a theory based only on the WebKit
crash.

## Root invariant

`MTLCompilerService` is used by both native iOS clients and the chroot. An
executable-name Substrate filter therefore does not identify a MacWS request.
The old constructor violated that boundary by doing all of the following in
every service instance:

- installing `open/stat/mkdir/rename/unlink` interpositions;
- NOPing MTLCompiler's target-OS rejection branch;
- NOPing AGXCompilerCore's `agx.` renamer call;
- patching and dumping every compiler reply.

The first two NOPs were also forbidden production fixes under the repository's
patch-discipline rule: they suppressed protocol checks instead of supplying
their preconditions.

## Implementation

`MTLCompilerBypassOSCheck/Tweak.x` now uses the request as the isolation
boundary:

1. A request is MacWS-owned only when request type `0xd` contains both exact
   chroot-only arguments:
   `-working-directory "..."` and
   `-fmodules-cache-path="/var/folders/zz/.../com.apple.metalfe/..."`.
2. The original build calls are serialized. A scoped atomic flag is true only
   while the validated MacWS request executes.
3. The libc cache adapter is installed lazily on the first validated MacWS
   request. A native iOS compiler instance never installs those hooks.
4. Cache paths are translated only inside that validated request scope.
5. The global MTLCompiler OS-check NOP and AGXCompilerCore renamer NOP are no
   longer installed.
6. Compiler-reply patching and filesystem logging are diagnostic-only, gated
   by `/var/jb/var/mobile/macws_mtlcompiler_diagnostics`.

The diagnostic helpers remain in source for explicit RE sessions, but are not
reachable from the production constructor.

## Verification

### A/B recovery

With the old tweak disabled and the chroot GUI stopped, Safari, WebContent,
WebKit GPU, and fresh compiler services remained alive and produced no new
reports. The device remained at thermal state `nominal`.

### New tweak loaded by a native compiler

The final deployed dylib SHA-256 was:

```text
d513f07983e48fc12e59526e3e59c9af13ceeb53df0b3fbf7dcc51a994c35ec8
```

`PingMTLCompilerService` created native service PID 87843. LLDB `image list`
runtime-confirmed that the new tweak was actually loaded:

```text
[  0] MTLCompilerService
[ 90] MTLCompilerBypassOSCheck.dylib
[ 93] MTLCompiler
[ 96] libMTLCompilerHelper.dylib
```

`AGXCompilerCore` was absent, proving the tweak no longer force-loaded it to
apply the renamer NOP. PID 87843 returned a valid XPC reply, survived the
10-second hold, and produced no crash report. The final read/write-lock build
was then re-run as native service PID 88008; it also returned a valid reply and
produced no compiler or WebKit GPU report.

### Safari rendering soak

With the new tweak active, Safari opened
`https://www.apple.com.cn/iphone-17-pro/`. After 25 seconds:

- `MobileSafari` PID 87599 remained alive;
- `com.apple.WebKit.GPU` PID 87603 remained alive from 11:58;
- a new WebContent PID 87875 was created normally;
- there were zero new MobileSafari, WebKit GPU, or MTLCompilerService reports;
- iPad thermal state was `nominal`, effective temperature 32.19 C;
- the macOS GUI stack was stopped throughout this isolation test.

The pre-fix binary is preserved on the device as
`/var/jb/Library/MobileSubstrate/DynamicLibraries/MTLCompilerBypassOSCheck.dylib.pre-safari-isolation-20260801`.

## Remaining work

- Revalidate macOS source compilation with a validated chroot request. The
  legacy renamer/OS-check NOPs must not be re-enabled to make a test pass; any
  newly exposed target or AIR error needs an upstream semantic fix.
- Continue the independent VSCode video investigation. Decode advanced during
  the reproduction, while translated AGX submissions returned `0x102/0x103`;
  that command ABI/resource-lifetime problem remains open.
