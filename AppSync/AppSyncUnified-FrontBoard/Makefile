include $(THEOS)/makefiles/common.mk

TWEAK_NAME = mcp-appsync-frontboard

mcp-appsync-frontboard_FILES = AppSyncUnified-FrontBoard.x
mcp-appsync-frontboard_CFLAGS = -fobjc-arc
mcp-appsync-frontboard_LIBRARIES = substrate
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    mcp-appsync-frontboard_LIBRARIES += roothide
    mcp-appsync-frontboard_LDFLAGS += $(THEOS)/vendor/lib/libroot.a
endif

include $(THEOS_MAKE_PATH)/tweak.mk
