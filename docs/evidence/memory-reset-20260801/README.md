# 2026-08-01 system-memory reset and production guard

## Runtime attribution

The device-generated
[`SystemMemoryReset-2026-08-01-034131.ips`](SystemMemoryReset-2026-08-01-034131.ips)
is the authoritative witness. Its event reason is:

```text
User reclaimable memory dropped below the limit. User reclaimable current: 56%. User reclaimable minimum: 65%
```

The report records a 16 KiB page size. Its largest resident entries were:

| Process | PID | Resident pages | Approx. resident MiB |
|---|---:|---:|---:|
| Reynard Helper | 71139 | 105574 | 1649.6 |
| Reynard Helper | 71155 | 57609 | 900.1 |
| WindowServer | 95375 | 50768 | 793.2 |
| MacWSHost | 71870 | 25038 | 391.2 |
| Reynard Helper | 71142 | 20520 | 320.6 |
| Code Helper (Renderer) | 98689 | 14290 | 223.3 |
| Code Helper (Renderer) | 98686 | 10944 | 171.0 |

This is runtime evidence for a whole-system memory event, not an attribution
to one MacWS process. The later Electron abort in `_RegisterApplication`
occurred after the WindowServer event port died and is downstream of this
event.

## Guard policy

The recovered, GUI-stopped device reported 61–62% through
`memory_pressure -Q`. Production now samples that XNU value every 30 seconds
and stops the disposable macOS GUI stack at or below 58%. The threshold is a
project safety margin selected between the recovered idle witness and the 56%
reset witness; it is not claimed to be an Apple-defined critical threshold.
Missing or malformed telemetry is logged but does not invent a pressure state.

This does not alter the user-selected thermal policy: temperature is still
sampled every 300 seconds and only an explicitly observed `critical` thermal
state intervenes. A no-GUI watchdog run on the device observed
`thermal-state=nominal`, `free=61%`, armed successfully, and exited when it
confirmed that the WindowServer job was unloaded.
