local script_path = arg[0]:match("^(.*[/\\])") or "./"
local LobbySync = dofile(script_path .. "../mod/scripts/lobby_sync.lua")

local store = {}
local writes = {}
local lobby = { Result = 123 }
local sessions = {}
function sessions:GetAllJoinedSessionsAndLobbies()
    return { { SessionName = "GameSession", LobbyId = lobby } }
end
local matchmaking = {}
function matchmaking:SetLobbyData(_, key, value)
    store[key] = value
    table.insert(writes, key)
    return true
end
function matchmaking:GetLobbyData(_, key)
    return store[key] or ""
end

local host = LobbySync.new({
    context = function() return {} end,
    sessions = sessions,
    matchmaking = matchmaking,
})
local client = LobbySync.new({
    context = function() return {} end,
    sessions = sessions,
    matchmaking = matchmaking,
})

local published = assert(host:publish_start("https://youtu.be/test", 42.5, 0.7))
assert(published.state == "play")
assert(writes[#writes] == "rvtn_radio_serial")
local received = assert(client:poll())
assert(received.url == "https://youtu.be/test")
assert(received.target_time == 42.5)
assert(received.volume == 0.7)
assert(client:poll() == nil)

assert(host:publish_volume(0.4))
local volume = assert(client:poll())
assert(volume.state == "volume" and volume.volume == 0.4)
local late_client = LobbySync.new({
    context = function() return {} end,
    sessions = sessions,
    matchmaking = matchmaking,
})
local late_play = assert(late_client:poll())
assert(late_play.state == "play" and late_play.volume == 0.4)

assert(host:publish_stop())
assert(writes[#writes] == "rvtn_radio_serial")
local stopped = assert(client:poll())
assert(stopped.state == "stop")

local presence_store = {}
local friends = {}
function friends:SetRichPresence(key, value)
    presence_store[key] = value
    return true
end
function friends:RequestFriendRichPresence() end
function friends:GetFriendRichPresence(_, key)
    return presence_store[key] or ""
end

local no_lobbies = {}
function no_lobbies:GetAllJoinedSessionsAndLobbies()
    return {}
end
local unavailable_matchmaking = {}
function unavailable_matchmaking:SetLobbyData() return false end
function unavailable_matchmaking:GetLobbyData() return "" end

local host_id = { Result = 76561198000000000 }
local presence_host = LobbySync.new({
    context = function() return {} end,
    sessions = no_lobbies,
    matchmaking = unavailable_matchmaking,
    friends = friends,
    host_id = host_id,
})
local presence_client = LobbySync.new({
    context = function() return {} end,
    sessions = no_lobbies,
    matchmaking = unavailable_matchmaking,
    friends = friends,
    host_id = host_id,
})
local long_url = "https://example.com/" .. string.rep("radio-segment/", 25)
assert(presence_host:publish_start(long_url, 91.25, 0.8))
local presence_event = assert(presence_client:poll())
assert(presence_event.url == long_url)
assert(presence_event.target_time == 91.25)
assert(presence_event.volume == 0.8)
assert(presence_host:publish_volume(0.3))
assert(presence_client:poll().volume == 0.3)
local late_presence_client = LobbySync.new({
    context = function() return {} end,
    sessions = no_lobbies,
    matchmaking = unavailable_matchmaking,
    friends = friends,
    host_id = host_id,
})
assert(late_presence_client:poll().state == "play")
assert(late_presence_client:poll().volume == 0.3)
assert(presence_host:publish_stop())
assert(presence_client:poll().state == "stop")

print("Lua lobby sync tests passed.")
