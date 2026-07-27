"""Verify a click and framebuffer refresh on one persistent RFB connection.

Unlike vnc_capture.py's reconnecting --after mode, this client keeps the
initial framebuffer, applies every incremental rectangle to it, and succeeds
only after OSXvnc sends a full physical-resolution dirty rectangle following
the click.  That catches a frozen live session which a fresh full-frame request
would hide.
"""

import argparse
import hashlib
import socket
import struct
import time

import vnc_capture


def configure_raw(sock):
    pixel_format = struct.pack(
        ">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    sock.sendall(b"\x00\x00\x00\x00" + pixel_format)
    sock.sendall(struct.pack(">BBHi", 2, 0, 1, 0))


def request_update(sock, width, height, incremental):
    sock.sendall(struct.pack(
        ">BBHHHH", 3, 1 if incremental else 0, 0, 0, width, height))


def receive_update(sock, width, framebuffer):
    rectangles = []
    while True:
        message_type = vnc_capture.recv_exact(sock, 1)[0]
        if message_type == 0:
            vnc_capture.recv_exact(sock, 1)
            count = struct.unpack(
                ">H", vnc_capture.recv_exact(sock, 2))[0]
            for _ in range(count):
                x, y, rect_width, rect_height, encoding = struct.unpack(
                    ">HHHHi", vnc_capture.recv_exact(sock, 12))
                rectangles.append(
                    (x, y, rect_width, rect_height, encoding))
                if encoding == 0:
                    pixels = vnc_capture.recv_exact(
                        sock, rect_width * rect_height * 4)
                    row_bytes = rect_width * 4
                    for row in range(rect_height):
                        source = row * row_bytes
                        destination = ((y + row) * width + x) * 4
                        framebuffer[destination:destination + row_bytes] = \
                            pixels[source:source + row_bytes]
                elif encoding not in (-223, -224):
                    raise RuntimeError(
                        f"unexpected RFB encoding {encoding}")
            return rectangles
        if message_type == 2:
            continue
        if message_type == 3:
            vnc_capture.recv_exact(sock, 3)
            length = struct.unpack(
                ">I", vnc_capture.recv_exact(sock, 4))[0]
            vnc_capture.recv_exact(sock, length)
            continue
        raise RuntimeError(
            f"unexpected RFB server message {message_type}")


def save_frame(path, width, height, framebuffer, prefix):
    rgba = bytearray(len(framebuffer))
    nonblack = 0
    for offset in range(0, len(framebuffer), 4):
        blue, green, red = framebuffer[offset:offset + 3]
        rgba[offset:offset + 4] = bytes((red, green, blue, 255))
        if red or green or blue:
            nonblack += 1
    vnc_capture.write_rgba_png(path, width, height, rgba)
    digest = hashlib.sha256(framebuffer).hexdigest()
    print(f"{prefix} bgrx_sha256={digest} "
          f"nonblack={nonblack}/{width * height} wrote={path}")
    return digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--port", type=int, default=5900)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--click", nargs=2, required=True, type=int,
                        metavar=("X", "Y"))
    parser.add_argument("--max-updates", type=int, default=12)
    args = parser.parse_args()

    sock, width, height, name = vnc_capture.connect_rfb(
        args.host, args.port, args.timeout)
    framebuffer = bytearray(width * height * 4)
    try:
        configure_raw(sock)
        request_update(sock, width, height, False)
        initial_rectangles = receive_update(sock, width, framebuffer)
        print(f"RFB name={name!r} size={width}x{height} "
              f"initial_rectangles={initial_rectangles}")
        before_digest = save_frame(
            args.before, width, height, framebuffer, "before")

        x, y = args.click
        if not (0 <= x < width and 0 <= y < height):
            raise ValueError(
                f"click ({x},{y}) outside RFB {width}x{height}")

        # Match a normal viewer: keep an incremental request outstanding while
        # sending the pointer transition, then request the next incremental
        # update after each response.
        request_update(sock, width, height, True)
        time.sleep(0.1)
        sock.sendall(struct.pack(">BBHH", 5, 1, x, y))
        time.sleep(0.05)
        sock.sendall(struct.pack(">BBHH", 5, 0, x, y))

        deadline = time.monotonic() + args.timeout
        full_dirty = False
        update_count = 0
        while (time.monotonic() < deadline and
               update_count < args.max_updates):
            rectangles = receive_update(sock, width, framebuffer)
            update_count += 1
            print(f"incremental[{update_count}]={rectangles}")
            full_dirty = any(
                encoding == 0 and x0 == 0 and y0 == 0 and
                rect_width == width and rect_height == height
                for x0, y0, rect_width, rect_height, encoding in rectangles)
            if (full_dirty and
                hashlib.sha256(framebuffer).hexdigest() != before_digest):
                break
            if full_dirty:
                print("full dirty rectangle was unchanged; waiting for the "
                      "next committed generation")
                full_dirty = False
            request_update(sock, width, height, True)

        after_digest = save_frame(
            args.after, width, height, framebuffer, "after")
        changed = before_digest != after_digest
        print(f"result full_dirty={full_dirty} changed={changed} "
              f"updates={update_count}")
        if not full_dirty or not changed:
            raise SystemExit(2)
    except socket.timeout as error:
        print(f"result timeout={error}")
        raise SystemExit(2) from error
    finally:
        sock.close()


if __name__ == "__main__":
    main()
