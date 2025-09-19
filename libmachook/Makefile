ARCHS = arm64 arm64e
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = libmachook

libmachook_FILES = jit.m objc_hooks.c mac_hooks.m  os_variant_hooks.x \
  ControlCenter_hooks.x Metal_hooks.x QuartzCore_hooks.x os_log_hooks.m
# libmachook_CFLAGS = -D_FORCE_M1_DRIVER
libmachook_FRAMEWORKS = IOKit IOSurface Metal
libmachook_LDFLAGS = -undefined dynamic_lookup
libmachook_INSTALL_PATH = /usr/macOS/lib

include $(THEOS_MAKE_PATH)/library.mk
