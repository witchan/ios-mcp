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

TOOL_NAME = mcp-appinst
mcp-appinst_FILES = appinst.m unarchive.m
mcp-appinst_CCFLAGS += -std=c++11 -stdlib=libc++ -fobjc-arc -include ./zip.h -I . -fvisibility=hidden -Wno-unused-property-ivar
mcp-appinst_CFLAGS += -fobjc-arc -include ./zip.h -I . -fvisibility=hidden -Wno-unused-property-ivar
mcp-appinst_FRAMEWORKS = Foundation ImageIO CoreGraphics Security
mcp-appinst_PRIVATE_FRAMEWORKS = MobileCoreServices
mcp-appinst_LDFLAGS += $(THEOS)/lib/libzip.a
mcp-appinst_LIBRARIES = z
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    mcp-appinst_CFLAGS += -DMCP_ROOTHIDE=1
    mcp-appinst_CCFLAGS += -DMCP_ROOTHIDE=1
    mcp-appinst_LIBRARIES += roothide
    mcp-appinst_CODESIGN_FLAGS = -Smcp-appinst_roothide_entitlements.plist
else
    mcp-appinst_CODESIGN_FLAGS = -Smcp-appinst_entitlements.plist
endif
mcp-appinst_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
