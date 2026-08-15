# Launch through Steam's outer bootstrapper unless its installed client and
# pending package are already the same exact version. Both current arm64
# steam_osx images contain the STEAM_APP_BUNDLE_PATH -> steam.pipe owner path;
# the historical direct launch failed because it omitted that contract, not
# because the installed client is structurally unable to own the endpoint.

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
# RE-confirmed in this exact steam_osx arm64 slice (SHA-256
# ee0422cd4dccf99f186396c7769c53e20bf012698369ee990b1e47b9d2efad93):
# steam_osx+0x17778 reads STEAM_APP_BUNDLE_PATH. When the launch is the active
# instance, +0x177b8/+0x177c8 recreate /tmp/steam.pipe with unlink+mkfifo;
# without the bundle path it skipped that owner setup and the later writer
# opened a nonexistent FIFO. Preserve Steam's own bootstrap contract.
export STEAM_APP_BUNDLE_PATH=/Applications/Steam.app
# Keep Steam's CEF shell on the same native Metal/AGX path as the rest of the
# desktop.  Runtime Jetsam evidence from 2026-08-15 identified CEF's
# gpu-process as the largest process at 600,180 16-KiB resident pages while
# the old -cef-disable-gpu policy was active.  That policy did not remove the
# GPU helper: Valve also passed --enable-zero-copy and
# --enable-gpu-memory-buffer-compositor-resources to its renderer. The
# minidump/EXC_GUARD evidence establishes the native-GPU child death and
# SwiftShader fallback cycle; whether one particular software-surface owner
# accounts for all 9.16 GiB remains unproven and is not assumed here.
# -cef-force-gpu is Valve's supported inverse switch; the launch job supplies
# the validated native-AGX environment below.  CEF's own sandbox stays off
# because this foreign macOS task cannot construct the macOS sandbox profile.
#
# Runtime-confirmed on 2026-08-15: Jetsam left the old CEF family in kernel
# state UE, where even SIGKILL cannot reap it. The bootstrapper consequently
# could download and verify a package but could not acquire its clean-client
# install boundary; blind 254 restarts only repeated verification. Do not
# create that hot loop. When Valve's installed and newly downloaded manifests
# already report the exact same version, use Valve's own
# -skipinitialbootstrap switch to enter that verified installed client while
# retaining this outer bootstrapper's FIFO/instance setup. A genuinely newer
# pending version still takes the ordinary updater path.
steam_installed_manifest="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/package/steam_client_osx.manifest"
steam_pending_manifest="$HOME/Library/Application Support/Steam/package/steam_client_signed_osx"
manifest_version() {
    awk '/"version"/ { gsub(/"/, "", $2); print $2; exit }' "$1" \
        2>/dev/null
}
steam_installed_version=$(manifest_version "$steam_installed_manifest")
steam_pending_version=$(manifest_version "$steam_pending_manifest")
if [ -n "$steam_installed_version" ] &&
   [ "$steam_installed_version" = "$steam_pending_version" ]; then
    steam_installed_bundle="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam"
    steam_installed_root="$steam_installed_bundle/Contents/MacOS"
    if [ -x "$steam_installed_root/steam_osx" ]; then
        echo "Steam installed/pending manifests match version $steam_installed_version; launching verified installed client"
        export STEAM_APP_BUNDLE_PATH="$steam_installed_bundle"
        cd "$steam_installed_root" || exit 1
        exec ./steam_osx -no-cef-sandbox -cef-disable-gpu-sandbox \
            -cef-force-gpu "$@"
    fi
fi

exec ./steam_osx -no-cef-sandbox -cef-disable-gpu-sandbox \
    -cef-force-gpu "$@"
