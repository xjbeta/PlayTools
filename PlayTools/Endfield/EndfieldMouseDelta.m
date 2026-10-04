//
//  EndfieldMouseDelta.m
//  PlayTools
//
//  libUnityDesktopMode feeds the game the mouse delta straight from GCMouse, in window points,
//  while PlayTools makes the game's screen `windowPoints x customScaler` (it swizzles
//  UIScreen.scale/nativeScale to the scaler). The game therefore reads the delta in pixels and
//  the look ends up `customScaler` times too slow. Wrap GCMouse's moved handler and scale the
//  delta back up; `endfieldMouseDeltaScale` is a user multiplier on top (default 1.0).
//
//  Endfield only - the entry point checks the bundle id.
//

#import "EndfieldMouseDelta.h"

#import <Foundation/Foundation.h>
#import <PlayTools/PlayTools-Swift.h>
#include <objc/message.h>
#include <objc/runtime.h>

static void ef_md_log(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"pt_endfield.log"];
    FILE *file = fopen(path.UTF8String, "a");
    if (file == NULL) { return; }
    fputs(line.UTF8String, file);
    fclose(file);
}

static IMP ef_original_set_mouse_moved = NULL;

static void ef_set_mouse_moved_handler(id self, SEL _cmd,
                                       void (^handler)(id, float, float)) {
    void (^wrapped)(id, float, float) = nil;
    if (handler != nil) {
        double scale = [[PlaySettings shared] customScaler]
                     * [[PlaySettings shared] endfieldMouseDeltaScale];
        wrapped = [^(id mouse, float dx, float dy) {
            handler(mouse, (float)(dx * scale), (float)(dy * scale));
        } copy];
    }
    if (ef_original_set_mouse_moved != NULL) {
        ((void (*)(id, SEL, id))ef_original_set_mouse_moved)(self, _cmd, wrapped);
    }
}

void EndfieldMouseDeltaStart(void) {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.hypergryph.endfield"]) {
        return;
    }
    if (ef_original_set_mouse_moved != NULL) { return; }
    Class mouseInput = objc_getClass("GCMouseInput");
    SEL setter = sel_registerName("setMouseMovedHandler:");
    if (mouseInput == Nil) { return; }
    Method method = class_getInstanceMethod(mouseInput, setter);
    if (method == NULL) {
        ef_md_log(@"[ZEF] mouse delta: GCMouseInput.setMouseMovedHandler not found");
        return;
    }
    ef_original_set_mouse_moved = method_setImplementation(method, (IMP)ef_set_mouse_moved_handler);
    ef_md_log(@"[ZEF] mouse delta: scaling installed (x customScaler x endfieldMouseDeltaScale)");
}
