TARGET := macosx:clang:latest:13.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

_THEOS_INTERNAL_IFLAGS_BASE = -I$(THEOS_TARGET_INCLUDE_PATH) \
	-I$(THEOS_INCLUDE_PATH) -I$(THEOS_FALLBACK_INCLUDE_PATH)

TOOL_NAME = macwsinteropd

macwsinteropd_FILES = main.m
macwsinteropd_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra \
	-I$(CURDIR)/../include -isystem $(CURDIR)/../vendor/ios-xpc
macwsinteropd_FRAMEWORKS = Foundation AppKit
macwsinteropd_CODESIGN_FLAGS = -S../layout/usr/macOS/bin/entitlements.plist
macwsinteropd_INSTALL_PATH = /usr/macOS/bin

include $(THEOS_MAKE_PATH)/tool.mk
