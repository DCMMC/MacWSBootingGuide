TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# iOS subprojects
SUBPROJECTS += MTLCompilerBypassOSCheck MTLSimDriverHost launchdchrootexec
# macOS subprojects
SUBPROJECTS += launchservicesd libmachook login

include $(THEOS_MAKE_PATH)/aggregate.mk
