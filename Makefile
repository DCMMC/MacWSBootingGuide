TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += MTLCompilerBypassOSCheck launchdchrootexec launchservicesd libmachook login MTLSimDriverHost TestMetalIOSurface

include $(THEOS_MAKE_PATH)/aggregate.mk
