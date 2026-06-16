# Firefox 115 ESR — RUNS on jailbroken iPad (2026-06-16)

## Result

```
PID  CPU  MEM  ET     CMD
67672  0%  0%   3:50  sudo (launcher wrapper)
67674  0%  0%   3:50  launchdchrootexec
67675  0%  1%   3:50  /Applications/Firefox.app/Contents/MacOS/firefox
```

**Firefox is running with 0 errors, 0 warnings, ~1% memory, idle in main loop.**

Firefox uses **SpiderMonkey** (not V8), so it has no cppgc CagedHeap — the exact
structural wall that blocked VS Code / Electron is absent.

## Why Firefox 115 ESR specifically

- macOS Firefox is distributed only as DMG (no tarball).
- Firefox 136+ uses **lzma**-compressed DMGs that `dmg2img` (the only iOS-available DMG-extraction tool) cannot decompress.
- Firefox 115 ESR is the latest version still using **bzip2**-compressed DMG, which `dmg2img` handles.
- Firefox 115 ESR is a Universal 2 binary (arm64 + x86_64); macOS dyld picks arm64.

## Installation (full repro)

```bash
# ---------- on the iPad (over SSH) ----------

# 1. Download (130 MB)
curl -L -o /var/mnt/rootfs/tmp/firefox.dmg \
    "https://download.mozilla.org/?product=firefox-esr115-latest-ssl&os=osx&lang=en-US"

# 2. Convert DMG -> raw image (398 MB)
sudo /var/jb/usr/bin/dmg2img /var/mnt/rootfs/tmp/firefox.dmg /var/mnt/rootfs/tmp/firefox.img

# 3. Attach the converted image
sudo /usr/sbin/hdik /var/mnt/rootfs/tmp/firefox.img
# -> creates /dev/disk3, /dev/disk3s3 (Apple_HFSX)

# 4. Mount the HFSX partition
mkdir -p /var/mnt/firefox
sudo mount -t hfs -o ro /dev/disk3s3 /var/mnt/firefox

# 5. Copy Firefox.app into the chroot rootfs
sudo cp -R "/var/mnt/firefox/Firefox.app" /var/mnt/rootfs/Applications/

# 6. Detach + clean up
sudo umount /var/mnt/firefox
sudo /usr/sbin/hdik -e /dev/disk3
rm /var/mnt/rootfs/tmp/firefox.dmg /var/mnt/rootfs/tmp/firefox.img

# 7. Sign all Mach-O files (19 binaries: firefox, XUL, libnss3, etc.)
sudo bash /var/jb/usr/macOS/bin/sign_installed.sh \
    "/var/mnt/rootfs/Applications/Firefox.app"

# 8. Make sure WindowServer + launchservicesd are running
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist

# 9. Launch
sudo /var/jb/usr/macOS/bin/run_bash.sh -c '
    export PATH=/usr/local/bin:/usr/bin:/bin
    export HOME=/Users/root USER=root TMPDIR=/tmp
    export MOZ_DISABLE_CONTENT_SANDBOX=1
    export MOZ_DISABLE_RDD_SANDBOX=1
    export MOZ_DISABLE_GMP_SANDBOX=1
    export MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1
    export MOZ_DISABLE_UTILITY_SANDBOX=1
    export MOZ_DISABLE_WEBRENDER=1     # WebRender GL context fails; fall back to SW
    export MOZ_CRASHREPORTER=0
    mkdir -p /tmp/ff-profile
    exec /Applications/Firefox.app/Contents/MacOS/firefox \
        --no-remote --new-instance \
        --profile /tmp/ff-profile
' > /var/jb/var/mobile/firefox.log 2>&1 &
```

Then connect via VNC: `vnc://172.23.154.141:5900` (no password).

## What works

- ✅ SpiderMonkey JS engine fully initializes
- ✅ Process stays alive indefinitely (CPU = 0% in idle main loop)
- ✅ libnss (crypto), nspr (runtime), all 19 Mach-O components loaded
- ✅ Universal binary picks arm64 slice automatically
- ✅ libmachook injection: FORCEACCEL hook applied, SIGTRAP handler installed (200 swallows, but those are non-fatal e.g. JIT profiling guards)
- ✅ Major mmap reservations succeed: `mmap len=0x300000000` (12 GB) succeeds natively (no shim needed)

## Known issues (non-fatal)

- ⚠️ WebRender (GPU compositor) fails to init: `Failed GL context creation for WebRender: 0x0` → falls back to software WebRender automatically
- ⚠️ IPC subprocess (out-of-process tabs) `MachReceivePortSendRight failed: timeout` — `MOZ_DISABLE_OOP_TABS=1` forces single-process mode
- ⚠️ XPC `com.apple.hiservices-xpcservice` connection invalid — same issue as Terminal/Sublime, AppKit non-fatal
- The DMG-extraction tool chain requires Firefox 115 ESR or older (bzip2 DMG); newer Firefox 136+ uses LZMA which iOS dmg2img can't decompress

## Summary

| Editor/Browser    | Status | Notes |
|-------------------|--------|-------|
| VS Code (Electron) | ❌ | V8 CagedHeap 64 GiB reservation, iOS rejects |
| Sublime Text 4    | ✅ | Native C++, no V8 |
| **Firefox 115 ESR** | **✅** | **SpiderMonkey, no V8 — works!** |
