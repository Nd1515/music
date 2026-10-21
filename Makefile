ARCHS = armv7
TARGET = iphone:clang:10.3:6.0
TWEAK_NAME = RainyDayEnhancer
RainyDayEnhancer_FILES = Tweak.m
RainyDayEnhancer_FRAMEWORKS = UIKit Foundation AVFoundation MediaPlayer
RainyDayEnhancer_CFLAGS = -fobjc-arc
RainyDayEnhancer_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

