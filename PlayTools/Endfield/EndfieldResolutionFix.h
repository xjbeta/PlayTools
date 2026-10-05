//
//  EndfieldResolutionFix.h
//  PlayTools
//
//  Endfield render-resolution fix, resolved at runtime. See EndfieldResolutionFix.m.
//

#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Forces the render resolution to PlayCover's window x customScaler by intercepting
/// UnityEngine.Screen.SetResolution. Name-based and in-memory; a no-op when missing.
void EndfieldResolutionFixStart(void);

#ifdef __cplusplus
}
#endif
