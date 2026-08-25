# No shebang: invoke through /var/jb/usr/bin/bash.
set -Eeuo pipefail

ROOTFS=/var/mnt/rootfs
WORK=/var/jb/var/macws-bootstrap
IPSW=$WORK/UniversalMac_13.4_22F66_Restore.ipsw
FS_DMG=$WORK/filesystem.dmg
SYS_DMG=$WORK/system.dmg

IPS W=/var/jb/usr/macOS/bin/ipsw
APFS=/var/jb/usr/macOS/bin/apfs
BASH=/var/jb/usr/bin/bash
LAUNCHCTL=/var/jb/usr/bin/launchctl

mkdir -p "$WORK" "$ROOTFS" "$ROOTFS/System/Volumes/Preboot/Cryptexes/OS" "$ROOTFS/Users/root"

log() { printf '[macws-setup] %s\n' "$*"; }

command -v "$IPS W" >/dev/null 2>&1 || true
[ -x "$IPS W" ] || { echo 'ipsw tool missing from package' >&2; exit 20; }
[ -x "$APFS" ] || { echo 'APFS extractor missing from package' >&2; exit 21; }

if [ ! -f "$IPSW" ] || [ "$(wc -c < "$IPSW")" -lt 1000000000 ]; then
    log 'Скачиваю официальный macOS 13.4 IPSW для Mac14,7 (22F66)…'
    rm -f "$IPSW"
    "$IPS W" download ipsw --confirm --macos --device Mac14,7 --version 13.4 --output "$WORK"
    found=$(find "$WORK" -maxdepth 1 -type f -name '*.ipsw' -print -quit)
    [ -n "$found" ] || { echo 'IPSW download did not produce a file' >&2; exit 22; }
    [ "$found" = "$IPSW" ] || mv -f "$found" "$IPSW"
fi

if [ ! -f "$FS_DMG" ]; then
    log 'Извлекаю файловую систему macOS из IPSW…'
    rm -rf "$WORK/fs-extract"
    mkdir -p "$WORK/fs-extract"
    "$IPS W" extract --dmg fs "$IPSW" --output "$WORK/fs-extract"
    candidate=$(find "$WORK/fs-extract" -type f -name '*.dmg' -print -quit)
    [ -n "$candidate" ] || { echo 'filesystem DMG was not extracted' >&2; exit 23; }
    cp -f "$candidate" "$FS_DMG"
fi

if [ ! -f "$SYS_DMG" ]; then
    log 'Извлекаю системный cryptex macOS из IPSW…'
    rm -rf "$WORK/sys-extract"
    mkdir -p "$WORK/sys-extract"
    "$IPS W" extract --dmg sys "$IPSW" --output "$WORK/sys-extract"
    candidate=$(find "$WORK/sys-extract" -type f -name '*.dmg' -print -quit)
    [ -n "$candidate" ] || { echo 'SystemOS DMG was not extracted' >&2; exit 24; }
    cp -f "$candidate" "$SYS_DMG"
fi

if [ ! -f "$ROOTFS/usr/bin/sh" ]; then
    log 'Распаковываю APFS файловую систему macOS в /var/mnt/rootfs…'
    "$APFS" extract "$FS_DMG" -C "$ROOTFS" --recursive --preserve-meta --xattrs --symlinks real
fi

log 'Распаковываю OS cryptex в System/Volumes/Preboot/Cryptexes/OS…'
rm -rf "$ROOTFS/System/Volumes/Preboot/Cryptexes/OS.new"
mkdir -p "$ROOTFS/System/Volumes/Preboot/Cryptexes/OS.new"
"$APFS" extract "$SYS_DMG" -C "$ROOTFS/System/Volumes/Preboot/Cryptexes/OS.new" --recursive --preserve-meta --xattrs --symlinks real
rm -rf "$ROOTFS/System/Volumes/Preboot/Cryptexes/OS"
mv "$ROOTFS/System/Volumes/Preboot/Cryptexes/OS.new" "$ROOTFS/System/Volumes/Preboot/Cryptexes/OS"

log 'Создаю структуру Data/Home/var/folders…'
rm -rf "$ROOTFS/System/Volumes/Data"
ln -s ../.. "$ROOTFS/System/Volumes/Data"
rm -f "$ROOTFS/home"
ln -s System/Volumes/Data/home "$ROOTFS/home"
mkdir -p "$ROOTFS/Users/root" "$ROOTFS/var/folders" 
rm -f "$ROOTFS/var/folders/zz"
ln -s /var/folders/zz "$ROOTFS/var/folders/zz"
mkdir -p "$ROOTFS/System/Volumes/Data/home" "$ROOTFS/System/Volumes/Data/var"

if [ -d "$ROOTFS/System/Library/Templates/Data" ]; then
    log 'Сливаю System/Library/Templates/Data…'
    cp -a "$ROOTFS/System/Library/Templates/Data/." "$ROOTFS/"
fi

mkdir -p "$ROOTFS/var/jb"

log 'Запускаю встроенную автоматическую пост-установку проекта…'
"$BASH" /var/jb/usr/macOS/bin/postinst.sh

log 'Готово: rootfs, cryptex, структура каталогов и runtime provisioning установлены.'
