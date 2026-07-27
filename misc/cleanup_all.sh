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
bash /var/jb/usr/macOS/bin/macos_gui.sh stop 2>&1 | head -5

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
sleep 3
for p in $(jobs -p); do kill -9 $p 2>/dev/null; done

echo === killing chroot processes ===
for pat in WindowServer launchservicesd OSXvnc-server Terminal GlassDemo \
           "Activity Monitor" launchdchrootexec MTLSimDriverHost macwsinputd \
           MacWSHost; do
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

echo === killing orphan build/debug scripts ===
for pat in 'sh /tmp/' oslog build_on_ios.sh find_crash.sh '/var/jb/usr/bin/lldb' \
           debugserver tmux; do
  pkill -9 -f "$pat" 2>/dev/null
done

sleep 2
echo
echo === final state ===
ps aux | grep -iE \
  "WindowServer|macwsallocd|macwsinputd|OSXvnc|autosignd|launchdchroot|GlassDemo|Terminal|launchservicesd|MacWSHost" \
  | grep -v grep | head -10 || echo "(none)"
echo
uptime
