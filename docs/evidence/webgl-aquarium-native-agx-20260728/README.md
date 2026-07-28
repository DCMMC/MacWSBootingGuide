# Native-AGX WebGL Aquarium evidence (2026-07-28)

## Test matrix

Both runs used `https://webglsamples.org/aquarium/aquarium.html`, the 1000-fish
preset, a 1024x1024 drawing buffer, five seconds of warm-up, and fifteen
one-second samples from Aquarium's own `g_fpsTimer.averageFPS` value.

| Environment | Browser engine | Average | Median | Min | Max |
|---|---|---:|---:|---:|---:|
| iPad13,6 / macOS chroot / native iOS AGX | VS Code 1.130.0, Electron 42.6.0, Chromium 148.0.7778.280 | 14.4 | 14 | 11 | 18 |
| MacBook Air M1 | local browser | 60.07 | 60 | 60 | 61 |

The iPad result is 23.97% of the M1 result; conversely the M1 result is 4.17x
the measured iPad throughput. The M1 run is refresh-rate limited, so 4.17x is
a lower bound on the hardware/stack gap for this workload rather than an
uncapped GPU ratio.

## Runtime witnesses

The iPad discovery endpoint returned:

```text
Browser: Chrome/148.0.7778.280
User-Agent: Code/1.130.0 Chrome/148.0.7778.280 Electron/42.6.0
```

The formal Aquarium window produced this bounded error count immediately
before shutdown:

```text
FORMAL_AGX_ERRORS
00000102=0
00000103=0
0000000a=0
```

The retained log contains the native driver/class/compiler witnesses and the
active strict ABI-translation scaffold:

```text
#### PREREGISTER image[627] AGXMetal13_3: 52/52 realized
#### MACWS_AGX_NATIVE setupCompiler:0x30010 fired (Device=0x600282000)
#### AGXIOC Method sel=0x18->0x18 inCnt=0 inSC=0 outSC=0 -> 0xe00002c2
#### MACWS-NEW-EVENT #1 original=nil sharedEvent=... class=_MTLSharedEvent ... deviceClass=AGXG13GFamilyDevice
#### AGX_SUBMIT_DIAG #19 TEMP-KCMD-MULTISEG-FIX ... wrappedTail=YES
#### AGX_SUBMIT_DIAG #21 TEMP-KCMD-MULTISEG-FIX ... wrappedTail=YES
```

No `IOGPU-ERROR-GETTER` line occurs in the retained formal log. The zero
counts above are therefore an absence witness scoped only to this bounded run,
not a general stability claim.

## Files

- `ipad-vscode-1000fish.json`: formal iPad samples.
- `ipad-vscode-1000fish.png`: 2388x1668 macOS/VNC capture of the fully rendered
  Aquarium scene in VS Code.
- `ipad-cdp-version.json`: exact VS Code/Electron/Chromium versions.
- `ipad-vscode.log`: complete formal process/AGX log.
- `m1-air-1000fish.json`: formal M1 comparison samples.
- `m1-air-1000fish.jpg`: M1 comparison capture.
- `device-stop.log`: proof that the bounded iPad run was stopped afterward.

The subtype-1/subtype-3 KCMD transformations remain explicitly temporary ABI
translation scaffolding. Visible WebGL output and zero bounded command-buffer
errors demonstrate that the observed command shapes work; they do not replace
field-level RE of both producer and kernel parser.
