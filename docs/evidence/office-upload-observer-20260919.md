# Bounded Office upload observer, 2026-09-19

This is diagnostic tooling, not a renderer fix. `misc/macws_office_upload_observer.m`
is not linked into libmachook. Inject it only into an explicitly owned test
PowerPoint process. No flag file, service restart, command submission, or
production-library change is part of this helper.

The four selected image sizes are 284×102, 309×250, 282×28, and 471×56.
Post-`CGContextDrawImage` sampling uses only the real bitmap-context data pointer,
validated stride×height, and at most 1 MiB per draw. Eight numeric ranges are
remembered; they are not retained allocations and are never independently
dereferenced. Address reuse is therefore a possible correlation ambiguity, not
proof of image identity. Logs distinguish full span from the sampled prefix.

## Versions and receipts

All builds below used Apple clang/ld64, arm64+arm64e, macOS 13.0 minimum, MRC,
blocks, and `-Wall -Wextra -Werror`. Files are local `/tmp` diagnostics, not
package payloads.

| Version | Source SHA-256 | Dylib SHA-256 |
| --- | --- | --- |
| v1 | `1830bd6919836364c41537a667a3b3124a922def07367fe981e21875f8378c0d` | `e8c7d215a9a3b501a842ea4c5966b3bcc52db697092f1bcb77db5a531963cf5c` |
| v2 | `7ced13e0571b732d025bd73e18d4b2e821182875178d90bbd1978fe8cf512fa4` | `4bbf24812a5ab085d75ab79e620474887a94b509940ebad8824cbb5f8ec391de` |
| v3 | `cc1ee4f3c87369bac93243b59c59f4f198981bb24b14bfaf9b052ea512653e11` | `10f435a417cbcc474782c132772edbecabb7244141770a03b2b08b3fa84986be` |
| v4 | `a823bde29e87296ded9dcf39c9f2b9de9a9bba0710621098b352e190168379d4` | `e512f3d4f6295afd0918830658eca48729e4cfa6608cfe89638cd8310a2cdbac` |

v2 file: `/tmp/macws_office_upload_observer-v2-20260919.dylib`, UUIDs
`A3DE3925-53B9-33EE-9D85-4AA2FA13D6E9` / `B61EC229-8241-32AB-B62C-A64447193400`.

v3 file: `/tmp/macws_office_upload_observer-v3-20260919.dylib`, UUIDs
`36A9CB95-2FE7-3878-9F8F-B887542888AF` / `79A0E06D-5D3A-316D-B85A-3B3BFDB709F7`.

v4 file: `/tmp/macws_office_upload_observer-v4-20260919.dylib`, UUIDs
`6DBA33C4-6543-30F4-80E8-391C1DFC4008` / `402E8BE3-935D-307F-8909-2F3EF9B0E2E0`.

v1 observed CPU pixels, matching public NoCopy calls, and eight completed command
buffers. v2 moved the completion budget to fixture draw ordinal ≥5 to avoid
spending it on startup thumbnails. It added the actual returned blit-encoder
class's public buffer→texture copy method. v3 adds the actual returned NoCopy
buffer class's public `newTextureWithDescriptor:offset:bytesPerRow:` method.
Each original implementation receives exactly its original selector/arguments;
NoCopy deallocators are not wrapped or invoked. Installations validate full
public type encodings and override only the concrete observed class, not an
inherited Method shared with sibling classes.

v3 also contains a bounded matched-blit readback route. Only eight actual encoder
creation calls after draw 5 may allocate records. Encoder and command completion
independently retain the record; the record stores neither object, avoiding an
encoder/command retain cycle or unretained command pointer. Only one matching
copy reserves a CPU hash per record. Completed-status Shared 2D, single-sample,
level/slice-zero RGBA8/BGRA8 (including sRGB) regions ≤1 MiB are supported.
Source span and destination region are checked before reading. CPU and GPU
hashes cover identical tight rows, excluding padding. Private textures and
unsupported requests are reported as skipped. Completion clears/releases the
record's texture. The buffer-backed-view route does not itself trigger this
blit readback.

## Local executable verification

`python3 -m unittest misc.test_office_upload_observer -v`: 2 tests PASS.

The fixture uses real CoreGraphics CPU bitmaps, not a GPU. It proves byte-for-byte
draw equivalence and the 1 MiB bound; fake Objective-C device/command/encoder
objects execute the real wrappers and test original argument/result/nil/error
and exception propagation, errno preservation, callback identity, class-local
installation, and observation budgets. It also checks readback region/span/Shared
guards, single reservation, post-completion texture release, and tight-row hash
comparison against owned CPU memory. This does **not** prove on-device texture
pixels or Office rendering. Actual injected-process receipts belong in the
Office diagnosis document; they must not be inferred from these unit tests.

## Actual Office shader/binding RE and v4 boundary

RE-confirmed in the captured Office 16.91 mso40ui arm64 UUID
`08F30267-C97A-30FB-A4BB-43186407CDB2`, not inferred from a nearby export:

| Image-relative offset | Original operation |
| --- | --- |
| `0x118d58` | Calls `0x11d080` to obtain the bitmap texture wrapper. That helper locks, calls `0x11d04c`, which returns cached bitmap+0x60 or asks bitmap+0x58 through `0x117080`. |
| `0x118d74–0x118d94` | Wrapper vtable+0x20 returns the actual texture; `x2=texture`, `w3=1`, then calls ObjC stub `0x607a00` = `setFragmentTexture:atIndex:`. The image is slot **1**, not 0. |
| `0x118ed0` | `setFragmentSamplerState:atIndex:` with index1. |
| `0x118ee0–0x118ef8` | Takes a float returned by the brush's vtable+0x38, stores it, and calls `setFragmentBytes:length:atIndex:` with length4/index0. This is the opacity observation point; its actual value still needs runtime proof. |
| `0x1190bc–0x1190cc` | `setVertexBytes:length:atIndex:` with length0x30/index3, containing the calculated transform. |
| `0x118c48–0x118ca4` | Creates functions named by CFString `bitmapVS` and formatted `bitmap%@PS`, then sets the pipeline's vertex/fragment functions. The bool constant at function-constant index0 comes from a comparison of state+0x80 with2 (`0x118c10–0x118c28`). Its semantic meaning is not established by that comparison alone. |
| `0x126f94`, `0x13a440` | The image's two direct callers of `newRenderPipelineStateWithDescriptor:error:`. No options/reflection overload selref was found in this image. |

The shader suffix lookup at `0x126a58` uses the table at `0x8b7360` for input
values2…9: `Mirror`, `Wrap`, empty, `IgnoreSrcAlpha`, `StraightSrcAlpha`, `Cubic`,
`IgnoreSrcAlphaCubic`, `StraightSrcAlphaCubic`; other inputs select empty. Do not
assign an enum name to that input without additional call-site evidence.

The target bitmap shader is bundled binary AIR/Metal data, not the unrelated ink
source strings also present in mso40ui. At `0x1269e8–0x1269fc`, actual imported
`CFBundleCopyResourceURL` receives `Metal2DShaders` and `metallib.zip`. At
`0x126a18`, imported `MBUCopyZipArchivePart` reads `/Metal2DShaders.metallib`.
At `0x126a28`, exported `ARC::Metal::RegisterMetalLibraryWithData` is called with
registration name `Metal2D`; the asynchronous loader calls
`newLibraryWithData:error:` at `0x13c834`. Bitmap function lookup with constants
reaches `newFunctionWithName:constantValues:error:` at `0x13d0b4`.

v4 discovers the actual render-encoder class from the real command buffer's
`renderCommandEncoderWithDescriptor:` result and validates complete public
method encodings before installing wrappers. It joins only returned selected
view pointers bound at fragment slot1 to the subsequent4B/48B constants; no
shader or constant is changed. Eight matched binds, opacity records, transform
records and bitmap pipeline creations are permitted. Unbinding/replacing slot1
clears the join; encoder creation clears old mask state. Pointer reuse remains
the ordinary limitation of non-retaining diagnostic correlation.

Slot0 binding stores only a numeric public-metadata snapshot, not a retained
texture. It is emitted when slot1 matches, distinguishing unobserved from an
observed nil slot0. Render-pass color0/depth/stencil texture and resolve metadata,
load/store actions, samples, levels and slices are similarly snapshotted without
retaining textures. Only a later matched image bind spends the eight-pass log
budget, avoiding startup noise. No private texture pixels are read.

The extended CPU-only test executes all v4 wrappers and verifies exact inputs,
original NSError/nil/exception/errno propagation, unbind behavior, 8-record
budgets, deferred pass logging, and a four-sample Private target with a one-sample
Shared resolve metadata control. It does not execute Office's real shaders.
