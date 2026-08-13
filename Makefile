TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# iOS subprojects
SUBPROJECTS += MTLCompilerBypassOSCheck MacWSWindowing MacWSCatalystLaunch MTLSimDriverHost launchdchrootexec autosignd macwsallocd macwshostd macwskeychaind macwsthermal macwslocationd mountdevfs ViewBridgeChrootProxy HIServicesChrootProxy OpenAndSavePanelChrootProxy DockHelperChrootProxy ExtensionKitChrootProxy SettingsExtensionChrootProxy FileCoordinationChrootProxy GeodChrootProxy WriteConfigChrootProxy LocationdChrootProxy mtl_keepalive MacWSHost MacWSCatalystLauncher SettingsExtensionMetadata misc/PingMTLCompilerService
# macOS subprojects
SUBPROJECTS += launchservicesd libmachook macwsinputd macwsdisplayd macwsinteropd macwsworkspacectl

include $(THEOS_MAKE_PATH)/aggregate.mk

# Package the authoritative VS Code production benchmark assets outside every
# auto-scanned LaunchDaemons directory. macos_gui.sh loads this optional job
# explicitly only after WindowServer is ready, so reinstall/re-jailbreak cannot
# start Electron against a missing CGS session.
after-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/usr/macOS/gui-launchd
	@mkdir -p $(THEOS_STAGING_DIR)/usr/macOS/share/certificates
	@mkdir -p $(THEOS_STAGING_DIR)/usr/macOS/libexec/MacWSInteropService.app/Contents/MacOS
	@rm -rf $(THEOS_STAGING_DIR)/usr/macOS/bin/__pycache__
	@mkdir -p $(THEOS_STAGING_DIR)/usr/macOS/share/vscode/macwsguide.macws-aquarium-runner-0.0.1
	@install -m 0644 misc/com.macwsguide.vscode.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.macwsguide.vscode.plist
	@install -m 0644 misc/com.macwsguide.macos-locationd.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.macwsguide.macos-locationd.plist
	@install -m 0644 misc/com.macwsguide.corelocationagent.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.macwsguide.corelocationagent.plist
	@install -m 0644 misc/com.macwsguide.locationbridge.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.macwsguide.locationbridge.plist
	@install -m 0644 misc/com.macwsguide.macos-writeconfig.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.macwsguide.macos-writeconfig.plist
	@install -m 0644 layout/usr/macOS/libexec/MacWSInteropService.app/Contents/Info.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/libexec/MacWSInteropService.app/Contents/Info.plist
	@install -m 0755 $(THEOS_STAGING_DIR)/usr/macOS/bin/macwsinteropd \
		$(THEOS_STAGING_DIR)/usr/macOS/libexec/MacWSInteropService.app/Contents/MacOS/macwsinteropd
	@install -m 0644 misc/vscode-production-settings.json \
		$(THEOS_STAGING_DIR)/usr/macOS/share/vscode/settings.json
	@install -m 0644 layout/usr/macOS/share/certificates/SectigoPublicServerAuthenticationCAOVR36.pem \
		$(THEOS_STAGING_DIR)/usr/macOS/share/certificates/SectigoPublicServerAuthenticationCAOVR36.pem
	@install -m 0644 misc/vscode-aquarium-runner/extensions.json \
		$(THEOS_STAGING_DIR)/usr/macOS/share/vscode/extensions.json
	@install -m 0644 misc/vscode-aquarium-runner/package.json \
		misc/vscode-aquarium-runner/extension.js \
		misc/vscode-aquarium-runner/README.md \
		$(THEOS_STAGING_DIR)/usr/macOS/share/vscode/macwsguide.macws-aquarium-runner-0.0.1/
	@install -m 0644 misc/repack_metallib_macabi.py \
		$(THEOS_STAGING_DIR)/usr/macOS/bin/repack_metallib_macabi.py
	@install -m 0644 misc/add_macho_load_dylib.py \
		$(THEOS_STAGING_DIR)/usr/macOS/bin/add_macho_load_dylib.py
