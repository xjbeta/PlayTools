//
//  EndfieldGamepadMap.m
//  PlayTools
//
//  See EndfieldGamepadMap.h.
//
//  DeviceInfo.isMobile decides whether the whole game behaves like a mobile device (Unity
//  InputSystem) or a desktop one (Rewired): the gamepad buttons, the analog triggers, and the
//  in-game screens that hand gamepad buttons to their UI (the gacha screen among them). On this
//  machine DeviceInfo.platform is 2 (PC), so isMobile is false and the game takes the desktop
//  path, where the view button means "menu" and some screens never see the buttons they expect.
//
//  This module rewrites DeviceInfo.get_isMobile to answer from the current input mode: true while
//  the game is being played with the pad (inputType == 2) and the desktop answer otherwise. The
//  replacement is a small trampoline written over the method entry that calls the game's own
//  DeviceInfo.get_inputType:
//
//      stp  x29, x30, [sp, #-16]!      ; save LR: the bl below overwrites it
//      bl   DeviceInfo.get_inputType
//      ldp  x29, x30, [sp], #16
//      cmp  w0, #2
//      cset w0, eq
//      ret
//
//  So the gamepad - buttons, triggers and the screens that use them - gets the mobile behaviour
//  while a pad is in use, and keyboard/mouse play is left alone. The real isMobile (platform 8 /
//  11) is deliberately not consulted: platform is 2 here, so the input mode is the whole story.
//
//  isMobile is also what DeviceInfo.get_supportsTouch answers, and the game's CheckUsingController
//  only looks at supportsTouch to choose whether to watch the touch or the keyboard for a device
//  change. Left alone, supportsTouch would be true whenever the pad is in use, so the game would
//  watch the touch branch (touchCount only) and a key press would never switch it back. Only the
//  gamepad and keyboard/mouse modes are wanted here, so supportsTouch is pinned to false:
//
//      mov  w0, #0
//      ret
//
//  Everything is resolved by name; a game update degrades to "no patch".
//

#import "EndfieldGamepadMap.h"
#import "EndfieldRuntime.h"

#import <Foundation/Foundation.h>

#define EF_INPUTTYPE_GAMEPAD 2

// stp x29, x30, [sp, #-16]! ; bl <get_inputType> ; ldp x29, x30, [sp], #16 ; cmp w0,#2 ;
// cset w0, eq ; ret
static const uint32_t EF_STP_LR   = 0xA9BF7BFDu;
static const uint32_t EF_LDP_LR   = 0xA8C17BFDu;
static const uint32_t EF_CMP_W0_2 = 0x7100081Fu;
static const uint32_t EF_CSET_EQ  = 0x1A9F17E0u;
static const uint32_t EF_MOV_W0_0 = 0x52800000u;
static const uint32_t EF_RET      = 0xD65F03C0u;

// Set once the patch has landed, so the timer stops retrying.
static BOOL ef_done = NO;

static uint32_t ef_u32(const void *p) { return *(const uint32_t *)p; }

/// Encode `bl` from `from` to `to`; 0 when out of reach.
static uint32_t ef_bl_encode(uintptr_t from, uintptr_t to) {
    int64_t delta = (int64_t)to - (int64_t)from;
    if (delta % 4 != 0) { return 0; }
    int64_t words = delta >> 2;
    if (words < -(1 << 25) || words >= (1 << 25)) { return 0; }
    return 0x94000000u | (uint32_t)(words & 0x3FFFFFF);
}

/// Rewrite DeviceInfo.get_isMobile to return `inputType == 2`, so the game takes the mobile path
/// while a gamepad is in use and the desktop path otherwise. Returns YES once the patch is in
/// place and NO while it cannot be reached.
static BOOL ef_patch_is_mobile(void) {
    if (ef_done) { return YES; }

    void *device = EndfieldRuntimeClass("Beyond", "DeviceInfo");
    if (device == NULL) { return NO; }
    uintptr_t isMobile = (uintptr_t)EndfieldRuntimeMethodPointer(
        EndfieldRuntimeMethod(device, "get_isMobile", 0));
    uintptr_t inputType = (uintptr_t)EndfieldRuntimeMethodPointer(
        EndfieldRuntimeMethod(device, "get_inputType", 0));
    if (isMobile == 0 || inputType == 0) { return NO; }

    uint32_t call = ef_bl_encode(isMobile + 4, inputType);   // bl sits at entry+4
    if (call == 0) { return NO; }
    uint32_t code[6] = { EF_STP_LR, call, EF_LDP_LR, EF_CMP_W0_2, EF_CSET_EQ, EF_RET };

    BOOL already = YES;
    for (int i = 0; i < 6; i++) {
        if (ef_u32((const void *)(isMobile + (uintptr_t)i * 4)) != code[i]) { already = NO; break; }
    }
    if (already) {
        ef_done = YES;
        return YES;
    }
    if (EndfieldRuntimeWriteMemory((void *)isMobile, code, sizeof(code))) {
        ef_done = YES;
        EndfieldRuntimeLog(@"[ZEF] gamepad map: isMobile -> (inputType==%d) @ %p",
                           EF_INPUTTYPE_GAMEPAD, (void *)isMobile);
        return YES;
    }
    return NO;
}

/// Pin DeviceInfo.get_supportsTouch to false.
///
/// supportsTouch is DeviceInfo.isMobile (SupportsInputType(Touch)); the game's
/// CheckUsingController only looks at supportsTouch to choose which branch watches for a device
/// change. While isMobile is true (gamepad), supportsTouch would also be true, so the game takes
/// the touch branch - which only watches touchCount - and a key press is never seen, leaving the
/// game stuck in gamepad mode. We keep only the gamepad and keyboard/mouse modes here, so touch is
/// pinned off: the keyboard branch runs and the switch target resolves to keyboard/mouse.
static BOOL ef_patch_supports_touch(void) {
    static BOOL done = NO;
    if (done) { return YES; }

    void *device = EndfieldRuntimeClass("Beyond", "DeviceInfo");
    if (device == NULL) { return NO; }
    uintptr_t supportsTouch = (uintptr_t)EndfieldRuntimeMethodPointer(
        EndfieldRuntimeMethod(device, "get_supportsTouch", 0));
    if (supportsTouch == 0) { return NO; }

    uint32_t code[2] = { EF_MOV_W0_0, EF_RET };   // mov w0, #0 ; ret
    if (ef_u32((const void *)supportsTouch) == code[0] &&
        ef_u32((const void *)(supportsTouch + 4)) == code[1]) {
        done = YES;
        return YES;
    }
    if (EndfieldRuntimeWriteMemory((void *)supportsTouch, code, sizeof(code))) {
        done = YES;
        EndfieldRuntimeLog(@"[ZEF] gamepad map: supportsTouch -> false @ %p", (void *)supportsTouch);
        return YES;
    }
    return NO;
}

@interface EFGamepadMap : NSObject @end
@implementation EFGamepadMap

// The source must outlive +start: under ARC a bare local dispatch_source_t is released on
// return and cancelled before it can fire. Keep the strong reference here instead.
static dispatch_source_t ef_timer = nil;

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        EndfieldRuntimeLog(@"[ZEF] gamepad map: start");

        // A private queue, not the main queue: Unity does not service the main dispatch queue
        // on its own (PlayTools drains it with a CADisplayLink), so this must not depend on it.
        // The engine needs a moment to come up, so the patch is retried until it lands.
        dispatch_queue_t queue = dispatch_queue_create("playcover.endfield.gamepadmap",
                                                       DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  (uint64_t)(1.0 * NSEC_PER_SEC), 0);
        dispatch_source_set_event_handler(timer, ^{
            BOOL mobile = ef_patch_is_mobile();
            BOOL touch = ef_patch_supports_touch();
            if (mobile && touch) {
                dispatch_source_cancel(timer);
                EndfieldRuntimeLog(@"[ZEF] gamepad map: isMobile + supportsTouch patches installed");
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
