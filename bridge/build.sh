#!/usr/bin/env bash

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OUTPUT="$ROOT/mod/bin/rv-radio-bridge.exe"

mkdir -p "$(dirname "$OUTPUT")"
x86_64-w64-mingw32-gcc \
    -std=c11 -O2 -s -mwindows -municode \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    "$ROOT/bridge/rv_radio_bridge.c" \
    "$ROOT/bridge/mf_audio.c" \
    "$ROOT/bridge/spatial_audio.c" \
    "$ROOT/bridge/youtube_resolver.c" \
    -o "$OUTPUT" \
    -lwinhttp -lmfreadwrite -lmfplat -lmfuuid -lole32 -lshell32 -lws2_32

printf '%s\n' "$OUTPUT"
