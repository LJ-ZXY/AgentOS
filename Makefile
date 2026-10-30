# ios-deb: floating AI panel + tool loop.
# It does NOT ship an MCP server; tools come from the on-device ios-mcp
# service over http://127.0.0.1:8090/mcp.

ARCHS = arm64 arm64e
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    TARGET := iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    TARGET := iphone:clang:latest:15.0
else
    TARGET := iphone:clang:latest:13.0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ios-deb
BUNDLE_NAME = iosdebprefs

ios-deb_FILES = Tweak.x \
                IOSDebLog.m \
                IOSDebStore.m \
                IOSDebMCPClient.m \
                IOSDebLLMClient.m \
                IOSDebAgent.m \
                IOSDebSkill.m \
                IOSDebRecorder.m \
                IOSDebFloatingPanel.m

ios-deb_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
ios-deb_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    ios-deb_LIBRARIES = roothide
    ios-deb_CFLAGS += -DMCP_ROOTHIDE=1
    iosdebprefs_LIBRARIES = roothide
else ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    ios-deb_CFLAGS += -DMCP_ROOTLESS=1
endif

iosdebprefs_FILES = prefs/IOSDEBRootListController.m \
                    prefs/IOSDEBLocalization.m
iosdebprefs_CFLAGS = -fobjc-arc
iosdebprefs_FRAMEWORKS = UIKit CoreGraphics
iosdebprefs_PRIVATE_FRAMEWORKS = Preferences
iosdebprefs_LDFLAGS = -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
iosdebprefs_INSTALL_PATH = /Library/PreferenceBundles
iosdebprefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	@# Remap substrate and re-sign so SpringBoard can load the dylib.
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -name "*.dylib" -exec install_name_tool -change /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate @loader_path/.jbroot/usr/lib/libsubstrate.dylib {} + 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -name "*.dylib" -exec ldid -S {} + 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -type f -name "iosdebprefs" -exec ldid -S {} + 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp prefs/entry/ai.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ios-deb.plist"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/usr/share/doc/ios-deb"$(ECHO_END)
	$(ECHO_NOTHING)if [ -f LICENSE ]; then cp LICENSE "$(THEOS_STAGING_DIR)/usr/share/doc/ios-deb/LICENSE"; fi$(ECHO_END)
	$(ECHO_NOTHING)if [ -f NOTICE ]; then cp NOTICE "$(THEOS_STAGING_DIR)/usr/share/doc/ios-deb/NOTICE"; fi$(ECHO_END)

after-install::
	install.exec "killall -9 SpringBoard"
