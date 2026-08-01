set -eu

FLAG=/var/mobile/Library/Preferences/com.macwsguide.dense-grid.disabled
LOADED=/var/mobile/Library/Preferences/com.macwsguide.dense-grid.loaded

case "${1:-status}" in
    enable)
        rm -f "$FLAG"
        echo "MacWS dense Stage Manager grid: enabled for the next SpringBoard start"
        ;;
    disable)
        : > "$FLAG"
        chmod 0644 "$FLAG"
        echo "MacWS dense Stage Manager grid: disabled for the next SpringBoard start"
        ;;
    status)
        if [ -e "$FLAG" ]; then
            echo "MacWS dense Stage Manager grid: disabled"
        else
            echo "MacWS dense Stage Manager grid: enabled"
        fi
        if [ -f "$LOADED" ]; then
            echo "SpringBoard hook: $(head -n 1 "$LOADED")"
            for witness in /var/mobile/Library/Preferences/com.macwsguide.dense-grid.width \
                           /var/mobile/Library/Preferences/com.macwsguide.dense-grid.height \
                           /var/mobile/Library/Preferences/com.macwsguide.dense-grid.width-getter \
                           /var/mobile/Library/Preferences/com.macwsguide.dense-grid.height-getter; do
                [ ! -f "$witness" ] || head -n 1 "$witness"
            done
        else
            echo "SpringBoard hook: not loaded in the current SpringBoard"
        fi
        ;;
    *)
        echo "usage: $0 {enable|disable|status}" >&2
        exit 64
        ;;
esac

echo "No respring was performed. The policy changes only on a later user-initiated SpringBoard restart."
