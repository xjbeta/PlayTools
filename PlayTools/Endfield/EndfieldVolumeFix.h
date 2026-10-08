//
//  EndfieldVolumeFix.h
//  PlayTools
//
//  Endfield: boost the master volume above 100% by scaling the samples Wwise renders through
//  its AVAudioSourceNode. The multiplier is the endfieldVolumeBoost setting (percent).
//  See EndfieldVolumeFix.m for why the Wwise volume APIs cannot be used for this.
//

#pragma once

/// Installs the render-buffer gain. Self-gated on the app bundle id and the setting (>100%).
void EndfieldVolumeFixStart(void);
