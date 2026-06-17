"""
LLDB python module that traces -[AGXG13GFamilyTexture initImplWith...] in
chroot WindowServer. Imported via `command script import` from
misc/lldb_trace_initimpl.lldb (which is itself sourced by Mac lldb after
connecting to iOS debugserver).

Module-level callbacks are registered as breakpoint handlers; each writes
state to /tmp/lldb_initimpl_hits.log on the Mac side (where this code runs).

Addresses are macOS-static (AGXMetal13_3 __TEXT base = 0x1e53dd000); slid
at __lldb_init_module time.
"""

import lldb

LOG = "/tmp/lldb_initimpl_hits.log"

TEXT_STATIC_BASE = 0x1e53dd000

# Macros (macOS-static addresses).
ADDR_INITIMPL_ENTRY    = 0x1e5a4a284  # _-[AGXG13GFamilyTexture initImplWith...]
ADDR_NIL_BLOCK_30      = 0x1e5a4a998  # mov w0,#0; b epi (central nil exit)
ADDR_BLOCK_24_TBNZ_W21 = 0x1e5a4a3fc  # tbnz w21,#1, block 30
ADDR_BLOCK_81_TBNZ_W20 = 0x1e5a4a9a0  # tbnz w20,#0, block 30
ADDR_EPILOGUE          = 0x1e5a4af4c  # block 20 (function exit, return x0)


def L(msg):
    with open(LOG, "a") as f:
        f.write(msg + "\n")


def _regs(frame, names):
    out = {}
    for regset in frame.GetRegisters():
        for r in regset:
            if r.GetName() in names:
                v = r.GetValue()
                try:
                    out[r.GetName()] = int(v, 16) if v else 0
                except (ValueError, TypeError):
                    out[r.GetName()] = v
    return out


def bp_entry(frame, bp_loc, internal_dict):
    r = _regs(frame, ("x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "lr"))
    L(
        f"[entry] self={hex(r.get('x0',0))} sel={hex(r.get('x1',0))} "
        f"device={hex(r.get('x2',0))} desc={hex(r.get('x3',0))} "
        f"ios={hex(r.get('x4',0))} plane={r.get('x5',0)} "
        f"buf={hex(r.get('x6',0))} bpr={r.get('x7',0)} "
        f"lr={hex(r.get('lr',0))}"
    )
    return False  # auto-continue


def bp_nil_block_30(frame, bp_loc, internal_dict):
    r = _regs(frame, ("x0","x19","x20","x21","x22","x23","x24","x25","lr"))
    L(f"[NIL block 30] regs={ {k: hex(v) for k,v in r.items() if isinstance(v,int)} }")
    return False


def bp_block_24_tbnz_w21(frame, bp_loc, internal_dict):
    w21 = _regs(frame, ("x21",)).get("x21", 0) & 0xFFFFFFFF
    L(f"[block 24 tbnz w21,#1] w21={hex(w21)} bit1_set={bool(w21 & 0x2)}")
    return False


def bp_block_81_tbnz_w20(frame, bp_loc, internal_dict):
    w20 = _regs(frame, ("x20",)).get("x20", 0) & 0xFFFFFFFF
    L(f"[block 81 tbnz w20,#0] w20={hex(w20)} bit0_set={bool(w20 & 0x1)}")
    return False


def bp_epilogue(frame, bp_loc, internal_dict):
    x0 = _regs(frame, ("x0",)).get("x0", 0)
    L(f"[epilogue] return x0={hex(x0)} ({'SUCCESS' if x0 else 'NIL'})")
    return False


def __lldb_init_module(debugger, internal_dict):
    """Called by lldb when the module is loaded via `command script import`."""
    open(LOG, "w").write("=== session start ===\n")

    target = debugger.GetSelectedTarget()
    if not target.IsValid():
        L("FATAL: no target — attach a process first")
        return

    # Compute AGXMetal13_3 slide.
    slide = None
    for mod in target.module_iter():
        name = mod.GetFileSpec().GetFilename() or ""
        if name == "AGXMetal13_3":
            sec = mod.FindSection("__TEXT")
            if sec.IsValid():
                slide = sec.GetLoadAddress(target) - TEXT_STATIC_BASE
                L(f"AGXMetal13_3 slide = {hex(slide)} (__TEXT @ {hex(sec.GetLoadAddress(target))})")
                break
    if slide is None:
        names = [m.GetFileSpec().GetFilename() or "?" for m in target.module_iter()][:30]
        L(f"FATAL: AGXMetal13_3 not in target modules. Sample names: {names}")
        return

    bp_specs = [
        (ADDR_INITIMPL_ENTRY,    "bp_entry",             "initImpl entry"),
        (ADDR_NIL_BLOCK_30,      "bp_nil_block_30",      "NIL block 30"),
        (ADDR_BLOCK_24_TBNZ_W21, "bp_block_24_tbnz_w21", "block 24 tbnz w21"),
        (ADDR_BLOCK_81_TBNZ_W20, "bp_block_81_tbnz_w20", "block 81 tbnz w20"),
        (ADDR_EPILOGUE,          "bp_epilogue",          "epilogue"),
    ]
    for static_addr, cb_name, label in bp_specs:
        runtime_addr = static_addr + slide
        bp = target.BreakpointCreateByAddress(runtime_addr)
        if not bp.IsValid():
            L(f"FAILED bp @ {hex(runtime_addr)} ({label})")
            continue
        bp.SetScriptCallbackFunction(f"lldb_trace_initimpl.{cb_name}")
        L(f"bp{bp.GetID()} @ {hex(runtime_addr)} = {label}  cb={cb_name}")

    L("=== breakpoints armed; ready to continue ===")
