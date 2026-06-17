# misc/lldb_trace_runner.sh — non-interactive variant of lldb_remote.sh.
#
# Same iOS debugserver + SSH tunnel setup as lldb_remote.sh, but instead of
# leaving you in an interactive (lldb) prompt, runs `--batch` with a chain
# of -o commands sourced from a trace script. Captures output to a file so
# Claude can read it back.
#
# Usage:
#   bash misc/lldb_trace_runner.sh <host> [port] [process-name] <commands-file>
#
# commands-file format: one lldb command per non-blank, non-comment line.
# For multi-line commands (python callbacks), join with literal "\n" — the
# runner converts to real newlines before sending.
#
# Output ends up in /tmp/lldb_trace_run.log; the tail is printed to stdout.

set -u

HOST=${1:-}
PORT=${2:-2222}
PROC_NAME=${3:-WindowServer}
CMDS_FILE=${4:-}
DBG_PORT=${DBG_PORT:-5555}
RUN_LOG=${RUN_LOG:-/tmp/lldb_trace_run.log}

if [ -z "$HOST" ] || [ -z "$CMDS_FILE" ]; then
    echo "usage: bash $0 <host> [ssh-port] [process-name] <commands-file>" >&2
    exit 1
fi
if [ ! -f "$CMDS_FILE" ]; then
    echo "error: commands file $CMDS_FILE not found" >&2
    exit 1
fi

PID=$(ssh -p "$PORT" root@"$HOST" \
    "ps aux | grep -E '$PROC_NAME' | grep -v grep | head -1 | awk '{print \$2}'")
if [ -z "$PID" ]; then
    echo "error: no process matching '$PROC_NAME'" >&2
    exit 1
fi
echo "[trace] $PROC_NAME PID=$PID" >&2

cleanup() {
    pkill -f "ssh.*-L $DBG_PORT:127.0.0.1" 2>/dev/null || true
    ssh -p "$PORT" root@"$HOST" \
        'echo alpine | sudo -S bash -c '\''for p in $(ps aux | grep debugserver | grep -v grep | awk "{print \$2}"); do kill -9 $p 2>/dev/null; done'\''' \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

cleanup
sleep 1

ssh -p "$PORT" root@"$HOST" \
    "echo alpine | sudo -S /var/jb/usr/bin/debugserver 127.0.0.1:$DBG_PORT --attach=$PID" \
    >/tmp/debugserver_remote.log 2>&1 &
sleep 3

STATE=$(ssh -p "$PORT" root@"$HOST" \
    "ps -o state= -p $PID 2>/dev/null | tr -d ' ' || echo MISS")
if [ "${STATE:0:1}" != "T" ]; then
    echo "[trace] WARNING: target state '$STATE' (expected T) — debugserver attach failed?" >&2
fi

ssh -fN -p "$PORT" -L "$DBG_PORT:127.0.0.1:$DBG_PORT" root@"$HOST"
sleep 1

# lldb runs the commands file via --source — that respects multi-line
# `script ... DONE` blocks, lldb python heredocs, etc. (which `-o` would
# split across separate one-line invocations).
LLDB_ARGS=(
    --batch
    -O "process connect --plugin gdb-remote connect://127.0.0.1:$DBG_PORT"
    --source "$CMDS_FILE"
    -o "process detach"
    -o "quit"
)

echo "[trace] running lldb in batch (output -> $RUN_LOG)" >&2
/usr/bin/lldb "${LLDB_ARGS[@]}" >"$RUN_LOG" 2>&1 || true

echo
echo "===== LLDB SESSION OUTPUT ====="
tail -500 "$RUN_LOG"
