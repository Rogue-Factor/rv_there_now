local script_path = arg[0]:match("^(.*[/\\])") or "./"
local ConfigStore = dofile(script_path .. "../mod/scripts/config_store.lua")
local path = os.tmpname() .. ".ini"

local function write(content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    file:close()
end

local function read()
    local file = assert(io.open(path, "rb"))
    local content = file:read("*all")
    file:close()
    return content
end

local function contains(content, expected)
    assert(content:find(expected, 1, true), "missing expected content: " .. expected)
end

write(table.concat({
    "[/Script/Engine.RendererSettings]",
    "r.SomeSetting=1",
    "",
    "[/script/engine.gamesession]",
    "OtherSetting=yes",
    "maxplayers = 5",
    "MaxPlayers=6",
    "",
    "[/Script/Engine.Other]",
    "Value=kept",
    "",
}, "\r\n"))

assert(ConfigStore.read_max_players(path) == 6)
assert(ConfigStore.set_max_players(path, 12))
local changed = read()
contains(changed, "r.SomeSetting=1")
contains(changed, "OtherSetting=yes")
contains(changed, "MaxPlayers=12")
contains(changed, "Value=kept")
assert(select(2, changed:gsub("MaxPlayers=12", "")) == 1, "target key was duplicated")
assert(io.open(path .. ".rv-there-now.bak", "rb"), "backup was not created")

assert(ConfigStore.reset(path))
local reset = read()
contains(reset, "OtherSetting=yes")
assert(not reset:lower():find("maxplayers%s*="), "reset left a player cap")
assert(ConfigStore.read_max_players(path) == 4)

assert(ConfigStore.restore(path))
local restored = read()
contains(restored, "maxplayers = 5")
contains(restored, "MaxPlayers=6")

local accepted = ConfigStore.set_max_players(path, 25)
assert(not accepted, "accepted an unsafe player count")

local radio_path = path .. ".radio"
assert(ConfigStore.read_radio_url(radio_path) == nil)
assert(ConfigStore.set_radio_url(radio_path, "https://example.com/live.mp3?token=a&mode=1"))
assert(ConfigStore.read_radio_url(radio_path) == "https://example.com/live.mp3?token=a&mode=1")
assert(not ConfigStore.set_radio_url(radio_path, "file:///tmp/audio.mp3"))
assert(not ConfigStore.set_radio_url(radio_path, "https://example.comhttps://other.example/live.mp3"))
write("https://example.comhttps://youtu.be/video\n")
assert(ConfigStore.read_radio_url(path) == nil)

os.remove(path)
os.remove(path .. ".rv-there-now.bak")
os.remove(path .. ".rv-there-now.tmp")
os.remove(radio_path)
os.remove(radio_path .. ".rv-there-now.tmp")
print("Lua config tests passed.")
