local MOD_NAME = "RVThereNow"
local MOD_VERSION = "0.17.0"
local MIN_PLAYERS = 4
local MAX_PLAYERS = 24
local PLAYER_ROWS = 8
local MENU_ROWS = 5

local RADIO_STATIONS = {
    {
        name = "SUMMER HITS '76",
        detail = "AccuRadio 1976 hits",
        url = "https://www.accuradio.com/channel/6a16080bab53e30b49bec67b",
    },
    {
        name = "GROOVE SALAD",
        detail = "Ambient and downtempo",
        url = "https://ice5.somafm.com/groovesalad-128-mp3",
    },
    {
        name = "DRONE ZONE",
        detail = "Atmospheric ambient",
        url = "https://ice5.somafm.com/dronezone-128-mp3",
    },
    {
        name = "SECRET AGENT",
        detail = "Spy and lounge soundtrack",
        url = "https://ice5.somafm.com/secretagent-128-mp3",
    },
    {
        name = "LEFT COAST 70S",
        detail = "Mellow seventies rock",
        url = "https://ice5.somafm.com/seventies-128-mp3",
    },
    {
        name = "UNDERGROUND 80S",
        detail = "Synthpop and new wave",
        url = "https://ice5.somafm.com/u80s-128-mp3",
    },
    {
        name = "INDIE POP ROCKS",
        detail = "New and classic indie pop",
        url = "https://ice5.somafm.com/indiepop-128-mp3",
    },
    {
        name = "DEF CON RADIO",
        detail = "Electronic hacker radio",
        url = "https://ice5.somafm.com/defcon-128-mp3",
    },
    {
        name = "KONA 610 AM",
        detail = "News, talk, and Coast to Coast overnight",
        now_playing = "Live news and talk / Coast to Coast overnight",
        url = "https://live.amperwave.net/direct/townsquare-konaammp3-ibc3",
    },
    {
        name = "WNYC 93.9",
        detail = "Public radio news and conversation",
        now_playing = "Live public radio from New York",
        url = "https://fm939.wnyc.org/wnycfm",
    },
    {
        name = "RNZ NATIONAL",
        detail = "News, interviews, readings, and features",
        now_playing = "RNZ National live programming",
        url = "http://radionz-ice.streamguys.com/national.mp3",
    },
    {
        name = "BBC WORLD SERVICE",
        detail = "Global news, documentaries, and discussion",
        now_playing = "BBC World Service live programming",
        url = "https://stream.live.vc.bbcmedia.co.uk/bbc_world_service",
    },
}

local script_source = debug.getinfo(1, "S").source:gsub("^@", "")
local script_directory = script_source:match("^(.*[\\/])") or ""
local ConfigStore = dofile(script_directory .. "config_store.lua")
local LobbySync = dofile(script_directory .. "lobby_sync.lua")
local Radio = dofile(script_directory .. "radio.lua")
local UEHelpers = require("UEHelpers")

local State = {
    open = false,
    count = MIN_PLAYERS,
    applied_count = MIN_PLAYERS,
    selected_row = 1,
    hud_enabled = true,
    status = "Ready",
    session_players = 0,
    session_role = "MENU",
    in_game = false,
    players = {},
    average_ping = nil,
    player_page = 1,
    config_path = nil,
    radio_config_path = nil,
    station_index = 1,
    station_cursor = 1,
    station_list_open = false,
    player_controller = nil,
    ui = nil,
    tape_hooks = {},
    tape_hooks_attempted = false,
    tape_controls = {},
}

local COLORS = {
    panel = { R = 0.035, G = 0.043, B = 0.047, A = 0.96 },
    surface = { R = 0.12, G = 0.14, B = 0.15, A = 1.0 },
    surface_alt = { R = 0.20, G = 0.22, B = 0.23, A = 1.0 },
    text = { R = 0.94, G = 0.95, B = 0.93, A = 1.0 },
    muted = { R = 0.63, G = 0.66, B = 0.64, A = 1.0 },
    green = { R = 0.19, G = 0.56, B = 0.34, A = 1.0 },
    red = { R = 0.68, G = 0.20, B = 0.18, A = 1.0 },
    amber = { R = 0.91, G = 0.62, B = 0.15, A = 1.0 },
}

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function is_valid(object)
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

local function unwrap(remote)
    if remote == nil then return nil end
    local ok, value = pcall(function() return remote:get() end)
    return ok and value or remote
end

local function resolve_hit_component(hit_result)
    local hit = unwrap(hit_result)
    if hit == nil then return nil end
    local component = nil
    pcall(function() component = hit.HitComponent end)
    if component == nil then pcall(function() component = hit.Component end) end
    if is_valid(component) then return component end
    local resolved = nil
    pcall(function() resolved = component:Get() end)
    if is_valid(resolved) then return resolved end
    pcall(function() resolved = component:get() end)
    return is_valid(resolved) and resolved or nil
end

local function run_on_game_thread(callback)
    ExecuteInGameThread(function()
        local ok, err = pcall(callback)
        if not ok then
            log("Game-thread error: " .. tostring(err))
        end
    end)
end

local RadioLobby = LobbySync.new({
    context = function()
        return UEHelpers.GetPlayerController()
    end,
    log = log,
})

local InternetRadio = Radio.new({
    is_valid = is_valid,
    log = log,
    get_player_controller = function()
        return UEHelpers.GetPlayerController()
    end,
    get_server_time = function()
        local controller = UEHelpers.GetPlayerController()
        local world = is_valid(controller) and controller:GetWorld() or nil
        local game_state = is_valid(world) and world.GameState or nil
        if is_valid(game_state) then
            return game_state:GetServerWorldTimeSeconds()
        end
        return os.time()
    end,
    get_player_count = function()
        local controller = UEHelpers.GetPlayerController()
        local world = is_valid(controller) and controller:GetWorld() or nil
        local game_state = is_valid(world) and world.GameState or nil
        if is_valid(game_state) and game_state.PlayerArray then
            return #game_state.PlayerArray
        end
        return 1
    end,
    sync = RadioLobby,
})

local function set_text(widget, value)
    if not is_valid(widget) then
        return
    end
    pcall(function()
        widget:SetText(FText(tostring(value)))
    end)
end

local function set_text_color(widget, color)
    if not is_valid(widget) then
        return
    end
    pcall(function()
        widget:SetColorAndOpacity({
            SpecifiedColor = color,
            ColorUseRule = 0,
        })
    end)
end

local function set_font_size(widget, size)
    pcall(function()
        local font = widget.Font
        font.Size = size
        widget:SetFont(font)
    end)
end

local function set_visibility(widget, visible)
    if is_valid(widget) then
        widget:SetVisibility(visible and 0 or 1)
    end
end

local function focus_game_viewport()
    pcall(function()
        local widget_library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        widget_library:SetFocusToGameViewport()
    end)
end

local function find_class(path)
    local object = StaticFindObject(path)
    if not is_valid(object) then
        error("Required UMG class is unavailable: " .. path)
    end
    return object
end

local function add_canvas_child(canvas, child, x, y, width, height, z_order)
    local slot = canvas:AddChild(child)
    slot:SetAnchors({
        Minimum = { X = 1.0, Y = 0.0 },
        Maximum = { X = 1.0, Y = 0.0 },
    })
    slot:SetAlignment({ X = 0.0, Y = 0.0 })
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = width, Y = height })
    slot:SetZOrder(z_order or 1)
    return slot
end

local function add_bottom_right_child(canvas, child, x, y, width, height, z_order)
    local slot = canvas:AddChild(child)
    slot:SetAnchors({
        Minimum = { X = 1.0, Y = 1.0 },
        Maximum = { X = 1.0, Y = 1.0 },
    })
    slot:SetAlignment({ X = 0.0, Y = 0.0 })
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = width, Y = height })
    slot:SetZOrder(z_order or 1)
    return slot
end

local function create_text(tree, classes, value, color, font_size, justification)
    local widget = StaticConstructObject(classes.text, tree)
    set_text(widget, value)
    set_text_color(widget, color or COLORS.text)
    set_font_size(widget, font_size or 16)
    pcall(function()
        widget:SetJustification(justification or 1)
    end)
    return widget
end

local function create_border(tree, classes, color)
    local widget = StaticConstructObject(classes.border, tree)
    widget:SetBrushColor(color)
    return widget
end

local function track(ui, widget, menu_only)
    table.insert(ui.references, widget)
    if menu_only then
        table.insert(ui.menu_widgets, widget)
    end
    return widget
end

local function add_label(ui, value, x, y, width, height, color, font_size, menu_only)
    local widget = create_text(ui.tree, ui.classes, value, color, font_size)
    add_canvas_child(ui.canvas, widget, x, y, width, height, 3)
    return track(ui, widget, menu_only)
end

local function add_left_label(ui, value, x, y, width, height, color, font_size, menu_only)
    local widget = create_text(ui.tree, ui.classes, value, color, font_size, 0)
    add_canvas_child(ui.canvas, widget, x, y, width, height, 3)
    return track(ui, widget, menu_only)
end

local function add_row(ui, index, y, label)
    local border = create_border(ui.tree, ui.classes, COLORS.surface)
    add_canvas_child(ui.canvas, border, -426, y, 370, 38, 2)
    track(ui, border, true)
    ui.rows[index] = border

    local row_label = add_label(ui, label, -412, y + 7, 176, 25, COLORS.muted, 14, true)
    local value = add_label(ui, "", -231, y + 5, 160, 27, COLORS.text, 16, true)
    ui.row_values[index] = value
    ui.row_widgets[index] = { border, row_label, value }
    return value
end

local function update_runtime_cap(value)
    local default_session = StaticFindObject("/Script/Engine.Default__GameSession")
    if not is_valid(default_session) then
        return false
    end
    return pcall(function()
        default_session.MaxPlayers = value
    end)
end

local function update_session_snapshot()
    local player_controller = State.player_controller
    if not is_valid(player_controller) then
        return
    end

    local ok, players, role, roster, average_ping, in_game = pcall(function()
        local player_states = {}
        local world = player_controller:GetWorld()
        if is_valid(world) and is_valid(world.GameState) and world.GameState.PlayerArray then
            player_states = world.GameState.PlayerArray
        end

        local is_host = false
        pcall(function()
            is_host = player_controller:HasAuthority()
        end)
        local local_state = player_controller.PlayerState
        local local_address = is_valid(local_state) and tostring(local_state:GetAddress()) or nil
        local rows = {}
        local ping_total = 0
        local ping_count = 0

        for index = 1, #player_states do
            local player_state = player_states[index]
            if is_valid(player_state) then
                local name = "Player " .. tostring(index)
                pcall(function()
                    local player_name = player_state:GetPlayerName()
                    local resolved = player_name:ToString()
                    if resolved ~= "" and resolved ~= "nil" then
                        name = resolved
                    end
                end)

                local is_local = local_address ~= nil and tostring(player_state:GetAddress()) == local_address
                local ping = nil
                pcall(function()
                    ping = tonumber(player_state:GetPingInMilliseconds())
                end)
                if not ping then
                    pcall(function()
                        ping = tonumber(player_state.ExactPing)
                    end)
                end
                if ping then
                    ping = math.max(0, math.floor(ping + 0.5))
                end

                local status = is_local and "YOU" or "ONLINE"
                pcall(function()
                    if player_state.bIsABot then
                        status = "BOT"
                    elseif player_state.bIsInactive then
                        status = "INACTIVE"
                    elseif player_state.bOnlySpectator then
                        status = "SPECTATOR"
                    end
                end)

                if ping and ping > 0 and not is_local then
                    ping_total = ping_total + ping
                    ping_count = ping_count + 1
                end
                table.insert(rows, {
                    name = name,
                    ping = ping,
                    is_local = is_local,
                    status = status,
                })
            end
        end

        local world_identity = ""
        pcall(function()
            world_identity = tostring(world:GetFullName())
        end)
        pcall(function()
            world_identity = world_identity .. " "
                .. tostring(world.CommittedPersistentLevelName:ToString())
        end)
        local lower_world = world_identity:lower()
        local gameplay = #rows > 0
        if lower_world:find("/game/ride/maps/frontend", 1, true) then
            gameplay = false
        elseif lower_world:find("/game/ride/maps/ridemap", 1, true)
            or lower_world:find("ridemap", 1, true) then
            gameplay = true
        end

        local average = ping_count > 0 and math.floor(ping_total / ping_count + 0.5) or nil
        return #rows, is_host and "HOST" or "CLIENT", rows, average, gameplay
    end)

    if ok then
        State.session_players = players
        State.session_role = role
        State.players = roster
        State.average_ping = average_ping
        State.in_game = in_game == true
        if not State.in_game then
            State.session_role = "MENU"
        end
    end
end

local function visible_menu_rows()
    return State.in_game and { 4, 5 } or { 1, 3 }
end

local function normalize_menu_selection()
    local rows = visible_menu_rows()
    for _, row in ipairs(rows) do
        if State.selected_row == row then return end
    end
    State.selected_row = rows[1]
    State.station_list_open = false
end

local function set_menu_widgets_visible(visible)
    if not State.ui then return end
    local ui = State.ui
    for _, widget in ipairs(ui.menu_widgets) do
        set_visibility(widget, visible)
    end

    local allowed = {}
    for _, row in ipairs(visible_menu_rows()) do allowed[row] = true end
    for index, widgets in ipairs(ui.row_widgets) do
        for _, widget in ipairs(widgets) do
            set_visibility(widget, visible and allowed[index] == true)
        end
    end
    for _, widget in ipairs(ui.game_widgets) do
        set_visibility(widget, visible and State.in_game)
    end
    pcall(function()
        ui.panel_slot:SetSize({ X = 470, Y = State.in_game and 450 or 180 })
    end)
end

local function row_color(index)
    if index ~= State.selected_row then
        return COLORS.surface
    end
    if index == 3 then
        return COLORS.green
    end
    if index == 5 and InternetRadio.state == "PLAYING" then
        return COLORS.green
    end
    return COLORS.surface_alt
end

local function refresh_ui()
    local ui = State.ui
    if not ui or not is_valid(ui.root) then
        return
    end

    update_session_snapshot()
    normalize_menu_selection()
    set_menu_widgets_visible(State.open)
    local previous_radio_state = InternetRadio.state
    InternetRadio:update()
    for index, station in ipairs(RADIO_STATIONS) do
        if station.url == InternetRadio.url then
            State.station_index = index
            break
        end
    end
    if State.selected_row == 5 and InternetRadio:is_active() then
        State.status = InternetRadio:status_text()
    end
    if previous_radio_state ~= InternetRadio.state
        and (previous_radio_state == "OPENING" or InternetRadio.state == "FAILED") then
        State.status = InternetRadio:status_text()
    end
    set_text(ui.session_text, string.format("SESSION  %d / %d   %s", State.session_players, State.applied_count, State.session_role))
    set_text(ui.row_values[1], string.format("<  %d  >", State.count))
    set_text(ui.row_values[2], State.hud_enabled and "ON" or "OFF")
    set_text(ui.row_values[3], "APPLY")
    set_text(ui.row_values[4], RADIO_STATIONS[State.station_index].name)
    set_text(ui.row_values[5], InternetRadio:label())

    for index, row in ipairs(ui.rows) do
        pcall(function()
            row:SetBrushColor(row_color(index))
        end)
    end

    set_text(ui.status_text, State.status)
    for index, widget in ipairs(ui.station_options) do
        local dropdown_visible = State.open and State.in_game and State.station_list_open
        set_visibility(widget, dropdown_visible)
        if dropdown_visible then
            set_text_color(widget, index == State.station_cursor and COLORS.green or COLORS.text)
        end
    end
    set_visibility(ui.station_dropdown, State.open and State.in_game and State.station_list_open)

    if State.selected_row == 4 then
        local station = RADIO_STATIONS[State.station_list_open
            and State.station_cursor or State.station_index]
        set_text(ui.warning_text, station.detail)
        set_text_color(ui.warning_text, COLORS.muted)
    elseif State.selected_row == 5 then
        set_text(ui.warning_text, "RV positional playback")
        set_text_color(ui.warning_text, COLORS.muted)
    elseif State.count > 8 then
        set_text(ui.warning_text, "Large sessions may be unstable")
        set_text_color(ui.warning_text, COLORS.amber)
    else
        set_text(ui.warning_text, "Host-only setting")
        set_text_color(ui.warning_text, COLORS.muted)
    end

    local ping_summary = State.average_ping and string.format("AVG %d ms", State.average_ping) or "PING --"
    set_text(ui.hud_text, string.format("RV NOW   %d / %d   %s", State.session_players, State.applied_count, ping_summary))

    local page_count = math.max(1, math.ceil(#State.players / PLAYER_ROWS))
    State.player_page = math.max(1, math.min(page_count, State.player_page))
    set_text(ui.player_page_text, string.format("PLAYERS  %d / %d   PAGE %d / %d", State.session_players, State.applied_count, State.player_page, page_count))
    local first = (State.player_page - 1) * PLAYER_ROWS + 1
    for row = 1, PLAYER_ROWS do
        local player = State.players[first + row - 1]
        if player then
            set_text(ui.player_names[row], player.name)
            set_text(ui.player_pings[row], player.is_local and "LOCAL" or (player.ping and string.format("%d ms", player.ping) or "--"))
            set_text(ui.player_statuses[row], player.status)
            local ping_color = COLORS.muted
            if player.is_local or not player.ping or player.ping <= 60 then
                ping_color = COLORS.green
            elseif player.ping <= 120 then
                ping_color = COLORS.amber
            else
                ping_color = COLORS.red
            end
            set_text_color(ui.player_pings[row], ping_color)
            set_text_color(ui.player_statuses[row], player.is_local and COLORS.green or COLORS.muted)
        else
            set_text(ui.player_names[row], "-")
            set_text(ui.player_pings[row], "")
            set_text(ui.player_statuses[row], "")
        end
    end
    set_visibility(ui.hud_border, State.in_game and State.hud_enabled and not State.open)
    set_visibility(ui.hud_text, State.in_game and State.hud_enabled and not State.open)

    local show_radio_display = State.in_game and InternetRadio:is_active()
    local active_station = RADIO_STATIONS[State.station_index]
    set_text(ui.radio_title, "RV RADIO  //  " .. active_station.name)
    set_text(ui.radio_track, InternetRadio:now_playing_text(
        active_station.now_playing or active_station.detail
    ))
    set_visibility(ui.radio_display, show_radio_display)
    set_visibility(ui.radio_title, show_radio_display)
    set_visibility(ui.radio_track, show_radio_display)
end

local select_station

local function discover_tape_players()
    local ok, tape_players = pcall(FindAllOf, "BP_TapePlayer_C")
    if not ok or not tape_players then return end
    for _, tape_player in ipairs(tape_players) do
        local address = is_valid(tape_player) and unreal_address(tape_player) or nil
        local existing = address and State.tape_controls[address] or nil
        if existing and (not is_valid(existing.tape_player)
            or not same_unreal_object(existing.tape_player, tape_player)) then
            State.tape_controls[address] = nil
        end
        if address and not State.tape_controls[address] then
            local controls = {}
            local complete = true
            for _, name in ipairs({
                "PlayButton", "StopButton", "UpVolumeButton", "DownVolumeButton",
                "NextTapeButton", "PreviousTapeButton",
            }) do
                local captured = false
                pcall(function()
                    controls[name] = tape_player[name]
                    captured = is_valid(controls[name])
                end)
                if not captured then complete = false end
            end
            if complete then
                pcall(function()
                    local cassette = tape_player.SM_CassetteTape_Austin_01
                    if is_valid(cassette) then
                        cassette:SetVisibility(false, true)
                        cassette:SetHiddenInGame(true, true)
                    end
                end)
                controls.tape_player = tape_player
                State.tape_controls[address] = controls
                log("Physical RV buttons bound to internet-radio controls")
            end
        end
    end
end

local function register_tape_control_hooks()
    pcall(function()
        LoadAsset("/Game/Ride/Vehicle/Blueprints/BP_TapePlayer")
    end)
    discover_tape_players()
    if State.tape_hooks_attempted then return end
    State.tape_hooks_attempted = true

    local class_path = "/Game/Ride/Vehicle/Blueprints/BP_TapePlayer.BP_TapePlayer_C:"
    local callback = function(context, player_character, hit_result)
        local tape_player = unwrap(context)
        local authority = false
        pcall(function() authority = tape_player:HasAuthority() == true end)
        local controls = State.tape_controls[unreal_address(tape_player)]
        local component = resolve_hit_component(hit_result)
        if not controls or not is_valid(component) then return end

        local control = nil
        if same_unreal_object(component, controls.NextTapeButton) then
            control = "next"
        elseif same_unreal_object(component, controls.PreviousTapeButton) then
            control = "previous"
        elseif same_unreal_object(component, controls.PlayButton) then
            control = "play"
        elseif same_unreal_object(component, controls.StopButton) then
            control = "stop"
        elseif same_unreal_object(component, controls.UpVolumeButton) then
            control = "volume_up"
        elseif same_unreal_object(component, controls.DownVolumeButton) then
            control = "volume_down"
        end
        if not control then return end
        pcall(function()
            tape_player.IsPlaying = false
            tape_player.CurrentTapeIndex = 0
            if is_valid(tape_player.Audio) then tape_player.Audio:Stop() end
        end)

        local character = unwrap(player_character)
        local local_character = nil
        pcall(function()
            local controller = UEHelpers.GetPlayerController()
            if is_valid(controller) then local_character = controller:K2_GetPawn() end
        end)
        if not authority or not same_unreal_object(character, local_character) then return end

        local volume_changed = false
        if control == "next" then
            select_station(State.station_index + 1)
        elseif control == "previous" then
            select_station(State.station_index - 1)
        elseif control == "play" then
            if not InternetRadio:is_active() then InternetRadio:start() end
        elseif control == "stop" then
            if InternetRadio:is_active() then InternetRadio:stop("Stopped at RV radio") end
        elseif control == "volume_up" then
            local volume = InternetRadio:adjust_volume(0.1)
            State.status = string.format("Radio volume %d%%", math.floor(volume * 100 + 0.5))
            volume_changed = true
        elseif control == "volume_down" then
            local volume = InternetRadio:adjust_volume(-0.1)
            State.status = string.format("Radio volume %d%%", math.floor(volume * 100 + 0.5))
            volume_changed = true
        end
        if not volume_changed and (control == "play" or control == "stop") then
            State.status = InternetRadio:status_text()
        end
        refresh_ui()
    end
    local ok, pre_id, post_id = pcall(RegisterHook, class_path .. "Interact", callback)
    if ok then
        table.insert(State.tape_hooks, {
            path = class_path .. "Interact",
            pre = pre_id,
            post = post_id,
        })
        log("Registered physical RV internet-radio controls")
    else
        State.tape_hooks_attempted = false
    end
end

local function adjust_count(delta)
    State.count = math.max(MIN_PLAYERS, math.min(MAX_PLAYERS, State.count + delta))
    State.status = "Ready to apply"
    refresh_ui()
end

local function apply_count()
    local ok, err = ConfigStore.set_max_players(State.config_path, State.count)
    if not ok then
        State.status = "Save failed"
        log("Could not update Game.ini: " .. tostring(err))
        refresh_ui()
        return
    end

    local runtime_updated = update_runtime_cap(State.count)
    State.applied_count = State.count
    State.status = runtime_updated and "Applied to new lobbies" or "Saved; restart before hosting"
    log(string.format("Player cap set to %d", State.count))
    refresh_ui()
end

local function build_ui(player_controller)
    local classes = {
        user_widget = find_class("/Script/UMG.UserWidget"),
        widget_tree = find_class("/Script/UMG.WidgetTree"),
        canvas = find_class("/Script/UMG.CanvasPanel"),
        border = find_class("/Script/UMG.Border"),
        text = find_class("/Script/UMG.TextBlock"),
    }
    local widget_library = find_class("/Script/UMG.Default__WidgetBlueprintLibrary")
    local root = widget_library:Create(player_controller, classes.user_widget, player_controller)
    if not is_valid(root) then
        root = StaticConstructObject(classes.user_widget, player_controller)
    end
    if not is_valid(root) then
        error("Could not create the menu UserWidget")
    end

    local tree = StaticConstructObject(classes.widget_tree, root)
    local canvas = StaticConstructObject(classes.canvas, tree)
    root.WidgetTree = tree
    tree.RootWidget = canvas

    local ui = {
        root = root,
        tree = tree,
        canvas = canvas,
        classes = classes,
        rows = {},
        row_widgets = {},
        row_values = {},
        player_names = {},
        player_pings = {},
        player_statuses = {},
        station_options = {},
        menu_widgets = {},
        game_widgets = {},
        references = { root, tree, canvas, widget_library },
    }

    local panel = create_border(tree, classes, COLORS.panel)
    ui.panel_slot = add_canvas_child(canvas, panel, -500, 24, 470, 450, 1)
    track(ui, panel, true)

    add_label(ui, "RV THERE NOW", -476, 43, 420, 31, COLORS.text, 21, true)
    ui.session_text = add_label(ui, "", -476, 77, 420, 24, COLORS.green, 13, true)
    table.insert(ui.game_widgets, ui.session_text)

    add_row(ui, 1, 108, "PLAYER CAP")
    add_row(ui, 2, 194, "COMPACT HUD")
    add_row(ui, 3, 151, "")
    add_row(ui, 4, 108, "RADIO STATION")
    add_row(ui, 5, 151, "INTERNET RADIO")

    ui.warning_text = add_label(ui, "Host-only setting", -476, 194, 420, 21, COLORS.muted, 12, true)
    ui.status_text = add_label(ui, State.status, -476, 216, 420, 21, COLORS.muted, 12, true)
    table.insert(ui.game_widgets, ui.warning_text)
    table.insert(ui.game_widgets, ui.status_text)

    ui.player_page_text = add_label(ui, "PLAYERS", -476, 243, 420, 22, COLORS.green, 13, true)
    table.insert(ui.game_widgets, ui.player_page_text)
    local name_header = add_left_label(ui, "NAME", -462, 267, 238, 20, COLORS.muted, 11, true)
    local ping_header = add_label(ui, "PING", -220, 267, 76, 20, COLORS.muted, 11, true)
    local state_header = add_label(ui, "STATE", -140, 267, 78, 20, COLORS.muted, 11, true)
    table.insert(ui.game_widgets, name_header)
    table.insert(ui.game_widgets, ping_header)
    table.insert(ui.game_widgets, state_header)
    for row = 1, PLAYER_ROWS do
        local y = 289 + (row - 1) * 20
        ui.player_names[row] = add_left_label(ui, "-", -462, y, 238, 19, COLORS.text, 12, true)
        ui.player_pings[row] = add_label(ui, "", -220, y, 76, 19, COLORS.muted, 11, true)
        ui.player_statuses[row] = add_label(ui, "", -140, y, 78, 19, COLORS.muted, 11, true)
        table.insert(ui.game_widgets, ui.player_names[row])
        table.insert(ui.game_widgets, ui.player_pings[row])
        table.insert(ui.game_widgets, ui.player_statuses[row])
    end

    ui.station_dropdown = create_border(tree, classes, COLORS.surface_alt)
    add_canvas_child(canvas, ui.station_dropdown, -426, 149, 370, 170, 8)
    track(ui, ui.station_dropdown, false)
    for index, station in ipairs(RADIO_STATIONS) do
        local column = math.floor((index - 1) / 6)
        local row = (index - 1) % 6
        local option = create_text(tree, classes, station.name, COLORS.text, 11, 0)
        add_canvas_child(canvas, option, -414 + column * 181, 154 + row * 27, 174, 24, 9)
        track(ui, option, false)
        ui.station_options[index] = option
    end

    ui.radio_display = create_border(tree, classes, COLORS.panel)
    ui.radio_display_slot = add_bottom_right_child(
        canvas, ui.radio_display, -390, -84, 360, 54, 20
    )
    track(ui, ui.radio_display, false)
    ui.radio_title = create_text(tree, classes, "RV RADIO", COLORS.green, 12, 2)
    ui.radio_title_slot = add_bottom_right_child(
        canvas, ui.radio_title, -380, -78, 340, 20, 21
    )
    track(ui, ui.radio_title, false)
    ui.radio_track = create_text(tree, classes, "", COLORS.text, 11, 2)
    ui.radio_track_slot = add_bottom_right_child(
        canvas, ui.radio_track, -380, -55, 340, 19, 21
    )
    track(ui, ui.radio_track, false)

    ui.hud_border = create_border(tree, classes, COLORS.panel)
    add_canvas_child(canvas, ui.hud_border, -306, 24, 276, 42, 1)
    track(ui, ui.hud_border, false)
    ui.hud_text = add_label(ui, "", -296, 33, 256, 24, COLORS.text, 13, false)

    root:AddToViewport(10000)
    -- This is a full-screen overlay, so it must never intercept the game's UI.
    root:SetVisibility(3)
    State.ui = ui
    set_menu_widgets_visible(State.open)
    refresh_ui()
    return ui
end

local function set_menu_open(should_open)
    local player_controller = UEHelpers.GetPlayerController()
    if not is_valid(player_controller) then
        State.status = "Player controller unavailable"
        log(State.status)
        return
    end

    State.player_controller = player_controller
    if not State.ui or not is_valid(State.ui.root) then
        State.ui = nil
        build_ui(player_controller)
    end

    State.open = should_open
    if not should_open then
        State.station_list_open = false
        focus_game_viewport()
    end
    set_menu_widgets_visible(should_open)
    pcall(function()
        player_controller:SetIgnoreLookInput(should_open)
        player_controller:SetIgnoreMoveInput(should_open)
    end)
    refresh_ui()
end

local function toggle_menu()
    if State.ui and not is_valid(State.ui.root) then
        State.ui = nil
        State.open = false
    end
    set_menu_open(not State.open)
end

local function move_selection(delta)
    if not State.open then
        return
    end
    if State.station_list_open then
        State.station_cursor = ((State.station_cursor - 1 + delta) % #RADIO_STATIONS) + 1
        refresh_ui()
        return
    end
    local rows = visible_menu_rows()
    local current = 1
    for index, row in ipairs(rows) do
        if row == State.selected_row then current = index break end
    end
    State.selected_row = rows[((current - 1 + delta) % #rows) + 1]
    refresh_ui()
end

select_station = function(index)
    if InternetRadio:is_active() and not InternetRadio:can_control() then
        State.status = "Only the host can change the RV radio"
        return false
    end
    index = ((index - 1) % #RADIO_STATIONS) + 1
    local restart = InternetRadio:is_active()
    if restart then
        InternetRadio:stop("Station changed")
    end
    local station = RADIO_STATIONS[index]
    local ok, err = InternetRadio:set_url(station.url)
    if not ok then
        State.status = err
        return false
    end
    State.station_index = index
    State.station_cursor = index
    local saved, save_err = false, "radio config path unavailable"
    if State.radio_config_path then
        saved, save_err = ConfigStore.set_radio_url(State.radio_config_path, station.url)
    end
    State.status = saved and (station.name .. " selected") or "Station save failed"
    if not saved then log("Could not save radio station: " .. tostring(save_err)) end
    if restart then
        local started, start_err = InternetRadio:start()
        if not started then
            State.status = start_err or InternetRadio:status_text()
            return false
        end
        State.status = station.name .. " syncing"
    end
    return true
end

local function change_selected(delta)
    if not State.open or State.station_list_open then
        return
    end
    if State.selected_row == 1 then
        adjust_count(delta)
    elseif State.selected_row == 2 then
        State.hud_enabled = not State.hud_enabled
        State.status = State.hud_enabled and "Compact HUD enabled" or "Compact HUD disabled"
        refresh_ui()
    elseif State.selected_row == 4 then
        select_station(State.station_index + delta)
        refresh_ui()
    end
end

local function activate_selected()
    if not State.open then
        return
    end
    if State.station_list_open then
        select_station(State.station_cursor)
        State.station_list_open = false
        refresh_ui()
        return
    end
    if State.selected_row == 1 or State.selected_row == 3 then
        apply_count()
    elseif State.selected_row == 2 then
        State.hud_enabled = not State.hud_enabled
        State.status = State.hud_enabled and "Compact HUD enabled" or "Compact HUD disabled"
        refresh_ui()
    elseif State.selected_row == 4 then
        State.station_cursor = State.station_index
        State.station_list_open = true
        State.status = "Choose a radio station"
        refresh_ui()
    elseif State.selected_row == 5 then
        InternetRadio:toggle()
        State.status = InternetRadio:status_text()
        refresh_ui()
    end
end

local function bind_key(key, callback, always_consume)
    local ok, err = pcall(function()
        RegisterKeyBind(key, function()
            local consume = always_consume or State.open
            run_on_game_thread(callback)
            return consume
        end)
    end)
    if not ok then
        log("Could not register key: " .. tostring(err))
    end
end

State.config_path = ConfigStore.default_path()
State.radio_config_path = ConfigStore.default_radio_path()
if State.config_path then
    State.count = math.max(MIN_PLAYERS, math.min(MAX_PLAYERS, ConfigStore.read_max_players(State.config_path)))
    State.applied_count = State.count
else
    State.status = "Game.ini path unavailable"
end
if State.radio_config_path then
    local saved_radio_url = ConfigStore.read_radio_url(State.radio_config_path)
    if saved_radio_url then
        for index, station in ipairs(RADIO_STATIONS) do
            if station.url == saved_radio_url then
                State.station_index = index
                State.station_cursor = index
                break
            end
        end
    end
end
InternetRadio:set_url(RADIO_STATIONS[State.station_index].url)

bind_key(Key.F6, toggle_menu, true)
bind_key(Key.F7, function()
    if State.station_list_open then
        return
    end
    if not State.in_game then
        return
    end
    InternetRadio:toggle()
    State.status = InternetRadio:status_text()
    refresh_ui()
end, true)
bind_key(Key.ESCAPE, function()
    if State.station_list_open then
        State.station_list_open = false
        State.station_cursor = State.station_index
        State.status = "Station selection cancelled"
        refresh_ui()
    elseif State.open then
        set_menu_open(false)
    end
end)
bind_key(Key.UP_ARROW, function()
    move_selection(-1)
end)
bind_key(Key.DOWN_ARROW, function()
    move_selection(1)
end)
bind_key(Key.LEFT_ARROW, function()
    change_selected(-1)
end)
bind_key(Key.RIGHT_ARROW, function()
    change_selected(1)
end)
bind_key(Key.RETURN, activate_selected)
bind_key(Key.PAGE_UP, function()
    if State.open and not State.station_list_open then
        State.player_page = math.max(1, State.player_page - 1)
        refresh_ui()
    end
end)
bind_key(Key.PAGE_DOWN, function()
    if State.open and not State.station_list_open then
        local pages = math.max(1, math.ceil(#State.players / PLAYER_ROWS))
        State.player_page = math.min(pages, State.player_page + 1)
        refresh_ui()
    end
end)

pcall(function()
    LoopInGameThreadWithDelay(1000, function()
        InternetRadio:poll_sync()
        if State.ui and is_valid(State.ui.root) then
            refresh_ui()
        elseif InternetRadio:is_active() then
            InternetRadio:update()
        end
    end)
end)

pcall(function()
    LoopInGameThreadWithDelay(25, function()
        InternetRadio:maintain_audio()
    end)
end)

pcall(function()
    LoopInGameThreadWithDelay(1000, register_tape_control_hooks)
end)

log(string.format("v%s loaded; F6 opens the menu and F7 toggles the radio test", MOD_VERSION))
