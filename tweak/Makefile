ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AXJBashShim
AXJBashShim_FILES = shim.m
AXJBashShim_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter
AXJBashShim_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
