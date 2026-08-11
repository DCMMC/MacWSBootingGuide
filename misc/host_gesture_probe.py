"""Send a bounded native Host scroll or magnify gesture to a real app.

This is a transport/visual-response probe: it uses the same version-4 datagram
records as UIKit, but deliberately does not claim success from process uptime.
Pair it with DisplayStream counters or before/after Host screenshots.
"""

import argparse
import os
import socket
import struct
import time

from host_input_matrix import (
    DOUBLE_CLICK,
    GESTURE_BEGAN,
    GESTURE_CHANGED,
    GESTURE_ENDED,
    LATENCY_DIAGNOSTIC,
    MAGNIFY,
    SCROLL,
    SCROLL_MOMENTUM,
    SCROLL_WILL_MOMENTUM,
    SECONDARY_TAP,
    SOURCE_FINGER,
    TAP,
    TOUCH_DOWN,
    TOUCH_MOVE,
    TOUCH_UP,
    record,
)

GLOBAL_SYSTEM_SURFACE = 1 << 6


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("gesture", choices=(
        "tap", "double-tap", "right-tap", "drag", "scroll", "magnify"))
    parser.add_argument("--pid", type=int, default=0)
    parser.add_argument("--window", type=int, default=0)
    parser.add_argument("--width", type=int, default=2388)
    parser.add_argument("--height", type=int, default=1668)
    parser.add_argument("--x", type=float, default=1194.0)
    parser.add_argument("--y", type=float, default=834.0)
    parser.add_argument("--end-x", type=float, default=None)
    parser.add_argument("--end-y", type=float, default=None)
    parser.add_argument("--changes", type=int, default=30)
    parser.add_argument("--hz", type=float, default=60.0)
    parser.add_argument("--delta", type=float, default=-4.0,
                        help="scroll pixels or incremental magnification")
    parser.add_argument("--momentum", action="store_true",
                        help="mark a scroll sequence as native momentum")
    parser.add_argument("--will-momentum", action="store_true",
                        help="mark the terminal finger phase as followed by momentum")
    parser.add_argument(
        "--global-system-surface", action="store_true",
        help=("send a fullscreen hardware-style record to a CGS-connected "
              "system endpoint; --pid must name that live endpoint"))
    parser.add_argument("--diagnostic", action="store_true",
                        help="use the bounded DIAG contact marker")
    parser.add_argument(
        "--socket",
        default="/var/mnt/rootfs/private/tmp/macws_host_input.sock")
    args = parser.parse_args()
    if (args.changes < 1 or args.hz <= 0 or args.width < 1 or args.height < 1):
        parser.error("changes, hz, and geometry must be positive")
    if args.momentum and args.gesture != "scroll":
        parser.error("--momentum is valid only for scroll")
    if args.will_momentum and (args.gesture != "scroll" or args.momentum):
        parser.error("--will-momentum requires a non-momentum scroll")
    if args.global_system_surface and args.pid <= 1:
        parser.error("--global-system-surface requires a live target --pid")

    local = f"/tmp/macws_host_gesture.{os.getpid()}.sock"
    try:
        os.unlink(local)
    except FileNotFoundError:
        pass
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(local)
    kind = SCROLL if args.gesture == "scroll" else MAGNIFY
    # Scroll repurposes contactID as the horizontal float in the v4 ABI.
    # A mnemonic integer such as "GSTR" decodes to a huge finite float and is
    # correctly rejected by macwsinputd's +/-16384 input bound.  Magnify and
    # pointer gestures keep a stable ordinary contact identity.
    contact = (struct.unpack("<I", struct.pack("<f", 0.0))[0]
               if args.gesture == "scroll" else 0x47535452)  # "GSTR"
    if args.diagnostic and args.gesture != "scroll":
        contact = 0x44494147  # "DIAG"
    sequence = 0

    def send(phase, amount=0.0):
        nonlocal sequence
        sequence += 1
        if args.global_system_surface:
            phase |= GLOBAL_SYSTEM_SURFACE
        if args.diagnostic:
            phase |= LATENCY_DIAGNOSTIC
        if args.momentum:
            phase |= SCROLL_MOMENTUM
        if args.will_momentum and (phase & GESTURE_ENDED):
            phase |= SCROLL_WILL_MOMENTUM
        sock.sendto(record(
            kind, sequence, args.pid, args.window, args.width, args.height,
            args.x, args.y, pressure=amount, contact=contact,
            source=SOURCE_FINGER, flags=phase), args.socket)

    started = time.perf_counter()
    deadline = time.perf_counter()
    if args.gesture in ("tap", "double-tap", "right-tap"):
        # UIKit classifies a stationary touch as one atomic tap record.  The
        # target bridge constructs and queues its matching down/up pair before
        # entering AppKit's synchronous control tracker; two datagrams can
        # strand the up event inside that nested loop.
        kind = SECONDARY_TAP if args.gesture == "right-tap" else TAP
        if args.gesture == "double-tap":
            # Preserve the two physical taps produced by UIKit: AppKit uses
            # the first clickCount=1 transition to arm controls and the second
            # clickCount=2 transition to perform their double-click action.
            # Sending only clickCount=2 selects Finder items but does not open
            # them, and is not equivalent to the Host's production route.
            send(0, 1.0)
            time.sleep(0.10)
            send(DOUBLE_CLICK, 1.0)
            record_count = 2
        else:
            send(0, 1.0)
            record_count = 1
    elif args.gesture == "drag":
        end_x = args.end_x if args.end_x is not None else args.x + 300.0
        end_y = args.end_y if args.end_y is not None else args.y + 180.0
        kind = TOUCH_DOWN
        send(0, 1.0)
        for index in range(1, args.changes + 1):
            kind = TOUCH_MOVE
            args.x += (end_x - args.x) / (args.changes - index + 1)
            args.y += (end_y - args.y) / (args.changes - index + 1)
            send(0, 1.0)
            deadline += 1.0 / args.hz
            delay = deadline - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        kind = TOUCH_UP
        send(0)
        record_count = args.changes + 2
    else:
        send(GESTURE_BEGAN)
        for _ in range(args.changes):
            send(GESTURE_CHANGED, args.delta)
            deadline += 1.0 / args.hz
            delay = deadline - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        send(GESTURE_ENDED)
        record_count = args.changes + 2
    elapsed = time.perf_counter() - started
    changed_samples = (args.changes if args.gesture in
                       ("drag", "scroll", "magnify") else 0)
    print(
        f"gesture={args.gesture} records={record_count} "
        f"elapsed-ms={elapsed * 1000.0:.3f} "
        f"effective-hz={changed_samples / elapsed:.2f} "
        f"route-pid={args.pid} route-window={args.window} "
        f"point=({args.x:.1f},{args.y:.1f})")
    sock.close()
    os.unlink(local)


if __name__ == "__main__":
    main()
