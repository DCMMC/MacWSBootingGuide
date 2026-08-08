# No shebang: invoke with bash. This jailbreak's AMFI rejects execve of
# shebang scripts.

# Provision the exact secondary QuartzCore library needed by the native iOS
# AGX driver. This intentionally does not replace Ventura's process-wide
# default.metallib. It is small enough to run from both package installation
# and the complete rootfs repair path, closing the upgrade case where all
# trust sentinels remain valid but a newly discovered shader is still absent.
ROOTFS=/var/mnt/rootfs
QC_DEFAULT="$ROOTFS/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"
QC_ORIGINAL="$QC_DEFAULT.macws-macos13.4-original"
QC_EXPECTED_SHA256=ac8014164c7784395f86ac2926c62b67c96faa2a3c789f231b4b22b64024bfba
QC_COMPAT_DIR="$ROOTFS/usr/local/share/macws/quartzcore"
QC_COMPAT_TARGET="$QC_COMPAT_DIR/default-desktop-effects-macabi.metallib"
QC_COMPAT_EXPECTED_SHA256=4a1fceb931d8b0f2a67ae13a9c9f17e928cccc04af67e86bfbff2564dbf63e08
QC_REPACKER=/var/jb/usr/macOS/bin/repack_metallib_macabi.py
QC_LLVM_DIS=/var/jb/usr/lib/llvm-16/bin/llvm-dis
QC_LLVM_AS=/var/jb/usr/lib/llvm-16/bin/llvm-as

qc_compat_sha256() {
	sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

if [ "$(qc_compat_sha256 "$QC_ORIGINAL")" != "$QC_EXPECTED_SHA256" ]; then
	if [ "$(qc_compat_sha256 "$QC_DEFAULT")" != "$QC_EXPECTED_SHA256" ]; then
		echo "[ERROR] QuartzCore default.metallib is not the supported macOS 13.4 library." >&2
		exit 1
	fi
	cp "$QC_DEFAULT" "$QC_ORIGINAL.new.$$" || exit 1
	chmod 0644 "$QC_ORIGINAL.new.$$" || exit 1
	mv -f "$QC_ORIGINAL.new.$$" "$QC_ORIGINAL" || exit 1
fi

# Undo an interrupted diagnostic replacement before any GUI process can see
# it. The supported system library hash is the authoritative source.
if [ "$(qc_compat_sha256 "$QC_DEFAULT")" != "$QC_EXPECTED_SHA256" ]; then
	cp "$QC_ORIGINAL" "$QC_DEFAULT.new.$$" || exit 1
	chmod 0644 "$QC_DEFAULT.new.$$" || exit 1
	mv -f "$QC_DEFAULT.new.$$" "$QC_DEFAULT" || exit 1
fi

if [ ! -f "$QC_REPACKER" ] || [ ! -x "$QC_LLVM_DIS" ] ||
   [ ! -x "$QC_LLVM_AS" ]; then
	echo "[ERROR] QuartzCore macabi repacker or device LLVM 16 is unavailable." >&2
	exit 1
fi

# A matching artifact is already a complete byte-level witness. Avoid LLVM
# work on every package reinstall and cold repair.
if [ "$(qc_compat_sha256 "$QC_COMPAT_TARGET")" =
     "$QC_COMPAT_EXPECTED_SHA256" ]; then
	echo '[INFO] exact QuartzCore desktop-effects macabi shader library already installed'
	exit 0
fi

mkdir -p "$QC_COMPAT_DIR" || exit 1
QC_COMPAT_TMP="$QC_COMPAT_TARGET.new.$$"
python3 "$QC_REPACKER" "$QC_ORIGINAL" "$QC_COMPAT_TMP" \
	--llvm-dis "$QC_LLVM_DIS" --llvm-as "$QC_LLVM_AS" \
	--function fixed_vert_lph_spc \
	--function fixed_vert_lph_gen \
	--function fixed_frag_lph_cpf \
	--function path_blit_vert_lph \
	--function attachment_clear_frag_lph \
	--function std_vert1_lph \
	--function inplace_copy_lph \
	--function downsample_blur_vert_lph \
	--function downsample_8_frag_lph \
	--function single_pass_blur_3_lph \
	--rewrite-fract-v3f16-function fixed_frag_lph_cpf \
	--preserve-container-target || {
	rm -f "$QC_COMPAT_TMP"
	exit 1
}
if [ "$(qc_compat_sha256 "$QC_COMPAT_TMP")" !=
     "$QC_COMPAT_EXPECTED_SHA256" ]; then
	echo "[ERROR] Generated QuartzCore desktop-effects library failed exact validation." >&2
	rm -f "$QC_COMPAT_TMP"
	exit 1
fi
chmod 0644 "$QC_COMPAT_TMP" || exit 1
mv -f "$QC_COMPAT_TMP" "$QC_COMPAT_TARGET" || exit 1
echo '[INFO] installed exact QuartzCore desktop-effects macabi shader library'

