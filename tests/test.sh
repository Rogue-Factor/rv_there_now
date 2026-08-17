#!/usr/bin/env bash

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TOOL="$ROOT/rv-there-now"
export PATH="$ROOT/tests/bin:$PATH"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local expected="$1"
  local file="$2"
  grep -Fqx "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
  local unexpected="$1"
  local file="$2"
  if grep -Fqi "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
config="$temp_dir/Game.ini"

RV_THERE_YET_CONFIG="$config" "$TOOL" set >/dev/null
assert_contains '[/Script/Engine.GameSession]' "$config"
assert_contains 'MaxPlayers=8' "$config"
[[ "$(RV_THERE_YET_CONFIG="$config" "$TOOL" status | head -n 1)" == 'Player cap: 8' ]] || fail 'status did not report 8'

cat > "$config" <<'EOF'
[/Script/Engine.RendererSettings]
r.SomeSetting=1

[ /not/the/target ]
MaxPlayers=99

[/script/engine.gamesession]
OtherSetting=yes
maxplayers = 5
MaxPlayers=6

[/Script/Engine.Other]
Value=kept
EOF

RV_THERE_YET_CONFIG="$config" "$TOOL" set 12 >/dev/null 2>&1
assert_contains 'r.SomeSetting=1' "$config"
assert_contains 'OtherSetting=yes' "$config"
assert_contains 'MaxPlayers=12' "$config"
assert_contains 'Value=kept' "$config"
[[ "$(grep -Eic '^[[:space:]]*MaxPlayers[[:space:]]*=' "$config")" == '2' ]] || fail 'target duplicate was not removed or unrelated key was changed'
[[ -f "$config.rv-there-now.bak" ]] || fail 'backup was not created'

RV_THERE_YET_CONFIG="$config" "$TOOL" reset >/dev/null
assert_contains 'OtherSetting=yes' "$config"
assert_contains 'MaxPlayers=99' "$config"
assert_not_contains 'MaxPlayers=12' "$config"
[[ "$(RV_THERE_YET_CONFIG="$config" "$TOOL" status | head -n 1)" == 'Player cap: game default (4)' ]] || fail 'status did not report the default'

RV_THERE_YET_CONFIG="$config" "$TOOL" restore >/dev/null
assert_contains 'maxplayers = 5' "$config"
assert_contains 'MaxPlayers=6' "$config"

if RV_THERE_YET_CONFIG="$config" "$TOOL" set 25 >/dev/null 2>&1; then
  fail 'accepted an unsafe player count'
fi

lua "$ROOT/tests/test_lua_config.lua"
lua "$ROOT/tests/test_lua_radio.lua"
lua "$ROOT/tests/test_lua_lobby_sync.lua"

grep -Fq 'root:SetVisibility(3)' "$ROOT/mod/scripts/main.lua" || fail 'overlay root must be hit-test invisible'
if grep -Fq 'root:SetVisibility(0)' "$ROOT/mod/scripts/main.lua"; then
  fail 'overlay root must not block the game UI'
fi

luac -p "$ROOT/mod/scripts/main.lua"
luac -p "$ROOT/mod/scripts/radio.lua"
luac -p "$ROOT/mod/scripts/lobby_sync.lua"

grep -Fq 'local MENU_ROWS = 5' "$ROOT/mod/scripts/main.lua" \
    || fail 'dashboard must use the five-row station layout'
grep -Fq 'RADIO STATION' "$ROOT/mod/scripts/main.lua" \
    || fail 'dashboard station selector is missing'
if grep -Eq 'STREAM URL|row_values\[6\]|add_row\(ui, 6|EditableTextBox' "$ROOT/mod/scripts/main.lua"; then
  fail 'legacy editable URL or six-row UI remains'
fi
if grep -Fq 'set_text(ui.row_values[4], "RESET")' "$ROOT/mod/scripts/main.lua"; then
  fail 'Reset row remains in dashboard'
fi
grep -Fq 'local SYNC_LEAD_SECONDS = 12' "$ROOT/mod/scripts/radio.lua" \
    || fail 'radio must use the shortened synchronized startup lead'
grep -Fq '#define STREAM_READY_CHUNKS 1' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'radio bridge must become ready after its first stream chunk'
grep -Fq '#define STREAM_RETAIN_CHUNKS 3' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'radio bridge must retain its recovery window'
grep -Fq '#define STREAM_CHANNELS 1' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native stream must use the cassette mono source contract'
grep -Fq 'native_chunk_player_init' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native chunk output is missing from the bundled bridge'
grep -Fq 'spatial_audio_mono_to_stereo_s16' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native output must apply RV-relative stereo gains'
grep -Fq 'write_atomic(self.play_path' "$ROOT/mod/scripts/radio.lua" \
    || fail 'Lua must release the synchronized native playback gate'
grep -Fq 'fscanf(file, "%u", &value)' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native playback gate must parse Lua ASCII control data'
if grep -Fq 'fwscanf(file' "$ROOT/bridge/rv_radio_bridge.c"; then
  fail 'wide scanning cannot parse the Lua ASCII playback gate reliably under Wine'
fi
grep -Fq 'rv-there-now-radio.playing' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native output confirmation marker is missing'
if grep -Fq 'SIK_QueueAudio' "$ROOT/mod/scripts/radio.lua"; then
  fail 'dead Unreal procedural playback path remains'
fi
grep -Fq 'same_unreal_object(' "$ROOT/mod/scripts/radio.lua" \
    || fail 'UE4SS UObject wrappers must be compared by Unreal address'
grep -Fq '"Interact",' "$ROOT/mod/scripts/main.lua" \
    || fail 'physical tape changer interaction hook is missing'
grep -Fq 'tape_player.NextTapeButton' "$ROOT/mod/scripts/main.lua" \
    || fail 'physical next button is not mapped to radio stations'
grep -Fq 'tape_player.PreviousTapeButton' "$ROOT/mod/scripts/main.lua" \
    || fail 'physical previous button is not mapped to radio stations'

[[ -f "$ROOT/mod/bin/rv-radio-bridge.exe" ]] || fail 'bundled radio bridge is missing'
[[ -f "$ROOT/mod/bin/accuradio-resolver.js" ]] || fail 'bundled AccuRadio resolver is missing'
grep -Fq 'JSON.parse' "$ROOT/mod/bin/accuradio-resolver.js" \
    || fail 'AccuRadio resolver must use structured JSON parsing'
[[ "$(od -An -tx1 -N2 "$ROOT/mod/bin/rv-radio-bridge.exe" | tr -d ' ')" == '4d5a' ]] \
    || fail 'bundled radio bridge is not a Windows executable'
[[ "$(od -An -tx1 -N2 "$ROOT/mod/bin/yt-dlp.exe" | tr -d ' ')" == '4d5a' ]] \
    || fail 'bundled YouTube resolver is not a Windows executable'
[[ "$(od -An -tx1 -N2 "$ROOT/mod/bin/qjs.exe" | tr -d ' ')" == '4d5a' ]] \
    || fail 'bundled QuickJS runtime is not a Windows executable'
(cd "$ROOT" && sha256sum -c bridge/dependencies.sha256 >/dev/null) \
    || fail 'bundled YouTube dependency checksum failed'
[[ -f "$ROOT/mod/licenses/LICENSE.miniaudio" ]] || fail 'miniaudio license is missing'
[[ -f "$ROOT/mod/licenses/LICENSE.yt-dlp" ]] || fail 'yt-dlp license is missing'
[[ -f "$ROOT/mod/licenses/THIRD_PARTY_LICENSES.yt-dlp.txt" ]] \
    || fail 'yt-dlp third-party licenses are missing'
[[ -f "$ROOT/mod/licenses/LICENSE.quickjs-ng" ]] || fail 'QuickJS license is missing'
[[ -f "$ROOT/LICENSE" ]] || fail 'project GPL license is missing'

printf 'All tests passed.\n'
