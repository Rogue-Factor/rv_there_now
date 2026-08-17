#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MA_NO_WAV
#define MA_NO_FLAC
#define MINIAUDIO_IMPLEMENTATION
#include "vendor/miniaudio.h"
#include "mf_audio.h"
#include "spatial_audio.h"
#include "youtube_resolver.h"

#define STOP_EVENT_NAME L"Local\\RVThereNowRadioStop"
#define USER_AGENT L"RVThereNow-RadioBridge/0.1"
#define REWIND_CACHE_SIZE (1024 * 1024)
#define RELAY_PORT_FIRST 18765
#define RELAY_PORT_LAST 18774
#define STREAM_SAMPLE_RATE 48000
#define STREAM_CHANNELS 1
#define STREAM_CHUNK_SECONDS 8
#define STREAM_READY_CHUNKS 1
#define STREAM_RETAIN_CHUNKS 3
#define ACCURADIO_MAX_TRACKS 64
#define NATIVE_READ_FRAMES 4096

typedef struct HttpStream {
    HINTERNET session;
    HINTERNET connection;
    HINTERNET request;
    unsigned char* rewind_cache;
    size_t rewind_cache_size;
    uint64_t cursor;
    uint64_t network_position;
    volatile LONG ended;
    volatile LONG failed;
} HttpStream;

typedef struct Playback {
    ma_decoder decoder;
    HttpStream* stream;
} Playback;

static wchar_t g_status_path[MAX_PATH];
static wchar_t g_url_path[MAX_PATH];
static wchar_t g_play_path[MAX_PATH];
static wchar_t g_confirm_path[MAX_PATH];

static void initialize_temp_paths(void)
{
    wchar_t temp_path[MAX_PATH];
    DWORD length = GetTempPathW(MAX_PATH, temp_path);
    if (length == 0 || length >= MAX_PATH) {
        wcscpy(g_status_path, L"rv-there-now-radio.status");
        wcscpy(g_url_path, L"rv-there-now-radio.url");
        wcscpy(g_play_path, L"rv-there-now-radio.play");
        wcscpy(g_confirm_path, L"rv-there-now-radio.playing");
        return;
    }
    _snwprintf(g_status_path, MAX_PATH - 1, L"%lsrv-there-now-radio.status", temp_path);
    g_status_path[MAX_PATH - 1] = L'\0';
    _snwprintf(g_url_path, MAX_PATH - 1, L"%lsrv-there-now-radio.url", temp_path);
    g_url_path[MAX_PATH - 1] = L'\0';
    _snwprintf(g_play_path, MAX_PATH - 1, L"%lsrv-there-now-radio.play", temp_path);
    g_play_path[MAX_PATH - 1] = L'\0';
    _snwprintf(g_confirm_path, MAX_PATH - 1,
        L"%lsrv-there-now-radio.playing", temp_path);
    g_confirm_path[MAX_PATH - 1] = L'\0';
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

static int open_http_stream(const wchar_t* url, HttpStream* stream)
{
    URL_COMPONENTS parts;
    wchar_t host[512];
    wchar_t path[4096];
    wchar_t extra[4096];
    wchar_t request_path[8192];
    DWORD status_code = 0;
    DWORD status_size = sizeof(status_code);
    DWORD flags = 0;
    const wchar_t* headers = L"Icy-MetaData: 0\r\nCache-Control: no-cache\r\n";

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
    return 1;
}

static int module_directory(wchar_t* directory, size_t capacity)
{
    DWORD length = GetModuleFileNameW(NULL, directory, (DWORD)capacity);
    wchar_t* separator;
    if (length == 0 || length >= capacity) return 0;
    separator = wcsrchr(directory, L'\\');
    if (separator == NULL) return 0;
    *separator = L'\0';
    return 1;
}

static int download_http_file(const wchar_t* url, const wchar_t* path)
{
    HttpStream stream;
    FILE* output;
    int succeeded = 0;

    if (!open_http_stream(url, &stream)) return 0;
    output = _wfopen(path, L"wb");
    if (output == NULL) {
        close_http_stream(&stream);
        return 0;
    }
    for (;;) {
        unsigned char buffer[32768];
        DWORD bytes_read = 0;
        if (!WinHttpReadData(stream.request, buffer, sizeof(buffer), &bytes_read)) break;
        if (bytes_read == 0) {
            succeeded = 1;
            break;
        }
        if (fwrite(buffer, 1, bytes_read, output) != bytes_read) break;
    }
    fclose(output);
    close_http_stream(&stream);
    if (!succeeded) DeleteFileW(path);
    return succeeded;
}

static int extract_accuradio_channel(const wchar_t* url, wchar_t channel[25])
{
    const wchar_t* host;
    const wchar_t* path;
    const wchar_t* marker = L"/channel/";
    size_t host_length;
    int index;

    if (_wcsnicmp(url, L"https://", 8) == 0) host = url + 8;
    else if (_wcsnicmp(url, L"http://", 7) == 0) host = url + 7;
    else return 0;
    host_length = wcscspn(host, L"/:?");
    if (!((host_length == 13 && _wcsnicmp(host, L"accuradio.com", 13) == 0)
        || (host_length == 17 && _wcsnicmp(host, L"www.accuradio.com", 17) == 0))) {
        return 0;
    }
    path = wcschr(host, L'/');
    if (path == NULL || _wcsnicmp(path, marker, wcslen(marker)) != 0) return 0;
    path += wcslen(marker);
    for (index = 0; index < 24; ++index) {
        wchar_t value = path[index];
        if (!((value >= L'0' && value <= L'9')
            || (value >= L'a' && value <= L'f')
            || (value >= L'A' && value <= L'F'))) {
            return 0;
        }
        channel[index] = value;
    }
    channel[24] = L'\0';
    return path[24] == L'\0' || path[24] == L'/' || path[24] == L'?' || path[24] == L'#';
}

static int resolve_accuradio_tracks(
    const wchar_t* channel,
    wchar_t tracks[ACCURADIO_MAX_TRACKS][4096],
    int* track_count)
{
    wchar_t temp[MAX_PATH];
    wchar_t playlist_path[MAX_PATH];
    wchar_t tracks_path[MAX_PATH];
    wchar_t playlist_url[1024];
    wchar_t directory[4096];
    wchar_t quickjs[4096];
    wchar_t script[4096];
    wchar_t command[16384];
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD exit_code = 1;
    FILE* file = NULL;
    char line[8192];
    int count = 0;
    int succeeded = 0;

    *track_count = 0;
    if (GetTempPathW(MAX_PATH, temp) == 0 || !module_directory(directory, 4096)) return 0;
    _snwprintf(playlist_path, MAX_PATH - 1, L"%lsrv-there-now-accuradio.json", temp);
    playlist_path[MAX_PATH - 1] = L'\0';
    _snwprintf(tracks_path, MAX_PATH - 1, L"%lsrv-there-now-accuradio.urls", temp);
    tracks_path[MAX_PATH - 1] = L'\0';
    _snwprintf(playlist_url, 1023,
        L"https://www.accuradio.com/playlist/json/%ls/?ando=0&intro=true&spotschedule=5488775f0d1140151d7e3402&fa=null&rand=%lu",
        channel, (unsigned long)GetTickCount());
    playlist_url[1023] = L'\0';
    _snwprintf(quickjs, 4095, L"%ls\\qjs.exe", directory);
    quickjs[4095] = L'\0';
    _snwprintf(script, 4095, L"%ls\\accuradio-resolver.js", directory);
    script[4095] = L'\0';
    DeleteFileW(playlist_path);
    DeleteFileW(tracks_path);
    if (!download_http_file(playlist_url, playlist_path)) goto cleanup;
    if (GetFileAttributesW(quickjs) == INVALID_FILE_ATTRIBUTES
        || GetFileAttributesW(script) == INVALID_FILE_ATTRIBUTES) goto cleanup;
    if (_snwprintf(command, (sizeof(command) / sizeof(command[0])) - 1,
            L"\"%ls\" --std \"%ls\" \"%ls\" \"%ls\"",
            quickjs, script, playlist_path, tracks_path) < 0) goto cleanup;
    memset(&startup, 0, sizeof(startup));
    memset(&process, 0, sizeof(process));
    startup.cb = sizeof(startup);
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW,
            NULL, directory, &startup, &process)) goto cleanup;
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, 30000);
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    if (exit_code != 0) goto cleanup;
    file = _wfopen(tracks_path, L"rb");
    if (file == NULL) goto cleanup;
    while (count < ACCURADIO_MAX_TRACKS && fgets(line, sizeof(line), file) != NULL) {
        size_t length = strcspn(line, "\r\n");
        line[length] = '\0';
        if (length == 0 || MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                line, -1, tracks[count], 4096) <= 0) continue;
        ++count;
    }
    fclose(file);
    file = NULL;
    succeeded = count > 0;
    *track_count = count;

cleanup:
    if (file != NULL) fclose(file);
    DeleteFileW(playlist_path);
    DeleteFileW(tracks_path);
    return succeeded;
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
            if (!WinHttpReadData(stream->request, destination + total, requested, &received)) {
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

static void audio_callback(ma_device* device, void* output, const void* input, ma_uint32 frame_count)
{
    Playback* playback = (Playback*)device->pUserData;
    ma_uint64 frames_read = 0;
    ma_result result;
    (void)input;

    memset(output, 0, (size_t)frame_count * 2 * sizeof(float));
    result = ma_decoder_read_pcm_frames(&playback->decoder, output, frame_count, &frames_read);
    spatial_audio_apply_f32((float*)output, (size_t)frames_read, 2);
    if (result != MA_SUCCESS && result != MA_AT_END) {
        InterlockedExchange(&playback->stream->failed, 1);
        InterlockedExchange(&playback->stream->ended, 1);
    }
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
    HANDLE event;
    int attempt;
    for (attempt = 0; attempt < 30; ++attempt) {
        event = CreateEventW(NULL, TRUE, FALSE, STOP_EVENT_NAME);
        if (event != NULL && GetLastError() != ERROR_ALREADY_EXISTS) {
            return event;
        }
        if (event != NULL) {
            SetEvent(event);
            CloseHandle(event);
        }
        Sleep(100);
    }
    return NULL;
}

static int process_is_running(const wchar_t* executable_name)
{
    HANDLE snapshot;
    PROCESSENTRY32W entry;
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

static int run_bridge(const wchar_t* url, float volume, const wchar_t* watched_process)
{
    HANDLE stop_event;
    HttpStream stream;
    Playback playback;
    ma_decoder_config decoder_config;
    ma_device_config device_config;
    ma_device device;
    ma_result result;
    DWORD wait_result;
    int exit_code = 0;

    write_status(L"OPENING");
    stop_event = create_stop_event();
    if (stop_event == NULL) {
        write_status(L"ERROR Could not acquire bridge event");
        return 2;
    }
    write_status(L"OPENING HTTP");
    if (!open_http_stream(url, &stream)) {
        write_status(L"ERROR HTTP connection failed");
        CloseHandle(stop_event);
        return 3;
    }

    write_status(L"OPENING DECODER");
    memset(&playback, 0, sizeof(playback));
    playback.stream = &stream;
    decoder_config = ma_decoder_config_init(ma_format_f32, 2, 48000);
    result = ma_decoder_init(decoder_read, decoder_seek, &stream, &decoder_config, &playback.decoder);
    if (result != MA_SUCCESS) {
        write_status(L"ERROR MP3 decoder initialization failed");
        close_http_stream(&stream);
        CloseHandle(stop_event);
        return 4;
    }

    write_status(L"OPENING OUTPUT");
    device_config = ma_device_config_init(ma_device_type_playback);
    device_config.playback.format = ma_format_f32;
    device_config.playback.channels = 2;
    device_config.sampleRate = 48000;
    device_config.dataCallback = audio_callback;
    device_config.pUserData = &playback;
    result = ma_device_init(NULL, &device_config, &device);
    if (result != MA_SUCCESS) {
        write_status(L"ERROR Audio output initialization failed");
        ma_decoder_uninit(&playback.decoder);
        close_http_stream(&stream);
        CloseHandle(stop_event);
        return 5;
    }
    ma_device_set_master_volume(&device, volume);
    result = ma_device_start(&device);
    if (result != MA_SUCCESS) {
        write_status(L"ERROR Audio output start failed");
        ma_device_uninit(&device);
        ma_decoder_uninit(&playback.decoder);
        close_http_stream(&stream);
        CloseHandle(stop_event);
        return 6;
    }

    write_status(L"PLAYING RV positional audio");
    for (;;) {
        wait_result = WaitForSingleObject(stop_event, 100);
        if (wait_result == WAIT_OBJECT_0) {
            break;
        }
        if (!process_is_running(watched_process)) {
            break;
        }
        spatial_audio_update();
        if (InterlockedCompareExchange(&stream.ended, 0, 0) != 0) {
            if (InterlockedCompareExchange(&stream.failed, 0, 0) != 0) {
                write_status(L"ERROR Stream read failed");
                exit_code = 7;
            } else {
                write_status(L"ERROR Stream ended");
                exit_code = 8;
            }
            break;
        }
    }

    ma_device_uninit(&device);
    ma_decoder_uninit(&playback.decoder);
    close_http_stream(&stream);
    CloseHandle(stop_event);
    if (exit_code == 0) {
        write_status(L"OFF");
    }
    return exit_code;
}

static int socket_send_all(SOCKET client, const char* data, int length)
{
    int offset = 0;
    while (offset < length) {
        int sent = send(client, data + offset, length - offset, 0);
        if (sent <= 0) return 0;
        offset += sent;
    }
    return 1;
}

static int run_relay(const wchar_t* url, const wchar_t* watched_process)
{
    static const char response[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: audio/mpeg\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n";
    WSADATA winsock;
    SOCKET server = INVALID_SOCKET;
    HANDLE stop_event;
    unsigned short port;
    int exit_code = 0;
    wchar_t ready_status[128];

    write_status(L"OPENING Local RV audio relay");
    stop_event = create_stop_event();
    if (stop_event == NULL) {
        write_status(L"ERROR Could not acquire bridge event");
        return 40;
    }
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        write_status(L"ERROR Local relay networking failed");
        CloseHandle(stop_event);
        return 41;
    }

    for (port = RELAY_PORT_FIRST; port <= RELAY_PORT_LAST; ++port) {
        struct sockaddr_in address;
        server = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (server == INVALID_SOCKET) break;
        memset(&address, 0, sizeof(address));
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(port);
        if (bind(server, (const struct sockaddr*)&address, sizeof(address)) == 0
            && listen(server, 1) == 0) {
            break;
        }
        closesocket(server);
        server = INVALID_SOCKET;
    }
    if (server == INVALID_SOCKET) {
        write_status(L"ERROR No local relay port is available");
        WSACleanup();
        CloseHandle(stop_event);
        return 42;
    }

    _snwprintf(ready_status, (sizeof(ready_status) / sizeof(ready_status[0])) - 1,
        L"READY http://127.0.0.1:%u/rv-radio.mp3", (unsigned int)port);
    ready_status[(sizeof(ready_status) / sizeof(ready_status[0])) - 1] = L'\0';
    write_status(ready_status);

    for (;;) {
        fd_set readable;
        struct timeval timeout;
        SOCKET client;
        HttpStream stream;
        char request[4096];
        int received;

        if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
            || !process_is_running(watched_process)) {
            break;
        }
        FD_ZERO(&readable);
        FD_SET(server, &readable);
        timeout.tv_sec = 0;
        timeout.tv_usec = 100000;
        if (select(0, &readable, NULL, NULL, &timeout) <= 0) continue;
        client = accept(server, NULL, NULL);
        if (client == INVALID_SOCKET) continue;

        received = recv(client, request, sizeof(request), 0);
        if (received <= 0 || !open_http_stream(url, &stream)) {
            closesocket(client);
            write_status(ready_status);
            continue;
        }
        if (!socket_send_all(client, response, (int)strlen(response))) {
            close_http_stream(&stream);
            closesocket(client);
            write_status(ready_status);
            continue;
        }

        write_status(L"PLAYING Unreal RV audio");
        for (;;) {
            unsigned char buffer[32768];
            DWORD bytes_read = 0;
            if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
                || !process_is_running(watched_process)) {
                break;
            }
            if (!WinHttpReadData(stream.request, buffer, sizeof(buffer), &bytes_read)
                || bytes_read == 0
                || !socket_send_all(client, (const char*)buffer, (int)bytes_read)) {
                break;
            }
        }
        close_http_stream(&stream);
        closesocket(client);
        if (WaitForSingleObject(stop_event, 0) != WAIT_OBJECT_0) {
            write_status(ready_status);
        }
    }

    closesocket(server);
    WSACleanup();
    CloseHandle(stop_event);
    write_status(L"OFF");
    return exit_code;
}

static int write_pcm_chunk(
    const wchar_t* prefix,
    unsigned int sequence,
    const int16_t* samples,
    size_t byte_count)
{
    wchar_t final_path[MAX_PATH];
    wchar_t partial_path[MAX_PATH];
    FILE* file;

    _snwprintf(final_path, MAX_PATH - 1, L"%ls.%06u.pcm", prefix, sequence);
    final_path[MAX_PATH - 1] = L'\0';
    _snwprintf(partial_path, MAX_PATH - 1, L"%ls.%06u.part", prefix, sequence);
    partial_path[MAX_PATH - 1] = L'\0';
    file = _wfopen(partial_path, L"wb");
    if (file == NULL) return 0;
    if (fwrite(samples, 1, byte_count, file) != byte_count || fclose(file) != 0) {
        DeleteFileW(partial_path);
        return 0;
    }
    if (!MoveFileExW(partial_path, final_path,
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(partial_path);
        return 0;
    }
    return 1;
}

static int pcm_chunk_exists(const wchar_t* prefix, unsigned int sequence)
{
    wchar_t path[MAX_PATH];
    _snwprintf(path, MAX_PATH - 1, L"%ls.%06u.pcm", prefix, sequence);
    path[MAX_PATH - 1] = L'\0';
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

static void delete_pcm_chunks(const wchar_t* prefix, unsigned int count)
{
    unsigned int sequence;
    for (sequence = 0; sequence < count; ++sequence) {
        wchar_t path[MAX_PATH];
        _snwprintf(path, MAX_PATH - 1, L"%ls.%06u.pcm", prefix, sequence);
        path[MAX_PATH - 1] = L'\0';
        DeleteFileW(path);
        _snwprintf(path, MAX_PATH - 1, L"%ls.%06u.part", prefix, sequence);
        path[MAX_PATH - 1] = L'\0';
        DeleteFileW(path);
    }
}

typedef struct NativeChunkPlayer {
    ma_device device;
    wchar_t prefix[MAX_PATH];
    FILE* current_file;
    HANDLE confirmation_thread;
    unsigned int sequence;
    DWORD last_spatial_update;
    volatile LONG started;
    volatile LONG confirmed;
    volatile LONG shutting_down;
    int initialized;
} NativeChunkPlayer;

static void confirm_native_output(NativeChunkPlayer* player,
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

static DWORD WINAPI native_confirmation_thread(void* context)
{
    NativeChunkPlayer* player = (NativeChunkPlayer*)context;
    while (InterlockedCompareExchange(&player->shutting_down, 0, 0) == 0) {
        if (InterlockedCompareExchange(&player->confirmed, 0, 0) != 0) {
            HANDLE marker = CreateFileW(g_confirm_path, GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
            if (marker != INVALID_HANDLE_VALUE) {
                CloseHandle(marker);
                return 0;
            }
        }
        Sleep(10);
    }
    return 0;
}

static int read_play_sequence(unsigned int* sequence)
{
    FILE* file = _wfopen(g_play_path, L"rb");
    unsigned int value = 0;
    if (file == NULL) return 0;
    if (fscanf(file, "%u", &value) != 1) {
        fclose(file);
        return 0;
    }
    fclose(file);
    *sequence = value;
    return 1;
}

static void native_chunk_callback(
    ma_device* device, void* output, const void* input, ma_uint32 frame_count)
{
    NativeChunkPlayer* player = (NativeChunkPlayer*)device->pUserData;
    int16_t* stereo = (int16_t*)output;
    ma_uint32 written = 0;
    (void)input;
    memset(stereo, 0, (size_t)frame_count * 2 * sizeof(int16_t));
    if (InterlockedCompareExchange(&player->started, 0, 0) == 0) {
        unsigned int sequence = 0;
        if (!read_play_sequence(&sequence)) return;
        player->sequence = sequence;
        InterlockedExchange(&player->started, 1);
    }
    if (GetTickCount() - player->last_spatial_update >= 50) {
        spatial_audio_update();
        player->last_spatial_update = GetTickCount();
    }
    while (written < frame_count) {
        int16_t mono[NATIVE_READ_FRAMES];
        size_t requested = frame_count - written;
        size_t received;
        if (requested > NATIVE_READ_FRAMES) requested = NATIVE_READ_FRAMES;
        if (player->current_file == NULL) {
            wchar_t path[MAX_PATH];
            _snwprintf(path, MAX_PATH - 1, L"%ls.%06u.pcm",
                player->prefix, player->sequence);
            path[MAX_PATH - 1] = L'\0';
            player->current_file = _wfopen(path, L"rb");
            if (player->current_file == NULL) return;
        }
        received = fread(mono, sizeof(int16_t), requested, player->current_file);
        if (received > 0) {
            confirm_native_output(player, mono, received);
            spatial_audio_mono_to_stereo_s16(
                mono, stereo + (size_t)written * 2, received);
            written += (ma_uint32)received;
        }
        if (received < requested) {
            wchar_t path[MAX_PATH];
            fclose(player->current_file);
            player->current_file = NULL;
            _snwprintf(path, MAX_PATH - 1, L"%ls.%06u.pcm",
                player->prefix, player->sequence);
            path[MAX_PATH - 1] = L'\0';
            DeleteFileW(path);
            ++player->sequence;
            if (received == 0) continue;
        }
    }
}

static int native_chunk_player_init(
    NativeChunkPlayer* player, const wchar_t* prefix, unsigned int sample_rate)
{
    ma_device_config config;
    memset(player, 0, sizeof(*player));
    wcsncpy(player->prefix, prefix, MAX_PATH - 1);
    player->prefix[MAX_PATH - 1] = L'\0';
    config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_s16;
    config.playback.channels = 2;
    config.sampleRate = sample_rate;
    config.dataCallback = native_chunk_callback;
    config.pUserData = player;
    if (ma_device_init(NULL, &config, &player->device) != MA_SUCCESS) return 0;
    player->initialized = 1;
    player->confirmation_thread = CreateThread(NULL, 0,
        native_confirmation_thread, player, 0, NULL);
    if (player->confirmation_thread == NULL) {
        ma_device_uninit(&player->device);
        player->initialized = 0;
        return 0;
    }
    if (ma_device_start(&player->device) != MA_SUCCESS) {
        InterlockedExchange(&player->shutting_down, 1);
        WaitForSingleObject(player->confirmation_thread, INFINITE);
        CloseHandle(player->confirmation_thread);
        player->confirmation_thread = NULL;
        ma_device_uninit(&player->device);
        player->initialized = 0;
        return 0;
    }
    return 1;
}

static void native_chunk_player_uninit(NativeChunkPlayer* player)
{
    InterlockedExchange(&player->shutting_down, 1);
    if (player->initialized) ma_device_uninit(&player->device);
    if (player->current_file != NULL) fclose(player->current_file);
    player->current_file = NULL;
    if (player->confirmation_thread != NULL) {
        WaitForSingleObject(player->confirmation_thread, INFINITE);
        CloseHandle(player->confirmation_thread);
        player->confirmation_thread = NULL;
    }
    player->initialized = 0;
}

static int run_stream_pcm(const wchar_t* url, const wchar_t* watched_process)
{
    HANDLE stop_event;
    HttpStream stream;
    ma_decoder decoder;
    ma_decoder_config decoder_config;
    ma_result result;
    int16_t* samples = NULL;
    const ma_uint64 frames_per_chunk = STREAM_SAMPLE_RATE * STREAM_CHUNK_SECONDS;
    const size_t bytes_per_chunk = (size_t)frames_per_chunk
        * STREAM_CHANNELS * sizeof(int16_t);
    wchar_t temp_path[MAX_PATH];
    wchar_t prefix[MAX_PATH];
    wchar_t status[MAX_PATH + 96];
    unsigned int sequence = 0;
    int exit_code = 0;
    NativeChunkPlayer player;

    prefix[0] = L'\0';
    memset(&player, 0, sizeof(player));

    write_status(L"OPENING Live stream decoder");
    stop_event = create_stop_event();
    if (stop_event == NULL) {
        write_status(L"ERROR Could not acquire bridge event");
        return 60;
    }
    if (!open_http_stream(url, &stream)) {
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
    if (GetTempPathW(MAX_PATH, temp_path) == 0
        || wcslen(temp_path) + 48 >= MAX_PATH) {
        write_status(L"ERROR Stream temporary path is unavailable");
        exit_code = 63;
        goto cleanup;
    }
    _snwprintf(prefix, MAX_PATH - 1, L"%lsrv-there-now-stream-%lu",
        temp_path, (unsigned long)GetCurrentProcessId());
    prefix[MAX_PATH - 1] = L'\0';
    samples = (int16_t*)malloc(bytes_per_chunk);
    if (samples == NULL) {
        write_status(L"ERROR Could not allocate stream PCM buffer");
        exit_code = 64;
        goto cleanup;
    }

    for (;;) {
        ma_uint64 frames_read = 0;
        ma_uint64 total_frames = 0;
        if (sequence >= STREAM_RETAIN_CHUNKS) {
            unsigned int oldest = sequence - STREAM_RETAIN_CHUNKS;
            while (pcm_chunk_exists(prefix, oldest)) {
                if (WaitForSingleObject(stop_event, 50) == WAIT_OBJECT_0
                    || !process_is_running(watched_process)) {
                    goto cleanup;
                }
            }
        }
        while (total_frames < frames_per_chunk) {
            if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
                || !process_is_running(watched_process)) {
                goto cleanup;
            }
            frames_read = 0;
            result = ma_decoder_read_pcm_frames(&decoder,
                samples + (size_t)total_frames * STREAM_CHANNELS,
                frames_per_chunk - total_frames, &frames_read);
            total_frames += frames_read;
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
        }
        if (!write_pcm_chunk(prefix, sequence, samples, bytes_per_chunk)) {
            write_status(L"ERROR Could not write live stream buffer");
            exit_code = 67;
            goto cleanup;
        }
        ++sequence;
        if (sequence == 1
            && !native_chunk_player_init(&player, prefix, STREAM_SAMPLE_RATE)) {
            write_status(L"ERROR Native audio output initialization failed");
            exit_code = 68;
            goto cleanup;
        }
        if (sequence < STREAM_READY_CHUNKS) {
            _snwprintf(status, (sizeof(status) / sizeof(status[0])) - 1,
                L"BUFFERING Live stream %u / %u", sequence,
                (unsigned int)STREAM_READY_CHUNKS);
            status[(sizeof(status) / sizeof(status[0])) - 1] = L'\0';
            write_status(status);
        } else if (sequence == STREAM_READY_CHUNKS) {
            _snwprintf(status, (sizeof(status) / sizeof(status[0])) - 1,
                L"STREAM_PCM %ls\t%u\t%u\t%u", prefix,
                (unsigned int)STREAM_SAMPLE_RATE,
                (unsigned int)STREAM_CHANNELS,
                (unsigned int)STREAM_CHUNK_SECONDS);
            status[(sizeof(status) / sizeof(status[0])) - 1] = L'\0';
            write_status(status);
        }
    }

cleanup:
    native_chunk_player_uninit(&player);
    free(samples);
    if (prefix[0] != L'\0') delete_pcm_chunks(prefix, sequence);
    ma_decoder_uninit(&decoder);
    close_http_stream(&stream);
    CloseHandle(stop_event);
    if (exit_code == 0) write_status(L"OFF");
    return exit_code;
}

static int run_accuradio_pcm(const wchar_t* url, const wchar_t* watched_process)
{
    HANDLE stop_event;
    wchar_t channel[25];
    wchar_t temp_path[MAX_PATH];
    wchar_t prefix[MAX_PATH];
    wchar_t source_path[MAX_PATH];
    wchar_t decoded_path[MAX_PATH];
    wchar_t status[MAX_PATH + 96];
    wchar_t tracks[ACCURADIO_MAX_TRACKS][4096];
    unsigned char* chunk = NULL;
    size_t chunk_size = 0;
    size_t chunk_used = 0;
    UINT32 stream_rate = 0;
    UINT32 stream_channels = 0;
    unsigned int sequence = 0;
    int exit_code = 0;
    NativeChunkPlayer player;

    prefix[0] = L'\0';
    memset(&player, 0, sizeof(player));
    if (!extract_accuradio_channel(url, channel)) {
        write_status(L"ERROR Invalid AccuRadio channel URL");
        return 70;
    }
    stop_event = create_stop_event();
    if (stop_event == NULL) {
        write_status(L"ERROR Could not acquire bridge event");
        return 71;
    }
    if (GetTempPathW(MAX_PATH, temp_path) == 0 || wcslen(temp_path) + 64 >= MAX_PATH) {
        write_status(L"ERROR AccuRadio temporary path is unavailable");
        CloseHandle(stop_event);
        return 72;
    }
    _snwprintf(prefix, MAX_PATH - 1, L"%lsrv-there-now-stream-%lu",
        temp_path, (unsigned long)GetCurrentProcessId());
    prefix[MAX_PATH - 1] = L'\0';
    _snwprintf(source_path, MAX_PATH - 1, L"%ls-accuradio.m4a", prefix);
    source_path[MAX_PATH - 1] = L'\0';
    _snwprintf(decoded_path, MAX_PATH - 1, L"%ls-accuradio.pcm", prefix);
    decoded_path[MAX_PATH - 1] = L'\0';

    for (;;) {
        int track_count = 0;
        int track_index;
        write_status(L"OPENING AccuRadio playlist");
        if (!resolve_accuradio_tracks(channel, tracks, &track_count)) {
            write_status(L"ERROR Could not resolve AccuRadio playlist");
            exit_code = 73;
            break;
        }
        for (track_index = 0; track_index < track_count; ++track_index) {
            UINT32 sample_rate = 0;
            UINT32 channels = 0;
            double duration = 0.0;
            FILE* decoded;

            if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
                || !process_is_running(watched_process)) goto cleanup;
            write_status(sequence < STREAM_READY_CHUNKS
                ? L"BUFFERING AccuRadio tracks"
                : L"PLAYING AccuRadio track queue");
            DeleteFileW(source_path);
            if (!download_http_file(tracks[track_index], source_path)) {
                continue;
            }
            if (!mf_decode_audio_file_to_pcm(source_path, decoded_path, stop_event,
                    watched_process, &sample_rate, &channels, &duration, write_status)) {
                DeleteFileW(source_path);
                continue;
            }
            DeleteFileW(source_path);
            if (stream_rate == 0) {
                stream_rate = sample_rate;
                stream_channels = channels;
                chunk_size = (size_t)stream_rate * stream_channels
                    * sizeof(int16_t) * STREAM_CHUNK_SECONDS;
                chunk = (unsigned char*)malloc(chunk_size);
                if (chunk == NULL) {
                    write_status(L"ERROR Could not allocate AccuRadio PCM buffer");
                    exit_code = 74;
                    goto cleanup;
                }
            } else if (sample_rate != stream_rate || channels != stream_channels) {
                DeleteFileW(decoded_path);
                continue;
            }
            decoded = _wfopen(decoded_path, L"rb");
            if (decoded == NULL) continue;
            while (!feof(decoded)) {
                size_t amount = fread(chunk + chunk_used, 1, chunk_size - chunk_used, decoded);
                chunk_used += amount;
                if (chunk_used < chunk_size) {
                    if (ferror(decoded)) break;
                    continue;
                }
                if (sequence >= STREAM_RETAIN_CHUNKS) {
                    unsigned int oldest = sequence - STREAM_RETAIN_CHUNKS;
                    while (pcm_chunk_exists(prefix, oldest)) {
                        if (WaitForSingleObject(stop_event, 50) == WAIT_OBJECT_0
                            || !process_is_running(watched_process)) {
                            fclose(decoded);
                            goto cleanup;
                        }
                    }
                }
                if (!write_pcm_chunk(prefix, sequence, (const int16_t*)chunk, chunk_size)) {
                    fclose(decoded);
                    write_status(L"ERROR Could not write AccuRadio stream buffer");
                    exit_code = 75;
                    goto cleanup;
                }
                ++sequence;
                if (sequence == 1
                    && !native_chunk_player_init(&player, prefix, stream_rate)) {
                    fclose(decoded);
                    write_status(L"ERROR Native audio output initialization failed");
                    exit_code = 76;
                    goto cleanup;
                }
                chunk_used = 0;
                if (sequence < STREAM_READY_CHUNKS) {
                    _snwprintf(status, (sizeof(status) / sizeof(status[0])) - 1,
                        L"BUFFERING AccuRadio %u / %u", sequence,
                        (unsigned int)STREAM_READY_CHUNKS);
                    status[(sizeof(status) / sizeof(status[0])) - 1] = L'\0';
                    write_status(status);
                } else if (sequence == STREAM_READY_CHUNKS) {
                    _snwprintf(status, (sizeof(status) / sizeof(status[0])) - 1,
                        L"STREAM_PCM %ls\t%u\t%u\t%u", prefix,
                        (unsigned int)stream_rate, (unsigned int)stream_channels,
                        (unsigned int)STREAM_CHUNK_SECONDS);
                    status[(sizeof(status) / sizeof(status[0])) - 1] = L'\0';
                    write_status(status);
                }
            }
            fclose(decoded);
            DeleteFileW(decoded_path);
        }
    }

cleanup:
    native_chunk_player_uninit(&player);
    free(chunk);
    DeleteFileW(source_path);
    DeleteFileW(decoded_path);
    if (prefix[0] != L'\0') delete_pcm_chunks(prefix, sequence);
    CloseHandle(stop_event);
    if (exit_code == 0) write_status(L"OFF");
    return exit_code;
}

static int run_youtube_prepare(const wchar_t* watched_process)
{
    HANDLE stop_event;
    wchar_t audio_path[MAX_PATH];
    wchar_t pcm_path[MAX_PATH];
    wchar_t prefix[MAX_PATH];
    wchar_t ready_status[MAX_PATH + 96];
    UINT32 sample_rate = 0;
    UINT32 channels = 0;
    double duration_seconds = 0.0;
    unsigned char* chunk = NULL;
    size_t chunk_size = 0;
    unsigned int sequence = 0;
    int exit_code = 0;
    FILE* decoded = NULL;
    NativeChunkPlayer player;

    audio_path[0] = L'\0';
    pcm_path[0] = L'\0';
    prefix[0] = L'\0';
    memset(&player, 0, sizeof(player));

    write_status(L"OPENING YouTube helper");
    stop_event = create_stop_event();
    if (stop_event == NULL) {
        write_status(L"ERROR Could not acquire bridge event");
        return 50;
    }
    if (!youtube_download_audio(g_url_path, audio_path,
            sizeof(audio_path) / sizeof(audio_path[0]), stop_event,
            watched_process, write_status)) {
        if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
            || !process_is_running(watched_process)) {
            write_status(L"OFF");
        }
        exit_code = 51;
        goto cleanup;
    }
    if (GetTempPathW(MAX_PATH, pcm_path) == 0
        || wcslen(pcm_path) + wcslen(L"rv-there-now-youtube.pcm") + 1 >= MAX_PATH) {
        write_status(L"ERROR Could not create decoded audio path");
        exit_code = 53;
        goto cleanup;
    }
    wcscat(pcm_path, L"rv-there-now-youtube.pcm");
    if (!mf_decode_audio_file_to_pcm(audio_path, pcm_path, stop_event,
            watched_process, &sample_rate, &channels, &duration_seconds,
            write_status)) {
        exit_code = 54;
        goto cleanup;
    }
    DeleteFileW(audio_path);
    audio_path[0] = L'\0';
    if (channels != STREAM_CHANNELS || sample_rate == 0) {
        write_status(L"ERROR YouTube decoder returned unsupported PCM");
        exit_code = 55;
        goto cleanup;
    }
    _snwprintf(prefix, MAX_PATH - 1, L"%lsrv-there-now-stream-%lu",
        pcm_path, (unsigned long)GetCurrentProcessId());
    prefix[MAX_PATH - 1] = L'\0';
    chunk_size = (size_t)sample_rate * channels * sizeof(int16_t)
        * STREAM_CHUNK_SECONDS;
    chunk = (unsigned char*)malloc(chunk_size);
    if (chunk == NULL) {
        write_status(L"ERROR Could not allocate YouTube PCM buffer");
        exit_code = 56;
        goto cleanup;
    }
    decoded = _wfopen(pcm_path, L"rb");
    if (decoded == NULL) {
        write_status(L"ERROR Could not open decoded YouTube audio");
        exit_code = 57;
        goto cleanup;
    }
    for (;;) {
        size_t amount = fread(chunk, 1, chunk_size, decoded);
        if (amount == 0) break;
        if (!write_pcm_chunk(prefix, sequence, (const int16_t*)chunk, amount)) {
            write_status(L"ERROR Could not stage YouTube audio");
            exit_code = 58;
            goto cleanup;
        }
        ++sequence;
        if (amount < chunk_size) break;
    }
    fclose(decoded);
    decoded = NULL;
    DeleteFileW(pcm_path);
    pcm_path[0] = L'\0';
    if (sequence == 0) {
        write_status(L"ERROR Decoded YouTube audio was empty");
        exit_code = 59;
        goto cleanup;
    }
    if (!native_chunk_player_init(&player, prefix, sample_rate)) {
        write_status(L"ERROR Native audio output initialization failed");
        exit_code = 60;
        goto cleanup;
    }
    _snwprintf(ready_status, (sizeof(ready_status) / sizeof(ready_status[0])) - 1,
        L"STREAM_PCM %ls\t%u\t%u\t%u", prefix,
        (unsigned int)sample_rate, (unsigned int)channels,
        (unsigned int)STREAM_CHUNK_SECONDS);
    ready_status[(sizeof(ready_status) / sizeof(ready_status[0])) - 1] = L'\0';
    write_status(ready_status);

    while (WaitForSingleObject(stop_event, 100) != WAIT_OBJECT_0
        && process_is_running(watched_process)) {
    }

cleanup:
    native_chunk_player_uninit(&player);
    if (decoded != NULL) fclose(decoded);
    free(chunk);
    if (audio_path[0] != L'\0') DeleteFileW(audio_path);
    if (pcm_path[0] != L'\0') DeleteFileW(pcm_path);
    if (prefix[0] != L'\0') delete_pcm_chunks(prefix, sequence);
    CloseHandle(stop_event);
    if (exit_code == 0) write_status(L"OFF");
    return exit_code;
}

static int run_youtube_bridge(float volume, const wchar_t* watched_process)
{
    HANDLE stop_event;
    wchar_t audio_path[MAX_PATH];
    int result;

    write_status(L"OPENING YouTube helper");
    stop_event = create_stop_event();
    if (stop_event == NULL) {
        write_status(L"ERROR Could not acquire bridge event");
        return 30;
    }
    if (!youtube_download_audio(g_url_path, audio_path,
            sizeof(audio_path) / sizeof(audio_path[0]), stop_event,
            watched_process, write_status)) {
        if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
            || !process_is_running(watched_process)) {
            write_status(L"OFF");
        }
        CloseHandle(stop_event);
        return 31;
    }

    result = mf_play_audio_file(audio_path, volume, stop_event,
        watched_process, write_status);
    DeleteFileW(audio_path);
    CloseHandle(stop_event);
    return result;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show_command)
{
    int argument_count = 0;
    wchar_t** arguments;
    float volume = 0.5f;
    const wchar_t* watched_process = NULL;
    const wchar_t* url;
    wchar_t url_from_file[4096];
    int index;
    int result;
    (void)instance;
    (void)previous;
    (void)command_line;
    (void)show_command;

    initialize_temp_paths();
    spatial_audio_initialize();
    arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
    if (arguments == NULL || argument_count < 2) {
        write_status(L"ERROR Missing stream URL");
        return 1;
    }
    if (wcscmp(arguments[1], L"--stop") == 0) {
        result = signal_existing_bridge() ? 0 : 1;
        LocalFree(arguments);
        return result;
    }
    DeleteFileW(g_confirm_path);
    if (wcscmp(arguments[1], L"--url-file") == 0
        || wcscmp(arguments[1], L"--relay") == 0
        || wcscmp(arguments[1], L"--stream-pcm") == 0
        || wcscmp(arguments[1], L"--prepare-youtube") == 0) {
        if (!read_url_file(url_from_file, sizeof(url_from_file) / sizeof(url_from_file[0]))) {
            write_status(L"ERROR Invalid or missing stream URL");
            LocalFree(arguments);
            return 1;
        }
        url = url_from_file;
    } else {
        url = arguments[1];
    }
    for (index = 2; index + 1 < argument_count; index += 2) {
        if (wcscmp(arguments[index], L"--volume") == 0) {
            int percent = _wtoi(arguments[index + 1]);
            if (percent >= 0 && percent <= 100) {
                volume = (float)percent / 100.0f;
            }
        } else if (wcscmp(arguments[index], L"--watch") == 0) {
            watched_process = arguments[index + 1];
        }
    }

    if (wcscmp(arguments[1], L"--prepare-youtube") == 0) {
        result = youtube_is_url(url)
            ? run_youtube_prepare(watched_process)
            : 52;
        if (result == 52) write_status(L"ERROR Source is not a YouTube URL");
    } else if (wcscmp(arguments[1], L"--relay") == 0) {
        result = run_relay(url, watched_process);
    } else if (wcscmp(arguments[1], L"--stream-pcm") == 0) {
        wchar_t accuradio_channel[25];
        result = extract_accuradio_channel(url, accuradio_channel)
            ? run_accuradio_pcm(url, watched_process)
            : run_stream_pcm(url, watched_process);
    } else if (youtube_is_url(url) && wcscmp(arguments[1], L"--url-file") == 0) {
        result = run_youtube_bridge(volume, watched_process);
    } else {
        result = run_bridge(url, volume, watched_process);
    }
    LocalFree(arguments);
    return result;
}
