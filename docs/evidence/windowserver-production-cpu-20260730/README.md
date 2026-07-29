# WindowServer production CPU and patch-safety evidence (2026-07-30)

This set records three production fixes on iPad13,6 running the macOS 13.4
chroot with native AGX and the Retina `2388x1668` VNC framebuffer.  It also
records the remaining right-click failure; none of the results below claim
M1-equivalent performance yet.

## Executable patching race

Runtime-confirmed by
[`WindowServer-2026-07-30-013455.ips`](WindowServer-2026-07-30-013455.ips):
an NSXPC worker faulted at `objc_msgSend`, with PC and FAR both
`0x188341c00`, while its queue was
`com.apple.NSXPCConnection.m-user.com.apple.systemstatus`.  The exception is
`SIGBUS / KERN_PROTECTION_FAILURE`.  At the same time the dyld image callback
could patch `objc_msgSendSuper2+0x10` on the same 16-KiB libobjc page.  The old
`ModifyExecutableRegion` made that entire page RW/non-executable while writing
four bytes, allowing a peer thread to fetch from a non-X page.

The replacement serializes patch operations, resolves the current thread by
`THREAD_IDENTIFIER_INFO`, suspends peer threads for the W^X interval, checks
every protection operation, clears the instruction cache, and restores the
actual VM-region protection.  It refuses unknown or cross-region writes.

Two validation failures exposed additional invariants instead of being
bypassed:

- [`WindowServer-2026-07-30-014140.ips`](WindowServer-2026-07-30-014140.ips)
  is the deliberate fatal check after the first implementation tried to
  restore RX to a `__DATA_CONST` patch.  The final implementation preserves
  the region's real protection.
- [`WindowServer-2026-07-30-014340.ips`](WindowServer-2026-07-30-014340.ips)
  is an instruction-permission fault at `IOMobileFramebufferOpen`.  On this
  cross-OS shared-cache mapping, `mach_vm_region` reported R even though the
  loaded Mach-O segment is executable.  The final implementation adds the
  containing segment's `initprot & VM_PROT_EXECUTE` when restoring code and
  leaves data non-executable.

Multiple subsequent cold starts reached a validated Retina first frame
without another patch-window crash.

## Completion observer thread reuse

[`windowserver-production-stable.sample.txt`](windowserver-production-stable.sample.txt)
captured 69 short-lived `__macws_vnc_finish_update_block_invoke` NSThreads in
one production sample.  Each accepted compositor completion had used
`detachNewThreadWithBlock:` even though the existing `pollInFlight` invariant
permits only one observer.  A serial dispatch queue now preserves that
invariant while reusing the workqueue pool.

After the change, the live process had 17 long-lived threads in the first
sample and 15 after the SystemStatus fix.  A single quiet 10-second A/B moved
WindowServer CPU time from 5.78 seconds to 5.22 seconds (57.8% to 52.2% of one
core).  This small single-run delta is recorded as an observation, not a
causal performance claim.

## SystemStatus namespace collision

The pre-fix WindowServer samples contain four queues repeatedly executing
`-[STStatusDomainXPCServerHandle _reregisterForDomains]`,
`BSIntegerMapEnumerateWithBlock`, and `observeDomain:...`, followed by XPC
disconnect handling.  See
[`windowserver-with-systemstatusd.sample.txt`](windowserver-with-systemstatusd.sample.txt).
The first attempt merely started macOS `systemstatusd`; it did not help because
its three stock names collide with endpoints already active in iOS.

[`systemstatus-bootstrap-collision.txt`](systemstatus-bootstrap-collision.txt)
is the before/after unload proof.  A direct server trace in
[`systemstatus-listener-trace.txt`](systemstatus-listener-trace.txt) proves all
three macOS listeners enter the hooked
`xpc_connection_create_mach_service(..., flags=0x1)`.  The production fix
therefore rewrites exactly these names on both listener and client calls:

| macOS/iOS stock name | chroot-private name |
|---|---|
| `com.apple.systemstatus` | `com.apple.macosbooter.systemstatus` |
| `com.apple.systemstatus.publisher` | `com.apple.macosbooter.systemstatus.publisher` |
| `com.apple.systemstatus.activityattribution` | `com.apple.macosbooter.systemstatus.activityattribution` |

The launchd plist publishes only the private names, and `macos_gui.sh` starts
the signed/trustcached macOS daemon before WindowServer and other clients.
[`systemstatus-private-lldb.txt`](systemstatus-private-lldb.txt) is the runtime
witness that a cold WindowServer connection reached the real
`-[STStatusDomainXPCClientListener listener:shouldAcceptNewConnection:]`
delegate.  The post-fix daemon sample,
[`systemstatusd-private.sample.txt`](systemstatusd-private.sample.txt), is idle
after registration rather than spinning.

## Repeated CPU result

The old serial-worker production baseline consumed 5.22 CPU seconds in a
10-second interval (52.2%).  Starting a macOS daemon under the colliding stock
names produced a cold 5.91-second interval (59.1%) and the re-registration
stacks remained visible.

With private names, cumulative WindowServer CPU readings were:

| Run | Cumulative CPU points | Three 10-second deltas | Mean |
|---|---|---|---:|
| production cold start | 15.92, 18.50, 21.07, 23.66 s | 2.58, 2.57, 2.59 s | 25.80% |
| cold WS reload after LLDB proof | 39.08, 41.63, 44.19, 46.74 s | 2.55, 2.56, 2.55 s | 25.53% |

The second run had 15 WindowServer threads, `systemstatusd` reported 0.0% CPU,
and a grep of the new WindowServer log for SystemStatus/NSXPC
disconnect/re-register failures returned zero.  Compared with the 52.2%
baseline, the repeated mean is approximately 51% lower; compared with the
failed stock-name cold run it is approximately 57% lower.

## VNC/input regression result

[`systemstatus-private-vnc/results.json`](systemstatus-private-vnc/results.json)
kept the full Retina framebuffer active after the CPU fix.  Menu open was
341 ms, six visibly changing hover operations were 74-273 ms, menu close was
171 ms, and a correctly targeted title drag was 308 ms with 510,502 changed
pixels.  The before/after window position is visible in
[`systemstatus-private-vnc/title-drag.png`](systemstatus-private-vnc/title-drag.png).

The same run did not publish the contextual menu, and a dedicated retry in
[`systemstatus-private-context-1/results.json`](systemstatus-private-context-1/results.json)
also missed.  This remains an open AppKit menu-tracker / compositor-publication
problem; the SystemStatus work is not presented as a complete VNC usability
fix.
