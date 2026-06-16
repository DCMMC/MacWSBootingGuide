#!/usr/bin/env python3
"""
two_phase_dump.py — Drive a two-pass lldb attack against the brk #0 in VSCode.

Pass 1: lldb attaches with --waitfor, lets brk fire, dumps state. We extract
        the framework slide from the EXC_BREAKPOINT subcode.

Pass 2: knowing the slide, we synthesize a new lldb script that sets a
        breakpoint at the ABSOLUTE address (slide + 0x12331a8) where the stp
        writes the abort args, then re-attaches a fresh Code launch and lets
        the BP fire. At BP we capture x8/x9 (the abort args).

ASLR randomizes per run, BUT the binary offset 0x12331a8 is fixed; the bp
address must be (this run's slide) + 0x12331a8, computed at runtime.

Solution: we attach early to a process that we'll launch, set a BP at a
fixed binary offset relative to the still-unknown slide, then read the slide
from `image list -o -f` output BEFORE static initializers run.

We piggyback on a dyld function break — `dyld4::Loader::runInitializersBottomUp`
fires AFTER frameworks are mapped (so slide is known to lldb) but BEFORE
their static initializers actually run.
"""
import argparse, os, subprocess, re, sys, tempfile, time

DEV = os.environ.get("DEV", "172.23.154.141")
PW = os.environ.get("PW", "alpine")
PORT = os.environ.get("PORT", "2222")

SSH_COMMON = ["-o", "StrictHostKeyChecking=no", "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no"]

def ssh(cmd, capture=True):
    full = ["sshpass", "-p", PW, "ssh", "-p", PORT, *SSH_COMMON, f"root@{DEV}", cmd]
    return subprocess.run(full, capture_output=capture, text=True)

def scp(local, remote_dev_path):
    full = ["sshpass", "-p", PW, "scp", "-P", PORT, *SSH_COMMON, local, f"root@{DEV}:{remote_dev_path}"]
    return subprocess.run(full, capture_output=True, text=True, check=True)

def launch_code_bg():
    """Trigger a fresh Code launch in the chroot (non-blocking)."""
    subprocess.Popen(["sshpass", "-p", PW, "ssh", "-p", PORT, *SSH_COMMON, f"root@{DEV}",
                      f"echo {PW} | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/launch_vscode.sh "
                      "> /var/jb/var/mobile/vscode.log 2>&1"])

PHASE2_TEMPLATE = """\
process handle SIGTRAP --stop true --pass false --notify true
process attach --waitfor --name "Code"

# Break on a dyld function fired AFTER frameworks are mapped but BEFORE static
# initializers. At that BP, the Electron Framework load addr is known to lldb.
b dyld4::Loader::runInitializersBottomUp
continue

# At dyld BP: now safe to set a BP within Electron Framework using image-offset
# Lldb 16 syntax requires absolute virtual addr — compute via `image list`-ish trick:
# Use the image base from a known SYMBOL in the framework.
# We have v8::V8::Initialize at file offset 0x1003284 — its abs addr will be
# (slide + 0x1003284). Just set a BP on its name; once hit, we'd know slide.
# But we don't want to wait for v8::V8::Initialize (called from main, AFTER static
# inits). Instead: jump straight to the known stp offset via `image lookup`.
#
# Workaround: read slide from the framework module's load address via a side
# channel — `image list -o "Electron Framework"` prints just the slide.
image list -o -f Electron\\ Framework

# Now use a hardcoded absolute address. The slide changes per run, so we have
# to do this dynamically.  We use a tiny trick: lldb supports backtick exprs.
# `image-info` doesn't return a numeric in pure cmd mode, so we resort to:
# manually setting BP at a known SYMBOL within the framework that's never
# called from static init, then computing the offset.
# Static-init-safe anchor: the bp at the start of `node::OnFatalError` (if
# present). Failing that, ANY exported symbol's address = slide + symbol_offset.

# CHEAT: this lldb script is GENERATED with the CURRENT-RUN slide already
# substituted in by the host python orchestrator AFTER reading the slide
# from a prior run.
breakpoint set --address {STP_ABS:#x}
breakpoint set --address {BL_ABS:#x}

breakpoint delete 1
continue

# === at stp x9,x8,[&error_and_abort_args] ===
process status
register read x0 x1 x2 x3 x8 x9 x10 fp sp pc lr
memory read --format x --size 8 --count 16 `$sp`
memory read --format x --size 8 --count 16 `$fp`
# x8, x9 as strings (likely file name)
memory read --format c --size 1 --count 200 `$x8`
memory read --format c --size 1 --count 200 `$x9`

continue

# === at bl 0x5340888 (the abort helper call) ===
process status
register read x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 fp sp pc lr
memory read --format c --size 1 --count 200 `$x0`
memory read --format c --size 1 --count 200 `$x1`
quit
"""

PHASE1 = "misc/electron/lldb/dump_at_check.cmd"
DEV_CMD = "/var/jb/var/mobile/lldb_dump.cmd"


def run_lldb(cmd_local_path):
    """Upload + run lldb --batch --source CMD on the device, return stdout."""
    scp(cmd_local_path, DEV_CMD)
    # background lldb so we can launch Code from another connection
    lldb_proc = subprocess.Popen(
        ["sshpass", "-p", PW, "ssh", "-p", PORT, *SSH_COMMON, f"root@{DEV}",
         f"echo {PW} | sudo -S /var/jb/usr/bin/lldb --batch --source {DEV_CMD} 2>&1"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(3)
    launch_code_bg()
    out, _ = lldb_proc.communicate(timeout=120)
    return out


def parse_brk_slide(text):
    m = re.search(r"EXC_BREAKPOINT.*?subcode=0x([0-9a-fA-F]+)", text)
    if not m: return None
    brk_pc = int(m.group(1), 16)
    return brk_pc - 0x53408c8


def main():
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    repo = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    phase1_path = os.path.join(repo, PHASE1)

    print("=== Phase 1: capture slide ===")
    out1 = run_lldb(phase1_path)
    with open("/tmp/phase1.log", "w") as f: f.write(out1)
    slide = parse_brk_slide(out1)
    if slide is None:
        print("[!] could not extract slide from Phase 1 output -- check /tmp/phase1.log")
        sys.exit(1)
    print(f"  framework slide: 0x{slide:x}")

    stp_abs = slide + 0x12331a8
    bl_abs  = slide + 0x12331b0
    print(f"  stp BP abs:      0x{stp_abs:x}")
    print(f"  bl  BP abs:      0x{bl_abs:x}")

    # NOTE: ASLR will rerandomize the slide on next run.  But we can attach
    # *immediately* on the next attempt and use the dyld-stopped image list
    # to derive the new slide before any static init runs.  Phase 2 below
    # uses a script approach for that.

    print("\n=== Phase 2: re-attach with BP at the abort-args store ===")
    # Generate phase 2 cmd with the *placeholder* values; we'll regenerate
    # again for the actual run using its own slide.

    # Build Phase 2 that ALWAYS gets the slide via dyld-stopped breakpoint
    # and uses lldb's `expr` to compute absolute BP addresses from the slide.
    phase2_cmd = f"""process handle SIGTRAP --stop true --pass false --notify true
process attach --waitfor --name "Code"
b dyld4::Loader::runInitializersBottomUp
continue

# At dyld BP: Electron Framework is loaded.  We obtain its slide by looking up
# a known exported symbol's address.  v8::V8::Initialize sits at file offset
# 0x1003284 in the framework -- after slide, its absolute address is
# slide+0x1003284.  We resolve it by name and use it as an anchor.
image lookup --name "_ZN2v82V810InitializeEi"

# Then we set the BPs we actually care about, by hardcoded absolute addresses
# *relative to the resolved anchor*.  Pure-cmd lldb can't do arithmetic across
# command outputs, so we let the host python orchestrator inject the right
# absolute addresses.  But since ASLR randomizes the slide every run, the
# host CAN'T precompute.  So instead, we use **lldb expressions** with the
# `target.module-load-address` API which IS accessible from the expression
# evaluator (lldb's C++ expr mode).

# Trick: lldb's `expr` lets us call SBTarget API methods.  We construct the
# absolute address dynamically.
expr (lldb::addr_t) lldb::SBTarget::FindModule(lldb::SBFileSpec("Electron Framework")).GetSectionAtIndex(0).GetLoadAddress()

# Fallback simpler: use breakpoint regex/name resolution with `--name` + `--address-offset`
# This DOES support per-symbol offsets in lldb 16.
breakpoint set --shlib "Electron Framework" --address {0x12331a8 + slide:#x}

breakpoint delete 1
continue

process status
register read x0 x1 x2 x3 x8 x9 fp sp pc lr
memory read --format c --size 1 --count 200 `$x8`
memory read --format c --size 1 --count 200 `$x9`
memory read --format x --size 8 --count 16 `$sp`
memory read --format x --size 8 --count 16 `$fp`
quit
"""
    with tempfile.NamedTemporaryFile("w", suffix=".cmd", delete=False) as f:
        f.write(phase2_cmd)
        phase2_path = f.name
    print(f"  generated phase2 cmd: {phase2_path}")
    out2 = run_lldb(phase2_path)
    with open("/tmp/phase2.log", "w") as f: f.write(out2)
    print("\n=== Phase 2 output ===")
    print(out2[-4000:])

if __name__ == "__main__":
    main()
