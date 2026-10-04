//
//  EndfieldGamepadMap.h
//  PlayTools
//
//  Independent fix for the Endfield GAMEPAD map key. Kept small and self-contained: the
//  keyboard/mouse mode switch belongs to the separate libUnityDesktopMode work, so this
//  module only handles the gamepad half.
//
//  The game's DeviceInfo.platform decides what the view button does:
//    platform 2 -> desktop binding (view button switches input mode)
//    platform 8 -> mobile binding  (view button opens the map)
//  While the game is in gamepad mode (inputType == 2) nothing keeps platform at 8, so the
//  map key breaks. This module maintains platform == 8 in gamepad mode and otherwise stays
//  out of the way.
//

#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void EndfieldGamepadMapStart(void);

/// Called from the keyboard path on a real key press; see the implementation for why.
void EndfieldGamepadMapKeyboardActivity(void);

#ifdef __cplusplus
}
#endif
