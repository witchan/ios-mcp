#ifndef AXPrivate_h
#define AXPrivate_h

#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================
// AXUIElement — cross-process accessibility element handle
// ============================================================

typedef const struct __AXUIElement *AXUIElementRef;
typedef int32_t AXError;

enum {
    kAXErrorSuccess                  = 0,
    kAXErrorFailure                  = -25200,
    kAXErrorAttributeUnsupported     = -25205,
    kAXErrorNoValue                  = -25212,
    kAXErrorNotImplemented           = -25208,
};

// ============================================================
// AXUIElement creation
// ============================================================

// Create a root AX element for a given PID (cross-process)
typedef AXUIElementRef (*AXUIElementCreateApplicationFunc)(pid_t pid);

// Create system-wide AX element
typedef AXUIElementRef (*AXUIElementCreateSystemWideFunc)(void);

// ============================================================
// AXUIElement attribute access
// ============================================================

// Copy the value of an attribute
typedef AXError (*AXUIElementCopyAttributeValueFunc)(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value);

// Copy the list of attribute names
typedef AXError (*AXUIElementCopyAttributeNamesFunc)(AXUIElementRef element, CFArrayRef *names);

// Get element at position
typedef AXError (*AXUIElementCopyElementAtPositionFunc)(AXUIElementRef application, float x, float y, AXUIElementRef *element);

// ============================================================
// Common AX attribute name constants
// ============================================================

#define kAXRoleAttribute           CFSTR("AXRole")
#define kAXSubroleAttribute        CFSTR("AXSubrole")
#define kAXLabelAttribute          CFSTR("AXLabel")
#define kAXValueAttribute          CFSTR("AXValue")
#define kAXTitleAttribute          CFSTR("AXTitle")
#define kAXDescriptionAttribute    CFSTR("AXDescription")
#define kAXFrameAttribute          CFSTR("AXFrame")
#define kAXEnabledAttribute        CFSTR("AXEnabled")
#define kAXChildrenAttribute       CFSTR("AXChildren")
#define kAXIdentifierAttribute     CFSTR("AXIdentifier")
#define kAXPlaceholderAttribute    CFSTR("AXPlaceholderValue")
#define kAXTraitsAttribute         CFSTR("AXTraits")
#define kAXFocusedAttribute        CFSTR("AXFocused")
#define kAXSelectedAttribute       CFSTR("AXSelected")

#ifdef __cplusplus
}
#endif

#endif /* AXPrivate_h */
