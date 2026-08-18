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
grep -Fq 'return State.in_game and { 4, 5 } or { 1, 3 }' "$ROOT/mod/scripts/main.lua" \
    || fail 'dashboard controls are not separated between frontend and gameplay'
grep -Fq '/game/ride/maps/frontend' "$ROOT/mod/scripts/main.lua" \
    || fail 'dashboard does not identify the frontend world'
grep -Fq '/game/ride/maps/ridemap' "$ROOT/mod/scripts/main.lua" \
    || fail 'dashboard does not identify the gameplay world'
grep -Fq 'RADIO STATION' "$ROOT/mod/scripts/main.lua" \
    || fail 'dashboard station selector is missing'
if grep -Eq 'STREAM URL|row_values\[6\]|add_row\(ui, 6|EditableTextBox' "$ROOT/mod/scripts/main.lua"; then
  fail 'legacy editable URL or six-row UI remains'
fi
if grep -Fq 'set_text(ui.row_values[4], "RESET")' "$ROOT/mod/scripts/main.lua"; then
  fail 'Reset row remains in dashboard'
fi
grep -Fq 'local SYNC_LEAD_SECONDS = 4' "$ROOT/mod/scripts/radio.lua" \
    || fail 'radio must use the four-second synchronized startup lead'
grep -Fq '#define STREAM_BUFFER_SECONDS 8' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'radio bridge must retain an eight-second in-memory recovery buffer'
grep -Fq '#define STREAM_READY_SECONDS 2' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'radio bridge must prebuffer two seconds before synchronized playback'
grep -Fq '#define STREAM_CHANNELS 1' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native stream must use the cassette mono source contract'
grep -Fq 'ma_pcm_rb_init' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native in-memory stream buffer is missing from the bundled bridge'
grep -Fq 'spatial_audio_mono_to_stereo_s16' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native output must apply RV-relative stereo gains'
grep -Fq 'call_bridge("rvtn_play")' "$ROOT/mod/scripts/radio.lua" \
    || fail 'Lua must release synchronized playback through the native bridge'
grep -Fq '__declspec(dllexport) int __cdecl rvtn_play' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native playback signal export is missing'
if grep -Eq 'write_pcm_chunk|pcm_chunk_exists|\.pcm"|_wfopen\(g_play_path' \
    "$ROOT/bridge/rv_radio_bridge.c"; then
  fail 'legacy disk-backed PCM handoff remains'
fi
if grep -Fq 'SIK_QueueAudio' "$ROOT/mod/scripts/radio.lua"; then
  fail 'dead Unreal procedural playback path remains'
fi
grep -Fq 'same_unreal_object(' "$ROOT/mod/scripts/radio.lua" \
    || fail 'UE4SS UObject wrappers must be compared by Unreal address'
grep -Fq 'class_path .. "Interact"' "$ROOT/mod/scripts/main.lua" \
    || fail 'physical tape changer interaction hook is missing'
grep -Fq 'controls.NextTapeButton' "$ROOT/mod/scripts/main.lua" \
    || fail 'physical next button is not mapped to radio stations'
grep -Fq 'controls.PreviousTapeButton' "$ROOT/mod/scripts/main.lua" \
    || fail 'physical previous button is not mapped to radio stations'
if grep -Fq 'tape_player[name] = nil' "$ROOT/mod/scripts/main.lua"; then
  fail 'physical radio button component references must remain intact'
fi
grep -Fq 'tape_player.CurrentTapeIndex = 0' "$ROOT/mod/scripts/main.lua" \
    || fail 'vanilla cassette index is not reset after radio input'
grep -Fq 'same_unreal_object(character, local_character)' "$ROOT/mod/scripts/main.lua" \
    || fail 'physical radio controls are not restricted to the listen host'
if grep -Eq 'os\.execute|start ""' "$ROOT/mod/scripts/radio.lua"; then
  fail 'radio helper still launches through a focus-stealing command shell'
fi
grep -Fq 'package.loadlib(path, symbol)' "$ROOT/mod/scripts/radio.lua" \
    || fail 'radio does not load the native bridge DLL'
grep -Fq 'FreeLibraryAndExitThread' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'radio bridge worker does not retain its DLL lifetime'
grep -Fq 'Previous radio worker did not stop' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'radio bridge does not serialize worker restarts'
grep -Fq '__declspec(dllexport) int __cdecl rvtn_stop' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'native stop signal export is missing'
grep -Fq 'Left the RV session' "$ROOT/mod/scripts/radio.lua" \
    || fail 'radio does not stop when its RV world is unloaded'
grep -Fq 'Icy-MetaData: 1' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'live stream metadata is not requested'
grep -Fq 'StreamTitle=' "$ROOT/bridge/rv_radio_bridge.c" \
    || fail 'live stream title metadata is not parsed'
grep -Fq 'add_bottom_right_child' "$ROOT/mod/scripts/main.lua" \
    || fail 'static lower-right now-playing display is missing'
if grep -Fq 'ProjectWorldLocationToScreen' "$ROOT/mod/scripts/main.lua"; then
  fail 'now-playing display still follows the physical radio'
fi

[[ -f "$ROOT/mod/bin/rv-radio-bridge.dll" ]] || fail 'bundled radio bridge DLL is missing'
[[ ! -f "$ROOT/mod/bin/rv-radio-bridge.exe" ]] || fail 'obsolete radio bridge executable remains'
[[ ! -f "$ROOT/mod/bin/rv-radio-launcher.dll" ]] || fail 'obsolete launcher DLL remains'
[[ "$(od -An -tx1 -N2 "$ROOT/mod/bin/rv-radio-bridge.dll" | tr -d ' ')" == '4d5a' ]] \
    || fail 'bundled radio bridge is not a Windows DLL'
[[ -f "$ROOT/mod/licenses/LICENSE.miniaudio" ]] || fail 'miniaudio license is missing'
if find "$ROOT/mod/bin" -maxdepth 1 -type f ! -name 'rv-radio-bridge.dll' -print -quit | grep -q .; then
  fail 'unsupported executable or resolver remains in the radio package'
fi
if rg -i 'accuradio|youtube|yt-dlp|quickjs|qjs' "$ROOT/mod" "$ROOT/bridge"; then
  fail 'unsupported radio provider or resolver code remains'
fi
[[ "$(grep -Ec 'ice[0-9]+\.somafm\.com/' "$ROOT/mod/scripts/main.lua")" == '17' ]] \
    || fail 'station catalog must contain exactly seventeen SomaFM direct streams'
[[ "$(grep -Fc 'u80s-128-mp3' "$ROOT/mod/scripts/main.lua")" == '1' ]] \
    || fail 'Underground 80s must appear exactly once'
if rg -i 'KONA|WNYC|RNZ NATIONAL|BBC WORLD' "$ROOT/mod/scripts/main.lua"; then
  fail 'news or talk station remains in the bundled catalog'
fi
[[ "$(grep -Fc 'LoopInGameThreadWithDelay(' "$ROOT/mod/scripts/main.lua")" == '1' ]] \
    || fail 'game-thread maintenance must use one consolidated scheduler'
grep -Fq 'scheduler_tick % 5 == 0' "$ROOT/mod/scripts/main.lua" \
    || fail 'Steam radio synchronization must poll at 500 ms intervals'
grep -Fq 'InternetRadio.state == "PREPARING" or InternetRadio.state == "OPENING"' \
    "$ROOT/mod/scripts/main.lua" \
    || fail 'fast radio updates must stop after startup'
grep -Fq 'self.next_presence_poll_at = now + 1' "$ROOT/mod/scripts/lobby_sync.lua" \
    || fail 'rich-presence fallback polling must be rate limited'
if grep -Fq 'LoopInGameThreadWithDelay(25, function()' "$ROOT/mod/scripts/main.lua"; then
  fail 'legacy 40 Hz spatial maintenance loop remains'
fi
grep -Fq 'host:match("^ice%d+%.somafm%.com$")' "$ROOT/mod/scripts/radio.lua" \
    || fail 'radio playback must reject non-SomaFM lobby sources'
[[ -f "$ROOT/LICENSE" ]] || fail 'project GPL license is missing'
[[ -f "$ROOT/standalone/UE4SS-settings.ini" ]] || fail 'standalone UE4SS settings are missing'
grep -Fq 'MajorVersion = 5' "$ROOT/standalone/UE4SS-settings.ini" \
    || fail 'standalone UE4SS major version override is missing'
grep -Fq 'MinorVersion = 6' "$ROOT/standalone/UE4SS-settings.ini" \
    || fail 'standalone UE4SS minor version override is missing'
grep -Fq 'HookLoadMap = 0' "$ROOT/standalone/UE4SS-settings.ini" \
    || fail 'standalone UE4SS must disable the failing LoadMap hook'
grep -Fq '8deaf2a7246370f4e30f65af37645cdef481a28cb353d7285c3a62576bcba853' \
    "$ROOT/scripts/package-standalone.sh" \
    || fail 'standalone UE4SS dependency is not checksum-pinned'

printf 'All tests passed.\n'
