ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MacWSWindowing
MacWSWindowing_FILES = Tweak.x
MacWSWindowing_CFLAGS = -fobjc-arc -Wall -Wextra
MacWSWindowing_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
