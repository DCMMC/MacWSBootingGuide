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

## Retired guard policy

The recovered, GUI-stopped device reported 61–62% through
`memory_pressure -Q`. An initial policy sampled that value every 30 seconds and
stopped the GUI at or below 58%. A later production start produced the sequence
`62% -> 60% -> 58%` while the thermal state remained nominal; the project guard
then stopped an otherwise-running WindowServer, DisplayStream and Terminal.

That policy is retired. The percentage describes currently available memory,
not an Apple pressure-state boundary, and normal iOS cache/reclaim behavior
makes a fixed free-percentage threshold unsuitable as a project kill switch.
Production no longer samples, refuses, or stops the GUI based on this value.
XNU/iOS memorystatus remains responsible for reclamation and pressure policy.

This does not alter the user-selected thermal policy: temperature is still
sampled every 300 seconds and only an explicitly observed `critical` thermal
state intervenes. Crash-loop detection and explicit automation runtime caps
also remain independent safeguards.
