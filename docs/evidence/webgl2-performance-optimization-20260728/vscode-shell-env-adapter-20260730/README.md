# VS Code shell environment and production WebGL validation (2026-07-30)

This evidence closes three independent startup/resource problems without
changing Chromium rendering, JIT code generation, Metal commands, or the
native-AGX driver path.

## Exact shell-environment boundary

VS Code 1.130's installed `out/main.js` constructs an interactive login shell
environment containing `ELECTRON_RUN_AS_NODE=1`,
`ELECTRON_NO_ATTACH_CONSOLE=1`, and
`VSCODE_RESOLVING_ENVIRONMENT=1`. The shell then execs the same Electron
binary with a `-p` expression that prints a 12-hex token around
`JSON.stringify(process.env)`. The parent parses the JSON and explicitly
deletes all three temporary variables. Its ptyHost call site passes `{_:[]}`
instead of the main CLI arguments, so `--force-disable-user-env` cannot cover
that second path.

Three runtime controls located the required compatibility boundary:

- A completely un-injected Electron child trapped in
  `_check_internal_content -> os_variant_has_internal_diagnostics`; see
  `electron-without-compat-crash.ips`.
- Returning early from only `InitStuff` left the independent Metal constructor
  active. The login shell SIGBUSed in `InitMetalHooks -> libroot -> libxpc`;
  see `bash-partial-constructor-gate-crash.ips`.
- Disabling all four heavyweight GUI constructors retained the necessary
  dyld `os_variant` interposes, but starting Electron still reserved 24.5 GiB
  of address space and aborted at Oilpan's CagedHeap reservation; see
  `electron-minimal-constructors-oilpan-crash.ips`.

The production adapter therefore operates only when all four exact witnesses
match: the installed VS Code Electron path, both official environment markers,
and the `-p` expression containing `JSON.stringify(process.env)`. At the final
shell `exec` boundary it serializes that already-resolved environment using the
real token protocol and exits zero. Normal VS Code main, renderer, GPU and
extension-host processes do not carry the marker and keep the ordinary
libmachook/native-AGX path.

## Startup ownership and production overhead

The Aquarium extension previously called `simpleBrowser.show` on every launch
while VS Code asynchronously restored old webviews. Each restart therefore
added a complete Chromium renderer and native-AGX resource graph. The extension
now converges after bounded restore passes to exactly one tab named
`WebGL Aquarium` and closes only duplicate benchmark tabs.

The disposable profile sets `chat.agentHost.enabled=false`. Runtime A/B reduced
Code Helper processes from nine to eight, removed the optional AgentHost, and
removed its failing Copilot CLI Electron child. The extension host, Simple
Browser and WebGL2 stayed active. Production also stopped counting and printing
successful JIT permission flips; the logic and failure-only messages remain,
while detailed counters require diagnostics or `MACWS_JIT_MPROTECT_TRACE`.

## Native-AGX/VNC validation

The final coexistence production runs used official VS Code 1.130.0 / Electron
42.6.0 / Chromium 148, one Aquarium tab, a 1024x1024 WebGL2 canvas, Retina
2388x1668 VNC, diagnostics off, and the real `AGXG13GFamily` path.

| Workload | Page FPS | p50 interval | p95 interval | Context lost |
|---|---:|---:|---:|---:|
| 1,000 fish | 118.949 | 8.4 ms | 9.1 ms | no |
| 60,000 fish | 12.056 | 82.1 ms | 95.1 ms | no |

The 1,000-fish result is now refresh paced and is not a performance-ratio
workload. At 60,000 fish the same-version M1 result remains 37.679 FPS, so the
iPad is 31.996% of M1 (M1 is 3.125x faster). No `GL_OUT_OF_MEMORY`, texture
allocation nil, IOGPU completion error, context loss, Oilpan failure,
ptyHost shell-environment error, or production JIT flip log appears in the
final run. This startup/resource milestone does not close the high-load
presentation/command-encoding gap.

Artifacts:

- `aquarium-1000-production.json`, `aquarium-60000-production.json` — CDP
  measurements and context integrity fields.
- `production-agenthost-off-20s.png`, `aquarium-60000-production.png` — full
  Retina VNC frames.
- `vscode-60000.log`, `main-60000.log`, `ptyhost-60000.log` — production logs.
- the three `.ips` reports above — exact rejected boundary controls.
