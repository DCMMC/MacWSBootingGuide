"""Stop in macOS AGX updateBindData for the 2388x1668 pf550 texture.

This tracer is intentionally descriptor-driven: it scans the private C++
texture object for the hardware width/height encoding instead of relying on
the macOS (+0x190) or iOS (+0x180) descriptor offset as a cross-OS ABI.
"""

import lldb
import struct


TEXT_STATIC_BASE = 0x1E53DD000
UPDATE_BIND_STATIC = 0x1E57716B4
UPDATE_BIND_THREE_ARG_STATIC = 0x1E5770C1C
UPDATE_BIND_TWO_ARG_STATIC = 0x1E5770C14
THREE_ARG_DISPATCH_STATIC = 0x1E5770C7C
THREE_ARG_DEVICE_GATE_STATIC = 0x1E5770C50
AFTER_COMPRESSIBLE_STORES_STATIC = 0x1E5771718
COMPRESSIBLE_VIRTUAL_CALL_STATIC = 0x1E577173C
UNCOMPRESSIBLE_VIRTUAL_CALL_STATIC = 0x1E5771868

_slide = None
_target_thread = 0
_compressible = False
_target_impl = 0
_entry_count = 0
_three_entry_count = 0


def _reg(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def _read(process, address, size):
    error = lldb.SBError()
    data = process.ReadMemory(address, size, error)
    return data if error.Success() else b""


def _descriptor(process, impl):
    data = _read(process, impl + 0x140, 0x119)
    for relative in range(max(0, len(data) - 23)):
        value = int.from_bytes(data[relative:relative + 24], "little")
        width = ((value >> 28) & 0x3FFF) + 1
        height = ((value >> 42) & 0x3FFF) + 1
        if (width, height) != (2388, 1668):
            continue
        raw = (value >> 128) & ((1 << 64) - 1)
        return {
            "offset": relative + 0x140,
            "layout": (value >> 4) & 3,
            "compressed": (value >> 103) & 1,
            "extended": (value >> 127) & 1,
            "address": ((value >> 66) & ((1 << 36) - 1)) << 4,
            "acceleration": (raw & ((1 << 36) - 1)) << 4,
            "raw": raw,
            "bytes": data[relative:relative + 24].hex(),
        }
    return None


def _print_descriptor(frame, label, impl):
    descriptor = _descriptor(frame.GetThread().GetProcess(), impl)
    if not descriptor:
        print("PF550-UPDATEBIND %s impl=%#x descriptor=NOT-FOUND" %
              (label, impl))
        return
    print("PF550-UPDATEBIND %s impl=%#x descOff=%#x layout=%d "
          "compressed=%d extended=%d address=%#x acceleration=%#x "
          "accelerationRaw=%#x bytes=%s" %
          (label, impl, descriptor["offset"], descriptor["layout"],
           descriptor["compressed"], descriptor["extended"],
           descriptor["address"], descriptor["acceleration"],
           descriptor["raw"], descriptor["bytes"]))


def entry_callback(frame, _bp_location, _internal_dict):
    global _target_thread, _compressible, _target_impl, _entry_count
    process = frame.GetThread().GetProcess()
    texture = _reg(frame, "x0")
    object_data = _read(process, texture + 0x208, 8)
    if len(object_data) != 8:
        return False
    impl = struct.unpack("<Q", object_data)[0]
    _entry_count += 1
    descriptor = _descriptor(process, impl)
    if not descriptor:
        # At method entry the address-bearing descriptor may not have been
        # finalized yet.  Log the actual +0x190 candidate from the macOS
        # object so that this tracer does not silently assume otherwise.
        candidate = _read(process, impl + 0x190, 24)
        if len(candidate) == 24:
            value = int.from_bytes(candidate, "little")
            width = ((value >> 28) & 0x3FFF) + 1
            height = ((value >> 42) & 0x3FFF) + 1
            if _entry_count <= 128 or width >= 1000 or height >= 600:
                print("PF550-UPDATEBIND SEEN count=%d texture=%#x impl=%#x "
                      "candidate=%dx%d layout=%d compressed=%d extended=%d "
                      "gpuVA(x4)=%#x isCompressible(x5)=%d raw=%s" %
                      (_entry_count, texture, impl, width, height,
                       (value >> 4) & 3, (value >> 103) & 1,
                       (value >> 127) & 1, _reg(frame, "x4"),
                       _reg(frame, "x5") & 0xFF, candidate.hex()))
        return False
    _target_thread = frame.GetThread().GetThreadID()
    _compressible = bool(_reg(frame, "x5") & 0xFF)
    _target_impl = impl
    print("PF550-UPDATEBIND ENTRY thread=%#x texture=%#x impl=%#x "
          "cpuAddress(x2)=%#x cpuMetadata(x3)=%#x gpuVA(x4)=%#x "
          "isCompressible(x5)=%d shouldInitMetadata(x6)=%d lr=%#x" %
          (_target_thread, texture, impl, _reg(frame, "x2"),
           _reg(frame, "x3"), _reg(frame, "x4"),
           _reg(frame, "x5") & 0xFF, _reg(frame, "x6") & 0xFF,
           _reg(frame, "lr")))
    _print_descriptor(frame, "entry", impl)
    return True


def three_arg_entry_callback(frame, _bp_location, _internal_dict):
    global _target_thread, _target_impl, _three_entry_count
    process = frame.GetThread().GetProcess()
    texture = _reg(frame, "x0")
    object_data = _read(process, texture + 0x208, 8)
    if len(object_data) != 8:
        return False
    impl = struct.unpack("<Q", object_data)[0]
    _three_entry_count += 1
    descriptor = _descriptor(process, impl)
    # The first pf550 bind enters with the 24-byte hardware descriptor still
    # zeroed; texBaseAddressesUpdated constructs it later.  The first
    # three-argument update in the controlled fresh-WS harness is therefore
    # the target.  Record the criterion explicitly instead of pretending the
    # dimensions are already available here.
    if not descriptor and _three_entry_count != 1:
        return False
    _target_thread = frame.GetThread().GetThreadID()
    _target_impl = impl
    print("PF550-UPDATEBIND THREE-ARG ENTRY count=%d thread=%#x "
          "texture=%#x impl=%#x cpuAddress(x2)=%#x gpuVA(x3)=%#x "
          "shouldInitMetadata(x4)=%d lr=%#x" %
          (_three_entry_count, _target_thread, texture, impl,
           _reg(frame, "x2"), _reg(frame, "x3"), _reg(frame, "x4") & 0xFF,
           _reg(frame, "lr")))
    _print_descriptor(frame, "three-arg-entry", impl)
    return True


def _arm(debugger, static_address, label):
    target = debugger.GetSelectedTarget()
    address = static_address + _slide
    breakpoint = target.BreakpointCreateByAddress(address)
    breakpoint.SetThreadID(_target_thread)
    breakpoint.SetOneShot(True)
    print("PF550-UPDATEBIND armed %s bp=%d address=%#x thread=%#x" %
          (label, breakpoint.GetID(), address, _target_thread))


def arm_after_update(debugger):
    address = (AFTER_COMPRESSIBLE_STORES_STATIC if _compressible
               else UNCOMPRESSIBLE_VIRTUAL_CALL_STATIC)
    _arm(debugger, address,
         "after-compressible-stores" if _compressible
         else "uncompressible-virtual-call")


def arm_three_arg_dispatch(debugger):
    _arm(debugger, THREE_ARG_DISPATCH_STATIC, "three-arg-dispatch")


def arm_three_arg_device_gate(debugger):
    _arm(debugger, THREE_ARG_DEVICE_GATE_STATIC, "three-arg-device-gate")


def arm_compressible_virtual_call(debugger):
    _arm(debugger, COMPRESSIBLE_VIRTUAL_CALL_STATIC,
         "compressible-virtual-call")


def dump_impl_from_x24(debugger, label):
    process = debugger.GetSelectedTarget().GetProcess()
    frame = process.GetSelectedThread().GetFrameAtIndex(0)
    _print_descriptor(frame, label, _reg(frame, "x24"))


def dump_target_impl(debugger, label):
    process = debugger.GetSelectedTarget().GetProcess()
    frame = process.GetSelectedThread().GetFrameAtIndex(0)
    _print_descriptor(frame, label, _target_impl)


def _find_slide(target):
    for module in target.module_iter():
        if (module.GetFileSpec().GetFilename() or "") != "AGXMetal13_3":
            continue
        section = module.FindSection("__TEXT")
        if not section.IsValid():
            continue
        load = section.GetLoadAddress(target)
        if load != lldb.LLDB_INVALID_ADDRESS:
            return load - TEXT_STATIC_BASE
    return None


def install(debugger):
    global _slide
    target = debugger.GetSelectedTarget()
    _slide = _find_slide(target)
    if _slide is None:
        print("PF550-UPDATEBIND FATAL AGXMetal13_3 module not found")
        return False
    breakpoint = target.BreakpointCreateByAddress(UPDATE_BIND_STATIC + _slide)
    breakpoint.SetScriptCallbackFunction(
        "lldb_trace_pf550_updatebind.entry_callback")
    print("PF550-UPDATEBIND installed entry=%#x slide=%#x bp=%d" %
          (UPDATE_BIND_STATIC + _slide, _slide, breakpoint.GetID()))
    three = target.BreakpointCreateByAddress(
        UPDATE_BIND_THREE_ARG_STATIC + _slide)
    three.SetScriptCallbackFunction(
        "lldb_trace_pf550_updatebind.three_arg_entry_callback")
    print("PF550-UPDATEBIND installed three-arg=%#x bp=%d two-arg-thunk=%#x" %
          (UPDATE_BIND_THREE_ARG_STATIC + _slide, three.GetID(),
           UPDATE_BIND_TWO_ARG_STATIC + _slide))
    return True


def wait_for_agx_and_install(debugger):
    """Continue only between dyld image-load stops until AGX is present."""
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    for event_count in range(1, 1025):
        if _find_slide(target) is not None:
            print("PF550-UPDATEBIND AGX loaded after %d image events" %
                  (event_count - 1))
            return install(debugger)
        error = process.Continue()
        if error.Fail():
            print("PF550-UPDATEBIND FATAL continue failed: %s" % error)
            return False
        if process.GetState() != lldb.eStateStopped:
            print("PF550-UPDATEBIND FATAL process state=%d before AGX load" %
                  process.GetState())
            return False
    print("PF550-UPDATEBIND FATAL AGX absent after 1024 image events")
    return False
