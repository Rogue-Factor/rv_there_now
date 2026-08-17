#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vendor/miniaudio.h"
#include "mf_audio.h"
#include "spatial_audio.h"

#define PCM_BUFFER_SIZE (4 * 1024 * 1024)
#define MAX_PCM_FILE_SIZE ((uint64_t)512 * 1024 * 1024)

typedef struct MfPlayback {
    wchar_t path[4096];
    unsigned char* pcm;
    size_t capacity;
    size_t read_position;
    size_t write_position;
    size_t used;
    UINT32 channels;
    UINT32 sample_rate;
    float volume;
    CRITICAL_SECTION lock;
    HANDLE ready_event;
    HANDLE thread;
    volatile LONG stop_requested;
    volatile LONG failed;
    volatile LONG ended;
    volatile LONG has_audio;
    HRESULT error;
} MfPlayback;

static int process_is_running(const wchar_t* executable_name)
{
    PROCESSENTRY32W entry;
    HANDLE snapshot;
    int found = 0;
    if (executable_name == NULL) {
        return 1;
    }

    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
        return 1;
    }
    memset(&entry, 0, sizeof(entry));
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            if (_wcsicmp(entry.szExeFile, executable_name) == 0) {
                found = 1;
                break;
            }
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return found;
}

int mf_decode_audio_file_to_pcm(
    const wchar_t* input_path,
    const wchar_t* output_path,
    HANDLE stop_event,
    const wchar_t* watched_process,
    UINT32* sample_rate,
    UINT32* channels,
    double* duration_seconds,
    MfStatusCallback write_status)
{
    IMFSourceReader* reader = NULL;
    IMFMediaType* requested_type = NULL;
    IMFMediaType* current_type = NULL;
    FILE* output = NULL;
    HRESULT result;
    uint64_t total_bytes = 0;
    int succeeded = 0;

    if (sample_rate == NULL || channels == NULL || duration_seconds == NULL) {
        return 0;
    }
    *sample_rate = 0;
    *channels = 0;
    *duration_seconds = 0.0;
    DeleteFileW(output_path);

    result = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(result)) {
        write_status(L"ERROR Could not initialize audio decoder");
        return 0;
    }
    result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (SUCCEEDED(result)) {
        result = MFCreateSourceReaderFromURL(input_path, NULL, &reader);
    }
    if (SUCCEEDED(result)) {
        result = IMFSourceReader_SetStreamSelection(reader,
            MF_SOURCE_READER_ALL_STREAMS, FALSE);
    }
    if (SUCCEEDED(result)) {
        result = IMFSourceReader_SetStreamSelection(reader,
            MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
    }
    if (SUCCEEDED(result)) result = MFCreateMediaType(&requested_type);
    if (SUCCEEDED(result)) {
        result = IMFMediaType_SetGUID(requested_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_SetGUID(requested_type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_SetUINT32(requested_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_SetUINT32(requested_type, &MF_MT_AUDIO_NUM_CHANNELS, 1);
    }
    if (SUCCEEDED(result)) {
        result = IMFSourceReader_SetCurrentMediaType(reader,
            MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, requested_type);
    }
    if (SUCCEEDED(result)) {
        result = IMFSourceReader_GetCurrentMediaType(reader,
            MF_SOURCE_READER_FIRST_AUDIO_STREAM, &current_type);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_GetUINT32(current_type,
            &MF_MT_AUDIO_NUM_CHANNELS, channels);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_GetUINT32(current_type,
            &MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate);
    }
    if (FAILED(result) || *channels == 0 || *channels > 8 || *sample_rate == 0) {
        write_status(L"ERROR AAC decoder failed");
        goto cleanup;
    }

    output = _wfopen(output_path, L"wb");
    if (output == NULL) {
        write_status(L"ERROR Could not create decoded audio file");
        goto cleanup;
    }
    write_status(L"DECODING Audio for Unreal");

    for (;;) {
        DWORD flags = 0;
        IMFSample* sample = NULL;
        IMFMediaBuffer* buffer = NULL;
        unsigned char* data = NULL;
        DWORD maximum_length = 0;
        DWORD current_length = 0;

        if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
            || !process_is_running(watched_process)) {
            goto cleanup;
        }
        result = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM,
            0, NULL, &flags, NULL, &sample);
        if (FAILED(result)) {
            write_status(L"ERROR AAC decoding failed");
            goto cleanup;
        }
        if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
            if (sample != NULL) IMFSample_Release(sample);
            break;
        }
        if (sample == NULL) continue;
        result = IMFSample_ConvertToContiguousBuffer(sample, &buffer);
        if (SUCCEEDED(result)) {
            result = IMFMediaBuffer_Lock(buffer, &data, &maximum_length, &current_length);
        }
        if (SUCCEEDED(result) && current_length > 0) {
            if (total_bytes + current_length > MAX_PCM_FILE_SIZE
                || fwrite(data, 1, current_length, output) != current_length) {
                if (data != NULL) IMFMediaBuffer_Unlock(buffer);
                if (buffer != NULL) IMFMediaBuffer_Release(buffer);
                IMFSample_Release(sample);
                write_status(total_bytes + current_length > MAX_PCM_FILE_SIZE
                    ? L"ERROR Audio is too long for Unreal procedural playback"
                    : L"ERROR Could not write decoded audio");
                goto cleanup;
            }
            total_bytes += current_length;
        }
        if (data != NULL) IMFMediaBuffer_Unlock(buffer);
        if (buffer != NULL) IMFMediaBuffer_Release(buffer);
        IMFSample_Release(sample);
        if (FAILED(result)) {
            write_status(L"ERROR AAC decoding failed");
            goto cleanup;
        }
    }

    if (total_bytes == 0) {
        write_status(L"ERROR Decoded YouTube audio was empty");
        goto cleanup;
    }
    *duration_seconds = (double)total_bytes
        / ((double)*sample_rate * (double)*channels * sizeof(int16_t));
    succeeded = 1;

cleanup:
    if (output != NULL) fclose(output);
    if (!succeeded) DeleteFileW(output_path);
    if (current_type != NULL) IMFMediaType_Release(current_type);
    if (requested_type != NULL) IMFMediaType_Release(requested_type);
    if (reader != NULL) IMFSourceReader_Release(reader);
    MFShutdown();
    CoUninitialize();
    return succeeded;
}

static void set_failure(MfPlayback* playback, HRESULT error)
{
    playback->error = error;
    InterlockedExchange(&playback->failed, 1);
    SetEvent(playback->ready_event);
}

static int push_pcm(MfPlayback* playback, const unsigned char* data, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        size_t available;
        size_t contiguous;
        size_t amount;
        if (InterlockedCompareExchange(&playback->stop_requested, 0, 0) != 0) {
            return 0;
        }

        EnterCriticalSection(&playback->lock);
        available = playback->capacity - playback->used;
        if (available == 0) {
            LeaveCriticalSection(&playback->lock);
            Sleep(5);
            continue;
        }
        contiguous = playback->capacity - playback->write_position;
        amount = length - offset;
        if (amount > available) amount = available;
        if (amount > contiguous) amount = contiguous;
        memcpy(playback->pcm + playback->write_position, data + offset, amount);
        playback->write_position = (playback->write_position + amount) % playback->capacity;
        playback->used += amount;
        LeaveCriticalSection(&playback->lock);
        offset += amount;
        InterlockedExchange(&playback->has_audio, 1);
    }
    return 1;
}

static DWORD WINAPI decode_thread(void* context)
{
    MfPlayback* playback = (MfPlayback*)context;
    IMFSourceReader* reader = NULL;
    IMFMediaType* requested_type = NULL;
    IMFMediaType* current_type = NULL;
    HRESULT result;

    result = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(result)) {
        set_failure(playback, result);
        return 1;
    }
    result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (SUCCEEDED(result)) {
        result = MFCreateSourceReaderFromURL(playback->path, NULL, &reader);
    }
    if (SUCCEEDED(result)) {
        result = IMFSourceReader_SetStreamSelection(reader,
            MF_SOURCE_READER_ALL_STREAMS, FALSE);
    }
    if (SUCCEEDED(result)) {
        result = IMFSourceReader_SetStreamSelection(reader,
            MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
    }
    if (SUCCEEDED(result)) {
        result = MFCreateMediaType(&requested_type);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_SetGUID(requested_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_SetGUID(requested_type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_SetUINT32(requested_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_SetUINT32(requested_type, &MF_MT_AUDIO_NUM_CHANNELS, 1);
    }
    if (SUCCEEDED(result)) {
        result = IMFSourceReader_SetCurrentMediaType(reader,
            MF_SOURCE_READER_FIRST_AUDIO_STREAM, NULL, requested_type);
    }
    if (SUCCEEDED(result)) {
        result = IMFSourceReader_GetCurrentMediaType(reader,
            MF_SOURCE_READER_FIRST_AUDIO_STREAM, &current_type);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_GetUINT32(current_type,
            &MF_MT_AUDIO_NUM_CHANNELS, &playback->channels);
    }
    if (SUCCEEDED(result)) {
        result = IMFMediaType_GetUINT32(current_type,
            &MF_MT_AUDIO_SAMPLES_PER_SECOND, &playback->sample_rate);
    }
    if (FAILED(result) || playback->channels == 0 || playback->channels > 8
        || playback->sample_rate == 0) {
        set_failure(playback, FAILED(result) ? result : E_FAIL);
        goto cleanup;
    }
    SetEvent(playback->ready_event);

    while (InterlockedCompareExchange(&playback->stop_requested, 0, 0) == 0) {
        DWORD flags = 0;
        IMFSample* sample = NULL;
        IMFMediaBuffer* buffer = NULL;
        unsigned char* data = NULL;
        DWORD maximum_length = 0;
        DWORD current_length = 0;

        result = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM,
            0, NULL, &flags, NULL, &sample);
        if (FAILED(result)) {
            set_failure(playback, result);
            break;
        }
        if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
            InterlockedExchange(&playback->ended, 1);
            if (sample != NULL) IMFSample_Release(sample);
            break;
        }
        if (sample == NULL) {
            continue;
        }
        result = IMFSample_ConvertToContiguousBuffer(sample, &buffer);
        if (SUCCEEDED(result)) {
            result = IMFMediaBuffer_Lock(buffer, &data, &maximum_length, &current_length);
        }
        if (SUCCEEDED(result) && current_length > 0) {
            if (!push_pcm(playback, data, current_length)) {
                IMFMediaBuffer_Unlock(buffer);
                IMFMediaBuffer_Release(buffer);
                IMFSample_Release(sample);
                break;
            }
        }
        if (data != NULL) IMFMediaBuffer_Unlock(buffer);
        if (buffer != NULL) IMFMediaBuffer_Release(buffer);
        IMFSample_Release(sample);
        if (FAILED(result)) {
            set_failure(playback, result);
            break;
        }
    }

cleanup:
    if (current_type != NULL) IMFMediaType_Release(current_type);
    if (requested_type != NULL) IMFMediaType_Release(requested_type);
    if (reader != NULL) IMFSourceReader_Release(reader);
    MFShutdown();
    CoUninitialize();
    return InterlockedCompareExchange(&playback->failed, 0, 0) != 0 ? 1 : 0;
}

static size_t buffered_bytes(MfPlayback* playback)
{
    size_t used;
    EnterCriticalSection(&playback->lock);
    used = playback->used;
    LeaveCriticalSection(&playback->lock);
    return used;
}

static void audio_callback(ma_device* device, void* output, const void* input, ma_uint32 frame_count)
{
    MfPlayback* playback = (MfPlayback*)device->pUserData;
    size_t requested = (size_t)frame_count * playback->channels * sizeof(int16_t);
    size_t copied = 0;
    int16_t* samples = (int16_t*)output;
    size_t index;
    (void)input;

    memset(output, 0, requested);
    EnterCriticalSection(&playback->lock);
    while (copied < requested && playback->used > 0) {
        size_t amount = requested - copied;
        size_t contiguous = playback->capacity - playback->read_position;
        if (amount > playback->used) amount = playback->used;
        if (amount > contiguous) amount = contiguous;
        memcpy((unsigned char*)output + copied,
            playback->pcm + playback->read_position, amount);
        playback->read_position = (playback->read_position + amount) % playback->capacity;
        playback->used -= amount;
        copied += amount;
    }
    LeaveCriticalSection(&playback->lock);

    if (playback->volume < 0.999f) {
        for (index = 0; index < copied / sizeof(int16_t); ++index) {
            samples[index] = (int16_t)((float)samples[index] * playback->volume);
        }
    }
    spatial_audio_apply_s16(samples,
        copied / (playback->channels * sizeof(int16_t)), playback->channels);
}

int mf_play_audio_file(
    const wchar_t* path,
    float volume,
    HANDLE stop_event,
    const wchar_t* watched_process,
    MfStatusCallback write_status)
{
    MfPlayback playback;
    ma_device_config device_config;
    ma_device device;
    ma_result audio_result;
    DWORD wait_result;
    int exit_code = 0;

    memset(&playback, 0, sizeof(playback));
    wcsncpy(playback.path, path, (sizeof(playback.path) / sizeof(playback.path[0])) - 1);
    playback.capacity = PCM_BUFFER_SIZE;
    playback.volume = volume;
    playback.pcm = (unsigned char*)malloc(playback.capacity);
    if (playback.pcm == NULL) {
        write_status(L"ERROR Could not allocate YouTube audio buffer");
        return 20;
    }
    InitializeCriticalSection(&playback.lock);
    playback.ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (playback.ready_event == NULL) {
        write_status(L"ERROR Could not create YouTube decoder event");
        DeleteCriticalSection(&playback.lock);
        free(playback.pcm);
        return 21;
    }
    playback.thread = CreateThread(NULL, 0, decode_thread, &playback, 0, NULL);
    if (playback.thread == NULL) {
        write_status(L"ERROR Could not start YouTube decoder");
        CloseHandle(playback.ready_event);
        DeleteCriticalSection(&playback.lock);
        free(playback.pcm);
        return 22;
    }

    write_status(L"OPENING YouTube decoder");
    wait_result = WaitForSingleObject(playback.ready_event, 30000);
    if (wait_result != WAIT_OBJECT_0
        || InterlockedCompareExchange(&playback.failed, 0, 0) != 0) {
        write_status(L"ERROR YouTube AAC decoder failed");
        exit_code = 23;
        goto cleanup_thread;
    }

    device_config = ma_device_config_init(ma_device_type_playback);
    device_config.playback.format = ma_format_s16;
    device_config.playback.channels = playback.channels;
    device_config.sampleRate = playback.sample_rate;
    device_config.dataCallback = audio_callback;
    device_config.pUserData = &playback;
    audio_result = ma_device_init(NULL, &device_config, &device);
    if (audio_result != MA_SUCCESS) {
        write_status(L"ERROR YouTube audio output initialization failed");
        exit_code = 24;
        goto cleanup_thread;
    }
    audio_result = ma_device_start(&device);
    if (audio_result != MA_SUCCESS) {
        write_status(L"ERROR YouTube audio output start failed");
        ma_device_uninit(&device);
        exit_code = 25;
        goto cleanup_thread;
    }

    write_status(L"PLAYING YouTube RV positional audio");
    for (;;) {
        wait_result = WaitForSingleObject(stop_event, 100);
        if (wait_result == WAIT_OBJECT_0 || !process_is_running(watched_process)) {
            break;
        }
        spatial_audio_update();
        if (InterlockedCompareExchange(&playback.failed, 0, 0) != 0
            && buffered_bytes(&playback) == 0) {
            write_status(L"ERROR YouTube AAC playback failed");
            exit_code = 26;
            break;
        }
        if (InterlockedCompareExchange(&playback.ended, 0, 0) != 0
            && buffered_bytes(&playback) == 0) {
            break;
        }
    }
    ma_device_uninit(&device);

cleanup_thread:
    InterlockedExchange(&playback.stop_requested, 1);
    WaitForSingleObject(playback.thread, INFINITE);
    CloseHandle(playback.thread);
    CloseHandle(playback.ready_event);
    DeleteCriticalSection(&playback.lock);
    free(playback.pcm);
    if (exit_code == 0) {
        write_status(L"OFF");
    }
    return exit_code;
}
