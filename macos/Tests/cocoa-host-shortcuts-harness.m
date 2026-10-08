#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <stdbool.h>
#include <assert.h>
#include <stdio.h>
#define COCOA_DEBUG(...) ((void)0)
typedef int InputButton;
enum { KEY_LEFTSHIFT=128, KEY_RIGHTSHIFT, KEY_LEFTCTRL, KEY_RIGHTCTRL,
       KEY_LEFTALT, KEY_RIGHTALT, KEY_LEFTMETA, KEY_RIGHTMETA, KEY_CAPSLOCK };
enum { QKBD_MOD_CAPSLOCK };
static struct { bool held[256]; bool caps; } keyboard, *kbd=&keyboard;
static bool swap_opt_cmd=false, left_command_key_enabled=true;
static struct { void *con; } dcl;
static bool qkbd_state_modifier_get(void *unused, int modifier) { return keyboard.caps; }
static void qkbd_state_key_event(void *unused, unsigned int key, bool down) {
    assert(key < 256);
    if (key==KEY_CAPSLOCK && down && !keyboard.held[key]) keyboard.caps=!keyboard.caps;
    keyboard.held[key]=down;
}
static bool qemu_console_is_graphic(void *unused) { return true; }
static unsigned int cocoa_keycode_to_linux(unsigned short key) { return key; }
/* HELPERS */
@interface QemuCocoaView : NSObject
@property BOOL captured;
- (BOOL)isKeyboardCaptured;
- (bool)handleEvent:(NSEvent *)event;
- (bool)handleEventLocked:(NSEvent *)event;
- (bool)handleInjectedText:(NSEvent *)event;
- (void)toggleKey:(int)key;
- (void)raiseAllKeys;
- (void)reenableEventTap;
- (void)selectConsoleLocked:(int)console;
- (void)ungrabMouse;
- (void)handleMonitorInput:(NSEvent *)event;
@end
@implementation QemuCocoaView
- (BOOL)isKeyboardCaptured { return self.captured; }
- (bool)handleEvent:(NSEvent *)event { return [self handleEventLocked:event]; }
- (bool)handleInjectedText:(NSEvent *)event { return false; }
- (void)toggleKey:(int)key { qkbd_state_key_event(kbd,key,!keyboard.held[key]); }
- (void)raiseAllKeys { for(int key=0;key<256;key++) qkbd_state_key_event(kbd,key,false); }
- (void)reenableEventTap {}
- (void)selectConsoleLocked:(int)console {}
- (void)ungrabMouse { self.captured=NO; }
- (void)handleMonitorInput:(NSEvent *)event {}
/* METHOD */
@end
/* TAP */
static void route(QemuCocoaView *view, unsigned short key, CGEventType type,
                  CGEventFlags flags, bool repeat, bool host, bool reserved)
{
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, key, type != kCGEventKeyUp);
    CGEventSetType(event, type);
    CGEventSetFlags(event, flags);
    CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, repeat);
    CGEventRef result = handleTapEvent(NULL, type, event, view);
    assert(result == (host ? event : NULL));
    if (result && view.captured) {
        /* Exercise the actual consumer when AppKit sees the same event. */
        assert([view handleEvent:[NSEvent eventWithCGEvent:event]]);
    }
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        assert(cocoa_is_host_shortcut([NSEvent eventWithCGEvent:event]) == reserved);
        assert(keyboard.held[key] == (!reserved && type == kCGEventKeyDown));
    }
    CFRelease(event);
}

static void assert_released(void)
{
    for (int key = 0; key < 256; key++) {
        assert(!keyboard.held[key]);
    }
    assert(host_shortcut_modifiers == 0);
}

int main(void)
{
    @autoreleasepool {
        QemuCocoaView *view = [QemuCocoaView new];
        view.captured = YES;
        CGEventFlags cmd = kCGEventFlagMaskCommand;
        CGEventFlags ctrl = kCGEventFlagMaskControl;
        CGEventFlags shift = kCGEventFlagMaskShift;
        CGEventFlags option = kCGEventFlagMaskAlternate;

        /* Modifier-up must reach the host even when Tab was released first. */
        route(view, kVK_Command, kCGEventFlagsChanged, cmd, false, false, false);
        assert(keyboard.held[KEY_LEFTMETA]);
        route(view, kVK_Tab, kCGEventKeyDown, cmd, false, true, true);
        assert(!keyboard.held[kVK_Tab] && keyboard.held[KEY_LEFTMETA]);
        route(view, kVK_Tab, kCGEventKeyDown, cmd, true, true, true);
        route(view, kVK_Tab, kCGEventKeyUp, cmd, false, true, true);
        /* A pending host chord must not bypass other guest keys/modifiers. */
        route(view, kVK_Shift, kCGEventFlagsChanged, cmd | shift, false, false, false);
        assert(keyboard.held[KEY_LEFTSHIFT]);
        route(view, kVK_Shift, kCGEventFlagsChanged, cmd, false, false, false);
        assert(!keyboard.held[KEY_LEFTSHIFT]);
        route(view, kVK_Space, kCGEventKeyDown, cmd, false, false, false);
        assert(keyboard.held[kVK_Space] && keyboard.held[KEY_LEFTMETA]);
        route(view, kVK_Space, kCGEventKeyUp, cmd, false, false, false);
        route(view, kVK_Return, kCGEventKeyDown, cmd, false, false, false);
        route(view, kVK_Return, kCGEventKeyUp, cmd, false, false, false);
        route(view, kVK_Command, kCGEventFlagsChanged, 0, false, true, false);
        assert_released();

        /* Reverse switching, modifier-first release, and focus loss. */
        route(view, kVK_Command, kCGEventFlagsChanged, cmd, false, false, false);
        route(view, kVK_Shift, kCGEventFlagsChanged, cmd | shift, false, false, false);
        assert(keyboard.held[KEY_LEFTMETA] && keyboard.held[KEY_LEFTSHIFT]);
        route(view, kVK_Tab, kCGEventKeyDown, cmd | shift, false, true, true);
        view.captured = NO;
        [view raiseAllKeys]; /* Upstream windowDidResignKey cleanup. */
        route(view, kVK_Control, kCGEventFlagsChanged, cmd | shift | ctrl,
              false, true, false);
        assert(!keyboard.held[KEY_LEFTCTRL] && !keyboard.held[KEY_LEFTSHIFT]);
        route(view, kVK_Command, kCGEventFlagsChanged, shift | ctrl, false, true, false);
        view.captured = YES;
        route(view, kVK_Tab, kCGEventKeyDown, 0, true, true, true);
        route(view, kVK_Tab, kCGEventKeyUp, 0, false, true, true);
        assert_released();

        /* A guest press cannot be stolen when modifiers change mid-repeat. */
        route(view, kVK_Tab, kCGEventKeyDown, 0, false, false, false);
        route(view, kVK_Tab, kCGEventKeyDown, cmd, true, false, false);
        route(view, kVK_Tab, kCGEventKeyUp, cmd, false, false, false);
        route(view, kVK_Tab, kCGEventKeyDown, cmd | option, false, false, false);
        route(view, kVK_Tab, kCGEventKeyUp, 0, false, false, false);
        route(view, kVK_Tab, kCGEventKeyDown, cmd | ctrl, false, false, false);
        route(view, kVK_Tab, kCGEventKeyUp, 0, false, false, false);
        route(view, kVK_Tab, kCGEventKeyDown, cmd | kCGEventFlagMaskSecondaryFn,
              false, false, false);
        route(view, kVK_Tab, kCGEventKeyUp, 0, false, false, false);

        /* Caps Lock is a lock state, not an extra shortcut modifier. */
        route(view, kVK_Tab, kCGEventKeyDown, cmd | kCGEventFlagMaskAlphaShift,
              false, true, true);
        route(view, kVK_Command, kCGEventFlagsChanged, 0, false, true, false);
        route(view, kVK_Tab, kCGEventKeyUp, 0, false, true, true);

        route(view, kVK_Control, kCGEventFlagsChanged, ctrl, false, false, false);
        assert(keyboard.held[KEY_LEFTCTRL]);
        route(view, kVK_ANSI_Grave, kCGEventKeyDown, ctrl, false, true, true);
        route(view, kVK_ANSI_Grave, kCGEventKeyDown, ctrl, true, true, true);
        route(view, kVK_Control, kCGEventFlagsChanged, 0, false, true, false);
        route(view, kVK_ANSI_Grave, kCGEventKeyUp, 0, false, true, true);
        assert_released();
        route(view, kVK_ANSI_Grave, kCGEventKeyDown, ctrl | shift, false, false, false);
        route(view, kVK_ANSI_Grave, kCGEventKeyUp, 0, false, false, false);
        route(view, kVK_ANSI_Grave, kCGEventKeyDown, ctrl | option, false, false, false);
        route(view, kVK_ANSI_Grave, kCGEventKeyUp, 0, false, false, false);
        route(view, kVK_ANSI_Grave, kCGEventKeyDown, 0, false, false, false);
        route(view, kVK_ANSI_Grave, kCGEventKeyUp, 0, false, false, false);

        route(view, kVK_Space, kCGEventKeyDown, cmd, false, false, false);
        route(view, kVK_Space, kCGEventKeyUp, 0, false, false, false);
        route(view, kVK_Return, kCGEventKeyDown, cmd, false, false, false);
        route(view, kVK_Return, kCGEventKeyUp, 0, false, false, false);
        assert_released();
        puts("PASS: host shortcut presses, repeats, release ordering, focus changes, and exact modifiers");
    }
    return 0;
}
