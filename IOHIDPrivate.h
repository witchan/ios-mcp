#ifndef IOHIDPrivate_h
#define IOHIDPrivate_h

#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach_time.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================
// IOHIDEvent types and opaque references
// ============================================================

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOOptionBits;
typedef double IOHIDFloat;

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// ============================================================
// IOHIDEvent type constants
// ============================================================

enum {
    kIOHIDEventTypeNULL                = 0,
    kIOHIDEventTypeVendorDefined       = 1,
    kIOHIDEventTypeKeyboard            = 3,
    kIOHIDEventTypeDigitizer           = 11,
};

// ============================================================
// IOHIDDigitizer transducer types
// ============================================================

enum {
    kIOHIDDigitizerTransducerTypeStylus  = 0,
    kIOHIDDigitizerTransducerTypePuck    = 1,
    kIOHIDDigitizerTransducerTypeFinger  = 2,
    kIOHIDDigitizerTransducerTypeHand    = 3,
};

// ============================================================
// IOHIDDigitizer event mask bits
// ============================================================

enum {
    kIOHIDDigitizerEventRange           = 1 << 0,
    kIOHIDDigitizerEventTouch           = 1 << 1,
    kIOHIDDigitizerEventPosition        = 1 << 2,
    kIOHIDDigitizerEventStop            = 1 << 3,
    kIOHIDDigitizerEventPeak            = 1 << 4,
    kIOHIDDigitizerEventIdentity        = 1 << 5,
    kIOHIDDigitizerEventAttribute       = 1 << 6,
    kIOHIDDigitizerEventCancel          = 1 << 7,
    kIOHIDDigitizerEventStart           = 1 << 8,
    kIOHIDDigitizerEventResting         = 1 << 9,
};

// ============================================================
// HID Usage Pages
// ============================================================

enum {
    kHIDPage_KeyboardOrKeypad = 0x07,
    kHIDPage_Consumer         = 0x0C,
};

// ============================================================
// HID Consumer Usages
// ============================================================

enum {
    kHIDUsage_Csmr_Power             = 0x30,
    kHIDUsage_Csmr_Menu              = 0x40,   // Home button
    kHIDUsage_Csmr_Mute              = 0xE2,
    kHIDUsage_Csmr_VolumeIncrement   = 0xE9,
    kHIDUsage_Csmr_VolumeDecrement   = 0xEA,
};

// ============================================================
// HID Keyboard/Keypad Usages (page 0x07)
// ============================================================

enum {
    // Letters a-z = 0x04-0x1D
    kHIDUsage_Kbd_A             = 0x04,
    kHIDUsage_Kbd_Z             = 0x1D,
    // Digits 1-9 = 0x1E-0x26, 0 = 0x27
    kHIDUsage_Kbd_1             = 0x1E,
    kHIDUsage_Kbd_0             = 0x27,
    // Special keys
    kHIDUsage_Kbd_ReturnOrEnter = 0x28,
    kHIDUsage_Kbd_Escape        = 0x29,
    kHIDUsage_Kbd_DeleteOrBackspace = 0x2A,
    kHIDUsage_Kbd_Tab           = 0x2B,
    kHIDUsage_Kbd_Spacebar      = 0x2C,
    kHIDUsage_Kbd_Hyphen        = 0x2D,
    kHIDUsage_Kbd_EqualSign     = 0x2E,
    kHIDUsage_Kbd_OpenBracket   = 0x2F,
    kHIDUsage_Kbd_CloseBracket  = 0x30,
    kHIDUsage_Kbd_Backslash     = 0x31,
    kHIDUsage_Kbd_Semicolon     = 0x33,
    kHIDUsage_Kbd_Quote         = 0x34,
    kHIDUsage_Kbd_GraveAccent   = 0x35,
    kHIDUsage_Kbd_Comma         = 0x36,
    kHIDUsage_Kbd_Period        = 0x37,
    kHIDUsage_Kbd_Slash         = 0x38,
    kHIDUsage_Kbd_DeleteForward = 0x4C,
    // Arrow keys
    kHIDUsage_Kbd_RightArrow    = 0x4F,
    kHIDUsage_Kbd_LeftArrow     = 0x50,
    kHIDUsage_Kbd_DownArrow     = 0x51,
    kHIDUsage_Kbd_UpArrow       = 0x52,
    // Modifiers
    kHIDUsage_Kbd_LeftControl   = 0xE0,
    kHIDUsage_Kbd_LeftShift     = 0xE1,
    kHIDUsage_Kbd_LeftAlt       = 0xE2,
    kHIDUsage_Kbd_LeftGUI       = 0xE3,  // Command key
};

// ============================================================
// IOHIDEvent field selectors (for IOHIDEventSetIntegerValue / SetFloatValue)
// ============================================================

enum {
    kIOHIDEventFieldDigitizerX                   = 0xB0001,
    kIOHIDEventFieldDigitizerY                   = 0xB0002,
    kIOHIDEventFieldDigitizerMajorRadius         = 0xB0014,
    kIOHIDEventFieldDigitizerMinorRadius         = 0xB0015,
    kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0xB0018,
};

// ============================================================
// IOHIDEvent creation functions
// ============================================================

IOHIDEventRef IOHIDEventCreateKeyboardEvent(
    CFAllocatorRef allocator,
    uint64_t       timeStamp,
    uint32_t       usagePage,
    uint32_t       usage,
    Boolean        down,
    IOOptionBits   flags
);

IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator,
    uint64_t       timeStamp,
    uint32_t       transducerType,
    uint32_t       index,
    uint32_t       identity,
    uint32_t       eventMask,
    uint32_t       buttonMask,
    IOHIDFloat     x,
    IOHIDFloat     y,
    IOHIDFloat     z,
    IOHIDFloat     tipPressure,
    IOHIDFloat     barrelPressure,
    IOHIDFloat     twist,
    Boolean        range,
    Boolean        touch,
    IOOptionBits   options
);

IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator,
    uint64_t       timeStamp,
    uint32_t       index,
    uint32_t       identity,
    uint32_t       eventMask,
    IOHIDFloat     x,
    IOHIDFloat     y,
    IOHIDFloat     z,
    IOHIDFloat     tipPressure,
    IOHIDFloat     twist,
    Boolean        range,
    Boolean        touch,
    IOOptionBits   options
);

// ============================================================
// IOHIDEvent manipulation
// ============================================================

void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, IOOptionBits options);
void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int32_t value);
void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, IOHIDFloat value);

// ============================================================
// IOHIDEvent accessors
// ============================================================

uint32_t IOHIDEventGetType(IOHIDEventRef event);
uint64_t IOHIDEventGetSenderID(IOHIDEventRef event);

// ============================================================
// IOHIDEventSystemClient
// ============================================================

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

// Callback registration for capturing sender ID
typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon, void *service, IOHIDEventRef event);
void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
void IOHIDEventSystemClientUnscheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client, IOHIDEventSystemClientEventCallback callback, void *target, void *refcon);
void IOHIDEventSystemClientUnregisterEventCallback(IOHIDEventSystemClientRef client);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);

#ifdef __cplusplus
}
#endif

#endif /* IOHIDPrivate_h */
