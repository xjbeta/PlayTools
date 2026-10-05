//
//  EndfieldRuntime.m
//  PlayTools
//
//  See EndfieldRuntime.h. Two deliberate choices keep this build-agnostic:
//    * the il2cpp API is resolved with dlsym, not with file offsets. Every il2cpp entry point
//      is exported by UnityFramework (241 of them in 1.5.3); only their addresses move
//      between builds, the names do not.
//    * writes go through mach_vm_write / VM_PROT_COPY and are read back, so a failed patch is
//      reported instead of silently half-applied.
//

#import "EndfieldRuntime.h"

#import <dlfcn.h>
#import <libkern/OSCacheControl.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// The iOS SDK ships <mach/mach_vm.h> as an "unsupported" stub, but both symbols exist in
// libsystem_kernel, so declare them here (EndfieldGamepadMap.m does the same).
extern kern_return_t mach_vm_write(vm_map_t target_task, mach_vm_address_t address,
                                   vm_offset_t data, mach_msg_type_number_t dataCnt);
extern kern_return_t mach_vm_protect(vm_map_t target_task, mach_vm_address_t address,
                                     mach_vm_size_t size, boolean_t set_maximum,
                                     vm_prot_t new_protection);
#ifndef VM_PROT_COPY
#define VM_PROT_COPY 0x10           // only defined in macOS' vm_prot.h
#endif

// The Endfield builds we know. Matching the bundle id is what keeps the fixes off every other
// app PlayTools is injected into. CN and international ship the same managed game code, so a
// single name-based implementation covers both.
static bool ef_rt_is_endfield_bundle(NSString *bundle) {
    return [bundle isEqualToString:@"com.hypergryph.endfield"]
        || [bundle isEqualToString:@"com.gryphline.endfield.ios"];
}

bool EndfieldRuntimeIsGame(void) {
    return ef_rt_is_endfield_bundle([NSBundle mainBundle].bundleIdentifier ?: @"");
}

// ---------------------------------------------------------------------------
// Install-status registry, so a failed patch is visible instead of only a log line buried among
// the rest.
// ---------------------------------------------------------------------------

#define EF_RT_MAX_NOTES 8
static struct { const char *name; int ok; } ef_rt_notes[EF_RT_MAX_NOTES];
static int ef_rt_note_count = 0;

void EndfieldRuntimeNote(const char *component, bool ok) {
    if (component == NULL || ef_rt_note_count >= EF_RT_MAX_NOTES) { return; }
    ef_rt_notes[ef_rt_note_count].name = component;
    ef_rt_notes[ef_rt_note_count].ok = ok ? 1 : 0;
    ef_rt_note_count += 1;
}

void EndfieldRuntimeLogStatus(void) {
    NSMutableString *line = [NSMutableString stringWithString:@"[ZEF] status:"];
    if (ef_rt_note_count == 0) {
        [line appendString:@" (nothing recorded)"];
    }
    for (int i = 0; i < ef_rt_note_count; i++) {
        [line appendFormat:@" %s=%@", ef_rt_notes[i].name, ef_rt_notes[i].ok ? @"OK" : @"FAILED"];
    }
    EndfieldRuntimeLog(@"%@", line);
}

void EndfieldRuntimeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"pt_endfield.log"];
    FILE *file = fopen(path.UTF8String, "a");
    if (file == NULL) { return; }
    fputs(line.UTF8String, file);
    fclose(file);
}

// ---------------------------------------------------------------------------
// il2cpp entry points, resolved by symbol name.
// ---------------------------------------------------------------------------

typedef const void *(*ef_domain_get_fn)(void);
typedef const void **(*ef_domain_get_assemblies_fn)(const void *domain, size_t *size);
typedef const void *(*ef_assembly_get_image_fn)(const void *assembly);
typedef void *(*ef_class_from_name_fn)(const void *image, const char *nameSpace, const char *name);
typedef void *(*ef_class_get_method_from_name_fn)(void *klass, const char *name, int argsCount);
typedef void *(*ef_class_get_field_from_name_fn)(void *klass, const char *name);
typedef size_t (*ef_field_get_offset_fn)(void *field);
typedef void *(*ef_class_get_static_field_data_fn)(void *klass);
typedef void *(*ef_resolve_icall_fn)(const char *name);

typedef struct {
    ef_domain_get_fn domain_get;
    ef_domain_get_assemblies_fn domain_get_assemblies;
    ef_assembly_get_image_fn assembly_get_image;
    ef_class_from_name_fn class_from_name;
    ef_class_get_method_from_name_fn class_get_method_from_name;
    ef_class_get_field_from_name_fn class_get_field_from_name;
    ef_field_get_offset_fn field_get_offset;
    ef_class_get_static_field_data_fn class_get_static_field_data;
    ef_resolve_icall_fn resolve_icall;
    bool ready;
} ef_il2cpp_api;

static ef_il2cpp_api ef_api;

static void *ef_rt_symbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static bool ef_rt_load_api(void) {
    if (ef_api.ready) { return true; }
    ef_api.domain_get = (ef_domain_get_fn)ef_rt_symbol("il2cpp_domain_get");
    ef_api.domain_get_assemblies =
        (ef_domain_get_assemblies_fn)ef_rt_symbol("il2cpp_domain_get_assemblies");
    ef_api.assembly_get_image =
        (ef_assembly_get_image_fn)ef_rt_symbol("il2cpp_assembly_get_image");
    ef_api.class_from_name = (ef_class_from_name_fn)ef_rt_symbol("il2cpp_class_from_name");
    ef_api.class_get_method_from_name =
        (ef_class_get_method_from_name_fn)ef_rt_symbol("il2cpp_class_get_method_from_name");
    ef_api.class_get_field_from_name =
        (ef_class_get_field_from_name_fn)ef_rt_symbol("il2cpp_class_get_field_from_name");
    ef_api.field_get_offset =
        (ef_field_get_offset_fn)ef_rt_symbol("il2cpp_field_get_offset");
    ef_api.class_get_static_field_data =
        (ef_class_get_static_field_data_fn)ef_rt_symbol("il2cpp_class_get_static_field_data");
    ef_api.resolve_icall = (ef_resolve_icall_fn)ef_rt_symbol("il2cpp_resolve_icall");
    ef_api.ready = ef_api.domain_get && ef_api.domain_get_assemblies
        && ef_api.assembly_get_image && ef_api.class_from_name
        && ef_api.class_get_method_from_name && ef_api.class_get_field_from_name
        && ef_api.field_get_offset && ef_api.class_get_static_field_data;
    if (!ef_api.ready) {
        EndfieldRuntimeLog(@"[ZEF] runtime: il2cpp API unavailable (not an il2cpp app yet?)");
    }
    return ef_api.ready;
}

// ---------------------------------------------------------------------------
// Readiness gate. il2cpp segfaults if its assembly list is queried before the runtime has
// finished initialising it. We do not probe it with a signal handler (a siglongjmp out of a
// fault can leave il2cpp's internal lock held, deadlocking the game); instead we simply do not
// touch il2cpp until the process has been up long enough for init to have completed, and the
// caller retries until then.
// ---------------------------------------------------------------------------

static int64_t ef_rt_load_ns = 0;

__attribute__((constructor)) static void ef_rt_record_load_time(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    ef_rt_load_ns = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/// Seconds since PlayTools was loaded (i.e. since the game process started).
static double ef_rt_uptime_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    int64_t now = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
    if (ef_rt_load_ns == 0) { ef_rt_load_ns = now; }
    return (double)(now - ef_rt_load_ns) / 1000000000.0;
}

// The engine finishes il2cpp init a few seconds in; stay clear of that window as a first pass.
static const double ef_rt_min_uptime = 6.0;

// ---------------------------------------------------------------------------
// Crash-guarded probe. Before il2cpp has built its assembly list, querying it dereferences
// not-yet-initialised state and segfaults. A SIGSEGV/SIGBUS handler with sigsetjmp turns that
// into "not ready yet" for the caller, instead of taking the game down. The probe flag and the
// jump buffer are thread-local so only the probing thread is affected.
// ---------------------------------------------------------------------------

static __thread sigjmp_buf ef_rt_probe_jmp;
static __thread volatile sig_atomic_t ef_rt_probing = 0;

static void ef_rt_probe_handler(int sig, siginfo_t *info, void *context) {
    if (ef_rt_probing) {
        ef_rt_probing = 0;
        siglongjmp(ef_rt_probe_jmp, 1);
    }
    // Not our probe: this is a real crash. Restore the default action and re-raise.
    signal(sig, SIG_DFL);
    raise(sig);
}

void *EndfieldRuntimeClass(const char *nameSpace, const char *name) {
    if (!ef_rt_load_api()) { return NULL; }
    if (ef_rt_uptime_seconds() < ef_rt_min_uptime) { return NULL; }

    struct sigaction action;
    struct sigaction prevSegv;
    struct sigaction prevBus;
    memset(&action, 0, sizeof(action));
    action.sa_flags = SA_SIGINFO;
    action.sa_sigaction = ef_rt_probe_handler;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, &prevSegv);
    sigaction(SIGBUS, &action, &prevBus);

    void *result = NULL;
    if (sigsetjmp(ef_rt_probe_jmp, 1) == 0) {
        ef_rt_probing = 1;
        const void *domain = ef_api.domain_get();
        if (domain != NULL) {
            size_t count = 0;
            const void **assemblies = ef_api.domain_get_assemblies(domain, &count);
            if (assemblies != NULL) {
                for (size_t i = 0; i < count; i++) {
                    const void *image = ef_api.assembly_get_image(assemblies[i]);
                    if (image == NULL) { continue; }
                    void *klass = ef_api.class_from_name(image, nameSpace, name);
                    if (klass != NULL) { result = klass; break; }
                }
            }
        }
        ef_rt_probing = 0;
    } else {
        EndfieldRuntimeLog(@"[ZEF] runtime: il2cpp not ready yet (probe recovered)");
    }

    sigaction(SIGSEGV, &prevSegv, NULL);
    sigaction(SIGBUS, &prevBus, NULL);
    return result;
}

void *EndfieldRuntimeMethod(void *klass, const char *name, int argc) {
    if (klass == NULL || !ef_rt_load_api()) { return NULL; }
    return ef_api.class_get_method_from_name(klass, name, argc);
}

// Il2CppMethodPointer sits at the head of MethodInfo in every il2cpp layout we target.
void *EndfieldRuntimeMethodPointer(void *method) {
    if (method == NULL) { return NULL; }
    return *(void *volatile *)method;
}

void *EndfieldRuntimeStaticFieldAddress(void *klass, const char *name) {
    if (klass == NULL || !ef_rt_load_api()) { return NULL; }
    void *field = ef_api.class_get_field_from_name(klass, name);
    if (field == NULL) { return NULL; }
    void *data = ef_api.class_get_static_field_data(klass);
    if (data == NULL) { return NULL; }
    return (char *)data + ef_api.field_get_offset(field);
}

void *EndfieldRuntimeResolveIcall(const char *name) {
    if (!ef_rt_load_api() || ef_api.resolve_icall == NULL) { return NULL; }
    return ef_api.resolve_icall(name);
}

void *EndfieldRuntimeImageBase(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name != NULL && strstr(name, "UnityFramework") != NULL) {
            return (void *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

bool EndfieldRuntimeImageIsUnityFramework(const void *header) {
    if (header == NULL) { return false; }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == header) {
            const char *name = _dyld_get_image_name(i);
            return name != NULL && strstr(name, "UnityFramework") != NULL;
        }
    }
    return false;
}

void *EndfieldRuntimeStaticFieldData(void *klass) {
    if (klass == NULL || !ef_rt_load_api()) { return NULL; }
    return ef_api.class_get_static_field_data(klass);
}

// ---------------------------------------------------------------------------
// Code cave search for runtime __TEXT patches (used by the gamepad map hook).
// ---------------------------------------------------------------------------

// bl reaches +/-128 MB.
#define EF_RT_BRANCH_REACH 0x08000000ULL
#define EF_RT_MAX_SECTIONS 96

typedef struct { uintptr_t start; uintptr_t end; } ef_rt_span;

static BOOL ef_rt_zero_filled(uintptr_t address, size_t length) {
    const volatile unsigned char *bytes = (const volatile unsigned char *)address;
    for (size_t i = 0; i < length; i++) {
        if (bytes[i] != 0) { return NO; }
    }
    return YES;
}

static void ef_rt_sort_spans(ef_rt_span *spans, size_t count) {
    for (size_t i = 1; i < count; i++) {
        ef_rt_span key = spans[i];
        size_t j = i;
        while (j > 0 && spans[j - 1].start > key.start) {
            spans[j] = spans[j - 1];
            j--;
        }
        spans[j] = key;
    }
}

void *EndfieldRuntimeFindCodeCave(void *site, size_t size) {
    void *base = EndfieldRuntimeImageBase();
    if (base == NULL || size == 0) { return NULL; }
    const struct mach_header_64 *header = (const struct mach_header_64 *)base;
    if (header->magic != MH_MAGIC_64) { return NULL; }
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
                && segment->nsects > 0 && segment->nsects <= EF_RT_MAX_SECTIONS) {
                const struct section_64 *sections =
                    (const struct section_64 *)(cursor + sizeof(struct segment_command_64));
                ef_rt_span spans[EF_RT_MAX_SECTIONS];
                for (uint32_t s = 0; s < segment->nsects; s++) {
                    spans[s].start = (uintptr_t)(base + sections[s].addr);
                    spans[s].end = spans[s].start + (uintptr_t)sections[s].size;
                }
                ef_rt_sort_spans(spans, segment->nsects);

                for (uint32_t s = 0; s <= segment->nsects; s++) {
                    uintptr_t gapStart = s == 0 ? (uintptr_t)(base + segment->vmaddr)
                                                : spans[s - 1].end;
                    uintptr_t gapEnd = s < segment->nsects
                        ? spans[s].start
                        : (uintptr_t)(base + segment->vmaddr + segment->vmsize);
                    if (gapEnd <= gapStart || gapEnd - gapStart < size) { continue; }
                    uintptr_t candidate = (gapStart + 7) & ~(uintptr_t)7;
                    if (candidate + size > gapEnd) { continue; }
                    intptr_t delta = (intptr_t)candidate - (intptr_t)(uintptr_t)site;
                    if (delta < -(intptr_t)EF_RT_BRANCH_REACH
                        || delta > (intptr_t)EF_RT_BRANCH_REACH - 4) {
                        continue;
                    }
                    uintptr_t distance = delta < 0 ? (uintptr_t)(-delta) : (uintptr_t)delta;
                    if (distance >= bestDistance) { continue; }
                    if (!ef_rt_zero_filled(candidate, size)) { continue; }
                    bestDistance = distance;
                    best = candidate;
                }
            }
        }
        cursor += command->cmdsize;
    }
    return (void *)best;
}

void *EndfieldRuntimeScanText(const uint32_t *masks, const uint32_t *values, size_t count) {
    if (masks == NULL || values == NULL || count == 0) { return NULL; }
    void *base = EndfieldRuntimeImageBase();
    if (base == NULL) { return NULL; }
    const struct mach_header_64 *header = (const struct mach_header_64 *)base;
    if (header->magic != MH_MAGIC_64) { return NULL; }
    const unsigned char *cursor = (const unsigned char *)base + sizeof(struct mach_header_64);
    const unsigned char *limit = cursor + header->sizeofcmds;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) { break; }
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > limit) {
            break;
        }
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0) {
                const struct section_64 *sections =
                    (const struct section_64 *)(cursor + sizeof(struct segment_command_64));
                for (uint32_t s = 0; s < segment->nsects; s++) {
                    if (strncmp(sections[s].sectname, "__text", sizeof(sections[s].sectname)) != 0) {
                        continue;
                    }
                    uint32_t *words = (uint32_t *)((uintptr_t)base + sections[s].addr);
                    size_t countWords = sections[s].size / 4;
                    for (size_t k = 0; k + count <= countWords; k++) {
                        bool matched = true;
                        for (size_t j = 0; j < count; j++) {
                            if ((words[k + j] & masks[j]) != values[j]) { matched = false; break; }
                        }
                        if (matched) { return (void *)&words[k]; }
                    }
                }
            }
        }
        cursor += command->cmdsize;
    }
    return NULL;
}

void *EndfieldRuntimeScanTextPair(uint32_t head, uint32_t nextMask, uint32_t nextValue,
                                  uint32_t tail, size_t gapBytes) {
    return EndfieldRuntimeScanTextPairMasked(head, 0xFFFFFFFFu, nextMask, nextValue,
                                             tail, 0xFFFFFFFFu, gapBytes);
}

void *EndfieldRuntimeScanTextPairMasked(uint32_t head, uint32_t headMask,
                                        uint32_t nextMask, uint32_t nextValue,
                                        uint32_t tail, uint32_t tailMask, size_t gapBytes) {
    if (gapBytes == 0 || (gapBytes % 4) != 0) { return NULL; }
    void *base = EndfieldRuntimeImageBase();
    if (base == NULL) { return NULL; }
    const struct mach_header_64 *header = (const struct mach_header_64 *)base;
    if (header->magic != MH_MAGIC_64) { return NULL; }
    const unsigned char *cursor = (const unsigned char *)base + sizeof(struct mach_header_64);
    const unsigned char *limit = cursor + header->sizeofcmds;
    size_t gapWords = gapBytes / 4;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) { break; }
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command) || cursor + command->cmdsize > limit) {
            break;
        }
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0) {
                const struct section_64 *sections =
                    (const struct section_64 *)(cursor + sizeof(struct segment_command_64));
                for (uint32_t s = 0; s < segment->nsects; s++) {
                    if (strncmp(sections[s].sectname, "__text", sizeof(sections[s].sectname)) != 0) {
                        continue;
                    }
                    uint32_t *words = (uint32_t *)((uintptr_t)base + sections[s].addr);
                    size_t countWords = sections[s].size / 4;
                    if (countWords <= gapWords + 1) { continue; }
                    for (size_t k = 0; k + gapWords + 1 <= countWords; k++) {
                        if ((words[k] & headMask) != head) { continue; }
                        if ((words[k + 1] & nextMask) != nextValue) { continue; }
                        if ((words[k + gapWords] & tailMask) != tail) { continue; }
                        return (void *)&words[k];
                    }
                }
            }
        }
        cursor += command->cmdsize;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Memory access. Writes must land or report failure - a half-applied patch is exactly what
// this whole approach is meant to avoid.
// ---------------------------------------------------------------------------

bool EndfieldRuntimeReadMemory(void *address, void *out, size_t length) {
    if (address == NULL || out == NULL || length == 0) { return false; }
    memcpy(out, address, length);
    return true;
}

bool EndfieldRuntimeWriteMemory(void *address, const void *bytes, size_t length) {
    if (address == NULL || bytes == NULL || length == 0) { return false; }
    kern_return_t kr = mach_vm_write(mach_task_self(), (mach_vm_address_t)address,
                                     (vm_offset_t)bytes, (mach_msg_type_number_t)length);
    if (kr != KERN_SUCCESS || memcmp(address, bytes, length) != 0) {
        long pageSize = sysconf(_SC_PAGESIZE);
        uintptr_t page = (uintptr_t)address & ~((uintptr_t)pageSize - 1);
        kr = mach_vm_protect(mach_task_self(), (mach_vm_address_t)page,
                             (mach_vm_size_t)pageSize, FALSE,
                             VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) { return false; }
        memcpy(address, bytes, length);
        mach_vm_protect(mach_task_self(), (mach_vm_address_t)page,
                        (mach_vm_size_t)pageSize, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }
    if (memcmp(address, bytes, length) != 0) { return false; }
    sys_icache_invalidate(address, length);
    return true;
}

void *EndfieldRuntimeHookMethod(void *method, void *replacement) {
    if (method == NULL || replacement == NULL) { return NULL; }
    void *previous = *(void *volatile *)method;
    if (previous == NULL) { return NULL; }
    if (!EndfieldRuntimeWriteMemory(method, &replacement, sizeof(replacement))) {
        return NULL;
    }
    return previous;
}
