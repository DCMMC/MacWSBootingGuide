# Lifetime-aware AGX compatibility texture leases — 2026-07-29

This checkpoint replaces the historical one-object-per-shape caches used by
the AGX-native compatibility path.  Equal dimensions are not a lifetime
guarantee: SkyLight and Chromium can keep several equal-shaped render targets
live in one frame.  Reusing the same `MTLTexture` while its external retain is
still present caused distinct render passes to alias one backing IOSurface.

The ordinary compatibility allocator now keeps a per-shape lease list.  A hit
is eligible only when the cached texture is at its pool-owned retain baseline;
the `newTexture...` call receives a real retain before the lease is returned.
If all matching entries are busy, a distinct IOSurface/texture pair is created.
Idle entries are evicted by LRU only after the pool exceeds 512 MiB; busy
entries are never evicted or aliased.

The full-screen VNC-owned scanout path uses the same lifetime rule.  It leases
by the validated display shape and keeps an explicit reservation retain across
the native Metal initializer.  This removes the old original-IOSurface-ID key,
which changed continually and converted the cache into an allocation loop.

Runtime-confirmed on the current iPad13,6 WindowServer log:

```text
#### VNC-OWNED lease-new #1 key=2388x1668 original=0x12d937600 id=159 -> owned=0x12d8b9f70 id=160 2388x1668 bpr=9600 alloc=16023552 entries=1 pool=15MB baseline=1 reserved-retain=2
#### VNC-OWNED lease-new #4 key=2388x1668 original=0x12ce517d0 id=168 -> owned=0x12cf0a510 id=169 2388x1668 bpr=9600 alloc=16023552 entries=4 pool=61MB baseline=1 reserved-retain=2
#### VNC-OWNED lease-hit #39600 key=2388x1668 originalID=248 surface=0x12ce444d0 id=161 retain=1 baseline=1 entries=5 pool=76MB
```

This shows five owned 15.3-MiB display targets serving at least 39,600 reuse
hits instead of allocating against every changing source ID.  A live bounded
sample with Terminal open measured WindowServer at 214,240 KiB RSS.  These are
allocation/reuse witnesses, not a long-soak leak proof.

Representative functional artifacts:

- `terminal/results-1.json` records two menu/input rounds against the lease
  pool.
- `terminal/round-1/01-menu-open.png` is the full Retina menu frame.
- `terminal/round-1/hover-04.png` records a complete hover row.
- `vscode-start.png` records the latest VS Code main window on the same pool.

Mipmapped IOSurface textures remain a separate protocol boundary.  The hook
does not flatten or fabricate them: descriptors with more than one mip level
are sent to the real AGX allocator.  Apple's large mipmapped texture succeeds,
while the Aquarium 6x1/pixel-format-70/mip-level-3 allocation still reaches
the known native resource-create rejection.  That unresolved case is not
claimed fixed by this checkpoint.
