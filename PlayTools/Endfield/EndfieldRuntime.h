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

/// Resolve an il2cpp internal call by its registration name, or NULL.
void *EndfieldRuntimeResolveIcall(const char *name);

/// Base address of the loaded UnityFramework image, or NULL.
void *EndfieldRuntimeImageBase(void);

/// Static-field storage block for a class (the il2cpp static_fields pointer), or NULL.
void *EndfieldRuntimeStaticFieldData(void *klass);

/// The nearest run of zero bytes inside __TEXT that a `bl` from `site` can reach and that fits
/// `size` bytes, or NULL. Lets a module host a runtime stub without touching the file.
void *EndfieldRuntimeFindCodeCave(void *site, size_t size);

/// Scan the UnityFramework __text for a masked instruction pattern. Each entry is a 32-bit
/// little-endian word; a word matches when (word & mask) == value (mask 0 matches anything).
/// Returns the address of the first match, or NULL. Used to locate a patch site in a build
/// without hard-coding a file offset.
void *EndfieldRuntimeScanText(const uint32_t *masks, const uint32_t *values, size_t count);

/// Like EndfieldRuntimeScanText but for two sites that are not adjacent: find `head` at p such
/// that (p[1] & nextMask) == nextValue and p[gapBytes/4] == tail. Returns p, or NULL. Used for
/// the haptics gates (0x1D0 apart) so they survive a version change without fixed offsets.
void *EndfieldRuntimeScanTextPair(uint32_t head, uint32_t nextMask, uint32_t nextValue,
                                  uint32_t tail, size_t gapBytes);

/// As above, but with masks on the head and tail too, so a register-allocation change (e.g.
/// `cmp x0, x25` becoming `cmp x0, x24`) still matches.
void *EndfieldRuntimeScanTextPairMasked(uint32_t head, uint32_t headMask,
                                        uint32_t nextMask, uint32_t nextValue,
                                        uint32_t tail, uint32_t tailMask, size_t gapBytes);

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
