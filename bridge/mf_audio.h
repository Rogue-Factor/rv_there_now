#ifndef RV_MF_AUDIO_H
#define RV_MF_AUDIO_H

#include <windows.h>

typedef void (*MfStatusCallback)(const wchar_t* status);

int mf_decode_audio_file_to_pcm(
    const wchar_t* input_path,
    const wchar_t* output_path,
    HANDLE stop_event,
    const wchar_t* watched_process,
    UINT32* sample_rate,
    UINT32* channels,
    double* duration_seconds,
    MfStatusCallback write_status);

int mf_play_audio_file(
    const wchar_t* path,
    float volume,
    HANDLE stop_event,
    const wchar_t* watched_process,
    MfStatusCallback write_status);

#endif
