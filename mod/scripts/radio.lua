local Radio = {}

local DEFAULT_URL = "https://streams.radiomast.io/ref-128k-mp3-stereo"
local OPEN_TIMEOUT_SECONDS = 120
local SYNC_LEAD_SECONDS = 12

local module_source = debug.getinfo(1, "S").source:gsub("^@", "")
local module_directory = module_source:match("^(.*[\\/])") or ""
local DEFAULT_BRIDGE_PATH = module_directory .. "..\\bin\\rv-radio-bridge.exe"

local function default_is_valid(object)
    if not object then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid
end

local function unreal_address(object)
    if object == nil then return nil end
    local ok, address = pcall(function() return object:GetAddress() end)
    if not ok or address == nil then return nil end
    return tostring(address)
end

local function same_unreal_object(left, right)
    if left == right then return true end
    local left_address = unreal_address(left)
    local right_address = unreal_address(right)
    return left_address ~= nil and left_address == right_address
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content and content:gsub("[%s%z]+$", "") or nil
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function default_status_path()
    local temporary = os.getenv("TEMP") or os.getenv("TMP") or "."
    return temporary .. "\\rv-there-now-radio.status"
end

local function is_youtube_url(url)
    local host = url:lower():match("^https?://([^/:?]+)") or ""
    return host == "youtu.be" or host == "youtube.com" or host:match("%.youtube%.com$") ~= nil
end

function Radio.new(options)
    options = options or {}
    local self = {
        url = options.url or DEFAULT_URL,
        bridge_path = options.bridge_path or DEFAULT_BRIDGE_PATH,
        status_path = options.status_path or default_status_path(),
        url_path = options.url_path,
        youtube_path = options.youtube_path,
        pcm_path = options.pcm_path,
        play_path = options.play_path,
        confirmed_path = options.confirmed_path,
        spatial_path = options.spatial_path,
        is_valid = options.is_valid or default_is_valid,
        log = options.log or function() end,
        execute = options.execute or os.execute,
        get_player_controller = options.get_player_controller,
        get_server_time = options.get_server_time or function() return os.time() end,
        get_player_count = options.get_player_count or function() return 1 end,
        is_host_override = options.is_host,
        bridge_available = options.bridge_available,
        read_status = options.read_status,
        sync = options.sync,
        state = "OFF",
        detail = "",
        backend = nil,
        open_started_at = nil,
        target_time = nil,
        active_serial = nil,
        pcm_sample_rate = nil,
        pcm_channels = nil,
        play_signal_seen = false,
        host_signal_sent = false,
        sync_pending = false,
        next_sync_retry_at = nil,
        tape_player = nil,
        closing = false,
        stream_prefix = nil,
        stream_sequence = 0,
        stream_chunk_seconds = nil,
        native_play_started = false,
    }

    if not self.url_path then
        self.url_path = self.status_path:gsub("%.status$", ".url")
    end
    if not self.youtube_path then
        self.youtube_path = self.status_path:gsub(
            "rv%-there%-now%-radio%.status$", "rv-there-now-youtube.m4a"
        )
    end
    if not self.pcm_path then
        self.pcm_path = self.status_path:gsub(
            "rv%-there%-now%-radio%.status$", "rv-there-now-youtube.pcm"
        )
    end
    if not self.play_path then
        self.play_path = self.status_path:gsub(
            "rv%-there%-now%-radio%.status$", "rv-there-now-radio.play"
        )
    end
    if not self.spatial_path then
        self.spatial_path = self.status_path:gsub(
            "rv%-there%-now%-radio%.status$", "rv-there-now-radio.spatial"
        )
    end
    if not self.confirmed_path then
        self.confirmed_path = self.status_path:gsub(
            "rv%-there%-now%-radio%.status$", "rv-there-now-radio.playing"
        )
    end
    if not self.bridge_available then
        self.bridge_available = function()
            return file_exists(self.bridge_path)
        end
    end
    if not self.read_status then
        self.read_status = function()
            return read_file(self.status_path)
        end
    end

    local function find_tape_player()
        local controller = self.get_player_controller and self.get_player_controller() or nil
        local world = self.is_valid(controller) and controller:GetWorld() or nil
        local ok, players = pcall(FindAllOf, "BP_TapePlayer_C")
        if not ok or not players then
            return nil
        end
        local fallback = nil
        for _, tape_player in ipairs(players) do
            if self.is_valid(tape_player) then
                fallback = fallback or tape_player
                if self.is_valid(world) then
                    local same_world = false
                    pcall(function()
                        same_world = same_unreal_object(tape_player:GetWorld(), world)
                    end)
                    if same_world then
                        return tape_player
                    end
                end
            end
        end
        return self.is_valid(world) and nil or fallback
    end

    local function ensure_tape_player()
        if self.is_valid(self.tape_player) then
            local controller = self.get_player_controller and self.get_player_controller() or nil
            local world = self.is_valid(controller) and controller:GetWorld() or nil
            if not self.is_valid(world) then return true end
            local current_world = false
            pcall(function()
                current_world = same_unreal_object(self.tape_player:GetWorld(), world)
            end)
            if current_world then return true end
            self.tape_player = nil
        end
        self.tape_player = find_tape_player()
        if not self.is_valid(self.tape_player) then
            return false, "Enter the RV first"
        end
        return true
    end

    local function execute(command)
        local ok, result = pcall(self.execute, command)
        return ok and (result == true or result == 0)
    end

    local function stop_helper()
        execute(string.format('start "" /wait /B "%s" --stop', self.bridge_path))
    end

    local function start_helper()
        if not self.bridge_available() then
            return false, "Bundled radio bridge is missing"
        end
        local file = io.open(self.url_path, "wb")
        if not file then
            return false, "Could not write stream URL"
        end
        local written = file:write(self.url)
        file:close()
        if not written then
            return false, "Could not write stream URL"
        end
        os.remove(self.status_path)
        os.remove(self.youtube_path)
        os.remove(self.pcm_path)
        os.remove(self.play_path)
        os.remove(self.confirmed_path)
        os.remove(self.spatial_path)
        local mode = is_youtube_url(self.url) and "--prepare-youtube" or "--stream-pcm"
        local command = string.format(
            'start "" /B "%s" %s --watch Ride-Win64-Shipping.exe',
            self.bridge_path, mode
        )
        if not execute(command) then
            return false, "Could not launch bundled radio helper"
        end
        self.backend = is_youtube_url(self.url) and "youtube" or "stream"
        self.state = "PREPARING"
        self.detail = self.backend == "youtube" and "Downloading on all players" or "Preparing RV stream"
        self.open_started_at = os.time()
        return true
    end

    local function server_time()
        local ok, value = pcall(self.get_server_time)
        return ok and tonumber(value) or os.time()
    end

    local function write_atomic(path, content)
        local partial = path .. ".part"
        local file = io.open(partial, "wb")
        if not file then return false end
        local written = file:write(content)
        file:close()
        if not written then
            os.remove(partial)
            return false
        end
        os.remove(path)
        if not os.rename(partial, path) then
            os.remove(partial)
            return false
        end
        return true
    end

    local function update_native_spatial()
        if not self.native_play_started then return end
        local volume = 0.5
        pcall(function()
            volume = math.max(0, math.min(1,
                tonumber(self.tape_player.VolumeMultiplier) or 0.5))
        end)
        local left, right = volume, volume
        pcall(function()
            local controller = self.get_player_controller and self.get_player_controller() or nil
            local pawn = self.is_valid(controller) and controller:K2_GetPawn() or nil
            if not self.is_valid(pawn) then return end
            local source = self.tape_player:K2_GetActorLocation()
            local listener = pawn:K2_GetActorLocation()
            local rotation = controller:GetControlRotation()
            local dx = tonumber(source.X) - tonumber(listener.X)
            local dy = tonumber(source.Y) - tonumber(listener.Y)
            local dz = tonumber(source.Z) - tonumber(listener.Z)
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            local distance_gain = math.max(0, 1 - distance / 10000)
            local pan = 0
            if distance > 1 then
                local yaw = math.rad(tonumber(rotation.Yaw) or 0)
                pan = math.max(-1, math.min(1,
                    (dx * -math.sin(yaw) + dy * math.cos(yaw)) / distance))
            end
            left = volume * distance_gain * (pan > 0 and (1 - pan) or 1)
            right = volume * distance_gain * (pan < 0 and (1 + pan) or 1)
        end)
        write_atomic(self.spatial_path, string.format("%.4f %.4f", left, right))
    end

    local function start_native_playback(sequence)
        self.native_play_started = true
        update_native_spatial()
        if not write_atomic(self.play_path, tostring(sequence or 0)) then
            self.native_play_started = false
            return false, "Could not signal native audio playback"
        end
        return true
    end

    local function local_is_host()
        if self.is_host_override ~= nil then
            return self.is_host_override == true
        end
        local ready = ensure_tape_player()
        if not ready then
            return false
        end
        local ok, authority = pcall(function()
            return self.tape_player:HasAuthority()
        end)
        return ok and authority == true
    end

    local function stop_unreal_audio()
        pcall(function()
            if self.is_valid(self.tape_player.Audio) then
                self.tape_player.Audio:Stop()
            end
        end)
    end

    local function stream_chunk_path(sequence)
        return string.format("%s.%06d.pcm", self.stream_prefix, sequence)
    end

    local function close_local(reason)
        self.closing = true
        self.state = "OFF"
        stop_helper()
        if self.is_valid(self.tape_player) and self.is_valid(self.tape_player.Audio) then
            pcall(function()
                self.tape_player.Audio:Stop()
            end)
        end
        os.remove(self.youtube_path)
        os.remove(self.pcm_path)
        self.detail = reason or ""
        self.backend = nil
        self.open_started_at = nil
        self.target_time = nil
        self.active_serial = nil
        self.pcm_sample_rate = nil
        self.pcm_channels = nil
        self.stream_prefix = nil
        self.stream_sequence = 0
        self.stream_chunk_seconds = nil
        self.native_play_started = false
        os.remove(self.play_path)
        os.remove(self.confirmed_path)
        os.remove(self.spatial_path)
        os.remove(self.play_path .. ".part")
        os.remove(self.spatial_path .. ".part")
        self.play_signal_seen = false
        self.host_signal_sent = false
        self.sync_pending = false
        self.next_sync_retry_at = nil
        self.closing = false
    end

    local function apply_play_event(event)
        if event.serial and event.serial == self.active_serial then
            return true
        end
        local ok, err = self:set_url(event.url)
        if not ok then
            return false, err
        end
        close_local()
        local ready, tape_error = ensure_tape_player()
        if not ready then
            self.state = "UNAVAILABLE"
            self.detail = tape_error
            return false, tape_error
        end
        self.active_serial = event.serial
        self.target_time = tonumber(event.target_time) or (server_time() + 5)
        local started, helper_error = start_helper()
        if not started then
            self.state = "FAILED"
            self.detail = helper_error
            return false, helper_error
        end
        stop_unreal_audio()
        self.log("Synchronized RV radio source received")
        return true
    end

    local function signal_tape(playing)
        local controller = self.get_player_controller and self.get_player_controller() or nil
        if not self.is_valid(controller) or not self.is_valid(self.tape_player) then
            return false
        end
        local ok = pcall(function()
            controller:Server_TapeSetPlaying(self.tape_player, playing)
        end)
        if not ok then
            ok = pcall(function()
                self.tape_player:SetPlaying(playing)
            end)
        end
        return ok
    end

    function self:set_url(url)
        url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #url == 0 or #url > 4096 then
            return false, "URL must be 1 to 4096 characters"
        end
        if not url:lower():match("^https?://") then
            return false, "URL must start with http:// or https://"
        end
        if url:find("[\r\n%z]") then
            return false, "URL contains invalid characters"
        end
        local scheme_end = url:lower():match("^https?://()")
        if url:lower():find("https?://", scheme_end) then
            return false, "URL contains another address"
        end
        self.url = url
        return true
    end

    function self:source_name()
        local source = self.url:match("^[Hh][Tt][Tt][Pp][Ss]?://([^/]+)") or "custom stream"
        return #source > 42 and (source:sub(1, 39) .. "...") or source
    end

    function self:start()
        local ready, err = ensure_tape_player()
        if not ready then
            self.state = "UNAVAILABLE"
            self.detail = err
            return false
        end
        if not local_is_host() then
            self.state = "UNAVAILABLE"
            self.detail = "Only the host can change the RV radio"
            return false
        end
        local target = server_time() + SYNC_LEAD_SECONDS
        local event = nil
        local sync_pending = false
        if self.sync then
            event, err = self.sync:publish_start(self.url, target)
            if not event then
                local count_ok, player_count = pcall(self.get_player_count)
                if not count_ok or (tonumber(player_count) or 1) > 1 then
                    self.state = "UNAVAILABLE"
                    self.detail = err or "Steam session sync unavailable"
                    self.log("Could not synchronize radio start: " .. tostring(self.detail))
                    return false
                end
                sync_pending = true
            end
        end
        if not event then
            event = {
                state = "play",
                url = self.url,
                target_time = target,
                serial = string.format("local-%d", os.time()),
            }
        end
        local applied, apply_error = apply_play_event(event)
        if applied and sync_pending then
            self.sync_pending = true
            self.next_sync_retry_at = os.time() + 5
            self.detail = "Local RV audio; waiting for Steam session"
            self.log("Steam session unavailable; radio started locally and will retry")
        end
        return applied, apply_error
    end

    function self:stop(reason)
        if local_is_host() and self.sync then
            local _, err = self.sync:publish_stop()
            if err then self.log("Could not publish radio stop: " .. tostring(err)) end
        end
        signal_tape(false)
        close_local(reason)
        self.log(reason or "Internet radio stopped")
    end

    function self:toggle()
        if self:is_active() then
            self:stop()
            return false
        end
        return self:start()
    end

    function self:poll_sync()
        if not self.sync then
            return
        end
        local event = self.sync:poll()
        if not event then
            return
        end
        if event.state == "stop" then
            if self:is_active() then close_local("Stopped by host") end
            return
        end
        local ok, err = apply_play_event(event)
        if not ok then
            self.log("Could not apply synchronized radio state: " .. tostring(err))
        end
    end

    function self:on_tape_state(playing)
        if self.closing then
            return false
        end
        if not self:is_active() then
            if not playing then return false end
            local started, err = self:start()
            if started then
                self.play_signal_seen = true
                self.log("Internet radio started from the RV play control")
                return true
            end
            self.log("Could not start internet radio from the RV: " .. tostring(err or self.detail))
            return false
        end
        if playing then
            self.play_signal_seen = true
            stop_unreal_audio()
            return true
        end
        if self.play_signal_seen then
            if local_is_host() and self.sync then self.sync:publish_stop() end
            close_local("Stopped at RV radio")
            return true
        end
        return false
    end

    function self:update_volume()
        if not self:is_active() or not self.is_valid(self.tape_player) then return end
        if self.is_valid(self.tape_player.Audio) then
            pcall(function()
                self.tape_player.Audio:SetVolumeMultiplier(
                    math.max(0, math.min(1,
                        tonumber(self.tape_player.VolumeMultiplier) or 0.5))
                )
            end)
        end
        update_native_spatial()
    end

    function self:maintain_audio()
        if not self:is_active() then
            return
        end
        stop_unreal_audio()
        self:update_volume()
    end

    function self:update()
        if not self:is_active() then
            return
        end
        self:maintain_audio()

        if self.sync_pending and local_is_host() and self.sync
            and os.time() >= (self.next_sync_retry_at or 0) then
            self.next_sync_retry_at = os.time() + 5
            local event = self.sync:publish_start(self.url, self.target_time or server_time())
            if event then
                self.active_serial = event.serial
                self.sync_pending = false
                self.next_sync_retry_at = nil
                self.log("Internet radio synchronization is now available")
            end
        end

        local status = self.read_status()
        if status and status:match("^ERROR") then
            self.state = "FAILED"
            self.detail = status:match("^ERROR%s+(.+)$") or "Radio helper failed"
            self.backend = nil
            self.log("Internet radio helper failed: " .. self.detail)
            return
        end
        if status and status:match("^BUFFERING%s+") then
            self.detail = status:match("^BUFFERING%s+(.+)$") or "Buffering live stream"
        end
        if status and status:match("^READY_PCM%s+") then
            self.state = "FAILED"
            self.detail = "Restart required to load the new radio bridge"
            return
        elseif status and status:match("^STREAM_PCM%s+") and not self.stream_prefix then
            local prefix, sample_rate, channels, chunk_seconds = status:match(
                "^STREAM_PCM%s+([^\t]+)\t(%d+)\t(%d+)\t(%d+)$"
            )
            if not prefix then
                self.state = "FAILED"
                self.detail = "Radio helper returned invalid stream metadata"
                return
            end
            self.stream_prefix = prefix
            self.pcm_sample_rate = tonumber(sample_rate)
            self.pcm_channels = tonumber(channels)
            self.stream_chunk_seconds = tonumber(chunk_seconds)
            self.detail = "Live stream buffered; waiting for synchronized start"
        end

        local now = server_time()
        if self.target_time and now < self.target_time then
            local remaining = math.max(1, math.ceil(self.target_time - now))
            if self.stream_prefix then
                self.detail = string.format("Live stream buffered; starting in %ds", remaining)
            end
        end
        if local_is_host() and not self.host_signal_sent and self.target_time and now >= self.target_time then
            self.host_signal_sent = true
            signal_tape(true)
        end
        if self.stream_prefix and not self.native_play_started
            and self.target_time and now >= self.target_time then
            local elapsed = math.max(0, now - self.target_time)
            local sequence = math.floor(elapsed / self.stream_chunk_seconds)
            for skipped = 0, sequence - 1 do
                os.remove(stream_chunk_path(skipped))
            end
            local accepted, err = start_native_playback(sequence)
            if accepted then
                self.stream_sequence = sequence
                self.state = "OPENING"
                self.detail = "Starting native RV audio output"
                self.log("Released synchronized native audio start")
            else
                self.state = "FAILED"
                self.detail = err
                self.log("Native RV stream failed: " .. tostring(err))
            end
        end

        if self.native_play_started and file_exists(self.confirmed_path)
            and self.state ~= "PLAYING" then
            self.state = "PLAYING"
            self.detail = self.sync_pending
                and "Local RV audio; waiting for Steam session"
                or "Synchronized live RV stream"
            self.log("Native RV audio output confirmed")
        end

        if (self.state == "PREPARING" or self.state == "OPENING") and self.open_started_at
            and os.difftime(os.time(), self.open_started_at) >= OPEN_TIMEOUT_SECONDS then
            self.state = "FAILED"
            self.detail = "Radio preparation timed out"
            stop_helper()
        end
    end

    function self:label()
        if self.state == "PLAYING" then return "PLAYING" end
        if self.state == "PREPARING" or self.state == "OPENING" then return "SYNCING" end
        if self.state == "FAILED" or self.state == "UNAVAILABLE" then return "FAILED" end
        return "OFF"
    end

    function self:is_active()
        return self.state == "PREPARING" or self.state == "OPENING" or self.state == "PLAYING"
    end

    function self:status_text()
        if self.state == "OFF" then
            return self.detail ~= "" and self.detail or "Internet radio is off"
        end
        return self.detail ~= "" and self.detail or self.state
    end

    return self
end

return Radio
