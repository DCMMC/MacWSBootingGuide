# VS Code JSON language-server reservation failure

Status: root cause and isolated production-shape adapter are runtime-confirmed.
The running VS Code profile has not yet been restarted with the integrated
library; do not equate the protocol probe with final editor UI acceptance.

## Failure and preservation

The current profile was `/tmp/macws-vscode-profile-agx-native-production1`,
workspace folder `file:///Users/root`, main PID 37317, extension host 37367.
Its entire log directory was copied read-only to the local
`/tmp/macws-vscode-language-logs-20260920` before any GUI lifecycle change.
The active session `20260919T054241` identifies the actual failing extension:

```text
ExtensionService#_doActivateExtension vscode.json-language-features, startup: false, activationEvent: 'onLanguage:json'
# Oilpan: Out of memory (Oilpan: CagedHeap reservation.)
Server process exited with signal SIGABRT.
The JSON Language Server server crashed 5 times in the last 3 minutes. The server will not be restarted.
```

The copied crash `/tmp/macws-vscode-json-plugin-crash-20260920.ips` identifies
Code Helper (Plugin) 88452, parent extension host 37367, with the fault through
`cppgc::InitializeProcess` and `node::InitializeOncePerProcess`. Its 24.0-GiB
VM tag 253 total is reserved address space, not evidence of 24 GiB physical
RAM consumption. Disk signatures for both main and Plugin already contain
extended-virtual-addressing, increased-memory-limit, and allow-jit.

Other logs mention renderer Wasm allocation failure and Git discovery via
`xcode-select -p`. Those are separate observations; neither is claimed fixed
by the JSON result below.

## Actual producer contract

RE-confirmed against the installed arm64 Electron Framework, UUID
`4C4C4442-5555-3144-A1A8-564169F3FF00`:

- `+0x61d2354` constructs the default V8 PageAllocator, writing vtable
  `+0xac8b718`; AllocatePages slot `+0x30` is `+0x61d2398`.
- The 24-byte `+0x61d2398` thunk rearranges `(self,hint,size,alignment,permission)`
  into platform arguments and tail-calls `+0xc1cc74`; it has no accounting or
  ownership mutation omitted by the new exact-size first attempt.
- `+0xc1cc74` always reserves `(size + alignment - 1) & ~16383`, maps, aligns,
  and unmaps the prefix/suffix. Unlike the other Chromium allocator, it does
  not first try the actual size at an already aligned hint.
- The existing UUID-locked complete PA/Oilpan port retains compressed-pointer
  shift 3 and bit 34, and asks for a 4-GiB useful cage at aligned 56 GiB.
  Its constructor/fallback checks remain intact.

Original byte receipts are local
`/tmp/macws-electron-cagedheap-code-20260920.json` and
`/tmp/macws-electron-node-allocator-code-20260920.json` (bounded reads, not a
new IPSW extraction).

In `/tmp/macws-vscode-json-owned-node-va-trace-20260920.log`, a self-owned
Plugin using normal launch environment plus process-only diagnostics failed
in 0.466 seconds. The relevant real mmap calls were:

```text
hint=0xe00000000 size=0x3ffffc000 prot=0 flags=0x1042 ... result=0xa00000000 errno=0
hint=0xe00000000 size=0x2ffffc000 prot=0 flags=0x1042 ... result=0xa00000000 errno=0
```

The request succeeds as an mmap, but the excessive over-reservation causes
the hint to be ignored. The returned 40-GiB base fails the unchanged Oilpan
compressed-pointer bit/alignment requirement. Retrying the same allocation
four times does not repair that invariant.

## Narrow upstream repair and tests

`MacWSElectronPageAllocator.c` installs automatically only for the actual
Electron-as-Node process mode and recognized Electron/Code Helper names,
then checks the exact framework UUID, constructor/thunk instruction bytes,
ported cage instructions, loaded segment ranges, and relocated vtable slot.
It changes only the data slot, not executable text (early-fork RX inheritance
must remain intact). All other process modes/UUIDs are untouched.

For eligible `kNoAccess` requests with a nonzero aligned hint and validated
size/alignment, it makes a real exact-size, non-`MAP_FIXED` mmap with original
protection/flags/tag. Only a genuinely aligned result is returned. An
unaligned result is unmapped before the original allocator runs; actual
failure, unsupported requests, and permission modes retain the original
implementation. No capacity, compressed-pointer ABI, validation, or error is
replaced with success. Production has no enable flag and no success logging.

The diagnostic-only standalone candidate produced:

```text
exact hint=0xe00000000 size=0x200000000 result=0xa00000000 errno=0
exact hint=0xe00000000 size=0x100000000 result=0xe00000000 errno=0
OWNED_NODE_OK pid=11371 node=v24.18.0
OWNED_END rc=0 elapsed=0.656
```

The first 8-GiB attempt is still rejected by the original constructor when
its address is unsuitable; the existing 4-GiB fallback now obtains the real
correctly aligned mapping. Log:
`/tmp/macws-vscode-json-owned-node-candidate-20260920.log`.

`misc/test_electron_page_allocator.py` compiles and executes the actual pure-C
helper and extracted production wrapper: real-size/alignment, exact and
alternate-aligned success, MAP_FAILED, unaligned/null cleanup, unmap failure,
all fallback arguments, errno, permission and overflow guards. Both tests
pass. Standalone arm64 macOS and arm64e iOS16.5-SDK compile with
`-Wall -Wextra -Werror`; the arm64-only framework adapter is inactive in the
arm64e build.

## Real language-server acceptance (isolated, no user documents)

A self-owned Plugin runs the installed built-in
`json-language-features/server/dist/node/jsonServerMain.js --stdio`. The
client sends `initialize`, `initialized`, and `didOpen` for an in-memory
invalid JSON fixture, then `shutdown`/`exit`. The fixture URI is not written
to disk and no user document is opened. Only the owned process group may be
cleaned up after its eight-second deadline.

The final standalone library was built without the diagnostic macro or any
diagnostic environment variables. Log
`/tmp/macws-json-lsp-owned-production-20260920.log` confirms:

```text
initialize -> capabilities (hoverProvider, documentSymbolProvider, etc.)
textDocument/publishDiagnostics -> "Value expected", severity=1, code=516
shutdown -> result:null
LSP_RESULT initialized=1 invalid-json-diagnosed=1 shutdown=1 exit=0
```

This validates the actual bundled server and JSON protocol rather than mere
process uptime. Canonical library deployment and fresh normal editor-profile
acceptance remain separate required steps.
