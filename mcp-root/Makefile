ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    export TARGET = iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    export TARGET = iphone:clang:latest:15.0
else
    export TARGET = iphone:clang:latest:13.0
endif
export ARCHS = arm64 arm64e
export DEBUG = 0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = mcp-root
mcp-root_FILES = main.c
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    mcp-root_CFLAGS += -DMCP_ROOTHIDE=1
    mcp-root_LIBRARIES = roothide
    mcp-root_CODESIGN_FLAGS = -Smcp-root_roothide_entitlements.plist
endif
mcp-root_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
