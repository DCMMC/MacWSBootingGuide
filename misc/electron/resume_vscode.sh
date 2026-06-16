#!/usr/bin/env bash
# Run on macOS host after iPad has been power-cycled.
# Detects current state of libmachook + VSCode trustcache + chroot health,
# rebuilds/re-deploys if needed, then launches VSCode.
set -u
SSH="sshpass -p alpine ssh -p 2222 -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no root@172.23.154.141"
SCP="sshpass -p alpine scp -P 2222 -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no"

step() { printf "\n==> %s\n" "$*"; }

step "1. Probe device"
$SSH 'echo ALIVE; uptime; date' || { echo "device unreachable"; exit 1; }

step "2. Check libmachook version (should have SHIM string)"
HAS_SHIM=$($SSH 'strings /var/jb/usr/macOS/lib/libmachook.dylib 2>/dev/null | grep -c "mmap SHIM"' || true)
echo "  SHIM string count: $HAS_SHIM"

if [ "$HAS_SHIM" = "0" ]; then
    step "  -> libmachook is OLD. Pushing source + rebuilding."
    $SCP /Users/dcmmcc/Downloads/Projects/MacWSBootingGuide/libmachook/mac_hooks.m \
        "root@172.23.154.141:/var/jb/var/mobile/MacWSBootingGuide/libmachook/mac_hooks.m"
    $SSH 'THEOS=/var/jb/var/mobile/theos bash /var/jb/var/mobile/MacWSBootingGuide/misc/build_on_ios.sh' || {
        echo "build failed — bailing"; exit 1; }
fi

step "3. Verify postinst has run (basic chroot health: 'ls' works)"
if $SSH 'echo alpine | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh -c "/bin/ls /tmp >/dev/null 2>&1 && echo CHROOT-OK" 2>&1' | grep -q CHROOT-OK; then
    echo "  chroot OK"
else
    echo "  chroot broken — running postinst"
    $SSH 'echo alpine | sudo -S bash /var/jb/usr/macOS/bin/postinst.sh'
fi

step "4. Verify VSCode trustcache (resign + re-trustcache if needed)"
$SSH 'echo alpine | sudo -S bash /var/jb/var/mobile/resign_vscode.sh 2>&1' | tail -3

step "5. Restore Electron Framework to .orig (no binary patches — relying on mmap shim)"
$SSH 'echo alpine | sudo -S bash /var/jb/var/mobile/patch_brk.sh --restore' || echo "  (no .orig to restore — that's fine)"
$SSH 'echo alpine | sudo -S /var/jb/usr/bin/ldid -S/var/jb/usr/macOS/bin/vscode_entitlements.plist -M "/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"; h=$(/var/jb/usr/bin/ldid -arch arm64 -h "/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework" | grep CDHash= | cut -c8- | tr A-F a-f); echo alpine | sudo -S /var/jb/usr/bin/jbctl trustcache add $h; echo "cdhash: $h"'

step "6. Launch VSCode + monitor"
$SSH 'echo alpine | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/launch_vscode.sh > /var/jb/var/mobile/vscode.log 2>&1 &'
sleep 3

for i in 5 15 30 60 90; do
    sleep $i
    procs=$($SSH 'ps -ax 2>/dev/null | grep -E "Visual Studio Code|Code Helper" | grep -v grep | wc -l')
    echo "  t=+$((i+3))s: $procs Code-like processes alive"
done

step "7. Final state"
$SSH 'ps -ax 2>/dev/null | grep -E "Visual Studio Code|Code Helper|WindowServer" | grep -v grep'
echo
$SSH 'tail -40 /var/jb/var/mobile/vscode.log'
