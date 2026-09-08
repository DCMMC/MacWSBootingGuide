# VS Code WebGL restoration witness (2026-09-08)

Device: iPad13,6, iPadOS 16.3.1, macOS 13.4 userland. Test application:
VS Code 1.130 / Chromium 148 with the packaged Aquarium extension.

## Runtime-confirmed extension-host deadlock

The first extension-host sample captured every one of its 1,589 samples in:

```text
pthread_jit_write_protect_np_new
tlv_get_addr
mprotect_new
_pthread_mutex_firstfit_lock_wait
```

This is runtime-confirmed via `/tmp/vscode-exthost-timeout.sample`. The JIT
write-protect callback already held `g_macws_jit_state_lock`; the dylib-local
`mprotect` resolved back through the interposer, whose CodeRange overlap query
tried to take that same mutex. A second sample showed that the first
thread-local-variable lookup could take the same allocation route while the
lock was held (`/tmp/vscode-exthost-after-vmprotect.sample`).

The repair resolves the TLV before taking the state mutex and performs the
recorded CodeRange permission flips with `vm_protect`, the kernel primitive
already used by the page-granular RX restore. The existing RW/RX W^X state
machine remains intact; no permission result or validation is forced.

After rebuilding, the extension host started immediately:

```text
Started local extension host with pid 22190.
```

The previous 60-second extension-host timeout did not recur.

## Native-AGX WebGL2 witness

The production launch profile now selects ANGLE Metal and does not pass the
exact `--disable-gpu` switch. The live GPU helper command line contained
`--type=gpu-process --use-angle=metal`.

The on-device Aquarium page visibly rendered 60,000 fish. A five-second CDP
measurement from that real page reported:

```text
canvas [1024,1024]
fish 60000
modelFish 60000
context WebGL2RenderingContext
contextLost false
callbacks 145
elapsed 5.0015
callbackFps 28.9913
p50 34.6ms
p95 37.4ms
max 40.9ms
contextLost false
```

The VS Code log contained no `MTLCommandBuffer`, internal execution, or WebGL
context-loss error for this run. The result therefore witnesses both a real
WebGL2 context and advancing rendered work, not merely an Electron process
that stayed alive.

## Idle-CPU regression check

After closing the Aquarium tab and restoring the packaged
`openOnStartup=false` setting, `misc/thread_cpu_probe.c` measured VS Code pid
22133 for ten seconds. No `Chrome_IOThread` exceeded the 1 ms reporting
threshold; the only reported threads were:

```text
6162854112   1.9ms  unnamed
8589631200  16.5ms  CrBrowserMain
```

This preserves the earlier long-session heat fix while restoring native WebGL.
