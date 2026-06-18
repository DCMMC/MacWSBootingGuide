TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# iOS subprojects
SUBPROJECTS += MTLCompilerBypassOSCheck MTLSimDriverHost launchdchrootexec autosignd mountdevfs ViewBridgeChrootProxy mtl_keepalive
# macOS subprojects
SUBPROJECTS += launchservicesd libmachook

include $(THEOS_MAKE_PATH)/aggregate.mk
