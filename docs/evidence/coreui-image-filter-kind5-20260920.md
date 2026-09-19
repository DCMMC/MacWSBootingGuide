# CoreUI image-filter request target provenance (2026-09-20)

This records the producer/ABI investigation and bounded candidate acceptance,
not final Office UI acceptance. No shared cache was cleared, no service was
restarted and no check or compiled-library header was bypassed for the
observations below. Candidate 1 passed the small CoreUI fixture but failed Word
86703. The actual Word request exposed an incorrect 16-byte container-alignment
assumption; candidate 2 corrected it to the genuine 8-byte producer contract.
Owned Word 87884 then passed the real fresh-cache Save-alert visual test.
The subsequent ordinary shared-cache launch, Word 2999, still failed; see
[the separate default-cache acceptance](word-default-cache-acceptance-20260920.md).
Safe migration and final default-launch acceptance remain outstanding. Shared
caches and the user's running applications have deliberately not been migrated
or restarted.

## Discriminating runtime evidence

The owned Word Save-alert capture reports a real failed `ciKernelMain` compute
pipeline while drawing the Save button (`cacheDisplay`, button 2):

```
CI-PIPELINE-OBS pid=77878 selector=newComputePipelineStateWithDescriptor:options:reflection:error: function=ciKernelMain error=Error Domain=AGXMetal13_3 Code=3 "Target OS is incompatible."
```

Record: `/tmp/macws-word-alert-pipeline-20260920.log`. A separately owned Word
process, PID 79289, using the genuine Metal cache-path API and a newly created
private cache, reproduced the same failure. Therefore an old shared cache alone
does not explain it, and a cache-schema bump alone is not a demonstrated repair.

The root agent then reproduced it without Word or UI: a 16-pixel
`CUIHueSaturationFilterLocal` graph (`setDefaults`, synthetic input, real GPU),
`/tmp/macws-coreui-hue-fresh-cache-20260920.log`. The request capture identifies
the real native compiler request as **kind 5**, not the existing DAG kind 14:

- input `raw-80913-001-5-139840-17d210668e484ab2.bin`, 139840 bytes,
  SHA-256 `c198cb4af834a1ee6676b30049c6c5838291636cad4c48022ca94650a1c0b2b0`;
- header words: `(21, 372, 2, 1168, 0)`;
- module 0: offset `0x4a0`, length 118544;
- module 1: offset `0x1d3b0`, length 20112;
- both embedded AIR target witnesses are `air64-apple-macosx13.4.0`;
- reply `reply-80913-001-12872-bbf068d562e288c3.bin`, MTLB starts at byte 104,
  retaining the macOS target (`0x81` target discriminator).

The audio agent's isolated native replay produced byte-identical replies with
and without a genuine `GPUCompiler::getDefaultTargetTriple` Catalyst optional
argument. The hook ran during service creation, not during kind-5 compilation.
This rules out merely extending the current kind-14 factory scope to kind 5.

## Actual producer chain

All offsets are image-relative and come from the device's actual code, not from
an assumed SDK implementation.

1. CoreImage UUID `780B768C-4B54-36C3-AC8E-9D6138C86592`,
   `CIMetalComputePipelineStateCreateFromDAG` at `0x2b35c`, calls
   `CreateFunctionFromDAG`; `0x2b3e0` invokes
   `newLibraryWithImageFilterFunctionsSPI:imageFilterFunctionInfo:error:`.
2. Metal UUID `2BAB169C-42DA-36E3-955A-F30B709EC2AD`, method `0x22ef4`,
   delegates to `newLibraryWithCIFilters:imageFilterFunctionInfo:error:`.
   Builder `0x22f0c` gathers the original function AIR modules. At `0x23918`
   it writes kind 5, and `0x23998` calls `newLibraryWithRequestData`.
3. Metal `initLibraryContainerWithRequestData`, `0xebb20`, hashes/looks up the
   request. On a miss, `0xebf38..0xebf3c` copies its unchanged request type into
   the compiler message. The runtime capture confirms native service `a2=5`.
4. Native MTLCompiler UUID `482EE528-9D70-3ED7-A746-D19BB741245B`,
   build dispatch `0x2488`, jump-table entry 5 at `0x80b7c + 5*4`, selects
   `0x2710`. The case parses the original AIR modules. `0x75d14` resolves
   `composeImageFilterFunctionsFromModulesSPI` from native
   `/System/Library/PrivateFrameworks/GPUCompiler.framework/Libraries/libComposeFilters.dylib`.

Captured code/metadata records on the development Mac:
`/tmp/macws-coreimage-dag-producer-code-v8-20260920.log`,
`/tmp/macws-metal-image-filter-builder-20260920.log`,
`/tmp/macws-metal-library-container-map-20260920.log`, and the already preserved
`tmp/MTLCompiler-text-20260913.bin` with its matching image/UUID records.

## Native composition and ownership boundary

Fresh self-process, read-only capture identifies native libComposeFilters UUID
`BEAEC489-ED9B-3F62-B645-BC10399B2D18`. Its text is only `0xbff8` bytes; the
capture was split into 32768-byte and 16376-byte bounded reads. No GPU operation
or compiler request was made by this metadata reader.

`composeImageFilterFunctionsFromModulesSPI` begins at `0x9bb8` with bytes
`7f2303d5ff4304d1fc6f0ba9fa670ca9`.

The actual MTLCompiler caller at `0x31e0..0x31f0` passes:

| Register | Observed argument |
|---|---|
| x0 | address of the parsed module-pointer vector |
| x1 | address of the selected function-pointer vector |
| x2 | address of the filter-info vector |
| x3 | address of the error-output pointer |
| x0 result | generated LLVM function pointer; caller obtains its owning module |

The module container's first two words are begin/end addresses; the callee
computes `(end-begin)/8` and consumes each 8-byte module pointer. This proves the
wire/ABI access pattern, **not** an arbitrary C++ container ownership typedef.
Do not construct, destroy, reinterpret as an unverified `vector<unique_ptr<...>>`,
or retain this container beyond the real call.

- For one module, `0x9c10` loads it and `0x9c60` tail-calls
  `composeImageFilterFunctionsSPI` at `0x4b2c`.
- For multiple modules, `0x9dec..0x9df0` picks module 0 as destination.
  `0x9e20` invokes the genuine `llvm::Linker::linkModules` on every remaining
  module. Native import resolution confirms this symbol; it is not a guess
  based on its argument shape.
- `0x9f7c` passes the merged first module to `composeImageFilterFunctionsSPI`.
- The latter retains its original module as x20 (`0x4b60`); at
  `0x93b8..0x93d0` it constructs the optimization Triple from that module's
  target string. The same field is independently exposed by `LLVMGetTarget`.
  `0x9590` runs the real pass manager on the original module.

The input modules, not the service's default-target factory, therefore supply
the target used by this actual kind-5 path. A compatibility translation must
occur before their real linker/composer and preserve the original composition,
verification and error handling.

## Verified upstream API, not opaque field writes

Native `/usr/lib/libLLVM.dylib`, UUID
`3C9D9D6C-CC92-326A-911C-141BC96DC8BE`, exports:

| API | Offset | First 16 bytes |
|---|---|---|
| `LLVMGetTarget(LLVMModuleRef)` | `0x844fb0` | `e80300aa0060039108bdc3394800f837` |
| `LLVMSetTarget(LLVMModuleRef, const char *)` | `0x844fcc` | `7f2303d5f44fbea9fd7b01a9fd430091` |

The real setter obtains the string length and tail-calls the actual module
target-string implementation. An implementation should call this API, not write
LLVM's string/Triple storage. Fresh runtime imports/prologues:
`/tmp/macws-compose-imports-v2-20260920.log`; Compose text/UUID:
`/tmp/macws-composefilters-{entry,target,exports}-20260920.{bin,log,trie}`.

Candidate review constraints (not yet a production acceptance claim): only a
strictly validated all-macOS-13.4 kind-5 request may establish a synchronous
scope; validate every live module target before changing any; preserve all four
arguments, return/error values and the actual composer. Unknown, mixed or
already-Catalyst input must retain its original behavior. Because the original
linker consumes secondary modules, never restore or inspect saved module
pointers after it returns. Genuine API/UUID/prologue validation must remain.

## Reviewed production implementation

The candidate in `MTLCompilerBypassOSCheck/Tweak.x` implements those constraints:

- Only request kind 5 whose bounded container classifier recognizes **every**
  source module as macOS 13.4 enters the compatibility scope. It does not modify
  the request bytes. The existing kind-14 path is separate and unchanged.
- The compiler-request write lock covers lazy adapter installation and the
  entire real build call. Module count is thread-local, with its previous value
  restored when that synchronous call returns; other request kinds clear the
  scope while they run.
- Compose and both LLVM C APIs require the exact image UUID, image-relative
  offset and instruction prologue recorded above. Pointer authentication is
  removed with the existing architectural code-pointer helper, not by rounding
  or masking away valid low instruction-address bits.
- The wrapper reads only the verified vector ABI: aligned, ordered begin/end/
  capacity addresses, exact count matching the classified request, bounded to
  4096 modules. It rejects null and duplicate module pointers. It does not
  construct a guessed C++ container or access fields inside an LLVM module.
- Validation is two-pass: genuine `LLVMGetTarget` must return the exact native
  target for **all** live modules before any genuine `LLVMSetTarget` changes one
  to `air64-apple-ios19.0.0-macabi`. Unknown, mixed, native-iOS and
  already-Catalyst targets retain the original compose behavior.
- All four arguments and the real compose result/error are passed through.
  There is no validation bypass, fabricated function, header edit or access to
  module pointers after the original composer can consume them. Production
  activation depends on the actual request contract, not a diagnostic flag.

Independent review found no normal-path ABI, endianness, TLS or lifetime
violation. One existing hook-installation limitation remains: a partial
`MSHookFunction`/RX-restoration failure has no transactional rollback. A false
ready state is not proof that the entry text remained unchanged. This is not an
observed failure in the accepted candidate (`restore-rx=0`), and the tests below
do not simulate the Substrate implementation or claim to fix that limitation.

## Native replay and actual AGX acceptance

The independently compiled, owned native process replay used the unchanged
139840-byte capture and preserved all four compose arguments. Its UUID/offset/
prologue guards passed for the composer and both LLVM APIs. The real getter
reported both modules as macOS 13.4 before the genuine setter, and Catalyst 19
afterwards:

```
KIND5 compose module=0 after=air64-apple-ios19.0.0-macabi
KIND5 compose module=1 after=air64-apple-ios19.0.0-macabi
KIND5 compose accepted=1 calls=1 changed=2 vector-unchanged=1
KIND5 callback result=0 bytes=12888 error=nil compose-calls=1 changed=2 failure=0
KIND5 complete status=0 compose-calls=1 changed=2 raw-sha-unchanged=1
```

Record: `/tmp/macws-kind5-compose-catalyst-replay-20260920.log`.

| Replay | Reply bytes | Reply SHA-256 | Original compiler's MTLB target |
|---|---:|---|---|
| Unchanged baseline | 12872 | `09ff2a8232a6395ad247163b07e2ccb4db48271aedac525468429ee983d10578` | macOS, `0x81` |
| Default-Triple-only control | 12872 | `09ff2a8232a6395ad247163b07e2ccb4db48271aedac525468429ee983d10578` | macOS, `0x81` |
| Genuine pre-compose module setter | 12888 | `aa8ae57a304a7dc044381f9d6fe2e3caff9d73e4595cb5c98a3e58bd151cf3fc` | Catalyst, `0x86` |

The header difference alone is not acceptance. The resulting library was also
loaded by the macOS Metal client and a genuine `ciKernelMain` pipeline was
successfully created on the real Apple M1 AGX device:

```
CI-PROBE device=Apple M1 class=AGXG13GFamilyDevice
CI-PROBE library=0x13270ad10 error=nil
CI-PROBE function=0x122828a90 pipeline=0x122829e40 error=nil
```

Record: `/tmp/macws-kind5-compose-catalyst-agx-20260920.log`. This establishes
library/pipeline admission, not rendering by itself.

The root agent subsequently tested the actual candidate through a fresh native
compiler worker and the owned CoreUI graph. Worker 86076 recorded
`MacWS image-filter module-target count=2 adapted=1`; the graph then produced:

```
CI-PROBE filter=CUIHueSaturationFilterLocal compiler-contract=image-filter
CI-PROBE pixels=256 visible=256 changed-bytes=226 varied-bytes=672 dags=0 hash=2842d1a2e7ace5d7 first=140,0,0,255 last=240,240,80,255
```

Records: `/tmp/macws-compiler-kind5-deploy-20260920.compiler.log` and
`/tmp/macws-compiler-kind5-deploy-20260920.probe.log`. This was an explicitly
fresh, process-private cache, with no mutation of a shared cache. A read-only
mapped-worker UUID query was denied (`task_for_pid=5`), so no mapped-UUID PASS
is claimed; the deployment receipt separately records the published artifact
and the new worker's actual candidate-specific request handling.

## Executable regression coverage and remaining acceptance

`misc/test_metal_image_filter_compose.py` extracts the **actual production
wrapper** from `Tweak.x`, compiles it as C with UBSan and `-Werror`, then executes
21 owned-memory scenarios across six tests. These verify bounds/count failures,
duplicate/null modules, last-module unknown/native-iOS/Catalyst/null targets
causing zero setters, all-native conversion only after every target validates,
unchanged vector/arguments, exact original result and error propagation, and an
unmasked original failure. The simulated original composer marks both its
module and table pages `PROT_NONE`; any later wrapper access would fault. All
six tests passed.

The initial kind-5 container classifier had 12 passing executable tests; the
Word-driven correction below brings it to **15**. They include both captured
packet geometries, truncation, alias/overlap, opaque metadata, unknown/mixed
targets, zero-padding bounds, unrounded table lengths and the actual statistics
flag. It deliberately does not claim to validate LLVM IR in place of Apple's
compiler. Independently rerunning the final classifier plus compose tests gives
21 tests passing (15 classifier + 6 wrapper).

The full local regression run reports:

```
Ran 439 tests in 53.564s
OK (skipped=12)
```

Final local record: `/tmp/macws-kind5-word-regression-suite-20260920.log`.
The earlier `/tmp/macws-kind5-regression-suite-20260920.log` records 436 tests
before the three additional Word-derived cases. Skipped tests are not passes.

## Candidate 1 Word failure, real layout correction, candidate 2 acceptance

The initial real-Word test was **FAIL**, despite its fresh process-private cache:
Word 86703's Save button was transparent and the pipeline still reported
`Target OS is incompatible`. Keeping that failed acceptance separate from the
small CoreUI success led to the exact request, rather than a cache workaround.

The captured Word request is
`/tmp/raw-87122-001-5-139288-7abde80b00408403.bin`, SHA-256
`ca0362c33b4038e7cf20fed2884f28dc028e5af549dc41f804ce81312c9c79b7`.
Its header is `(9, 0xb4, 2, 0x268, 0)` and module table is
`(0x278, 0x1cf10, 0x1d188, 0x4e90)`. Both modules have the same supported native
target, but the first module starts at `0x278`, which is 8-byte aligned and
**not** 16-byte aligned. Candidate 1's stricter check incorrectly declined
adaptation and left the real native-macOS target untouched.

RE of actual Metal UUID `2BAB169C-42DA-36E3-955A-F30B709EC2AD` proves the
correction: `0x23500..0x23510` rounds the section sizes to 8 bytes;
`0x23608..0x23610` advances modules by `align8(originalLength)`; the table stores
the original length at `0x23840/0x23850`. `0x236b0..0x236e8` may also set the
genuine statistics bit `0x200`. Candidate 2 accepts that exact layout, preserves
the statistics flag, and still rejects unknown bits, aliases, overlap, truncated
modules and nonzero padding. It does not relax Apple's LLVM/compile validation.

Candidate 2 publication is recorded in
`/tmp/macws-compiler-kind5-word-publish-20260920.json`: signed SHA-256
`164652ab63384b51c30d094cabe95b912aad877b6992a369057f001d4aaf8cc9`,
classifier source SHA-256
`f7a1e0fcc35923a5fd679ffb11aff6a53744c7daef8d4d8f10708a709fc2d991`.
The existing compiler workers and protected user applications were not restarted.

The subsequent owned Word **87884** used a fresh scoped cache. New native
compiler **87918** received the real **139288-byte** request and logged:

```
Image-filter target context installed=1 restore-rx=0
MacWS image-filter module-target count=2 adapted=1
```

Its real kind-5 reply was 10776 bytes. Records:
`/tmp/macws-word-alert-kind5-word-capture-20260920.compiler.log`, matching
`.log` and `.capture.json`. The root agent inspected the raw window capture,
Save-button bitmap and full iPad screenshot; the latter was independently viewed
for this evidence review. The Save button is again visibly blue with its label:
`/tmp/macws-word-kind5-word-fixed-alert-20260920.png`.

**Acceptance boundary:** this is an actual fresh-cache Word Save-alert PASS, not
merely process uptime or a synthetic shader result. It does **not** establish
that already-cached incompatible libraries in the ordinary shared cache are
healed. That cache has not been migrated while the user's existing apps are
using it, and full default-launch/shared-cache acceptance remains outstanding.
