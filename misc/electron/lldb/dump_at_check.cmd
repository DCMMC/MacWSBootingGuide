# ============================================================================
# dump_at_check.cmd — Phase 1: attach, continue to brk, dump generous state.
# Procursus iOS lldb 16 has NO Python — every command must be pure lldb.
# ============================================================================

process handle SIGTRAP --stop true --pass false --notify true
process attach --waitfor --name "Code"
continue

# === at brk #0 ===
register read
thread backtrace --count 15
image list -o -f Electron\ Framework
# Generous stack dump for offline analysis
memory read --format x --size 8 --count 64 `$sp`
memory read --format x --size 8 --count 32 `$fp`
# Disassemble preceding instructions (the actual abort emission site)
disassemble --start-address `$pc - 0x40` --end-address `$pc + 0x10`
quit
