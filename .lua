local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local AnimalsData = require(ReplicatedStorage:WaitForChild("Datas"):WaitForChild("Animals"))

-- ======================== ADMIN REMOTE DETECTION ========================
local adminRemote, adminUUID
adminUUID = "f888ee6e-c86d-46e1-93d7-0639d6635d42"

task.spawn(function()
    local Packages = ReplicatedStorage:WaitForChild("Packages", 15)
    if not Packages then return end
    local Net = Packages:WaitForChild("Net", 15)
    if not Net then return end
    local children = Net:GetChildren()

    for i = 1, #children - 1 do
        local cur, nxt = children[i], children[i+1]
        if cur:IsA("RemoteEvent") and nxt:IsA("RemoteEvent") then
            if nxt.Name == "RE/AdminPanelService/DealWithThis" then adminRemote = cur break end
        end
    end
    if not adminRemote then
        for i = 1, #children - 1 do
            local cur, nxt = children[i], children[i+1]
            if cur:IsA("RemoteEvent") and nxt:IsA("RemoteEvent") then
                if nxt.Name:match("AdminPanelService") then adminRemote = cur break end
            end
        end
    end
    if not adminRemote then
        for _, remote in ipairs(children) do
            if remote:IsA("RemoteEvent") and remote.Name:sub(1,3) == "RE/"
                and not remote.Name:match("AdminPanelService")
                and not remote.Name:match("NotificationService") then
                local ok = pcall(function() remote:FireServer(adminUUID, LocalPlayer, "ping") end)
                if ok then adminRemote = remote break end
            end
        end
    end
    if not adminRemote then
        local oldNC
        oldNC = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            if method ~= "FireServer" then return oldNC(self, ...) end
            local args = {...}
            if args[1] and type(args[1]) == "string"
                and args[1]:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
                if args[1]:sub(1,4) == "f888" then
                    adminUUID   = args[1]
                    adminRemote = self
                end
            end
            return oldNC(self, ...)
        end)
    end
end)

local function sendAdminCmd(player, cmd)
    if not adminRemote or not adminUUID or not player then return end
    pcall(function() adminRemote:FireServer(adminUUID, player, cmd) end)
end

local CONFIG_FOLDER = "SkyHub"
local CONFIG_FILE = CONFIG_FOLDER .. "/config.json"

local function ensureFolder()
    local ok = pcall(function()
        if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
    end)
    return ok
end

local function saveConfig(cfg)
    pcall(function()
        ensureFolder()
        local encoded = HttpService:JSONEncode(cfg)
        writefile(CONFIG_FILE, encoded)
    end)
end

local function loadConfig()
    local result = nil
    pcall(function()
        ensureFolder()
        if not isfile(CONFIG_FILE) then return end
        local raw = readfile(CONFIG_FILE)
        if not raw or raw == "" then return end
        local decoded = HttpService:JSONDecode(raw)
        if type(decoded) == "table" then
            result = decoded
        end
    end)
    return result
end

local savedCfg = loadConfig() or {}

-- ======================== PING SAMPLER ========================
local pingSamples = {}
local PING_SAMPLE_COUNT = 8

local function updatePingSamples()
    local ok, ping = pcall(function()
        return Players.LocalPlayer:GetNetworkPing() * 1000
    end)
    if ok and ping then
        table.insert(pingSamples, ping)
        if #pingSamples > PING_SAMPLE_COUNT then
            table.remove(pingSamples, 1)
        end
    end
end

local function getAveragePing()
    if #pingSamples == 0 then return 80 end
    local sum = 0
    for _, v in ipairs(pingSamples) do sum = sum + v end
    return sum / #pingSamples
end

local function getSmartBlockDelay(baseDelay)
    local ping = getAveragePing()
    local pingOffset = (ping - 80) / 1000
    local smartDelay = math.clamp(baseDelay - pingOffset, 0.02, 2.0)
    return smartDelay
end

task.spawn(function()
    while true do
        updatePingSamples()
        task.wait(0.5)
    end
end)

-- ======================== STATE ========================

local IsStealing = false
local StealProgress = 0
local StealStartTime = 0
local CurrentStealTarget = nil
local AUTO_BLOCK_ENABLED = savedCfg.autoBlock1 or false
local HAS_TELEPORTED_ONCE = false
local IsTeleporting = false
local hasBlocked = false
local hasTeleported = false
local hasGrabbed = false
local isTab2TPRunning = false

local TAB2_AUTO_BLOCK_ENABLED = savedCfg.autoBlock2  or false
local TAB2_TP_DELAY           = savedCfg.tpDelay     or 0.185
local TAB1_BLOCK_DELAY        = savedCfg.blockDelay1 or 0.27
local TAB2_BLOCK_DELAY        = savedCfg.blockDelay2 or 0.10
local TAB2_BALLOON_ENABLED    = savedCfg.balloon2     or false

-- ======================== ROLLING MICRO-CALIBRATOR ========================
local calibration = {
    lastBlockTarget  = nil,
    lastBlockTime    = 0,
    attemptCount     = 0,
    successCount     = 0,
    windowAttempts   = 0,
    windowSuccesses  = 0,
    lastResetTime    = tick(),
    baseDelay        = savedCfg.blockDelay2 or 0.10,
    RESET_INTERVAL   = 1800,
}
local blockDelayLbl = nil

local function getCalibrationStep()
    local ping = getAveragePing()
    if ping < 50 then
        return 0.003, 0.006
    elseif ping < 80 then
        return 0.005, 0.010
    else
        return 0.008, 0.015
    end
end

local function updateBlockDelayDisplay()
    if blockDelayLbl then
        blockDelayLbl.Text = string.format("%.3f", TAB2_BLOCK_DELAY)
    end
end

local function saveCalibrated()
    saveConfig({
        autoBlock1  = AUTO_BLOCK_ENABLED,
        autoBlock2  = TAB2_AUTO_BLOCK_ENABLED,
        tpDelay     = TAB2_TP_DELAY,
        blockDelay1 = TAB1_BLOCK_DELAY,
        blockDelay2 = TAB2_BLOCK_DELAY,
    })
end

local function periodicReset()
    local now = tick()
    if now - calibration.lastResetTime < calibration.RESET_INTERVAL then return end
    calibration.lastResetTime = now
    local winRate = calibration.windowAttempts > 0
        and (calibration.windowSuccesses / calibration.windowAttempts)
        or 0
    if winRate >= 0.7 then
        calibration.baseDelay = TAB2_BLOCK_DELAY
    else
        local pingBaseline = math.clamp(getAveragePing() / 1000 * 0.6, 0.02, 0.25)
        TAB2_BLOCK_DELAY = TAB2_BLOCK_DELAY + (pingBaseline - TAB2_BLOCK_DELAY) * 0.3
        TAB2_BLOCK_DELAY = math.floor(TAB2_BLOCK_DELAY * 1000 + 0.5) / 1000
        TAB2_BLOCK_DELAY = math.clamp(TAB2_BLOCK_DELAY, 0.02, 1.0)
    end
    calibration.windowAttempts  = 0
    calibration.windowSuccesses = 0
    updateBlockDelayDisplay()
    saveCalibrated()
end

local function calibrateBlockDelay(targetPlayer)
    calibration.lastBlockTarget = targetPlayer
    calibration.lastBlockTime   = tick()
    calibration.attemptCount    = calibration.attemptCount + 1
    calibration.windowAttempts  = calibration.windowAttempts + 1
    periodicReset()
    task.spawn(function()
        local watchWindow = 2.5
        local left = false
        local deadline = tick() + watchWindow
        while tick() < deadline do
            task.wait(0.08)
            local found = false
            for _, p in ipairs(Players:GetPlayers()) do
                if p == targetPlayer then found = true break end
            end
            if not found then left = true break end
        end
        local tightenStep, loosenStep = getCalibrationStep()
        if left then
            calibration.successCount    = calibration.successCount + 1
            calibration.windowSuccesses = calibration.windowSuccesses + 1
            TAB2_BLOCK_DELAY = math.clamp(TAB2_BLOCK_DELAY - tightenStep, 0.02, 1.0)
        else
            TAB2_BLOCK_DELAY = math.clamp(TAB2_BLOCK_DELAY + loosenStep, 0.02, 1.0)
        end
        TAB2_BLOCK_DELAY = math.floor(TAB2_BLOCK_DELAY * 1000 + 0.5) / 1000
        updateBlockDelayDisplay()
        saveCalibrated()
    end)
end

local allAnimalsCache = {}
local PromptMemoryCache = {}
local InternalStealCache = {}
local originalDurations = {}

local REQUIRED_TOOL = "Flying Carpet"
local FLASH_TOOL    = "Flash Teleport"

local spots = {
    CFrame.new(-362.4256286621094, -4.9, 89.1047592163086),
    CFrame.new(-328.834351, -4.9, 59.371944),
}
local SPOT_CONFIGS = {
    [1] = { position = Vector3.new(-327.315063, -0.442955, 78.682510),  lookVector = Vector3.new(-0.075495, -0.271168, -0.959567) },
    [2] = { position = Vector3.new(-331.540405, -0.238845, 79.038910),  lookVector = Vector3.new(0.131070,  -0.274596, -0.952585) },
}
local selectedSpot = 1

local TAB2_TP_POSITION  = Vector3.new(-335.791779, -7.308126, 63.851040)
local TAB2_CAM_CFRAME   = CFrame.new(-337.0014,-3.4227,76.0416, 0.9951,0.0196,-0.0968, 0.0000,0.9800,0.1988, 0.0987,-0.1979,0.9752)
local TAB2_CAM_FOV      = 70

local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()

LocalPlayer.CharacterAdded:Connect(function(c)
    char = c
    HAS_TELEPORTED_ONCE = false
    hasTeleported = false
    IsTeleporting = false
    isTab2TPRunning = false
end)

local Camera = workspace.CurrentCamera
local camLocked = false
local CAM_CFRAME = CFrame.lookAt(SPOT_CONFIGS[1].position, SPOT_CONFIGS[1].position + SPOT_CONFIGS[1].lookVector)

RunService.RenderStepped:Connect(function()
    if camLocked then Camera.CFrame = CAM_CFRAME end
end)

local function lockCamera(cf, fov)
    CAM_CFRAME = cf or CFrame.lookAt(SPOT_CONFIGS[selectedSpot].position, SPOT_CONFIGS[selectedSpot].position + SPOT_CONFIGS[selectedSpot].lookVector)
    camLocked = true
    Camera.CameraType = Enum.CameraType.Scriptable
    Camera.CameraSubject = nil
    Camera.CFrame = CAM_CFRAME
    if fov then Camera.FieldOfView = fov end
end

local function unlockCamera()
    camLocked = false
    local h = char and char:FindFirstChildOfClass("Humanoid")
    if h then Camera.CameraSubject = h end
    Camera.CameraType = Enum.CameraType.Custom
    Camera.FieldOfView = 70
end

local function getHRP()
    local c = LocalPlayer.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("UpperTorso")
end

local function findNearestEnemy()
    local root = getHRP()
    if not root then return nil end
    local nearest, minDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local r = p.Character:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (root.Position - r.Position).Magnitude
                if d < minDist then minDist = d nearest = p end
            end
        end
    end
    return nearest
end

local function equipTool(c, hum, name)
    local tool = LocalPlayer.Backpack:FindFirstChild(name) or c:FindFirstChild(name)
    if not tool then warn("[SkyHub] Tool not found: " .. name) return nil end
    if tool.Parent ~= c then
        hum:EquipTool(tool)
        local t = tick()
        repeat task.wait(0.03) until tool.Parent == c or tick()-t > 3
    end
    if tool.Parent ~= c then warn("[SkyHub] Failed to equip: " .. name) return nil end
    return tool
end

local isBlocking = false
local function NavigationBlock(targetPlayer)
    if not targetPlayer then return end
    if isBlocking then return end
    isBlocking = true
    local ok, err = pcall(function()
        StarterGui:SetCore("PromptBlockPlayer", targetPlayer)
        task.wait(0.1)
        local blockButton = nil
        local findOk, found = pcall(function()
            return game:GetService("CoreGui")
                .BlockingModalScreen.BlockingModalContainer
                .BlockingModalContainerWrapper.BlockingModal
                .AlertModal.AlertContents.Footer.Buttons["3"]
        end)
        if not findOk or not found then return end
        blockButton = found
        local timeout = tick() + 2
        while not blockButton.Visible and tick() < timeout do task.wait(0.016) end
        if not blockButton.Visible then return end
        GuiService.SelectedObject = blockButton
        task.wait(0.05)
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
        task.wait(0.02)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
        task.wait(0.1)
    end)
    if not ok then warn("[!] Block error: " .. tostring(err)) end
    isBlocking = false
end

-- Mouse-click block method (for manual block buttons only)
local function MouseClickBlock(targetPlayer)
    if not targetPlayer then return end
    StarterGui:SetCore("PromptBlockPlayer", targetPlayer)
    task.spawn(function()
        local size = workspace.CurrentCamera.ViewportSize
        for _ = 1, 5 do
            VirtualInputManager:SendMouseButtonEvent(size.X/2, size.Y/2 + 50, 0, true, game, 1)
            VirtualInputManager:SendMouseButtonEvent(size.X/2, size.Y/2 + 50, 0, false, game, 1)
            task.wait(0.01)
        end
    end)
end

local function fireBlockAfterSteal(target)
    if not target then return end
    task.spawn(function() NavigationBlock(target) end)
    task.delay(0.05, function()
        task.spawn(function() NavigationBlock(target) end)
    end)
end

local getNearestAnimal
local findProximityPromptForAnimal
local attemptSteal

local function buildStealCallbacks(prompt)
    if InternalStealCache[prompt] then return end
    local data = {holdCallbacks = {}, triggerCallbacks = {}, ready = true}
    local ok1, conns1 = pcall(getconnections, prompt.PromptButtonHoldBegan)
    if ok1 and type(conns1) == "table" then
        for _, conn in ipairs(conns1) do
            if type(conn.Function) == "function" then table.insert(data.holdCallbacks, conn.Function) end
        end
    end
    local ok2, conns2 = pcall(getconnections, prompt.Triggered)
    if ok2 and type(conns2) == "table" then
        for _, conn in ipairs(conns2) do
            if type(conn.Function) == "function" then table.insert(data.triggerCallbacks, conn.Function) end
        end
    end
    if #data.holdCallbacks > 0 or #data.triggerCallbacks > 0 then
        InternalStealCache[prompt] = data
    end
end

local function executeInternalStealAsync(prompt, animalData)
    local data = InternalStealCache[prompt]
    if not data or not data.ready then return false end
    data.ready = false
    IsStealing = true
    StealProgress = 0
    CurrentStealTarget = animalData
    StealStartTime = tick()
    hasTeleported = false
    hasGrabbed = false
    hasBlocked = false
    task.spawn(function()
        for _, fn in ipairs(data.holdCallbacks) do task.spawn(fn) end
        for _, fn in ipairs(data.triggerCallbacks) do task.spawn(fn) end
        hasGrabbed = true
        task.wait(0.01)
        IsStealing = false
        StealProgress = 0
        CurrentStealTarget = nil
        data.ready = true
        hasTeleported = false
        hasGrabbed = false
        hasBlocked = false
    end)
    return true
end

local function teleportAll(prePrompt, preTarget)
    if IsTeleporting then return end
    IsTeleporting = true
    local currentChar = LocalPlayer.Character
    if not currentChar then IsTeleporting = false return end
    local currentHumanoid = currentChar:FindFirstChildOfClass("Humanoid")
    local currentHRP = currentChar:FindFirstChild("HumanoidRootPart")
    if not currentHumanoid or not currentHRP then IsTeleporting = false return end
    local tool = equipTool(currentChar, currentHumanoid, REQUIRED_TOOL)
    if not tool then IsTeleporting = false return end

    local tab1BlockTarget = nil
    if AUTO_BLOCK_ENABLED then
        tab1BlockTarget = findNearestEnemy()
    end

    if tab1BlockTarget and AUTO_BLOCK_ENABLED then
        task.spawn(function() NavigationBlock(tab1BlockTarget) end)
        task.delay(0.05, function()
            task.spawn(function() NavigationBlock(tab1BlockTarget) end)
        end)
    end

    currentHumanoid:ChangeState(Enum.HumanoidStateType.Physics)
    task.wait(0.05)

    for _ = 1, 6 do
        currentHRP.CFrame = spots[1]
        currentHRP.AssemblyLinearVelocity = Vector3.zero
        currentHRP.AssemblyAngularVelocity = Vector3.zero
        task.wait(0.03)
    end
    currentHumanoid:ChangeState(Enum.HumanoidStateType.Physics)
    task.wait(0.03)
    for _ = 1, 6 do
        currentHRP.CFrame = spots[2]
        currentHRP.AssemblyLinearVelocity = Vector3.zero
        currentHRP.AssemblyAngularVelocity = Vector3.zero
        task.wait(0.03)
    end
    currentHRP.AssemblyLinearVelocity = Vector3.zero
    currentHRP.AssemblyAngularVelocity = Vector3.zero

    local flashChar = LocalPlayer.Character
    if not flashChar then IsTeleporting = false return end
    local flashHumanoid = flashChar:FindFirstChildOfClass("Humanoid")
    local flashHRP = flashChar:FindFirstChild("HumanoidRootPart")
    if not flashHumanoid or not flashHRP then IsTeleporting = false return end

    lockCamera(nil, nil)
    local flashTool = equipTool(flashChar, flashHumanoid, FLASH_TOOL)
    if not flashTool then unlockCamera() IsTeleporting = false return end

    flashHRP.CFrame = spots[2]
    flashHRP.AssemblyLinearVelocity = Vector3.zero
    flashHRP.AssemblyAngularVelocity = Vector3.zero
    flashTool:Activate()
    task.wait(0.19)

    if prePrompt and prePrompt.Parent and preTarget then
        if attemptSteal then attemptSteal(prePrompt, preTarget) end
    end

    hasTeleported = true
    HAS_TELEPORTED_ONCE = true
    IsTeleporting = false

    local restoreChar = LocalPlayer.Character
    if restoreChar then
        local rh = restoreChar:FindFirstChildOfClass("Humanoid")
        if rh then rh:ChangeState(Enum.HumanoidStateType.Running) end
    end
    task.delay(1.5, unlockCamera)
end

-- ======================== INSTANT FLASH (TAB 2) ========================

local function doInstantFlash(prePrompt, preTarget)
    if isTab2TPRunning then return end
    isTab2TPRunning = true

    local function getChar()
        local c = LocalPlayer.Character
        if not c then return nil, nil, nil end
        return c, c:FindFirstChildOfClass("Humanoid"), c:FindFirstChild("HumanoidRootPart")
    end

    local c, hum, hrp = getChar()
    if not c or not hum or not hrp then isTab2TPRunning = false return end

    local blockTargetForCalib = nil
    if TAB2_AUTO_BLOCK_ENABLED then
        blockTargetForCalib = findNearestEnemy()
    end

    if TAB2_TP_DELAY > 0 then task.wait(TAB2_TP_DELAY) end

    local c2, hum2, hrp2 = getChar()
    if not c2 or not hum2 or not hrp2 then isTab2TPRunning = false return end

    local carpet = LocalPlayer.Backpack:FindFirstChild(REQUIRED_TOOL) or c2:FindFirstChild(REQUIRED_TOOL)
    if not carpet then
        for _, item in ipairs(LocalPlayer.Backpack:GetChildren()) do
            if item:IsA("Tool") and (item.Name:lower():find("flying") or item.Name:lower():find("carpet")) then carpet = item break end
        end
    end
    if not carpet then isTab2TPRunning = false return end
    if carpet.Parent ~= c2 then hum2:EquipTool(carpet) task.wait(0.09) end

    if blockTargetForCalib then
        task.spawn(function() NavigationBlock(blockTargetForCalib) end)
        task.delay(0.05, function()
            task.spawn(function() NavigationBlock(blockTargetForCalib) end)
        end)
    end

    local c3, _, hrp3 = getChar()
    if not c3 or not hrp3 then isTab2TPRunning = false return end
    hrp3.CFrame = CFrame.new(TAB2_TP_POSITION)
    hrp3.AssemblyLinearVelocity = Vector3.zero
    hrp3.AssemblyAngularVelocity = Vector3.zero

    task.wait(0.185)

    lockCamera(TAB2_CAM_CFRAME, TAB2_CAM_FOV)

    local c4, hum4, hrp4 = getChar()
    if not c4 or not hum4 or not hrp4 then unlockCamera() isTab2TPRunning = false return end

    local flashTool = nil
    for _ = 1, 3 do
        flashTool = LocalPlayer.Backpack:FindFirstChild(FLASH_TOOL) or c4:FindFirstChild(FLASH_TOOL)
        if not flashTool then task.wait(0.1)
        else
            if flashTool.Parent ~= c4 then
                hum4:EquipTool(flashTool)
                local t = tick()
                repeat task.wait(0.03) until flashTool.Parent == c4 or tick()-t > 1
            end
            if flashTool.Parent == c4 then break end
            flashTool = nil
        end
    end
    if not flashTool then unlockCamera() isTab2TPRunning = false return end

    hrp4.CFrame = CFrame.new(TAB2_TP_POSITION)
    hrp4.AssemblyLinearVelocity = Vector3.zero
    hrp4.AssemblyAngularVelocity = Vector3.zero

    if TAB2_BALLOON_ENABLED and adminRemote then
        local balloonTarget = findNearestEnemy()
        if balloonTarget then
            task.delay(0.09, function()
                sendAdminCmd(balloonTarget, "balloon")
            end)
        end
    end

    flashTool:Activate()
    task.wait(0.19)

    if prePrompt and prePrompt.Parent and preTarget then
        if attemptSteal then attemptSteal(prePrompt, preTarget) end
    end

    if blockTargetForCalib then
        calibrateBlockDelay(blockTargetForCalib)
    end

    task.delay(1.5, unlockCamera)
    task.wait(1)
    isTab2TPRunning = false
end

-- ======================== ANIMAL SCANNING ========================

local function isMyBase(plotName)
    local plot = workspace.Plots:FindFirstChild(plotName)
    if not plot then return false end
    local sign = plot:FindFirstChild("PlotSign")
    if sign then
        local yourBase = sign:FindFirstChild("YourBase")
        if yourBase and yourBase:IsA("BillboardGui") then return yourBase.Enabled == true end
    end
    return false
end

local function scanSinglePlot(plot)
    if not plot or not plot:IsA("Model") then return end
    if isMyBase(plot.Name) then return end
    local podiums = plot:FindFirstChild("AnimalPodiums")
    if not podiums then return end
    local podium = podiums:FindFirstChild("10")
    if not podium or not podium:IsA("Model") or not podium:FindFirstChild("Base") then return end
    local animalName, displayName = "Unknown", "Unknown"
    local spawn = podium.Base:FindFirstChild("Spawn")
    if spawn then
        for _, child in ipairs(spawn:GetChildren()) do
            if child:IsA("Model") and child.Name ~= "PromptAttachment" then
                animalName = child.Name
                local info = AnimalsData[animalName]
                displayName = (info and info.DisplayName) or animalName
                break
            end
        end
    end
    table.insert(allAnimalsCache, {
        name = displayName, plot = plot.Name, slot = podium.Name,
        worldPosition = podium:GetPivot().Position,
        uid = plot.Name .. "_" .. podium.Name,
    })
end

local function initializeScanner()
    task.wait(2)
    local plots = workspace:WaitForChild("Plots", 10)
    if not plots then return end
    for _, plot in ipairs(plots:GetChildren()) do
        if plot:IsA("Model") then scanSinglePlot(plot) end
    end
    plots.ChildAdded:Connect(function(plot)
        if plot:IsA("Model") then task.wait(0.5) scanSinglePlot(plot) end
    end)
    task.spawn(function()
        while task.wait(5) do
            allAnimalsCache = {}
            for _, plot in ipairs(plots:GetChildren()) do
                if plot:IsA("Model") then scanSinglePlot(plot) end
            end
        end
    end)
end

local function startAutoSteal()
    getNearestAnimal = function()
        local root = getHRP()
        if not root then return nil end
        local nearest, minDist = nil, math.huge
        for _, animalData in ipairs(allAnimalsCache) do
            if not isMyBase(animalData.plot) and animalData.worldPosition then
                local d = (root.Position - animalData.worldPosition).Magnitude
                if d < minDist then minDist = d nearest = animalData end
            end
        end
        return nearest
    end
    findProximityPromptForAnimal = function(animalData)
        if not animalData then return nil end
        local cached = PromptMemoryCache[animalData.uid]
        if cached and cached.Parent then return cached end
        local plot = workspace.Plots:FindFirstChild(animalData.plot)
        if not plot then return nil end
        local podiums = plot:FindFirstChild("AnimalPodiums")
        if not podiums then return nil end
        local podium = podiums:FindFirstChild(animalData.slot)
        if not podium then return nil end
        local base = podium:FindFirstChild("Base")
        if not base then return nil end
        local spawn = base:FindFirstChild("Spawn")
        if not spawn then return nil end
        local attach = spawn:FindFirstChild("PromptAttachment")
        if not attach then return nil end
        for _, p in ipairs(attach:GetChildren()) do
            if p:IsA("ProximityPrompt") then
                PromptMemoryCache[animalData.uid] = p
                if not originalDurations[p] then originalDurations[p] = p.HoldDuration end
                return p
            end
        end
        return nil
    end
    attemptSteal = function(prompt, animalData)
        if not prompt or not prompt.Parent then return false end
        if not originalDurations[prompt] then originalDurations[prompt] = prompt.HoldDuration end
        prompt.HoldDuration = 0
        buildStealCallbacks(prompt)
        if not InternalStealCache[prompt] then return false end
        return executeInternalStealAsync(prompt, animalData)
    end
end

-- ======================== ADMIN ESP ========================

local ADMIN_TAG_TEXT    = "OWNS AP"
local NO_ADMIN_TAG_TEXT = "NO AP"
local ADMIN_TEXT_COLOR  = Color3.fromRGB(30, 60, 180)
local NO_ADMIN_COLOR    = Color3.fromRGB(0, 0, 0)
local BOX_COLOR         = Color3.fromRGB(130, 200, 255)
local NAME_COLOR        = Color3.fromRGB(0, 0, 0)
local TAG_FONT          = Enum.Font.GothamBold
local NAME_TEXT_SIZE    = 11
local TAG_TEXT_SIZE     = 9
local CHAR_HALF_W       = 1.5
local CHAR_HALF_H       = 2.9
local CHAR_HALF_D       = 0.6

local adminESPGui = Instance.new("ScreenGui")
adminESPGui.Name           = "AdminESP"
adminESPGui.ResetOnSpawn   = false
adminESPGui.DisplayOrder   = 999998
adminESPGui.IgnoreGuiInset = true
adminESPGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
adminESPGui.Parent         = PlayerGui

local adminESPCanvas = Instance.new("Frame", adminESPGui)
adminESPCanvas.Size                  = UDim2.new(1, 0, 1, 0)
adminESPCanvas.BackgroundTransparency = 1
adminESPCanvas.BorderSizePixel       = 0

local adminESPEntries = {}

local function playerHasAdmin(player)
    return player:GetAttribute("AdminCommands") == true
end

local function getScreenBoundsAdmin(hrp)
    local cam = workspace.CurrentCamera
    local pos = hrp.Position
    local corners = {
        Vector3.new( CHAR_HALF_W,  CHAR_HALF_H,  CHAR_HALF_D),
        Vector3.new(-CHAR_HALF_W,  CHAR_HALF_H,  CHAR_HALF_D),
        Vector3.new( CHAR_HALF_W, -CHAR_HALF_H,  CHAR_HALF_D),
        Vector3.new(-CHAR_HALF_W, -CHAR_HALF_H,  CHAR_HALF_D),
        Vector3.new( CHAR_HALF_W,  CHAR_HALF_H, -CHAR_HALF_D),
        Vector3.new(-CHAR_HALF_W,  CHAR_HALF_H, -CHAR_HALF_D),
        Vector3.new( CHAR_HALF_W, -CHAR_HALF_H, -CHAR_HALF_D),
        Vector3.new(-CHAR_HALF_W, -CHAR_HALF_H, -CHAR_HALF_D),
    }
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local anyVisible = false
    for _, offset in ipairs(corners) do
        local sp, vis = cam:WorldToViewportPoint(pos + offset)
        if vis then
            anyVisible = true
            if sp.X < minX then minX = sp.X end
            if sp.Y < minY then minY = sp.Y end
            if sp.X > maxX then maxX = sp.X end
            if sp.Y > maxY then maxY = sp.Y end
        end
    end
    if not anyVisible then return nil end
    return minX, minY, maxX, maxY
end

local function makeAdminESPEntry(player)
    if adminESPEntries[player] then return end

    local box = Instance.new("Frame", adminESPCanvas)
    box.BackgroundTransparency = 1
    box.BorderSizePixel        = 0
    box.ZIndex                 = 10
    box.Visible                = false

    local stroke = Instance.new("UIStroke", box)
    stroke.Color        = BOX_COLOR
    stroke.Thickness    = 1.5
    stroke.Transparency = 0

    local nameLbl = Instance.new("TextLabel", adminESPCanvas)
    nameLbl.BackgroundTransparency = 1
    nameLbl.TextColor3             = NAME_COLOR
    nameLbl.TextStrokeColor3       = Color3.fromRGB(255, 255, 255)
    nameLbl.TextStrokeTransparency = 0
    nameLbl.Font                   = TAG_FONT
    nameLbl.TextSize               = NAME_TEXT_SIZE
    nameLbl.TextScaled             = false
    nameLbl.Text                   = player.Name
    nameLbl.Size                   = UDim2.new(0, 150, 0, NAME_TEXT_SIZE + 2)
    nameLbl.TextXAlignment         = Enum.TextXAlignment.Left
    nameLbl.ZIndex                 = 11
    nameLbl.Visible                = false

    local tagLbl = Instance.new("TextLabel", adminESPCanvas)
    tagLbl.BackgroundTransparency  = 1
    tagLbl.Font                    = TAG_FONT
    tagLbl.TextSize                = TAG_TEXT_SIZE
    tagLbl.TextScaled              = false
    tagLbl.Size                    = UDim2.new(0, 150, 0, TAG_TEXT_SIZE + 2)
    tagLbl.TextXAlignment          = Enum.TextXAlignment.Left
    tagLbl.TextStrokeColor3        = Color3.fromRGB(255, 255, 255)
    tagLbl.TextStrokeTransparency  = 0
    tagLbl.ZIndex                  = 11
    tagLbl.Visible                 = false

    if playerHasAdmin(player) then
        tagLbl.Text       = ADMIN_TAG_TEXT
        tagLbl.TextColor3 = ADMIN_TEXT_COLOR
    else
        tagLbl.Text       = NO_ADMIN_TAG_TEXT
        tagLbl.TextColor3 = NO_ADMIN_COLOR
    end

    adminESPEntries[player] = { box = box, name = nameLbl, tag = tagLbl }

    player.AttributeChanged:Connect(function(attr)
        if attr == "AdminCommands" then
            local e = adminESPEntries[player]
            if not e then return end
            if playerHasAdmin(player) then
                e.tag.Text       = ADMIN_TAG_TEXT
                e.tag.TextColor3 = ADMIN_TEXT_COLOR
            else
                e.tag.Text       = NO_ADMIN_TAG_TEXT
                e.tag.TextColor3 = NO_ADMIN_COLOR
            end
        end
    end)
end

local function removeAdminESPEntry(player)
    local e = adminESPEntries[player]
    if not e then return end
    e.box:Destroy()
    e.name:Destroy()
    e.tag:Destroy()
    adminESPEntries[player] = nil
end

local function setupAdminESP(player)
    if player == LocalPlayer then return end
    makeAdminESPEntry(player)
    player.CharacterAdded:Connect(function()
        task.wait(0.05)
        if adminESPEntries[player] then
            adminESPEntries[player].name.Text = player.Name
        end
    end)
end

task.spawn(function()
    while true do
        task.wait(0.01)
        for player, e in pairs(adminESPEntries) do
            local char2 = player.Character
            local hrp = char2 and char2:FindFirstChild("HumanoidRootPart")
            local hum = char2 and char2:FindFirstChildOfClass("Humanoid")
            if not hrp or not hum or hum.Health <= 0 then
                e.box.Visible  = false
                e.name.Visible = false
                e.tag.Visible  = false
                continue
            end
            local minX, minY, maxX, maxY = getScreenBoundsAdmin(hrp)
            if not minX then
                e.box.Visible  = false
                e.name.Visible = false
                e.tag.Visible  = false
                continue
            end
            local w = maxX - minX
            local h = maxY - minY
            e.box.Visible  = true
            e.name.Visible = true
            e.tag.Visible  = true
            e.box.Position = UDim2.fromOffset(math.round(minX), math.round(minY))
            e.box.Size     = UDim2.fromOffset(math.round(w), math.round(h))
            local sideX = math.round(maxX + 4)
            e.name.Position = UDim2.fromOffset(sideX, math.round(minY))
            e.tag.Position  = UDim2.fromOffset(sideX, math.round(minY) + NAME_TEXT_SIZE + 3)
        end
    end
end)

for _, p in ipairs(Players:GetPlayers()) do setupAdminESP(p) end
Players.PlayerAdded:Connect(function(p) task.wait(0.05) setupAdminESP(p) end)
Players.PlayerRemoving:Connect(function(p) removeAdminESPEntry(p) end)

-- ======================== GUI ========================

local C = {
    bg      = Color3.fromRGB(7,  9,  20),
    panel   = Color3.fromRGB(11, 14, 30),
    raised  = Color3.fromRGB(15, 19, 40),
    border  = Color3.fromRGB(20, 50, 160),
    accent  = Color3.fromRGB(80, 150, 255),
    accentB = Color3.fromRGB(120, 80, 255),
    accentD = Color3.fromRGB(18, 30, 80),
    on      = Color3.fromRGB(40, 210, 130),
    text    = Color3.fromRGB(210, 225, 255),
    sub     = Color3.fromRGB(80, 105, 170),
    muted   = Color3.fromRGB(25, 32, 65),
    glow1   = Color3.fromRGB(20, 60, 180),
    glow2   = Color3.fromRGB(130, 60, 255),
    glow3   = Color3.fromRGB(40, 180, 255),
}

local galaxyColors = {
    Color3.fromRGB(20,  60,  180),
    Color3.fromRGB(10,  30,  120),
    Color3.fromRGB(50,  20,  160),
    Color3.fromRGB(10,  80,  200),
    Color3.fromRGB(30,  10,  100),
    Color3.fromRGB(0,   100, 210),
    Color3.fromRGB(15,  50,  140),
    Color3.fromRGB(40,  0,   130),
    Color3.fromRGB(0,   70,  160),
}

local W, H = 220, 355

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SkyHubUI"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 999999
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

-- ======================== FLOATING RIGHT-SIDE BUTTONS ========================

local function makeFloatBtn(label, color, yOffset)
    local holder = Instance.new("Frame", screenGui)
    holder.Size = UDim2.fromOffset(158, 48)
    holder.Position = UDim2.new(1, -174, 0.5, yOffset)
    holder.BackgroundTransparency = 1
    holder.Active = true
    holder.Draggable = false
    holder.ZIndex = 100

    local btn = Instance.new("TextButton", holder)
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundColor3 = color
    btn.BackgroundTransparency = 0.15
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.ZIndex = 101
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 14)

    local stroke = Instance.new("UIStroke", btn)
    stroke.Color = Color3.fromRGB(60, 120, 220)
    stroke.Thickness = 1
    stroke.Transparency = 0.45
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local lbl = Instance.new("TextLabel", btn)
    lbl.Size = UDim2.fromScale(1, 1)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = Color3.fromRGB(190, 215, 255)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 13
    lbl.ZIndex = 102

    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quint), {BackgroundTransparency = 0.0}):Play()
        TweenService:Create(stroke, TweenInfo.new(0.12), {Transparency = 0.1}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quint), {BackgroundTransparency = 0.15}):Play()
        TweenService:Create(stroke, TweenInfo.new(0.12), {Transparency = 0.45}):Play()
    end)
    btn.MouseButton1Down:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.07), {
            BackgroundTransparency = 0.0,
            Size = UDim2.new(1, -4, 1, -4),
            Position = UDim2.new(0, 2, 0, 2)
        }):Play()
    end)
    btn.MouseButton1Up:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.1), {
            BackgroundTransparency = 0.08,
            Size = UDim2.fromScale(1, 1),
            Position = UDim2.fromScale(0, 0)
        }):Play()
    end)

    return btn
end

local floatBlockBtn = makeFloatBtn("🚫  Block Nearest", Color3.fromRGB(18, 50, 130), -64)
local floatFlashBtn = makeFloatBtn("⚡  Instant Flash",  Color3.fromRGB(14, 40, 110), -8)

floatBlockBtn.Activated:Connect(function()
    local root = getHRP()
    if not root then return end
    local nearestPlayer, minDist = nil, math.huge
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local theirRoot = player.Character:FindFirstChild("HumanoidRootPart")
            if theirRoot then
                local dist = (root.Position - theirRoot.Position).Magnitude
                if dist < minDist then minDist = dist nearestPlayer = player end
            end
        end
    end
    if nearestPlayer then
        task.spawn(function() MouseClickBlock(nearestPlayer) end)
    end
end)

-- ======================== MAIN WRAPPER ========================

local isMinimized = false
local MINIMIZED_H = 68

local wrapper = Instance.new("Frame")
wrapper.Name = "Wrapper"
wrapper.Size = UDim2.new(0, W, 0, H)
wrapper.Position = UDim2.new(0, 16, 0, 16)
wrapper.BackgroundTransparency = 1
wrapper.BorderSizePixel = 0
wrapper.Active = true
wrapper.Draggable = true
wrapper.ZIndex = 1
wrapper.Parent = screenGui

local root = Instance.new("Frame", wrapper)
root.Name = "Root"
root.Size = UDim2.new(1, 0, 1, 0)
root.BackgroundColor3 = C.bg
root.BackgroundTransparency = 0
root.BorderSizePixel = 0
root.ClipsDescendants = true
root.ZIndex = 2
Instance.new("UICorner", root).CornerRadius = UDim.new(0, 18)

local rootStroke = Instance.new("UIStroke", root)
rootStroke.Color = galaxyColors[1]
rootStroke.Thickness = 2
rootStroke.Transparency = 0.05

local glowOverlay = Instance.new("Frame", root)
glowOverlay.Size = UDim2.new(1, 0, 0, 60)
glowOverlay.Position = UDim2.new(0, 0, 0, 0)
glowOverlay.BackgroundColor3 = galaxyColors[1]
glowOverlay.BackgroundTransparency = 0.93
glowOverlay.BorderSizePixel = 0
glowOverlay.ZIndex = 3

local galaxyIdx = 1
task.spawn(function()
    while screenGui.Parent do
        local nxt = (galaxyIdx % #galaxyColors) + 1
        TweenService:Create(rootStroke,  TweenInfo.new(3.5, Enum.EasingStyle.Sine), {Color = galaxyColors[nxt]}):Play()
        TweenService:Create(glowOverlay, TweenInfo.new(3.5, Enum.EasingStyle.Sine), {BackgroundColor3 = galaxyColors[nxt]}):Play()
        galaxyIdx = nxt
        task.wait(3.5)
    end
end)

-- ======================== HEADER ========================

local header = Instance.new("Frame", root)
header.Size = UDim2.new(1, 0, 0, 65)
header.Position = UDim2.new(0, 0, 0, 0)
header.BackgroundTransparency = 1
header.ZIndex = 4

local titleLbl = Instance.new("TextLabel", header)
titleLbl.Size = UDim2.new(1, -50, 0, 28)
titleLbl.Position = UDim2.new(0, 14, 0, 8)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "SKY HUB"
titleLbl.TextColor3 = C.text
titleLbl.Font = Enum.Font.GothamBlack
titleLbl.TextSize = 20
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.ZIndex = 5

task.spawn(function()
    local titleColors = {
        Color3.fromRGB(210, 225, 255),
        Color3.fromRGB(160, 200, 255),
        Color3.fromRGB(200, 170, 255),
        Color3.fromRGB(160, 220, 255),
    }
    local ti = 1
    while screenGui.Parent do
        local tn = (ti % #titleColors) + 1
        TweenService:Create(titleLbl, TweenInfo.new(3.5, Enum.EasingStyle.Sine), {TextColor3 = titleColors[tn]}):Play()
        ti = tn
        task.wait(3.5)
    end
end)

local discordLbl = Instance.new("TextLabel", header)
discordLbl.Size = UDim2.new(1, -16, 0, 13)
discordLbl.Position = UDim2.new(0, 15, 0, 35)
discordLbl.BackgroundTransparency = 1
discordLbl.Text = "discord.gg/skyserver"
discordLbl.TextColor3 = C.sub
discordLbl.Font = Enum.Font.Gotham
discordLbl.TextSize = 10
discordLbl.TextXAlignment = Enum.TextXAlignment.Left
discordLbl.ZIndex = 5

local pingLbl = Instance.new("TextLabel", header)
pingLbl.Size = UDim2.new(1, -16, 0, 13)
pingLbl.Position = UDim2.new(0, 15, 0, 50)
pingLbl.BackgroundTransparency = 1
pingLbl.Text = "Ping: --ms"
pingLbl.TextColor3 = C.on
pingLbl.Font = Enum.Font.GothamBold
pingLbl.TextSize = 10
pingLbl.TextXAlignment = Enum.TextXAlignment.Left
pingLbl.ZIndex = 5

task.spawn(function()
    while screenGui.Parent do
        local ok, ping = pcall(function()
            return math.floor(Players.LocalPlayer:GetNetworkPing() * 1000)
        end)
        if ok and ping then
            pingLbl.Text = "Ping: " .. ping .. "ms"
            local pingColor
            if ping < 60 then
                pingColor = Color3.fromRGB(40, 210, 130)
            elseif ping < 100 then
                pingColor = Color3.fromRGB(255, 210, 50)
            elseif ping < 150 then
                pingColor = Color3.fromRGB(255, 140, 30)
            else
                pingColor = Color3.fromRGB(255, 60, 60)
            end
            TweenService:Create(pingLbl, TweenInfo.new(0.3, Enum.EasingStyle.Sine), {TextColor3 = pingColor}):Play()
        end
        task.wait(0.5)
    end
end)

-- ======================== MINIMIZE BUTTON ========================

local minBtn = Instance.new("TextButton", header)
minBtn.Size = UDim2.fromOffset(28, 28)
minBtn.Position = UDim2.new(1, -38, 0, 10)
minBtn.BackgroundColor3 = Color3.fromRGB(18, 40, 110)
minBtn.BackgroundTransparency = 0.1
minBtn.BorderSizePixel = 0
minBtn.Text = "—"
minBtn.TextColor3 = Color3.fromRGB(160, 200, 255)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 14
minBtn.AutoButtonColor = false
minBtn.ZIndex = 10
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 8)

local minBtnStroke = Instance.new("UIStroke", minBtn)
minBtnStroke.Color = Color3.fromRGB(50, 110, 230)
minBtnStroke.Thickness = 1
minBtnStroke.Transparency = 0.4

task.spawn(function()
    while minBtn.Parent do
        TweenService:Create(minBtnStroke, TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Transparency = 0.0}):Play()
        task.wait(1.8)
        if not minBtn.Parent then break end
        TweenService:Create(minBtnStroke, TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Transparency = 0.55}):Play()
        task.wait(1.8)
    end
end)

minBtn.MouseEnter:Connect(function()
    TweenService:Create(minBtn, TweenInfo.new(0.12), {BackgroundColor3 = Color3.fromRGB(30, 70, 180), BackgroundTransparency = 0.0}):Play()
    TweenService:Create(minBtnStroke, TweenInfo.new(0.12), {Transparency = 0.0}):Play()
end)
minBtn.MouseLeave:Connect(function()
    TweenService:Create(minBtn, TweenInfo.new(0.12), {BackgroundColor3 = Color3.fromRGB(18, 40, 110), BackgroundTransparency = 0.1}):Play()
end)
minBtn.MouseButton1Down:Connect(function()
    TweenService:Create(minBtn, TweenInfo.new(0.07), {
        Size = UDim2.fromOffset(24, 24),
        Position = UDim2.new(1, -36, 0, 12),
        BackgroundTransparency = 0.0
    }):Play()
end)
minBtn.MouseButton1Up:Connect(function()
    TweenService:Create(minBtn, TweenInfo.new(0.1), {
        Size = UDim2.fromOffset(28, 28),
        Position = UDim2.new(1, -38, 0, 10),
    }):Play()
end)

local contentContainer = Instance.new("Frame", root)
contentContainer.Name = "ContentContainer"
contentContainer.Size = UDim2.new(1, 0, 1, -68)
contentContainer.Position = UDim2.new(0, 0, 0, 68)
contentContainer.BackgroundTransparency = 1
contentContainer.ClipsDescendants = false
contentContainer.ZIndex = 4

minBtn.Activated:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        minBtn.Text = "+"
        TweenService:Create(wrapper, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Size = UDim2.new(0, W, 0, MINIMIZED_H)
        }):Play()
        TweenService:Create(root, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Size = UDim2.new(1, 0, 1, 0)
        }):Play()
        TweenService:Create(contentContainer, TweenInfo.new(0.18, Enum.EasingStyle.Quint), {
            Position = UDim2.new(0, 0, 0, 80)
        }):Play()
        task.delay(0.15, function()
            contentContainer.Visible = false
        end)
    else
        minBtn.Text = "—"
        contentContainer.Visible = true
        contentContainer.Position = UDim2.new(0, 0, 0, 80)
        TweenService:Create(wrapper, TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Size = UDim2.new(0, W, 0, H)
        }):Play()
        TweenService:Create(root, TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Size = UDim2.new(1, 0, 1, 0)
        }):Play()
        TweenService:Create(contentContainer, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Position = UDim2.new(0, 0, 0, 68)
        }):Play()
    end
end)

-- ======================== DIVIDER + TABS ========================

local div = Instance.new("Frame", contentContainer)
div.Size = UDim2.new(1, -24, 0, 1)
div.Position = UDim2.new(0, 12, 0, 0)
div.BackgroundColor3 = galaxyColors[1]
div.BackgroundTransparency = 0.4
div.BorderSizePixel = 0
div.ZIndex = 4
task.spawn(function()
    while screenGui.Parent do
        local nxt = (galaxyIdx % #galaxyColors) + 1
        TweenService:Create(div, TweenInfo.new(3.5, Enum.EasingStyle.Sine), {BackgroundColor3 = galaxyColors[nxt]}):Play()
        task.wait(3.5)
    end
end)

local tabRow = Instance.new("Frame", contentContainer)
tabRow.Size = UDim2.new(1, -16, 0, 30)
tabRow.Position = UDim2.new(0, 8, 0, 5)
tabRow.BackgroundColor3 = C.panel
tabRow.BorderSizePixel = 0
tabRow.ZIndex = 4
Instance.new("UICorner", tabRow).CornerRadius = UDim.new(0, 10)
local tabStroke = Instance.new("UIStroke", tabRow)
tabStroke.Color = C.border
tabStroke.Thickness = 1
tabStroke.Transparency = 0.4

local function makeTabBtn(xPos, w, label)
    local b = Instance.new("TextButton", tabRow)
    b.Size = UDim2.new(0, w, 1, -6)
    b.Position = UDim2.new(0, xPos, 0, 3)
    b.BackgroundColor3 = C.accent
    b.BackgroundTransparency = 1
    b.BorderSizePixel = 0
    b.Text = label
    b.TextColor3 = C.sub
    b.Font = Enum.Font.GothamBold
    b.TextSize = 11
    b.AutoButtonColor = false
    b.ZIndex = 5
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    return b
end

local TW = 97
local tabBtn1 = makeTabBtn(3, TW, "FLASH TP")
local tabBtn2 = makeTabBtn(TW + 5, TW, "INSTANT")

local CONTENT_TOP = 40
local contentH = H - 68 - CONTENT_TOP - 8

local clipFrame = Instance.new("Frame", contentContainer)
clipFrame.Size = UDim2.new(1, -16, 0, contentH)
clipFrame.Position = UDim2.new(0, 8, 0, CONTENT_TOP)
clipFrame.BackgroundTransparency = 1
clipFrame.ClipsDescendants = true
clipFrame.ZIndex = 4

local slider = Instance.new("Frame", clipFrame)
slider.Size = UDim2.new(2, 16, 1, 0)
slider.Position = UDim2.new(0, 0, 0, 0)
slider.BackgroundTransparency = 1
slider.ZIndex = 5

local PW = W - 16
local tab1Frame = Instance.new("Frame", slider)
tab1Frame.Size = UDim2.new(0, PW, 1, 0)
tab1Frame.Position = UDim2.new(0, 0, 0, 0)
tab1Frame.BackgroundTransparency = 1
tab1Frame.ZIndex = 6

local tab2Frame = Instance.new("Frame", slider)
tab2Frame.Size = UDim2.new(0, PW, 1, 0)
tab2Frame.Position = UDim2.new(0, PW + 8, 0, 0)
tab2Frame.BackgroundTransparency = 1
tab2Frame.ZIndex = 6

local function switchTab(n)
    TweenService:Create(slider, TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Position = UDim2.new(0, n == 1 and 0 or -(PW + 8), 0, 0)
    }):Play()
    tabBtn1.BackgroundTransparency = n == 1 and 0.72 or 1
    tabBtn1.TextColor3 = n == 1 and C.text or C.sub
    tabBtn2.BackgroundTransparency = n == 2 and 0.72 or 1
    tabBtn2.TextColor3 = n == 2 and C.text or C.sub
end
switchTab(1)
tabBtn1.Activated:Connect(function() switchTab(1) end)
tabBtn2.Activated:Connect(function() switchTab(2) end)

local SP = 9

local function makeBtn(parent, yPos, label)
    local btn = Instance.new("TextButton", parent)
    btn.Size = UDim2.new(1, 0, 0, 38)
    btn.Position = UDim2.new(0, 0, 0, yPos)
    btn.BackgroundColor3 = C.raised
    btn.BackgroundTransparency = 0
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.ZIndex = 7
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 12)
    local s = Instance.new("UIStroke", btn)
    s.Color = C.border s.Thickness = 1 s.Transparency = 0.5
    local lbl = Instance.new("TextLabel", btn)
    lbl.Size = UDim2.new(1, -16, 1, 0)
    lbl.Position = UDim2.new(0, 14, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.text
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.ZIndex = 8
    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.13, Enum.EasingStyle.Quint), {BackgroundColor3 = C.panel}):Play()
        TweenService:Create(s, TweenInfo.new(0.15), {Color = C.glow1, Transparency = 0.1}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.13, Enum.EasingStyle.Quint), {BackgroundColor3 = C.raised}):Play()
        TweenService:Create(s, TweenInfo.new(0.15), {Color = C.border, Transparency = 0.5}):Play()
    end)
    btn.MouseButton1Down:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.07), {BackgroundColor3 = C.accentD, Size = UDim2.new(1,-4,0,36), Position = UDim2.new(0,2,0,yPos+1)}):Play()
    end)
    btn.MouseButton1Up:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = C.panel, Size = UDim2.new(1,0,0,38), Position = UDim2.new(0,0,0,yPos)}):Play()
    end)
    return btn, lbl
end

local function makeToggle(parent, yPos, label, state)
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1, 0, 0, 38)
    row.Position = UDim2.new(0, 0, 0, yPos)
    row.BackgroundColor3 = C.raised
    row.BackgroundTransparency = 0
    row.BorderSizePixel = 0
    row.ZIndex = 7
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 12)
    local s = Instance.new("UIStroke", row)
    s.Color = C.border s.Thickness = 1 s.Transparency = 0.5
    local lbl = Instance.new("TextLabel", row)
    lbl.Size = UDim2.new(1, -68, 1, 0)
    lbl.Position = UDim2.new(0, 14, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.text
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.ZIndex = 8
    local track = Instance.new("Frame", row)
    track.Size = UDim2.new(0, 42, 0, 22)
    track.Position = UDim2.new(1, -52, 0.5, -11)
    track.BackgroundColor3 = state and C.on or C.muted
    track.BorderSizePixel = 0
    track.ZIndex = 8
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)
    local knob = Instance.new("Frame", track)
    knob.Size = UDim2.new(0, 16, 0, 16)
    knob.Position = state and UDim2.new(1,-19,0.5,-8) or UDim2.new(0,3,0.5,-8)
    knob.BackgroundColor3 = Color3.fromRGB(220, 235, 255)
    knob.BorderSizePixel = 0
    knob.ZIndex = 9
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    local click = Instance.new("TextButton", row)
    click.Size = UDim2.new(1, 0, 1, 0)
    click.BackgroundTransparency = 1
    click.Text = ""
    click.ZIndex = 10
    local function setToggle(v)
        TweenService:Create(track, TweenInfo.new(0.18, Enum.EasingStyle.Quint), {BackgroundColor3 = v and C.on or C.muted}):Play()
        TweenService:Create(knob,  TweenInfo.new(0.18, Enum.EasingStyle.Quint), {Position = v and UDim2.new(1,-19,0.5,-8) or UDim2.new(0,3,0.5,-8)}):Play()
    end
    click.MouseEnter:Connect(function()
        TweenService:Create(row, TweenInfo.new(0.13), {BackgroundColor3 = C.panel}):Play()
        TweenService:Create(s,   TweenInfo.new(0.15), {Color = C.glow1, Transparency = 0.1}):Play()
    end)
    click.MouseLeave:Connect(function()
        TweenService:Create(row, TweenInfo.new(0.13), {BackgroundColor3 = C.raised}):Play()
        TweenService:Create(s,   TweenInfo.new(0.15), {Color = C.border, Transparency = 0.5}):Play()
    end)
    return row, click, setToggle
end

local function makeInput(parent, yPos, label, default)
    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1, 0, 0, 38)
    row.Position = UDim2.new(0, 0, 0, yPos)
    row.BackgroundColor3 = C.raised
    row.BackgroundTransparency = 0
    row.BorderSizePixel = 0
    row.ZIndex = 7
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 12)
    local s = Instance.new("UIStroke", row)
    s.Color = C.border s.Thickness = 1 s.Transparency = 0.5
    local lbl = Instance.new("TextLabel", row)
    lbl.Size = UDim2.new(1, -80, 1, 0)
    lbl.Position = UDim2.new(0, 14, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.sub
    lbl.Font = Enum.Font.GothamSemibold
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.ZIndex = 8
    local box = Instance.new("TextBox", row)
    box.Size = UDim2.new(0, 60, 0, 24)
    box.Position = UDim2.new(1, -68, 0.5, -12)
    box.BackgroundColor3 = C.panel
    box.BackgroundTransparency = 0
    box.BorderSizePixel = 0
    box.Text = tostring(default)
    box.TextColor3 = C.text
    box.Font = Enum.Font.GothamBold
    box.TextSize = 12
    box.ClearTextOnFocus = false
    box.ZIndex = 8
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
    local bs = Instance.new("UIStroke", box)
    bs.Color = C.border bs.Thickness = 1 bs.Transparency = 0.4
    box.Focused:Connect(function()   TweenService:Create(bs, TweenInfo.new(0.12), {Color = C.glow1, Transparency = 0}):Play() end)
    box.FocusLost:Connect(function() TweenService:Create(bs, TweenInfo.new(0.12), {Color = C.border, Transparency = 0.4}):Play() end)
    return row, box
end

-- ======================== TAB 1 ========================

local y = 4
local flashBtn, _ = makeBtn(tab1Frame, y, "⚡  Flash Teleport")
y = y + 38 + SP

local blockRow1, blockClick1, setBlock1 = makeToggle(tab1Frame, y, "Auto Block", AUTO_BLOCK_ENABLED)
y = y + 38 + SP

local _, blockDelay1Box = makeInput(tab1Frame, y, "Block Delay (s)", TAB1_BLOCK_DELAY)
y = y + 38 + SP

local blockNearBtn, _ = makeBtn(tab1Frame, y, "🚫  Block Nearest")

flashBtn.Activated:Connect(function()
    if IsStealing or IsTeleporting then return end
    local preTarget = getNearestAnimal and getNearestAnimal()
    local prePrompt = nil
    if preTarget then
        prePrompt = PromptMemoryCache[preTarget.uid]
        if not prePrompt or not prePrompt.Parent then
            prePrompt = findProximityPromptForAnimal and findProximityPromptForAnimal(preTarget)
        end
    end
    if not prePrompt then return end
    if not originalDurations[prePrompt] then originalDurations[prePrompt] = prePrompt.HoldDuration end
    prePrompt.HoldDuration = 0
    buildStealCallbacks(prePrompt)
    if not InternalStealCache[prePrompt] then return end
    task.spawn(function()
        HAS_TELEPORTED_ONCE = false
        hasTeleported = false
        hasBlocked = false
        teleportAll(prePrompt, preTarget)
    end)
end)

blockClick1.Activated:Connect(function()
    AUTO_BLOCK_ENABLED = not AUTO_BLOCK_ENABLED
    setBlock1(AUTO_BLOCK_ENABLED)
    saveConfig({autoBlock1=AUTO_BLOCK_ENABLED, autoBlock2=TAB2_AUTO_BLOCK_ENABLED, tpDelay=TAB2_TP_DELAY, blockDelay1=TAB1_BLOCK_DELAY, blockDelay2=TAB2_BLOCK_DELAY, balloon2=TAB2_BALLOON_ENABLED})
end)

blockDelay1Box.FocusLost:Connect(function()
    local n = tonumber(blockDelay1Box.Text)
    if n then TAB1_BLOCK_DELAY = math.clamp(n, 0, 30) end
    blockDelay1Box.Text = tostring(TAB1_BLOCK_DELAY)
    saveConfig({autoBlock1=AUTO_BLOCK_ENABLED, autoBlock2=TAB2_AUTO_BLOCK_ENABLED, tpDelay=TAB2_TP_DELAY, blockDelay1=TAB1_BLOCK_DELAY, blockDelay2=TAB2_BLOCK_DELAY, balloon2=TAB2_BALLOON_ENABLED})
end)

blockNearBtn.Activated:Connect(function()
    local root = getHRP()
    if not root then return end
    local nearestPlayer, minDist = nil, math.huge
    for _, player in pairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local theirRoot = player.Character:FindFirstChild("HumanoidRootPart")
            if theirRoot then
                local dist = (root.Position - theirRoot.Position).Magnitude
                if dist < minDist then minDist = dist nearestPlayer = player end
            end
        end
    end
    if nearestPlayer then
        task.spawn(function() MouseClickBlock(nearestPlayer) end)
    end
end)

-- ======================== TAB 2 ========================

y = 4
local instantBtn, _ = makeBtn(tab2Frame, y, "⚡  Instant Flash")
y = y + 38 + SP

local _, tpBox = makeInput(tab2Frame, y, "TP Delay (s)", TAB2_TP_DELAY)
y = y + 38 + SP

local blockDelayRow = Instance.new("Frame", tab2Frame)
blockDelayRow.Size = UDim2.new(1, 0, 0, 38)
blockDelayRow.Position = UDim2.new(0, 0, 0, y)
blockDelayRow.BackgroundColor3 = C.raised
blockDelayRow.BackgroundTransparency = 0
blockDelayRow.BorderSizePixel = 0
blockDelayRow.ZIndex = 7
Instance.new("UICorner", blockDelayRow).CornerRadius = UDim.new(0, 12)
local bdStroke = Instance.new("UIStroke", blockDelayRow)
bdStroke.Color = C.border bdStroke.Thickness = 1 bdStroke.Transparency = 0.5
local bdLabel = Instance.new("TextLabel", blockDelayRow)
bdLabel.Size = UDim2.new(1, -120, 1, 0)
bdLabel.Position = UDim2.new(0, 14, 0, 0)
bdLabel.BackgroundTransparency = 1
bdLabel.Text = "Block Delay"
bdLabel.TextColor3 = C.sub
bdLabel.Font = Enum.Font.GothamSemibold
bdLabel.TextSize = 11
bdLabel.TextXAlignment = Enum.TextXAlignment.Left
bdLabel.ZIndex = 8
local bdBox = Instance.new("TextBox", blockDelayRow)
bdBox.Size = UDim2.new(0, 55, 0, 24)
bdBox.Position = UDim2.new(1, -118, 0.5, -12)
bdBox.BackgroundColor3 = C.panel
bdBox.BackgroundTransparency = 0
bdBox.BorderSizePixel = 0
bdBox.Text = string.format("%.3f", TAB2_BLOCK_DELAY)
bdBox.TextColor3 = C.text
bdBox.Font = Enum.Font.GothamBold
bdBox.TextSize = 11
bdBox.ClearTextOnFocus = false
bdBox.ZIndex = 8
Instance.new("UICorner", bdBox).CornerRadius = UDim.new(0, 8)
local bdBoxStroke = Instance.new("UIStroke", bdBox)
bdBoxStroke.Color = C.border bdBoxStroke.Thickness = 1 bdBoxStroke.Transparency = 0.4
bdBox.Focused:Connect(function() TweenService:Create(bdBoxStroke, TweenInfo.new(0.12), {Color = C.glow1, Transparency = 0}):Play() end)
bdBox.FocusLost:Connect(function()
    local n = tonumber(bdBox.Text)
    if n then TAB2_BLOCK_DELAY = math.clamp(n, 0.02, 1.0) end
    bdBox.Text = string.format("%.3f", TAB2_BLOCK_DELAY)
    TweenService:Create(bdBoxStroke, TweenInfo.new(0.12), {Color = C.border, Transparency = 0.4}):Play()
    saveConfig({autoBlock1=AUTO_BLOCK_ENABLED, autoBlock2=TAB2_AUTO_BLOCK_ENABLED, tpDelay=TAB2_TP_DELAY, blockDelay1=TAB1_BLOCK_DELAY, blockDelay2=TAB2_BLOCK_DELAY, balloon2=TAB2_BALLOON_ENABLED})
end)
local bdAutoLbl = Instance.new("TextLabel", blockDelayRow)
bdAutoLbl.Size = UDim2.new(0, 48, 0, 14)
bdAutoLbl.Position = UDim2.new(1, -58, 0.5, -7)
bdAutoLbl.BackgroundTransparency = 1
bdAutoLbl.Text = string.format("%.3f", TAB2_BLOCK_DELAY)
bdAutoLbl.TextColor3 = C.on
bdAutoLbl.Font = Enum.Font.GothamBold
bdAutoLbl.TextSize = 10
bdAutoLbl.TextXAlignment = Enum.TextXAlignment.Right
bdAutoLbl.ZIndex = 8
blockDelayLbl = bdAutoLbl
y = y + 38 + SP

local blockRow2, blockClick2, setBlock2 = makeToggle(tab2Frame, y, "Auto Block", TAB2_AUTO_BLOCK_ENABLED)
y = y + 38 + SP

local balloonRow2, balloonClick2, setBalloon2 = makeToggle(tab2Frame, y, "Balloon on Flash", TAB2_BALLOON_ENABLED)

local function triggerInstantFlash()
    if isTab2TPRunning then return end
    local preTarget = getNearestAnimal and getNearestAnimal()
    local prePrompt = nil
    if preTarget then
        prePrompt = PromptMemoryCache[preTarget.uid]
        if not prePrompt or not prePrompt.Parent then
            prePrompt = findProximityPromptForAnimal and findProximityPromptForAnimal(preTarget)
        end
    end
    if not prePrompt then return end
    if not originalDurations[prePrompt] then originalDurations[prePrompt] = prePrompt.HoldDuration end
    prePrompt.HoldDuration = 0
    buildStealCallbacks(prePrompt)
    if not InternalStealCache[prePrompt] then return end
    HAS_TELEPORTED_ONCE = false
    doInstantFlash(prePrompt, preTarget)
end

instantBtn.Activated:Connect(triggerInstantFlash)
floatFlashBtn.Activated:Connect(triggerInstantFlash)

tpBox.FocusLost:Connect(function()
    local n = tonumber(tpBox.Text)
    if n then TAB2_TP_DELAY = math.clamp(n, 0, 10) end
    tpBox.Text = tostring(TAB2_TP_DELAY)
    saveConfig({autoBlock1=AUTO_BLOCK_ENABLED, autoBlock2=TAB2_AUTO_BLOCK_ENABLED, tpDelay=TAB2_TP_DELAY, blockDelay1=TAB1_BLOCK_DELAY, blockDelay2=TAB2_BLOCK_DELAY, balloon2=TAB2_BALLOON_ENABLED})
end)

blockClick2.Activated:Connect(function()
    TAB2_AUTO_BLOCK_ENABLED = not TAB2_AUTO_BLOCK_ENABLED
    setBlock2(TAB2_AUTO_BLOCK_ENABLED)
    saveConfig({autoBlock1=AUTO_BLOCK_ENABLED, autoBlock2=TAB2_AUTO_BLOCK_ENABLED, tpDelay=TAB2_TP_DELAY, blockDelay1=TAB1_BLOCK_DELAY, blockDelay2=TAB2_BLOCK_DELAY, balloon2=TAB2_BALLOON_ENABLED})
end)

balloonClick2.Activated:Connect(function()
    TAB2_BALLOON_ENABLED = not TAB2_BALLOON_ENABLED
    setBalloon2(TAB2_BALLOON_ENABLED)
    saveConfig({autoBlock1=AUTO_BLOCK_ENABLED, autoBlock2=TAB2_AUTO_BLOCK_ENABLED, tpDelay=TAB2_TP_DELAY, blockDelay1=TAB1_BLOCK_DELAY, blockDelay2=TAB2_BLOCK_DELAY, balloon2=TAB2_BALLOON_ENABLED})
end)

-- ======================== INIT ========================

tpBox.Text          = tostring(TAB2_TP_DELAY)
blockDelay1Box.Text = tostring(TAB1_BLOCK_DELAY)
setBlock1(AUTO_BLOCK_ENABLED)
setBlock2(TAB2_AUTO_BLOCK_ENABLED)

initializeScanner()
startAutoSteal()
