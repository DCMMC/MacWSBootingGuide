# op-3 record OOL-offset dump spec — for next-session implementation

## Goal

Answer the question: **with REC-SIZE FIX enabled, what bytes are at the OOL-flag
locations the iOS kernel body sub-fn reads** (`[x24+0x1a8]`, `[x24+0x6a8]`,
`[x24+0x19c]`, `[x24+0x1ae]`)? If they happen to land on zero bytes / sane
size values, REC-SIZE FIX works by luck. If they ever land on garbage, this
spec gives the bytes to fix.

## Background (from agx-kernel-validator-fully-decoded.md)

- iOS kernel `AGXCommandQueue::processSegmentKernelCommand @ 0xfffffe00086e2274`
  validates op-3 records: `record[+0x2c]=size=0x1a8`, `[+0x30]=type=0x30`,
  `[+0x34]=subtype=3`.
- The body sub-fn (`0x086e434c`) then does:
  - `x20 = record body (= record + 8)`
  - `x21 = record_size from stack-mirror = 0x1a8`
  - `x24 = x21 + x20 = record body + 0x1a8`
  - Reads `[x24, #0x1a8]`, `[x24, #0x6a8]`, `[x24, #0x19c]`, `[x24, #0x1ae]`
- macOS-AGXMetal13_3 reserves **0x1f0 bytes** per record (via
  `AGX::ContextCommon::newCommand(0x1f0)`); body is 0x1b8 in the
  `arg1+0x10800`-source buffer; REC-SIZE FIX truncates the copy to 0x1a8.

So `x24 = record_body + 0x1a8` lands in **the 0x10 bytes immediately past
the body copy**, then `[x24, #0x6a8]` lands far past the single record's
0x1e0 reservation — **inside subsequent records / segment trail**.

## Implementation in libmachook (extend existing SUBMIT-DUMP)

Existing `macws_scan_records()` already finds type=0x30 records.  Extend it
to print the OOL field values:

```c
// Inside macws_scan_records loop, when finding a type=0x30 record at offset k:
const uint8_t *body = (const uint8_t *)(p + k + (8 / 4));     // record + 8 = body start
// validator-checked header (record[+0x2c..+0x38])
const uint32_t *hdr = p + k + (0x28 / 4);                    // 16-byte header
uint32_t next_off = hdr[0], rec_size = hdr[1], type = hdr[2], subtype = hdr[3];
fprintf(stderr, "    rec@%zu hdr={next=%#x size=%#x type=%#x subtype=%u}\n",
    k*4, next_off, rec_size, type, subtype);

// OOL fields the body sub-fn reads via x24 = body + 0x1a8
// These addresses must be inside the dumped segment range or skip.
size_t x24 = (k * 4) + 8 + 0x1a8;     // x24 from segment start
struct { size_t off; const char *name; int width; } ool[] = {
    { x24 + 0x1a8, "flag-A", 1 },
    { x24 + 0x6a8, "flag-B", 1 },
    { x24 + 0x19c, "size-w14", 4 },
    { x24 + 0x1ae, "flag-C", 1 },
};
for (size_t i = 0; i < 4; i++) {
    if (ool[i].off + 4 > n_u32 * 4) {
        fprintf(stderr, "    ool[%s] @ +%#zx — OUT OF SEGMENT\n",
            ool[i].name, ool[i].off);
        continue;
    }
    uint32_t v;
    memcpy(&v, ((const uint8_t *)p) + ool[i].off, 4);
    fprintf(stderr, "    ool[%s] @ +%#zx = %#x\n", ool[i].name, ool[i].off, v);
}
```

## How to trigger

1. Add the extension above to `macws_scan_records()` in `libmachook/mac_hooks.m`
   (gated by the existing `/tmp/macws_submit_dump` flag).
2. Build via `build_on_ios.sh` (full build — added code, FAST mode insufficient).
3. On device:
   ```bash
   R=/var/mnt/rootfs/tmp
   rm -f $R/macws_vnc_* $R/ws_headless        # avoid the WS-crashing vnc flags
   touch $R/macws_recfix $R/macws_submit_dump
   sudo bash /var/jb/usr/macOS/bin/macos_gui.sh restart exclusive --no-terminal
   sleep 6
   grep 'SUBMIT-DUMP.*ool\[' /var/jb/var/mobile/WindowServer.err | head -40
   ```
4. The output `ool[flag-A] @ +#X = #Y` lines tell us EXACTLY whether those
   bytes are zero, a flag, or garbage.

## Decision tree from output

| ool[flag-A] | ool[flag-B] | ool[size-w14] | Result |
|---|---|---|---|
| 0x00 | (not checked) | (not checked) | REC-SIZE FIX safe; OOL path = "no trail" |
| 0x00 with flag-B=0 | 0x00 | (any) | err 0x0c (validator rejects) |
| nonzero | (any) | > 1<<queue[+0xc] (= probably 0x800) | err 0x100 (size too large) |
| nonzero | (any) | ≤ max | falls into OOL processing — needs valid resource refs |

## Companion: alternate fix — zero out the SKIPPED 16 bytes

Right after the body memcpy (b1 site at `0x1e55fb308`), emit a memset that
zeros out `arg1[0x109a8..0x109b8]` (the 16 bytes REC-SIZE FIX no longer
copies). Logic: if those 16 bytes are reliably zero in macOS's pre-built
buffer (because BlitDispatchContext::beginComputePass zero-inits some range
of it via the existing memset @+0xa8/+0xb1), REC-SIZE FIX is structural.
Otherwise this memset closes the gap.

## Token budget

This whole spec is ~250 LOC of C in libmachook + one rebuild. Should fit a
short next session. The dump output answers the open question.
