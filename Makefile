# Rootful: iOS 13.0+, Rootless: iOS 15.0+, Roothide: iOS 15.0+
ARCHS = arm64 arm64e
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    TARGET := iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    TARGET := iphone:clang:latest:15.0
else
    TARGET := iphone:clang:latest:13.0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ios-mcp ios-mcp-helper
BUNDLE_NAME = iosmcpprefs

ios-mcp_FILES = Tweak.x MCPServer.m HIDManager.m ScreenManager.m ClipboardManager.m AppManager.m AccessibilityManager.m TextInputManager.m MCPProcessUtil.m
ios-mcp_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
ios-mcp_FRAMEWORKS = IOKit UIKit CoreGraphics QuartzCore MobileCoreServices AVFoundation Security

ios-mcp-helper_FILES = helper/AXHelper.m
ios-mcp-helper_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
ios-mcp-helper_FRAMEWORKS = UIKit CoreGraphics

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    ios-mcp_LIBRARIES = roothide
    ios-mcp_CFLAGS += -DMCP_ROOTHIDE=1
    iosmcpprefs_LIBRARIES = roothide
endif

iosmcpprefs_FILES = prefs/IOSMCPRootListController.m prefs/IOSMCPQRCodeCell.m
iosmcpprefs_CFLAGS = -fobjc-arc
iosmcpprefs_FRAMEWORKS = UIKit CoreGraphics
iosmcpprefs_PRIVATE_FRAMEWORKS = Preferences
iosmcpprefs_LDFLAGS = -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
iosmcpprefs_INSTALL_PATH = /Library/PreferenceBundles
iosmcpprefs_RESOURCE_DIRS = prefs/Resources
iosmcpprefs_USE_MODULES = 0

# ollvm相关配置
OLLVMNAME = LLVM19.0.0git
TARGET_CC = /Applications/Xcode.app/Contents/Developer/Toolchains/$(OLLVMNAME).xctoolchain/usr/bin/clang
TARGET_CXX = /Applications/Xcode.app/Contents/Developer/Toolchains/$(OLLVMNAME).xctoolchain/usr/bin/clang++
TARGET_LD = /Applications/Xcode.app/Contents/Developer/Toolchains/$(OLLVMNAME).xctoolchain/usr/bin/clang++
OLLVMPASS = -mllvm -enable-bcfobf -mllvm -enable-cffobf -mllvm -enable-splitobf -mllvm -enable-subobf -mllvm -enable-indibran -mllvm -enable-strcry -mllvm -enable-funcwra -mllvm -enable-fco
ios-mcp_USE_MODULES = 0
ios-mcp-helper_USE_MODULES = 0
ios-mcp_CFLAGS += $(OLLVMPASS)
ios-mcp_CXXFLAGS += $(OLLVMPASS)
ios-mcp-helper_CFLAGS += $(OLLVMPASS)
ios-mcp-helper_CXXFLAGS += $(OLLVMPASS)

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp prefs/entry/ios-mcp.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ios-mcp.plist"$(ECHO_END)
	@# Bundle mcp-appsync (bypass installd signature checks)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)cp AppSync/.theos/obj/mcp-appsync-installd.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/mcp-appsync-installd.dylib"$(ECHO_END)
	$(ECHO_NOTHING)cp AppSync/AppSyncUnified-installd/mcp-appsync-installd.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/mcp-appsync-installd.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp AppSync/.theos/obj/mcp-appsync-frontboard.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/mcp-appsync-frontboard.dylib"$(ECHO_END)
	$(ECHO_NOTHING)cp AppSync/AppSyncUnified-FrontBoard/mcp-appsync-frontboard.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/mcp-appsync-frontboard.plist"$(ECHO_END)
	@# Bundle mcp-appinst (CLI IPA installer)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/usr/bin"$(ECHO_END)
	$(ECHO_NOTHING)cp AppSync/appinst/.theos/obj/mcp-appinst "$(THEOS_STAGING_DIR)/usr/bin/mcp-appinst"$(ECHO_END)
	@# Bundle mcp-roothelper (CLI TrollStore RootHelper wrapper for roothide installs)
	$(ECHO_NOTHING)cp mcp-roothelper/.theos/obj/mcp-roothelper "$(THEOS_STAGING_DIR)/usr/bin/mcp-roothelper"$(ECHO_END)
	@# Bundle mcp-ldid (CLI fakesign helper)
	$(ECHO_NOTHING)cp mcp-ldid/.theos/obj/mcp-ldid "$(THEOS_STAGING_DIR)/usr/bin/mcp-ldid"$(ECHO_END)
	@# Bundle mcp-root (setuid root helper for running commands as root from mobile)
	$(ECHO_NOTHING)cp mcp-root/.theos/obj/mcp-root "$(THEOS_STAGING_DIR)/usr/bin/mcp-root"$(ECHO_END)
	$(ECHO_NOTHING)chmod 4755 "$(THEOS_STAGING_DIR)/usr/bin/mcp-root"$(ECHO_END)

after-install::
	install.exec "killall -9 SpringBoard"
