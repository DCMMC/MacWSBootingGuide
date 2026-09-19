# An owned-process Metal cache scope (2026-09-20)

This is a diagnostic isolation tool, **not a production cache repair**. It does
not establish where Word's incompatible cached CoreUI `ciKernelMain` originated
and does not establish that this library causes the missing blue Save button.

## Actual implementation and ABI

Self-process, read-only metadata/code capture of the device's macOS Metal:

- image `/System/Library/Frameworks/Metal.framework/Versions/A/Metal`
- UUID `2BAB169C-42DA-36E3-955A-F30B709EC2AD`
- source records `/tmp/macws-shader-cache-metadata-setter-20260920.log`
  and `/tmp/macws-shader-cache-metadata-pathapi-20260920.log` on the development
  Mac. Each capture only loaded framework metadata, not a Metal device, command
  queue or shader. Code reads were bounded small function neighborhoods.

RE-confirmed entry points:

| Image-relative offset | Observed operation |
|---|---|
| `0x983e4` | exported `MTLSetShaderCachePath`; `+0x983f0` sends `UTF8String` to its first argument, then tail-calls `0x463d0` |
| `0x463d0` | `setShaderCacheMainFolder(const char*)`; locks, compares the existing path, refuses a different path after first cache use or first path assignment, otherwise copies the caller's string into process-local state |
| `0x981d4` | exported `MTLGetShaderCachePath`; once-cached NSString result derived from `getShaderCacheMainFolder` |
| `0x4ad74` | `getCacheMainFolder`; if the override exists, copies and returns that exact path before the normal user-cache construction |
| `0x4adf0..0x4ae00` | normal path passes integer `65538` to the imported directory-query call; SDK `unistd.h` defines this as `_CS_DARWIN_USER_CACHE_DIR` |

The SDK Metal `.tbd` also exports `MTLSetShaderCachePath` and
`MTLGetShaderCachePath`. Their argument types above are based on the actual
device code, not an assumed undocumented header.

The actual setter's late-call guard means calling it in an already-running Word
is **not** a valid isolation experiment. It must run early in a new owned test
process. The observer calls the genuine getter after setting the path and reports
an error if the request was ignored. No class-wide constant-return hook, cache
read bypass or compiler-result alteration is used.

The framework also contains `MTL_SHADER_CACHE_SIZE` and `FS_CACHE_SIZE`, but this
investigation has **not** established that zero disables both reads and writes.
They are not used by this test. No guessed cache-directory environment variable
is used.

## Self-owned no-GPU control

`misc/macws_metal_cache_scope_observer.m` is not linked into production. Its
constructor creates an exclusive mode-0700 temporary directory, checks the
actual Metal UUID, invokes the two APIs, and verifies the returned path and
directory identity. It deliberately preserves the temporary directory for
inspection. It never removes or renames shared caches.

Built with Apple clang, `-arch arm64e -mmacosx-version-min=13.0 -fobjc-arc
-Wall -Wextra -Werror`, both as a dylib and with
`MACWS_METAL_CACHE_SCOPE_STANDALONE` for the no-device control. The actual control
on the iPad reported:

```text
METAL-CACHE-SCOPE READY pid=78319 requested=/private/tmp/macws-metal-cache-scope-78319-P5XEab actual=/private/tmp/macws-metal-cache-scope-78319-P5XEab inode=53537417 no-gpu=yes no-shared-cache-mutation=yes
METAL-CACHE-SCOPE-CONTROL status=0 path=/private/tmp/macws-metal-cache-scope-78319-P5XEab
```

Control log: `/tmp/macws-metal-cache-scope-control-20260920.log`.

## Required next acceptance (not yet claimed)

Inject only into the next **owned** Word process before any Metal cache use.
Require its `READY` line and actual new cache-pair paths beneath that directory;
do not infer isolation from injection success. Reproduce the same Save alert,
capture the compiler request/reply and actual pipeline result, then compare the
new `ciKernelMain` container with the old record. A changed cache alone cannot
distinguish a stale artifact from a current producer defect.

The old Word cache's native-macOS target is not by itself evidence that the
current iOS compiler target adapter emitted it. Precompiled/CoreImage-side
producers and the file's historical generation remain separate possibilities
until the new request and reply are observed.
