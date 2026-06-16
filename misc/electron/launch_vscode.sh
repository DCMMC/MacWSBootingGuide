# Launch VSCode in the macOS chroot with sandbox + GPU disabled.
# Run from iOS shell:
#   echo 'alpine' | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/launch_vscode.sh
export PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/Users/root
export USER=root
export TMPDIR=/tmp
export SHELL=/bin/bash
# Proxy + SSL — VSCode does HTTPS to fetch update metadata, extension marketplace
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export HTTP_PROXY=socks5h://127.0.0.1:1082
export SSL_CERT_FILE=/etc/ssl/cert.pem
# DYLD_INSERT_LIBRARIES is set by launchdchrootexec for the parent; for explicit
# bash invocation we re-inject to be safe.
export DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook.dylib
# Electron / Chromium telemetry off
export ELECTRON_NO_ATTACH_CONSOLE=1
export ELECTRON_ENABLE_LOGGING=1

mkdir -p /tmp/vscode-user /tmp/vscode-cache 2>/dev/null

CODE="/Applications/Visual Studio Code.app/Contents/MacOS/Code"
echo "==== launching VSCode ===="
echo "binary: $CODE"
ls -l "$CODE" 2>&1
echo

# First attempt: --no-sandbox + GPU disabled + software rendering, single window.
# --user-data-dir to avoid touching ~/Library which may not exist / be writable.
# 2>&1 to merge stderr -- chromium prints all of its diagnostic logging to stderr.
exec "$CODE" \
    --no-sandbox \
    --disable-gpu \
    --disable-gpu-compositing \
    --disable-software-rasterizer \
    --use-gl=swiftshader \
    --user-data-dir=/tmp/vscode-user \
    --disable-features=CalculateNativeWinOcclusion,UseChromeOSDirectVideoDecoder \
    --enable-logging=stderr \
    --v=1 \
    /tmp 2>&1
