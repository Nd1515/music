ARCHS = armv7
TARGET = iphone:clang:10.3:6.0
TWEAK_NAME = RainyDayEnhancer
RainyDayEnhancer_FILES = Tweak.m
RainyDayEnhancer_FRAMEWORKS = UIKit Foundation AVFoundation
RainyDayEnhancer_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
