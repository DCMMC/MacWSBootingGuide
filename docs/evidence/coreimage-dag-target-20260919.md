# CoreImage native GPU DAG target boundary (2026-09-19)

Device: iPad13,6, iPadOS16.3, Ventura13.4 rootfs. No IPSW extraction,
debugger attachment, app activation, service restart or respring was used
to obtain these witnesses. All compilation probes used small synthetic
content; no user document contents were captured.

## Observed failure, not an attribution from process uptime

The current Finder321 and iconservicesagent97323 logs independently contain:

```text
Metal library creation failed: Error Domain=MTLLibraryErrorDomain Code=1
"This library format is not supported on this platform (or was built with an old version of the tools)"
```

Their following CoreImage DAGs include real color conversion, blending and
Lanczos kernels. This establishes an upstream producer/compiler failure;
it alone does not prove why a particular Finder file icon is absent.

Disconfirming control: `macws_file_icon_probe` forced the actual NSWorkspace
icon for `/var/root/macws-internal-drag-probe.txt` into a64x64 bitmap. It
returned2500 visible pixels and its PNG visually showed the normal text-page
icon. No fresh compiler request occurred. A cached normal file icon and a
Finder-generated QuickLook thumbnail are different acceptance cases.

`macws_coreimage_probe` then rendered a16x16 synthetic color ramp through
CIColorControls with an explicit real Metal device, not a software context:

```text
CI-PROBE device=Apple M1 class=AGXG13GFamilyDevice
CI-PROBE pixels=256 visible=0 changed-bytes=992 varied-bytes=0 dags=0 hash=c8a6259ce7a13383 first=0,0,0,0 last=0,0,0,0
```

It logged the same library-format error. Its15-second deadline was not hit;
the complete SSH/probe call returned in about1.4seconds. The optional public
device DAG observer saw zero calls: CoreImage's compiler route is not that
particular Objective-C selector. The service-side capture is authoritative.

Fresh compiler worker13338 logged installation of all three target-adapter
call sites and the reply observer, then captured exactly:

- Request `raw-13338-001-e-64634-df2faf2cd8545008.bin`, discriminator14,
  64634bytes, FNV1a64`df2faf2cd8545008`.
- Reply `reply-13338-001-6192-1c9ea56c901302c1.bin`, 6192bytes,
  FNV1a64`1c9ea56c901302c1`.
- All ten wrapped AIR modules name `air64-apple-macosx13.4.0`.
- Reply's MTLB at offset104 starts `4d544c42 0100 0200 0700 0082`:
  an iOS archive, rejected by the unmodified macOS loader.

The dynamic `/tmp/macws_mtlcompiler_diagnostics` switch was enabled only
around this probe with an EXIT/signal cleanup trap; its absence was verified
afterward. The fresh worker exited naturally. This failure is not explained
solely by an unrelated day-old compiler worker retaining an older tweak.

## Two real consumer contracts

The isolated native replay calls Apple's original
MTLCodeGenServiceBuildRequest on the byte-identical captured input. It never
changes request bytes, compiled archive bytes, loader checks or pipeline
results.

| Upstream target construction | MTLB target | macOS library load | Native AGX compute pipeline |
|---|---|---|---|
| Original default factory | iOS,01/82 | Error1 | Not reached |
| Factory Optional platform1 | iOS19,01/82 | Still the wrong platform | Not a fix |
| Original factory + real LLVM setTriple(macOS13.4) | macOS,0180/81 | Accepted | Error3: `Target OS is incompatible.` |
| Original factory Optional Catalyst6 | Mac Catalyst,0180/86 | Accepted | Real ciKernelMain pipeline accepted |

RE-confirmed from512bytes read inside the isolated process:
libGPUCompilerImpl UUID`41d2f0618da83cfa8c4ac3e9d7009604`,
getDefaultTargetTriple at image+`0x2d880`, compares the explicit platform
only to6 at+`0x2d8cc` and otherwise constructs an `ios` target. Passing
platform1 cannot make this iOS compiler manufacture a native macOS triple.

The genuine setter experiment used exported
`llvm::Triple::setTriple(llvm::Twine const&)`, libLLVM UUID
`3c9d9d6ccc92326a911c141bc96dc8be`, image+`0x1039848`. Its actual code calls
the real Triple constructor at+`0x1034154`, releases the previous owned
string and replaces all48bytes of the resulting Triple. No opaque zero
object or guessed metadata was used. It proves that satisfying only the
macOS archive loader is insufficient for the native iOS AGX consumer.

## Candidate policy and remaining acceptance

The request parser distinguishes the two observed source contracts:
native Ventura13.4 AIR and metal2metal's existing Catalyst19macabi AIR.
Every wrapped module and optional explicit target must agree. Mixed,
unsupported, malformed and truncated requests remain on Apple's original
route. Validated MacWS requests select the genuine Catalyst factory inside
their thread-local compiler scope, satisfying both consumers; ordinary iOS
requests and explicit compiler context are unchanged.

Fourteen parser tests pass, including a reduced ten-module fixture,
all-prefix truncation checks and mixed/unknown target rejection. The exact
64634-byte runtime capture also classifies as native MacOS134. Both Theos
arm64 and arm64e builds pass.

## Real instruction-entry regression exposed by the new build layout

The first candidate failed before entering the request parser and was
immediately rolled back. Runtime crash
`MTLCompilerService-2026-09-19-052757.ips` (PID15900) reports
`EXC_CRASH SIGABRT`, `stack buffer overflow`, and MTLPatchLog+472.
The arm64e image UUID was FA75CA66-49AE-3447-8277-D5736B525D63.
This was an Apple clang/ld64 build, not the prior Theos lld ABI issue.

RE-confirmed in that exact candidate: the wrapper's real symbol is0x4724,
beginning with PACIBSP, but the install code computes it with:

```text
0x41dc add x16, x16, #0x724
0x41e0 paciza x16
0x41fc and x10, x16, #0x7ffffffffff8
```

The old integer PAC mask was optimized together with a pointer-alignment
assumption and rounded this four-byte-aligned entry down to0x4720, the
preceding MTLPatchLog stack-canary failure call. The runtime installed
wrapper address0x1047f8720 exactly matches the wrong destination. The old
diagnostic reply observer's adjacent-entry `+4` workaround masked the same
class of defect without repairing it.

The fix uses architectural `ptrauth_strip(...,ptrauth_key_function_pointer)`
for every compiler code-symbol caller, keeps exact PACIBSP validation, and
removes the adjacent-instruction guess. New disassembly preserves the real
wrapper0x46f4 and reply0x5794 with PACIZA followed by XPACI. A standalone
arm64e executable exercised both0/4 modulo8 function entries on the iPad:

```text
CODE-POINTER index=0 raw=0x104d54000 stripped=0x104d54000 alignment=0 branch=0x94000000
CODE-POINTER index=1 raw=0x104d5400c stripped=0x104d5400c alignment=4 branch=0x94000003
CODE-POINTER isolated-dlopen=PASS error=none
CODE-POINTER result=PASS
```

The candidate also loaded safely in this isolated executable; its compiler
UUID guard declined to patch this unrelated process. Two executable/source
contract tests plus the fourteen DAG parser tests pass locally.

## Producer and cache acceptance

After isolated validation, a new-inode canonical install retained exact
rollback bytes at `/tmp/macws-coreimage-compiler-before-20260919.dylib`.
Original SHA256: `3f44e231c4fddcd00545ab2bf21e06ad3545a6283d3b5813c7744d09bbad2947`.
Accepted signed candidate SHA256:
`2967872e8a333e7bc0bc87d8ad72a62e0bf3a3c5a6d277bdd925cd8ce755921b`.
Canonical inode1702401, root:staff,0755. No live service was killed/restarted.

Fresh worker17531 reports exact wrapper0x102f246f4, input-target1,
Catalyst context1, the70587-byte native-Mac gamma DAG, a6352-byte MacABI
library reply and a3520-byte genuine native compute pipeline reply.
The16x16 CoreImage readback now succeeds:

```text
CI-PROBE pixels=256 visible=256 changed-bytes=749 varied-bytes=636 dags=0 hash=00f2ae4b8db2c9dc first=0,0,0,255 last=225,225,144,255
MPS-GRAPH readback=16/16 first=1 last=4.75
```

The second line is the independent existing Catalyst MPSGraph path with
real GPU float readback, confirming that the accepted previous input route
still works. Diagnostic flag absence was verified after each capture.

Installing the compiler alone does not repair already cached wrong-target
archives. A bounded read of the macOS root-user generic
`C/com.apple.metal/31001/libraries.data` found the **byte-identical** old
bad CoreImage MTLB at offset7376800 and the new gamma MTLB at7135456.
Finder/iconservices/Preview client caches also contain the wrong iOS
archive headers; this is not permission to edit a guessed cache format.

With the synthetic probes finished, only the generic `libraries.list` and
`libraries.data` pair was moved intact to the recoverable rootfs path
`/tmp/macws-ci-cache-before-20260919`. Original inodes53459009/24238032,
owner root:wheel,0644, and SHA256 values were preserved:

```text
715cd41faf2ae757df6fcd20b275f11f20dd01b71121a603494010fe9faf1a2c libraries.list
34864f0daac7e50314cfa141c2a56ef2d47cfe284204933d39abf444f91a7c1b libraries.data
```

The **identical original** graph then genuinely recompiled and healed:

```text
CI-PROBE pixels=256 visible=256 changed-bytes=748 varied-bytes=668 dags=0 hash=f0d3b28ab6d70146 first=0,0,0,255 last=241,241,195,255
```

A one-time derived-cache schema migration is now packaged in
`macws_metal_cache_migration.py` and called by postinst and the normal/full
GUI startup paths. It checks actual libproc process-root identities before
mutation, journals exact `31001/libraries.list` and `libraries.data` renames,
and writes the schema only after every planned file has been retired.
Inodes, bytes, permissions and ownership are retained in the recoverable
archive. Partial rename/commit failures resume from the journal. Symlinks,
path traversal, changed-source collisions and malformed records fail closed.
The schema is a derived-data revision, not a production feature/debug flag.
Compiler compatibility works without it; it prevents repeated cache work.

Nineteen executable migration tests pass, in addition to the sixteen compiler
tests. On the actual iPad a fresh isolated empty root without any revision
or flags returned `migrated` and then `current`. The live real root correctly
returned `deferred` with its actual chroot PIDs and created no schema. A
read-only full libproc ABI sample returned440 valid2352-byte records and
three ESRCH exits, with no uninspectable permission-denied identities.
Both rename-parent directories are fsynced before the schema commit, and
actual client identity is checked again under the migration lock and before
commit. New clients leave the journal recoverable with no successful epoch.
If a writer recreates a pair after an interrupted retirement, the previous
plan and immutable archives are retained and a numbered new generation is
retired separately. This avoids a permanent startup collision without
overwriting either generation. The iPad synthetic partial-pair test verified
both generations' bytes, inode/metadata preservation and a subsequent
idempotent run. Unexpected archive metadata changes still fail closed.

The currently live application caches have **not** all been migrated; the
helper attempts migration only after actual quiescence, without forcing a
respring or closing unsaved documents. The cleanup function does not prove
that all arbitrary chroot clients or manual shells have exited; historical
outer autoload jobs also require separate validated retirement. Therefore
automatic completion at the next cold start remains an untested acceptance
condition, not an assumption from an empty fixture. Do not repeatedly
invalidate caches at every boot or touch
user profiles/documents. Finder
PDF/TXT thumbnail visibility, Preview live PDF annotations across zoom
levels and Weather MissionControl thumbnails each require their own visual
acceptance; they are not declared fixed from this shared producer probe.
