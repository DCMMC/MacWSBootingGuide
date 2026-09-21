# Geekbench 6 GUI CPU regression: launch ownership A/B

Runtime on iPad13,6 / iOS 16.3.1, Geekbench 6.7.1, 2026-09-22.
These are observations, not a claim about an uninspected XNU scheduler branch.

| Launch route | GUI / worker coalition (resource, jetsam) | Worker XNU Performance / Efficiency instructions | Result |
| --- | --- | --- | --- |
| macwshostd direct `posix_spawn` | `(591, 592)` / `(591, 592)` | `0` / `75,433,752,546` (PID 14153) | GUI showed `2.06 GHz`; previous GUI run uploaded `2164` multi-core |
| SSH `launchdchrootexec` (diagnostic) | `(1429, 1430)` / `(1429, 1430)` | `98,819,790,677` / `28,983` (PID 15237) | GUI showed `3.20 GHz` |
| Separate `UIKitApplication:com.macwsguide.geekbench` launchd job | `(1521, 1522)` / `(1521, 1522)` | `239,426,753,079` / `329,481,528` (PID 15606) | [Geekbench result 19231350](https://browser.geekbench.com/v6/cpu/19231350): single `2293`, multi `8156` |
| New hostd `launch-path` -> loaded job | `(1521, 1522)` / `(1521, 1522)` | `137,924,107,758` / `120,550,958` (PID 17328) | Real control request: `ok=yes launched-pid=17235`; worker deliberately terminated after core witness |
| New hostd `launch-path` -> absent job | `(1599, 1600)` / not run | not run | Real control request: `ok=yes launched-pid=17511`; window metrics had one visible entry |
| Launchpad GUI click -> dedicated job | `(1599, 1600)` / `(1599, 1600)` | `107,688,646,169` / `79,126,784` (worker PID 20861) | GUI PID 20542; completed CPU run uploaded [result 19231623](https://browser.geekbench.com/v6/cpu/19231623) |

The first, third and fourth worker samples were taken with `macwsthermal`
reporting `thermal-state=nominal`. The direct and separate-job worker probes
reported the same `pbi_flags=0x404010`, `TASK_UNSPECIFIED` role, and task QoS
latency/throughput `0`. The directly observed difference includes launchd
coalition ownership and the inherited launcher environment, not a changed
benchmark executable, workload, or measured app-level QoS setting. THEORY:
hostd's service coalition or associated importance transaction causes E-only
placement; the exact XNU scheduler branch has not been disassembled. The
upstream fix gives the GUI and worker the independent launch transaction
proven by the A/B, without overriding scheduler policy or benchmark work.

Reproduce with `misc/task_policy_target_probe.c` (compile/sign/trustcache on
iPad) and `misc/proc_perf_levels_probe.c`. CPU-counter evidence comes from
XNU's per-performance-level `PROC_PIDTHREADCOUNTS` flavor, not GUI text or
idle-process uptime. The GUI result was visually verified via macOS
`screencapture` after Geekbench opened its result in VS Code.

Launchpad completion is runtime-confirmed via `/var/jb/var/mobile/geekbench.log`:
`2026-09-21 10:29:14.742 Geekbench 6[20542:153927] Run completed with document`
and `2026-09-21 10:29:16.306 Geekbench 6[20542:156032] Results upload finished`
for result `19231623`. `launchctl list UIKitApplication:com.macwsguide.geekbench`
reported `PID = 20542` while the GUI was running. The worker probe reported
Performance/Efficiency instructions as recorded in the table, with thermal
state `nominal`.
