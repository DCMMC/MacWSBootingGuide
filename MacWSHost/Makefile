# The on-device lld emits arm64e Objective-C metadata that traps in
# libobjc readClass() before main (runtime-confirmed on iPad13,6 / iOS 16.3.1).
# An arm64 application runs natively on this arm64e CPU and avoids that broken
# fixup ABI; do not paper over it with the libobjc autda diagnostic patch.
ARCHS = arm64
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = MacWSHost

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MacWSHost

MacWSHost_FILES = main.m MacWSControlClient.m MacWSStreamClient.m \
	MacWSPerformanceMonitor.m \
	Testing/MacWSPerformanceGestureScenario.m \
	Support/MacWSHostDiagnostics.m \
	Transport/MacWSCatalystDrawableReceiver.m \
	Compatibility/MacWSMappedFrame.m \
	MacWSMenuClient.m \
	MacWSInteropClient.m ../misc/iosclear_ref.m
MacWSHost_FRAMEWORKS = UIKit Metal MetalKit QuartzCore CoreGraphics Foundation \
	IOKit IOSurface UniformTypeIdentifiers
MacWSHost_LIBRARIES = bsm
MacWSHost_CFLAGS = -fobjc-arc -Wall -Wextra -I$(CURDIR)/../include \
	-I$(CURDIR)/Support -I$(CURDIR)/Testing -I$(CURDIR)/Transport \
	-I$(CURDIR)/Compatibility \
	-isystem $(CURDIR)/../vendor/ios-xpc -DIOSCLEAR_LIBRARY_MODE=1
MacWSHost_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
