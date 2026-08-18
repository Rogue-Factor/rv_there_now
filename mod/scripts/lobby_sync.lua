local LobbySync = {}

local EVENT_KEY = "rvtn_radio_event"
local VOLUME_EVENT_KEY = "rvtn_radio_volume_event"
local PRESENCE_CONTROL_KEY = "rvtn_radio_ctl"
local PRESENCE_VOLUME_KEY = "rvtn_radio_volctl"
local PRESENCE_CHUNK_PREFIX = "rvtn_radio_"
local PRESENCE_CHUNK_BYTES = 220
local PRESENCE_MAX_CHUNKS = 15

local function valid(object)
    if not object then
        return false
    end
    local ok, result = pcall(function()
        return object:IsValid()
    end)
    return ok and result
end

local function as_string(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        return value
    end
    local ok, result = pcall(function()
        return value:ToString()
    end)
    return ok and tostring(result) or tostring(value)
end

local function steam_id_value(steam_id)
    local ok, result = pcall(function()
        return tonumber(steam_id.Result)
    end)
    return ok and result or nil
end

local function split_utf8(value, maximum_bytes)
    local chunks = {}
    local current = ""
    local ok = pcall(function()
        for _, codepoint in utf8.codes(value) do
            local character = utf8.char(codepoint)
            if #current > 0 and #current + #character > maximum_bytes then
                table.insert(chunks, current)
                current = ""
            end
            current = current .. character
        end
    end)
    if not ok then
        chunks = {}
        current = ""
        for offset = 1, #value, maximum_bytes do
            table.insert(chunks, value:sub(offset, offset + maximum_bytes - 1))
        end
        return chunks
    end
    if current ~= "" then
        table.insert(chunks, current)
    end
    return chunks
end

function LobbySync.new(options)
    options = options or {}
    local self = {
        context = options.context,
        sessions = options.sessions,
        matchmaking = options.matchmaking,
        friends = options.friends,
        shared = options.shared,
        host_id = options.host_id,
        lobby_id = options.lobby_id,
        serial_counter = 0,
        last_serial = nil,
        last_volume_serial = nil,
        last_presence_request_at = 0,
        next_presence_poll_at = 0,
        log = options.log or function() end,
    }

    local function ensure_lobby_libraries()
        if self.sessions and self.matchmaking then
            return true
        end
        local ok = pcall(function()
            self.sessions = StaticFindObject(
                "/Script/SteamIntegrationKit.Default__SIK_SessionsSubsystem"
            )
            self.matchmaking = StaticFindObject(
                "/Script/SteamIntegrationKit.Default__SIK_MatchmakingLibrary"
            )
        end)
        return ok and valid(self.sessions) and valid(self.matchmaking)
    end

    local function ensure_friends_library()
        if self.friends then
            return true
        end
        local ok = pcall(function()
            self.friends = StaticFindObject(
                "/Script/SteamIntegrationKit.Default__SIK_FriendsLibrary"
            )
        end)
        return ok and valid(self.friends)
    end

    local function ensure_shared_library()
        if self.shared then
            return true
        end
        local ok = pcall(function()
            self.shared = StaticFindObject(
                "/Script/SteamIntegrationKit.Default__SIK_SharedFile"
            )
        end)
        return ok and valid(self.shared)
    end

    local function find_lobby()
        if self.lobby_id then
            return self.lobby_id
        end
        if not ensure_lobby_libraries() then
            return nil
        end
        local context = self.context and self.context() or nil
        if not context then
            return nil
        end
        local ok, joined = pcall(function()
            return self.sessions:GetAllJoinedSessionsAndLobbies(context)
        end)
        if not ok or not joined then
            return nil
        end
        for _, session in ipairs(joined) do
            local result = nil
            pcall(function()
                result = steam_id_value(session.LobbyId)
            end)
            if result and result > 0 then
                self.lobby_id = session.LobbyId
                return self.lobby_id
            end
        end
        return nil
    end

    local function find_host_steam_id()
        if self.host_id then
            local ok, result = pcall(function()
                return type(self.host_id) == "function" and self.host_id() or self.host_id
            end)
            if ok and steam_id_value(result) and steam_id_value(result) > 0 then
                return result
            end
        end
        if not ensure_shared_library() then
            return nil
        end
        local context = self.context and self.context() or nil
        if not context then
            return nil
        end
        local ok, host_id = pcall(function()
            local world = context:GetWorld()
            local player_states = world.GameState.PlayerArray
            local host_state = nil
            local lowest_player_id = math.huge
            for index = 1, #player_states do
                local player_state = player_states[index]
                local player_id = tonumber(player_state.PlayerId) or math.huge
                if player_id < lowest_player_id then
                    host_state = player_state
                    lowest_player_id = player_id
                end
            end
            if not host_state then
                return nil
            end
            return self.shared:GetSteamIdFromUniqueNetId(host_state.UniqueId)
        end)
        if ok and steam_id_value(host_id) and steam_id_value(host_id) > 0 then
            return host_id
        end
        return nil
    end

    local function set_data(key, value)
        local lobby = find_lobby()
        if not lobby then
            return false
        end
        local ok, result = pcall(function()
            return self.matchmaking:SetLobbyData(lobby, key, tostring(value))
        end)
        if ok and result == true then
            return true
        end

        -- A cached lobby becomes invalid when the player leaves or changes sessions.
        self.lobby_id = nil
        lobby = find_lobby()
        if not lobby then
            return false
        end
        ok, result = pcall(function()
            return self.matchmaking:SetLobbyData(lobby, key, tostring(value))
        end)
        return ok and result == true
    end

    local function get_data(key)
        local lobby = find_lobby()
        if not lobby then
            return nil, false
        end
        local ok, result = pcall(function()
            return self.matchmaking:GetLobbyData(lobby, key)
        end)
        return ok and as_string(result or "") or nil, ok
    end

    local function set_presence(key, value)
        if not ensure_friends_library() then
            return false
        end
        local ok, result = pcall(function()
            return self.friends:SetRichPresence(key, tostring(value))
        end)
        return ok and result == true
    end

    local function get_presence(key)
        if not ensure_friends_library() then
            return nil
        end
        local host_id = find_host_steam_id()
        if not host_id then
            return nil
        end
        local now = os.time()
        if now - self.last_presence_request_at >= 10 then
            self.last_presence_request_at = now
            pcall(function()
                self.friends:RequestFriendRichPresence(host_id)
            end)
        end
        local ok, result = pcall(function()
            return self.friends:GetFriendRichPresence(host_id, key)
        end)
        return ok and as_string(result or "") or nil
    end

    local function publish_presence_start(url, target_time, volume, serial)
        local chunks = split_utf8(url, PRESENCE_CHUNK_BYTES)
        if #chunks == 0 or #chunks > PRESENCE_MAX_CHUNKS then
            return false
        end
        for index, chunk in ipairs(chunks) do
            if not set_presence(PRESENCE_CHUNK_PREFIX .. string.format("%02d", index), chunk) then
                return false
            end
        end
        local control = table.concat({
            "play", string.format("%.3f", target_time), serial, tostring(#chunks),
            string.format("%.1f", volume),
        }, "\t")
        return set_presence(PRESENCE_CONTROL_KEY, control)
    end

    local function publish_presence_stop(serial)
        return set_presence(
            PRESENCE_CONTROL_KEY,
            table.concat({ "stop", "0", serial, "0", "0" }, "\t")
        )
    end

    local function publish_presence_volume(volume, serial)
        return set_presence(PRESENCE_VOLUME_KEY, table.concat({
            serial, string.format("%.1f", volume),
        }, "\t"))
    end

    local function next_serial()
        self.serial_counter = self.serial_counter + 1
        return string.format("%d-%d", os.time(), self.serial_counter)
    end

    function self:publish_start(url, target_time, volume)
        volume = math.max(0, math.min(1, tonumber(volume) or 0.5))
        local serial = next_serial()
        local lobby_ok = set_data(EVENT_KEY, table.concat({
            "play", string.format("%.3f", target_time), serial,
            string.format("%.1f", volume), url,
        }, "\t"))
        local presence_ok = lobby_ok or publish_presence_start(url, target_time, volume, serial)
        if not lobby_ok and not presence_ok then
            return nil, "Steam session sync unavailable"
        end
        self.last_serial = serial
        return {
            state = "play",
            url = url,
            target_time = target_time,
            serial = serial,
            volume = volume,
        }
    end

    function self:publish_stop()
        local serial = next_serial()
        local lobby_ok = set_data(EVENT_KEY, table.concat({
            "stop", "0", serial, "0", "",
        }, "\t"))
        local presence_ok = lobby_ok or publish_presence_stop(serial)
        if not lobby_ok and not presence_ok then
            return nil, "Steam session sync unavailable"
        end
        self.last_serial = serial
        return { state = "stop", serial = serial }
    end

    function self:publish_volume(volume)
        volume = math.max(0, math.min(1, tonumber(volume) or 0.5))
        local serial = next_serial()
        local lobby_ok = set_data(VOLUME_EVENT_KEY, table.concat({
            serial, string.format("%.1f", volume),
        }, "\t"))
        local presence_ok = lobby_ok or publish_presence_volume(volume, serial)
        if not lobby_ok and not presence_ok then
            return nil, "Steam session sync unavailable"
        end
        self.last_volume_serial = serial
        return { state = "volume", serial = serial, volume = volume }
    end

    local function read_lobby_volume()
        local control, available = get_data(VOLUME_EVENT_KEY)
        if not control or control == "" then return nil, nil, available end
        local serial, volume_text = control:match("^([^\t]+)\t([%d%.]+)$")
        local volume = tonumber(volume_text)
        if not serial or not volume then return nil, nil, available end
        return volume, serial, available
    end

    local function poll_lobby()
        local control, available = get_data(EVENT_KEY)
        if not control or control == "" then
            return nil, available
        end
        local state, target_text, serial, volume_text, url = control:match(
            "^(%a+)\t([^\t]*)\t([^\t]+)\t([%d%.]+)\t([^\t]*)$"
        )
        if not serial or serial == self.last_serial
            or (state ~= "play" and state ~= "stop") then
            return nil, available
        end
        if state == "stop" then
            self.last_serial = serial
            return { state = state, serial = serial }, available
        end
        local target_time = tonumber(target_text)
        local volume = tonumber(volume_text)
        if not url or url == "" or not target_time or not volume then
            return nil, available
        end
        local current_volume, volume_serial = read_lobby_volume()
        if current_volume then
            volume = current_volume
            self.last_volume_serial = volume_serial
        end
        self.last_serial = serial
        return {
            state = state,
            url = url,
            target_time = target_time,
            serial = serial,
            volume = volume,
        }, available
    end

    local function poll_lobby_volume()
        local volume, serial, available = read_lobby_volume()
        if not serial or serial == self.last_volume_serial then return nil, available end
        self.last_volume_serial = serial
        return { state = "volume", serial = serial, volume = volume }, available
    end

    local function poll_presence()
        local control = get_presence(PRESENCE_CONTROL_KEY)
        if not control or control == "" then
            return nil
        end
        local state, target_text, serial, chunk_text, volume_text = control:match(
            "^(%a+)\t([^\t]*)\t([^\t]+)\t(%d+)\t([%d%.]+)$"
        )
        if not serial or serial == self.last_serial
            or (state ~= "play" and state ~= "stop") then
            return nil
        end
        if state == "stop" then
            if get_presence(PRESENCE_CONTROL_KEY) ~= control then
                return nil
            end
            self.last_serial = serial
            return { state = state, serial = serial }
        end
        local volume = tonumber(volume_text)
        local target_time = tonumber(target_text)
        local chunk_count = tonumber(chunk_text)
        if not target_time or not chunk_count or chunk_count < 1
            or chunk_count > PRESENCE_MAX_CHUNKS then
            return nil
        end
        local chunks = {}
        for index = 1, chunk_count do
            local chunk = get_presence(PRESENCE_CHUNK_PREFIX .. string.format("%02d", index))
            if not chunk or chunk == "" then
                return nil
            end
            table.insert(chunks, chunk)
        end
        if get_presence(PRESENCE_CONTROL_KEY) ~= control then
            return nil
        end
        self.last_serial = serial
        return {
            state = state,
            url = table.concat(chunks),
            target_time = target_time,
            serial = serial,
            volume = volume or 0.5,
        }
    end

    local function poll_presence_volume()
        local control = get_presence(PRESENCE_VOLUME_KEY)
        if not control or control == "" then return nil end
        local serial, volume_text = control:match("^([^\t]+)\t([%d%.]+)$")
        if not serial or serial == self.last_volume_serial then return nil end
        local volume = tonumber(volume_text)
        if not volume or get_presence(PRESENCE_VOLUME_KEY) ~= control then return nil end
        self.last_volume_serial = serial
        return { state = "volume", serial = serial, volume = volume }
    end

    function self:poll()
        local event, event_available = poll_lobby()
        if event then return event end
        local volume_event, volume_available = poll_lobby_volume()
        if volume_event then return volume_event end
        if event_available or volume_available then
            return nil
        end
        local now = os.clock()
        if now < self.next_presence_poll_at then return nil end
        local presence_event = poll_presence() or poll_presence_volume()
        if not presence_event then self.next_presence_poll_at = now + 1 end
        return presence_event
    end

    function self:clear_lobby()
        self.lobby_id = nil
    end

    return self
end

return LobbySync
