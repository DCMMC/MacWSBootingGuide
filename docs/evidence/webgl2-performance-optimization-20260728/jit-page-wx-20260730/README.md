# Page-granular V8 W^X and remaining VS Code gap (2026-07-30)

This milestone replaces VS Code's process-wide 256-MiB JIT CodeRange
permission flips with an opt-in, page-granular W^X adapter. It is enabled only
for the tracked VS Code launch job by `MACWS_JIT_FAULT_WRITE_COMPAT=1`.
Chrome is deliberately unchanged until it receives its own validation.

This is an executable-memory invariant fix, not a check bypass. Generated code
normally remains RX. A data SIGBUS from a V8 writer scope turns only the
faulting 16-KiB CodeRange page RW, records that page, and the last writer
restores every dirty page RX before publishing zero active writers. Instruction
fetch faults wait for that RX restore. Unknown SIGBUS events continue to the
previous handler or the normal crash path.

## Runtime-confirmed iOS boundary

Direct RWX is not available to this chroot process. The control process asked
for an RWX page, received `rw-/rwx`, and then died with an instruction-abort
permission fault when it executed the page:

```text
VM_ALLOCATE 10417c000-104180000 [16K] rw-/rwx
EXC_BAD_ACCESS / SIGBUS / KERN_PROTECTION_FAILURE at 0x10417c000
esr: (Instruction Abort) Permission fault
```

The new standalone probe then validated the intended page transition on the
same iPad13,6 / iOS 16.3.1 kernel:

```text
page=0xc1a02c000 size=0x4000 csflags=0x3680380d before=42 after=43 write_faults=1 final=RX
```

The probe writes code returning 42, changes the page RX, deliberately writes
new code returning 43 inside a trusted writer scope, handles exactly one data
fault by making that page RW, restores RX, and successfully executes 43.

## Whole-range versus page-granular runtime trace

The legacy adapter repeatedly invalidated the complete 256-MiB CodeRange. A
representative VS Code trace reached:

```text
JIT-MPROTECT flip #23552 ranges=1 prot=RX writers=1 exec_waits=7272 late_retries=192
```

The page-granular trace initializes each CodeRange RX once. One VS Code process
then reached:

```text
JIT-MPROTECT flip #1 ranges=1 prot=RX writers=0 exec_waits=0 late_retries=0
JIT-FAULT-WRITE restore #11264 pages=1 overflow=0 write_faults=12318 exec_waits=442 late_retries=208
```

The logs are interleaved across Electron child processes, so these counters are
per process and are not summed. They establish the permission mechanism and
the order-of-magnitude reduction in fetch waits; they are not an FPS claim.
Production logging remains off.

## JIT is active; the remaining gap is not `--jitless`

The exact official VS Code 1.130.0 / Electron 42.6.0 build reported V8
`%GetOptimizationStatus(tdl.math.pseudoRandom) == 41` on both iPad and M1.
V8's status bits map 41 to `IsFunction | Optimized | TurboFanned`. Project LLDB
then sampled and disassembled the iPad's RX JIT range: the hot
`pseudoRandom` modulo is inline AArch64 (`fmul`, `fadd`, `fcvtzu`, `scvtf`,
`fdiv`, `frintz`, `fmsub` plus range checks), rather than a call to macOS 13
`fmod`. This rules out missing JIT and the old-libm theory for that hot path.

The same-version direct-frame decomposition still shows a roughly 3x CPU-side
gap:

| Mode | iPad p50 | M1 p50 | iPad / M1 time |
|---|---:|---:|---:|
| full | 78.5 ms | 23.1 ms | 3.40x |
| no draw calls | 60.9 ms | 21.1 ms | 2.89x |
| no uniform calls | 52.3 ms | 17.9 ms | 2.92x |
| JS-only (draw + uniform calls removed) | 47.4 ms | 15.3 ms | 3.10x |

CPU profiles agree. On iPad, `tdl.math.pseudoRandom` consumed 789.632 ms self
(49.52%), `Program.setUniform` 350.195 ms (21.96%), and `renderMono` 182.042 ms
(11.42%). The same M1 profile measured 248.050 ms, 61.871 ms, and 65.559 ms.
Renice and a controlled user-interactive QoS override did not change the raw
arithmetic result, so that diagnostic override was removed before the final
build.

## Production native-AGX/VNC validation

The final production job used AGX native, diagnostics off, one 60,000-fish
WebGL2 target, a 1024x1024 canvas, and the 2388x1668 Retina VNC desktop. Two
short-connection rAF rounds produced:

| Round | FPS | p50 | p95 | WebGL context lost |
|---|---:|---:|---:|---:|
| 1 | 11.812 | 80.1 ms | 97.9 ms | no |
| 2 | 11.594 | 80.2 ms | 98.1 ms | no |

[`vscode-60000-production.png`](vscode-60000-production.png) is the full VNC
frame. A native RFB click at `(200,25)` changed the retained-frame SHA-256 from
`549a158e...` to `18cf4f9e...` and opened VS Code's real File menu within the
one-second capture window; [`vscode-60000-file-menu.png`](vscode-60000-file-menu.png)
is the visual witness.

## Explicitly not closed

- Steady FPS did not improve materially: page mode measured about 11.6 FPS,
  while the legacy production result was about 11.6-12.1 FPS. The adapter
  removes pathological permission invalidation; it does not solve the inline
  scalar-JS and WebGL command-encoding cost.
- A production stress run emitted one real native completion error
  `Internal Error (00000103)`, and the diagnostic trace emitted two. The page
  continued rendering and `contextLost` stayed false, but M1-level stability
  is therefore not yet achieved.
- Navigating an already-live 1,000-fish WebView directly to 60,000 fish caused
  an ANGLE `MakeTexture:330` host-memory OOM and GPU-process restart. A clean
  production start directly at the tracked 60,000-fish URL did not. The
  disposable profile now pins that URL, and recorded runs verify both `fish`
  and `modelFish` instead of trusting the address bar.
- A synthetic direct-20-frame burst can still time out and trigger native
  command-buffer errors. Real rAF/VNC use is the valid production witness; the
  burst failure remains a separate AGX command-submission stability target.

The next performance work should concentrate on the 3.1x JS-only gap and the
5.7x `Program.setUniform` self-time gap, while the next stability work should
capture the first mapped submit behind the remaining `0x103` rather than
suppressing it.
