#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>

#include "youtube_resolver.h"

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

static int file_is_ready(const wchar_t* path)
{
    WIN32_FILE_ATTRIBUTE_DATA data;
    ULARGE_INTEGER size;
    if (!GetFileAttributesExW(path, GetFileExInfoStandard, &data)) {
        return 0;
    }
    size.LowPart = data.nFileSizeLow;
    size.HighPart = data.nFileSizeHigh;
    return size.QuadPart > 1024;
}

static int module_directory(wchar_t* directory, size_t capacity)
{
    DWORD length = GetModuleFileNameW(NULL, directory, (DWORD)capacity);
    wchar_t* separator;
    if (length == 0 || length >= capacity) {
        return 0;
    }
    separator = wcsrchr(directory, L'\\');
    if (separator == NULL) {
        return 0;
    }
    *separator = L'\0';
    return 1;
}

int youtube_is_url(const wchar_t* url)
{
    const wchar_t* host;
    size_t host_length;
    if (_wcsnicmp(url, L"https://", 8) == 0) {
        host = url + 8;
    } else if (_wcsnicmp(url, L"http://", 7) == 0) {
        host = url + 7;
    } else {
        return 0;
    }
    host_length = wcscspn(host, L"/:?");
    if (host_length == 8 && _wcsnicmp(host, L"youtu.be", 8) == 0) {
        return 1;
    }
    if (host_length == 11 && _wcsnicmp(host, L"youtube.com", 11) == 0) {
        return 1;
    }
    return host_length > 12
        && _wcsnicmp(host + host_length - 12, L".youtube.com", 12) == 0;
}

int youtube_download_audio(
    const wchar_t* url_file,
    wchar_t* audio_path,
    size_t audio_path_capacity,
    HANDLE stop_event,
    const wchar_t* watched_process,
    YoutubeStatusCallback write_status)
{
    wchar_t directory[4096];
    wchar_t resolver[4096];
    wchar_t quickjs[4096];
    wchar_t command[16384];
    wchar_t temp[MAX_PATH];
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD temp_length;
    DWORD exit_code = 1;
    int command_length;

    if (!module_directory(directory, sizeof(directory) / sizeof(directory[0]))) {
        write_status(L"ERROR YouTube helper path is unavailable");
        return 0;
    }
    _snwprintf(resolver, (sizeof(resolver) / sizeof(resolver[0])) - 1,
        L"%ls\\yt-dlp.exe", directory);
    _snwprintf(quickjs, (sizeof(quickjs) / sizeof(quickjs[0])) - 1,
        L"%ls\\qjs.exe", directory);
    if (GetFileAttributesW(resolver) == INVALID_FILE_ATTRIBUTES
        || GetFileAttributesW(quickjs) == INVALID_FILE_ATTRIBUTES) {
        write_status(L"ERROR Bundled YouTube helper is missing");
        return 0;
    }

    temp_length = GetTempPathW(MAX_PATH, temp);
    if (temp_length == 0 || temp_length >= MAX_PATH) {
        write_status(L"ERROR YouTube temporary path is unavailable");
        return 0;
    }
    _snwprintf(audio_path, audio_path_capacity - 1,
        L"%lsrv-there-now-youtube.m4a", temp);
    audio_path[audio_path_capacity - 1] = L'\0';
    DeleteFileW(audio_path);

    command_length = _snwprintf(command,
        (sizeof(command) / sizeof(command[0])) - 1,
        L"\"%ls\" --no-config --no-playlist --no-warnings "
        L"--js-runtimes \"quickjs:%ls\" -f \"ba[ext=m4a]\" "
        L"--match-filter \"!is_live\" --force-overwrites --no-part "
        L"-o \"%ls\" --batch-file \"%ls\"",
        resolver, quickjs, audio_path, url_file);
    if (command_length < 0
        || command_length >= (int)(sizeof(command) / sizeof(command[0])) - 1) {
        write_status(L"ERROR YouTube helper command is too long");
        return 0;
    }

    memset(&startup, 0, sizeof(startup));
    memset(&process, 0, sizeof(process));
    startup.cb = sizeof(startup);
    write_status(L"OPENING Downloading YouTube audio");
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW,
            NULL, directory, &startup, &process)) {
        write_status(L"ERROR Could not start YouTube helper");
        return 0;
    }
    CloseHandle(process.hThread);

    for (;;) {
        DWORD wait_result = WaitForSingleObject(process.hProcess, 100);
        if (wait_result == WAIT_OBJECT_0) {
            break;
        }
        if (WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0
            || !process_is_running(watched_process)) {
            TerminateProcess(process.hProcess, 2);
            WaitForSingleObject(process.hProcess, 5000);
            CloseHandle(process.hProcess);
            DeleteFileW(audio_path);
            return 0;
        }
    }
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    if (exit_code != 0 || !file_is_ready(audio_path)) {
        wchar_t status[128];
        _snwprintf(status, (sizeof(status) / sizeof(status[0])) - 1,
            L"ERROR YouTube audio download failed (helper exit %lu)", exit_code);
        status[(sizeof(status) / sizeof(status[0])) - 1] = L'\0';
        write_status(status);
        DeleteFileW(audio_path);
        return 0;
    }
    return 1;
}
