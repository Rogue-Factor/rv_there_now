#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MA_NO_WAV
#define MA_NO_FLAC
#define MINIAUDIO_IMPLEMENTATION
#include "vendor/miniaudio.h"
#include "spatial_audio.h"

#define STOP_EVENT_NAME L"Local\\RVThereNowRadioStop"
#define PLAY_EVENT_NAME L"Local\\RVThereNowRadioPlay"
#define USER_AGENT L"RVThereNow-RadioBridge/0.1"
#define REWIND_CACHE_SIZE (1024 * 1024)
#define STREAM_SAMPLE_RATE 48000
#define STREAM_CHANNELS 1
#define STREAM_BUFFER_SECONDS 8
#define STREAM_READY_SECONDS 2
#define NATIVE_READ_FRAMES 4096

typedef struct HttpStream {
    HINTERNET session;
    HINTERNET connection;
    HINTERNET request;
    unsigned char* rewind_cache;
    size_t rewind_cache_size;
    uint64_t cursor;
    uint64_t network_position;
    DWORD icy_metaint;
    DWORD icy_audio_remaining;
    volatile LONG ended;
    volatile LONG failed;
} HttpStream;

static wchar_t g_status_path[MAX_PATH];
static wchar_t g_url_path[MAX_PATH];
static wchar_t g_now_playing_path[MAX_PATH];
static HMODULE g_module;
static HANDLE g_worker_thread;
static SRWLOCK g_worker_lock = SRWLOCK_INIT;

static void initialize_temp_paths(void)
{
    wchar_t temp_path[MAX_PATH];
    DWORD length = GetTempPathW(MAX_PATH, temp_path);
    if (length == 0 || length >= MAX_PATH) {
        wcscpy(g_status_path, L"rv-there-now-radio.status");
        wcscpy(g_url_path, L"rv-there-now-radio.url");
        wcscpy(g_now_playing_path, L"rv-there-now-radio.nowplaying");
        return;
    }
    _snwprintf(g_status_path, MAX_PATH - 1, L"%lsrv-there-now-radio.status", temp_path);
    g_status_path[MAX_PATH - 1] = L'\0';
    _snwprintf(g_url_path, MAX_PATH - 1, L"%lsrv-there-now-radio.url", temp_path);
    g_url_path[MAX_PATH - 1] = L'\0';
    _snwprintf(g_now_playing_path, MAX_PATH - 1,
        L"%lsrv-there-now-radio.nowplaying", temp_path);
    g_now_playing_path[MAX_PATH - 1] = L'\0';
}

static int read_url_file(wchar_t* url, size_t capacity)
{
    FILE* file;
    char utf8[8192];
    size_t length;
    int converted;
    if (capacity == 0) {
        return 0;
    }

    file = _wfopen(g_url_path, L"rb");
    if (file == NULL) {
        return 0;
    }
    length = fread(utf8, 1, sizeof(utf8) - 1, file);
    fclose(file);
    while (length > 0 && (utf8[length - 1] == '\r' || utf8[length - 1] == '\n'
            || utf8[length - 1] == ' ' || utf8[length - 1] == '\t')) {
        --length;
    }
    utf8[length] = '\0';
    converted = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1,
        url, (int)capacity);
    if (converted <= 0) {
        return 0;
    }
    return _wcsnicmp(url, L"https://", 8) == 0 || _wcsnicmp(url, L"http://", 7) == 0;
}

static void write_status(const wchar_t* status)
{
    FILE* file = _wfopen(g_status_path, L"wb");
    int needed;
    char* utf8;
    if (file == NULL) {
        return;
    }

    needed = WideCharToMultiByte(CP_UTF8, 0, status, -1, NULL, 0, NULL, NULL);
    if (needed <= 1) {
        fclose(file);
        return;
    }
    utf8 = (char*)malloc((size_t)needed);
    if (utf8 != NULL) {
        WideCharToMultiByte(CP_UTF8, 0, status, -1, utf8, needed, NULL, NULL);
        fwrite(utf8, 1, (size_t)needed - 1, file);
        free(utf8);
    }
    fclose(file);
}

static void write_now_playing(const unsigned char* value, size_t length)
{
    FILE* file;
    while (length > 0 && (value[length - 1] == '\0' || value[length - 1] == ' ')) {
        --length;
    }
    if (length == 0 || length > 512) return;
    file = _wfopen(g_now_playing_path, L"wb");
    if (file == NULL) return;
    fwrite(value, 1, length, file);
    fclose(file);
}

static void close_http_stream(HttpStream* stream)
{
    if (stream->request != NULL) {
        WinHttpCloseHandle(stream->request);
    }
    if (stream->connection != NULL) {
        WinHttpCloseHandle(stream->connection);
    }
    if (stream->session != NULL) {
        WinHttpCloseHandle(stream->session);
    }
    free(stream->rewind_cache);
    memset(stream, 0, sizeof(*stream));
}

static int open_http_stream(const wchar_t* url, HttpStream* stream, int request_metadata)
{
    URL_COMPONENTS parts;
    wchar_t host[512];
    wchar_t path[4096];
    wchar_t extra[4096];
    wchar_t request_path[8192];
    DWORD status_code = 0;
    DWORD status_size = sizeof(status_code);
    DWORD flags = 0;
    const wchar_t* headers = request_metadata
        ? L"Icy-MetaData: 1\r\nCache-Control: no-cache\r\n"
        : L"Icy-MetaData: 0\r\nCache-Control: no-cache\r\n";

    memset(stream, 0, sizeof(*stream));
    stream->rewind_cache = (unsigned char*)malloc(REWIND_CACHE_SIZE);
    if (stream->rewind_cache == NULL) {
        return 0;
    }
    memset(&parts, 0, sizeof(parts));
    parts.dwStructSize = sizeof(parts);
    parts.lpszHostName = host;
    parts.dwHostNameLength = (DWORD)(sizeof(host) / sizeof(host[0]));
    parts.lpszUrlPath = path;
    parts.dwUrlPathLength = (DWORD)(sizeof(path) / sizeof(path[0]));
    parts.lpszExtraInfo = extra;
    parts.dwExtraInfoLength = (DWORD)(sizeof(extra) / sizeof(extra[0]));

    if (!WinHttpCrackUrl(url, 0, 0, &parts)) {
        close_http_stream(stream);
        return 0;
    }
    if (parts.dwUrlPathLength + parts.dwExtraInfoLength + 1
        >= (DWORD)(sizeof(request_path) / sizeof(request_path[0]))) {
        close_http_stream(stream);
        return 0;
    }
    memcpy(request_path, path, (size_t)parts.dwUrlPathLength * sizeof(wchar_t));
    memcpy(request_path + parts.dwUrlPathLength, extra,
        (size_t)parts.dwExtraInfoLength * sizeof(wchar_t));
    request_path[parts.dwUrlPathLength + parts.dwExtraInfoLength] = L'\0';
    host[parts.dwHostNameLength] = L'\0';

    stream->session = WinHttpOpen(USER_AGENT, WINHTTP_ACCESS_TYPE_NO_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (stream->session == NULL) {
        close_http_stream(stream);
        return 0;
    }
    WinHttpSetTimeouts(stream->session, 5000, 5000, 5000, 10000);

    stream->connection = WinHttpConnect(stream->session, host, parts.nPort, 0);
    if (stream->connection == NULL) {
        close_http_stream(stream);
        return 0;
    }
    if (parts.nScheme == INTERNET_SCHEME_HTTPS) {
        flags |= WINHTTP_FLAG_SECURE;
    }
    stream->request = WinHttpOpenRequest(stream->connection, L"GET", request_path, NULL,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (stream->request == NULL) {
        close_http_stream(stream);
        return 0;
    }
    if (!WinHttpAddRequestHeaders(stream->request, headers, (DWORD)-1,
            WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE)
        || !WinHttpSendRequest(stream->request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
            WINHTTP_NO_REQUEST_DATA, 0, 0, 0)
        || !WinHttpReceiveResponse(stream->request, NULL)) {
        close_http_stream(stream);
        return 0;
    }
    if (!WinHttpQueryHeaders(stream->request,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &status_size,
            WINHTTP_NO_HEADER_INDEX)
        || status_code < 200 || status_code >= 300) {
        close_http_stream(stream);
        return 0;
    }
    if (request_metadata) {
        wchar_t metaint[32];
        DWORD metaint_size = sizeof(metaint);
        if (WinHttpQueryHeaders(stream->request, WINHTTP_QUERY_CUSTOM,
                L"icy-metaint", metaint, &metaint_size, WINHTTP_NO_HEADER_INDEX)) {
            stream->icy_metaint = (DWORD)_wtoi(metaint);
            stream->icy_audio_remaining = stream->icy_metaint;
        }
    }
    return 1;
}

static int winhttp_read_exact(HINTERNET request, unsigned char* output, DWORD length)
{
    DWORD total = 0;
    while (total < length) {
        DWORD received = 0;
        if (!WinHttpReadData(request, output + total, length - total, &received)
            || received == 0) {
            return 0;
        }
        total += received;
    }
    return 1;
}

static void consume_icy_metadata(HttpStream* stream)
{
    unsigned char length_byte = 0;
    unsigned char metadata[4096 + 1];
    DWORD metadata_length;
    const char* marker;
    const char* end;
    if (!winhttp_read_exact(stream->request, &length_byte, 1)) {
        InterlockedExchange(&stream->failed, 1);
        InterlockedExchange(&stream->ended, 1);
        return;
    }
    metadata_length = (DWORD)length_byte * 16;
    if (metadata_length == 0) {
        stream->icy_audio_remaining = stream->icy_metaint;
        return;
    }
    if (metadata_length > sizeof(metadata) - 1
        || !winhttp_read_exact(stream->request, metadata, metadata_length)) {
        InterlockedExchange(&stream->failed, 1);
        InterlockedExchange(&stream->ended, 1);
        return;
    }
    metadata[metadata_length] = '\0';
    marker = strstr((const char*)metadata, "StreamTitle='");
    if (marker != NULL) {
        marker += strlen("StreamTitle='");
        end = strstr(marker, "';");
        if (end != NULL && end > marker) {
            write_now_playing((const unsigned char*)marker, (size_t)(end - marker));
        }
    }
    stream->icy_audio_remaining = stream->icy_metaint;
}

static int read_stream_audio(HttpStream* stream, unsigned char* output,
    DWORD requested, DWORD* received)
{
    *received = 0;
    while (stream->icy_metaint > 0 && stream->icy_audio_remaining == 0) {
        consume_icy_metadata(stream);
        if (InterlockedCompareExchange(&stream->ended, 0, 0) != 0) return 0;
    }
    if (stream->icy_metaint > 0 && requested > stream->icy_audio_remaining) {
        requested = stream->icy_audio_remaining;
    }
    if (!WinHttpReadData(stream->request, output, requested, received)) return 0;
    if (stream->icy_metaint > 0) stream->icy_audio_remaining -= *received;
    return 1;
}

static ma_result decoder_read(ma_decoder* decoder, void* output, size_t bytes_to_read, size_t* bytes_read)
{
    HttpStream* stream = (HttpStream*)decoder->pUserData;
    unsigned char* destination = (unsigned char*)output;
    size_t total = 0;
    *bytes_read = 0;

    if (InterlockedCompareExchange(&stream->ended, 0, 0) != 0) {
        return MA_AT_END;
    }
    while (total < bytes_to_read) {
        if (stream->cursor < stream->rewind_cache_size) {
            size_t available = stream->rewind_cache_size - (size_t)stream->cursor;
            size_t amount = bytes_to_read - total;
            if (amount > available) {
                amount = available;
            }
            memcpy(destination + total, stream->rewind_cache + (size_t)stream->cursor, amount);
            stream->cursor += amount;
            total += amount;
            continue;
        }

        if (stream->cursor == stream->network_position) {
            DWORD requested = bytes_to_read - total > UINT32_MAX
                ? UINT32_MAX
                : (DWORD)(bytes_to_read - total);
            DWORD received = 0;
            if (!read_stream_audio(stream, destination + total, requested, &received)) {
                InterlockedExchange(&stream->failed, 1);
                InterlockedExchange(&stream->ended, 1);
                *bytes_read = total;
                return total > 0 ? MA_SUCCESS : MA_ERROR;
            }
            if (received == 0) {
                InterlockedExchange(&stream->ended, 1);
                break;
            }
            if (stream->rewind_cache_size < REWIND_CACHE_SIZE) {
                size_t room = REWIND_CACHE_SIZE - stream->rewind_cache_size;
                size_t amount = received < room ? received : room;
                memcpy(stream->rewind_cache + stream->rewind_cache_size,
                    destination + total, amount);
                stream->rewind_cache_size += amount;
            }
            stream->cursor += received;
            stream->network_position += received;
            total += received;
            continue;
        }

        InterlockedExchange(&stream->failed, 1);
        *bytes_read = total;
        return total > 0 ? MA_SUCCESS : MA_BAD_SEEK;
    }
    *bytes_read = total;
    return total > 0 ? MA_SUCCESS : MA_AT_END;
}

static ma_result decoder_seek(ma_decoder* decoder, ma_int64 offset, ma_seek_origin origin)
{
    HttpStream* stream = (HttpStream*)decoder->pUserData;
    int64_t base;
    int64_t target;

    if (origin == ma_seek_origin_start) {
        base = 0;
    } else if (origin == ma_seek_origin_current) {
        base = (int64_t)stream->cursor;
    } else {
        return MA_BAD_SEEK;
    }
    if ((offset > 0 && base > INT64_MAX - offset)
        || (offset < 0 && base < INT64_MIN - offset)) {
        return MA_BAD_SEEK;
    }
    target = base + offset;
    if (target < 0) {
        return MA_BAD_SEEK;
    }
    if ((uint64_t)target <= stream->rewind_cache_size
        || (uint64_t)target == stream->network_position) {
        stream->cursor = (uint64_t)target;
        return MA_SUCCESS;
    }
    return MA_BAD_SEEK;
}

static int signal_existing_bridge(void)
{
    HANDLE event = OpenEventW(EVENT_MODIFY_STATE, FALSE, STOP_EVENT_NAME);
    if (event == NULL) {
        return 0;
    }
    SetEvent(event);
    CloseHandle(event);
    return 1;
}

static HANDLE create_stop_event(void)
{
    HANDLE event = CreateEventW(NULL, TRUE, FALSE, STOP_EVENT_NAME);
    if (event != NULL && GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(event);
        return NULL;
    }
    return event;
}

static int signal_named_event(const wchar_t* name)
{
    HANDLE event = OpenEventW(EVENT_MODIFY_STATE, FALSE, name);
    if (event == NULL) return 0;
    SetEvent(event);
    CloseHandle(event);
    return 1;
}

typedef struct NativeStreamPlayer {
    ma_device device;
    ma_pcm_rb ring;
    HANDLE play_event;
    HANDLE control_thread;
    volatile LONG started;
    volatile LONG confirmed;
    volatile LONG shutting_down;
    volatile LONG status_confirmed;
    int initialized;
} NativeStreamPlayer;

static void confirm_native_output(NativeStreamPlayer* player,
    const int16_t* samples, size_t frames)
{
    size_t frame;
    if (InterlockedCompareExchange(&player->confirmed, 0, 0) != 0) return;
    for (frame = 0; frame < frames; ++frame) {
        if (samples[frame] == 0) continue;
        InterlockedExchange(&player->confirmed, 1);
        return;
    }
}

static DWORD WINAPI native_control_thread(void* context)
{
    NativeStreamPlayer* player = (NativeStreamPlayer*)context;
    while (InterlockedCompareExchange(&player->shutting_down, 0, 0) == 0) {
        if (InterlockedCompareExchange(&player->started, 0, 0) == 0
            && WaitForSingleObject(player->play_event, 0) == WAIT_OBJECT_0) {
            InterlockedExchange(&player->started, 1);
        }
        spatial_audio_update();
        if (InterlockedCompareExchange(&player->confirmed, 0, 0) != 0) {
            if (InterlockedCompareExchange(&player->status_confirmed, 1, 0) == 0) {
                write_status(L"PLAYING");
            }
        }
        Sleep(50);
    }
    return 0;
}

static void native_stream_callback(
    ma_device* device, void* output, const void* input, ma_uint32 frame_count)
{
    NativeStreamPlayer* player = (NativeStreamPlayer*)device->pUserData;
    int16_t* stereo = (int16_t*)output;
    ma_uint32 written = 0;
    (void)input;
    memset(stereo, 0, (size_t)frame_count * 2 * sizeof(int16_t));
    if (InterlockedCompareExchange(&player->started, 0, 0) == 0) return;
    while (written < frame_count) {
        ma_uint32 available = frame_count - written;
        void* buffer = NULL;
        if (ma_pcm_rb_acquire_read(&player->ring, &available, &buffer) != MA_SUCCESS
            || available == 0) break;
        confirm_native_output(player, (const int16_t*)buffer, available);
        spatial_audio_mono_to_stereo_s16((const int16_t*)buffer,
            stereo + (size_t)written * 2, available);
        ma_pcm_rb_commit_read(&player->ring, available);
        written += available;
    }
}

static int native_stream_player_init(NativeStreamPlayer* player, unsigned int sample_rate)
{
    ma_device_config config;
    memset(player, 0, sizeof(*player));
    if (ma_pcm_rb_init(ma_format_s16, STREAM_CHANNELS,
            sample_rate * STREAM_BUFFER_SECONDS, NULL, NULL, &player->ring) != MA_SUCCESS) {
        return 0;
    }
    player->play_event = CreateEventW(NULL, TRUE, FALSE, PLAY_EVENT_NAME);
    if (player->play_event == NULL || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (player->play_event != NULL) CloseHandle(player->play_event);
        ma_pcm_rb_uninit(&player->ring);
        return 0;
    }
    config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_s16;
    config.playback.channels = 2;
    config.sampleRate = sample_rate;
    config.dataCallback = native_stream_callback;
    config.pUserData = player;
    if (ma_device_init(NULL, &config, &player->device) != MA_SUCCESS) {
        CloseHandle(player->play_event);
        ma_pcm_rb_uninit(&player->ring);
        return 0;
    }
    player->initialized = 1;
    player->control_thread = CreateThread(NULL, 0, native_control_thread, player, 0, NULL);
    if (player->control_thread == NULL) {
        ma_device_uninit(&player->device);
        CloseHandle(player->play_event);
        ma_pcm_rb_uninit(&player->ring);
        player->initialized = 0;
        return 0;
    }
    if (ma_device_start(&player->device) != MA_SUCCESS) {
        InterlockedExchange(&player->shutting_down, 1);
        WaitForSingleObject(player->control_thread, INFINITE);
        CloseHandle(player->control_thread);
        player->control_thread = NULL;
        ma_device_uninit(&player->device);
        CloseHandle(player->play_event);
        ma_pcm_rb_uninit(&player->ring);
        player->initialized = 0;
        return 0;
    }
    return 1;
}

static void native_stream_player_uninit(NativeStreamPlayer* player)
{
    InterlockedExchange(&player->shutting_down, 1);
    if (player->initialized) ma_device_uninit(&player->device);
    if (player->control_thread != NULL) {
        WaitForSingleObject(player->control_thread, INFINITE);
        CloseHandle(player->control_thread);
        player->control_thread = NULL;
    }
    if (player->play_event != NULL) CloseHandle(player->play_event);
    ma_pcm_rb_uninit(&player->ring);
    player->initialized = 0;
}

static int run_stream_pcm(const wchar_t* url)
{
    HANDLE stop_event;
    HttpStream stream;
    ma_decoder decoder;
    ma_decoder_config decoder_config;
    ma_result result;
    int ready = 0;
    int exit_code = 0;
    NativeStreamPlayer player;

    memset(&player, 0, sizeof(player));

    write_status(L"OPENING Live stream decoder");
    stop_event = create_stop_event();
    if (stop_event == NULL) {
        write_status(L"ERROR Could not acquire bridge event");
        return 60;
    }
    if (!open_http_stream(url, &stream, 1)) {
        write_status(L"ERROR HTTP connection failed");
        CloseHandle(stop_event);
        return 61;
    }
    decoder_config = ma_decoder_config_init(
        ma_format_s16, STREAM_CHANNELS, STREAM_SAMPLE_RATE);
    result = ma_decoder_init(decoder_read, decoder_seek, &stream, &decoder_config, &decoder);
    if (result != MA_SUCCESS) {
        write_status(L"ERROR Stream decoder initialization failed");
        close_http_stream(&stream);
        CloseHandle(stop_event);
        return 62;
    }
    if (!native_stream_player_init(&player, STREAM_SAMPLE_RATE)) {
        write_status(L"ERROR Native audio output initialization failed");
        ma_decoder_uninit(&decoder);
        close_http_stream(&stream);
        CloseHandle(stop_event);
        return 64;
    }
    write_status(L"BUFFERING Live stream");

    for (;;) {
        ma_uint32 frames_to_write;
        void* write_buffer = NULL;
        ma_uint64 frames_read = 0;
        if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0) goto cleanup;
        frames_to_write = ma_pcm_rb_available_write(&player.ring);
        if (frames_to_write == 0) {
            if (WaitForSingleObject(stop_event, 10) == WAIT_OBJECT_0) goto cleanup;
            continue;
        }
        if (frames_to_write > NATIVE_READ_FRAMES) frames_to_write = NATIVE_READ_FRAMES;
        if (ma_pcm_rb_acquire_write(&player.ring, &frames_to_write, &write_buffer)
                != MA_SUCCESS || frames_to_write == 0) {
            write_status(L"ERROR Could not acquire stream buffer");
            exit_code = 67;
            goto cleanup;
        }
        result = ma_decoder_read_pcm_frames(
            &decoder, write_buffer, frames_to_write, &frames_read);
        if (frames_read > 0) {
            ma_pcm_rb_commit_write(&player.ring, (ma_uint32)frames_read);
        } else {
            ma_pcm_rb_commit_write(&player.ring, 0);
        }
        if (result != MA_SUCCESS && result != MA_AT_END) {
            write_status(L"ERROR Live stream decoding failed");
            exit_code = 65;
            goto cleanup;
        }
        if (result == MA_AT_END || frames_read == 0) {
            write_status(L"ERROR Live stream ended");
            exit_code = 66;
            goto cleanup;
        }
        if (!ready && ma_pcm_rb_available_read(&player.ring)
                >= STREAM_SAMPLE_RATE * STREAM_READY_SECONDS) {
            ready = 1;
            write_status(L"STREAM_READY 48000\t1");
        }
    }

cleanup:
    native_stream_player_uninit(&player);
    ma_decoder_uninit(&decoder);
    close_http_stream(&stream);
    CloseHandle(stop_event);
    if (exit_code == 0) write_status(L"OFF");
    return exit_code;
}

static int run_launch_request(void)
{
    wchar_t url_from_file[4096];

    initialize_temp_paths();
    spatial_audio_initialize();
    DeleteFileW(g_now_playing_path);
    if (!read_url_file(url_from_file, sizeof(url_from_file) / sizeof(url_from_file[0]))) {
        write_status(L"ERROR Invalid or missing stream URL");
        return 1;
    }
    return run_stream_pcm(url_from_file);
}

static DWORD WINAPI bridge_worker(void* parameter)
{
    HMODULE worker_module = (HMODULE)parameter;
    DWORD result = (DWORD)run_launch_request();
    FreeLibraryAndExitThread(worker_module, result);
    return result;
}

__declspec(dllexport) int __cdecl rvtn_play(void* lua_state)
{
    (void)lua_state;
    signal_named_event(PLAY_EVENT_NAME);
    return 0;
}

__declspec(dllexport) int __cdecl rvtn_stop(void* lua_state)
{
    (void)lua_state;
    signal_named_event(STOP_EVENT_NAME);
    return 0;
}

__declspec(dllexport) int __cdecl rvtn_launch(void* lua_state)
{
    wchar_t module_path[MAX_PATH];
    HMODULE worker_module;
    DWORD wait_result;
    (void)lua_state;

    initialize_temp_paths();
    AcquireSRWLockExclusive(&g_worker_lock);
    if (g_worker_thread != NULL) {
        wait_result = WaitForSingleObject(g_worker_thread, 0);
        if (wait_result == WAIT_TIMEOUT) {
            signal_existing_bridge();
            wait_result = WaitForSingleObject(g_worker_thread, 3000);
        }
        if (wait_result == WAIT_TIMEOUT) {
            write_status(L"ERROR Previous radio worker did not stop");
            ReleaseSRWLockExclusive(&g_worker_lock);
            return 0;
        }
        CloseHandle(g_worker_thread);
        g_worker_thread = NULL;
    }

    if (GetModuleFileNameW(g_module, module_path, MAX_PATH) == 0) {
        write_status(L"ERROR Could not retain radio bridge DLL");
        ReleaseSRWLockExclusive(&g_worker_lock);
        return 0;
    }
    module_path[MAX_PATH - 1] = L'\0';
    worker_module = LoadLibraryW(module_path);
    if (worker_module == NULL) {
        write_status(L"ERROR Could not retain radio bridge DLL");
        ReleaseSRWLockExclusive(&g_worker_lock);
        return 0;
    }
    g_worker_thread = CreateThread(NULL, 0, bridge_worker, worker_module, 0, NULL);
    if (g_worker_thread == NULL) {
        FreeLibrary(worker_module);
        write_status(L"ERROR Could not start radio bridge thread");
    }
    ReleaseSRWLockExclusive(&g_worker_lock);
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}
