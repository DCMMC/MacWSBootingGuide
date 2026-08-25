# No shebang: invoke through /var/jb/usr/bin/bash.
set -e
LAUNCHCTL=/var/jb/usr/bin/launchctl
"$LAUNCHCTL" unload /var/jb/usr/macOS/LaunchDaemons 2>/dev/null || true
"$LAUNCHCTL" load /System/Library/LaunchDaemons/com.apple.SpringBoard.plist 2>/dev/null || true
"$LAUNCHCTL" load /System/Library/LaunchDaemons/com.apple.backboardd.plist 2>/dev/null || true
printf '%s\n' 'macOS остановлена. iOS GUI восстановлен.'
