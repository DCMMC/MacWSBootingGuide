TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# iOS subprojects
SUBPROJECTS += MTLCompilerBypassOSCheck MacWSWindowing MacWSCatalystLaunch MTLSimDriverHost launchdchrootexec autosignd macwsallocd macwshostd macwscontrolprobe macwskeychaind macwsthermal macwslocationd mountdevfs ViewBridgeChrootProxy HIServicesChrootProxy OpenAndSavePanelChrootProxy DockHelperChrootProxy ExtensionKitChrootProxy SettingsExtensionChrootProxy FileCoordinationChrootProxy GeodChrootProxy WriteConfigChrootProxy LocationdChrootProxy mtl_keepalive MacWSHost MacWSCatalystLauncher SettingsExtensionMetadata misc/PingMTLCompilerService
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
	@rm -f $(THEOS_STAGING_DIR)/usr/macOS/bin/.ldid.entitlements.plist
	@mkdir -p $(THEOS_STAGING_DIR)/usr/macOS/share/vscode/macwsguide.macws-aquarium-runner-0.0.1
	@install -m 0644 misc/com.macwsguide.vscode.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.macwsguide.vscode.plist
	@install -m 0644 misc/com.macwsguide.steam.runtime.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.macwsguide.steam.runtime.plist
	@install -m 0644 misc/com.valvesoftware.steam.ipctool.plist \
		$(THEOS_STAGING_DIR)/usr/macOS/gui-launchd/com.valvesoftware.steam.ipctool.plist
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
	@install -m 0644 misc/metal2metal.py \
		misc/metal2metal_manifest.py \
		misc/metal2metal_profiles.py \
		misc/repack_metallib_macabi.py \
		$(THEOS_STAGING_DIR)/usr/macOS/bin/
	@install -m 0644 misc/install_stray_exact_metallib.py \
		$(THEOS_STAGING_DIR)/usr/macOS/bin/install_stray_exact_metallib.py
	@install -m 0644 misc/add_macho_load_dylib.py \
		$(THEOS_STAGING_DIR)/usr/macOS/bin/add_macho_load_dylib.py
	@install -m 0644 misc/patch_electron_pa_ios_va.py \
		misc/patch_steam_cef126_pa_ios_va.py \
		misc/refresh_steam_inventory.py \
		$(THEOS_STAGING_DIR)/usr/macOS/bin/
	@install -m 0755 misc/run_steam_live.sh \
		$(THEOS_STAGING_DIR)/usr/macOS/bin/run_steam_live.sh

# SpringBoard is arm64e and requires authenticated data fixups for Objective-C
# and CF constant objects. The iPad's lld does not encode those fixups correctly
# even with -fixup_chains; SpringBoard-2026-08-28-001431.ips trapped in CFHash
# on the first Darwin-observer registration. Full on-device builds still build
# the subproject to keep Theos's dependency graph intact, but the final staging
# transaction must atomically replace that unsafe intermediate with the
# Apple-ld64 artifact validated and cached by deploy_macwswindowing.sh.
ifneq ($(strip $(MACWS_WINDOWING_CROSS_PREBUILT)),)
after-stage::
	@test -s "$(MACWS_WINDOWING_CROSS_PREBUILT)" || { \
		echo 'ERROR: validated MacWSWindowing cross-build is missing.' >&2; exit 1; }
	@mkdir -p $(THEOS_STAGING_DIR)/usr/lib/TweakInject
	@install -m 0755 "$(MACWS_WINDOWING_CROSS_PREBUILT)" \
		$(THEOS_STAGING_DIR)/usr/lib/TweakInject/MacWSWindowing.dylib
	@echo '==> Replaced on-device MacWSWindowing intermediate with validated Apple-ld64 artifact'
endif
