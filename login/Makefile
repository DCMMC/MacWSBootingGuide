ARCHS = arm64
include $(THEOS)/makefiles/common.mk

TOOL_NAME = login

login_FILES = main.m
login_CFLAGS = -fobjc-arc
login_CODESIGN_FLAGS = -S../entitlements.plist
login_INSTALL_PATH = /usr/macOS/bin

include $(THEOS_MAKE_PATH)/tool.mk
