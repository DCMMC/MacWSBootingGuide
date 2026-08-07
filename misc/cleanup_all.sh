# cleanup_all.sh — one-click stop of all chroot macOS services + cleanup of
# build-helper / debug-loop zombies. Useful when CPU/load gets stuck due to:
#   - WindowServer crash loops respawned by launchd
#   - macwsallocd respawn churn from a bad XPC handler
#   - autosignd zombies accumulating from repeated postinst.sh runs
#   - orphan oslog/tail/grep/find_crash.sh from interactive debug sessions
#   - stale lldb/debugserver attached to dead procs
#
# Run as root (or via `sudo bash`).
#
# NO shebang on purpose — AMFI SIGKILLs execve() of any file with a `#!` line
# on this jailbreak. Always invoke as `bash cleanup_all.sh`.

echo === stopping GUI stack ===
# This script is the explicit thermal/crash-loop emergency stop.  A test lease
# must protect a controlled measurement from an unrelated ordinary start/stop,
# but it must not make emergency recovery partial.  Runtime-confirmed
# 2026-07-29: a stale Chrome test lease made macos_gui.sh refuse this stop;
# cleanup later killed the processes but left ws_headless/mode state behind
# while the orphan workload had already held the device near 5.2 W.
# Authenticate with the exact current token, then clear the now-stopped lease
# so a dead test owner cannot block the next deliberate session.
cleanup_lease_file=/var/jb/var/mobile/macws_test_lease
cleanup_lease_token=""
if [ -f "$cleanup_lease_file" ]; then
  cleanup_lease_token=$(awk 'NR == 1 { print; exit }' "$cleanup_lease_file" 2>/dev/null)
fi
if [ -n "$cleanup_lease_token" ]; then
  MACWS_TEST_LEASE_TOKEN="$cleanup_lease_token" \
    bash /var/jb/usr/macOS/bin/macos_gui.sh stop 2>&1 | head -5
else
  bash /var/jb/usr/macOS/bin/macos_gui.sh stop 2>&1 | head -5
fi
rm -f "$cleanup_lease_file"

echo === unloading all macwsguide jobs ===
for plist in /var/jb/Library/LaunchDaemons/com.macwsguide.*.plist \
             /var/jb/usr/macOS/LaunchDaemons/com.macwsguide.*.plist \
             /var/jb/usr/macOS/gui-launchd/com.macwsguide.*.plist; do
  [ -f "$plist" ] && launchctl unload "$plist" 2>/dev/null
done

echo === unloading WindowServer launchd plists ===
# launchctl unload may block on system-domain plists; bound each call.
for plist in /var/jb/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist \
             /var/jb/usr/macOS/LaunchDaemons/com.apple.coreservices.launchservicesd.plist; do
  [ -f "$plist" ] || continue
  launchctl unload "$plist" 2>/dev/null &
done
# Wait for the WindowServer/launchservicesd processes to actually exit, bounded
# by the previous fixed 3s but finishing immediately when they are already gone.
ws_unload_waited=0
while [ "$ws_unload_waited" -lt 3 ]; do
  if ! ps aux 2>/dev/null | grep -v grep | grep -qE 'WindowServer|launchservicesd'; then
    break
  fi
  sleep 1
  ws_unload_waited=$((ws_unload_waited + 1))
done
for p in $(jobs -p); do kill -9 $p 2>/dev/null; done

echo === killing chroot processes ===
for pat in WindowServer launchservicesd OSXvnc-server Terminal GlassDemo \
           "Activity Monitor" launchdchrootexec MTLSimDriverHost macwsinputd \
           macwsdisplayd macwsinteropd \
           "Visual Studio Code.app" "Code Helper" \
           "Google Chrome.app" "Chrome Helper" MacWSHost; do
  pkill -9 -f "$pat" 2>/dev/null
done

# A running UIKit application is owned by mobile and may survive root's
# procursus pkill on this jailbreak. Remove its exact dynamic launchd label,
# then kill only the executable path if SpringBoard has not reaped it yet.
for label in $(launchctl list 2>/dev/null \
    | awk '/UIKitApplication:com\.macwsguide\.host/{print $3}'); do
  launchctl remove "$label" 2>/dev/null
done
for pid in $(ps aux 2>/dev/null \
    | awk '/Applications\/MacWSHost\.app\/MacWSHost/ && !/awk/{print $2}'); do
  kill -9 "$pid" 2>/dev/null
done

echo === killing all autosignd zombies ===
killall -9 autosignd 2>/dev/null

echo === killing macwsallocd ===
killall -9 macwsallocd 2>/dev/null

echo === killing macwsinputd ===
killall -9 macwsinputd 2>/dev/null
echo === killing display and interop bridges ===
killall -9 macwsdisplayd 2>/dev/null
killall -9 macwsinteropd 2>/dev/null
rm -f /var/mnt/rootfs/private/tmp/macws_window_metrics.*.bin 2>/dev/null
rm -f /var/mnt/rootfs/private/tmp/macws_menu_client.*.sock 2>/dev/null
rm -f /var/mnt/rootfs/private/tmp/macws_menu_snapshot.*.bin 2>/dev/null

echo === killing orphan build/debug scripts ===
for pat in 'sh /tmp/' oslog build_on_ios.sh find_crash.sh '/var/jb/usr/bin/lldb' \
           debugserver tmux; do
  pkill -9 -f "$pat" 2>/dev/null
done
# procursus pkill has occasionally missed an already-orphaned oslog process.
# Resolve only the exact debug executables from ps and terminate their PIDs.
for pid in $(ps aux 2>/dev/null \
    | awk '/\/oslog( |$)|\/debugserver( |$)|\/lldb( |$)/ && !/awk/{print $2}'); do
  kill -9 "$pid" 2>/dev/null
done

# Let the KILL signals land before printing the final state; finish early when
# everything is already dead instead of paying a fixed 2s.
final_waited=0
while [ "$final_waited" -lt 2 ]; do
  if ! ps aux 2>/dev/null | grep -v grep | grep -qE \
      "WindowServer|macwsallocd|macwsinputd|macwsdisplayd|macwsinteropd|OSXvnc|autosignd|launchdchroot|GlassDemo|Terminal|launchservicesd|Visual Studio Code|Code Helper|Google Chrome|Chrome Helper"; then
    break
  fi
  sleep 1
  final_waited=$((final_waited + 1))
done
echo
echo === final state ===
ps aux | grep -iE \
  "WindowServer|macwsallocd|macwsinputd|macwsdisplayd|macwsinteropd|OSXvnc|autosignd|launchdchroot|GlassDemo|Terminal|launchservicesd|Visual Studio Code|Code Helper|Google Chrome|Chrome Helper|MacWSHost" \
  | grep -v grep | head -10 || echo "(none)"
echo
uptime
