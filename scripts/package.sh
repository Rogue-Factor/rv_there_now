#!/usr/bin/env bash

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VERSION="$(jq -r '.version_number' "$ROOT/manifest.json")"
readonly OUTPUT_DIR="$ROOT/dist"
readonly OUTPUT="$OUTPUT_DIR/Rogue-Factor-RVThereNow-$VERSION.zip"

[[ -f "$ROOT/icon.png" ]] || {
  printf 'Missing required Thunderstore icon: %s/icon.png\n' "$ROOT" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
(
  cd "$ROOT"
  zip -qrFS "$OUTPUT" manifest.json README.md CHANGELOG.md icon.png mod
)

printf '%s\n' "$OUTPUT"
