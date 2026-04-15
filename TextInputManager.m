#import "TextInputManager.h"
#import "HIDManager.h"
#import "IOHIDPrivate.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>

#define TI_LOG(fmt, ...) NSLog(@"[witchan][ios-mcp][TextInput] " fmt, ##__VA_ARGS__)

#define SYNTHETIC_SENDER_ID 0xDEFACEDBEEFFECE5ULL

// ============================================================
// ASCII to HID usage mapping (US keyboard layout)
// ============================================================

typedef struct {
    uint32_t usage;
    BOOL     shift;
} KeyMapping;

static KeyMapping _asciiToHID[128];
static BOOL _mappingInitialized = NO;

static void initKeyMapping(void) {
    if (_mappingInitialized) return;
    _mappingInitialized = YES;

    memset(_asciiToHID, 0, sizeof(_asciiToHID));

    // Lowercase letters a-z
    for (char c = 'a'; c <= 'z'; c++) {
        _asciiToHID[(int)c] = (KeyMapping){kHIDUsage_Kbd_A + (c - 'a'), NO};
    }
    // Uppercase letters A-Z (shift + letter)
    for (char c = 'A'; c <= 'Z'; c++) {
        _asciiToHID[(int)c] = (KeyMapping){kHIDUsage_Kbd_A + (c - 'A'), YES};
    }
    // Digits 1-9
    for (char c = '1'; c <= '9'; c++) {
        _asciiToHID[(int)c] = (KeyMapping){kHIDUsage_Kbd_1 + (c - '1'), NO};
    }
    _asciiToHID['0'] = (KeyMapping){kHIDUsage_Kbd_0, NO};

    // Shift+digit symbols
    _asciiToHID['!'] = (KeyMapping){kHIDUsage_Kbd_1 + 0, YES};  // Shift+1
    _asciiToHID['@'] = (KeyMapping){kHIDUsage_Kbd_1 + 1, YES};  // Shift+2
    _asciiToHID['#'] = (KeyMapping){kHIDUsage_Kbd_1 + 2, YES};  // Shift+3
    _asciiToHID['$'] = (KeyMapping){kHIDUsage_Kbd_1 + 3, YES};  // Shift+4
    _asciiToHID['%'] = (KeyMapping){kHIDUsage_Kbd_1 + 4, YES};  // Shift+5
    _asciiToHID['^'] = (KeyMapping){kHIDUsage_Kbd_1 + 5, YES};  // Shift+6
    _asciiToHID['&'] = (KeyMapping){kHIDUsage_Kbd_1 + 6, YES};  // Shift+7
    _asciiToHID['*'] = (KeyMapping){kHIDUsage_Kbd_1 + 7, YES};  // Shift+8
    _asciiToHID['('] = (KeyMapping){kHIDUsage_Kbd_1 + 8, YES};  // Shift+9
    _asciiToHID[')'] = (KeyMapping){kHIDUsage_Kbd_0, YES};       // Shift+0

    // Special characters
    _asciiToHID[' ']  = (KeyMapping){kHIDUsage_Kbd_Spacebar, NO};
    _asciiToHID['\n'] = (KeyMapping){kHIDUsage_Kbd_ReturnOrEnter, NO};
    _asciiToHID['\t'] = (KeyMapping){kHIDUsage_Kbd_Tab, NO};
    _asciiToHID['-']  = (KeyMapping){kHIDUsage_Kbd_Hyphen, NO};
    _asciiToHID['_']  = (KeyMapping){kHIDUsage_Kbd_Hyphen, YES};
    _asciiToHID['=']  = (KeyMapping){kHIDUsage_Kbd_EqualSign, NO};
    _asciiToHID['+']  = (KeyMapping){kHIDUsage_Kbd_EqualSign, YES};
    _asciiToHID['[']  = (KeyMapping){kHIDUsage_Kbd_OpenBracket, NO};
    _asciiToHID['{']  = (KeyMapping){kHIDUsage_Kbd_OpenBracket, YES};
    _asciiToHID[']']  = (KeyMapping){kHIDUsage_Kbd_CloseBracket, NO};
    _asciiToHID['}']  = (KeyMapping){kHIDUsage_Kbd_CloseBracket, YES};
    _asciiToHID['\\'] = (KeyMapping){kHIDUsage_Kbd_Backslash, NO};
    _asciiToHID['|']  = (KeyMapping){kHIDUsage_Kbd_Backslash, YES};
    _asciiToHID[';']  = (KeyMapping){kHIDUsage_Kbd_Semicolon, NO};
    _asciiToHID[':']  = (KeyMapping){kHIDUsage_Kbd_Semicolon, YES};
    _asciiToHID['\''] = (KeyMapping){kHIDUsage_Kbd_Quote, NO};
    _asciiToHID['"']  = (KeyMapping){kHIDUsage_Kbd_Quote, YES};
    _asciiToHID['`']  = (KeyMapping){kHIDUsage_Kbd_GraveAccent, NO};
    _asciiToHID['~']  = (KeyMapping){kHIDUsage_Kbd_GraveAccent, YES};
    _asciiToHID[',']  = (KeyMapping){kHIDUsage_Kbd_Comma, NO};
    _asciiToHID['<']  = (KeyMapping){kHIDUsage_Kbd_Comma, YES};
    _asciiToHID['.']  = (KeyMapping){kHIDUsage_Kbd_Period, NO};
    _asciiToHID['>']  = (KeyMapping){kHIDUsage_Kbd_Period, YES};
    _asciiToHID['/']  = (KeyMapping){kHIDUsage_Kbd_Slash, NO};
    _asciiToHID['?']  = (KeyMapping){kHIDUsage_Kbd_Slash, YES};
}

static BOOL textNeedsPasteboardFallback(NSString *text) {
    initKeyMapping();

    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        if (ch >= 128 || _asciiToHID[ch].usage == 0) {
            return YES;
        }
    }
    return NO;
}

@implementation TextInputManager {
    IOHIDEventSystemClientRef _hidClient;
    dispatch_queue_t _inputQueue;
}

+ (instancetype)sharedInstance {
    static TextInputManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TextInputManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _inputQueue = dispatch_queue_create("com.witchan.ios-mcp.textinput", DISPATCH_QUEUE_SERIAL);
        _hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        initKeyMapping();
    }
    return self;
}

#pragma mark - Bulk Text Input (Pasteboard)

- (void)inputText:(NSString *)text completion:(void (^)(BOOL, NSString *))completion {
    if (!text.length) {
        if (completion) completion(NO, @"Empty text");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        NSArray *savedPasteboardItems = pasteboard.items;

        // Write text to pasteboard
        pasteboard.string = text;

        // Simulate Cmd+V (paste) via HID keyboard
        dispatch_async(self->_inputQueue, ^{
            // Key down: Left GUI (Command)
            [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:kHIDUsage_Kbd_LeftGUI down:YES];
            usleep(30000);
            // Key down: V
            [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:(kHIDUsage_Kbd_A + ('v' - 'a')) down:YES];
            usleep(30000);
            // Key up: V
            [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:(kHIDUsage_Kbd_A + ('v' - 'a')) down:NO];
            usleep(30000);
            // Key up: Left GUI
            [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:kHIDUsage_Kbd_LeftGUI down:NO];
            usleep(350000); // Wait for paste to complete before restoring clipboard

            // Restore clipboard
            dispatch_async(dispatch_get_main_queue(), ^{
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                if (savedPasteboardItems.count > 0) {
                    pasteboard.items = savedPasteboardItems;
                } else {
                    pasteboard.items = @[];
                }
            });

            if (completion) completion(YES, nil);
        });
    });
}

#pragma mark - Character-by-Character Typing

- (void)typeText:(NSString *)text delayMs:(NSTimeInterval)delayMs completion:(void (^)(BOOL, NSString *))completion {
    if (!text.length) {
        if (completion) completion(NO, @"Empty text");
        return;
    }

    if (textNeedsPasteboardFallback(text)) {
        TI_LOG(@"Using pasteboard fallback for text containing non-ASCII or unsupported HID characters");
        [self inputText:text completion:^(BOOL success, NSString *error) {
            if (!success) {
                if (completion) completion(NO, error ?: @"Pasteboard fallback failed");
                return;
            }

            if (completion) completion(YES, @"Used pasteboard fallback for non-ASCII or unsupported text");
        }];
        return;
    }

    if (delayMs <= 0) delayMs = 50;

    dispatch_async(_inputQueue, ^{
        useconds_t delay = (useconds_t)(delayMs * 1000);

        for (NSUInteger i = 0; i < text.length; i++) {
            unichar ch = [text characterAtIndex:i];

            KeyMapping mapping = _asciiToHID[ch];

            // Press shift if needed
            if (mapping.shift) {
                [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:kHIDUsage_Kbd_LeftShift down:YES];
                usleep(20000);
            }

            // Key down
            [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:mapping.usage down:YES];
            usleep(20000);
            // Key up
            [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:mapping.usage down:NO];

            // Release shift if needed
            if (mapping.shift) {
                usleep(20000);
                [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:kHIDUsage_Kbd_LeftShift down:NO];
            }

            usleep(delay);
        }

        if (completion) completion(YES, nil);
    });
}

#pragma mark - Special Key Press

- (void)pressKey:(NSString *)keyName completion:(void (^)(BOOL, NSString *))completion {
    NSString *key = keyName.lowercaseString;
    uint32_t usage = 0;

    if ([key isEqualToString:@"enter"] || [key isEqualToString:@"return"]) {
        usage = kHIDUsage_Kbd_ReturnOrEnter;
    } else if ([key isEqualToString:@"tab"]) {
        usage = kHIDUsage_Kbd_Tab;
    } else if ([key isEqualToString:@"escape"] || [key isEqualToString:@"esc"]) {
        usage = kHIDUsage_Kbd_Escape;
    } else if ([key isEqualToString:@"delete"] || [key isEqualToString:@"del"]) {
        usage = kHIDUsage_Kbd_DeleteForward;
    } else if ([key isEqualToString:@"backspace"]) {
        usage = kHIDUsage_Kbd_DeleteOrBackspace;
    } else if ([key isEqualToString:@"space"]) {
        usage = kHIDUsage_Kbd_Spacebar;
    } else if ([key isEqualToString:@"up"]) {
        usage = kHIDUsage_Kbd_UpArrow;
    } else if ([key isEqualToString:@"down"]) {
        usage = kHIDUsage_Kbd_DownArrow;
    } else if ([key isEqualToString:@"left"]) {
        usage = kHIDUsage_Kbd_LeftArrow;
    } else if ([key isEqualToString:@"right"]) {
        usage = kHIDUsage_Kbd_RightArrow;
    } else {
        if (completion) completion(NO, [NSString stringWithFormat:@"Unknown key: %@", keyName]);
        return;
    }

    dispatch_async(_inputQueue, ^{
        [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:usage down:YES];
        usleep(50000);
        [self sendKeyEvent:kHIDPage_KeyboardOrKeypad usage:usage down:NO];

        if (completion) completion(YES, nil);
    });
}

#pragma mark - HID Key Event

- (void)sendKeyEvent:(uint32_t)usagePage usage:(uint32_t)usage down:(BOOL)down {
    if (!_hidClient) return;

    IOHIDEventRef event = IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault,
        mach_absolute_time(),
        usagePage,
        usage,
        down,
        0
    );
    if (!event) return;

    IOHIDEventSetSenderID(event, SYNTHETIC_SENDER_ID);
    IOHIDEventSystemClientDispatchEvent(_hidClient, event);
    CFRelease(event);
}

@end
