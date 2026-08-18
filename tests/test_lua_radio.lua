local script_path = arg[0]:match("^(.*[/\\])") or "./"
local Radio = dofile(script_path .. "../mod/scripts/radio.lua")

local object_address = 0
local function object(fields)
    fields = fields or {}
    object_address = (object_address or 0) + 1
    fields._address = fields._address or object_address
    fields.valid = true
    function fields:IsValid() return self.valid end
    function fields:GetAddress() return self._address end
    return fields
end

local world = object()
local original_sound = object()
local audio = object({ stopped = false, playing = false, Sound = original_sound })
function audio:Stop() self.stopped = true self.playing = false end
function audio:SetSound(sound) self.Sound = sound end
function audio:SetVolumeMultiplier(volume) self.volume = volume end
function audio:SetPitchMultiplier(pitch) assert(pitch == 1.0) self.pitch = pitch end
function audio:SetPaused(paused) assert(paused == false) self.paused = paused end
function audio:Activate(reset) assert(reset == true) self.active = true end
function audio:Play(start_time)
    assert(start_time == 0.0)
    self.play_count = (self.play_count or 0) + 1
    self.playing = true
end
function audio:IsPlaying() return self.playing end

local tape_player = object({ Audio = audio, VolumeMultiplier = 0.5 })
function tape_player:GetWorld() return object({ _address = world:GetAddress() }) end
function tape_player:HasAuthority() return true end

local controller = object({ signals = {} })
function controller:GetWorld() return object({ _address = world:GetAddress() }) end
function controller:Server_TapeSetPlaying(target, playing)
    assert(target == tape_player)
    table.insert(self.signals, playing)
end

function FindAllOf(class_name)
    assert(class_name == "BP_TapePlayer_C")
    return { tape_player }
end

local published = {}
local sync = {}
function sync:publish_start(url, target_time)
    local event = {
        state = "play",
        url = url,
        target_time = target_time,
        serial = "host-1",
    }
    table.insert(published, event)
    return event
end
function sync:publish_stop()
    local event = { state = "stop", serial = "host-2" }
    table.insert(published, event)
    return event
end
function sync:publish_volume(volume)
    local event = { state = "volume", serial = "host-volume", volume = volume }
    table.insert(published, event)
    return event
end
function sync:poll() return nil end

local launches = {}
local messages = {}
local url_path = os.tmpname() .. ".url"
local status_path = os.tmpname() .. ".status"
local function recording_bridge(_, symbol)
    return function()
        table.insert(launches, symbol)
    end
end
local function noop_bridge_loader()
    return function() end
end
local radio = Radio.new({
    bridge_path = "C:\\Mods\\RVThereNow\\bin\\rv-radio-bridge.dll",
    status_path = status_path,
    url_path = url_path,
    get_player_controller = function() return controller end,
    get_server_time = function() return 100 end,
    bridge_available = function() return true end,
    read_status = function() return nil end,
    load_bridge = recording_bridge,
    sync = sync,
    log = function(message) table.insert(messages, message) end,
})

assert(radio:set_url("https://ice5.somafm.com/groovesalad-128-mp3"))
assert(radio:source_name() == "ice5.somafm.com")
local unsupported_ok, unsupported_error = radio:set_url("https://example.com/live.mp3")
assert(not unsupported_ok)
assert(unsupported_error == "Source is not a supported SomaFM stream")
local combined_ok, combined_error = radio:set_url(
    "https://ice5.somafm.comhttps://other.example/live.mp3"
)
assert(not combined_ok)
assert(combined_error == "URL contains another address")

assert(radio:start())
assert(radio.state == "PREPARING")
assert(radio.backend == "stream")
assert(radio.target_time == 104)
assert(#published == 1 and published[1].url == "https://ice5.somafm.com/groovesalad-128-mp3")
assert(audio.stopped)
assert(#launches == 1 and launches[1] == "rvtn_launch")
local url_file = assert(io.open(url_path, "rb"))
assert(url_file:read("*all") == "https://ice5.somafm.com/groovesalad-128-mp3")
url_file:close()

radio:stop("Stopped at RV radio")
assert(radio.state == "OFF")
assert(radio.detail == "Stopped at RV radio")
assert(#published == 2 and published[2].state == "stop")
assert(#launches == 2 and launches[2] == "rvtn_stop")

local restart_launch_count = #launches
assert(radio:start())
assert(radio.state == "PREPARING")
assert(#published == 3 and published[3].state == "play")
assert(#launches == restart_launch_count + 1)
assert(launches[#launches] == "rvtn_launch")
assert(radio:adjust_volume(0.2) == 0.7)
assert(published[#published].state == "volume")
assert(published[#published].volume == 0.7)
radio:stop()

local failed = Radio.new({
    get_player_controller = function() return controller end,
    is_host = true,
    bridge_available = function() return false end,
    load_bridge = noop_bridge_loader,
})
assert(not failed:start())
assert(failed.state == "FAILED")
assert(failed.detail == "Bundled radio bridge is missing")

local unsynchronized = Radio.new({
    get_player_controller = function() return controller end,
    is_host = true,
    bridge_available = function() return true end,
    load_bridge = noop_bridge_loader,
    get_player_count = function() return 2 end,
    sync = {
        publish_start = function()
            return nil, "Steam lobby metadata unavailable"
        end,
    },
})
assert(not unsynchronized:start())
assert(unsynchronized.state == "UNAVAILABLE")
assert(unsynchronized.detail == "Steam lobby metadata unavailable")

local client_radio = Radio.new({
    get_player_controller = function() return controller end,
    is_host = false,
    sync = sync,
})
client_radio.state = "PLAYING"
assert(not client_radio:stop())
assert(client_radio.state == "PLAYING")
assert(client_radio.detail == "Only the host can stop the RV radio")

local solo_unsynchronized = Radio.new({
    get_player_controller = function() return controller end,
    is_host = true,
    status_path = status_path,
    url_path = url_path,
    bridge_available = function() return true end,
    load_bridge = noop_bridge_loader,
    get_server_time = function() return 100 end,
    get_player_count = function() return 1 end,
    sync = {
        publish_start = function()
            return nil, "Steam session sync unavailable"
        end,
    },
})
assert(solo_unsynchronized:start())
assert(solo_unsynchronized.state == "PREPARING")
assert(solo_unsynchronized.sync_pending)
assert(solo_unsynchronized.detail == "Local RV audio; waiting for Steam session")

local media_now = 200
local media_spatial_path = os.tmpname() .. ".spatial"
local media_status = "STREAM_READY 44100\t1"
local media_sync = {}
function media_sync:publish_start(url, target_time)
    return { state = "play", url = url, target_time = target_time, serial = "media-1" }
end
function media_sync:publish_stop() return { state = "stop", serial = "media-2" } end
function media_sync:poll() return nil end
local file_radio = Radio.new({
    get_player_controller = function() return controller end,
    is_host = true,
    status_path = status_path,
    url_path = url_path,
    spatial_path = media_spatial_path,
    bridge_available = function() return true end,
    load_bridge = noop_bridge_loader,
    get_server_time = function() return media_now end,
    read_status = function()
        return media_status
    end,
    sync = media_sync,
})
assert(file_radio:set_url("https://ice6.somafm.com/deepspaceone-128-mp3"))
assert(file_radio:start())
media_now = 204
file_radio:update()
file_radio:update()
assert(file_radio.state == "OPENING")
assert(file_radio.native_play_started)
local media_spatial = assert(io.open(media_spatial_path, "rb"))
assert(media_spatial:read("*all") == "0.5000 0.5000")
media_spatial:close()
media_status = "PLAYING"
file_radio:update()
assert(file_radio.state == "PLAYING")
file_radio:stop()

local stream_spatial_path = os.tmpname() .. ".spatial"
local stream_now_playing_path = os.tmpname() .. ".nowplaying"
local stream_now = 300
local stream_status = "STREAM_READY 48000\t1"
local stream_sync = {}
function stream_sync:publish_start(url, target_time)
    return { state = "play", url = url, target_time = target_time, serial = "stream-1" }
end
function stream_sync:publish_stop() return { state = "stop", serial = "stream-2" } end
function stream_sync:poll() return nil end
local stream_radio = Radio.new({
    get_player_controller = function() return controller end,
    is_host = true,
    status_path = status_path,
    url_path = url_path,
    spatial_path = stream_spatial_path,
    now_playing_path = stream_now_playing_path,
    bridge_available = function() return true end,
    load_bridge = recording_bridge,
    get_server_time = function() return stream_now end,
    read_status = function()
        return stream_status
    end,
    sync = stream_sync,
})
assert(stream_radio:set_url("https://ice6.somafm.com/thistle-128-mp3"))
assert(stream_radio:start())
assert(launches[#launches] == "rvtn_launch")
stream_now = 303
stream_radio:update()
assert(stream_radio.state == "PREPARING")
assert(stream_radio.detail == "Live stream buffered; starting in 1s")
stream_now = 304
stream_radio:update()
assert(stream_radio.state == "OPENING")
local first_play_count = audio.play_count
assert(launches[#launches] == "rvtn_play")
local stream_spatial = assert(io.open(stream_spatial_path, "rb"))
assert(stream_spatial:read("*all") == "0.5000 0.5000")
stream_spatial:close()
stream_status = "PLAYING"
stream_now = 313
stream_radio:maintain_audio()
assert(audio.play_count == first_play_count)
stream_radio:update()
assert(stream_radio.state == "PLAYING")
local now_playing_file = assert(io.open(stream_now_playing_path, "wb"))
now_playing_file:write("Test Artist - Test Track")
now_playing_file:close()
stream_radio:update()
assert(stream_radio:now_playing_text("fallback") == "Test Artist - Test Track")
stream_now = 319.97
stream_radio:maintain_audio()
assert(stream_radio.native_play_started)
tape_player.valid = false
stream_radio:update()
assert(stream_radio.state == "OFF", stream_radio.state .. ": " .. stream_radio.detail)
assert(stream_radio.detail == "Left the RV session")
assert(not io.open(stream_now_playing_path, "rb"))

os.remove(url_path)
os.remove(status_path)
os.remove(media_spatial_path)
os.remove(stream_spatial_path)
print("Lua radio tests passed.")
