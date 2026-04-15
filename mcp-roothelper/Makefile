ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    export TARGET = iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    export TARGET = iphone:clang:latest:15.0
else
    export TARGET = iphone:clang:latest:13.0
endif
export ARCHS = arm64
export DEBUG = 0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = mcp-roothelper

mcp-roothelper_FILES = main.m
mcp-roothelper_CFLAGS += -fobjc-arc -include ../AppSync/appinst/zip.h -I../AppSync/appinst -fvisibility=hidden
mcp-roothelper_CCFLAGS += -fobjc-arc -std=c++11 -stdlib=libc++ -include ../AppSync/appinst/zip.h -I../AppSync/appinst -fvisibility=hidden
mcp-roothelper_FRAMEWORKS = Foundation
mcp-roothelper_LDFLAGS += $(THEOS)/lib/libzip.a
mcp-roothelper_LIBRARIES = z
mcp-roothelper_USE_MODULES = 0
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    mcp-roothelper_CFLAGS += -DMCP_ROOTHIDE=1
    mcp-roothelper_CCFLAGS += -DMCP_ROOTHIDE=1
    mcp-roothelper_LIBRARIES += roothide
    mcp-roothelper_CODESIGN_FLAGS = -Smcp-roothelper_roothide_entitlements.plist
endif
mcp-roothelper_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
