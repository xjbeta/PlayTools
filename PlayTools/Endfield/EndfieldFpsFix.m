//
//  EndfieldFpsFix.m
//  PlayTools
//
//  Same byte patch the PlayCover-side fix applied, but in memory:
//
//    Application::set_targetFrameRate icall trampoline:
//      +0x0c: mov x19, x0   ->   add x19, x0, x0
//
//  which doubles the value the engine receives (30/45/60 -> 60/90/120) and unlocks both the
//  internal limiter and CADisplayLink. The trampoline is reached through the managed method's
//  own entry point, so no file offset is hard-coded.
//
//  Fail-closed: if the method or the expected bytes are missing, nothing is written.
//

#import "EndfieldFpsFix.h"
#import "EndfieldRuntime.h"

#include <stdint.h>

static const int ef_fps_max_attempts = 30;
static const int64_t ef_fps_retry_ns = 2 * NSEC_PER_SEC;
static const uint32_t ef_fps_original = 0xAA0003F3u;     // mov x19, x0
static const uint32_t ef_fps_doubled = 0x8B000013u;      // add x19, x0, x0

static bool ef_fps_patched = false;

static bool ef_fps_patch_trampoline(void) {
    if (ef_fps_patched) { return true; }

    void *klass = EndfieldRuntimeClass("UnityEngine", "Application");
    void *method = EndfieldRuntimeMethod(klass, "set_targetFrameRate", 1);
    void *trampoline = EndfieldRuntimeMethodPointer(method);
    if (trampoline == NULL) { return false; }

    // Find `mov x19, x0` (the fps argument being saved) in the trampoline's first few
    // instructions, rather than assuming a fixed offset, so a prologue change does not break it.
    uint32_t *site = NULL;
    for (size_t i = 0; i < 8; i++) {
        uint32_t word = 0;
        if (!EndfieldRuntimeReadMemory((char *)trampoline + i * 4, &word, sizeof(word))) { break; }
        if (word == ef_fps_doubled) {
            ef_fps_patched = true;
            return true;
        }
        if (word == ef_fps_original) {
            site = (uint32_t *)((char *)trampoline + i * 4);
            break;
        }
    }
    if (site == NULL) {
        EndfieldRuntimeLog(@"[ZEF] fps x2: `mov x19,x0` not found in the trampoline, not patched");
        EndfieldRuntimeNote("fps x2", false);
        return false;
    }
    if (!EndfieldRuntimeWriteMemory(site, &ef_fps_doubled, sizeof(ef_fps_doubled))) {
        EndfieldRuntimeLog(@"[ZEF] fps x2: write failed");
        EndfieldRuntimeNote("fps x2", false);
        return false;
    }
    ef_fps_patched = true;
    EndfieldRuntimeNote("fps x2", true);
    EndfieldRuntimeLog(@"[ZEF] fps x2: patched trampoline @ %p", (void *)site);
    return true;
}

static void ef_fps_attempt(int remaining) {
    if (ef_fps_patched || !EndfieldRuntimeIsGame()) { return; }

    if (ef_fps_patch_trampoline()) { return; }

    if (remaining <= 0) {
        EndfieldRuntimeLog(@"[ZEF] fps x2: set_targetFrameRate trampoline not patched, giving up");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ef_fps_retry_ns),
                   dispatch_get_main_queue(), ^{ ef_fps_attempt(remaining - 1); });
}

void EndfieldFpsFixStart(void) {
    if (ef_fps_patched || !EndfieldRuntimeIsGame()) { return; }
    ef_fps_attempt(ef_fps_max_attempts);
}
