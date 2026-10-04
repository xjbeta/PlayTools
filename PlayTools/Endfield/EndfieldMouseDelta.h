//
//  EndfieldMouseDelta.h
//  PlayTools
//
//  See EndfieldMouseDelta.m. Separate module so the gamepad map-key fix stays independent.
//

#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installs the GCMouse delta scaling. Endfield only - checks the bundle id itself.
void EndfieldMouseDeltaStart(void);

#ifdef __cplusplus
}
#endif
