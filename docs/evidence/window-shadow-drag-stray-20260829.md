# Window shadow/drag regression and Stray pacing evidence (2026-08-29)

Device: iPad13,6, iPadOS 16.3, macOS 13.4 chroot.

## Desktop compositor regression

Runtime snapshots captured the Terminal window twice: once in
WindowServer's completed FinalComposite base and again as exact layer 58.
MacWSHost then painted its own SDF shadow around the second copy. This
produced the broad grey halo at rest and independently timed window copies
while dragging.

The production invariant is now:

- a live FinalComposite is the completed desktop image, not a wallpaper
  underlay;
- generic AppKit exact layers are composed only when FinalComposite is not
  live;
- a geometry-only catalog change publishes an ordered geometry transaction
  and does not declare a layer-topology mutation or request a FinalComposite
  replay;
- add/remove/catalog-return remains a real topology mutation.

After deployment, a bounded 120-sample 60 Hz Terminal title-bar drag changed
the real SkyLight bounds from `(281,198)` to `(379,262)`. The final rendered
snapshot contained one Terminal window with the native shadow and no ghost.
The Host measurement recorded FinalComposite source cadence at 61.10 FPS,
capture-to-Host mean 2.58 ms, Host receipt-to-submit mean 7.36 ms and Host GPU
mean 0.61 ms. An earlier tighter drag measured 69.49 source FPS and 54.92
geometry updates/s.

## Stray production profile

Every accepted run verified the persisted profile before launch and before
scoring:

- 1440x900 output, native fullscreen mode `0`;
- High (`sg.*Quality=2`);
- MetalFX at 50%, with runtime `_MFXTemporalScalingEffectV3` evidence showing
  720x452 -> 1440x900;
- Steam overlay enabled with high-contrast FPS in the top-left;
- `FrameRateLimit=0` and `t.MaxFPS=0` for the retained production profile.

## Pacing and input A/B

All FPS values below are unique direct drawables that reached a real
MacWSHost drawable presentation. Producer cadence matched the Host result and
missing transport sequence count was zero.

| Direct-only desktop pace | Input | Sample | Visible FPS | Thermal result | Outcome |
|---|---:|---:|---:|---|---|
| 100 ms | none | 20.52 s | 52.03 | all nominal | accepted bounded baseline |
| 100 ms | none | 60.65 s | 49.15 | nominal -> fair -> serious | sustained thermal limit remains |
| 500 ms | none | 60.59 s | 53.16 | final sample fair | static throughput improved |
| 500 ms | 961 hover samples at 120 Hz | before scoring | n/a | nominal | present stopped at sequence 11880; UE logged `MTLCommandBufferErrorDomain Code: 2` / GPU timeout |
| 100 ms | same 961 hover samples at 120 Hz | 20.59 s | 52.40 | all nominal | present advanced 11880 -> 12360; screenshots changed; no fatal |

The controlled input result makes 500 ms a rejected optimization. Production
remains at the previously validated 100 ms direct-only desktop pace. It is not
valid to promote the static 53.16 FPS result while hiding its input-triggered
GPU-timeout regression.

Two frame-cap experiments were also rejected as thermal fixes: 54 FPS capped
scored 52.31 FPS/60 s and ended fair; 52 FPS capped scored 50.57 FPS/60 s and
ended serious. The persisted profile was restored to uncapped afterward.

## Remaining performance boundary

The accepted input-safe build exceeds 50 FPS for a 20-second nominal sample,
including after the repeated Magic Keyboard-style pointer route. A 60-second
uncapped run at the same visual profile still reaches thermal pressure and
averages 49.15 FPS. That remaining issue is GPU/MetalFX work, not Host
transport loss: the long run measured 97.08% mean GPU residency and zero
missing transport sequences. Sustained 50+ while remaining nominal is not yet
claimed.

## Mission Control thumbnail restore regression

The visually slow thumbnail-to-window restore was not a Host GPU bottleneck.
Before the fix, runtime display logs showed Dock's fallback full-screen layers
delivering only 20.12--38.25 FPS with up to three outstanding leases, while
the Host GPU stage remained about 4 ms. At the same time,
`/private/tmp/macws_final_composite.state` reported `state=fallback` and the
WindowServer publisher was frozen at sequence 38410.

A process-memory read against WindowServer PID 87380 runtime-confirmed that
`g_vnc_comp_max_area` held `0x40ed18 = 4,255,000` pixels. The actual display is
2388x1668 = 3,983,184 pixels. Source inspection showed that the completion
candidate path compared every future display target with this
process-lifetime maximum. A transient larger 2500x1702-class intermediate
therefore permanently excluded the real owned scanout and stopped the final
composite source timestamp from advancing, even though WindowServer and Dock
continued to render.

The production selector now uses the current update's pending candidate:

- a process-owned scanout always outranks an unowned intermediate, regardless
  of dimensions;
- a later owned scanout replaces an earlier owned scanout;
- unowned legacy candidates compare area only within the current update.

`misc/macws_protocol_test.c` pins the larger-intermediate/smaller-owned case.
After deployment and a controlled workspace rebuild, the state reached
`state=ready producer=9182 sequence=64 reason=validated-final-composite` and
continued through sequence 4573 after four automated Mission Control
selection runs. The rendered screenshot contained the restored InputLab,
wallpaper, native Dock material and menu bar.

Three repeated zero-debug selection profiles after the initial validation
measured 84.51--88.10 visible FPS. Two passed the complete gate with about
47.98 FPS 1% low; one recorded two isolated 25--29 ms intervals and a 39.98
FPS 1% low. No run fell back to the old layered presentation, no Metal command
error occurred, and the thermal witness remained `nominal`.
