//
//  EndfieldGamepadMap.m
//  PlayTools
//
//  See EndfieldGamepadMap.h. The game's DeviceInfo.platform decides what the view button does:
//    platform 2 -> desktop binding (view button switches input mode)
//    platform 8 -> mobile binding  (view button opens the map)
//  While the game is in gamepad mode (inputType == 2) nothing keeps platform at 8, so the map
//  key breaks.
//
//  Two mechanisms, both aimed at the same field:
//
//    * An event hook on the game's own device decision. Beyond.Input.InputManager
//      .CheckUsingController is the managed method that switches the input device; it is
//      resolved by name and its entry replaced. After the game has decided, this module mirrors
//      the decision into DeviceInfo.platform, so the switch is immediate (no guardian lag).
//      Being a managed method resolved by name, this works on any build - the CN and
//      international binaries share the same managed code.
//    * A slow guardian. The game can still move `platform` without a switch, so a 10 s timer
//      re-asserts 8 while inputType == 2. It is the safety net for anything the hook misses.
//
//  A key press while the game is in gamepad mode releases platform to 2 for a moment - the
//  game's own switch back to keyboard/mouse needs that - and the hook/guardian leave the field
//  alone for that window.
//
//  Shared Endfield plumbing (il2cpp lookup by name, static fields, logging, bundle gate, memory
//  writes) lives in EndfieldRuntime; this module only owns the gamepad logic.
//
//    DeviceInfo static fields: platform @ +0x24, inputType @ +0x28
//

#import "EndfieldGamepadMap.h"
#import "EndfieldRuntime.h"

#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <time.h>

#define EF_OFF_PLATFORM            0x24
#define EF_OFF_INPUTTYPE           0x28

#define EF_INPUTTYPE_GAMEPAD 2
#define EF_PLATFORM_DESKTOP  2
#define EF_PLATFORM_MOBILE   8

// While a key is being pressed the hook and guardian leave platform alone for a moment, so the
// game can run its own switch back to keyboard/mouse (see EndfieldGamepadMapKeyboardActivity).
static volatile int64_t ef_suppress_until_ns = 0;

// Native entry of CheckUsingController saved when the hook is installed.
static void *ef_check_original = NULL;

/// Monotonic nanoseconds; used only for the short window after a key press.
static int64_t ef_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void *ef_static_fields(void) {
    static void *cached = NULL;
    if (cached != NULL) { return cached; }
    void *klass = EndfieldRuntimeClass("Beyond", "DeviceInfo");
    if (klass == NULL) { return NULL; }
    cached = EndfieldRuntimeStaticFieldData(klass);
    return cached;
}

static int ef_read(int offset) {
    void *fields = ef_static_fields();
    if (fields == NULL) { return -1; }
    return *(volatile int *)((char *)fields + offset);
}

static void ef_write(int offset, int value) {
    void *fields = ef_static_fields();
    if (fields == NULL) { return; }
    *(volatile int *)((char *)fields + offset) = value;
}

/// Hold platform at 8 while the game is in gamepad mode. Idempotent and cheap: in steady state
/// the `platform == 8` check returns without writing, so this does no work per frame.
static void ef_force_platform_if_gamepad(void) {
    if (ef_read(EF_OFF_INPUTTYPE) != EF_INPUTTYPE_GAMEPAD) { return; }
    if (ef_read(EF_OFF_PLATFORM) == EF_PLATFORM_MOBILE) { return; }
    if (ef_now_ns() < ef_suppress_until_ns) { return; }   // a key press is in flight
    ef_write(EF_OFF_PLATFORM, EF_PLATFORM_MOBILE);
}

/// Replacement for Beyond.Input.InputManager.CheckUsingController. Runs the game's own check
/// first, then mirrors the resulting device into platform.
static void ef_check_using_controller(void *self) {
    void *original = ef_check_original;
    if (original == NULL) { return; }
    ((void (*)(void *))original)(self);
    ef_force_platform_if_gamepad();
}

/// Installs the managed hook. Idempotent; returns NO whenever it cannot be sure of itself (the
/// engine is not ready, the class/method is missing, the write is refused) - the guardian keeps
/// running either way.
static BOOL ef_install_device_hook(void) {
    if (ef_check_original != NULL) { return YES; }

    void *klass = EndfieldRuntimeClass("Beyond.Input", "InputManager");
    void *method = EndfieldRuntimeMethod(klass, "CheckUsingController", 0);
    void *original = EndfieldRuntimeMethodPointer(method);
    if (original == NULL) { return NO; }

    void *previous = EndfieldRuntimeHookMethod(method, (void *)ef_check_using_controller);
    if (previous == NULL) {
        EndfieldRuntimeLog(@"[ZEF] gamepad map: CheckUsingController hook write failed");
        return NO;
    }
    ef_check_original = previous;
    EndfieldRuntimeLog(@"[ZEF] gamepad map: CheckUsingController hook installed @ %p", previous);
    return YES;
}

@interface EFGamepadMap : NSObject @end
@implementation EFGamepadMap

// The source must outlive +start: under ARC a bare local dispatch_source_t is released on
// return and cancelled before it can fire. Keep the strong reference here instead.
static dispatch_source_t ef_timer = nil;

// The key monitor token must be retained too: releasing the returned token removes the monitor.
static id ef_key_monitor = nil;

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        EndfieldRuntimeLog(@"[ZEF] gamepad map: start");

        // Watch real key presses. This must not depend on PlayTools' keymapping being enabled:
        // ControlMode only installs its keyboard handler when keymapping is on, and Endfield runs
        // with it off. The framework is compiled against the iOS SDK (no AppKit headers), so
        // NSEvent is reached through the ObjC runtime; the app runs on macOS, where it exists.
        Class nsEvent = objc_getClass("NSEvent");
        SEL addMonitor = sel_registerName("addLocalMonitorForEventsMatchingMask:handler:");
        if (nsEvent != Nil) {
            NSUInteger keyDownMask = 1 << 10; // NSEventMaskKeyDown
            id (^handler)(id) = ^id(id event) {
                EndfieldGamepadMapKeyboardActivity();
                return event;
            };
            ef_key_monitor = ((id (*)(id, SEL, NSUInteger, id))objc_msgSend)((id)nsEvent,
                                                                            addMonitor,
                                                                            keyDownMask,
                                                                            handler);
        }

        // A private queue, not the main queue: Unity does not service the main dispatch queue
        // on its own (PlayTools drains it with a CADisplayLink), so this must not depend on it.
        dispatch_queue_t queue = dispatch_queue_create("playcover.endfield.gamepadmap",
                                                       DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        // Startup cadence is 1 s, so the hook is installed and the initial platform corrected as
        // soon as the engine is reachable. It is re-armed to the guardian's 10 s once the hook
        // is in place - the hook is what makes a switch instant, the guardian is only a net.
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  (uint64_t)(1.0 * NSEC_PER_SEC), 0);
        __block NSInteger ticks = 0;
        __block BOOL reportedNotReady = NO;
        __block BOOL guardianCadence = NO;
        dispatch_source_set_event_handler(timer, ^{
            ticks += 1;
            if (ef_static_fields() == NULL) {
                if (!reportedNotReady) {
                    reportedNotReady = YES;
                    EndfieldRuntimeLog(@"[ZEF] gamepad map: DeviceInfo not ready");
                }
                return;
            }
            if (ef_check_original == NULL && ef_install_device_hook()) {
                guardianCadence = YES;
                dispatch_source_set_timer(timer,
                                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                                          (uint64_t)(10.0 * NSEC_PER_SEC), 0);
            }
            int inputType = ef_read(EF_OFF_INPUTTYPE);
            int platform = ef_read(EF_OFF_PLATFORM);
            // One state line a minute (12 s startup, 60 s guardian); it doubles as the heartbeat.
            if (ticks % (guardianCadence ? 6 : 12) == 0) {
                EndfieldRuntimeLog(@"[ZEF] gamepad map: inputType=%d platform=%d",
                                   inputType, platform);
            }
            if (inputType != EF_INPUTTYPE_GAMEPAD) {
                // Left gamepad mode: drop any key-press suppression so switching back is
                // corrected immediately.
                ef_suppress_until_ns = 0;
            } else if (platform != EF_PLATFORM_MOBILE && ef_now_ns() >= ef_suppress_until_ns) {
                ef_write(EF_OFF_PLATFORM, EF_PLATFORM_MOBILE);
                EndfieldRuntimeLog(@"[ZEF] gamepad map: platform %d -> 8 (guardian)", platform);
            }
        });
        ef_timer = timer;
        dispatch_resume(timer);
    });
}

@end

void EndfieldGamepadMapStart(void) {
    // Endfield only - the entry point is shared by every game PlayTools launches.
    if (!EndfieldRuntimeIsGame()) {
        return;
    }
    [EFGamepadMap start];
}

void EndfieldGamepadMapKeyboardActivity(void) {
    // Called on a real key press. While the game is in gamepad mode the hook holds platform
    // at 8 (mobile binding), which keeps the keyboard out of the device set, so the game never
    // runs its own switch back to keyboard/mouse. Release platform to 2 for a short window and
    // let the game switch; if it does not, the hook/guardian restores 8 afterwards.
    if (ef_read(EF_OFF_INPUTTYPE) != EF_INPUTTYPE_GAMEPAD) { return; }
    if (ef_read(EF_OFF_PLATFORM) != EF_PLATFORM_MOBILE) { return; }
    ef_write(EF_OFF_PLATFORM, EF_PLATFORM_DESKTOP);
    ef_suppress_until_ns = ef_now_ns() + 3LL * 1000000000LL;
    EndfieldRuntimeLog(@"[ZEF] gamepad map: keyboard activity -> platform 8 -> 2");
}
