ARCHS = arm64e
TARGET = iphone:clang:latest:14.0
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ViewBridgeAuxiliary

ViewBridgeAuxiliary_DYNAMIC_LIBRARY = 0
ViewBridgeAuxiliary_BUNDLE_EXTENSION = xpc
ViewBridgeAuxiliary_FILES = main.m
ViewBridgeAuxiliary_CFLAGS = -fobjc-arc
ViewBridgeAuxiliary_CODESIGN_FLAGS = -S../entitlements.plist
ViewBridgeAuxiliary_INSTALL_PATH = /usr/macOS/Frameworks/ViewBridge.framework/Versions/A/XPCServices

include $(THEOS_MAKE_PATH)/bundle.mk
