# AGX-direct page-fault dig: notes from Asahi Linux references

## Cloned repositories (under ~/Downloads/)
- `m1n1/` (Asahi Linux's bootloader + AGX research): has rich proxy-client GPU experiments
  - `proxyclient/m1n1/agx/`: high-level GPU context model
  - `proxyclient/m1n1/agx/context.py`: defines GPU VA layout
  - `proxyclient/m1n1/hw/uat.py`: GPU MMU/page-table format
- `mesa/` (sparse-checkout: src/asahi, src/gallium/drivers/asahi): Mesa AGX userspace driver
- `asahi-linux/` (Linux kernel with Asahi DRM): `drivers/gpu/drm/asahi/` kernel-side driver

## Key finding: Asahi's GPU VA layout (proxyclient/m1n1/agx/context.py)

```python
self.uobj = GPUAllocator(agx, "Userspace",  0x1600000000, 0x100000000, ...)
self.gobj = GPUAllocator(agx, "GEM",        0x1500000000, 0x100000000, ...)
self.pipeline_base = 0x1100000000
self.pobj = GPUAllocator(agx, "Pipelines",  self.pipeline_base + 0x10000, self.pipeline_size, ...)
```

So the 0x1100000000 range we've been chasing is the **PIPELINE region** — where pipeline
state blobs (compiled shaders + descriptors) live.

## What this confirms
- Our heap dumps show iOS kernel allocates the macOS-driver-requested heaps in the GEM range
  (0x1500000000+), not the pipeline range
- macOS Metal compiles shaders/pipeline-state assuming they live at 0x11xx (matching Asahi/macOS-native)
- iOS kernel doesn't follow that mapping convention
- The GPU faults on 0x1158048000 = 0x1100000000 + 0x58048000 — a perfect "pipeline region offset" address

## Why our experiments failed
- AGX_STRIP_HEAP_OPT (strip option bit 0xc): no effect because iOS kernel never honored it anyway
- AGX_OBJC_VA_FIX (rewrite "22 macOS literals"): the 22 hits were unaligned-u64 misreads
- Brute search for 0x1158048000 in all AGX kexts: not present anywhere

The fault VA comes from kernel- and firmware-side state setup, not from any userland-visible
constant. The GPU's context register / pipeline-state pointer gets set up by the firmware
in response to the AGX driver's submit, with VAs the firmware expects in its own register layout.

## The actual fix locus
To bridge this:
- Patch the iOS kernel's IOGPUResource allocator to honor the macOS option bits and put
  clientID 0x10000 heaps in the 0x11xx range
- OR: patch the AGX kernel kext (AGXG13G) to remap the firmware's pipeline-base to 0x15xx
- OR: AGX firmware (RTBuddy) RE to find where the pipeline-base register is set

All three require kernel/firmware patching, none reachable from libmachook userland.
