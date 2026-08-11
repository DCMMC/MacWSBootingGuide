"""One-command MacWS application/input release gate.

The daily gate deliberately uses fixed iPad targets.  A physical MacBook run
is calibration-only and is not a dependency of this script.  Run this from the
MacWS repository on the controlling Mac; the InputLab probes themselves run on
the iPad so they exercise the production MacWSInputRecord-v4 transport.

This automated phase proves application launch topology and AppKit event
delivery.  It cannot measure glass-to-glass latency or judge animation
stutter from synthetic events; the companion manual sheet in
docs/control-center-input-performance-regression-20260811.md is the required
visible-output phase.
"""

import argparse
import json
import pathlib
import re
import shlex
import subprocess
import time


DEFAULT_APPS_OUTPUT = pathlib.Path("/tmp/macws-control-center-regression")
APP_NAMES = [
    "glassdemo", "terminal", "activity-monitor", "finder", "vscode",
    "system-settings", "maps", "amadine", "word", "excel", "powerpoint",
    "asphalt",
]
THRESHOLDS = {
    "active_interaction_target_fps": 60.0,
    "active_interaction_1pct_low_fps": 45.0,
    "input_bridge_p95_ms": 8.0,
    "input_to_visible_p95_ms": 50.0,
    "motion_60_min_delivery_hz": 45.0,
    "motion_120_min_delivery_hz": 60.0,
}


class Remote:
    def __init__(self, host, user, port):
        self.base = [
            "ssh", "-p", str(port), "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8", f"{user}@{host}",
        ]

    def run(self, command, *, timeout=30, check=True):
        result = subprocess.run(
            self.base + [command], capture_output=True, text=True,
            timeout=timeout,
        )
        if check and result.returncode:
            raise RuntimeError(
                f"remote command failed rc={result.returncode}: "
                f"{result.stderr.strip()}")
        return result.stdout


def parse_json_output(text, label):
    start = text.find("{")
    if start < 0:
        raise RuntimeError(f"{label} emitted no JSON: {text[-400:]}")
    try:
        return json.loads(text[start:])
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid {label} JSON: {error}") from error


def process_table(remote):
    text = remote.run("/bin/ps -axo pid=,comm=")
    table = {}
    for line in text.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        table.setdefault(pathlib.PurePosixPath(fields[1]).name, []).append(
            int(fields[0]))
    return table


def thermal_snapshot(remote):
    text = remote.run(
        "tail -n 1 /var/jb/var/mobile/macos_gui_watchdog.log 2>/dev/null || true",
        check=False,
    ).strip()
    state_match = re.search(r"thermal-state=([a-z]+)", text)
    temperature_match = re.search(r"effective-temp-centic=(\d+)", text)
    return {
        "state": state_match.group(1) if state_match else "unknown",
        "temperature_c": (int(temperature_match.group(1)) / 100.0
                          if temperature_match else None),
        "raw_witness": text,
    }


def preflight(remote):
    processes = process_table(remote)
    required = [
        "WindowServer", "macwsdisplayd", "MacWSHost", "UIKitSystem",
        "MacWSInputLab",
    ]
    missing = [name for name in required if not processes.get(name)]
    native = remote.run(
        "plutil /var/jb/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist "
        "2>/dev/null | grep -E "
        "'MACWS_AGX_NATIVE|MACWS_AGX_REGISTER_CLASSES|MACWS_PIN_FALLBACK'",
        check=False,
    )
    native_keys = {
        key: bool(re.search(rf'"{key}"\s*=\s*1;', native))
        for key in ("MACWS_AGX_NATIVE", "MACWS_AGX_REGISTER_CLASSES",
                    "MACWS_PIN_FALLBACK")
    }
    diagnostics_off = remote.run(
        "test ! -e /var/mnt/rootfs/private/tmp/macws_runtime_diagnostics; "
        "printf $?", check=False,
    ).strip() == "0"
    thermal = thermal_snapshot(remote)
    result = "PASS" if (not missing and all(native_keys.values()) and
                         diagnostics_off and thermal["state"] != "critical") \
        else "FAIL"
    return {
        "result": result,
        "required_processes": {
            name: processes.get(name, []) for name in required
        },
        "missing_processes": missing,
        "native_agx_switches": native_keys,
        "runtime_diagnostics_sentinel_off": diagnostics_off,
        "thermal": thermal,
        "thermal_policy": "intervene only at Critical; sample every 300 s",
    }


def run_remote_python(remote, repo, script, arguments, timeout=30):
    command = "cd {} && python3 {} {}".format(
        shlex.quote(str(pathlib.PurePosixPath(repo) / "misc")),
        shlex.quote(script),
        " ".join(shlex.quote(str(value)) for value in arguments),
    )
    return parse_json_output(remote.run(command, timeout=timeout), script)


def input_gate(remote, repo, pid):
    matrix = run_remote_python(
        remote, repo, "host_input_matrix.py", ["--pid", pid], timeout=30)
    motion = {}
    for rate in (60, 120):
        motion[str(rate)] = run_remote_python(
            remote, repo, "host_input_motion.py",
            ["--pid", pid, "--duration", 5, "--hz", rate], timeout=30)
    rates_ok = (
        motion["60"].get("drag_delivery_hz", 0) >=
            THRESHOLDS["motion_60_min_delivery_hz"] and
        motion["120"].get("drag_delivery_hz", 0) >=
            THRESHOLDS["motion_120_min_delivery_hz"]
    )
    latency_ok = all(
        result.get("latency_ms", {}).get("p95") is not None and
        result["latency_ms"]["p95"] <= THRESHOLDS["input_bridge_p95_ms"]
        for result in motion.values()
    )
    semantic_ok = matrix.get("result") == "PASS" and all(
        result.get("result") == "PASS" for result in motion.values())
    return {
        "result": "PASS" if semantic_ok and rates_ok and latency_ok else "FAIL",
        "semantic_matrix": matrix,
        "motion": motion,
        "gates": {
            "semantic_events": semantic_ok,
            "delivery_rate": rates_ok,
            "p95_latency": latency_ok,
        },
    }


def load_app_summary(path):
    if not path.is_file():
        raise RuntimeError(f"missing app summary: {path}")
    summary = json.loads(path.read_text())
    found = [item.get("app") for item in summary.get("apps", [])]
    return {
        "result": "PASS" if (summary.get("result") == "PASS" and
                                found == APP_NAMES) else "FAIL",
        "source": str(path),
        "summary": summary,
    }


def run_app_matrix(args):
    command = [
        "python3", str(pathlib.Path(__file__).with_name(
            "control_center_app_regression.py")),
        "--host", args.host, "--user", args.user, "--port", str(args.port),
        "--output", str(args.apps_output),
    ]
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", default="mobile")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument(
        "--remote-repo", default="/var/jb/var/mobile/MacWSBootingGuide")
    parser.add_argument("--apps-output", type=pathlib.Path,
                        default=DEFAULT_APPS_OUTPUT)
    parser.add_argument("--run-apps", action="store_true",
                        help="launch all 12 apps before validating their matrix")
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path("/tmp/macws-release-regression.json"))
    args = parser.parse_args()
    remote = Remote(args.host, args.user, args.port)
    began = time.time()
    preflight_result = preflight(remote)
    if preflight_result["thermal"]["state"] == "critical":
        report = {
            "result": "ABORTED_CRITICAL_THERMAL",
            "device": args.host,
            "thresholds": THRESHOLDS,
            "preflight": preflight_result,
        }
    else:
        if args.run_apps:
            run_app_matrix(args)
            # App launch is the heaviest automated phase.  Refresh both the
            # process and thermal witnesses before the input benchmark; a new
            # Critical sample must never be ignored just because the initial
            # preflight was cool.
            preflight_result = preflight(remote)
            if preflight_result["thermal"]["state"] == "critical":
                report = {
                    "result": "ABORTED_CRITICAL_THERMAL",
                    "device": args.host,
                    "thresholds": THRESHOLDS,
                    "preflight": preflight_result,
                }
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(
                    json.dumps(report, ensure_ascii=False, indent=2) + "\n")
                print(json.dumps({
                    "result": report["result"],
                    "output": str(args.output),
                    "thermal": report["preflight"]["thermal"],
                }, ensure_ascii=False, indent=2))
                raise SystemExit(2)
        apps = load_app_summary(args.apps_output / "summary.json")
        inputlab_pids = preflight_result["required_processes"].get(
            "MacWSInputLab", [])
        input_result = (input_gate(remote, args.remote_repo, inputlab_pids[-1])
                        if inputlab_pids else {"result": "FAIL"})
        report = {
            "result": "PASS" if (
                preflight_result["result"] == "PASS" and
                apps["result"] == "PASS" and
                input_result["result"] == "PASS") else "FAIL",
            "device": args.host,
            "elapsed_s": time.time() - began,
            "thresholds": THRESHOLDS,
            "preflight": preflight_result,
            "applications": apps,
            "input": input_result,
            "visible_output_gate": {
                "result": "MANUAL_REQUIRED",
                "reason": ("synthetic transport events cannot measure physical "
                           "touch-to-photon latency or 1% low frame rate"),
                "procedure": ("docs/control-center-input-performance-"
                              "regression-20260811.md"),
            },
            "macbook_calibration": "not required for daily regression",
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({
        "result": report["result"],
        "output": str(args.output),
        "thermal": report["preflight"]["thermal"],
    }, ensure_ascii=False, indent=2))
    if report["result"] not in ("PASS",):
        raise SystemExit(2)


if __name__ == "__main__":
    main()
