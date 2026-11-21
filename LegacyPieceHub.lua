-- LEGACY PIECE HUB
-- Built with LinoriaLib (from your example.lua)
-- Uses server-authorized remotes only.

local repo = 'https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/'

local Library = loadstring(game:HttpGet(repo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(repo .. 'addons/ThemeManager.lua'))()
local SaveManager = loadstring(game:HttpGet(repo .. 'addons/SaveManager.lua'))()

-- ============ SERVICES ============
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")

-- ============ CONFIG ============
local HUB_VERSION = "v1.0.0"
local STAT_ORDER = {"STYLE", "DEFENSE", "WEAPON", "ABILITY"}
local STAT_DATA_KEYS = {STYLE = 0, DEFENSE = 1, WEAPON = 2, ABILITY = 3}
local STAT_LABELS = {STYLE = "STYLE", DEFENSE = "DEFENSE", WEAPON = "WEAPON", ABILITY = "ABILITY"}

-- ============ REMOTES ============
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RF_GetNPCData = Remotes:WaitForChild("Functions"):WaitForChild("GetNPCData")
local RF_SkillTreeGetState = Remotes:WaitForChild("RF_SkillTreeGetState")
local RF_SkillTreeUnlock = Remotes:WaitForChild("RF_SkillTreeUnlock")
local RF_ContractAccept = Remotes:WaitForChild("RF_ContractAccept")
local RF_ContractClaim = Remotes:WaitForChild("RF_ContractClaim")
local RF_ContractGetState = Remotes:WaitForChild("RF_ContractGetState")
local RF_ContractAbandon = Remotes:WaitForChild("RF_ContractAbandon")
local RE_TeleportToPortal = Remotes:WaitForChild("TeleportToPortal")
local RE_TeleportToIslandSpot = Remotes:WaitForChild("TeleportToIslandSpot")

-- ============ STATE ============
local HubState = {
    Enabled = true,
    Visible = true,
    Scale = 1,
    Transparency = 0.05,
    CurrentTab = "AutoFarm",
    SelectedStat = "STYLE",
    SelectedQuest = nil,
    AvailableQuests = {},
    AutoStatsEnabled = false,
    AutoFarmEnabled = false,
    AutoFarmMode = "Select Quest", -- "Select Quest" or "To Max"
    FarmPositionMethod = "Above", -- "Above" or "Behind"
    UseM1Attack = true,
    Islands = {},
    NPCs = {},
    FarmThread = nil,
    QuestTIER_ORDER = {Mythic = 4, Legendary = 3, Rare = 2, Common = 1},
    AutoRepeatQuest = false,
}

-- ============ UTILITIES ============
local function GetCharacter()
    return Player.Character or Player.CharacterAdded:Wait()
end

local function GetRootPart()
    local char = GetCharacter()
    if char then return char:FindFirstChild("HumanoidRootPart") end
    return nil
end

local function TeleportTo(position)
    local root = GetRootPart()
    if root and position then
        root.CFrame = CFrame.new(position[1], position[2], position[3])
        return true
    end
    return false
end

-- ============ TELEPORTER LOGIC (cross-island) ============
local TELEPORTER_NAMES = {
    "The Gatekeeper", "Eclipse Championship", "Prestige Overseer",
    "The Wuthering Smith", "Trainer", "Enel", "Rob Lucci", "Rayleigh"
}

local function FindNearestTeleporter()
    local root = GetRootPart()
    if not root then return nil end
    local best, bestDist = nil, math.huge
    for name, info in pairs(HubState.NPCs) do
        if type(info) == "table" and info.Position then
            local lower = name:lower()
            for _, tn in ipairs(TELEPORTER_NAMES) do
                if lower:find(tn:lower(), 1, true) then
                    local pos = Vector3.new(info.Position[1], info.Position[2], info.Position[3])
                    local dist = (root.Position - pos).Magnitude
                    if dist < bestDist then
                        bestDist = dist
                        best = {Name = name, Position = info.Position}
                    end
                end
            end
        end
    end
    return best
end

-- Teleport using the game's teleporter portal remote (cross-island)
local function TeleportViaTeleporter(targetIslandName)
    local teleporter = FindNearestTeleporter()
    if not teleporter then
        Library:Notify('No teleporter NPC found nearby.', 3)
        return false
    end
    -- Walk to the teleporter first
    local root = GetRootPart()
    if root and teleporter.Position then
        local pos = Vector3.new(teleporter.Position[1], teleporter.Position[2], teleporter.Position[3])
        local dist = (root.Position - pos).Magnitude
        if dist > 8 then
            root.CFrame = CFrame.new(pos)
            task.wait(0.5)
        end
    end
    -- Fire the teleporter remote with the target island
    local ok, err = pcall(function()
        RE_TeleportToPortal:FireServer(targetIslandName)
    end)
    if ok then
        Library:Notify('Teleporting to ' .. targetIslandName .. ' via ' .. teleporter.Name, 3)
        task.wait(1.5)
        return true
    else
        Library:Notify('Teleporter failed: ' .. tostring(err), 3)
        return false
    end
end

-- ============ MOVEMENT SYSTEM (Heartbeat-based CFrame steering) ============
local RunService = game:GetService("RunService")

local Movement = {
    Target = nil,
    Method = "Above",
    Speed = 60,
    Active = false,
    PlatformStandBackup = false,
}

local MovementConnection = nil

local function StartMovement(targetPosition, method)
    Movement.Target = targetPosition
    Movement.Method = method or "Above"
    Movement.Active = true

    local char = GetCharacter()
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if humanoid then
        Movement.PlatformStandBackup = humanoid.PlatformStand
        humanoid.PlatformStand = true
    end

    if MovementConnection then
        MovementConnection:Disconnect()
    end
    MovementConnection = RunService.Heartbeat:Connect(function(dt)
        if not Movement.Active then return end
        if not Movement.Target then return end

        local root = GetRootPart()
        local humanoid2 = GetCharacter() and GetCharacter():FindFirstChildOfClass("Humanoid")
        if not root or not humanoid2 then return end

        root.AssemblyLinearVelocity = Vector3.zero

        local offsetPos = GetOffsetPosition(Movement.Target, Movement.Method)
        local flat = (offsetPos - root.Position)
        flat = Vector3.new(flat.X, 0, flat.Z)
        local dist = flat.Magnitude

        if dist <= 4 then
            Movement.Active = false
            Movement.Target = nil
            if MovementConnection then
                MovementConnection:Disconnect()
                MovementConnection = nil
            end
            humanoid2.PlatformStand = Movement.PlatformStandBackup
            return
        end

        local step = math.min(Movement.Speed * dt, dist)
        local flatUnit = flat.Unit
        local dy = offsetPos.Y - root.Position.Y
        local newPos = root.Position + flatUnit * step + Vector3.new(0, dy, 0)
        root.CFrame = CFrame.new(newPos)
    end)
end

local function StopMovement()
    Movement.Active = false
    Movement.Target = nil
    if MovementConnection then
        MovementConnection:Disconnect()
        MovementConnection = nil
    end
    local char = GetCharacter()
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid.PlatformStand = Movement.PlatformStandBackup
    end
end

local function SmartMove(targetPosition, targetName, method)
    local root = GetRootPart()
    if not root or not targetPosition then return false end
    local targetPos = Vector3.new(targetPosition[1], targetPosition[2], targetPosition[3])
    local dist = (root.Position - targetPos).Magnitude

    -- If cross-island (>3000 studs), use teleporter
    if dist > 3000 then
        local teleporter = FindNearestTeleporter()
        if not teleporter then
            Library:Notify('No teleporter NPC found nearby.', 3)
            return false
        end
        local tpPos = Vector3.new(teleporter.Position[1], teleporter.Position[2], teleporter.Position[3])
        local tpDist = (root.Position - tpPos).Magnitude

        -- Walk to the teleporter first (must stand near it to use)
        if tpDist > 8 then
            Library:Notify('Walking to teleporter: ' .. teleporter.Name, 3)
            StartMovement(tpPos, method)
            local startTime = tick()
            while tick() - startTime < 15 do
                if not HubState.AutoFarmEnabled then
                    StopMovement()
                    return false
                end
                if (GetRootPart().Position - tpPos).Magnitude <= 8 then
                    break
                end
                task.wait(0.1)
            end
            StopMovement()
        end

        -- Fire the ingame teleporter remote
        local tok, terr = pcall(function()
            RE_TeleportToPortal:FireServer(targetName or "Unknown")
        end)
        if tok then
            Library:Notify('Teleporting via ingame teleporter to ' .. (targetName or "Unknown"), 3)
            task.wait(2.5)
            return true
        else
            Library:Notify('Teleporter failed: ' .. tostring(terr), 3)
            return false
        end
    end

    -- Otherwise walk to target using Heartbeat CFrame steering
    StartMovement(targetPos, method or "Above")
    local startTime = tick()
    while tick() - startTime < 15 do
        if not HubState.AutoFarmEnabled then
            StopMovement()
            return false
        end
        if (GetRootPart().Position - targetPos).Magnitude <= 6 then
            StopMovement()
            return true
        end
        task.wait(0.1)
    end
    StopMovement()
    return false
end

-- Smart teleport: direct CFrame if close, teleporter remote if cross-island
local function SmartTeleport(targetPosition, targetName)
    local root = GetRootPart()
    if not root or not targetPosition then return false end
    local targetPos = Vector3.new(targetPosition[1], targetPosition[2], targetPosition[3])
    local dist = (root.Position - targetPos).Magnitude
    if dist > 3000 then
        return TeleportViaTeleporter(targetName or "Unknown")
    end
    root.CFrame = CFrame.new(targetPos)
    return true
end

-- Teleport using the game's teleporter portal remote (cross-island)
local function TeleportViaTeleporter(targetIslandName)
    local teleporter = FindNearestTeleporter()
    if not teleporter then
        Library:Notify('No teleporter NPC found nearby.', 3)
        return false
    end
    -- Walk to the teleporter first using Heartbeat movement
    local root = GetRootPart()
    if root and teleporter.Position then
        local pos = Vector3.new(teleporter.Position[1], teleporter.Position[2], teleporter.Position[3])
        local dist = (root.Position - pos).Magnitude
        if dist > 8 then
            StartMovement(pos, "Above")
            local startTime = tick()
            while tick() - startTime < 10 do
                if (GetRootPart().Position - pos).Magnitude <= 8 then break end
                task.wait(0.1)
            end
            StopMovement()
        end
    end
    -- Fire the teleporter remote with the target island
    local ok, err = pcall(function()
        RE_TeleportToPortal:FireServer(targetIslandName)
    end)
    if ok then
        Library:Notify('Teleporting to ' .. targetIslandName .. ' via ' .. teleporter.Name, 3)
        task.wait(1.5)
        return true
    else
        Library:Notify('Teleporter failed: ' .. tostring(err), 3)
        return false
    end
end

local function GetPlayerData()
    local dataFolder = Player:FindFirstChild("Data")
    if not dataFolder then return nil end
    local out = {}
    for _, v in ipairs(dataFolder:GetChildren()) do
        if v:IsA("ValueBase") then
            out[v.Name] = v.Value
        end
    end
    return out
end

local function GetStatPoints()
    local data = GetPlayerData()
    if data and data.Points then return tonumber(data.Points) or 0 end
    return 0
end

local function GetLevel()
    local data = GetPlayerData()
    if data and data.Level then return tonumber(data.Level) or 1 end
    return 1
end

local function GetOffsetPosition(basePos, method)
    local x, y, z
    if typeof(basePos) == "Vector3" then
        x, y, z = basePos.X, basePos.Y, basePos.Z
    else
        x, y, z = basePos[1], basePos[2], basePos[3]
    end
    if method == "Above" then
        return Vector3.new(x, y + 12, z)
    elseif method == "Behind" then
        return Vector3.new(x, y, z + 12)
    end
    return Vector3.new(x, y + 12, z)
end

local function DoM1Attack()
    local vim = VirtualInputManager
    vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
    task.wait(0.05)
    vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
end

local function FindQuestNPCs(questName)
    local results = {}
    for name, info in pairs(HubState.NPCs) do
        if type(info) == "table" and info.Position and name:lower():find(questName:lower(), 1, true) then
            table.insert(results, {Name = name, Position = info.Position})
        end
    end
    return results
end

-- ============ WINDOW ============
local Window = Library:CreateWindow({
    Title = 'LEGACY PIECE HUB  ' .. HUB_VERSION,
    Center = true,
    AutoShow = true,
    TabPadding = 8,
    MenuFadeTime = 0.2
})

local Tabs = {
    AutoFarm = Window:AddTab('Auto Farm'),
    AutoStats = Window:AddTab('Auto Stats'),
    IslandTP = Window:AddTab('Island Teleports'),
    NPCTP = Window:AddTab('NPC Teleports'),
    Settings = Window:AddTab('Settings'),
}

-- ============ AUTO FARM TAB ============
local AFLeft = Tabs.AutoFarm:AddLeftGroupbox('Auto Farm')
local AFRight = Tabs.AutoFarm:AddRightGroupbox('Farm Info')

-- Mode dropdown
local modeDropdown = AFLeft:AddDropdown('FarmModeDropdown', {
    Values = {"Select Quest", "To Max"},
    Default = 1,
    Multi = false,
    Text = 'Farm Mode',
    Tooltip = 'Select farming mode',
    Callback = function(Value)
        HubState.AutoFarmMode = Value
        ModeStatusLabel:SetText('Mode: ' .. Value)
        if Value == "To Max" then
            questDropdown:SetValues({})
            questDropdown:SetValue("")
            HubState.SelectedQuest = nil
        else
            RefreshQuestDropdown()
        end
    end
})

-- Quest dropdown
local questDropdown = AFLeft:AddDropdown('QuestDropdown', {
    Values = {},
    Default = 1,
    Multi = false,
    Text = 'Select Quest',
    Tooltip = 'Choose a quest to farm',
    Callback = function(Value)
        HubState.SelectedQuest = Value
    end
})

-- Position method dropdown
local posDropdown = AFLeft:AddDropdown('PosMethodDropdown', {
    Values = {"Above", "Behind"},
    Default = 1,
    Multi = false,
    Text = 'Position Method',
    Tooltip = 'Where to stand relative to mobs',
    Callback = function(Value)
        HubState.FarmPositionMethod = Value
    end
})

-- Auto Farm toggle (Start/Stop as tickbox, M1 always on when farming)
local AutoFarmToggle = AFLeft:AddToggle('AutoFarmToggle', {
    Text = 'Auto Farm',
    Default = false,
    Tooltip = 'Enable/disable auto farming (M1 attack is automatic)',
    Callback = function(Value)
        HubState.AutoFarmEnabled = Value
        if Value then
            Library:Notify('Auto Farm started: ' .. HubState.AutoFarmMode, 3)
            if HubState.FarmThread then
                Library:Notify('Auto Farm thread already running.', 3)
                return
            end
            HubState.FarmThread = task.spawn(function()
                while HubState.AutoFarmEnabled do
                    local questName = HubState.SelectedQuest
                    local mode = HubState.AutoFarmMode

                    if mode == "Select Quest" then
                        if not questName or questName == "None" then
                            Library:Notify('Please select a quest first.', 3)
                            HubState.AutoFarmEnabled = false
                            AutoFarmToggle:SetValue(false)
                            break
                        end
                        local npcs = FindQuestNPCs(questName)
                        if #npcs > 0 then
                            local target = npcs[math.random(1, #npcs)]
                            local root = GetRootPart()
                            if root and target.Position then
                                local offsetPos = GetOffsetPosition(target.Position, HubState.FarmPositionMethod)
                                local dist = (root.Position - offsetPos).Magnitude
                                if dist > 6 then
                                    SmartMove({offsetPos.X, offsetPos.Y, offsetPos.Z}, target.Name, HubState.FarmPositionMethod)
                                    task.wait(0.5)
                                end
                                DoM1Attack()  -- M1 always on when farming
                            end
                        end
                    elseif mode == "To Max" then
                        local contractState = nil
                        local ok, state = pcall(function() return RF_ContractGetState:InvokeServer() end)
                        if ok and type(state) == "table" then
                            contractState = state
                        end
                        if not contractState then
                            Library:Notify('To Max: failed to get quest state', 3)
                            task.wait(2)
                        else
                            local board = contractState.Board
                            local defs = board and board.Definitions
                            local profile = contractState.Profile
                            local actives = profile and profile.Actives or {}
                            
                            if #actives > 0 then
                                local activeId = actives[1]
                                local alreadyHave = false
                                if defs and #defs > 0 then
                                    for _, d in ipairs(defs) do
                                        if d.TargetId == activeId then alreadyHave = true break end
                                    end
                                end
                                if not HubState.AutoRepeatQuest or not alreadyHave then
                                    local aok, ares = pcall(function() return RF_ContractAbandon:InvokeServer(activeId) end)
                                    if aok and ares and ares.Ok then
                                        Library:Notify('To Max: cancelled active quest ' .. tostring(activeId), 3)
                                    else
                                        Library:Notify('To Max: failed to cancel quest ' .. tostring(activeId), 3)
                                    end
                                    task.wait(1)
                                end
                            end
                            
                            if defs and #defs > 0 then
                                local tierRank = HubState.QuestTIER_ORDER
                                table.sort(defs, function(a, b)
                                    return (tierRank[a.Tier or "Common"] or 0) > (tierRank[b.Tier or "Common"] or 0)
                                end)
                                local targetDef = defs[1]
                                local targetId = targetDef.TargetId
                                
                                local alreadyActive = false
                                for _, a in ipairs(actives) do
                                    if a == targetId then alreadyActive = true break end
                                end
                                
                                if not alreadyActive then
                                    -- Find the quest NPC first, then tween to it
                                    local npcs = FindQuestNPCs(targetId)
                                    if #npcs > 0 then
                                        local tgt = npcs[1]
                                        local root = GetRootPart()
                                        if root and tgt.Position then
                                            local targetPos = Vector3.new(tgt.Position[1], tgt.Position[2], tgt.Position[3])
                                            local dist = (root.Position - targetPos).Magnitude

                                            -- If cross-island (>3000 studs), use teleporter to get close first
                                            if dist > 3000 then
                                                Library:Notify('To Max: quest on different island, using teleporter...', 3)
                                                local teleporter = FindNearestTeleporter()
                                                if teleporter then
                                                    local tpPos = Vector3.new(teleporter.Position[1], teleporter.Position[2], teleporter.Position[3])
                                                    local tpDist = (root.Position - tpPos).Magnitude
                                                    if tpDist > 8 then
                                                        Library:Notify('Walking to teleporter: ' .. teleporter.Name, 3)
                                                        StartMovement(tpPos, HubState.FarmPositionMethod)
                                                        local startTime = tick()
                                                        while tick() - startTime < 10 do
                                                            if (GetRootPart().Position - tpPos).Magnitude <= 8 then break end
                                                            task.wait(0.1)
                                                        end
                                                        StopMovement()
                                                    end
                                                    local tok, terr = pcall(function()
                                                        RE_TeleportToPortal:FireServer(targetId)
                                                    end)
                                                    if tok then
                                                        Library:Notify('To Max: teleporting via ingame teleporter to ' .. targetId, 3)
                                                        task.wait(2.5)
                                                    else
                                                        Library:Notify('To Max: teleporter failed: ' .. tostring(terr), 3)
                                                        task.wait(2)
                                                    end
                                                else
                                                    Library:Notify('To Max: no teleporter found nearby', 3)
                                                    task.wait(2)
                                                end
                                            end

                                            -- Move to the quest NPC using direct CFrame
                                            Library:Notify('To Max: moving to quest NPC...', 3)
                                            SmartMove(targetPos, targetId, HubState.FarmPositionMethod)
                                            task.wait(0.5)

                                            -- Now accept the quest
                                            local aok, ares = pcall(function() return RF_ContractAccept:InvokeServer(targetId) end)
                                            if aok and ares and ares.Ok then
                                                Library:Notify('To Max: accepted quest ' .. targetId .. ' (Tier: ' .. tostring(targetDef.Tier) .. ')', 3)
                                            else
                                                Library:Notify('To Max: failed to accept quest ' .. targetId, 3)
                                                task.wait(2)
                                            end

                                            -- Farm mobs at the quest location
                                            Library:Notify('To Max: farming ' .. targetId .. ' (goal: ' .. (targetDef.KillGoal or 0) .. ')', 3)
                                            local root2 = GetRootPart()
                                            if root2 and tgt.Position then
                                                local mobPos = Vector3.new(tgt.Position[1], tgt.Position[2], tgt.Position[3])
                                                local offsetPos = GetOffsetPosition(mobPos, HubState.FarmPositionMethod)
                                                local dist2 = (root2.Position - offsetPos).Magnitude
                                                if dist2 > 6 then
                                                    SmartMove({mobPos.X, mobPos.Y, mobPos.Z}, targetId, HubState.FarmPositionMethod)
                                                    task.wait(0.5)
                                                end
                                                DoM1Attack()  -- M1 always on when farming
                                            end
                                        end
                                    else
                                        Library:Notify('To Max: no NPC found for quest ' .. targetId, 3)
                                        task.wait(2)
                                    end
                                end
                            else
                                Library:Notify('To Max: no quest definitions available', 3)
                                task.wait(2)
                            end
                        end
                    end

                    task.wait(0.3)
                end
            end)
        else
            HubState.FarmThread = nil
            Library:Notify('Auto Farm stopped.', 3)
        end
    end
})

-- Status labels
local SelectStatusLabel = AFLeft:AddLabel('Status: Stopped | Quest: None')
local ModeStatusLabel = AFLeft:AddLabel('Mode: Select Quest')

-- Right groupbox info
local MaxLevelLabel = AFRight:AddLabel('Level: 0')
local MaxCurrentQuestLabel = AFRight:AddLabel('Current Quest: None')
local MaxNextQuestLabel = AFRight:AddLabel('Next Quest: Auto-detect')
local MaxStatusLabel = AFRight:AddLabel('Status: Stopped')

-- Mode dropdown callback to update visibility/behavior
-- Quest dropdown callback is set via Callback in constructor above

-- Refresh quest dropdown function
local function RefreshQuestDropdown()
    if HubState.AutoFarmMode == "To Max" then return end
    local quests = {}
    for name, info in pairs(HubState.NPCs) do
        if type(info) == "table" and info.Instant == "Quest" then
            table.insert(quests, name)
        end
    end
    table.sort(quests)
    HubState.AvailableQuests = quests
    questDropdown:SetValues(quests)
    if #quests > 0 and not HubState.SelectedQuest then
        HubState.SelectedQuest = quests[1]
        questDropdown:SetValue(quests[1])
    end
end

-- ============ AUTO STATS TAB ============
local ASLeft = Tabs.AutoStats:AddLeftGroupbox('Stat Allocation')

local statButtons = {}
for _, key in ipairs(STAT_ORDER) do
    local btn = ASLeft:AddButton({
        Text = STAT_LABELS[key],
        Func = function()
            HubState.SelectedStat = key
            Library:Notify('Selected stat: ' .. STAT_LABELS[key], 2)
        end,
        DoubleClick = false,
        Tooltip = 'Allocate points to ' .. STAT_LABELS[key],
    })
    statButtons[key] = btn
end

local AutoStatsAmount = ASLeft:AddSlider('AutoStatsAmount', {
    Text = 'Amount to Allocate',
    Default = 1,
    Min = 1,
    Max = 1000,
    Rounding = 0,
    Compact = false,
    Callback = function(Value)
        HubState.AutoStatsAmount = Value
    end
})

local AutoStatsToggle = ASLeft:AddToggle('AutoStatsToggle', {
    Text = 'Auto Stats',
    Default = false,
    Tooltip = 'Automatically allocate stat points to selected category',
    Callback = function(Value)
        HubState.AutoStatsEnabled = Value
        if Value then
            task.spawn(function()
                while HubState.AutoStatsEnabled do
                    local points = GetStatPoints()
                    if points and points > 0 then
                        local key = HubState.SelectedStat
                        local dataKey = STAT_DATA_KEYS[key]
                        local amount = HubState.AutoStatsAmount or 1
                        local toAlloc = math.min(points, amount)
                        for i = 1, toAlloc do
                            local ok, ret = pcall(function()
                                return RF_SkillTreeUnlock:InvokeServer(dataKey)
                            end)
                            if not (ok and ret and ret.Ok) then
                                HubState.AutoStatsEnabled = false
                                AutoStatsToggle:SetValue(false)
                                Library:Notify('Auto Stats: server rejected (BAD_ARGS). Check remote signature.', 5)
                                break
                            end
                            task.wait(0.05)
                        end
                    end
                    task.wait(0.5)
                end
            end)
        end
    end
})

local StatPointsLabel = ASLeft:AddLabel('Stat Points: 0')

-- ============ ISLAND TELEPORTS TAB ============
local ITLeft = Tabs.IslandTP:AddLeftGroupbox('Island Teleports')

local islandDropdown = ITLeft:AddDropdown('IslandDropdown', {
    Values = {},
    Default = 1,
    Multi = false,
    Text = 'Select Island',
    Tooltip = 'Choose an island to teleport to',
    Callback = function(Value)
        HubState.SelectedIsland = Value
    end
})

ITLeft:AddButton({
    Text = 'REFRESH LIST',
    Func = function()
        HubState.Islands = {}
        islandDropdown:SetValues({})
        islandDropdown:SetValue("")
        HubState.SelectedIsland = nil
        Library:Notify('Loading island registry...', 2)
        local ok, npcData = pcall(function() return RF_GetNPCData:InvokeServer() end)
        if ok and type(npcData) == "table" then
            local count = 0
            for name, info in pairs(npcData) do
                -- Only list island destinations (Category == "Featured")
                if type(info) == "table" and info.Position and info.Category == "Featured" then
                    HubState.Islands[name] = {Position = info.Position, Category = info.Category or "Other"}
                    count = count + 1
                end
            end
            local islandNames = {}
            for name, _ in pairs(HubState.Islands) do
                table.insert(islandNames, name)
            end
            table.sort(islandNames)
            islandDropdown:SetValues(islandNames)
            if #islandNames > 0 then
                HubState.SelectedIsland = islandNames[1]
                islandDropdown:SetValue(islandNames[1])
            end
            Library:Notify('Found ' .. count .. ' islands', 3)
        else
            Library:Notify('Failed to load island registry.', 3)
        end
    end,
    DoubleClick = false,
    Tooltip = 'Refresh the island list from the server registry',
})

ITLeft:AddButton({
    Text = 'Teleport to Island',
    Func = function()
        if not HubState.SelectedIsland then
            Library:Notify('Please select an island first.', 3)
            return
        end
        local info = HubState.Islands[HubState.SelectedIsland]
        if info and info.Position then
            SmartMove(info.Position, HubState.SelectedIsland, HubState.FarmPositionMethod)
            Library:Notify('Teleported to ' .. HubState.SelectedIsland, 2)
        end
    end,
    DoubleClick = false,
    Tooltip = 'Teleport to the selected island (uses teleporter for cross-island)',
})

-- ============ NPC TELEPORTS TAB ============
local NTLeft = Tabs.NPCTP:AddLeftGroupbox('NPC Teleports')

local npcDropdown = NTLeft:AddDropdown('NPCDropdown', {
    Values = {},
    Default = 1,
    Multi = false,
    Text = 'Select NPC',
    Tooltip = 'Choose an NPC to teleport to',
    Callback = function(Value)
        HubState.SelectedNPC = Value
    end
})

NTLeft:AddButton({
    Text = 'REFRESH LIST',
    Func = function()
        HubState.NPCs = {}
        npcDropdown:SetValues({})
        npcDropdown:SetValue("")
        HubState.SelectedNPC = nil
        Library:Notify('Loading NPC registry...', 2)
        local ok, npcData = pcall(function() return RF_GetNPCData:InvokeServer() end)
        if ok and type(npcData) == "table" then
            local count = 0
            for name, info in pairs(npcData) do
                -- Only list actual NPCs (exclude island destinations / "Featured")
                if type(info) == "table" and info.Position and info.Category ~= "Featured" then
                    HubState.NPCs[name] = {Position = info.Position, Category = info.Category or "Other", Instant = info.Instant or ""}
                    count = count + 1
                end
            end
            local npcNames = {}
            for name, _ in pairs(HubState.NPCs) do
                table.insert(npcNames, name)
            end
            table.sort(npcNames)
            npcDropdown:SetValues(npcNames)
            if #npcNames > 0 then
                HubState.SelectedNPC = npcNames[1]
                npcDropdown:SetValue(npcNames[1])
            end
            RefreshQuestDropdown()
            Library:Notify('Found ' .. count .. ' NPCs', 3)
        else
            Library:Notify('Failed to load NPC registry.', 3)
        end
    end,
    DoubleClick = false,
    Tooltip = 'Refresh the NPC list from the server registry',
})

NTLeft:AddButton({
    Text = 'Teleport to NPC',
    Func = function()
        if not HubState.SelectedNPC then
            Library:Notify('Please select an NPC first.', 3)
            return
        end
        local info = HubState.NPCs[HubState.SelectedNPC]
        if info and info.Position then
            SmartMove(info.Position, HubState.SelectedNPC, HubState.FarmPositionMethod)
            Library:Notify('Teleported to ' .. HubState.SelectedNPC, 2)
        end
    end,
    DoubleClick = false,
    Tooltip = 'Teleport to the selected NPC (uses teleporter for cross-island)',
})

-- ============ SETTINGS TAB ============
local SLeft = Tabs.Settings:AddLeftGroupbox('Interface')

-- Toggle keybind
local MenuKeybind = SLeft:AddLabel('Menu keybind'):AddKeyPicker('MenuKeybind', {
    Default = 'RightShift',
    NoUI = true,
    Text = 'Menu keybind',
})
-- LinoriaLib KeyPicker handles menu toggle automatically via Default key

SLeft:AddToggle('ShowHideToggle', {
    Text = 'Show/Hide Hub',
    Default = true,
    Callback = function(Value)
        HubState.Visible = Value
        if not Value then
            Library:Unload()
        end
    end
})

SLeft:AddSlider('UISlider', {
    Text = 'Interface Scale',
    Default = 1,
    Min = 0.5,
    Max = 1.5,
    Rounding = 1,
    Compact = false,
    Callback = function(Value)
        HubState.Scale = Value
    end
})

SLeft:AddSlider('UIAlpha', {
    Text = 'UI Transparency',
    Default = 5,
    Min = 0,
    Max = 50,
    Rounding = 0,
    Suffix = '%',
    Compact = false,
    Callback = function(Value)
        HubState.Transparency = Value / 100
    end
})

SLeft:AddButton({
    Text = 'Reset Interface Settings',
    Func = function()
        HubState.Scale = 1
        HubState.Transparency = 0.05
        Library:Notify('Interface settings reset.', 2)
    end,
    DoubleClick = false,
    Tooltip = 'Reset scale and transparency to defaults',
})

SLeft:AddToggle('AutoRepeatToggle', {
    Text = 'Auto Repeat Quest',
    Default = false,
    Tooltip = 'Keep current quest active instead of cancelling when starting a new To Max farm',
    Callback = function(Value)
        HubState.AutoRepeatQuest = Value
    end
})

local VersionLabel = SLeft:AddLabel('LEGACY PIECE HUB ' .. HUB_VERSION)
local BuiltLabel = SLeft:AddLabel('Built for Legacy Piece')

-- ============ STATUS UPDATE LOOP ============
task.spawn(function()
    while true do
        if HubState.AutoFarmEnabled then
            SelectStatusLabel:SetText('Status: Farming | Quest: ' .. (HubState.SelectedQuest or 'None') .. ' | Mode: ' .. HubState.AutoFarmMode)
        else
            SelectStatusLabel:SetText('Status: Stopped | Quest: ' .. (HubState.SelectedQuest or 'None') .. ' | Mode: ' .. HubState.AutoFarmMode)
        end
        local lvl = GetLevel()
        MaxLevelLabel:SetText('Level: ' .. lvl)
        MaxCurrentQuestLabel:SetText('Current Quest: ' .. (HubState.SelectedQuest or 'None'))
        MaxNextQuestLabel:SetText('Next Quest: Auto-detect')
        if HubState.AutoFarmEnabled then
            MaxStatusLabel:SetText('Status: ' .. HubState.AutoFarmMode .. ' (Level ' .. lvl .. ')')
        else
            MaxStatusLabel:SetText('Status: Stopped')
        end
        local pts = GetStatPoints()
        StatPointsLabel:SetText('Stat Points: ' .. pts)
        task.wait(1)
    end
end)

-- Initial load
local ok, npcData = pcall(function() return RF_GetNPCData:InvokeServer() end)
if ok and type(npcData) == "table" then
    local count = 0
    for name, info in pairs(npcData) do
        if type(info) == "table" and info.Position then
            HubState.NPCs[name] = {Position = info.Position, Category = info.Category or "Other", Instant = info.Instant or ""}
            count = count + 1
        end
    end
    RefreshQuestDropdown()
end

print('LEGACY PIECE HUB loaded successfully')