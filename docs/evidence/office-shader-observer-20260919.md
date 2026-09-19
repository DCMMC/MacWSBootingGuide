# Office specialization observer — 2026-09-19

## Scope and status

This is an **explicit process-local diagnostic, not a production fix**. Its
source is `misc/macws_office_shader_observer.m`; no production Makefile links it.
It does not change a library, function constant, shader, GPU resource, command,
return value, error, or fallback. There is no constructor, environment switch,
code-page patch, guessed concrete class, or extra device/queue creation.

The earlier upload observer installs its device observer only when a selected
image is drawn. That is too late to exclude an earlier Office library or
function-specialization failure. This separate observer leaves the frozen v4
upload artifact unchanged and observes the app's own public device factories:

1. Forward `MTLCreateSystemDefaultDevice` / `MTLCopyAllDevices` exactly once.
2. On each actual returned device, verify the complete Objective-C signature
   and observe `newLibraryWithData:error:`.
3. On the actual returned library, verify the complete signature and observe
   `newFunctionWithName:constantValues:error:`.
4. Log at most eight `bitmap*` specialization calls, including real result,
   error domain/code/description, or propagated original exception. Constants
   and caller error-slot pointers are recorded, not altered or introspected.

Library loads have a separate eight-sample budget; each registry contains at
most eight actual concrete classes. Distinct typed entries preserve subclass
overrides that call an already observed superclass without recursive dispatch.
Inherited methods are added to the observed class rather than changing an
unobserved superclass or sibling. Successful calls do not inspect the caller's
possibly untouched error slot. The observer preserves original `errno` and
exception behavior; logging exceptions cannot replace an original result.

Coverage is deliberately limited to those two actual factory routes and the
synchronous data-library / constant-function methods. No log is not proof of
success: readiness and load logs must first show that the actual route was
observed. In particular, an already-created device or a different public
library-creation overload is not inferred to be covered.

## Local executable verification

`python3 -m unittest misc.test_office_shader_observer -v`: **2 tests PASS**.
The executable test uses real Objective-C dispatch with fake device/library
objects, never a real GPU. It verifies original argument identities, returned
object/nil, unchanged `NSError **` including NULL, success with an intentionally
invalid untouched error-slot value, errors, exceptions, `errno`, exact factory
call counts, sample budgets, signature rejection, sibling preservation, and
subclass override-to-super forwarding. This is not a claim that Office itself
has been fixed or that an actual specialization has succeeded.

Apple clang/ld64 strict `-Wall -Wextra -Werror -O2`, MRC/blocks, macOS 13 target,
arm64 + arm64e build passed. Artifact before any device signing:

| Item | Identity |
| --- | --- |
| Artifact | `/tmp/macws_office_shader_observer-20260919.dylib` |
| SHA256 | `603a12bbfcede5bab3d0e511aad868072875c67ed064afbab5fb9b8b42f62ec9` |
| arm64 UUID | `4BF4B9BB-5D18-3EC3-A1A8-F233C358EC20` |
| arm64e UUID | `E464E7BD-D9F5-3ECC-B3C5-47D65B1C8051` |
| Source SHA256 | `c03fe23ee21747773ea44f016fe39f2853970a43e9c113d7269afa02baa3162b` |

No device operations were performed while building/testing this observer.

## Bounded allocator RE, a disconfirmed alternative

RE-confirmed from actual Office 16.91 `mso40ui`, arm64 UUID
`08F30267-C97A-30FB-A4BB-43186407CDB2`, local thin image
`/tmp/macws_mso40ui_arm64`:

- The pooled NoCopy call at `+0x1283b0` uses length `P << bucket`, where
  `+0x128354` calls `+0x127a00` and `+0x127a3c` calls the real `_getpagesize`.
  The cached page value lives at `+0xae04c8`; supported buckets are 0 through 8.
- The slot pointer at `+0x1279bc..0x1279cc` is the VM pool base plus
  `slotIndex * (P << bucket)`, not an arbitrary byte suballocation.
- Both pool and direct owners reach `+0xde844`. It calls `_getpagesize` at
  `+0xde87c`, rounds requested length as `(request + P - 1) & -P` at
  `+0xde880..0xde898`, then calls `_vm_allocate` with flag 1 at `+0xde8b0`.
- The direct NoCopy call `+0x1286dc` receives the VM address from owner `+8`
  and the rounded allocated length from owner `+0x18`, not the unrounded
  requested length stored at owner `+0x10`.

Therefore the proposed separate hardcoded-4096-byte pooled allocator is **not
supported by this binary**. If the actual process's `getpagesize()` agrees with
native `vm_page_size`, these two paths meet the current native-page alignment
predicate by construction. The actual runtime equality is a separate witness;
the RE alone does not establish its value. No production alignment guard was
broadened on the basis of this theory.
