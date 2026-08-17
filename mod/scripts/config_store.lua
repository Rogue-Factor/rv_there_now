local ConfigStore = {}

local SECTION_NAME = "/script/engine.gamesession"
local DEFAULT_MAX_PLAYERS = 4

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function section_name(line)
    local name = line:match("^%s*%[(.-)%]%s*$")
    return name and trim(name):lower() or nil
end

local function is_max_players(line)
    local key = line:match("^%s*([^=]+)%s*=")
    return key ~= nil and trim(key):lower() == "maxplayers"
end

local function read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end

    local content = file:read("*all")
    file:close()
    return content
end

local function write_file(path, content)
    local file, err = io.open(path, "wb")
    if not file then
        return false, err
    end

    local ok, write_err = file:write(content)
    file:close()
    if not ok then
        return false, write_err
    end
    return true
end

local function split_lines(content)
    local newline = content:find("\r\n", 1, true) and "\r\n" or "\n"
    local normalized = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    local cursor = 1

    while cursor <= #normalized do
        local delimiter = normalized:find("\n", cursor, true)
        if not delimiter then
            table.insert(lines, normalized:sub(cursor))
            break
        end

        table.insert(lines, normalized:sub(cursor, delimiter - 1))
        cursor = delimiter + 1
    end

    return lines, newline
end

local function rewrite(content, mode, value)
    local lines, newline = split_lines(content)
    local output = {}
    local in_target = false
    local section_seen = false
    local key_written = false

    local function append(line)
        table.insert(output, line)
    end

    local function finish_section()
        if in_target and mode == "set" and not key_written then
            append("MaxPlayers=" .. tostring(value))
            key_written = true
        end
    end

    for _, line in ipairs(lines) do
        local current_section = section_name(line)
        if current_section then
            finish_section()
            in_target = current_section == SECTION_NAME
            if in_target then
                section_seen = true
                key_written = false
            end
            append(line)
        elseif in_target and is_max_players(line) then
            if mode == "set" and not key_written then
                append("MaxPlayers=" .. tostring(value))
                key_written = true
            end
        else
            append(line)
        end
    end

    finish_section()

    if mode == "set" and not section_seen then
        if #output > 0 and output[#output] ~= "" then
            append("")
        end
        append("[/Script/Engine.GameSession]")
        append("MaxPlayers=" .. tostring(value))
    end

    return table.concat(output, newline) .. newline
end

local function write_atomic(path, content)
    local temporary = path .. ".rv-there-now.tmp"
    local ok, err = write_file(temporary, content)
    if not ok then
        return false, err
    end

    os.remove(path)
    local renamed, rename_err = os.rename(temporary, path)
    if renamed then
        return true
    end

    local fallback_ok, fallback_err = write_file(path, content)
    os.remove(temporary)
    if fallback_ok then
        return true
    end
    return false, fallback_err or rename_err
end

local function make_backup(path, content)
    if read_file(path .. ".rv-there-now.bak") ~= nil then
        return true
    end
    return write_file(path .. ".rv-there-now.bak", content)
end

function ConfigStore.default_path()
    local local_app_data = os.getenv("LOCALAPPDATA")
    if not local_app_data or local_app_data == "" then
        local user_profile = os.getenv("USERPROFILE")
        if user_profile and user_profile ~= "" then
            local_app_data = user_profile .. "\\AppData\\Local"
        end
    end

    if not local_app_data or local_app_data == "" then
        return nil, "LOCALAPPDATA is not available"
    end

    return local_app_data .. "\\Ride\\Saved\\Config\\Windows\\Game.ini"
end

function ConfigStore.default_radio_path()
    local game_path, err = ConfigStore.default_path()
    if not game_path then
        return nil, err
    end
    return game_path:gsub("Game%.ini$", "RVThereNowRadio.txt")
end

local function valid_radio_url(url)
    if #url == 0 or #url > 4096 or url:find("[\r\n%z]") then
        return false
    end

    local scheme_end = url:lower():match("^https?://()")
    return scheme_end ~= nil and url:lower():find("https?://", scheme_end) == nil
end

function ConfigStore.read_radio_url(path)
    local content = read_file(path)
    if not content then
        return nil
    end
    local url = trim(content:match("^[^\r\n]*") or "")
    if not valid_radio_url(url) then
        return nil
    end
    return url
end

function ConfigStore.set_radio_url(path, url)
    url = trim(tostring(url or ""))
    if not valid_radio_url(url) then
        return false, "invalid HTTP stream URL"
    end
    return write_atomic(path, url .. "\n")
end

function ConfigStore.read_max_players(path)
    local content = read_file(path)
    if not content then
        return DEFAULT_MAX_PLAYERS
    end

    local in_target = false
    local result = nil
    for _, line in ipairs(split_lines(content)) do
        local current_section = section_name(line)
        if current_section then
            in_target = current_section == SECTION_NAME
        elseif in_target and is_max_players(line) then
            local raw_value = line:match("=%s*(.-)%s*$")
            local parsed = tonumber(raw_value)
            if parsed then
                result = math.floor(parsed)
            end
        end
    end

    return result or DEFAULT_MAX_PLAYERS
end

function ConfigStore.set_max_players(path, value)
    value = tonumber(value)
    if not value or value % 1 ~= 0 or value < 4 or value > 24 then
        return false, "player count must be an integer from 4 to 24"
    end

    local original = read_file(path) or ""
    if original ~= "" then
        local backup_ok, backup_err = make_backup(path, original)
        if not backup_ok then
            return false, "could not create backup: " .. tostring(backup_err)
        end
    end

    return write_atomic(path, rewrite(original, "set", value))
end

function ConfigStore.reset(path)
    local original = read_file(path)
    if not original then
        return true
    end

    local backup_ok, backup_err = make_backup(path, original)
    if not backup_ok then
        return false, "could not create backup: " .. tostring(backup_err)
    end

    return write_atomic(path, rewrite(original, "reset"))
end

function ConfigStore.restore(path)
    local backup, err = read_file(path .. ".rv-there-now.bak")
    if not backup then
        return false, err or "no backup exists"
    end
    return write_atomic(path, backup)
end

return ConfigStore
