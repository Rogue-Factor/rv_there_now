#ifndef RV_SPATIAL_AUDIO_H
#define RV_SPATIAL_AUDIO_H

#include <stddef.h>
#include <stdint.h>

void spatial_audio_initialize(void);
void spatial_audio_update(void);
void spatial_audio_apply_f32(float* samples, size_t frames, unsigned int channels);
void spatial_audio_apply_s16(int16_t* samples, size_t frames, unsigned int channels);
void spatial_audio_mono_to_stereo_s16(
    const int16_t* input, int16_t* output, size_t frames);

#endif
