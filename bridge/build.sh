#!/usr/bin/env bash

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OUTPUT="$ROOT/mod/bin/rv-radio-bridge.dll"

mkdir -p "$(dirname "$OUTPUT")"
x86_64-w64-mingw32-gcc \
    -std=c11 -O2 -s -shared \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    "$ROOT/bridge/rv_radio_bridge.c" \
    "$ROOT/bridge/spatial_audio.c" \
    -o "$OUTPUT" \
    -lwinhttp

printf '%s\n' "$OUTPUT"
