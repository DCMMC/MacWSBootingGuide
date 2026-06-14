ARCHS = arm64e
include $(THEOS)/makefiles/common.mk

TOOL_NAME = launchdchrootexec

launchdchrootexec_FILES = main.m
launchdchrootexec_CFLAGS = -fobjc-arc
launchdchrootexec_CODESIGN_FLAGS = -S../entitlements.plist
launchdchrootexec_INSTALL_PATH = /usr/macOS/bin

include $(THEOS_MAKE_PATH)/tool.mk
