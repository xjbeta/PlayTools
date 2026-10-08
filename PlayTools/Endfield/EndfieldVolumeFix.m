//
//  EndfieldVolumeFix.m
//  PlayTools
//
//  Endfield master-volume boost.
//
//  The in-game volume cannot exceed 100% through Wwise: the master RTPC
//  (au_rtpc_global_vol) tops out at 0 dB, AudioControlUtil.SetVolumeByType clamps to 1.0, and
//  AkSoundEngine.SetOutputVolume(AK_INVALID_SHARE_SET_ID, ...) returns AK_Success but does not
//  affect the main output. So the gain has to be added downstream of Wwise.
//
//  Wwise renders through AkAVAudioEngineSink, i.e. an AVAudioSourceNode into an AVAudioEngine.
//  We wrap the source node's render block and multiply the float samples it produces by the
//  boost - no change to the audio graph, so it cannot deadlock the engine. (Inserting an EQ into
//  the graph was tried first: it either did nothing or crashed the game.)
//
//  Version robustness: this touches no game symbol, offset or metadata - only the Apple
//  AVAudioSourceNode selector - so it survives game updates. If a future build renders a format
//  other than float32, the samples are passed through untouched (boost silently off) instead of
//  being corrupted; if it stops using AVAudioSourceNode at all, the swizzle simply never fires.
//
//  endfieldVolumeBoost is a percentage: 100 = off, 150 = x1.5 (~ +3.5 dB). Endfield only.
//

#import "EndfieldVolumeFix.h"
#import "EndfieldRuntime.h"

#import <AVFAudio/AVFAudio.h>
#import <PlayTools/PlayTools-Swift.h>
#import <objc/runtime.h>

static float ef_vol_linear = 1.0f;

/// Scale one render buffer in place (float32 samples, interleaved or not).
static void ef_vol_scale_buffers(AudioBufferList *data) {
    if (data == NULL || ef_vol_linear == 1.0f) { return; }
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        AudioBuffer *buffer = &data->mBuffers[b];
        float *samples = (float *)buffer->mData;
        if (samples == NULL) { continue; }
        UInt32 count = buffer->mDataByteSize / (UInt32)sizeof(float);
        for (UInt32 i = 0; i < count; i++) {
            float v = samples[i] * ef_vol_linear;
            samples[i] = v > 1.0f ? 1.0f : (v < -1.0f ? -1.0f : v);   // clamp, avoid wrap
        }
    }
}

@implementation AVAudioSourceNode (EndfieldVolumeFix)

- (instancetype)efvol_initWithFormat:(AVAudioFormat *)format
                         renderBlock:(AVAudioSourceNodeRenderBlock)block {
    // Only float32 buffers can be scaled safely. Anything else passes through, so a future change
    // to the sink's format degrades to "no boost" rather than noise.
    BOOL scalable = (format != nil) && (format.commonFormat == AVAudioPCMFormatFloat32);
    AVAudioSourceNodeRenderBlock wrapped =
        ^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                  AVAudioFrameCount frameCount, AudioBufferList *data) {
        OSStatus status = block(isSilence, timestamp, frameCount, data);
        if (status == noErr && scalable) { ef_vol_scale_buffers(data); }
        return status;
    };
    static bool logged = false;
    if (!logged) {
        logged = true;
        EndfieldRuntimeLog(@"[ZEF] volume: AVAudioSourceNode wrapped (fmt %ld, %.0f Hz, %u ch, "
                           @"x%.3f, scalable=%d)",
                           (long)format.commonFormat, format.sampleRate,
                           (unsigned)format.channelCount, ef_vol_linear, (int)scalable);
    }
    return [self efvol_initWithFormat:format renderBlock:wrapped];
}

@end

void EndfieldVolumeFixStart(void) {
    if (!EndfieldRuntimeIsGame()) { return; }

    double percent = [[PlaySettings shared] endfieldVolumeBoost];
    if (percent <= 100.0) { return; }            // 100% = no boost
    if (ef_vol_linear != 1.0f) { return; }        // already installed

    ef_vol_linear = (float)(percent / 100.0);

    Class cls = objc_getClass("AVAudioSourceNode");
    if (cls == Nil) {
        EndfieldRuntimeLog(@"[ZEF] volume: AVAudioSourceNode not loaded");
        EndfieldRuntimeNote("volume", false);
        return;
    }
    Method original = class_getInstanceMethod(cls, @selector(initWithFormat:renderBlock:));
    Method replacement = class_getInstanceMethod(cls, @selector(efvol_initWithFormat:renderBlock:));
    if (original == NULL || replacement == NULL) {
        EndfieldRuntimeNote("volume", false);
        return;
    }
    method_exchangeImplementations(original, replacement);

    EndfieldRuntimeNote("volume", true);
    EndfieldRuntimeLog(@"[ZEF] volume: %.0f%% (x%.3f, +%.2f dB)",
                       percent, ef_vol_linear, 20.0 * log10((double)ef_vol_linear));
}
