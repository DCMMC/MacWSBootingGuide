# Office bundled Metal library target mismatch — 2026-09-19

## Actual application failure, not a texture-format inference

Runtime-confirmed in the bounded observer on owned PowerPoint process 44208,
`/tmp/macws-ppt-shader-observed-20260919.log`:

```text
OFFICE-SHADER load pid=44208 sample=1/8 device=0x1498a8400 data=0x158ecddd0 error-slot=0x16dcdae98 library=0x158ee08e0 class=_MTLLibrary domain= code=0 description=
OFFICE-SHADER function pid=44208 sample=1/8 library=0x158ee08e0 class=_MTLLibrary name=bitmapVS constants=0x138b3acd0 error-slot=0x16d15dc98 result=0x0 domain=MTLLibraryErrorDomain code=3 description=Target OS is incompatible. exception=
OFFICE-SHADER function pid=44208 sample=2/8 library=0x158ee08e0 class=_MTLLibrary name=bitmapIgnoreSrcAlphaPS constants=0x138b3acd0 error-slot=0x16d15dc98 result=0x0 domain=MTLLibraryErrorDomain code=3 description=Target OS is incompatible. exception=
```

All eight observed specialization calls failed with the same real error,
including `bitmapCubicPS` and `bitmapPS`. The library load itself succeeded.
This is upstream of drawing the image: a non-nil library does not mean that its
requested functions or render pipeline can be created. The observer forwarded
the application's actual constant values and retained the original errors.

The standalone exact-shader negative control independently reproduced this in
`/tmp/macws-office-actual-bitmap-shader-20260919.log`:

```text
library=/private/tmp/libmachook-nocopy-arm64-20260919.dylib subtype=0 uuid=92820a6ab26e391f899c786575cee126
office-fixture bytes=155074 sha256=9eac296d60f976a0ef4e1cfe90b440101045b4eaed437af3a6dd803997959a02
shader-library=non-NIL error=none
office-function-constant name=hasStencil index=0 type=53 required=1
office-specialize name=bitmapVS hasStencil=0 result=NIL error=Error Domain=MTLLibraryErrorDomain Code=3 "Target OS is incompatible." UserInfo={NSLocalizedDescription=Target OS is incompatible.}
office-specialize name=bitmapPS hasStencil=0 result=NIL error=Error Domain=MTLLibraryErrorDomain Code=3 "Target OS is incompatible." UserInfo={NSLocalizedDescription=Target OS is incompatible.}
shader-render-contract=FAIL
```

The same device/library had passed ordinary compute sampling and fragment
sampling with newly compiled diagnostic shaders. Those controls establish that
the owned NoCopy texture can be sampled; they do **not** validate Office's
bundled AIR or disprove a bundled-library target incompatibility.

## Exact original resource and shader ABI

The installed archive is:

```text
/Applications/Microsoft PowerPoint.app/Contents/Resources/Arc.bundle/Metal2DShaders.metallib.zip
```

Its one ZIP member is `Metal2DShaders.metallib` (155074 bytes), without a leading
slash. RE-confirmed in actual Office 16.91 `mso40ui` UUID
`08F30267-C97A-30FB-A4BB-43186407CDB2`: resource lookup at `+0x1269e8` uses
`Metal2DShaders` / `metallib.zip`; the ZIP API at `+0x126a18` is passed the string
`/Metal2DShaders.metallib`; `+0x126a28` registers the returned data as `Metal2D`.
The ZIP API's lookup string must not be mistaken for the archive member name.
See [the actual upload/shader call sites](office-upload-observer-20260919.md).

The original library has 28 functions and AIR target
`air64-apple-macosx13.0.0`. The original and converted binary AIR were inspected
with LLVM 15, not inferred from filenames. Actual AIR and stock Metal pipeline
reflection agree on the following `hasStencil=false` bitmap contract:

| Stage | Binding | Actual data |
| --- | --- | --- |
| Vertex | buffer 0 | `float2` vertices, 8-byte stride/alignment |
| Vertex | buffer 2 | `float4x4 xfrm`, 64 bytes, 16-byte alignment |
| Vertex | buffer 3 | `float3x3 bmpXfrm`, 48 bytes: three padded 16-byte columns |
| Fragment | buffer 0 | opacity, one 4-byte float |
| Fragment | texture/sampler 1 | bitmap texture and sampler |
| Both | function constant 0 | required boolean `hasStencil` |

`bitmapVS` negates the transformed position's y component. `bitmapPS` samples
the original bitmap and multiplies RGBA by opacity. The owned test reproduces
these bindings and the y transform; it does not replace the Office shader with
a look-alike shader. The `hasStencil=true` branch additionally uses the real
stencil inputs and was not covered by this first pixel acceptance.

## Full-library translation, not a check bypass

The existing `metal2metal.py translate` workflow was used with its default
`ventura13-ios19-macabi` profile, packaged Apple `macws-llvm-dis` / `macws-llvm-as`,
`--auto-lower-known-air`, a full ABI report, and a runtime manifest. It converted
the complete 155074-byte library, not a selected subset of functions. The
single device conversion was under a 40-second timeout, completed in about
1.8 seconds, and did not run GPU work, install routes, or modify applications.

```text
converted=28/28 lowerings=0 target=air64-apple-ios19.0.0-macabi container_target=macabi bitcode=150384->141600 bytes file=155074->146290
```

Provenance:

| Artifact | SHA-256 |
| --- | --- |
| Original library, 155074 bytes | `9eac296d60f976a0ef4e1cfe90b440101045b4eaed437af3a6dd803997959a02` |
| Apple-tool translated library, 146290 bytes | `aa77bee44d63d653b142366cb02d28d5e1a8fa5b682df9acc5b86b2eb0490df5` |
| Packaged `macws-llvm-dis` | `946514b1318b11ad8b5e610c508714a3f7348086ecf1145e1b1aca706f862ecd` |
| Packaged `macws-llvm-as` | `aed878b2b1edf9365f71d36722f220c2f7b84c38879e965d5c88f6c58e8570b5` |

Both versions of **all 28 modules** were disassembled independently. After
normalizing only the file-specific `ModuleID` comment and the intended target
triple change, their complete IR text is identical: instructions, function
constants, stage declarations, binding metadata, and all remaining metadata.
The verifier printed `function_count=28 semantic_text_mismatches=0`. The full
runtime manifest also passed verification. The different bitcode size is not
evidence of removed shader logic; this comparison checks the actual decoded IR.

No target-validation instruction was patched, no check was forced true, and no
function result/error was fabricated. The production provisioner generates
and validates the whole artifact before publishing its manifest. The initial
translated-library experiment used the older unique complete-function-name-set
router; that alone was not a hash measurement of the application's in-memory
`dispatch_data_t`. The subsequent production review below strengthened this
boundary rather than treating the initial experiment as proof of provenance.

## Actual translated-shader pixels

The probe uses RGBA8Unorm (70), Managed NoCopy source memory, width309/height250,
source stride1248, late CPU writes to the **original mmap pointer**, real
`didModifyRange:`, and the original Office `bitmapVS` / `bitmapPS` functions.
It renders through a real render command encoder to a Shared target, then
checks all 77250 pixels and row padding. It has one queue, one GPU submission,
a ten-second alarm, and less than 1 MiB of owned pixel storage.

Runtime-confirmed on the iPad in
`/tmp/macws-office-translated-bitmap-shader-20260919.log` with the same
`92820a6a-b26e-391f-899c-786575cee126` hook-library generation as the failed
original-library test:

```text
nocopy alias=1 requested-storage=1 actual-storage=1 length=327680 early-callbacks=0
texture format=70 type=2 usage=1 requested-storage=1 actual-storage=1 shape=309x250 mips=1 samples=1
office-fixture bytes=146290 sha256=aa77bee44d63d653b142366cb02d28d5e1a8fa5b682df9acc5b86b2eb0490df5
office-specialize name=bitmapVS hasStencil=0 result=non-NIL error=none
office-specialize name=bitmapPS hasStencil=0 result=non-NIL error=none
pipeline=render result=non-NIL error=none
office-reflect vertex-mask=7 fragment-mask=7 contract=PASS
phase=render status=4 error=none
phase=render mismatched-pixels=0/77250 mismatched-bytes=0/309000 first=17,29,47,128 last=125,166,190,173
render-modified-padding=0
callbacks-after-drain=1 callback-mismatch=0
shader-render-contract=PASS
```

Stock macOS also passed both Managed NoCopy and ordinary-texture controls with
this exact Apple-tool output. Local logs are
`/tmp/macws-office-apple-translated-nocopy-local-20260919.log` and
`/tmp/macws-office-apple-translated-plain-local-20260919.log`.

This establishes a real library-target failure and its shader-level correction.
It does **not**, by itself, certify every Office drawing mode, stencil path, or
the real document's thumbnails. Actual fresh-application route/picture
acceptance is a separate required step; the user's unsaved process19000 was
not closed or modified for these experiments.

Private artifact locations for reproduction (not checked into the repository):

- Original extracted archive/library and comparison scripts:
  `/tmp/macws-office-metallib-re.YNSvYC/`.
- Device Apple conversion, ABI report, and manifest:
  `/tmp/macws-office-apple-translation.TKDjjU/`.
- Apple-output test executable:
  `/tmp/macws_office_apple_translated_shader_probe_mac_arm64_20260919`, SHA-256
  `09396b43783ec06dfdf71d4be965adc288362a6827c9a77801e695bc7121f0a4`.
- Its fixed input fixture:
  `/private/tmp/macws-office-Metal2DShaders-macabi-apple-20260919.metallib`.

The translated-fixture helper differs from the repository diagnostic only in
the fixed fixture path, size, and expected SHA. It does not accept arbitrary
input files or relax the shader/pixel checks. No proprietary binary fixture is
part of the repository.

## Production-chain independent review

The later production router observes the **actual bytes passed through the
successful public data constructor**. It associates only a unique exact
size/SHA-256 match to a fully verified route. Observed nonmatches, mapping
failures, duplicate identities, and ANGLE/Stray substitutions receive an
authoritative negative result; they cannot fall back to a same-names library.
The original constructor's arguments, library result, and NSError are kept.

Office-generated manifests additionally contain `requires_source_identity=true`.
The generic private-library name fallback refuses every route carrying this
policy, including malformed/false values, rather than treating names as
source identity. Existing system manifests without this policy retain their
prior fallback. Already-attributed exact Data/URL routes do not use that
fallback and continue normally. Cached Office manifests lacking the policy
are rebuilt and atomically replaced before reuse.

Provisioning runs on the ordinary startup/package boundary without an enable
marker. Derived AIR/manifests persist, but the optional speed cache is only in
`/tmp` and includes the boot UUID. Sources, artifacts, manifests, and helper
identities participate in its fingerprint; timestamps retain nanosecond
precision so same-inode/same-size changes within one second cannot reuse an
earlier successful stamp. A missing stamp always reaches verification, not a
disabled Office path.

Discovery/conversion errors are isolated per application/source version:
healthy Office libraries are still provisioned when another ZIP is damaged.
The overall helper returns failure after that partial success, so the shell
does not publish a success stamp and later preflight retries. Original app
archives and previous generations are preserved. Complete source/output files
are linked durably under fresh names before atomic publication of the route;
failed conversion/verification does not publish a partial route.

The new identity work occurs at library admission, not per rendered frame:
manifest files are validated once per process; candidate source sizes are
checked before mapping/hashing; later function requests use positive/negative
associated-object caches. No new timer, per-frame filesystem lookup, or
production debug logger was added. Live processes keep their previously
admitted route generation; refreshing new routes requires a fresh application
process, not a forced restart of an unsaved user document.

Executable host regressions cover exact/foreign/duplicate data, unchanged
constructor errors, negative-cache reuse, strict-policy name collisions,
system fallback preservation, old manifest migration, multiple Office
versions, mixed corrupt/healthy installs and repair, publication failure,
concurrent provisioning, source/output corruption, missing cold-start routes,
tool timeout, and same-second fingerprint changes. Their fake converter tests
transaction handling; actual AIR semantics and GPU pixels are established by
the independent witnesses above, not by the fake converter.
