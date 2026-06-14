# Diagnostic tools

Small C programs used during the AGX-direct path investigation to empirically test specific claims about Dopamine primitives, kernel object layout, and PT page accessibility.

All targets: iOS 16.3.1 / iPad13,6 (M1) / Dopamine. arm64e.

## Build template

```bash
xcrun -sdk iphoneos clang -arch arm64e \
  -Wl,-platform_version,ios,16.3,16.3 \
  TOOL.c -framework IOKit -o TOOL
ldid -S/path/to/entitlements.plist TOOL                         # sign
CDH=$(ldid -h TOOL 2>/dev/null | grep '^CDHash=' | cut -c8-)    # capture
# upload to device
ssh root@device 'cat > /tmp/TOOL && chmod 755 /tmp/TOOL' < TOOL
ssh root@device "sudo /var/jb/usr/bin/jbctl trustcache add $CDH"
ssh root@device 'sudo /tmp/TOOL'
```

## File-by-file

### `kcall_test.c`
Verifies whether libjailbreak's `kcall` is functional. Calls `is_kcall_available()` and then attempts `jbclient_get_fugu14_kcall()` to force-init.

**Result on this device:** `is_kcall_available()=0`, `jbclient_get_fugu14_kcall()=-1`. PAC bypass is not provisioned (Dopamine deliberately skips it on iOS 15.2+).

### `text_write_test.c` / `test3.c`
Tries to write to a kernel `__TEXT` page (`AGXSecureGart::deallocate`'s first instruction). Step-by-step: kread → kvtophys → physread (verify) → kwrite **identity** (no value change) → physwrite identity. Then a real `GO` mode that NOPs and restores.

**Result on this device:** `kread32` and `physread32` succeed. **`kwrite32` HANGS** indefinitely on the identity write — never returns. No kernel panic; device stays up. KTRR blocks `__TEXT` writes at the hardware memory-controller level; Dopamine's PPL bypass doesn't bypass KTRR.

### `survey.c` / `survey3.c` / `survey4.c`
Scans kernel object pointers (rooted at AGX object chain) looking for pages that contain valid AGX page-table entries (`(e & 0x3) == 0x3` for L1/L2 table descriptors; `(e & 0x0080000000000403) == 0x0080000000000403` for L3 leaf PTEs). Both heuristics derived from BN decompile of `AGXUnifiedAddressTranslator::encodePDEFlags / encodePCEFlags / encodePTEFlags`.

**Result:** 6654 candidate pages scanned across 3 levels of indirection from Gart pointers. Zero real PT pages found. PT pages are in ASC firmware memory, not in CPU-reachable DRAM via these objects.

### `krwtest.c`
Earlier exploration tool. Bootstraps libjailbreak KRW, locates AGXAccelerator via IOServiceMatching, dumps the per-DUC chain (`DUC+0x120 → AGXShared → +0x58 → Gart → +0x288 → LocalMux → +0x10 → per-task IOUAT handle`). The breakthrough that established navigation; first to notice the in-memory C++ vtable pointer = `__ZTV<class>_symbol + 0x10` (which had previously hidden every vtable match).

### `patcher.c`
The reckless one. Iterates ALL 22 AGXDeviceUserClient instances, computes each's "TTB" PA (which we now know is wrong — it's a kalloc buffer, not a PT page), and writes `L1[1]=L1[0]` to all of them. **Caused a kernel panic and a force-reboot** when run.

The lesson is the file's whole purpose: **don't kwrite/physwrite to a PA without first validating the target page looks like the data type you expect it to be**. A "PT page" must have valid PTE bit patterns (see `survey4.c` heuristics). The value `0x800000f122000000` that I treated as "L1[0]" had neither the table-descriptor `0x3` low bits nor a PA in DRAM.

Kept here as a cautionary example only — re-running this on a similar object chain on a different iOS build is likely to panic that device too.

## What's NOT here

- The `agxprobe_mid.m` / `agxprobe_krw.m` variants used in the kcall experiment — those are derivations of `misc/agxprobe.m` in the project root and don't need separate archival
- Full `libjailbreak_macos.dylib` extraction script — that experiment was a dead end (chroot dyld rejects the iOS dylib even after platform-tag patch because of missing iOS framework deps)

See the parent [README.md](../README.md) for the full investigation summary.
