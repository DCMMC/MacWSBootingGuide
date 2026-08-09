# Mission Control window-retention fix (2026-08-10)

## Symptom

After a native three-finger upward gesture, MacWS Host could show only the
focused application (or only a subset of the desktop) even though the missing
macOS windows were still alive. Exiting Mission Control did not reliably bring
those windows back into the Host compositor.

## Runtime-confirmed attribution

This was not a Dock gesture-direction error and not a real macOS window hide.
During the same completed upward gesture, `macwsworkspacectl list-windows`
reported the application windows on screen; representative lines were:

```text
window pid=30619 id=22 ... onscreen=yes ... name=Terminal — bash -i — 80×24
window pid=39264 id=54 ... onscreen=yes ... name=Glass Demo — vibrancy + segmented + popup + ctx menu
window pid=40764 id=67 ... onscreen=yes ... name=Welcome [Superuser]
```

The WindowServer Retina screenshot also contained Terminal, Finder,
GlassDemo, and VS Code in the native Mission Control layout. The Host snapshot
from the same state omitted Terminal and Finder, and its graph omitted layers
22 and 35:

```text
display-performance-snapshot ... layers=[..., layer=54/pid=39264/stream=31/..., layer=67/pid=40764/stream=36/..., ...]
```

The display service had removed those layers during a transient catalog
transition and then observed the same windows return:

```text
MACWS-DISPLAY workspace-layer-remove layer=22
MACWS-DISPLAY layer-retire-begin layer=22 reason=workspace-catalog-removed ...
MACWS-DISPLAY workspace-layer-remove layer=35
MACWS-DISPLAY layer-retire-begin layer=35 reason=workspace-catalog-removed ...
MACWS-DISPLAY layer-retire-cancel layer=35 reason=window-returned
MACWS-DISPLAY layer-retire-cancel layer=22 reason=window-returned
```

The installed `macwsdisplayd` was stale. `strings` exposed only the pre-cutoff
diagnostic:

```text
workspace-layer-remove layer=%u
```

That binary sent `layer_removed` without the producer stream ID and ordered
sequence cutoff. A current Host therefore tombstoned the live stream and
rejected every later frame from it. The current source already contained the
required stream/sequence cutoff and retained-IOSurface republish, but that
source had not reached the running daemon.

## Production fix

1. A clean on-device build and full package install replaced the stale
   display daemon. Its installed diagnostic is now:

   ```text
   workspace-layer-remove layer=%u stream=%llu through=%llu
   ```

2. `MACWS_STREAM_VERSION` was raised from 4 to 5. Version 5 makes the
   stream/sequence semantics of `layer_removed` a hard compatibility boundary.
   A stale daemon or stale Host now fails the handshake visibly instead of
   silently corrupting the compositor graph.

3. `misc/macws_protocol_test.c` pins version 5 and continues to verify that a
   frame from the same stream is accepted only above the removal cutoff, while
   a frame from a new stream generation is accepted immediately.

## Final runtime evidence

The v5 production package connected successfully:

```text
display-stream status connected=YES message=DisplayStream IOSurface 直传已连接
```

A forced App Exposé transition removed three non-focused application layers,
then restored the exact same live streams:

```text
MACWS-DISPLAY workspace-layer-remove layer=27 stream=15 through=627
MACWS-DISPLAY workspace-layer-remove layer=32 stream=16 through=136
MACWS-DISPLAY workspace-layer-remove layer=22 stream=11 through=109
MACWS-DISPLAY layer-retire-cancel layer=32 reason=window-returned
MACWS-DISPLAY layer-retire-cancel layer=27 reason=window-returned
MACWS-DISPLAY layer-retire-cancel layer=22 reason=window-returned
```

The following Host graph proves that the post-cutoff frames were accepted and
all four application windows were present again:

```text
display-performance-snapshot ... layers=[
  ...,
  layer=22/pid=33779/stream=11/sequence=180/...,  # Terminal
  layer=27/pid=33904/stream=15/sequence=737/...,  # GlassDemo
  layer=32/pid=33939/stream=16/sequence=206/...,  # VS Code
  layer=34/pid=33701/stream=17/sequence=146/...,  # Finder
  ...]
```

The clean cutoff build completed three additional Mission Control enter/exit
rounds with all four layers retained. The final v5 build then repeated native
Mission Control plus the forced remove/return transition above. Its Host
screenshot visibly contained Terminal, Finder, GlassDemo, and VS Code; its SHA-256 was
`1aa5862d1add607abaf9d3c5f1d390b99cb1cefaea080267fce7e1ce67749fc6`.
No WindowServer, Dock, MacWSHost, or `macwsdisplayd` crash report was created in
the five-minute validation window. The final iPad thermal sample was nominal
at 33.09 °C.

Production artifact identities:

```text
deb sha256:          beaf67b51e5b9fda5aad7dca05676947010a60ce8645a56bdbcf10d6015133dd
macwsdisplayd sha256: 08f5f8c611eb5b9ebc356aa20d3e00f02b62b2185f74c22347fe0ee705c77440
macwsdisplayd CDHash: ac93dad323a2986c81ce7fd47fdecc6b281379da
MacWSHost sha256:      1222e1ca5371a4253f387ec3bac8a11dde811bbafd1545398d50377a123e5603
MacWSHost CDHash:      3833a474875a6dbe42826a92e92e21dc3843d478
```
