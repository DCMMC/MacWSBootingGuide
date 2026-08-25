# No shebang: invoke through /var/jb/usr/bin/bash.
set -Eeuo pipefail
BASH=/var/jb/usr/bin/bash
LAUNCHCTL=/var/jb/usr/bin/launchctl
POSTINST=/var/jb/usr/macOS/bin/postinst.sh
ROOTFS=/var/mnt/rootfs

[ -d "$ROOTFS/System/Library" ] || { echo 'macOS rootfs is missing. Press the full automatic setup button first.' >&2; exit 30; }

printf '%s\n' 'Проверяю и исправляю среду macOS…'
"$BASH" "$POSTINST"

printf '%s\n' 'Останавливаю iOS GUI-службы…'
"$LAUNCHCTL" unload /System/Library/LaunchDaemons/com.apple.SpringBoard.plist 2>/dev/null || true
"$LAUNCHCTL" unload /System/Library/LaunchDaemons/com.apple.backboardd.plist 2>/dev/null || true

printf '%s\n' 'Запускаю службы macOS…'
"$LAUNCHCTL" load /var/jb/usr/macOS/LaunchDaemons

printf '%s\n' 'macOS запущена. Вернитесь в MacWSHost для отображения рабочего стола.'
