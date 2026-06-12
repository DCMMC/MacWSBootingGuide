TARGET := iphone:clang:latest:14.0
# Build both slices.  misc/build_on_ios.sh then SPLITS the fat into two THIN
# dylibs (libmachook.dylib = arm64e, libmachook_arm64.dylib = arm64) and inserts
# both, because on the target device's dyld (iOS 16.x) a *fat*
# DYLD_INSERT_LIBRARIES dylib fails to load into a chrooted macOS process
# ("missing compatible architecture ... need ''"), while a thin slice matching
# the process arch loads fine (and dyld silently skips a non-matching thin).
# The macOS cross-compile (misc/build.sh) ships the fat binary unchanged.
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

# On-device builds (misc/build_on_ios.sh passes LIBMACHOOK_ON_DEVICE_BUILD=1)
# use the on-device lld.  For the arm64e slice, lld emits the __interpose tuples
# (and ObjC class_t->data) as arm64e *authenticated* pointers but under the
# classic LC_DYLD_INFO_ONLY fixup format.  macOS arm64e dyld mis-processes those:
# the DYLD_INTERPOSE entries never register, so the real
# os_variant_has_internal_diagnostics() runs and traps (brk 1) inside
# libSystem_initializer before any of our hooks take effect.  -fixup_chains
# forces LC_DYLD_CHAINED_FIXUPS, which macOS dyld fully understands and
# re-signs/re-binds correctly at load (this also fixes the arm64e ObjC class_t
# PAC trap, so Metal_hooks.x may include arm64e ObjC under this define).
# The macOS cross-compile (misc/build.sh) uses Xcode ld64, which already emits
# chained fixups, so it must NOT receive this flag -> keep it on-device only.
ifeq ($(LIBMACHOOK_ON_DEVICE_BUILD),1)
libmachook_CFLAGS += -DLIBMACHOOK_ON_DEVICE_BUILD=1
libmachook_LDFLAGS += -Wl,-fixup_chains
endif

libmachook_INSTALL_PATH = /usr/macOS/lib

include $(THEOS_MAKE_PATH)/library.mk
