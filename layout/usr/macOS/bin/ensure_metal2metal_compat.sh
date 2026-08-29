# No shebang: invoke with bash. This jailbreak's AMFI rejects execve of
# shebang scripts.

# Provision the complete manifest-driven desktop Metal compatibility set.
# Every route is accepted only after the exact source and translated output
# both verify against its manifest. Existing valid routes are constant-time
# no-ops, so package upgrades and GUI cold starts share this one boundary
# without repeating LLVM work.
ROOTFS=/var/mnt/rootfs
METAL2METAL=/var/jb/usr/macOS/bin/metal2metal.py
LLVM_DIS=/var/jb/usr/lib/llvm-16/bin/llvm-dis
LLVM_AS=/var/jb/usr/lib/llvm-16/bin/llvm-as
ROUTE_DIR="$ROOTFS/usr/local/share/macws/metal2metal/routes"

metal2metal_sha256() {
	sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

if [ ! -f "$METAL2METAL" ] || [ ! -x "$LLVM_DIS" ] ||
   [ ! -x "$LLVM_AS" ]; then
	echo "[ERROR] metal2metal or device LLVM 16 is unavailable." >&2
	exit 1
fi

# QuartzCore also owns restoration of a diagnostically replaced system
# default.metallib, so retain that focused provisioner as the source owner.
bash /var/jb/usr/macOS/bin/ensure_quartzcore_compat.sh || exit 1

provision_route() {
	name="$1"
	source="$2"
	expected_source_sha256="$3"
	output="$4"
	manifest="$5"
	runtime_source="$6"
	runtime_output="$7"
	expected_output_sha256="$8"
	auto_lower="$9"

	if python3 "$METAL2METAL" verify-runtime-manifest "$manifest" \
	     --source "$source" --output "$output" >/dev/null 2>&1; then
		echo "[INFO] complete $name metal2metal route already installed"
		return 0
	fi
	if [ "$(metal2metal_sha256 "$source")" != "$expected_source_sha256" ]; then
		echo "[ERROR] $name source metallib is not the supported macOS 13.4 library." >&2
		return 1
	fi

	mkdir -p "$(dirname "$output")" "$ROUTE_DIR" || return 1
	output_tmp="$output.new.$$"
	manifest_tmp="$manifest.new.$$"
	args=(translate "$source" "$output_tmp"
		--llvm-dis "$LLVM_DIS" --llvm-as "$LLVM_AS"
		--runtime-manifest "$manifest_tmp"
		--runtime-source-path "$runtime_source"
		--runtime-output-path "$runtime_output")
	if [ "$auto_lower" = 1 ]; then
		args+=(--auto-lower-known-air)
	fi
	python3 "$METAL2METAL" "${args[@]}" || {
		rm -f "$output_tmp" "$manifest_tmp"
		return 1
	}
	if [ -n "$expected_output_sha256" ] &&
	   [ "$(metal2metal_sha256 "$output_tmp")" != "$expected_output_sha256" ]; then
		echo "[ERROR] generated $name metal2metal output failed exact validation." >&2
		rm -f "$output_tmp" "$manifest_tmp"
		return 1
	fi
	python3 "$METAL2METAL" verify-runtime-manifest "$manifest_tmp" \
		--source "$source" --output "$output_tmp" || {
		rm -f "$output_tmp" "$manifest_tmp"
		return 1
	}
	chmod 0644 "$output_tmp" "$manifest_tmp" || return 1
	mv -f "$output_tmp" "$output" || return 1
	mv -f "$manifest_tmp" "$manifest" || return 1
	echo "[INFO] installed complete $name metal2metal route"
}

provision_route \
	SkyLight \
	"$ROOTFS/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib" \
	378174fcbf7fc639aa737cad7a765690b2d76fa3a66c7a8e71018441f3ac3184 \
	"$ROOTFS/usr/local/share/macws/skylight/SkyLightShaders-desktop-effects-macabi.metallib" \
	"$ROUTE_DIR/skylight-shaders.route.plist" \
	"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib" \
	"/usr/local/share/macws/skylight/SkyLightShaders-desktop-effects-macabi.metallib" \
	bfe93e8146325a912a0db9fc1ed28a2de32aa9ccb4065148398be12ac0644df1 \
	0 || exit 1

provision_route \
	MPSImage \
	"$ROOTFS/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSImage.framework/Versions/A/Resources/default.metallib" \
	376ded7ee154429f6950656eb668b26af27fc6149b734b11dd48a33d68fe4285 \
	"$ROOTFS/usr/local/share/macws/mpsimage/default-desktop-effects-macabi.metallib" \
	"$ROUTE_DIR/mpsimage-default.route.plist" \
	"/System/Library/Frameworks/MetalPerformanceShaders.framework/Versions/A/Frameworks/MPSImage.framework/Versions/A/Resources/default.metallib" \
	"/usr/local/share/macws/mpsimage/default-desktop-effects-macabi.metallib" \
	"" \
	1 || exit 1

# Ventura MetalFX ships its temporal scaler network as one desktop-targeted
# library.  Route the complete library through the same manifest contract as
# QuartzCore/SkyLight/MPSImage: every source function must be translated and
# both metallibs must retain their exact identities before runtime accepts it.
# This is deliberately library-wide; no BRNet shader-name allowlist belongs
# in either the provisioner or libmachook.
provision_route \
	MetalFX \
	"$ROOTFS/System/Library/Frameworks/MetalFX.framework/Versions/A/Resources/default.metallib" \
	bb07e6ce97acf56caa32f8c69b8ebcc94bc74991ff51d76db8460791c7728534 \
	"$ROOTFS/usr/local/share/macws/metalfx/default-temporal-macabi.metallib" \
	"$ROUTE_DIR/metalfx-default.route.plist" \
	"/System/Library/Frameworks/MetalFX.framework/Versions/A/Resources/default.metallib" \
	"/usr/local/share/macws/metalfx/default-temporal-macabi.metallib" \
	"" \
	1 || exit 1
