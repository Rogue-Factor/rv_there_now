#ifndef RV_YOUTUBE_RESOLVER_H
#define RV_YOUTUBE_RESOLVER_H

#include <windows.h>

typedef void (*YoutubeStatusCallback)(const wchar_t* status);

int youtube_is_url(const wchar_t* url);
int youtube_download_audio(
    const wchar_t* url_file,
    wchar_t* audio_path,
    size_t audio_path_capacity,
    HANDLE stop_event,
    const wchar_t* watched_process,
    YoutubeStatusCallback write_status);

#endif
