include $(THEOS)/makefiles/common.mk

TWEAK_NAME = mcp-appsync-installd

mcp-appsync-installd_FILES = AppSyncUnified-installd.x dump.cpp cdhash.m
mcp-appsync-installd_CFLAGS += -fvisibility=hidden -Wno-unused-private-field
mcp-appsync-installd_LIBRARIES = substrate
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    mcp-appsync-installd_LIBRARIES += roothide
    mcp-appsync-installd_LDFLAGS += $(THEOS)/vendor/lib/libroot.a
endif

include $(THEOS_MAKE_PATH)/tweak.mk
