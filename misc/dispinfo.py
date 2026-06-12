# dispinfo.py — dump WindowServer's display topology as a SkyLight/CoreGraphics client.
# Runs inside the chroot via run_bash.sh. Read-only: queries WS, never touches it.
# Purpose: see how many displays WS has, which is the physical builtin (disp0) vs a
# virtual/offscreen one, their bounds — to design the flicker fix (suppress only the
# physical scanout while keeping the virtual one for VNC).
import ctypes

cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")

class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
class CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]
class CGRect(ctypes.Structure):
    _fields_ = [("origin", CGPoint), ("size", CGSize)]

cg.CGDisplayBounds.restype = CGRect
cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
cg.CGMainDisplayID.restype = ctypes.c_uint32
U32P = ctypes.POINTER(ctypes.c_uint32)
for fn in ["CGGetActiveDisplayList", "CGGetOnlineDisplayList"]:
    getattr(cg, fn).argtypes = [ctypes.c_uint32, U32P, U32P]
for fn in ["CGDisplayIsActive","CGDisplayIsOnline","CGDisplayIsMain","CGDisplayIsBuiltin",
           "CGDisplayIsAsleep","CGDisplayIsInMirrorSet","CGDisplayMirrorsDisplay",
           "CGDisplayPixelsWide","CGDisplayPixelsHigh","CGDisplayModelNumber",
           "CGDisplayVendorNumber","CGDisplayUnitNumber"]:
    getattr(cg, fn).argtypes = [ctypes.c_uint32]

MAX = 16
def getlist(fnname):
    ids = (ctypes.c_uint32 * MAX)()
    cnt = ctypes.c_uint32(0)
    err = getattr(cg, fnname)(MAX, ids, ctypes.byref(cnt))
    return err, [ids[i] for i in range(cnt.value)]

print("MainDisplayID =", cg.CGMainDisplayID())
for label, fn in [("ACTIVE", "CGGetActiveDisplayList"), ("ONLINE", "CGGetOnlineDisplayList")]:
    err, lst = getlist(fn)
    print(f"=== {label} displays: err={err} count={len(lst)} ===")
    for d in lst:
        b = cg.CGDisplayBounds(d)
        print(f"  id={d} bounds=({b.origin.x:.0f},{b.origin.y:.0f} {b.size.width:.0f}x{b.size.height:.0f}) "
              f"px={cg.CGDisplayPixelsWide(d)}x{cg.CGDisplayPixelsHigh(d)} "
              f"main={cg.CGDisplayIsMain(d)} builtin={cg.CGDisplayIsBuiltin(d)} "
              f"active={cg.CGDisplayIsActive(d)} online={cg.CGDisplayIsOnline(d)} "
              f"mirrorOf={cg.CGDisplayMirrorsDisplay(d)} inMirrorSet={cg.CGDisplayIsInMirrorSet(d)} "
              f"model={cg.CGDisplayModelNumber(d)} vendor={cg.CGDisplayVendorNumber(d)} unit={cg.CGDisplayUnitNumber(d)}")
