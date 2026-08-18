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
local youtube_path = os.tmpname() .. ".m4a"
local stop_path = os.tmpname() .. ".stop"
local launch_path = os.tmpname() .. ".launch"
local function recording_launcher(path)
    return function()
        local file = assert(io.open(path, "rb"))
        table.insert(launches, file:read("*all"))
        file:close()
        os.remove(path)
    end
end
local function noop_loader()
    return function() end
end
local radio = Radio.new({
    bridge_path = "C:\\Mods\\RVThereNow\\bin\\rv-radio-bridge.exe",
    status_path = status_path,
    url_path = url_path,
    youtube_path = youtube_path,
    stop_path = stop_path,
    launch_path = launch_path,
    get_player_controller = function() return controller end,
    get_server_time = function() return 100 end,
    bridge_available = function() return true end,
    read_status = function() return nil end,
    load_launcher = function() return recording_launcher(launch_path) end,
    sync = sync,
    log = function(message) table.insert(messages, message) end,
})

assert(radio:set_url("https://example.com/live.mp3?token=a&mode=1"))
assert(radio:source_name() == "example.com")
assert(radio:set_url("https://www.youtube.com/watch?v=test"))
local combined_ok, combined_error = radio:set_url("https://example.comhttps://youtu.be/test")
assert(not combined_ok)
assert(combined_error == "URL contains another address")

assert(radio:set_url("https://youtu.be/test"))
assert(radio:start())
assert(radio.state == "PREPARING")
assert(radio.backend == "youtube")
assert(radio.target_time == 112)
assert(#published == 1 and published[1].url == "https://youtu.be/test")
assert(audio.stopped)
assert(#launches == 1 and launches[1] == "youtube")
local url_file = assert(io.open(url_path, "rb"))
assert(url_file:read("*all") == "https://youtu.be/test")
url_file:close()

radio:stop("Stopped at RV radio")
assert(radio.state == "OFF")
assert(radio.detail == "Stopped at RV radio")
assert(#published == 2 and published[2].state == "stop")
assert(#launches == 1)
local stop_file = assert(io.open(stop_path, "rb"))
assert(stop_file:read("*all") == "stop")
stop_file:close()

local restart_launch_count = #launches
assert(radio:start())
assert(radio.state == "PREPARING")
assert(#published == 3 and published[3].state == "play")
assert(#launches == restart_launch_count + 1)
assert(launches[#launches] == "youtube")
assert(radio:adjust_volume(0.2) == 0.7)
assert(published[#published].state == "volume")
assert(published[#published].volume == 0.7)
radio:stop()

local failed = Radio.new({
    get_player_controller = function() return controller end,
    is_host = true,
    bridge_available = function() return false end,
    load_launcher = noop_loader,
    stop_path = os.tmpname() .. ".stop",
})
assert(not failed:start())
assert(failed.state == "FAILED")
assert(failed.detail == "Bundled radio bridge is missing")

local unsynchronized = Radio.new({
    get_player_controller = function() return controller end,
    is_host = true,
    bridge_available = function() return true end,
    load_launcher = noop_loader,
    stop_path = os.tmpname() .. ".stop",
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

local client_stop_path = os.tmpname() .. ".stop"
local client_radio = Radio.new({
    get_player_controller = function() return controller end,
    is_host = false,
    stop_path = client_stop_path,
    sync = sync,
})
client_radio.state = "PLAYING"
assert(not client_radio:stop())
assert(client_radio.state == "PLAYING")
assert(client_radio.detail == "Only the host can stop the RV radio")
assert(io.open(client_stop_path, "rb") == nil)

local solo_unsynchronized = Radio.new({
    get_player_controller = function() return controller end,
    is_host = true,
    status_path = status_path,
    url_path = url_path,
    youtube_path = youtube_path,
    stop_path = stop_path,
    bridge_available = function() return true end,
    load_launcher = noop_loader,
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
local media_prefix = os.tmpname() .. "-youtube-stream"
local media_play_path = os.tmpname() .. ".play"
local media_confirmed_path = os.tmpname() .. ".playing"
local media_spatial_path = os.tmpname() .. ".spatial"
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
    youtube_path = youtube_path,
    play_path = media_play_path,
    confirmed_path = media_confirmed_path,
    spatial_path = media_spatial_path,
    bridge_available = function() return true end,
    load_launcher = noop_loader,
    get_server_time = function() return media_now end,
    read_status = function()
        return string.format("STREAM_PCM %s\t44100\t1\t8", media_prefix)
    end,
    sync = media_sync,
})
assert(file_radio:set_url("https://youtu.be/media-test"))
assert(file_radio:start())
media_now = 212
file_radio:update()
file_radio:update()
assert(file_radio.state == "OPENING")
assert(file_radio.native_play_started)
local media_play = assert(io.open(media_play_path, "rb"))
assert(media_play:read("*all") == "0")
media_play:close()
local media_spatial = assert(io.open(media_spatial_path, "rb"))
assert(media_spatial:read("*all") == "0.5000 0.5000")
media_spatial:close()
local media_confirmed = assert(io.open(media_confirmed_path, "wb"))
media_confirmed:close()
file_radio:update()
assert(file_radio.state == "PLAYING")
file_radio:stop()
assert(not io.open(media_play_path, "rb"))
assert(not io.open(media_confirmed_path, "rb"))

local stream_prefix = os.tmpname() .. "-stream"
local stream_play_path = os.tmpname() .. ".play"
local stream_confirmed_path = os.tmpname() .. ".playing"
local stream_spatial_path = os.tmpname() .. ".spatial"
local function write_chunk(sequence)
    local path = string.format("%s.%06d.pcm", stream_prefix, sequence)
    local file = assert(io.open(path, "wb"))
    file:write("pcm")
    file:close()
end
write_chunk(0)
write_chunk(1)
local stream_now = 300
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
    youtube_path = youtube_path,
    play_path = stream_play_path,
    confirmed_path = stream_confirmed_path,
    spatial_path = stream_spatial_path,
    bridge_available = function() return true end,
    launch_path = launch_path,
    load_launcher = function() return recording_launcher(launch_path) end,
    get_server_time = function() return stream_now end,
    read_status = function()
        return string.format("STREAM_PCM %s\t48000\t1\t8", stream_prefix)
    end,
    sync = stream_sync,
})
assert(stream_radio:set_url("https://example.com/live.mp3"))
assert(stream_radio:start())
assert(launches[#launches] == "stream")
stream_now = 305
stream_radio:update()
assert(stream_radio.state == "PREPARING")
assert(stream_radio.detail == "Live stream buffered; starting in 7s")
stream_now = 312
stream_radio:update()
assert(stream_radio.state == "OPENING")
assert(stream_radio.stream_sequence == 0)
local first_play_count = audio.play_count
local stream_play = assert(io.open(stream_play_path, "rb"))
assert(stream_play:read("*all") == "0")
stream_play:close()
local stream_spatial = assert(io.open(stream_spatial_path, "rb"))
assert(stream_spatial:read("*all") == "0.5000 0.5000")
stream_spatial:close()
local stream_confirmed = assert(io.open(stream_confirmed_path, "wb"))
stream_confirmed:close()
stream_now = 313
stream_radio:maintain_audio()
assert(audio.play_count == first_play_count)
stream_radio:update()
assert(stream_radio.state == "PLAYING")
stream_now = 319.97
stream_radio:maintain_audio()
assert(stream_radio.stream_sequence == 0)
assert(stream_radio.native_play_started)
stream_radio:stop()
assert(not io.open(stream_play_path, "rb"))
assert(not io.open(stream_confirmed_path, "rb"))

os.remove(url_path)
os.remove(status_path)
os.remove(youtube_path)
os.remove(stop_path)
os.remove(launch_path)
os.remove(media_spatial_path)
os.remove(stream_spatial_path)
os.remove(string.format("%s.%06d.pcm", stream_prefix, 0))
os.remove(string.format("%s.%06d.pcm", stream_prefix, 1))
print("Lua radio tests passed.")
