//
//  EndfieldResolutionFix.m
//  PlayTools
//
//  The old PlayCover patch forced the render resolution by rewriting GetRenderResolution in the
//  on-disk UnityFramework, at a fixed file offset tied to one build:
//
//    csel w9, w9, w10, gt   ... +0x14 ...   csel w8, w9, w8, gt
//
//  This module does the same edit in process memory, located by that instruction pair instead of
//  a file offset, so one implementation covers the CN and international builds.
//
//  Timing is the whole point: the renderer reads its resolution during startup, so patching
//  after the engine is up is too late. Instead we patch the instant UnityFramework is loaded,
//  from a dyld add-image callback - before any of the game's code has run. That also means no
//  il2cpp involvement at all.
//
//  Fail-closed: if the signature does not match, or a write does not read back, nothing changes.
//

#import "EndfieldResolutionFix.h"
#import "EndfieldRuntime.h"

#import <PlayTools/PlayTools-Swift.h>
#import <mach-o/dyld.h>
#include <math.h>
#include <stdint.h>

// GetRenderResolution patch: the csel pair, and the movz that replaces each one.
static const uint32_t ef_res_csel_gt_width = 0x1A8AC129;    // csel w9, w9, w10, gt
static const uint32_t ef_res_csel_gt_height = 0x1A88C128;   // csel w8, w9, w8, gt
static const uint32_t ef_res_movz_mask = 0xFFE0001F;        // movz wX, #imm
static const uint32_t ef_res_movz_w9_value = 0x52800009;
static const uint32_t ef_res_movz_w8_value = 0x52800008;
static const size_t ef_res_csel_gap = 0x14;                 // patch2 - patch1

static int32_t ef_res_width = 0;
static int32_t ef_res_height = 0;
static bool ef_res_patched = false;

/// The resolution the graphics tab shows: window points x customScaler.
static void ef_res_read_target(void) {
    CGFloat width = PlaySettings.shared.windowSizeWidth;
    CGFloat height = PlaySettings.shared.windowSizeHeight;
    double scaler = PlaySettings.shared.customScaler;
    ef_res_width = (int32_t)llround(width * scaler);
    ef_res_height = (int32_t)llround(height * scaler);
}

/// ARM64 `movz Wd, #imm16`.
static uint32_t ef_res_movz(uint32_t reg, uint32_t imm16) {
    return 0x52800000u | ((imm16 & 0xFFFFu) << 5) | (reg & 0x1Fu);
}

/// Locate the csel pair and rewrite it to return the wanted resolution. Idempotent.
static bool ef_res_patch_native(void) {
    if (ef_res_patched) { return true; }

    // pattern: [csel width] [4 any words] [csel height]
    const uint32_t masks[6] = { 0xFFFFFFFF, 0, 0, 0, 0, 0xFFFFFFFF };
    const uint32_t values[6] = { ef_res_csel_gt_width, 0, 0, 0, 0, ef_res_csel_gt_height };
    uint32_t *widthSite = (uint32_t *)EndfieldRuntimeScanText(masks, values, 6);
    if (widthSite == NULL) {
        return false;
    }
    uint32_t *heightSite = (uint32_t *)((uintptr_t)widthSite + ef_res_csel_gap);

    uint32_t currentWidth = 0;
    uint32_t currentHeight = 0;
    if (!EndfieldRuntimeReadMemory(widthSite, &currentWidth, sizeof(currentWidth))
        || !EndfieldRuntimeReadMemory(heightSite, &currentHeight, sizeof(currentHeight))) {
        return false;
    }
    bool widthReady = (currentWidth == ef_res_csel_gt_width)
        || ((currentWidth & ef_res_movz_mask) == ef_res_movz_w9_value);
    bool heightReady = (currentHeight == ef_res_csel_gt_height)
        || ((currentHeight & ef_res_movz_mask) == ef_res_movz_w8_value);
    if (!widthReady || !heightReady) {
        EndfieldRuntimeLog(@"[ZEF] resolution: unexpected bytes at csel site (%08x/%08x), not patched",
                           currentWidth, currentHeight);
        return false;
    }

    uint32_t newWidth = ef_res_movz(9, (uint32_t)ef_res_width);
    uint32_t newHeight = ef_res_movz(8, (uint32_t)ef_res_height);
    if (!EndfieldRuntimeWriteMemory(widthSite, &newWidth, sizeof(newWidth))
        || !EndfieldRuntimeWriteMemory(heightSite, &newHeight, sizeof(newHeight))) {
        EndfieldRuntimeLog(@"[ZEF] resolution: native write failed");
        return false;
    }
    ef_res_patched = true;
    EndfieldRuntimeLog(@"[ZEF] resolution: patched GetRenderResolution @ %p/%p -> %dx%d",
                       widthSite, heightSite, ef_res_width, ef_res_height);
    return true;
}

/// The renderer reads `override`; the game pins it to 1080p at startup. Rewrite
/// SetOverrideResolution to copy `set` into `override` instead, so the renderer follows the
/// game's setting. Same edit as the old on-disk patch, rebuilt from the instruction's own
/// struct offset so it is not tied to one build.
static bool ef_res_patch_override(void) {
    // add x8,x8,#imm ; stp w19,w20,[x8] ; cmp w19,#1 ; b.lt ; cmp w20,#1
    const uint32_t masks[5] = { 0xFFC003FF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFF00001F, 0xFFFFFFFF };
    const uint32_t values[5] = { 0x91000108, 0x29005113, 0x7100067F, 0x5400000B, 0x7100069F };
    uint32_t *site = (uint32_t *)EndfieldRuntimeScanText(masks, values, 5);
    if (site == NULL) { return false; }

    uint32_t addInstr = 0;
    if (!EndfieldRuntimeReadMemory(site, &addInstr, sizeof(addInstr))) { return false; }
    uint32_t overrideOffset = (addInstr >> 10) & 0xFFF;   // struct + imm = override
    if (overrideOffset < 0x24) { return false; }
    uint32_t setOffset = overrideOffset - 0x24;           // override = set + 0x24

    // The patched sequence branches over the function's remaining work to its epilogue.
    // Confirm the epilogue is where the old patch found it (site + 0x60) before trusting it.
    uint32_t epilogue = 0;
    if (!EndfieldRuntimeReadMemory((char *)site + 0x60, &epilogue, sizeof(epilogue))) {
        return false;
    }
    if (epilogue != 0xA9417BFD) {   // ldp x29, x30, [sp, #0x10]
        EndfieldRuntimeLog(@"[ZEF] resolution: override epilogue not at +0x60 (%08x), skipped",
                           epilogue);
        return false;
    }

    uint32_t patched[5] = {
        0x91000000u | (setOffset << 10) | (8u << 5) | 8u,  // add x8, x8, #setOffset
        0x29405113u,                                        // ldp w19, w20, [x8]
        0x91009108u,                                        // add x8, x8, #0x24
        0x29005113u,                                        // stp w19, w20, [x8]  (override = set)
        0x14000014u,                                        // b site + 0x60 (epilogue)
    };
    if (!EndfieldRuntimeWriteMemory(site, patched, sizeof(patched))) {
        EndfieldRuntimeLog(@"[ZEF] resolution: override write failed");
        return false;
    }
    EndfieldRuntimeLog(@"[ZEF] resolution: patched SetOverrideResolution @ %p (set=+0x%x)",
                       site, setOffset);
    return true;
}

/// dyld calls this for every image as it is added - including the ones already loaded when we
/// register, and UnityFramework whenever it shows up. Patching here is early enough to beat the
/// renderer's first read.
static void ef_res_image_added(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (ef_res_patched) { return; }
    if (!EndfieldRuntimeImageIsUnityFramework(header)) { return; }
    ef_res_patch_native();
    ef_res_patch_override();
}

void EndfieldResolutionFixStart(void) {
    if (!EndfieldRuntimeIsGame()) { return; }
    ef_res_read_target();
    _dyld_register_func_for_add_image(ef_res_image_added);
}
