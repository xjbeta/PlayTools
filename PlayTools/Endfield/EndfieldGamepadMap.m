//
//  EndfieldGamepadMap.m
//  PlayTools
//
//  See EndfieldGamepadMap.h. Two mechanisms, both aimed at the same field:
//
//    * An event hook on the game's device switch. `CheckUsingController` changes the input
//      device through exactly one call site (`bl 0xa69b7b4` at 0xa69fe98); a stub rewrites the
//      call so the switch itself writes DeviceInfo.platform from its own argument - 8 when it
//      goes to the pad, 2 when it goes away. Event-driven, no lag.
//    * A slow guardian. The game can still move `platform` without a switch, so a 10 s timer
//      re-asserts 8 while inputType == 2. It only takes over once the hook is in place.
//
//  A key press while the game is in gamepad mode releases platform to 2 for a moment - the
//  game's own switch back to keyboard/mouse needs that - and the hook then settles the field
//  on the way out.
//
//  Engine plumbing is the same table the old Endfield/EndfieldInternal.h used for this 1.5.3
//  build; it is inlined so the module has no other dependencies:
//    DeviceInfo static fields block = klass + 0xB8
//    platform @ +0x24, inputType @ +0x28
//    device switch call @ 0xA69FE98 -> 0xA69B7B4
//

#import "EndfieldGamepadMap.h"

#import <Foundation/Foundation.h>
#import <libkern/OSCacheControl.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// The iOS SDK ships <mach/mach_vm.h> as an "unsupported" stub, but both symbols exist in
// libsystem_kernel, so declare them here (the old EndfieldSupport.m did the same).
extern kern_return_t mach_vm_write(vm_map_t target_task, mach_vm_address_t address,
                                   vm_offset_t data, mach_msg_type_number_t dataCnt);
extern kern_return_t mach_vm_protect(vm_map_t target_task, mach_vm_address_t address,
                                     mach_vm_size_t size, boolean_t set_maximum,
                                     vm_prot_t new_protection);
#ifndef VM_PROT_COPY
#define VM_PROT_COPY 0x10           // only defined in macOS' vm_prot.h
#endif

#define EF_OFF_DOMAIN_GET      0x0D6C9F1CULL
#define EF_OFF_ASSEMBLY_OPEN   0x0D6C9F20ULL
#define EF_OFF_ASSEMBLY_IMAGE  0x0D6C99D0ULL
#define EF_OFF_CLASS_FROM_NAME 0x0D6C99F8ULL
#define EF_OFF_DOMAIN_SLOT     0x13D0AC10ULL

#define EF_OFF_CLASS_STATIC_FIELDS 0xB8
#define EF_OFF_PLATFORM            0x24
#define EF_OFF_INPUTTYPE           0x28

#define EF_OFF_DEVICE_SWITCH_CALL 0xA69FE98ULL
#define EF_OFF_DEVICE_SWITCH_IMPL 0xA69B7B4ULL

#define EF_INPUTTYPE_GAMEPAD 2
#define EF_PLATFORM_DESKTOP  2
#define EF_PLATFORM_MOBILE   8

#define EF_HOOK_BRANCH_REACH 0x08000000ULL   // bl: +/-128 MB

typedef void *(*ef_domain_get_fn)(void);
typedef void *(*ef_assembly_open_fn)(void *domain, const char *name);
typedef void *(*ef_assembly_image_fn)(void *assembly);
typedef void *(*ef_class_from_name_fn)(void *image, const char *nameSpace, const char *name);

static void ef_log(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"pt_endfield.log"];
    FILE *file = fopen(path.UTF8String, "a");
    if (file == NULL) { return; }
    fputs(line.UTF8String, file);
    fclose(file);
}

/// Monotonic nanoseconds; used only for the short window after a key press during which the
/// guardian leaves `platform` alone so the game can switch back to keyboard/mouse.
static int64_t ef_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static uintptr_t ef_unityframework_base(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name != NULL && strstr(name, "UnityFramework") != NULL) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

static void *ef_static_fields(void) {
    static void *cached = NULL;
    if (cached != NULL) { return cached; }
    uintptr_t base = ef_unityframework_base();
    if (base == 0 || *(void *volatile *)(base + EF_OFF_DOMAIN_SLOT) == NULL) { return NULL; }
    void *domain = ((ef_domain_get_fn)(base + EF_OFF_DOMAIN_GET))();
    if (domain == NULL) { return NULL; }
    void *assembly = ((ef_assembly_open_fn)(base + EF_OFF_ASSEMBLY_OPEN))(domain, "Common.Beyond.dll");
    if (assembly == NULL) { return NULL; }
    void *image = ((ef_assembly_image_fn)(base + EF_OFF_ASSEMBLY_IMAGE))(assembly);
    if (image == NULL) { return NULL; }
    void *klass = ((ef_class_from_name_fn)(base + EF_OFF_CLASS_FROM_NAME))(image, "Beyond", "DeviceInfo");
    if (klass == NULL) { return NULL; }
    cached = *(void **)((char *)klass + EF_OFF_CLASS_STATIC_FIELDS);
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

static volatile int *ef_platform_field(void) {
    void *fields = ef_static_fields();
    return fields == NULL ? NULL : (volatile int *)((char *)fields + EF_OFF_PLATFORM);
}

// ---------------------------------------------------------------------------
// Device switch event hook
// ---------------------------------------------------------------------------

/// `bl 0xa69b7b4` at 0xa69fe98 encodes to the little-endian word 0x97ffee47, i.e. these bytes.
static const unsigned char ef_hook_expected_call[4] = { 0x47, 0xee, 0xff, 0x97 };

/// The stub the `bl` is rewritten to. It writes DeviceInfo.platform straight from the call's own
/// argument (w1): 8 when the switch goes to the pad, 2 when it goes away. Only x16/x17
/// (caller-saved) are touched, so the original call still gets its own x0/x1 and still returns
/// into CheckUsingController; every callee-saved register is untouched.
static const uint32_t ef_hook_stub_code[7] = {
    0x580000F0,   // ldr x16, #28      -> &DeviceInfo.platform
    0x52800051,   // mov w17, #2
    0x34000041,   // cbz w1, #16       -> not a pad switch: keep 2
    0x52800111,   // mov w17, #8
    0xB9000211,   // str w17, [x16]
    0x58000090,   // ldr x16, #36      -> original 0xa69b7b4
    0xD61F0200,   // br  x16
};

enum {
    EF_HOOK_PLATFORM_LITERAL = 28,   // offset of the .quad slots inside the stub
    EF_HOOK_ORIGINAL_LITERAL = 36,
    EF_HOOK_STUB_SIZE = 44,
    EF_MAX_SECTIONS = 96,            // __TEXT has ~25 today
};

static uintptr_t ef_hook_stub_address = 0;   // non-zero once installed

typedef struct {
    uintptr_t start;
    uintptr_t end;
} ef_span;

/// Every byte has to be zero for a gap to be padding rather than something the game reads.
static BOOL ef_zero_filled(uintptr_t address, size_t length) {
    const volatile unsigned char *bytes = (const volatile unsigned char *)address;
    for (size_t i = 0; i < length; i++) {
        if (bytes[i] != 0) { return NO; }
    }
    return YES;
}

static void ef_sort_spans(ef_span *spans, size_t count) {
    for (size_t i = 1; i < count; i++) {
        ef_span key = spans[i];
        size_t j = i;
        while (j > 0 && spans[j - 1].start > key.start) {
            spans[j] = spans[j - 1];
            j--;
        }
        spans[j] = key;
    }
}

/// The nearest stretch of zero bytes that sits in a gap __TEXT already has and that the call
/// site's `bl` can reach. Nearest wins: the distance left over is the headroom a later build of
/// the game has before the hook stops fitting. Returns 0 when nothing qualifies.
static uintptr_t ef_find_cave(uintptr_t base, uintptr_t site, size_t needed) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)base;
    if (header->magic != MH_MAGIC_64) { return 0; }
    const unsigned char *cursor = (const unsigned char *)base + sizeof(struct mach_header_64);
    const unsigned char *limit = cursor + header->sizeofcmds;

    uintptr_t best = 0;
    uintptr_t bestDistance = UINTPTR_MAX;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) { break; }
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > limit) {
            break;
        }
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0
                && segment->nsects > 0 && segment->nsects <= EF_MAX_SECTIONS) {
                const struct section_64 *sections =
                    (const struct section_64 *)(cursor + sizeof(struct segment_command_64));
                ef_span spans[EF_MAX_SECTIONS];
                for (uint32_t s = 0; s < segment->nsects; s++) {
                    spans[s].start = (uintptr_t)(base + sections[s].addr);
                    spans[s].end = spans[s].start + (uintptr_t)sections[s].size;
                }
                ef_sort_spans(spans, segment->nsects);

                // The space before each section, then the space after the last one.
                for (uint32_t s = 0; s <= segment->nsects; s++) {
                    uintptr_t gapStart = s == 0 ? (uintptr_t)(base + segment->vmaddr)
                                                : spans[s - 1].end;
                    uintptr_t gapEnd = s < segment->nsects
                        ? spans[s].start
                        : (uintptr_t)(base + segment->vmaddr + segment->vmsize);
                    if (gapEnd <= gapStart || gapEnd - gapStart < needed) { continue; }
                    uintptr_t candidate = (gapStart + 7) & ~(uintptr_t)7;   // keep the .quad slots tidy
                    if (candidate + needed > gapEnd) { continue; }
                    intptr_t delta = (intptr_t)candidate - (intptr_t)site;
                    if (delta < -(intptr_t)EF_HOOK_BRANCH_REACH
                        || delta > (intptr_t)EF_HOOK_BRANCH_REACH - 4) {
                        continue;
                    }
                    uintptr_t distance = delta < 0 ? (uintptr_t)(-delta) : (uintptr_t)delta;
                    if (distance >= bestDistance) { continue; }
                    if (!ef_zero_filled(candidate, needed)) { continue; }
                    bestDistance = distance;
                    best = candidate;
                }
            }
        }
        cursor += command->cmdsize;
    }
    return best;
}

/// Writes into a signed __TEXT page: mach_vm_write first, then a VM_PROT_COPY page. The page is
/// already r-x, so the write keeps it executable - no allocation, no protection change beyond it.
static BOOL ef_write_text(unsigned char *entry, const unsigned char *patched, size_t length,
                          NSString *tag) {
    const char *how = NULL;
    kern_return_t kr = mach_vm_write(mach_task_self(), (mach_vm_address_t)entry,
                                     (vm_offset_t)patched, (mach_msg_type_number_t)length);
    if (kr == KERN_SUCCESS && memcmp(entry, patched, length) == 0) {
        how = "mach_vm_write";
    } else {
        long pageSize = sysconf(_SC_PAGESIZE);
        uintptr_t page = (uintptr_t)entry & ~((uintptr_t)pageSize - 1);
        kr = mach_vm_protect(mach_task_self(), (mach_vm_address_t)page, (mach_vm_size_t)pageSize,
                             FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr == KERN_SUCCESS) {
            memcpy(entry, patched, length);
            mach_vm_protect(mach_task_self(), (mach_vm_address_t)page, (mach_vm_size_t)pageSize,
                            FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
            if (memcmp(entry, patched, length) == 0) { how = "VM_PROT_COPY"; }
        }
    }
    if (how == NULL) {
        ef_log([NSString stringWithFormat:@"[ZEF] gamepad map: %@ write failed (kr=%d)", tag, kr]);
        return NO;
    }
    sys_icache_invalidate(entry, length);
    return YES;
}

/// Installs the stub and rewrites the `bl`. Idempotent; returns NO whenever it cannot be sure of
/// itself (engine not loaded, call site bytes unexpected, no cave in `bl` range, write refused),
/// and the guardian keeps running either way.
static BOOL ef_install_device_hook(void) {
    if (ef_hook_stub_address != 0) { return YES; }
    uintptr_t base = ef_unityframework_base();
    if (base == 0) { return NO; }
    volatile int *platform = ef_platform_field();
    if (platform == NULL) { return NO; }

    unsigned char *site = (unsigned char *)(base + EF_OFF_DEVICE_SWITCH_CALL);
    if (memcmp(site, ef_hook_expected_call, sizeof(ef_hook_expected_call)) != 0) {
        ef_log([NSString stringWithFormat:
                @"[ZEF] gamepad map: device hook bytes differ (%02x%02x%02x%02x), not installed",
                site[0], site[1], site[2], site[3]]);
        return NO;
    }

    uintptr_t stub = ef_find_cave(base, (uintptr_t)site, EF_HOOK_STUB_SIZE);
    if (stub == 0) {
        ef_log(@"[ZEF] gamepad map: device hook: no cave in bl range, guardian only");
        return NO;
    }
    intptr_t delta = (intptr_t)stub - (intptr_t)site;

    unsigned char image[EF_HOOK_STUB_SIZE];
    memcpy(image, ef_hook_stub_code, sizeof(ef_hook_stub_code));
    *(uint64_t *)(image + EF_HOOK_PLATFORM_LITERAL) = (uint64_t)(uintptr_t)platform;
    *(uint64_t *)(image + EF_HOOK_ORIGINAL_LITERAL) = (uint64_t)(base + EF_OFF_DEVICE_SWITCH_IMPL);
    if (!ef_write_text((unsigned char *)stub, image, sizeof(image), @"device hook stub")) {
        return NO;
    }
    if (memcmp((const void *)stub, image, sizeof(image)) != 0) {
        ef_log(@"[ZEF] gamepad map: device hook: stub read-back mismatch, not enabled");
        return NO;
    }

    uint32_t branch = 0x94000000u | ((uint32_t)(delta >> 2) & 0x03FFFFFFu);
    unsigned char patched[4];
    memcpy(patched, &branch, sizeof(patched));
    if (!ef_write_text(site, patched, sizeof(patched), @"device hook")) { return NO; }
    if (memcmp(site, patched, sizeof(patched)) != 0) {
        ef_log(@"[ZEF] gamepad map: device hook: branch read-back mismatch, not enabled");
        return NO;
    }

    ef_hook_stub_address = stub;
    ef_log([NSString stringWithFormat:
            @"[ZEF] gamepad map: device hook installed @ %p -> %p (delta %+ld)",
            site, (void *)stub, (long)delta]);
    return YES;
}

@interface EFGamepadMap : NSObject @end
@implementation EFGamepadMap

// The source must outlive +start: under ARC a bare local dispatch_source_t is released on
// return and cancelled before it can fire. Keep the strong reference here instead.
static dispatch_source_t ef_timer = nil;

// The key monitor token must be retained too: releasing the returned token removes the monitor.
static id ef_key_monitor = nil;

// While a key is being pressed the guardian stops forcing platform=8 for a moment, so the game
// can run its own switch back to keyboard/mouse (see EndfieldGamepadMapKeyboardActivity).
static volatile int64_t ef_suppress_until_ns = 0;

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ef_log(@"[ZEF] gamepad map: start");

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
                    ef_log(@"[ZEF] gamepad map: DeviceInfo not ready");
                }
                return;
            }
            if (ef_hook_stub_address == 0 && ef_install_device_hook()) {
                guardianCadence = YES;
                dispatch_source_set_timer(timer,
                                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                                          (uint64_t)(10.0 * NSEC_PER_SEC), 0);
            }
            int inputType = ef_read(EF_OFF_INPUTTYPE);
            int platform = ef_read(EF_OFF_PLATFORM);
            // One state line a minute (12 s startup, 60 s guardian); it doubles as the heartbeat.
            if (ticks % (guardianCadence ? 6 : 12) == 0) {
                ef_log([NSString stringWithFormat:@"[ZEF] gamepad map: inputType=%d platform=%d",
                        inputType, platform]);
            }
            if (inputType != EF_INPUTTYPE_GAMEPAD) {
                // Left gamepad mode: drop any key-press suppression so switching back is
                // corrected immediately.
                ef_suppress_until_ns = 0;
            } else if (platform != EF_PLATFORM_MOBILE && ef_now_ns() >= ef_suppress_until_ns) {
                ef_write(EF_OFF_PLATFORM, EF_PLATFORM_MOBILE);
                ef_log([NSString stringWithFormat:@"[ZEF] gamepad map: platform %d -> 8 (guardian)",
                        platform]);
            }
        });
        ef_timer = timer;
        dispatch_resume(timer);
    });
}

@end

void EndfieldGamepadMapStart(void) {
    // Endfield only - the entry point is shared by every game PlayTools launches.
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.hypergryph.endfield"]) {
        return;
    }
    [EFGamepadMap start];
}

void EndfieldGamepadMapKeyboardActivity(void) {
    // Called on a real key press. While the game is in gamepad mode the guardian holds platform
    // at 8 (mobile binding), which keeps the keyboard out of the device set, so the game never
    // runs its own switch back to keyboard/mouse. Release platform to 2 for a short window and
    // let the game switch; if it does not, the guardian restores 8 afterwards.
    if (ef_read(EF_OFF_INPUTTYPE) != EF_INPUTTYPE_GAMEPAD) { return; }
    if (ef_read(EF_OFF_PLATFORM) != EF_PLATFORM_MOBILE) { return; }
    ef_write(EF_OFF_PLATFORM, EF_PLATFORM_DESKTOP);
    ef_suppress_until_ns = ef_now_ns() + 3LL * 1000000000LL;
    ef_log(@"[ZEF] gamepad map: keyboard activity -> platform 8 -> 2");
}
