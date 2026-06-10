TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
include $(THEOS)/makefiles/common.mk

# libmachook: full hooks (Metal, SkyLight, …) for WindowServer / GUI.
# libmachook_cli: minimal insert lib for run_bash — no Metal/IOSurface so dyld applies
# interposes before pulling the full framework stack (avoids early crashes / SIGSEGV).
LIBRARY_NAME = libmachook libmachook_cli

libmachook_FILES = jit.m objc_hooks.c mac_hooks.m os_variant_hooks.x \
  ControlCenter_hooks.x Metal_hooks.x QuartzCore_hooks.x os_log_hooks.m
libmachook_FRAMEWORKS = IOKit IOSurface Metal
libmachook_CFLAGS = -I..
libmachook_LDFLAGS = -undefined dynamic_lookup
libmachook_INSTALL_PATH = /usr/macOS/lib

libmachook_cli_FILES = jit.m objc_hooks.c mac_hooks_cli.m os_variant_hooks.x
libmachook_cli_FRAMEWORKS = IOKit
libmachook_cli_CFLAGS = -fobjc-arc -I..
libmachook_cli_LDFLAGS = -undefined dynamic_lookup
libmachook_cli_INSTALL_PATH = /usr/macOS/lib

include $(THEOS_MAKE_PATH)/library.mk
