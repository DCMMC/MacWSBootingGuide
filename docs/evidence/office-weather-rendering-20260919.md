# Office image content and Shanghai Weather: new failing acceptance cases

Status: **reproduced, not repaired**. These are separate acceptance cases from
Word text-selection highlighting and Weather's Mission Control card. Passing
those older cases did not establish that document pictures or every weather
effect rendered correctly.

## Actual UI observations

Native iPadOS captures, inspected by the main agent:

- `/tmp/macws-office-weather-report-20260919.png`: Weather Shanghai has a
  large solid magenta background. Its text, hourly forecast, and air-quality
  map remain visible. PowerPoint's black thumbnails are visible behind it.
- `/tmp/macws-powerpoint-black-thumbnails-20260919.png`: PowerPoint's built-in
  introductory presentation, slide 3, has normal large orange/white areas
  and text. Its embedded picture appears as a very thin horizontal strip.
  All six visible slide thumbnails have black backgrounds, with text still
  present. This is not merely failure to create a window or draw any pixels.
- `/tmp/macws-weather-shanghai-diag-settled-20260919.png` and
  `/tmp/macws-weather-shanghai-diag-second-20260919.png`: Shanghai's magenta
  effect reproduces after ordinary Weather Quit/relaunch. No Office document
  was closed or edited, and WindowServer PID 16900 remained unchanged.

Word/Excel's additional image errors are user-reported; this capture does not
pretend they were independently exercised. No image-layout or color repair
has been deployed for these failures.

## Weather: actual failing GPU command, not a color guess

Runtime-confirmed via the copied log
`/tmp/macws-weather-shanghai-full-20260919.log`:

```text
#### IOGPU-ERROR-GETTER observation=1 commandBuffer=0x13e7e4ed0 class=AGXG13GFamilyCommandBuffer submitSerial=2 fixed=0 domain=MTLCommandBufferErrorDomain code=1 description=Internal Error (00000102:Internal Error)
#### AGX_FAST_RING dumped reason=iogpu-error-getter-102 commandBuffer=0x13e7e4ed0 requested=2 matched=2 entries=2 byteEntries=2 range=1..2 path=/tmp/macws_fast_submit_error_21575_1
2026-09-19 03:05:51.366 Weather[21575:399218] RBDevice: command buffer error: Error Domain=MTLCommandBufferErrorDomain Code=1 "Internal Error (00000102:Internal Error)" UserInfo={NSLocalizedDescription=Internal Error (00000102:Internal Error)}
```

The app-side timestamp uses a different timezone from the iPadOS capture;
PID 21575 and the matched command/serial identify this observation. The local
artifact directory `/tmp/macws-weather-fast-submit-21575` contains the two
complete retained post-translation command/list pairs and resource metadata.
The failing serial 2 has 6408 command bytes and 880 segment-list bytes. It
must be decoded against the actual producer/consumer ABI before choosing a
repair. `fixed=0` is an observation, not proof that a translation was needed.

The first diagnostic attempt removed its startup sentinels before the lazy
error observer evaluated them, so it reproduced the pixels but did **not**
capture the failing command. The second kept the sentinels through city
selection and captured the exact error above. Both invocations used an
exception/deadline cleanup for only the files they created. The diagnostic
Weather was normally quit afterward; ordinary no-sentinel Weather PID 21702
was launched. The two sentinels were removed. No deep 2048-entry recorder,
full GUI restart, respring, GPU stress loop, or persistent setting was used.

## Negative control and limits of the visual comparison

Allowing the zero-depth record through the existing translator produced a
normal blue Shanghai view in diagnostic Weather PID 23212
(`/tmp/macws-weather-zero-depth-control-20260919.png`). However, the live
weather state changed during this comparison. A subsequent ordinary,
no-sentinel Weather PID 23673 also rendered Shanghai normally, with Drizzle
76 degrees, after correct activation and selection
(`/tmp/macws-weather-reverse-shanghai-20260919.png`). Its corresponding log
did not report the earlier 0x102 error. Therefore these screenshots are **not
a successful reversible A/B proof of the sole visual cause**. The exact
NSError-matched command fixture still proves a missing ABI conversion; its
executable replay is a separate, narrower result.

An initial reverse-test click did not target the now-moved Weather window.
The resulting empty city page was not accepted as a rendering pass. Window
activation, fresh pixels, and the actual Shanghai label were checked before
recording the valid observation above.

The previously retained `/tmp/macws_ppt_native_extended_madison.png` was
also inspected: its left PowerPoint thumbnail was already black, while the
large slide had colored geometry. This older artifact does not establish
the exact library identity, but it prevents treating today's newly added
IOSurface protection repair as a proven origin of all Office image failures.

## Required next validation

Small non-square row/column-pattern image tests will compare native iOS and
the chroot's real Metal upload, download, and CGImage/CoreAnimation paths.
They can isolate a primitive but cannot replace actual Office picture and
thumbnail acceptance. Weather requires the actual erroneous command/resource
contract plus visual Shanghai and Beijing checks, including Mission Control.
There is not yet evidence that Office and Weather have a single root cause.
