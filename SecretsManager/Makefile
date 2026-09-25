ARCHS = arm64
TARGET := iphone:clang:15.6:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SecretsManager
SecretsManager_FILES = Tweak.x
SecretsManager_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
SecretsManager_FRAMEWORKS = UIKit Foundation WebKit Security

include $(THEOS_MAKE_PATH)/tweak.mk
