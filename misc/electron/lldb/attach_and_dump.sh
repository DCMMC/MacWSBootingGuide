#!/usr/bin/env bash
# attach_and_dump.sh — orchestrate iOS-side lldb attach to a chrooted Code process.
#
# Usage:
#   ./attach_and_dump.sh                                  # uses defaults
#   ./attach_and_dump.sh CMD_FILE LAUNCH_SCRIPT           # custom
#
# Defaults:
#   CMD_FILE       = ./dump_at_check.cmd  (uploaded to device)
#   LAUNCH_SCRIPT  = /tmp/launch_vscode.sh (already on device)
#
# Prereqs (on the device):
#   - /var/jb/usr/bin/lldb (iOS-side, Procursus lldb16)
#   - /var/mnt/rootfs/tmp/launch_vscode.sh  (chroot-path script that exec's Code)
#   - VSCode signed + trustcached (see resign_vscode.sh)
set -u
DEV="${DEV:-172.23.154.141}"
PW="${PW:-alpine}"
PORT="${PORT:-2222}"

CMD_FILE="${1:-$(dirname "$0")/dump_at_check.cmd}"
LAUNCH_SCRIPT="${2:-/tmp/launch_vscode.sh}"     # chroot path
DEV_CMD="/var/jb/var/mobile/lldb_dump.cmd"

[ -f "$CMD_FILE" ] || { echo "missing cmd file: $CMD_FILE" >&2; exit 1; }

ssh_common="-o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no"
SSH="sshpass -p $PW ssh -p $PORT $ssh_common root@$DEV"
SCP="sshpass -p $PW scp -P $PORT $ssh_common"

echo "[$(date +%H:%M:%S)] Uploading lldb cmd file..."
$SCP "$CMD_FILE" "root@$DEV:$DEV_CMD" >/dev/null

OUT="/tmp/lldb_dump.$$.log"
echo "[$(date +%H:%M:%S)] Starting lldb (--waitfor Code) in background..."
$SSH "echo $PW | sudo -S /var/jb/usr/bin/lldb --batch --source $DEV_CMD 2>&1" \
    > "$OUT" 2>&1 &
LLDB_PID=$!

sleep 3
echo "[$(date +%H:%M:%S)] Launching Code via $LAUNCH_SCRIPT ..."
$SSH "echo $PW | sudo -S bash /var/jb/usr/macOS/bin/run_bash.sh $LAUNCH_SCRIPT \
       > /var/jb/var/mobile/vscode.log 2>&1" &
LAUNCH_PID=$!

# Wait for lldb to finish (it auto-quits on `quit` in the cmd file, or timeout)
wait $LLDB_PID 2>/dev/null
RC=$?
kill $LAUNCH_PID 2>/dev/null

echo "[$(date +%H:%M:%S)] lldb exited (rc=$RC). Output -> $OUT"
echo "================================================================"
cat "$OUT"
