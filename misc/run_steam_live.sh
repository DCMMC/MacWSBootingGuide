# Launch through Steam's outer bootstrapper.  The bootstrapper owns the
# /tmp/steam.pipe main-instance lifecycle; starting the installed client
# directly leaves steamglobalinstance without its IPC endpoint and stalls the
# updater window after verification.  The patched installed files are recorded
# in Valve's package inventory, so a normal verification preserves them.

export HOME=/Users/root
export USER=mobile
export LOGNAME=mobile
export TMPDIR=/tmp
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export MACWS_STEAM_LAUNCH_EPOCH="$$-$RANDOM-$RANDOM"

# Valve's native launcher uses fork after Network/XPC have initialized.
# Runtime crash steam_osx-2026-08-15-045104.ips proves its atfork child faults
# in xpc_dictionary_apply. The top Web Helper therefore uses libmachook's
# atomic posix_spawn adapter as well. Chromium's renderer/network descendants
# subsequently use their own ordinary posix_spawnp launcher. Exit-hook
# diagnostics perturb Crashpad's atfork path, so they remain opt-in and are not
# part of this production launcher.

# A launchd job has only one Steam root process. Remove file-backed semaphore
# objects and CEF shared-memory endpoints left by a previous crash before
# constructing the new private IPC graph; live processes retain no handles
# after the prior job has exited. The iOS-side root preflight handles objects
# which an older root-owned diagnostic run left inaccessible to uid 501.
find /tmp -maxdepth 1 \( -type f -o -type p -o -type s \) \
    \( -name '.macws-steam-sem-*' -o -name '.macws-sysvsem-*' \
       -o -name 'steam_chrome_shmem_uid501_spid*' \
       -o -name 'steam??????' \) -delete

MACWS_STEAM_ROOT="/Applications/Steam.app/Contents/MacOS"
cd "$MACWS_STEAM_ROOT" || exit 1
# Steam's supported CEF switches keep only the client shell on software
# compositing; games retain Metal/AGX.
exec ./steam_osx -no-cef-sandbox -cef-disable-gpu "$@"
