# validate_leak_fix.sh — run on iOS (via: sudo bash misc/validate_leak_fix.sh)
# Validates the VNC-capture-surface leak fix (capture-surface pool in
# IOSurfaceCreate_safe, gated /tmp/macws_vnc_cappool).
#
# Context (2026-06-21): the WS-killing leak is the screen-capture path
# (_XHWCaptureDesktop <- OSXvnc CGDisplayCreateImage) allocating an
# un-recycled 15MB IOSurface per frame -> IOSURF n->751 -> Jetsam + DCP panic.
# The cappool reuses one surface per (w,h,pf) -> n stays ~1. Captures are
# load-bearing in coexist (only render trigger) so the pool keeps full rate.
#
# Run AFTER a fresh boot / re-jailbreak (a clean boot also clears the
# post-panic DCP degradation that made WS die at AGXIOC=173). NO shebang on
# purpose (AMFI). Invoke with bash, not execve.

set +e
ROOT=/var/mnt/rootfs
GUI=/var/jb/usr/macOS/bin/macos_gui.sh
ERR=/var/jb/var/mobile/WindowServer.err
CLEANUP=/var/jb/var/mobile/MacWSBootingGuide/misc/cleanup_all.sh

wsproc()  { ps ax | grep -i "launchdchrootexec.*WindowServer" | grep -v grep | wc -l | tr -d ' '; }
agxioc()  { grep -ac AGXIOC "$ERR" 2>/dev/null; }
iosurf()  { grep -a IOSURF_STATS "$ERR" 2>/dev/null | tail -1 | grep -oa "n=[0-9]*"; }
cphits()  { grep -ac "CAPPOOL HIT" "$ERR" 2>/dev/null; }

echo "== chroot sanity =="
bash /var/jb/usr/macOS/bin/run_bash.sh -c "echo chroot_ok" 2>&1 | grep -v chdir | tail -1

echo; echo "== PHASE 1: clean baseline (NO cappool) — expect a HEALTHY device to reach AGXIOC>>173 =="
bash "$CLEANUP" >/dev/null 2>&1
rm -f "$ROOT/tmp/macws_vnc_cappool" "$ERR"
( bash "$GUI" start coexist --no-terminal >/dev/null 2>&1 & )
sleep 9
echo "  baseline: WSproc=$(wsproc) AGXIOC=$(agxioc) IOSURF=$(iosurf)"
echo "  (AGXIOC ~173 => device STILL degraded, need real reboot/recovery before fix can help)"
echo "  (AGXIOC ~17000 => healthy; the cappool test below is meaningful)"
bash "$GUI" stop >/dev/null 2>&1

echo; echo "== PHASE 2: WITH cappool — expect WS SURVIVES, IOSURF n bounded (~1-3), CAPPOOL HIT logs =="
bash "$CLEANUP" >/dev/null 2>&1
touch "$ROOT/tmp/macws_vnc_cappool"
rm -f "$ERR"
( bash "$GUI" start coexist --no-terminal >/dev/null 2>&1 & )
for t in 5 10 20 30 45 60; do
  sleep $(( t == 5 ? 5 : (t==10?5:(t==20?10:(t==30?10:15))) ))
  echo "  t=${t}s WSproc=$(wsproc) AGXIOC=$(agxioc) IOSURF=$(iosurf) CAPPOOL_HIT=$(cphits)"
done
echo "  CAPPOOL NEW/HIT lines:"; grep -a "CAPPOOL" "$ERR" 2>/dev/null | head -6
echo
echo "  VERDICT:"
echo "   - WSproc>0 at t=60 + IOSURF n small + CAPPOOL_HIT>0  => LEAK FIXED, WS survives at full capture rate."
echo "   - then capture VNC: (from Mac) vncdo -s localhost::5900 capture /tmp/glassdemo.png"
echo "   - launch GlassDemo inside chroot for the actual UI screenshot."
echo "  (leave WS running for the screenshot; run '$GUI stop' when done)"
