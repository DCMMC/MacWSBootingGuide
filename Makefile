TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# iOS subprojects
SUBPROJECTS += MTLCompilerBypassOSCheck MTLSimDriverHost launchdchrootexec autosignd macwsallocd macwshostd macwsthermal mountdevfs ViewBridgeChrootProxy mtl_keepalive MacWSHost
# macOS subprojects
SUBPROJECTS += launchservicesd libmachook macwsinputd macwsdisplayd macwsinteropd

include $(THEOS_MAKE_PATH)/aggregate.mk

# Package the authoritative VS Code production benchmark assets outside every
# auto-scanned LaunchDaemons directory. macos_gui.sh loads this optional job
# explicitly only after WindowServer is ready, so reinstall/re-jailbreak cannot
# start Electron against a missing CGS session.
after-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/usr/macOS/gui-launchd
	@mkdir -p $(THEOS_STAGING_DIR)/usr/macOS/share/vscode/macwsguide.macws-aquarium-runner-0.0.1
	@install -m 0644 misc/com.macwsguide.vscode.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.macwsguide.vscode.plist
	@install -m 0644 misc/vscode-production-settings.json \
		$(THEOS_STAGING_DIR)/usr/macOS/share/vscode/settings.json
	@install -m 0644 misc/vscode-aquarium-runner/extensions.json \
		$(THEOS_STAGING_DIR)/usr/macOS/share/vscode/extensions.json
	@install -m 0644 misc/vscode-aquarium-runner/package.json \
		misc/vscode-aquarium-runner/extension.js \
		misc/vscode-aquarium-runner/README.md \
		$(THEOS_STAGING_DIR)/usr/macOS/share/vscode/macwsguide.macws-aquarium-runner-0.0.1/
