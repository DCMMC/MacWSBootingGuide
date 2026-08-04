# The iPad's on-device lld emits malformed unauthenticated references for
# Objective-C/CF constant objects in arm64e dylibs.  Runtime evidence:
# SpringBoard-2026-08-04-124439.ips trapped in CFHash while registering this
# tweak's Darwin notifications with x16=0x00200001f87ae4c0, whereas
# __CFConstantStringClassReference was 0x00000001f87ae4c0.  The same source
# cross-linked by Apple's macOS ld64 produces authenticated chained fixups.
#
# SpringBoard can load an arm64 tweak on this arm64e device, so on-device
# package builds deliberately omit the unsafe arm64e slice.  Cross-builds keep
# both slices and remain the preferred release path.
ifneq ($(wildcard /var/jb/var/mobile/theos/makefiles/common.mk),)
ARCHS = arm64
else
ARCHS = arm64 arm64e
endif
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MacWSWindowing
MacWSWindowing_FILES = Tweak.x
MacWSWindowing_CFLAGS = -fobjc-arc -Wall -Wextra
MacWSWindowing_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
