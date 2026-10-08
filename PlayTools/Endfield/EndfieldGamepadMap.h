//
//  EndfieldGamepadMap.h
//  PlayTools
//
//  Independent fix for the Endfield gamepad buttons. Kept small and self-contained.
//
//  Beyond.Input.InputManager._CheckGamepadKeyCode branches on DeviceInfo.isMobile for every
//  gamepad button: when false the pad is read through Rewired's GamepadTemplate, when true through
//  Unity's InputSystem Gamepad (which is what a real iOS device uses). This module removes those
//  branches, so the view button (⧉) opens the map and the view/menu long-press behaviour matches a
//  real device. Everything is resolved by name; a game update degrades to "no patch".
//

#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void EndfieldGamepadMapStart(void);

#ifdef __cplusplus
}
#endif
