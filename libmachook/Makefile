TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = libmachook

libmachook_FILES = jit.m objc_hooks.c mac_hooks.m  os_variant_hooks.x \
  ControlCenter_hooks.x Metal_hooks.x QuartzCore_hooks.x os_log_hooks.m \
  exec_hooks.c
libmachook_FRAMEWORKS = IOKit IOSurface Metal
# -isystem: use the vendored iOS xpc headers (the theos iPhoneOS SDK ships
# without xpc/). See ../vendor/ios-xpc/README.md.
libmachook_CFLAGS = -isystem $(CURDIR)/../vendor/ios-xpc
libmachook_LDFLAGS = -undefined dynamic_lookup
libmachook_INSTALL_PATH = /usr/macOS/lib

include $(THEOS_MAKE_PATH)/library.mk
