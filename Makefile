export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:14.0
export INSTALL_TARGET_PROCESSES = DHPDaemon

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += tweak

include $(THEOS_MAKE_PATH)/aggregate.mk
