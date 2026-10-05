//
//  EndfieldFpsFix.h
//  PlayTools
//
//  Endfield high-refresh fix (FPS x2), resolved at runtime. See EndfieldFpsFix.m.
//

#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Doubles the frame rate the game hands to UnityEngine.Application.set_targetFrameRate
/// (30/45/60 -> 60/90/120). Name-based and in-memory; a no-op when the target is missing.
void EndfieldFpsFixStart(void);

#ifdef __cplusplus
}
#endif
