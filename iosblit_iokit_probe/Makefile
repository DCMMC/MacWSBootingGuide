ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = iosblit

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iosblit_iokit_probe

iosblit_iokit_probe_FILES = Tweak.x
iosblit_iokit_probe_CFLAGS = -fobjc-arc
iosblit_iokit_probe_FRAMEWORKS = IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
