//
//  EndfieldRuntime.h
//  PlayTools
//
//  Shared plumbing for the runtime Endfield fixes (resolution + FPS). Everything here is
//  resolved by NAME - bundle id, il2cpp class/method, dlsym symbol - and applied to process
//  memory only. The on-disk UnityFramework binary is never touched.
//
//  Why this exists: the old PlayCover-side patches wrote fixed file offsets into the game's
//  UnityFramework on disk. Those offsets belong to one build (and differ between the CN and
//  international binaries), and a failed write left a corrupted binary behind. Resolving by
//  name and patching in memory makes one implementation work on both builds, and turns any
//  failure into a no-op: the game simply runs unpatched.
//

#pragma once

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// True when the running app is an Endfield build (CN or international).
bool EndfieldRuntimeIsGame(void);

/// Record a component's install result, for the end-of-startup summary.
void EndfieldRuntimeNote(const char *component, bool ok);

/// Log a one-line summary of every recorded component (installed / failed).
void EndfieldRuntimeLogStatus(void);

/// Append a timestamped line to <container>/Data/pt_endfield.log.
void EndfieldRuntimeLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Look up a managed class by namespace + name, scanning every loaded assembly.
/// Returns the Il2CppClass pointer, or NULL.
void *EndfieldRuntimeClass(const char *nameSpace, const char *name);

/// Look up a method on `klass` by name and declared parameter count.
/// Returns the MethodInfo pointer, or NULL.
void *EndfieldRuntimeMethod(void *klass, const char *name, int argc);

/// The native entry point stored at the head of a MethodInfo, or NULL.
void *EndfieldRuntimeMethodPointer(void *method);

/// Address of a static field's storage, or NULL.
void *EndfieldRuntimeStaticFieldAddress(void *klass, const char *name);

/// Base address of the loaded UnityFramework image, or NULL.
void *EndfieldRuntimeImageBase(void);

/// Static-field storage block for a class (the il2cpp static_fields pointer), or NULL.
void *EndfieldRuntimeStaticFieldData(void *klass);

/// Scan the UnityFramework __text for a masked instruction pattern. Each entry is a 32-bit
/// little-endian word; a word matches when (word & mask) == value (mask 0 matches anything).
/// Returns the address of the first match, or NULL. Used to locate a patch site in a build
/// without hard-coding a file offset.
void *EndfieldRuntimeScanText(const uint32_t *masks, const uint32_t *values, size_t count);

/// True when `header` is the loaded UnityFramework image (used from a dyld add-image callback).
bool EndfieldRuntimeImageIsUnityFramework(const void *header);

/// Copy `length` bytes out of / into process memory. The write path also handles
/// read-only __TEXT pages (mach_vm_write, then VM_PROT_COPY) and verifies the result by
/// reading it back; it returns false when the bytes did not land.
bool EndfieldRuntimeReadMemory(void *address, void *out, size_t length);
bool EndfieldRuntimeWriteMemory(void *address, const void *bytes, size_t length);

/// Replace a managed method's native entry. Returns the previous entry (so the caller can
/// chain to it), or NULL when the write did not stick.
void *EndfieldRuntimeHookMethod(void *method, void *replacement);

#ifdef __cplusplus
}
#endif
