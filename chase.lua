--[[
chase.lua 1.2.0 -- aquietone

https://www.redguides.com/community/resources/chase.2392/
https://github.com/aquietone/luachase

Commands:
- /luachase pause on|1|true -- pause chasing
- /luachase pause off|0|false -- resume chasing
- /luachase -- resume chasing
- /luachase target -- sets the chase to your current target, if it is a valid PC target
- /luachase name somedude -- sets the chase target to somedude
- /luachase name|follow -- prints the current chase target
- /luachase role [ma|mt|leader|raid1|raid2|raid3] -- chase the PC with the specified role
- /luachase role -- displays the role to chase
- /luachase distance 30 -- sets the chase distance to 30
- /luachase distance -- prints the current chase distance
- /luachase stopdistance 10 -- sets the stop distance to 10 (nav dist=# parameter)
- /luachase stopdistance -- prints the current stop distance
- /luachase pause on|1|true -- pauses the current chase, but remembers your chase target
- /luachase off|stop|end|0|false -- unpauses chase
- /luachase show -- displays the UI window
- /luachase hide -- hides the UI window
- /luachase [help] -- displays the help output

/multiline ; /lua stop chase;/timed 20 /lua run chase
    
TLO:
${Chase}
${Chase.Paused} -- bool, whether we're paused
${Chase.Following} -- bool, whether it's stopped or started
${Chase.Role} -- the role we're chasing if name isn't specified
${Chase.ChaseDistance} -- how far away before starting to follow
${Chase.StopDistance} -- how close to stop following
${Chase.Target} -- Name of person specified to chase. Will be empty while following a role

The following were added to provide feature parity with /afollow to make it easier to drop into macros as a replacement
${Chase.Active} -- always true if the script is running
${Chase.State} -- 1 or 0 equivalent to ${Chase.Following}
${Chase.Status} -- 0 = stopped, 1 = following, 2 = Paused
${Chase.Monitor} -- the spawn we're following
${Chase.Idle} -- tick count we've been idle for
${Chase.Length} -- estimated path length to reach chase target
]]--

local mq = require('mq')
require('ImGui')

local Settings = { CHASE = '', ROLE = 'none', DISTANCE = 30, STOP_DISTANCE = 10, open_gui = true, MAX_AFOLLOW_DISTANCE = 100 }

local RUNNING = false
local PAUSED = false

-- name of config file in config folder
local configPath = 'chase/chase_' .. mq.TLO.EverQuest.Server() .. '_' .. mq.TLO.Me.CleanName() .. '.lua'
local PREFIX = '\aw[\agCHASE\aw] \ay'
local ROLES = {[1]='none',none=1,[2]='ma',ma=1,[3]='mt',mt=1,[4]='leader',leader=1,[5]='raid1',raid1=1,[6]='raid2',raid2=1,[7]='raid3',raid3=1}
local IDLE = 0
local should_draw_gui = true


local function LoadConfig()

    local loadedSettings = { }
    -- attempt to read the config file
    local configData, err = loadfile(mq.configDir..'/'..configPath)
    if err then
        -- failed to read the config file, create it using pickle
        mq.pickle(configPath, Settings)
    elseif configData then
        -- file loaded, put content into your config table
        loadedSettings = configData()
        for k,v in pairs(loadedSettings) do Settings[k] = v end
    end
end

local function SaveConfig()
    mq.pickle(configPath, Settings)
end

LoadConfig()

local function get_spawn_for_role()
    local spawn = nil
    if Settings.ROLE == 'none' then
        spawn = mq.TLO.Spawn('pc ='..Settings.CHASE)
    elseif Settings.ROLE == 'ma' then
        spawn = mq.TLO.Group.MainAssist
    elseif Settings.ROLE == 'mt' then
        spawn = mq.TLO.Group.MainTank
    elseif Settings.ROLE == 'leader' then
        spawn = mq.TLO.Group.Leader
    elseif Settings.ROLE == 'raid1' then
        spawn = mq.TLO.Raid.MainAssist(1)
    elseif Settings.ROLE == 'raid2' then
        spawn = mq.TLO.Raid.MainAssist(2)
    elseif Settings.ROLE == 'raid3' then
        spawn = mq.TLO.Raid.MainAssist(3)
    end
    return spawn
end


local function init_tlo()
    local ChaseType

    local function ChaseTLO(index)
        return ChaseType, {}
    end

    local tlomembers = {
        Active = function() return 'bool', true end,
        Following = function() return 'bool', RUNNING end,
        Paused = function() return 'bool', PAUSED end,
        State = function() 
            if RUNNING then 
                return 'int', 1
            else
                return 'int', 0
            end
        end,
        Status = function() 
            if RUNNING then 
                if PAUSED then 
                    return 'int', 2
                else
                    return 'int', 1
                end
            else
                return 'int', 0
            end
        end,
        Monitor = function() 
            if Settings.ROLE == 'none' and Settings.CHASE == '' then return 'spawn', nil end
            return 'MQSpawn', get_spawn_for_role()
        end,
        Role = function() return 'string', Settings.ROLE end,
        Target = function() return 'string', Settings.CHASE end,
        ChaseDistance = function() return 'int', Settings.DISTANCE end,
        StopDistance = function() return 'int', Settings.STOP_DISTANCE end,
        Idle = function() return 'int', IDLE end,
        Length = function() 
            if Settings.ROLE == 'none' and Settings.CHASE == '' then return 'float', -1 end
            
            local chase_spawn = get_spawn_for_role()
            
            if mq.TLO.Nav.Active() and mq.TLO.Navigation.PathExists(string.format('spawn pc =%s', chase_spawn.CleanName())) then
                return 'float', mq.TLO.Navigation.PathLength(string.format('spawn pc =%s', chase_spawn.CleanName()))
            end
            
            return 'float', -1
        end,
        
    }

    ChaseType = mq.DataType.new('ChaseType', {
        Members = tlomembers
    })
    function ChaseType.ToString()
        return ('Chase Running = %s'):format((not PAUSED) and RUNNING)
    end

    mq.AddTopLevelObject('Chase', ChaseTLO)
end

local function validate_distance(distance)
    if distance >= 5 and distance <= 300 then
        if distance < Settings.STOP_DISTANCE then
            Settings.STOP_DISTANCE = distance / 2
        end
        return true
    else
        return false
    end
end

local function validate_max_afollow_distance(distance)
    return distance >= 1
end

local function validate_stop_distance(distance)
    return distance >= 1 and distance <= 300
end

local function check_distance(x1, y1, x2, y2)
    return (x2 - x1) ^ 2 + (y2 - y1) ^ 2
end

local function validate_chase_role(role)
    return ROLES[role] ~= nil
end

local function do_chase()
    if mq.TLO.Me.Moving() then 
        IDLE = 0 
    end
    if PAUSED then return end
    if not RUNNING then return end
    
    if not mq.TLO.Me.Moving() then 
        IDLE = IDLE + 1
    end
    
    if mq.TLO.Me.Hovering() or mq.TLO.Me.AutoFire() or mq.TLO.Me.Combat() or (mq.TLO.Me.Casting() and mq.TLO.Me.Class.ShortName() ~= 'BRD') or mq.TLO.Stick.Active() then return end
    local chase_spawn = get_spawn_for_role()
    local me_x = mq.TLO.Me.X()
    local me_y = mq.TLO.Me.Y()
    local chase_x = chase_spawn.X()
    local chase_y = chase_spawn.Y()
    if not chase_x or not chase_y then return end
    if check_distance(me_x, me_y, chase_x, chase_y) > Settings.DISTANCE^2 then
        if not mq.TLO.Nav.Active() then
            if mq.TLO.Navigation.PathExists(string.format('spawn pc =%s', chase_spawn.CleanName()))() then
                
                if mq.TLO.AdvPath.Following() then
                    mq.cmdf('/squelch /afollow off')
                end
                
                mq.cmdf('/squelch /nav spawn pc =%s | dist=%s log=off', chase_spawn.CleanName(), Settings.STOP_DISTANCE)
            else
                if not mq.TLO.AdvPath.Following() and check_distance(me_x, me_y, chase_x, chase_y) < Settings.MAX_AFOLLOW_DISTANCE^2 then
                    mq.cmdf('/squelch /afollow spawn %s', chase_spawn.ID())
                end
            end
        end
    end
end

local function helpMarker(desc)
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
        ImGui.Text(desc)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

local function draw_combo_box(resultvar, options)
    if ImGui.BeginCombo('Chase Role', resultvar) then
        for _,j in ipairs(options) do
            if ImGui.Selectable(j, j == resultvar) then
                resultvar = j
            end
        end
        ImGui.EndCombo()
    end
    helpMarker('Assign the group or raid role to chase')
    return resultvar
end

local function chase_ui()
    if not Settings.open_gui or mq.TLO.MacroQuest.GameState() ~= 'INGAME' then return end
    
    local old_open_gui = Settings.open_gui
    Settings.open_gui, should_draw_gui = ImGui.Begin('Chase', Settings.open_gui)

    if old_open_gui ~= Settings.open_gui then
        SaveConfig()
    end
    
    if should_draw_gui then

        if RUNNING then
            if ImGui.Button('Stop Following') then
                RUNNING = false
                PAUSED = false
                mq.cmd('/squelch /nav stop')
            end
        else
            ImGui.BeginDisabled(Settings.ROLE == 'none' and Settings.CHASE == '')
            if ImGui.Button('Start Following') then
                if Settings.ROLE ~= 'none' or Settings.CHASE ~= '' then
                    RUNNING = true
                    PAUSED = false
                end
            end
            ImGui.EndDisabled()
        end
        
        helpMarker('Start or stop chasing')
    
        ImGui.BeginDisabled(not RUNNING)
        
        if PAUSED then
            if ImGui.Button('Resume') then
                PAUSED = false
            end
        else
            if ImGui.Button('Pause') then
                PAUSED = true
                mq.cmd('/squelch /nav stop')
            end
        end
        
        ImGui.EndDisabled()
    
        helpMarker('Pause or resume chasing')
        
        
        ImGui.PushItemWidth(100)
        
        
        local oldrole = Settings.ROLE
        Settings.ROLE = draw_combo_box(Settings.ROLE, ROLES)
        if oldrole ~= Settings.ROLE then
            RUNNING = true
            PAUSED = true
            SaveConfig()
        end
        
        local oldCHASE = Settings.CHASE
        if Settings.ROLE == 'none' then
            Settings.CHASE = ImGui.InputText('Chase Target', Settings.CHASE)
            if oldCHASE ~= Settings.CHASE then
                RUNNING = true
                PAUSED = true
                SaveConfig()
            end
            helpMarker('Assign the PC spawn name to chase')
        end
        
        local oldDISTANCE = Settings.DISTANCE
        local tmp_distance = ImGui.InputInt('Chase Distance', Settings.DISTANCE)
        helpMarker('Set the distance to begin chasing at. Min=15, Max=300')
        if validate_distance(tmp_distance) and oldDISTANCE ~= tmp_distance then
            Settings.DISTANCE = tmp_distance
            SaveConfig()
        end
        
        local oldSTOP_DISTANCE = Settings.STOP_DISTANCE
        tmp_distance = ImGui.InputInt('Stop Distance', Settings.STOP_DISTANCE)
        helpMarker('Set the distance to stop chasing at. Min=0, Max='..(Settings.DISTANCE-1))
        if validate_stop_distance(tmp_distance) and oldSTOP_DISTANCE ~= tmp_distance  then
            Settings.STOP_DISTANCE = tmp_distance
            SaveConfig()
        end
        
        local oldMAX_AFOLLOW_DISTANCE = Settings.MAX_AFOLLOW_DISTANCE
        tmp_distance = ImGui.InputInt('Maximum afollow Distance', Settings.MAX_AFOLLOW_DISTANCE)
        helpMarker('Set the maximum distance to use afollow as a fallback. Min=0')
        ImGui.PopItemWidth()
        if validate_max_afollow_distance(tmp_distance) and oldMAX_AFOLLOW_DISTANCE ~= tmp_distance  then
            Settings.MAX_AFOLLOW_DISTANCE = tmp_distance
            SaveConfig()
        end
    end
    ImGui.End()
end
mq.imgui.init('Chase', chase_ui)

local function print_help()
    print('\ayLua Chase 1.0 -- \awAvailable Commands:')
    print('\ay\t/luachase role ma|mt|leader|raid1|raid2|raid3')
    print('\ay\t/luachase target')
    print('\ay\t/luachase name|follow [pc_name_to_chase]')
    print('\ay\t/luachase spawn [pc_id_to_chase]')
    print('\ay\t/luachase distance [10,300]')
    print('\ay\t/luachase stopdistance [0,chase_distance-1]')
    print('\ay\t/luachase afollowdistance [number]')
    print('\ay\t/luachase pause on|1|true')
    print('\ay\t/luachase pause off|0|false')
    print('\ay\t/luachase unpause')
    print('\ay\t/luachase on|start|1|true')
    print('\ay\t/luachase off|stop|end|0|false')
    print('\ay\t/luachase show')
    print('\ay\t/luachase hide')
end

local function bind_chase(...)
    local args = {...}
    local key = args[1]
    local value = args[2]
    if not key or key == 'help' then
        print_help()
    elseif key == 'target' then
        if not mq.TLO.Target() or mq.TLO.Target.Type() ~= 'PC' then
            return
        end
        Settings.CHASE = mq.TLO.Target.CleanName()
        Settings.ROLE = 'none'
        RUNNING = true
        PAUSED = false
        SaveConfig()
    elseif key == 'spawn' then
        local tmpSpawn = mq.TLO.Spawn('id '..value)
        if not tmpSpawn.ID() or tmpSpawn.Type() ~= 'PC'  then
            printf('%sSpawn with ID %s not found', PREFIX, value)
            return
        end
        Settings.CHASE = tmpSpawn.CleanName()
        Settings.ROLE = 'none'
        RUNNING = true
        PAUSED = false
        SaveConfig()
    elseif key == 'name' or key == 'follow' then
        if value then
            Settings.CHASE = value
            Settings.ROLE = 'none'
            RUNNING = true
            PAUSED = false
            SaveConfig()
        else
            if not RUNNING then 
                printf('%sNo chase target', PREFIX)
            else
                printf('%sChase Target: \aw%s', PREFIX, Settings.CHASE)
            end
        end
    elseif key == 'role' then
        if value and validate_chase_role(value) then
            Settings.ROLE = value
            RUNNING = true
            PAUSED = false
            SaveConfig()
        else
            if not RUNNING then 
                printf('%sNo chase target', PREFIX)
            else
                printf('%sChase Role: \aw%s', PREFIX, Settings.ROLE)
            end
        end
    elseif key == 'distance' then
        if tonumber(value) then
            local tmp_distance = tonumber(value)
            if validate_distance(tmp_distance) then
                Settings.DISTANCE = tmp_distance
                SaveConfig()
            end
        else
            printf('%sChase Distance: \aw%s', PREFIX, Settings.DISTANCE)
        end
    elseif key == 'stopdistance' then
        if tonumber(value) then
            local tmp_distance = tonumber(value)
            if validate_stop_distance(tmp_distance) then
                Settings.STOP_DISTANCE = tmp_distance
                SaveConfig()
            end
        else
            printf('%sStop Distance: \aw%s', PREFIX, Settings.STOP_DISTANCE)
        end
    elseif key == 'afollowdistance' then
        if tonumber(value) then
            local tmp_distance = tonumber(value)
            if validate_max_afollow_distance(tmp_distance) then
                Settings.MAX_AFOLLOW_DISTANCE = tmp_distance
                SaveConfig()
            end
        else
            printf('%sMax afollow Distance: \aw%s', PREFIX, Settings.MAX_AFOLLOW_DISTANCE)
        end
    elseif key == 'pause' then
        if not RUNNING then
            printf('%sNo chase target', PREFIX)
        else
            if value == 'on' or value == '1' or value == 'true' then
                PAUSED = true
                mq.cmd('/squelch /nav stop')
            elseif value == 'off' or value == '0' or value == 'false' then
                PAUSED = false
            else
                PAUSED = true
            end
        end
    elseif key == 'unpause' then
        if not RUNNING then
            printf('%sNo chase target', PREFIX)
        else
            PAUSED = false
        end
    elseif key == 'on' or key == 'start' or key == '1' or key == 'true' then
        if Settings.ROLE ~= 'none' or Settings.CHASE ~= '' then
            RUNNING = true
            PAUSED = false
        end
    elseif key == 'off' or key == 'stop' or key == 'end' or key == '0' or key == 'false' then
        RUNNING = false
        PAUSED = false
        mq.cmd('/squelch /nav stop')
    elseif key == 'show' then
        Settings.open_gui = true
        SaveConfig()
    elseif key == 'hide' then
        Settings.open_gui = false
        SaveConfig()
    else
        print_help()
    end
end


mq.bind('/luachase', bind_chase)
init_tlo()

local args = {...}
if args[1] then
    if validate_chase_role(args[1]) then
        Settings.ROLE = args[1]
        SaveConfig()
    else
        Settings.CHASE=args[1]
        SaveConfig()
    end
end

while true do
    if mq.TLO.MacroQuest.GameState() == 'INGAME' then
        do_chase()
    end
    mq.delay(50)
end
