#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

static HMODULE g_module;

static void temporary_path(wchar_t* output, const wchar_t* name)
{
    wchar_t temporary[MAX_PATH];
    DWORD length = GetTempPathW(MAX_PATH, temporary);
    if (length == 0 || length >= MAX_PATH) {
        _snwprintf(output, MAX_PATH - 1, L"%ls", name);
    } else {
        _snwprintf(output, MAX_PATH - 1, L"%ls%ls", temporary, name);
    }
    output[MAX_PATH - 1] = L'\0';
}

static void write_launch_error(void)
{
    wchar_t status_path[MAX_PATH];
    FILE* file;
    temporary_path(status_path, L"rv-there-now-radio.status");
    file = _wfopen(status_path, L"wb");
    if (file != NULL) {
        fputs("ERROR Could not launch hidden radio worker", file);
        fclose(file);
    }
}

__declspec(dllexport) int __cdecl rvtn_launch(void* lua_state)
{
    wchar_t request_path[MAX_PATH];
    wchar_t launcher_path[MAX_PATH];
    wchar_t bridge_path[MAX_PATH];
    wchar_t command_line[MAX_PATH * 2];
    wchar_t* separator;
    char request[32];
    const wchar_t* mode;
    FILE* file;
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD length;
    (void)lua_state;

    temporary_path(request_path, L"rv-there-now-radio.launch");
    file = _wfopen(request_path, L"rb");
    if (file == NULL || fgets(request, sizeof(request), file) == NULL) {
        if (file != NULL) fclose(file);
        write_launch_error();
        return 0;
    }
    fclose(file);
    DeleteFileW(request_path);
    if (strncmp(request, "youtube", 7) == 0) {
        mode = L"--prepare-youtube";
    } else if (strncmp(request, "stream", 6) == 0) {
        mode = L"--stream-pcm";
    } else {
        write_launch_error();
        return 0;
    }

    length = GetModuleFileNameW(g_module, launcher_path, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) {
        write_launch_error();
        return 0;
    }
    separator = wcsrchr(launcher_path, L'\\');
    if (separator == NULL) {
        write_launch_error();
        return 0;
    }
    *separator = L'\0';
    _snwprintf(bridge_path, MAX_PATH - 1, L"%ls\\rv-radio-bridge.exe", launcher_path);
    bridge_path[MAX_PATH - 1] = L'\0';
    _snwprintf(command_line, (sizeof(command_line) / sizeof(command_line[0])) - 1,
        L"\"%ls\" %ls --watch Ride-Win64-Shipping.exe", bridge_path, mode);
    command_line[(sizeof(command_line) / sizeof(command_line[0])) - 1] = L'\0';

    memset(&startup, 0, sizeof(startup));
    memset(&process, 0, sizeof(process));
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    if (!CreateProcessW(bridge_path, command_line, NULL, NULL, FALSE,
            CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, NULL, NULL, &startup, &process)) {
        write_launch_error();
        return 0;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
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
