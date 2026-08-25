#!/bin/bash
# MacWSBootingGuide one-command host automation.
#
# On a Mac, this script can bootstrap Homebrew tools, RootHide Theos,
# the pinned iOS SDK, build/install the .deb, post-process libmachook and
# run postinst on the connected Dopamine device.
#
# Optional rootfs preparation downloads a macOS 13.4 IPSW with ipsw, mounts
# its filesystem and system cryptex, and transfers them to /var/mnt/rootfs.
# The project itself still owns the runtime patches and provisioning in
# layout/usr/macOS/bin/postinst.sh.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
THEOS="${THEOS:-$HOME/theos}"
WORKDIR="${MACWS_WORKDIR:-$HOME/.cache/macwsbootingguide}"
SDK_VERSION="${MACWS_IOS_SDK:-16.5}"
SDK_URL="https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS${SDK_VERSION}.sdk.tar.xz"
MACOS_VERSION="${MACWS_MACOS_VERSION:-13.4}"
MACOS_DEVICE="${MACWS_MACOS_DEVICE:-Mac14,7}"
DEVICE_IP="${MACWS_DEVICE_IP:-${DEVICE_IP:-172.20.10.3}}"
DEVICE_PORT="${MACWS_DEVICE_PORT:-${DEVICE_PORT:-2222}}"
DEVICE_USER="${MACWS_DEVICE_USER:-root}"
DEVICE_PASSWORD="${MACWS_DEVICE_PASSWORD:-alpine}"
ROOTFS="${MACWS_ROOTFS:-/var/mnt/rootfs}"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

ssh_target() {
  printf '%s@%s' "$DEVICE_USER" "$DEVICE_IP"
}

ssh_opts=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$DEVICE_PORT" )

essh() {
  if ! ssh "${ssh_opts[@]}" "$(ssh_target)" "$@"; then
    die "SSH command failed"
  fi
}

ensure_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Run this automation on macOS. It uses Xcode SDKs, hdiutil and the macOS toolchain."
}

ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    return
  fi
  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  else
    die "Homebrew installation finished but brew is not on PATH"
  fi
}

brew_install() {
  local formula
  for formula in "$@"; do
    brew list --formula "$formula" >/dev/null 2>&1 || brew install "$formula"
  done
}

bootstrap_host() {
  ensure_macos
  ensure_brew
  log "Installing host dependencies"
  brew_install make ldid xz dpkg blacktop/tap/ipsw sshpass
  need_cmd git
  need_cmd curl
  need_cmd python3
  need_cmd xcrun
  need_cmd gmake
  need_cmd ldid
  need_cmd ipsw
  need_cmd ssh
  need_cmd scp
  need_cmd sshpass

  mkdir -p "$WORKDIR/sdk" "$WORKDIR/macos"

  if [[ ! -d "$THEOS" ]]; then
    log "Cloning RootHide Theos into $THEOS"
    git clone --recursive https://github.com/roothide/theos.git "$THEOS"
  else
    log "Updating RootHide Theos"
    git -C "$THEOS" pull --ff-only || warn "Could not fast-forward Theos; keeping existing checkout"
    git -C "$THEOS" submodule update --init --recursive
  fi

  if [[ ! -d "$THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk" ]]; then
    log "Downloading iPhoneOS${SDK_VERSION}.sdk"
    curl --fail --retry 5 --retry-delay 2 -L "$SDK_URL" -o "$WORKDIR/sdk/iPhoneOS${SDK_VERSION}.sdk.tar.xz"
    tar -xJf "$WORKDIR/sdk/iPhoneOS${SDK_VERSION}.sdk.tar.xz" -C "$THEOS/sdks"
  fi
  [[ -d "$THEOS/sdks/iPhoneOS${SDK_VERSION}.sdk" ]] || die "iOS SDK extraction failed"

  local macsdk macver
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  macver="$(xcrun --sdk macosx --show-sdk-version)"
  mkdir -p "$THEOS/sdks"
  ln -sfn "$macsdk" "$THEOS/sdks/MacOSX${macver}.sdk"
  log "Host toolchain ready: Theos=$THEOS, iOS SDK=$SDK_VERSION, macOS SDK=$macver"
}

ensure_device_ssh() {
  log "Checking device SSH at $(ssh_target):$DEVICE_PORT"
  if ssh "${ssh_opts[@]}" "$(ssh_target)" true >/dev/null 2>&1; then
    return
  fi

  if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
    log "Generating an SSH key"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"
  fi

  log "Installing SSH key on the jailbroken device"
  sshpass -p "$DEVICE_PASSWORD" ssh "${ssh_opts[@]}" "$(ssh_target)" \
    "mkdir -p ~/.ssh; chmod 700 ~/.ssh; cat >> ~/.ssh/authorized_keys" \
    < "$HOME/.ssh/id_ed25519.pub"
  chmod 600 "$HOME/.ssh/id_ed25519"
  ssh "${ssh_opts[@]}" "$(ssh_target)" true >/dev/null 2>&1 || die "SSH key installation failed"
  unset DEVICE_PASSWORD
}

build_package() {
  bootstrap_host
  ensure_device_ssh
  log "Building RootHide package"
  export THEOS
  gmake -j"$(sysctl -n hw.logicalcpu)" clean
  gmake -j"$(sysctl -n hw.logicalcpu)" \
    FINALPACKAGE=1 \
    STRIP=0 \
    OPTFLAG=-O2 \
    GO_EASY_ON_ME=1 \
    THEOS_PACKAGE_SCHEME=roothide \
    TARGET="iphone:clang:${SDK_VERSION}:15.0" \
    package

  local pkg
  pkg="$(find "$REPO_DIR/packages" -maxdepth 1 -type f -name '*.deb' -print -quit)"
  [[ -n "$pkg" ]] || die "No .deb produced"
  log "Package produced: $pkg"
}

install_package() {
  build_package
  log "Installing package on device"
  gmake \
    FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 GO_EASY_ON_ME=1 \
    THEOS_PACKAGE_SCHEME=roothide \
    TARGET="iphone:clang:${SDK_VERSION}:15.0" \
    THEOS_DEVICE_IP="$DEVICE_IP" THEOS_DEVICE_PORT="$DEVICE_PORT" \
    package install

  log "Post-processing libmachook for macOS load-command compatibility"
  local tmp="$WORKDIR/libmachook.dylib"
  cp .theos/obj/libmachook.dylib "$tmp"
  python3 misc/set_macos_version.py "$tmp"
  ldid -S "$tmp"
  codesign -f -s - "$tmp"
  scp "${ssh_opts[@]}" "$tmp" "$(ssh_target):/var/jb/usr/macOS/lib/libmachook.dylib"
  rm -f "$tmp"

  log "Running postinst on the device"
  ssh "${ssh_opts[@]}" "$(ssh_target)" \
    "bash /var/jb/usr/macOS/bin/postinst.sh"
}

macos_ipsw() {
  mkdir -p "$WORKDIR/macos"
  local existing
  existing="$(find "$WORKDIR/macos" -maxdepth 1 -type f -name '*.ipsw' -print -quit)"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"
    return
  fi
  log "Downloading macOS ${MACOS_VERSION} IPSW for ${MACOS_DEVICE}" >&2
  ipsw download ipsw --confirm --macos --device "$MACOS_DEVICE" --version "$MACOS_VERSION" --output "$WORKDIR/macos" >&2
  existing="$(find "$WORKDIR/macos" -maxdepth 1 -type f -name '*.ipsw' -print -quit)"
  [[ -n "$existing" ]] || die "ipsw did not produce a macOS IPSW"
  printf '%s\n' "$existing"
}

wait_mount() {
  local path="$1"
  for _ in {1..60}; do
    [[ -d "$path" ]] && return 0
    sleep 1
  done
  die "Timed out waiting for mount: $path"
}

prepare_rootfs() {
  bootstrap_host
  ensure_device_ssh
  local ipsw_file="$WORKDIR/macos/root.ipsw"
  local fs_mount="$WORKDIR/macos/fs-mount"
  local sys_mount="$WORKDIR/macos/sys-mount"
  rm -rf "$fs_mount" "$sys_mount"
  mkdir -p "$fs_mount" "$sys_mount"

  local downloaded
  downloaded="$(macos_ipsw)"
  if [[ "$downloaded" != "$ipsw_file" ]]; then
    ln -sfn "$downloaded" "$ipsw_file"
  fi

  log "Mounting macOS filesystem DMG"
  ipsw mount fs "$ipsw_file" --lookup --mount-point "$fs_mount" --detach || true
  wait_mount "$fs_mount"

  log "Mounting macOS system cryptex"
  ipsw mount sys "$ipsw_file" --lookup --mount-point "$sys_mount" --detach || true
  wait_mount "$sys_mount"

  log "Creating $ROOTFS on the device"
  essh "mkdir -p '$ROOTFS' '$ROOTFS/System/Volumes/Preboot/Cryptexes/OS' '$ROOTFS/Users/root'"

  log "Streaming the full macOS filesystem to the device"
  tar -cpf - -C "$fs_mount" . | ssh "${ssh_opts[@]}" "$(ssh_target)" \
    "tar -xpf - -C '$ROOTFS'"

  if [[ -d "$fs_mount/System/Library/Templates/Data" ]]; then
    log "Merging System/Library/Templates/Data"
    tar -cpf - -C "$fs_mount/System/Library/Templates/Data" . | ssh "${ssh_opts[@]}" "$(ssh_target)" \
      "tar -xpf - -C '$ROOTFS'"
  fi

  log "Copying the OS cryptex into $ROOTFS/System/Volumes/Preboot/Cryptexes/OS"
  tar -cpf - -C "$sys_mount" . | ssh "${ssh_opts[@]}" "$(ssh_target)" \
    "tar -xpf - -C '$ROOTFS/System/Volumes/Preboot/Cryptexes/OS'"

  log "Creating the rootfs symlink topology"
  essh "rm -f '$ROOTFS/System/Volumes/Data' '$ROOTFS/home' '$ROOTFS/var/folders/zz'; \
        ln -s ../.. '$ROOTFS/System/Volumes/Data'; \
        ln -s System/Volumes/Data/home '$ROOTFS/home'; \
        ln -s /var/folders/zz '$ROOTFS/var/folders/zz'; \
        mkdir -p '$ROOTFS/Users/root' '$ROOTFS/var/jb'"

  log "Running the project's postinst provisioning"
  essh "bash /var/jb/usr/macOS/bin/postinst.sh"

  warn "The rootfs download/extraction step is intentionally pinned to macOS ${MACOS_VERSION}; the project documents macOS 13.4-specific offsets and hashes."
  log "Rootfs preparation finished"
}

launch_gui() {
  ensure_device_ssh
  log "Preparing macOS services and GUI launch"
  essh "bash /var/jb/usr/macOS/bin/postinst.sh"
  essh "launchctl unload /System/Library/LaunchDaemons/com.apple.SpringBoard.plist 2>/dev/null || true; \
         launchctl unload /System/Library/LaunchDaemons/com.apple.backboardd.plist 2>/dev/null || true; \
         launchctl load /var/jb/usr/macOS/LaunchDaemons"
  log "macOS launch daemons loaded. The MacWSHost app should now present the workspace."
}

launch_terminal() {
  ensure_device_ssh
  log "Opening a macOS chroot shell"
  ssh "${ssh_opts[@]}" -t "$(ssh_target)" "bash /var/jb/usr/macOS/bin/run_bash.sh"
}

stop_gui() {
  ensure_device_ssh
  log "Stopping macOS GUI and restoring iOS launchd jobs"
  essh "launchctl unload /var/jb/usr/macOS/LaunchDaemons 2>/dev/null || true; \
         launchctl load /System/Library/LaunchDaemons/com.apple.{SpringBoard,backboardd}.plist"
}

status() {
  ensure_device_ssh
  log "Checking device and MacWS runtime"
  essh "uname -a; echo; echo '--- rootfs ---'; test -d '$ROOTFS' && echo READY || echo MISSING; \
         echo '--- package ---'; test -x /var/jb/usr/macOS/bin/macwshostd && echo INSTALLED || echo MISSING; \
         echo '--- autosignd ---'; test -S '$ROOTFS/tmp/autosignd.sock' && echo READY || echo NOT_READY"
}

usage() {
  cat <<EOF
MacWSBootingGuide automation

Usage:
  ./macws-auto.sh bootstrap      Install host dependencies, Theos and SDK
  ./macws-auto.sh build          Build only
  ./macws-auto.sh install        Build + install + postinst
  ./macws-auto.sh rootfs         Download macOS 13.4 + provision /var/mnt/rootfs
  ./macws-auto.sh launch         Load macOS GUI daemons
  ./macws-auto.sh terminal       Open the macOS chroot shell
  ./macws-auto.sh stop           Stop macOS GUI and restore iOS services
  ./macws-auto.sh status         Check device/rootfs/runtime state
  ./macws-auto.sh all             bootstrap + rootfs + install + launch

Environment:
  MACWS_DEVICE_IP=172.20.10.3
  MACWS_DEVICE_PORT=2222
  MACWS_DEVICE_USER=root
  MACWS_DEVICE_PASSWORD=alpine
  MACWS_IOS_SDK=16.5
  MACWS_MACOS_VERSION=13.4
  MACWS_MACOS_DEVICE=Mac14,7
  MACWS_ROOTFS=/var/mnt/rootfs
  MACWS_WORKDIR=~/.cache/macwsbootingguide
EOF
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    bootstrap) bootstrap_host ;;
    build) build_package ;;
    install) install_package ;;
    rootfs) prepare_rootfs ;;
    launch) launch_gui ;;
    terminal) launch_terminal ;;
    stop) stop_gui ;;
    status) status ;;
    all)
      bootstrap_host
      prepare_rootfs
      install_package
      launch_gui
      ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

# Keep shell typo failures obvious during maintenance.
essh() { ssh "${ssh_opts[@]}" "$(ssh_target)" "$@"; }
essh "true" >/dev/null 2>&1 || true

main "$@"
