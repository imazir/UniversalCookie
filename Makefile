ARCHS = arm64
TARGET := iphone:clang:15.6:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UniversalCookie
UniversalCookie_FILES = Tweak.x
UniversalCookie_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
UniversalCookie_FRAMEWORKS = UIKit Foundation WebKit Security

include $(THEOS_MAKE_PATH)/tweak.mk
