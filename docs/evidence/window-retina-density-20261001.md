# Window-mode Retina density validation (2026-10-01)

Target: iPad13,6 / iPadOS 16.3.1, `root@192.168.1.2:2222`.

## Removed invalid enlargement modes

The old 125% and 150% modes used density factors above 1.0. With a real AppKit
backing scale of 2, their source budget was `2 / density` pixels per Scene
point, below the native 2-pixel iPad drawable budget. The final composition
therefore enlarged insufficient source pixels. The selectable modes are now:

- Retina Standard: density 1.0, exact source/drawable mapping.
- Retina More Space: density 0.85, 2x AppKit source is only reduced.

Legacy persisted values 3, 4, and 5 normalize to Retina Standard.

## Runtime witnesses

Retina Standard reached an exact closed geometry:

```text
1790846055.987 runtime-confirmed native Metal present scene=6e3f1d0f19984f11 frame=1122x772 backing=2.000 drawable=1122x772 content=(0.00,0.00 561.00x386.00) density=1.00 source=IOSurface status=4 error=nil
```

Retina More Space retained a `2000x1456` 2x producer and produced a
`1700x1238` rendered drawable snapshot (0.85 per axis, with height rounded):

```text
1790845906.287 runtime-confirmed native Metal present scene=81b2d1ed1598dfd7 frame=2000x1456 backing=2.000 drawable=2000x1456 content=(75.00,54.60 850.00x618.80) density=0.85 source=IOSurface status=4 error=nil
snapshot: 1700x1238 RGBA PNG
sha256: 80c4e16fc75d58574abf2fe79e3ed3776681fe170105f845cc52294f4c77e8d6
```

The first line is the pre-Scene-resize presentation witness; the captured
drawable is the settled post-resize result. Both axes have more producer
pixels than destination pixels. No upsampling occurs.

Writing the removed 125% persisted value (`4`) and relaunching produced:

```text
MIGRATED_DENSITY=1
```

The installed Host binary SHA-256 was
`7cc91667cb9a00238d62558af83e947507f3ea49d2edc9ed00f893e357a9e45b`.
The device remained at thermal state `nominal`; the final measured battery and
effective temperature was 38.39 C.
