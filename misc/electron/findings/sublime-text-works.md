# Sublime Text 4 — RUNS on jailbroken iPad (2026-06-16)

After determining VS Code / Electron is blocked by V8 CagedHeap's 64 GiB VA
reservation (which iOS rejects), we tried **Sublime Text 4** — a native C++
editor with no V8/Electron dependency.

## Result

```
ps -ax | grep sublime_text
  PID=63170  ET=02:19  /Applications/Sublime Text.app/Contents/MacOS/sublime_text   ← RUNNING STABLY
```

Process is alive for 2+ minutes, CPU = 0% (idle in event loop), MEM = 2.9%.
No crash report. MTLSimDriver loaded successfully ("MTLCreateSimulatorDevice
successfully" in the log). XPC connection errors are non-fatal (already-known
issue for AppKit apps in this chroot).

## Why this works where Electron doesn't

| Dependency        | Sublime Text 4 | VS Code/Electron |
|-------------------|----------------|-------------------|
| V8 JavaScript     | ❌ no          | ✅ required       |
| cppgc CagedHeap   | ❌ no          | ✅ 64 GiB VA reservation |
| Multi-process IPC | Single process | XPC + posix_spawn helpers |
| GUI               | AppKit native  | AppKit + Chromium compositor |
| GPU               | Metal (works via MTLSim bridge) | Metal (works) |
| Code size         | 40 MB DMG      | ~250 MB |

The 64 GiB VA reservation is the structural wall for Electron. Sublime has
no such requirement.

## Install instructions

```bash
# From iOS shell:
curl -L -o /var/mnt/rootfs/tmp/sublime.zip \
    "https://download.sublimetext.com/sublime_text_build_4200_mac.zip"
cd /var/mnt/rootfs/Applications
unzip -q /var/mnt/rootfs/tmp/sublime.zip
sudo bash /var/jb/usr/macOS/bin/sign_installed.sh \
    "/var/mnt/rootfs/Applications/Sublime Text.app"
rm /var/mnt/rootfs/tmp/sublime.zip

# Make sure WindowServer + launchservicesd are loaded:
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh start coexist

# Launch:
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c '
    export PATH=/usr/local/bin:/usr/bin:/bin
    export HOME=/Users/root
    exec "/Applications/Sublime Text.app/Contents/MacOS/sublime_text"
' &
```

Connect via VNC: `vnc://172.23.154.141:5900` (no password).

## Notes

- Sublime Text 4 build 4200 is a Universal 2 binary (arm64 + x86_64); macOS dyld
  picks the arm64 slice automatically.
- Plugin host (`plugin_host-3.3`, `plugin_host-3.8`) uses bundled CPython, no
  external Python dependency.
- License: Sublime Text is commercial software; ships in unregistered mode by
  default with a nag dialog and limited functionality.
