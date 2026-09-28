export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:12.0
export INSTALL_TARGET_PROCESSES = DHPDaemon

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AXJBashShim
AXJBashShim_FILES = tweak/shim.m
AXJBashShim_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter
AXJBashShim_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "launchctl kickstart -kp system/dhpdaemon || killall -9 DHPDaemon || true"
