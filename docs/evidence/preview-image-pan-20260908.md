# Preview zoomed-image pan regression witness (2026-09-08)

Device: iPad13,6, iPadOS 16.3.1, macOS 13.4 userland. No IPSW was
downloaded, extracted, or scanned during this work.

## Runtime-confirmed failure

A sample of the stock renderer after a small zoom spent all 2,298 captured
samples inside ImageKit's synchronized scaled-image rebuild:

```text
_resetScaledCIImage
objc_sync_enter
CIContext render:toIOSurface:
CI::GLContext::render_root_node
glDrawArrays
glvmInterpretFPTransformFourInner
```

This is runtime-confirmed via `/tmp/preview-image-after-small-zoom.sample`.
The application was not waiting on input: ImageKit held its own scaled-image
lock while the iOS software OpenGL Core Image renderer regenerated a tile.
Panning a zoomed image repeatedly selected the same path and made the window
appear frozen.

## Repair boundary

For an ImageKit half-float RGhA destination, the interpose reads the exact
`CIImage.extent`, decodes the current document through ImageIO, and draws it
into the exact IOSurface requested by ImageKit with CoreGraphics. The decoded
source is cached at its natural size up to 4,096 pixels; larger input uses an
ImageIO thumbnail bounded to 4,096 pixels. Unsupported pixel formats and
non-image documents continue through ImageKit's original renderer.

This changes the upstream renderer that was holding ImageKit's lock. It does
not suppress the lock, replace a failed surface with a zero buffer, bypass an
assertion, or report a fabricated success.

## Post-fix witness

Preview pid 18250, window 1298 displayed `IMG_0120.png`. The initial four
surface renders completed in:

```text
0.093261  0.003781  0.010031  0.001073 seconds
```

A ten-update magnify gesture completed at 29.54 Hz. The next six zoomed tiles
completed in:

```text
0.037069  0.004673  0.020477  0.002696  0.033217  0.018059 seconds
```

A 40-update pan then completed at 59.68 Hz in 670.264 ms. Preview remained
sleeping/responsive at 1.5% CPU with 352,800 KiB RSS. Captures before zoom,
after zoom and after pan had distinct hashes, proving that visible output
advanced rather than only preserving process uptime:

```text
fc5ab0311be3b7f5080eee178e1fe2fff2cc3054c972a451c197ca142c7c93ab
409e654e5dde1f8eb79fa5b094b43c0b0700aeca3115041f3c3cde6b315b266d
d5cca2161d832df7647ddc2b508ad27e4fbfe7924cb27bf1aae61ebeeafec54f
```
