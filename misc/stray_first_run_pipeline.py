"""Drive Stray's first-run path and retire exact Metal ABI failures.

Run this orchestrator on the development Mac, not inside the chroot.  It keeps
the proprietary captured Metal libraries under an output directory outside the
repository, converts only libraries that the running game reported as exact
length/FNV misses, and installs each replacement through the device-side
validator.  A wave is bounded: a UE fatal spin is killed immediately and a
Critical iPadOS thermal sample stops the entire run.

The input step uses MacWS input ABI v5.  It deliberately targets the largest
visible FCocoaWindow published by the game's version-2 window catalog instead
of relying on the first catalog entry (which is commonly UE's helper window).
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shlex
import struct
import subprocess
import sys
import time


HERE = pathlib.Path(__file__).resolve().parent
REPACK = HERE / "repack_metallib_macabi.py"
INSTALLER = HERE / "install_stray_exact_metallib.py"
VISION_OCR = HERE / "vision_ocr.swift"
KEY_PROBE = "/var/jb/var/mobile/MacWSBootingGuide/misc/host_key_probe.py"
METRICS_PREFIX = "/var/mnt/rootfs/private/tmp/macws_window_metrics"
CAPTURE_PREFIX = "/var/mnt/rootfs/private/tmp"
GAME_NAME = "Stray-Mac-Shipping"
GAME_DIR = (
    "/Users/root/Library/Application Support/Steam/steamapps/"
    "macws-runtime/Stray/Stray.app/Contents/MacOS"
)
IPCTOOL_LABEL = "com.valvesoftware.steam.ipctool"
IPCTOOL_PLIST = (
    "/var/jb/usr/macOS/gui-launchd/"
    "com.valvesoftware.steam.ipctool.plist"
)

MTL_MISS_RE = re.compile(
    r"MTL-LIB-DATA #(?P<sequence>\d+).*?bytes=(?P<length>\d+).*?"
    r"hash=(?P<hash>[0-9a-f]{16}).*?substituted=0.*?"
    r"path=(?P<path>/private/tmp/\S+) written=(?P<written>\d+)"
)
THERMAL_RE = re.compile(
    r"thermal-state=(?P<state>[a-z]+).*?"
    r"effective-temp-centic=(?P<temperature>\d+)"
)


class Remote:
    def __init__(self, host: str, user: str, port: int, password: str):
        self.host = host
        self.user = user
        self.port = port
        self.password = password
        self.base = [
            "ssh", "-p", str(port), "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8", f"{user}@{host}",
        ]

    def run(self, command: str, *, check: bool = True, binary: bool = False,
            timeout: float = 30):
        result = subprocess.run(
            self.base + [command], capture_output=True,
            text=not binary, timeout=timeout,
        )
        if check and result.returncode:
            stderr = (result.stderr.decode(errors="replace") if binary
                      else result.stderr)
            raise RuntimeError(
                f"remote command failed rc={result.returncode}: {stderr}"
            )
        return result.stdout

    def sudo(self, command: str, *, check: bool = True,
             timeout: float = 30):
        prefix = f"printf '%s\\n' {shlex.quote(self.password)} | sudo -S "
        return self.run(prefix + command, check=check, timeout=timeout)

    def copy_from(self, remote_path: str, local_path: pathlib.Path):
        subprocess.run([
            "scp", "-q", "-P", str(self.port),
            f"{self.user}@{self.host}:{remote_path}", str(local_path),
        ], check=True)

    def copy_to(self, local_path: pathlib.Path, remote_path: str):
        subprocess.run([
            "scp", "-q", "-P", str(self.port), str(local_path),
            f"{self.user}@{self.host}:{remote_path}",
        ], check=True)


def parse_metrics(payload: bytes):
    if len(payload) < 24:
        return []
    magic, version, header_size, entry_size, count, generation = \
        struct.unpack_from("<IHHIIQ", payload)
    if (magic != 0x4D57474D or version != 2 or header_size != 24 or
            entry_size != 20 or count < 1 or generation == 0 or
            len(payload) != header_size + count * entry_size):
        return []
    windows = []
    for index in range(count):
        offset = header_size + index * entry_size
        window, flags, group, width, height = struct.unpack_from(
            "<IIIff", payload, offset
        )
        windows.append({
            "window": window,
            "flags": flags,
            "logical_group": group,
            "width": width,
            "height": height,
        })
    return windows


def largest_game_window(remote: Remote, pid: int, timeout: float):
    path = f"{METRICS_PREFIX}.{pid}.bin"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        payload = remote.run(
            f"dd if={shlex.quote(path)} bs=1048576 2>/dev/null",
            check=False, binary=True,
        )
        windows = parse_metrics(payload)
        visible = [item for item in windows if item["flags"] & 1]
        candidates = visible or windows
        if candidates:
            # UE publishes a tiny helper window first.  Its actual game window
            # advertises the full stream-sized minimum geometry.
            best = max(
                candidates,
                key=lambda item: (item["width"] * item["height"],
                                  item["window"]),
            )
            # UE publishes its 0x28 menu/helper window before the spatial
            # FCocoaWindow. Returning that early happened to activate the
            # later key window, but made the orchestrator's evidence name the
            # wrong surface. Wait for a real content-sized window.
            if best["width"] * best["height"] >= 100000:
                return best, windows
        time.sleep(0.2)
    raise RuntimeError(f"no valid window catalog for Stray pid={pid}")


def activate_game_window(remote: Remote, pid: int, window: dict) -> str:
    """Activate the exact native window in an existing fullscreen workspace.

    The pipeline launches Stray directly so Steam is not required to stay in
    memory.  That intentionally bypasses macPad's normal launcher callback,
    which otherwise activates the new catalog window.  Re-enter the same
    public Scene URL used by displayd after the catalog has proved the exact
    PID/window pair; in fullscreen mode macPad activates it in-place instead
    of creating an iPadOS window.  This keeps VNC/Host visual witnesses bound
    to the game rather than whichever AppKit window was focused before the
    benchmark started.
    """
    window_id = int(window["window"])
    url = f"macwshost://new?window={window_id}&pid={pid}&title=Stray"
    output = remote.run(f"uiopen {shlex.quote(url)}", check=False).strip()
    time.sleep(0.8)
    return output or "requested"


def game_window_bounds(remote: Remote, pid: int, window: int):
    """Return CGWindow's actual VNC-space bounds for one game window."""
    source = (
        "/var/jb/var/mobile/MacWSBootingGuide/misc/cg_window_list.py"
    )
    destination = (
        "/var/mnt/rootfs/private/tmp/macws_cg_window_list.py"
    )
    remote.sudo(
        f"/var/jb/usr/bin/install -m 0644 {source} {destination}",
        check=False,
    )
    output = remote.sudo(
        "bash /var/jb/usr/macOS/bin/run_bash.sh -c "
        + shlex.quote(
            "export PATH=/opt/local/bin:/usr/local/bin:/usr/bin:/bin:"
            "/usr/sbin:/sbin; /opt/local/bin/python3.13 "
            f"/private/tmp/macws_cg_window_list.py {pid}"
        ),
        timeout=20,
    )
    try:
        catalog = json.loads(output)
    except json.JSONDecodeError:
        return None
    for item in catalog:
        bounds = item.get("bounds")
        if (item.get("window") == window and item.get("onscreen") and
                isinstance(bounds, list) and len(bounds) == 4 and
                bounds[2] > 0 and bounds[3] > 0):
            return [round(value) for value in bounds]
    return None


def thermal_snapshot(remote: Remote):
    raw = remote.run(
        "tail -n 1 /var/jb/var/mobile/macos_gui_watchdog.log 2>/dev/null",
        check=False,
    ).strip()
    match = THERMAL_RE.search(raw)
    return {
        "state": match.group("state") if match else "unknown",
        "temperature_c": (int(match.group("temperature")) / 100.0
                          if match else None),
        "raw": raw,
    }


def wait_for_pid(remote: Remote, timeout: float):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        output = remote.run(
            "ps -axo pid=,uid=,comm= | "
            f"awk '$2 == 501 && $3 == \"./{GAME_NAME}\" {{pid=$1}} "
            "END {if (pid) print pid}'",
            check=False,
        ).strip()
        if output.isdigit() and int(output) > 1:
            return int(output)
        time.sleep(0.25)
    raise RuntimeError("Stray process did not appear")


def ensure_ipctool(remote: Remote):
    # A live full Steam client owns the game IPC graph and /tmp/steam.pipe.
    # Loading Valve's standalone ipcserver beside it is both unnecessary and
    # can fail because the client has already claimed the corresponding
    # endpoint.  Runtime evidence from Stray then shows steamclient.dylib
    # loading with the real nonzero Steam ID.  Use the small ipcserver job only
    # for the direct/no-client fallback.
    steam_contract = remote.run(
        "/var/jb/usr/bin/killall -0 steam_osx 2>/dev/null && "
        "test -p /var/mnt/rootfs/private/tmp/steam.pipe && "
        "echo steam-client-running",
        check=False,
    ).strip()
    if steam_contract == "steam-client-running":
        return steam_contract

    # Rootless launchctl resolves this UID-501 plist into the user domain even
    # when `sudo launchctl load` is the submitting command.  The previous
    # system-only probe therefore declared a live endpoint missing and retried
    # until timeout.  Check both legal domains; Stray itself runs as UID 501
    # and can consume the user-domain Mach service.
    status_command = (
        f"launchctl print system/{IPCTOOL_LABEL} 2>/dev/null || "
        f"launchctl print user/501/{IPCTOOL_LABEL} 2>/dev/null || true"
    )
    status = remote.sudo(
        status_command,
        check=False,
    )
    if re.search(r"\bpid\s*=\s*\d+", status):
        return "already-running"
    remote.sudo(
        f"test -f {shlex.quote(IPCTOOL_PLIST)} && "
        f"launchctl load {shlex.quote(IPCTOOL_PLIST)}",
    )
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        status = remote.sudo(status_command, check=False)
        if re.search(r"\bpid\s*=\s*\d+", status):
            return "loaded"
        time.sleep(0.25)
    raise RuntimeError("Steam ipctool Mach service did not become live")


def start_game(remote: Remote, log_path: pathlib.Path, stat_fps: bool,
               game_args: list[str], exec_commands: list[str],
               native_plain: bool):
    # iPadOS's noninteractive sudo PATH does not contain Procursus and this
    # device has no pkill binary.  The former best-effort command therefore
    # left UE's fatal-spin process alive; wait_for_pid could bind the next wave
    # to that stale PID before the new game published its window catalog.
    remote.sudo(
        f"/var/jb/usr/bin/killall -9 {GAME_NAME} 2>/dev/null || true",
        check=False,
    )
    launch_arguments = ["-log", "-stdout", "-FullStdOutLogOutput"]
    launch_arguments.extend(game_args)
    commands = list(exec_commands)
    if stat_fps:
        commands.insert(0, "stat fps")
    if commands:
        # This string is subsequently shell-quoted as the one `bash -c`
        # argument. Keep the complete comma-separated command string as one
        # argv entry; backslash-escaped quotes would become literal bytes and
        # split commands containing spaces into unrelated argv entries.
        launch_arguments.append("-ExecCmds=" + ",".join(commands))
    shell_command = (
        f"cd {shlex.quote(GAME_DIR)} && exec ./{GAME_NAME} " +
        " ".join(shlex.quote(argument) for argument in launch_arguments)
    )
    environment = [
        "HOME=/Users/root", "USER=mobile", "LOGNAME=mobile",
        "TMPDIR=/tmp", "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "SteamAppId=1332010", "SteamGameId=1332010",
        "SteamOverlayGameId=1332010", "SteamClientLaunch=1",
        "MACWS_AGX_NATIVE=1", "MACWS_AGX_REGISTER_CLASSES=1",
        "MACWS_PIN_FALLBACK=1", "MACWS_STRAY_AGX_COMPAT=1",
        "MACWS_APP_INPUT_DIAGNOSTICS=1",
    ]
    if native_plain:
        environment.append("MACWS_AGX_NATIVE_PLAIN=1")
    command = (
        f"printf '%s\\n' {shlex.quote(remote.password)} | sudo -S env "
        + " ".join(environment)
        + " /var/jb/usr/macOS/bin/launchdchrootexec 501 501 "
          "/var/mnt/rootfs /bin/bash -c "
        + shlex.quote(shell_command)
    )
    output = log_path.open("wb")
    process = subprocess.Popen(
        remote.base + [command], stdout=output, stderr=subprocess.STDOUT,
    )
    return process, output


def send_key(remote: Remote, pid: int, window: dict, key: str, hold: float):
    width = max(1, round(window["width"]))
    height = max(1, round(window["height"]))
    # The helper intentionally remains attached for the complete key hold.
    # Leave enough time for SSH setup/teardown instead of racing the Remote
    # default when a sustained gameplay sample is exactly 30 seconds long.
    command_timeout = max(30.0, hold + 15.0)
    return remote.run(
        f"python3 {KEY_PROBE} --pid {pid} --window {window['window']} "
        f"--width {width} --height {height} --key {shlex.quote(key)} "
        f"--hold {hold}",
        timeout=command_timeout,
    ).strip()


def send_return(remote: Remote, pid: int, window: dict, hold: float):
    return send_key(remote, pid, window, "return", hold)


def send_escape(remote: Remote, pid: int, window: dict, hold: float):
    return send_key(remote, pid, window, "escape", hold)


PRESENT_SAMPLE_RE = re.compile(
    r"STRAY-PRESENT sequence=(?P<sequence>\d+) "
    r"totalSeconds=(?P<total_seconds>[0-9.]+).*?"
    r"averageFPS=(?P<average_fps>[0-9.]+).*?"
    r"windowFPS=(?P<window_fps>[0-9.]+)"
)


def latest_present_sample(log_path: pathlib.Path):
    """Return the last bounded present witness emitted by libmachook."""
    matches = list(PRESENT_SAMPLE_RE.finditer(read_log(log_path)))
    if not matches:
        return None
    match = matches[-1]
    return {
        "sequence": int(match.group("sequence")),
        "total_seconds": float(match.group("total_seconds")),
        "average_fps": float(match.group("average_fps")),
        "window_fps": float(match.group("window_fps")),
    }


def send_normalized_tap(remote: Remote, pid: int, window: dict,
                        normalized_x: float, normalized_y: float):
    width = max(1, round(window["width"]))
    height = max(1, round(window["height"]))
    x = round(width * normalized_x)
    y = round(height * normalized_y)
    return remote.run(
        f"python3 /var/jb/var/mobile/MacWSBootingGuide/misc/"
        f"host_gesture_probe.py tap --pid {pid} "
        f"--window {window['window']} --width {width} --height {height} "
        f"--x {x} --y {y} --socket "
        f"/var/mnt/rootfs/private/tmp/macws_host_input.sock",
    ).strip()


def send_normalized_rfb_tap(host: str, port: int, window: dict,
                            normalized_x: float, normalized_y: float):
    """Send one bounded RFB pointer pair to the fullscreen Stray surface.

    Stray's UE/Slate save selector runtime-confirmed that it receives the
    AppKit down/up pair from Host ABI v5 but does not change state.  OSXvnc's
    PointerEvent path is a useful independent control because it enters the
    same system route as an interactive VNC viewer.  This helper is used only
    after Vision proves the fullscreen SELECT SAVE page is frontmost.
    """
    from vnc_capture import click as rfb_click, connect_rfb

    # FCocoaWindow metrics are in logical points (1194x834 on this iPad),
    # whereas Retina RFB PointerEvent coordinates are physical pixels
    # (2388x1668).  Query the current server geometry instead of silently
    # clicking the upper-left quarter after a production cold start switches
    # Retina back on.
    probe, width, height, _ = connect_rfb(host, port, 8.0)
    probe.close()
    x = round(width * normalized_x)
    y = round(height * normalized_y)
    rfb_click(host, port, 8.0, x, y)
    return (
        f"rfb-pointer button=1/0 framebuffer={width}x{height} "
        f"point=({x},{y})"
    )


def send_rfb_key(host: str, port: int, key: str, hold: float):
    """Send one bounded RFB KeyEvent pair through OSXvnc's input path."""
    from vnc_capture import connect_rfb

    keysyms = {
        "return": 0xFF0D,
        "escape": 0xFF1B,
        "w": ord("w"),
    }
    if key not in keysyms:
        raise ValueError(f"unsupported RFB key: {key}")
    sock, width, height, _ = connect_rfb(host, port, 8.0)
    try:
        keysym = keysyms[key]
        sock.sendall(struct.pack(">BBxxI", 4, 1, keysym))
        time.sleep(hold)
        sock.sendall(struct.pack(">BBxxI", 4, 0, keysym))
    finally:
        sock.close()
    return (
        f"rfb-key key={key} keysym=0x{keysyms[key]:x} "
        f"framebuffer={width}x{height} hold={hold:.3f}s"
    )


def send_start_game_tap(remote: Remote, pid: int, window: dict):
    """Tap the normalized Start Game button after a save slot is selected.

    A Retina runtime capture after selecting SLOT 1 measured the button center
    at roughly (0.167, 0.69) in the complete RFB surface. It is not present until a save
    slot has been activated, so callers must not use this as a substitute for
    selecting the slot itself.  Route the atomic tap to the exact FCocoaWindow
    rather than through the global RFB pointer path, whose coordinate
    transform includes the desktop origin.
    """
    return send_normalized_tap(remote, pid, window, 0.167, 0.69)


def send_select_save_slot_tap(remote: Remote, pid: int, window: dict):
    """Select the first empty save slot through Host input ABI v5.

    A 1194x834 runtime capture put the highlighted SLOT 1 card at
    x=20..378, y=290..493, whose center is normalized (0.167, 0.47).
    Synthetic Return did not activate this card, while the preceding main-menu
    Return did work, so make this spatial action explicit and evidence-bearing
    instead of repeatedly sending a key to the wrong first-run state.
    """
    return send_normalized_tap(remote, pid, window, 0.167, 0.47)


def send_resume_action(remote: Remote, pid: int, window: dict, hold: float):
    """Activate RESUME regardless of the pause menu's hover selection.

    The Start Game tap leaves the synthetic pointer near the pause menu's QUIT
    row.  When Escape opens the menu, Unreal transfers selection to that hover
    row; blindly pressing Return therefore asks to quit instead of resuming.
    RESUME is centered at a stable window-local (0.5, 0.40).
    """
    tap = send_normalized_tap(remote, pid, window, 0.5, 0.40)
    time.sleep(0.25)
    activate = send_return(remote, pid, window, hold)
    return f"{tap}; {activate}"


def capture_vnc(host: str, port: int, destination: pathlib.Path,
                content_bounds: list[int] | None = None):
    raw_path = destination.with_suffix(".bgrx")
    command = [
        sys.executable, str(HERE / "vnc_capture.py"), host,
        str(destination), "--port", str(port), "--timeout", "15",
        "--raw", str(raw_path),
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    colorful_ratio = None
    mean_brightness = None
    edge_ratio = None
    mean_local_delta = None
    analysis_bounds = None
    try:
        raw = raw_path.read_bytes()
        size_match = re.search(r"size=(\d+)x(\d+)", result.stdout)
        screen_width = int(size_match.group(1)) if size_match else 0
        screen_height = int(size_match.group(2)) if size_match else 0
        if screen_width * screen_height * 4 != len(raw):
            screen_width = screen_height = 0
        left = 0
        top = 0
        right = screen_width
        bottom = screen_height
        if content_bounds and screen_width and screen_height:
            window_x, window_y, content_width, content_height = \
                content_bounds
            # CGWindow bounds use the same top-left screen coordinates as the
            # RFB framebuffer.  AppKit includes the 28-point title bar, so
            # exclude it from scene classification.  Sampling the entire VNC
            # desktop caused Steam's blue background and the colorful Dock to
            # turn Stray's black SELECT SAVE screen into a false success.
            left = max(0, window_x)
            top = max(0, window_y + 28)
            right = min(screen_width, window_x + content_width)
            bottom = min(screen_height, window_y + content_height)
        analysis_bounds = [left, top, right, bottom]
        sampled = 0
        colorful = 0
        brightness_total = 0
        edge_count = 0
        local_delta_total = 0
        # One in every 16 pixels is enough to distinguish Stray's black/gray
        # setup menus from a rendered 3D scene without making screenshot
        # classification part of the frame-time workload.
        if screen_width and screen_height:
            for y in range(top, bottom, 4):
                for x in range(left, right, 4):
                    offset = (y * screen_width + x) * 4
                    blue, green, red = raw[offset:offset + 3]
                    brightness = max(red, green, blue)
                    brightness_total += brightness
                    sampled += 1
                    if brightness >= 24 and max(red, green, blue) - \
                            min(red, green, blue) >= 18:
                        colorful += 1
                    if x + 4 < right:
                        neighbor = offset + 16
                        delta = max(
                            abs(raw[offset + channel] -
                                raw[neighbor + channel])
                            for channel in range(3)
                        )
                        local_delta_total += delta
                        if delta >= 18:
                            edge_count += 1
        if sampled:
            colorful_ratio = colorful / sampled
            mean_brightness = brightness_total / sampled
            edge_ratio = edge_count / sampled
            mean_local_delta = local_delta_total / sampled
    except OSError:
        pass
    return {
        "path": str(destination),
        "raw_path": str(raw_path),
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "colorful_pixel_ratio": colorful_ratio,
        "mean_brightness": mean_brightness,
        "edge_pixel_ratio": edge_ratio,
        "mean_local_delta": mean_local_delta,
        "analysis_bounds": analysis_bounds,
    }


def recognize_screen_text(capture: dict):
    """Recognize Stray's stylized first-run UI with macOS Vision.

    Tesseract produced an empty result for the same 1194x834 runtime frames,
    while VNRecognizeTextRequest recovered START GAME and every SELECT SAVE
    label.  Keep OCR on the host so it adds no CPU or memory pressure to the
    iPad, and retain the recognized text beside each screenshot as evidence
    for the input decision.
    """
    result = subprocess.run(
        ["/usr/bin/swift", str(VISION_OCR), capture["path"]],
        capture_output=True, text=True, timeout=20,
    )
    text = result.stdout.strip()
    capture["recognized_text"] = text
    if result.returncode:
        capture["ocr_error"] = result.stderr.strip()
    return text.upper()


def collect_render_targets(remote: Remote, destination: pathlib.Path):
    output = remote.run(
        "find /var/mnt/rootfs/private/tmp -maxdepth 1 -type f "
        "-name 'macws_stray_*_c*.raw' -print | sort",
        check=False,
    )
    copied = []
    for source in output.splitlines():
        source = source.strip()
        if not source:
            continue
        target = destination / pathlib.Path(source).name
        remote.copy_from(source, target)
        copied.append(str(target))
    if copied:
        remote.sudo(
            "rm -f /var/mnt/rootfs/private/tmp/macws_stray_rt_*.raw "
            "/var/mnt/rootfs/private/tmp/macws_stray_buf_*.raw",
            check=False,
        )
    return copied


def read_log(path: pathlib.Path):
    try:
        return path.read_text(errors="replace")
    except FileNotFoundError:
        return ""


def fatal_kind(text: str):
    """Classify the first actionable UE/Metal fatal without conflating it.

    A target-OS metallib rejection is recoverable by this pipeline's exact
    converter.  A GPU command-buffer error instead needs a selector-0x1a
    flight-recorder capture and must never be reported as a shader miss.
    """
    if "Target OS is incompatible" in text:
        return "shader_target_os"
    if ("MTLCommandBufferErrorDomain" in text and
            "Command Buffer" in text):
        return "command_buffer"
    if "Spinning after fatal error" in text:
        return "other"
    return None


def exact_misses(text: str):
    unique = {}
    for match in MTL_MISS_RE.finditer(text):
        item = {
            "sequence": int(match.group("sequence")),
            "length": int(match.group("length")),
            "hash": match.group("hash"),
            "path": match.group("path"),
            "written": int(match.group("written")),
        }
        unique[(item["length"], item["hash"])] = item
    return sorted(unique.values(), key=lambda item: item["sequence"])


def convert_and_install(remote: Remote, misses, wave_dir: pathlib.Path,
                        llvm_dis: pathlib.Path, llvm_as: pathlib.Path):
    installed = []
    for item in misses:
        if item["written"] not in (0, item["length"]):
            raise RuntimeError(
                f"capture was not written completely: {item}"
            )
        name = pathlib.PurePosixPath(item["path"]).name
        source = wave_dir / name
        replacement = wave_dir / f"{name[:-4]}.macabi.metallib"
        remote.copy_from(f"{CAPTURE_PREFIX}/{name}", source)
        subprocess.run([
            sys.executable, str(REPACK), str(source), str(replacement),
            "--llvm-dis", str(llvm_dis), "--llvm-as", str(llvm_as),
            "--target-triple", "air64-apple-ios19.0.0-macabi",
            "--container-target", "macabi",
            "--target-major", "19", "--target-minor", "0",
        ], check=True)
        remote_replacement = f"/var/jb/var/mobile/{replacement.name}"
        remote.copy_to(replacement, remote_replacement)
        output = remote.sudo(
            f"python3 /var/jb/var/mobile/MacWSBootingGuide/misc/"
            f"install_stray_exact_metallib.py {CAPTURE_PREFIX}/{name} "
            f"--prebuilt-replacement {remote_replacement}",
            timeout=60,
        ).strip()
        installed.append({**item, "installer_output": output})
    return installed


def stop_game(remote: Remote, pid: int, process: subprocess.Popen,
              output_handle):
    # `kill 0` targets the caller's process group.  Never let an early launch
    # failure turn cleanup into an unbounded signal operation.
    if pid > 1:
        remote.sudo(f"kill -KILL {pid} 2>/dev/null || true", check=False)
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
    output_handle.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", default="mobile")
    parser.add_argument("--ssh-port", type=int, default=22)
    parser.add_argument("--vnc-port", type=int, default=5900)
    parser.add_argument(
        "--sudo-password", default=os.environ.get("MACWS_DEVICE_SUDO_PASSWORD"),
        help="temporary device sudo password, or MACWS_DEVICE_SUDO_PASSWORD",
    )
    parser.add_argument("--max-waves", type=int, default=12)
    parser.add_argument("--launch-timeout", type=float, default=15)
    parser.add_argument("--catalog-timeout", type=float, default=25)
    parser.add_argument("--accept-delay", type=float, default=32)
    parser.add_argument(
        "--menu-delay", type=float, default=30,
        help="seconds after brightness acceptance before selecting Start Game",
    )
    parser.add_argument(
        "--prompt-delay", type=float, default=10,
        help="seconds between first-run default confirmations after Start Game",
    )
    parser.add_argument(
        "--prompt-steps", type=int, default=6,
        help="maximum default confirmations before a gameplay frame is required",
    )
    parser.add_argument(
        "--movie-skip-at", type=int, default=0,
        help=("optional prompt index that sends Escape for an explicit "
              "pause/resume diagnostic; zero leaves the live level alone"),
    )
    parser.add_argument(
        "--scene-color-ratio", type=float, default=0.015,
        help="sampled colorful-pixel ratio that proves a non-menu scene",
    )
    parser.add_argument(
        "--scene-edge-ratio", type=float, default=0.01,
        help=("sampled horizontal-edge ratio required with color; rejects "
              "uniform or low-frequency corrupted frames"),
    )
    parser.add_argument("--wave-timeout", type=float, default=100)
    parser.add_argument("--key-hold", type=float, default=0.12)
    parser.add_argument(
        "--movement-hold", type=float, default=1.0,
        help="seconds to hold W on post-skip black frames",
    )
    parser.add_argument(
        "--gameplay-movement-hold", type=float, default=0.0,
        help=("after the first verified gameplay frame, hold W for this many "
              "seconds and record present-rate witnesses; zero disables it"),
    )
    parser.add_argument("--stat-fps", action="store_true")
    parser.add_argument(
        "--native-plain", action="store_true",
        help=("diagnostic A/B: route ordinary plain textures through the "
              "native AGX allocator instead of the IOSurface lease pool"),
    )
    parser.add_argument(
        "--render-trace", action="store_true",
        help=("enable bounded first-bind/first-draw and 120-present cadence "
              "witnesses for this run"),
    )
    parser.add_argument(
        "--capture-render-targets", action="store_true",
        help=("after a colorful scene is observed, GPU-blit one bounded set "
              "of dynamically discovered intermediate render targets for "
              "offline diagnosis"),
    )
    parser.add_argument(
        "--capture-after-prompt", type=int, default=0,
        help=("diagnostic-only: trigger the bounded render-target capture "
              "after this prompt even when no valid scene is visible"),
    )
    parser.add_argument(
        "--game-arg", action="append", default=[],
        help="extra argv item passed verbatim to Stray (repeatable)",
    )
    parser.add_argument(
        "--exec-command", action="append", default=[],
        help="UE console command appended to -ExecCmds (repeatable)",
    )
    parser.add_argument("--no-auto-convert", action="store_true")
    parser.add_argument(
        "--llvm-prefix", type=pathlib.Path,
        default=pathlib.Path("/opt/homebrew/opt/llvm@15"),
    )
    parser.add_argument(
        "--output", type=pathlib.Path,
        default=pathlib.Path("/tmp/macws-stray-first-run"),
    )
    args = parser.parse_args()
    if not args.sudo_password:
        parser.error("provide --sudo-password or MACWS_DEVICE_SUDO_PASSWORD")
    if args.capture_render_targets and not args.render_trace:
        parser.error("--capture-render-targets requires --render-trace")
    if (args.max_waves < 1 or args.key_hold < 0 or args.movement_hold <= 0 or
            args.gameplay_movement_hold < 0 or
            args.prompt_delay <= 0 or
            args.prompt_steps < 1 or args.movie_skip_at < 0 or
            args.movie_skip_at >= args.prompt_steps or
            not 0 < args.scene_color_ratio < 1 or
            not 0 < args.scene_edge_ratio < 1 or
            args.capture_after_prompt < 0 or
            args.capture_after_prompt > args.prompt_steps):
        parser.error("invalid wave/input/prompt/scene-classification setting")
    if args.capture_after_prompt and not args.capture_render_targets:
        parser.error("--capture-after-prompt requires --capture-render-targets")

    args.output.mkdir(parents=True, exist_ok=True)
    llvm_dis = args.llvm_prefix / "bin/llvm-dis"
    llvm_as = args.llvm_prefix / "bin/llvm-as"
    if not args.no_auto_convert and not (llvm_dis.is_file() and llvm_as.is_file()):
        parser.error(f"LLVM 15 tools are missing below {args.llvm_prefix}")
    remote = Remote(args.host, args.user, args.ssh_port, args.sudo_password)
    remote.copy_to(INSTALLER, "/var/jb/var/mobile/MacWSBootingGuide/misc/"
                   "install_stray_exact_metallib.py")
    remote.copy_to(HERE / "host_input_matrix.py",
                   "/var/jb/var/mobile/MacWSBootingGuide/misc/"
                   "host_input_matrix.py")
    remote.copy_to(HERE / "host_key_probe.py",
                   "/var/jb/var/mobile/MacWSBootingGuide/misc/"
                   "host_key_probe.py")
    ipctool = ensure_ipctool(remote)
    diagnostic_flags = [
        "/var/mnt/rootfs/private/tmp/macws_pipeline_diag",
        "/var/mnt/rootfs/private/tmp/macws_mtl_data_diag",
    ]
    if args.render_trace:
        diagnostic_flags.append(
            "/var/mnt/rootfs/private/tmp/macws_stray_render_trace"
        )
    remote.sudo("touch " + " ".join(diagnostic_flags))
    remote.sudo(
        "rm -f /var/mnt/rootfs/private/tmp/macws_stray_rt_capture_now "
        "/var/mnt/rootfs/private/tmp/macws_stray_rt_*.raw "
        "/var/mnt/rootfs/private/tmp/macws_stray_buf_*.raw",
        check=False,
    )

    summary = {
        "device": args.host,
        "native_agx": True,
        "ipctool": ipctool,
        "game_args": args.game_arg,
        "exec_commands": (["stat fps"] if args.stat_fps else []) +
                         args.exec_command,
        "movie_skip_at": args.movie_skip_at,
        "render_trace": args.render_trace,
        "native_plain": args.native_plain,
        "capture_render_targets": args.capture_render_targets,
        "capture_after_prompt": args.capture_after_prompt,
        "gameplay_movement_hold": args.gameplay_movement_hold,
        "scene_classifier": {
            "colorful_pixel_ratio": args.scene_color_ratio,
            "edge_pixel_ratio": args.scene_edge_ratio,
        },
        "thermal_policy": (
            "read the cached 5-minute watchdog sample at wave boundaries; "
            "stop only at Critical"
        ),
        "waves": [],
        "result": "INCOMPLETE",
    }
    summary_path = args.output / "summary.json"
    try:
        for wave in range(1, args.max_waves + 1):
            thermal = thermal_snapshot(remote)
            if thermal["state"] == "critical":
                summary["result"] = "THERMAL_CRITICAL"
                break
            wave_dir = args.output / f"wave-{wave:02d}"
            wave_dir.mkdir(exist_ok=True)
            log_path = wave_dir / "stray.log"
            process, output_handle = start_game(
                remote, log_path, args.stat_fps,
                args.game_arg, args.exec_command, args.native_plain,
            )
            pid = 0
            entry = {"wave": wave, "thermal_before": thermal}
            try:
                pid = wait_for_pid(remote, args.launch_timeout)
                entry["pid"] = pid
                try:
                    window, windows = largest_game_window(
                        remote, pid, args.catalog_timeout
                    )
                except RuntimeError:
                    # A first-use shader can fail before FCocoaWindow publishes
                    # a catalog entry (observed with Stray's low-quality
                    # startup path on 2026-08-17).  Treat the actual UE/Metal
                    # fatal as another exact-cache wave instead of losing it
                    # behind the secondary "no catalog" symptom.  A genuinely
                    # live process with no window still raises below.
                    text = read_log(log_path)
                    detected_fatal = fatal_kind(text)
                    if not detected_fatal:
                        raise
                    misses = exact_misses(text)
                    entry.update({
                        "window_catalog_unavailable": True,
                        "fatal_kind": detected_fatal,
                        "fatal_shader":
                            detected_fatal == "shader_target_os",
                        "process_exited": process.poll() is not None,
                        "scene_detected": False,
                        "exact_misses": misses,
                        "after_wait": capture_vnc(
                            args.host, args.vnc_port,
                            wave_dir / "after-wait.png",
                        ),
                    })
                    stop_game(remote, pid, process, output_handle)
                    output_handle = None
                    if args.no_auto_convert and misses:
                        summary["result"] = "EXACT_SHADER_MISS"
                        summary["waves"].append(entry)
                        break
                    if not misses:
                        summary["result"] = (
                            "COMMAND_BUFFER_ERROR"
                            if detected_fatal == "command_buffer"
                            else "FATAL_WITHOUT_CAPTURE"
                        )
                        summary["waves"].append(entry)
                        break
                    entry["installed"] = convert_and_install(
                        remote, misses, wave_dir, llvm_dis, llvm_as
                    )
                    summary["waves"].append(entry)
                    summary_path.write_text(
                        json.dumps(summary, ensure_ascii=False, indent=2) +
                        "\n"
                    )
                    continue
                entry["window"] = window
                entry["windows"] = windows
                entry["workspace_activation"] = activate_game_window(
                    remote, pid, window
                )
                window_bounds = game_window_bounds(
                    remote, pid, window["window"]
                )
                entry["window_bounds"] = window_bounds
                time.sleep(args.accept_delay)
                entry["before_accept"] = capture_vnc(
                    args.host, args.vnc_port,
                    wave_dir / "before-accept.png",
                    window_bounds,
                )
                try:
                    accept_window, accept_windows = largest_game_window(
                        remote, pid, 5
                    )
                except RuntimeError:
                    # Shader creation continues asynchronously while the
                    # brightness prompt is visible.  A later exact-library
                    # miss can therefore invalidate the FCocoaWindow catalog
                    # during accept_delay, after the initial catalog probe
                    # succeeded.  Recover from the evidence-bearing Metal
                    # fatal here just as at the initial catalog boundary;
                    # otherwise the secondary "no valid window" symptom
                    # aborts the multi-wave converter before it can install
                    # the captured library.
                    text = read_log(log_path)
                    detected_fatal = fatal_kind(text)
                    if not detected_fatal:
                        raise
                    misses = exact_misses(text)
                    entry.update({
                        "window_catalog_lost_before_accept": True,
                        "fatal_kind": detected_fatal,
                        "fatal_shader":
                            detected_fatal == "shader_target_os",
                        "process_exited": process.poll() is not None,
                        "scene_detected": False,
                        "exact_misses": misses,
                        "after_wait": capture_vnc(
                            args.host, args.vnc_port,
                            wave_dir / "after-wait.png",
                            window_bounds,
                        ),
                    })
                    stop_game(remote, pid, process, output_handle)
                    output_handle = None
                    if args.no_auto_convert and misses:
                        summary["result"] = "EXACT_SHADER_MISS"
                        summary["waves"].append(entry)
                        break
                    if not misses:
                        summary["result"] = (
                            "COMMAND_BUFFER_ERROR"
                            if detected_fatal == "command_buffer"
                            else "FATAL_WITHOUT_CAPTURE"
                        )
                        summary["waves"].append(entry)
                        break
                    entry["installed"] = convert_and_install(
                        remote, misses, wave_dir, llvm_dis, llvm_as
                    )
                    summary["waves"].append(entry)
                    summary_path.write_text(
                        json.dumps(summary, ensure_ascii=False, indent=2) +
                        "\n"
                    )
                    continue
                entry["accept_window"] = accept_window
                entry["accept_windows"] = accept_windows
                entry["accept"] = send_return(
                    remote, pid, accept_window, args.key_hold
                )

                detected_fatal = None
                scene_detected = False
                process_exited = False
                menu_deadline = time.monotonic() + args.menu_delay
                while time.monotonic() < menu_deadline:
                    text = read_log(log_path)
                    detected_fatal = fatal_kind(text)
                    if detected_fatal:
                        break
                    if process.poll() is not None:
                        process_exited = True
                        break
                    time.sleep(0.5)
                if not detected_fatal and not process_exited:
                    entry["before_start_game"] = capture_vnc(
                        args.host, args.vnc_port,
                        wave_dir / "before-start-game.png",
                        window_bounds,
                    )
                    start_window, start_windows = largest_game_window(
                        remote, pid, 5
                    )
                    entry["start_game_window"] = start_window
                    entry["start_game_windows"] = start_windows
                    entry["start_game"] = send_return(
                        remote, pid, start_window, args.key_hold
                    )
                    # UE replaces its startup placeholder FCocoaWindow during
                    # the brightness/main-menu transition.  The metrics
                    # sidecar can briefly disappear at exactly that boundary.
                    # Falling back to the initial `window` then targets the
                    # retired placeholder: runtime log evidence showed
                    # `APP-INPUT DROP reason=target-window-closed`.  Preserve
                    # the most recently validated input owner instead.
                    last_input_window = start_window
                    deadline = time.monotonic() + args.wave_timeout
                    next_prompt = time.monotonic() + args.prompt_delay
                    prompt_index = 0
                    movie_skip_sent = args.movie_skip_at == 0
                    save_flow_started = False
                    post_save_actions = 0
                    gameplay_movement_sent = False
                    while time.monotonic() < deadline:
                        text = read_log(log_path)
                        detected_fatal = fatal_kind(text)
                        if detected_fatal:
                            break
                        if process.poll() is not None:
                            process_exited = True
                            break
                        if (not scene_detected and
                                prompt_index < args.prompt_steps and
                                time.monotonic() >= next_prompt):
                            prompt_index += 1
                            prompt_capture = capture_vnc(
                                args.host, args.vnc_port,
                                wave_dir / f"prompt-{prompt_index:02d}.png",
                                window_bounds,
                            )
                            recognized_text = recognize_screen_text(
                                prompt_capture
                            )
                            is_main_menu = (
                                "START GAME" in recognized_text and
                                "SETTINGS" in recognized_text
                            )
                            is_save_screen = (
                                "SELECT SAVE" in recognized_text or
                                ("SLOT 1" in recognized_text and
                                 "SLOT 2" in recognized_text)
                            )
                            entry.setdefault("prompts", []).append({
                                "index": prompt_index,
                                "capture": prompt_capture,
                            })
                            ratio = prompt_capture.get(
                                "colorful_pixel_ratio"
                            )
                            edge_ratio = prompt_capture.get(
                                "edge_pixel_ratio"
                            )
                            scene_classification_ready = (
                                save_flow_started and
                                ((args.movie_skip_at == 0 and
                                  post_save_actions >= 1) or
                                (args.movie_skip_at > 0 and
                                 movie_skip_sent and
                                 prompt_index >= args.movie_skip_at + 4))
                            )
                            if (scene_classification_ready and
                                    ratio is not None and
                                    ratio >= args.scene_color_ratio and
                                    edge_ratio is not None and
                                    edge_ratio >= args.scene_edge_ratio):
                                scene_detected = True
                                entry["scene_detected_at_prompt"] = \
                                    prompt_index
                                entry["scene_colorful_pixel_ratio"] = ratio
                                entry["scene_edge_pixel_ratio"] = edge_ratio
                                if (args.gameplay_movement_hold > 0 and
                                        not gameplay_movement_sent):
                                    # A static UE scene can intentionally fall
                                    # back to a 10 Hz idle cadence.  Hold a
                                    # real MacWS keyboard state while the
                                    # trace is still connected so the summary
                                    # distinguishes that throttle from active
                                    # gameplay throughput.
                                    present_before = latest_present_sample(
                                        log_path
                                    )
                                    movement_started = time.monotonic()
                                    movement_result = send_key(
                                        remote, pid, last_input_window, "w",
                                        args.gameplay_movement_hold,
                                    )
                                    time.sleep(1.0)
                                    present_after = latest_present_sample(
                                        log_path
                                    )
                                    movement_entry = {
                                        "key": "w",
                                        "hold_seconds":
                                            args.gameplay_movement_hold,
                                        "elapsed_seconds": round(
                                            time.monotonic() -
                                            movement_started, 3
                                        ),
                                        "input": movement_result,
                                        "present_before": present_before,
                                        "present_after": present_after,
                                    }
                                    if (present_before and present_after and
                                            present_after["sequence"] >
                                            present_before["sequence"] and
                                            present_after["total_seconds"] >
                                            present_before["total_seconds"]):
                                        movement_entry["active_present_fps"] = (
                                            (present_after["sequence"] -
                                             present_before["sequence"]) /
                                            (present_after["total_seconds"] -
                                             present_before["total_seconds"])
                                        )
                                    movement_entry["after_movement"] = \
                                        capture_vnc(
                                            args.host, args.vnc_port,
                                            wave_dir /
                                            "after-gameplay-movement.png",
                                            window_bounds,
                                        )
                                    entry["gameplay_movement"] = \
                                        movement_entry
                                    gameplay_movement_sent = True
                                if args.capture_render_targets:
                                    remote.sudo(
                                        "touch /var/mnt/rootfs/private/tmp/"
                                        "macws_stray_rt_capture_now"
                                    )
                            else:
                                try:
                                    prompt_window, prompt_windows = \
                                        largest_game_window(remote, pid, 5)
                                    last_input_window = prompt_window
                                except RuntimeError:
                                    # The FCocoaWindow remains alive while UE
                                    # momentarily stops refreshing its metrics
                                    # sidecar during menu transitions.  Reuse
                                    # the last structurally validated target;
                                    # the app-input receiver independently
                                    # rejects a stale window number.
                                    prompt_window = last_input_window
                                    prompt_windows = []
                                if (args.movie_skip_at > 0 and
                                        prompt_index == args.movie_skip_at):
                                    input_kind = "escape"
                                    prompt_result = send_escape(
                                        remote, pid, prompt_window,
                                        args.key_hold
                                    )
                                    movie_skip_sent = True
                                elif (args.movie_skip_at > 0 and prompt_index ==
                                      args.movie_skip_at + 1):
                                    # Runtime capture showed the prior Start
                                    # Game pointer position hovering QUIT when
                                    # Escape opened this menu.  Directly tap
                                    # RESUME rather than assuming the keyboard
                                    # highlight is on its default row.
                                    input_kind = "resume_tap_return"
                                    prompt_result = send_resume_action(
                                        remote, pid, prompt_window,
                                        args.key_hold
                                    )
                                elif is_main_menu:
                                    # Startup timing varies substantially on
                                    # a cold shader cache.  Only activate the
                                    # main menu once Vision has actually seen
                                    # its START GAME/SETTINGS labels.
                                    input_kind = "main_menu_return"
                                    prompt_result = send_return(
                                        remote, pid, prompt_window,
                                        args.key_hold
                                    )
                                elif is_save_screen:
                                    if not save_flow_started:
                                        # Runtime VNC evidence on 2026-08-18
                                        # showed that Return left SLOT 1
                                        # unchanged. Select the card first,
                                        # retain an intermediate screenshot,
                                        # then tap the button that fades in.
                                        input_kind = (
                                            "select_save_slot_then_start"
                                        )
                                        select_result = \
                                            send_normalized_rfb_tap(
                                                args.host, args.vnc_port,
                                                prompt_window, 0.167, 0.47)
                                        # The slot card is a focus target, not
                                        # the START GAME action itself.  The
                                        # live screen advertises ENTER Select,
                                        # and the AppInput witness confirms the
                                        # pointer lands inside SLOT 1.  Confirm
                                        # the focused card before looking for
                                        # the action exposed by that selection.
                                        confirm_result = send_rfb_key(
                                            args.host, args.vnc_port,
                                            "return", args.key_hold)
                                        time.sleep(1.5)
                                        after_slot = capture_vnc(
                                            args.host, args.vnc_port,
                                            wave_dir /
                                            "after-slot-selection.png",
                                            window_bounds,
                                        )
                                        after_slot_text = \
                                            recognize_screen_text(after_slot)
                                        entry["prompts"][-1][
                                            "after_slot_selection"
                                        ] = after_slot
                                        # A new slot normally exposes START
                                        # GAME.  Some builds transition straight
                                        # into loading, so absence of the label
                                        # is not a failure when SELECT SAVE has
                                        # also disappeared.  If the action is
                                        # visible, activate it with the same
                                        # independent RFB keyboard route.
                                        if "START GAME" in after_slot_text:
                                            start_result = send_rfb_key(
                                                args.host, args.vnc_port,
                                                "return", args.key_hold)
                                        elif ("SELECT SAVE" in after_slot_text or
                                              ("SLOT 1" in after_slot_text and
                                               "SLOT 2" in after_slot_text)):
                                            raise RuntimeError(
                                                "save slot confirmation left "
                                                "SELECT SAVE unchanged"
                                            )
                                        else:
                                            start_result = (
                                                "slot-confirm transitioned "
                                                "directly"
                                            )
                                        prompt_result = (
                                            f"{select_result}; "
                                            f"{confirm_result}; "
                                            f"{start_result}"
                                        )
                                        save_flow_started = True
                                    else:
                                        # Do not toggle the selected slot.
                                        # Retry its advertised ENTER action
                                        # through OSXvnc's keyboard route.
                                        input_kind = \
                                            "retry_start_game_rfb_return"
                                        prompt_result = send_rfb_key(
                                            args.host, args.vnc_port,
                                            "return", args.key_hold)
                                elif (save_flow_started and
                                      post_save_actions >= 3):
                                    # A held movement key is both a first-run
                                    # continuation aid and an end-to-end proof
                                    # that the rendered world consumes native
                                    # keyboard state, rather than merely keeping
                                    # a static Cocoa/Slate UI alive.
                                    input_kind = "move_w"
                                    prompt_result = send_key(
                                        remote, pid, prompt_window, "w",
                                        args.movement_hold
                                    )
                                else:
                                    input_kind = "return"
                                    prompt_result = send_return(
                                        remote, pid, prompt_window,
                                        args.key_hold
                                    )
                                    if save_flow_started:
                                        post_save_actions += 1
                                entry["prompts"][-1].update({
                                    "window": prompt_window,
                                    "windows": prompt_windows,
                                    "input_kind": input_kind,
                                    "input": prompt_result,
                                })
                            # Arm the GPU batch only after this prompt's
                            # input has completed.  Arming it before Return/
                            # Start Game captured six command buffers from the
                            # preceding save menu and falsely described their
                            # intentionally clear depth target as gameplay.
                            if (args.capture_render_targets and
                                    args.capture_after_prompt == prompt_index):
                                remote.sudo(
                                    "touch /var/mnt/rootfs/private/tmp/"
                                    "macws_stray_rt_capture_now"
                                )
                                entry["render_target_capture_trigger"] = {
                                    "kind": "post_input_diagnostic_prompt",
                                    "prompt": prompt_index,
                                }
                            next_prompt = (time.monotonic() +
                                           args.prompt_delay)
                        time.sleep(0.5)
                text = read_log(log_path)
                misses = exact_misses(text)
                entry["fatal_kind"] = detected_fatal
                # Keep the old field for consumers of earlier summaries, but
                # make its meaning exact instead of treating every UE fatal as
                # a shader failure.
                entry["fatal_shader"] = \
                    detected_fatal == "shader_target_os"
                entry["process_exited"] = process_exited
                entry["scene_detected"] = scene_detected
                entry["exact_misses"] = misses
                if args.capture_render_targets:
                    entry["render_targets"] = collect_render_targets(
                        remote, wave_dir
                    )
                entry["after_wait"] = capture_vnc(
                    args.host, args.vnc_port,
                    wave_dir / "after-wait.png",
                    window_bounds,
                )
                if detected_fatal:
                    stop_game(remote, pid, process, output_handle)
                    output_handle = None
                    if args.no_auto_convert and misses:
                        summary["result"] = "EXACT_SHADER_MISS"
                        summary["waves"].append(entry)
                        break
                    if not misses:
                        summary["result"] = (
                            "COMMAND_BUFFER_ERROR"
                            if detected_fatal == "command_buffer"
                            else "FATAL_WITHOUT_CAPTURE"
                        )
                        summary["waves"].append(entry)
                        break
                    entry["installed"] = convert_and_install(
                        remote, misses, wave_dir, llvm_dis, llvm_as
                    )
                    summary["waves"].append(entry)
                    summary_path.write_text(
                        json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
                    )
                    continue

                if process_exited:
                    summary["waves"].append(entry)
                    summary["result"] = "GAME_EXITED"
                    output_handle.close()
                    output_handle = None
                    break
                if not entry["scene_detected"]:
                    summary["waves"].append(entry)
                    summary["result"] = "NO_GAMEPLAY_FRAME"
                    stop_game(remote, pid, process, output_handle)
                    output_handle = None
                    break
                entry["stable_seconds"] = (
                    args.menu_delay + args.wave_timeout
                )
                summary["waves"].append(entry)
                summary["result"] = "STABLE_SCENE"
                # Leave the successful game alive for interactive inspection,
                # screenshot capture, and the FPS phase.
                output_handle.close()
                output_handle = None
                break
            finally:
                if output_handle is not None:
                    stop_game(remote, pid, process, output_handle)
            summary_path.write_text(
                json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
            )
    finally:
        # These flags only add synchronous logs and capture writes.  Exact maps
        # remain active without them, so production runs incur no diagnostic
        # overhead after this pipeline exits.
        remote.sudo("rm -f " + " ".join(diagnostic_flags), check=False)
        remote.sudo(
            "rm -f /var/mnt/rootfs/private/tmp/macws_stray_rt_capture_now",
            check=False,
        )
        summary_path.write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
        )
    print(json.dumps({
        "result": summary["result"],
        "waves": len(summary["waves"]),
        "summary": str(summary_path),
    }, ensure_ascii=False))
    return 0 if summary["result"] == "STABLE_SCENE" else 1


if __name__ == "__main__":
    raise SystemExit(main())
