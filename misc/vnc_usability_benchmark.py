"""Measure system-menu, context-menu, and title-drag VNC responsiveness.

The benchmark keeps one Retina RFB connection and one retained framebuffer.
For pointer motion it hashes a fixed region while masking both the old and new
cursor positions; a cursor tile by itself therefore cannot satisfy a test.

The defaults target Terminal on the iPad13,6 2388x1668 desktop used by this
project. Coordinates are physical RFB pixels, not AppKit points.
"""

import argparse
import hashlib
import json
import os
import socket
import statistics
import struct
import time

import vnc_capture
import vnc_live_click
import vnc_native_input_test

CURSOR_MASK_RADIUS = 32


def check_rect(width, height, rect, label):
    x, y, rect_width, rect_height = rect
    if (x < 0 or y < 0 or rect_width < 1 or rect_height < 1 or
            x + rect_width > width or y + rect_height > height):
        raise ValueError(
            f"{label} {rect} outside framebuffer {width}x{height}")


def region_digest(framebuffer, width, rect, masked_points=(), radius=None):
    """Hash a rectangle after zeroing cursor-sized boxes around points."""
    if radius is None:
        radius = CURSOR_MASK_RADIUS
    x, y, rect_width, rect_height = rect
    hasher = hashlib.sha256()
    for row in range(y, y + rect_height):
        start = (row * width + x) * 4
        line = bytearray(framebuffer[start:start + rect_width * 4])
        for point_x, point_y in masked_points:
            if point_y - radius <= row <= point_y + radius:
                left = max(x, point_x - radius)
                right = min(x + rect_width, point_x + radius + 1)
                if right > left:
                    relative_left = (left - x) * 4
                    relative_right = (right - x) * 4
                    line[relative_left:relative_right] = bytes(
                        relative_right - relative_left)
        hasher.update(line)
    return hasher.hexdigest()


def pointer(sock, mask, point):
    sock.sendall(struct.pack(">BBHH", 5, mask, point[0], point[1]))


def key(sock, keysym):
    sock.sendall(struct.pack(">BBxxI", 4, 1, keysym))
    sock.sendall(struct.pack(">BBxxI", 4, 0, keysym))


def wait_for_region(sock, width, height, framebuffer, rect, masks,
                    previous_digest, started, timeout, max_updates):
    rectangles_seen = []
    deadline = started + timeout
    for update_index in range(1, max_updates + 1):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sock.settimeout(remaining)
        rectangles = vnc_live_click.receive_update(
            sock, width, framebuffer)
        rectangles_seen.extend(rectangles)
        current_digest = region_digest(
            framebuffer, width, rect, masks)
        if current_digest != previous_digest:
            return {
                "passed": True,
                "latency_seconds": time.monotonic() - started,
                "updates": update_index,
                "rectangles": rectangles_seen,
                "digest": current_digest,
            }
        if time.monotonic() < deadline:
            vnc_live_click.request_update(sock, width, height, True)
    return {
        "passed": False,
        "latency_seconds": None,
        "updates": len(rectangles_seen),
        "rectangles": rectangles_seen,
        "digest": previous_digest,
    }


def measured_action(sock, width, height, framebuffer, label, rect, masks,
                    action, timeout, max_updates):
    before = region_digest(framebuffer, width, rect, masks)
    vnc_live_click.request_update(sock, width, height, True)
    started = time.monotonic()
    action()
    result = wait_for_region(
        sock, width, height, framebuffer, rect, masks, before, started,
        timeout, max_updates)
    result["operation"] = label
    latency = result["latency_seconds"]
    latency_label = "MISS" if latency is None else f"{latency:.3f}s"
    print(
        f"USABILITY {'PASS' if result['passed'] else 'MISS'} "
        f"operation={label} latency={latency_label} "
        f"updates={result['updates']}", flush=True)
    return result


def save_snapshot(directory, name, width, height, framebuffer):
    if not directory:
        return
    path = os.path.join(directory, f"{name}.png")
    vnc_live_click.save_frame(path, width, height, framebuffer, name)


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = round((len(ordered) - 1) * fraction)
    return ordered[index]


def main():
    global CURSOR_MASK_RADIUS
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("--port", type=int, default=5900)
    parser.add_argument("--encoding", choices=("raw", "hextile"),
                        default="raw")
    parser.add_argument("--timeout", type=float, default=6.0)
    parser.add_argument("--max-updates", type=int, default=16)
    parser.add_argument("--cursor-mask-radius", type=int, default=32)
    parser.add_argument("--menu-click", nargs=2, type=int, default=(235, 20),
                        metavar=("X", "Y"))
    parser.add_argument("--menu-roi", nargs=4, type=int,
                        default=(40, 30, 520, 410),
                        metavar=("X", "Y", "WIDTH", "HEIGHT"))
    parser.add_argument("--hover", nargs=2, type=int, action="append",
                        metavar=("X", "Y"),
                        help="menu hover point; repeat for a trajectory")
    parser.add_argument("--context-click", nargs=2, type=int,
                        default=(1000, 700), metavar=("X", "Y"))
    parser.add_argument("--context-roi", nargs=4, type=int,
                        default=(750, 450, 900, 900),
                        metavar=("X", "Y", "WIDTH", "HEIGHT"))
    parser.add_argument("--title-drag", nargs=4, type=int,
                        default=(1000, 185, 1250, 285),
                        metavar=("X1", "Y1", "X2", "Y2"))
    parser.add_argument("--drag-roi", nargs=4, type=int,
                        default=(80, 100, 1600, 1200),
                        metavar=("X", "Y", "WIDTH", "HEIGHT"))
    parser.add_argument("--snapshots")
    parser.add_argument("--json")
    args = parser.parse_args()
    CURSOR_MASK_RADIUS = args.cursor_mask_radius

    if (args.timeout <= 0 or args.max_updates < 1 or
            args.cursor_mask_radius < 0):
        parser.error("timeout/max-updates must be positive and mask nonnegative")
    hover_points = args.hover or [
        (180, 65), (180, 115), (180, 150), (180, 200),
        (180, 255), (180, 290), (180, 325), (180, 375),
    ]

    sock, width, height, name = vnc_capture.connect_rfb(
        args.host, args.port, args.timeout)
    framebuffer = bytearray(width * height * 4)
    results = []
    try:
        menu_rect = tuple(args.menu_roi)
        context_rect = tuple(args.context_roi)
        drag_rect = tuple(args.drag_roi)
        for rect, label in ((menu_rect, "menu ROI"),
                            (context_rect, "context ROI"),
                            (drag_rect, "drag ROI")):
            check_rect(width, height, rect, label)
        if args.snapshots:
            os.makedirs(args.snapshots, exist_ok=True)

        if args.encoding == "hextile":
            vnc_live_click.configure_hextile(sock)
        else:
            vnc_live_click.configure_raw(sock)
        vnc_live_click.request_update(sock, width, height, False)
        initial_rectangles = vnc_live_click.receive_update(
            sock, width, framebuffer)
        print(
            f"USABILITY start name={name!r} size={width}x{height} "
            f"initial={initial_rectangles}", flush=True)
        save_snapshot(args.snapshots, "00-initial", width, height,
                      framebuffer)

        # Normalize any menu state left by an interactive client.
        key(sock, 0xFF1B)
        time.sleep(0.15)

        menu_click = tuple(args.menu_click)
        result = measured_action(
            sock, width, height, framebuffer, "menu-open", menu_rect,
            (menu_click,),
            lambda: (pointer(sock, 1, menu_click), time.sleep(0.04),
                     pointer(sock, 0, menu_click)),
            args.timeout, args.max_updates)
        results.append(result)
        save_snapshot(args.snapshots, "01-menu-open", width, height,
                      framebuffer)

        previous_point = menu_click
        for index, next_point in enumerate(hover_points, 1):
            next_point = tuple(next_point)
            result = measured_action(
                sock, width, height, framebuffer,
                f"menu-hover-{index}", menu_rect,
                (previous_point, next_point),
                lambda point=next_point: pointer(sock, 0, point),
                args.timeout, args.max_updates)
            results.append(result)
            previous_point = next_point
            save_snapshot(args.snapshots, f"hover-{index:02d}", width,
                          height, framebuffer)

        result = measured_action(
            sock, width, height, framebuffer, "menu-close", menu_rect,
            (previous_point,), lambda: key(sock, 0xFF1B),
            args.timeout, args.max_updates)
        results.append(result)

        context_point = tuple(args.context_click)
        result = measured_action(
            sock, width, height, framebuffer, "context-menu", context_rect,
            (context_point,),
            lambda: (pointer(sock, 4, context_point), time.sleep(0.04),
                     pointer(sock, 0, context_point)),
            args.timeout, args.max_updates)
        results.append(result)
        save_snapshot(args.snapshots, "context-menu", width, height,
                      framebuffer)

        result = measured_action(
            sock, width, height, framebuffer, "context-close", context_rect,
            (context_point,), lambda: key(sock, 0xFF1B),
            args.timeout, args.max_updates)
        results.append(result)

        drag_start = tuple(args.title_drag[:2])
        drag_end = tuple(args.title_drag[2:])
        result = measured_action(
            sock, width, height, framebuffer, "title-drag", drag_rect,
            (drag_start, drag_end),
            lambda: vnc_native_input_test.send_drag(
                sock, drag_start, drag_end, 12, 0.015),
            args.timeout, args.max_updates)
        results.append(result)
        save_snapshot(args.snapshots, "title-drag", width, height,
                      framebuffer)

        latencies = [result["latency_seconds"] for result in results
                     if result["latency_seconds"] is not None]
        passed = sum(result["passed"] for result in results)
        summary = {
            "name": name,
            "width": width,
            "height": height,
            "encoding": args.encoding,
            "passed": passed,
            "total": len(results),
            "missed": len(results) - passed,
            "latency_min_seconds": min(latencies) if latencies else None,
            "latency_mean_seconds": statistics.mean(latencies)
            if latencies else None,
            "latency_p50_seconds": percentile(latencies, 0.50),
            "latency_p95_seconds": percentile(latencies, 0.95),
            "latency_max_seconds": max(latencies) if latencies else None,
            "results": results,
        }
        print(
            f"USABILITY SUMMARY passed={passed}/{len(results)} "
            f"missed={len(results) - passed} "
            f"p50={summary['latency_p50_seconds']} "
            f"p95={summary['latency_p95_seconds']} "
            f"max={summary['latency_max_seconds']}", flush=True)
        if args.json:
            with open(args.json, "w", encoding="utf-8") as output:
                json.dump(summary, output, indent=2)
                output.write("\n")
        if passed != len(results):
            raise SystemExit(2)
    except (EOFError, RuntimeError, socket.timeout) as error:
        print(f"USABILITY FAIL error={error}", flush=True)
        raise SystemExit(2) from error
    finally:
        sock.close()


if __name__ == "__main__":
    main()
