# Window-mode Retina density validation (2026-10-01)

Target: iPad13,6 / iPadOS 16.3.1, `root@192.168.1.2:2222`.

## Selectable modes

The old 125% and 150% modes used density factors above 1.0. With a real AppKit
backing scale of 2, their Host drawable budget was `2 / density` pixels per
Scene point. UIKit then enlarged that already undersized drawable again. The
replacement keeps the final drawable at the iPad panel's native 2x scale:

- Retina Standard: density 1.0, exact source/drawable mapping.
- Retina Larger: density 1.25, a smaller 2x AppKit logical workspace is
  enlarged once by the Host's Metal pass into the native 2x iPad drawable.

Legacy persisted values 3, 4, and 5 normalize to Retina Standard.

The first replacement tried a `Retina More Space` factor of 0.85. That was the
wrong direction for the requested UX: it exposed more logical content and made
fonts and controls smaller. User validation rejected it, so it is no longer a
selectable or normalized mode.

## Runtime witnesses

Retina Standard reached an exact closed geometry:

```text
1790846055.987 runtime-confirmed native Metal present scene=6e3f1d0f19984f11 frame=1122x772 backing=2.000 drawable=1122x772 content=(0.00,0.00 561.00x386.00) density=1.00 source=IOSurface status=4 error=nil
```

Retina Larger converged to a 703x475-point AppKit window backed by a real
`1406x950` Retina IOSurface. Its 879x594-point iPad content area kept a native
`1758x1188` drawable. The 1.25 density relation closes on both axes (within
half-point Scene rounding), while source and destination remain 2x in their
respective logical coordinate systems:

```text
1790847324.110 display-density changed previous=1 next=2 factor=1.25
1790847324.252 runtime-confirmed native Metal present scene=7a96d66f734cf7ff frame=1406x950 backing=2.000 drawable=1758x1188 content=(0.12,0.12 878.75x593.75) density=1.25 source=IOSurface status=4 error=nil
1790847339.205 rendered-drawable-snapshot written=YES bytes=273178 size=1758x1188 pixel-format=80 status=4 path=/var/mobile/Library/Logs/MacWSHost-rendered.png error=nil
snapshot sha256: 48056ca09f962a3420892b9fabac3f58daf11c655820f8f154fd0a742687a343
```

The same Terminal window visibly changed from 80x24 in Standard to 63x18 in
Larger. This is direct output evidence that the selectable direction is now
larger UI rather than more workspace. The quality sampler takes its additional
four constrained sharpening taps only while magnifying; exact and reduction
paths retain the original single linear sample.

Writing the removed 125% persisted value (`4`) and relaunching produced:

```text
MIGRATED_DENSITY=1
```

The installed Host binary SHA-256 was
`4e5d5078847f57a7b96948587221e929ee98d74157780b2ec7545c5e2d62b326`.
The device was left in Retina Larger mode. After the bounded validation it
reported thermal state `nominal`, effective temperature 34.09 C, and 0.5% Host
CPU in the static scene.
