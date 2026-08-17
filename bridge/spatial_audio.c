#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

#include "spatial_audio.h"

#define SPATIAL_SCALE 10000

static wchar_t g_spatial_path[MAX_PATH];
static volatile LONG g_left_gain = SPATIAL_SCALE;
static volatile LONG g_right_gain = SPATIAL_SCALE;

static LONG clamp_gain(double gain)
{
    if (gain < 0.0) return 0;
    if (gain > 1.0) return SPATIAL_SCALE;
    return (LONG)(gain * SPATIAL_SCALE + 0.5);
}

void spatial_audio_initialize(void)
{
    wchar_t temp_path[MAX_PATH];
    DWORD length = GetTempPathW(MAX_PATH, temp_path);
    if (length == 0 || length >= MAX_PATH) {
        wcscpy(g_spatial_path, L"rv-there-now-radio.spatial");
    } else {
        _snwprintf(g_spatial_path, MAX_PATH - 1,
            L"%lsrv-there-now-radio.spatial", temp_path);
        g_spatial_path[MAX_PATH - 1] = L'\0';
    }
}

void spatial_audio_update(void)
{
    FILE* file = _wfopen(g_spatial_path, L"rb");
    double left;
    double right;
    if (file == NULL) return;
    if (fscanf(file, "%lf %lf", &left, &right) == 2) {
        InterlockedExchange(&g_left_gain, clamp_gain(left));
        InterlockedExchange(&g_right_gain, clamp_gain(right));
    }
    fclose(file);
}

void spatial_audio_apply_f32(float* samples, size_t frames, unsigned int channels)
{
    const float left = (float)InterlockedCompareExchange(&g_left_gain, 0, 0)
        / (float)SPATIAL_SCALE;
    const float right = (float)InterlockedCompareExchange(&g_right_gain, 0, 0)
        / (float)SPATIAL_SCALE;
    size_t frame;
    if (channels == 0) return;
    for (frame = 0; frame < frames; ++frame) {
        float* sample = samples + frame * channels;
        if (channels == 1) {
            sample[0] *= (left + right) * 0.5f;
        } else {
            sample[0] *= left;
            sample[1] *= right;
        }
    }
}

void spatial_audio_apply_s16(int16_t* samples, size_t frames, unsigned int channels)
{
    const LONG left = InterlockedCompareExchange(&g_left_gain, 0, 0);
    const LONG right = InterlockedCompareExchange(&g_right_gain, 0, 0);
    size_t frame;
    if (channels == 0) return;
    for (frame = 0; frame < frames; ++frame) {
        int16_t* sample = samples + frame * channels;
        if (channels == 1) {
            sample[0] = (int16_t)(((LONG)sample[0] * ((left + right) / 2))
                / SPATIAL_SCALE);
        } else {
            sample[0] = (int16_t)(((LONG)sample[0] * left) / SPATIAL_SCALE);
            sample[1] = (int16_t)(((LONG)sample[1] * right) / SPATIAL_SCALE);
        }
    }
}

void spatial_audio_mono_to_stereo_s16(
    const int16_t* input, int16_t* output, size_t frames)
{
    const LONG left = InterlockedCompareExchange(&g_left_gain, 0, 0);
    const LONG right = InterlockedCompareExchange(&g_right_gain, 0, 0);
    size_t frame;
    for (frame = 0; frame < frames; ++frame) {
        const LONG sample = input[frame];
        output[frame * 2] = (int16_t)((sample * left) / SPATIAL_SCALE);
        output[frame * 2 + 1] = (int16_t)((sample * right) / SPATIAL_SCALE);
    }
}
