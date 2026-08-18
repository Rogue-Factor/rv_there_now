#!/usr/bin/env bash

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VERSION="$(jq -r '.version_number' "$ROOT/manifest.json")"
readonly OUTPUT_DIR="$ROOT/dist"
readonly OUTPUT="$OUTPUT_DIR/Rogue-Factor-RVThereNow-$VERSION-Standalone.zip"
readonly UE4SS_URL='https://thunderstore.io/package/download/Thunderstore/unreal_shimloader/1.1.7/'
readonly UE4SS_SHA256='8deaf2a7246370f4e30f65af37645cdef481a28cb353d7285c3a62576bcba853'

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

archive="$temp_dir/unreal-shimloader.zip"
extracted="$temp_dir/extracted"
payload="$temp_dir/payload"
win64="$payload/Ride/Binaries/Win64"

curl -fsSL --retry 3 --retry-delay 2 "$UE4SS_URL" -o "$archive"
printf '%s  %s\n' "$UE4SS_SHA256" "$archive" | sha256sum -c - >/dev/null
mkdir -p "$extracted" "$win64/Mods/RVThereNow" "$OUTPUT_DIR"
unzip -q "$archive" 'UE4SS/*' -d "$extracted"

cp "$extracted/UE4SS/dwmapi.dll" "$win64/dwmapi.dll"
cp "$extracted/UE4SS/UE4SS.dll" "$win64/UE4SS.dll"
cp -a "$extracted/UE4SS/Mods/." "$win64/Mods/"
cp "$ROOT/standalone/UE4SS-settings.ini" "$win64/UE4SS-settings.ini"
cp -a "$ROOT/mod/." "$win64/Mods/RVThereNow/"

cp "$ROOT/standalone/INSTALL.txt" "$payload/INSTALL.txt"
cp "$ROOT/standalone/THIRD_PARTY.md" "$payload/THIRD_PARTY.md"
cp "$ROOT/LICENSE" "$payload/RVThereNow-LICENSE"
cp "$extracted/UE4SS/LICENSE" "$payload/UE4SS-LICENSE"

(
  cd "$payload"
  zip -qrFS "$OUTPUT" .
)

printf '%s\n' "$OUTPUT"
