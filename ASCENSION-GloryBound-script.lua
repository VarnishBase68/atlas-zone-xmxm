--[[
    GloryBound Auto-Farm GUI v1.3
    Open-source auto-training & auto-rebirth for GloryBound

    Features:
      - Select 1.5x barbells or 1x dumbbells
      - Auto-train at max speed (3 reps/sec, teleport + auto-rep)
      - Auto-rebirth when RebirthReady (skips cutscene, shrine fallback)
      - Live strength display
      - Built-in anti-AFK (prevents idle kick)
      - Keybinds: T=Train, R=Rebirth, G=GUI
      - Draggable & minimizable GUI

    Requirements: executor with fireproximityprompt
    License: MIT
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

if getgenv().GloryBoundCleanup then
	getgenv().GloryBoundCleanup()
end

local oldGui = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("GloryBoundAutoFarm")
if oldGui then oldGui:Destroy() end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local TrainRepRemote = Remotes:WaitForChild("TrainRep")
local TrainStopRemote = Remotes:WaitForChild("TrainStop")
local RebirthRemote = Remotes:WaitForChild("Rebirth")
local ClientState = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controllers"):WaitForChild("ClientState"))

local REP_INTERVAL = 0.33
local REBIRTH_STOP_DELAY = 0.3
local MAX_REBIRTH = 50

local autoTrain = false
local autoRebirth = false
local equipmentMode = "1.5x"
local lastRepTime = 0
local isRebirthing = false
local isStartingTraining = false
local statusText = "Idle"
local minimized = false
local guiVisible = true

local COL_BG    = Color3.fromRGB(30, 30, 46)
local COL_BAR   = Color3.fromRGB(42, 42, 62)
local COL_GOLD  = Color3.fromRGB(212, 166, 70)
local COL_GREEN = Color3.fromRGB(80, 200, 120)
local COL_TEXT  = Color3.fromRGB(230, 230, 240)
local COL_MUTED = Color3.fromRGB(150, 150, 170)
local COL_OFF   = Color3.fromRGB(60, 60, 80)

local connections = {}
local function connect(signal, fn)
	local conn = signal:Connect(fn)
	table.insert(connections, conn)
	return conn
end

local function getState()
	return ClientState.get()
end

local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function findMachine()
	local lobby = workspace:FindFirstChild("Lobby")
	if not lobby then return nil end
	local gym = lobby:FindFirstChild("Gym")
	if not gym then return nil end
	local barbells = gym:FindFirstChild("Barbells")
	if not barbells then return nil end

	local root = getRoot()
	local best, bestDist = nil, math.huge

	for _, b in ipairs(barbells:GetChildren()) do
		local boost = b:GetAttribute("Boost")
		local occupant = b:GetAttribute("Occupant")
		local prompt = b:FindFirstChild("TrainPrompt", true)

		local matchesMode
		if equipmentMode == "1.5x" then
			matchesMode = boost and boost >= 1.5
		else
			matchesMode = not boost or boost < 1.5
		end

		if matchesMode and prompt
			and (occupant == 0 or occupant == LocalPlayer.UserId) then
			local part = b:FindFirstChildWhichIsA("BasePart", true)
			if part and root then
				local dist = (root.Position - part.Position).Magnitude
				if dist < bestDist then
					bestDist = dist
					best = {model = b, prompt = prompt, part = part}
				end
			end
		end
	end

	return best
end

local function startTraining()
	if isStartingTraining then return false end
	isStartingTraining = true

	local machine = findMachine()
	if not machine then
		statusText = "No available " .. equipmentMode .. " machine"
		isStartingTraining = false
		return false
	end

	local root = getRoot()
	if not root then
		statusText = "Waiting for character..."
		isStartingTraining = false
		return false
	end

	statusText = "Moving to " .. machine.model.Name .. "..."
	root.CFrame = CFrame.new(machine.part.Position + Vector3.new(0, 3, 0))
	task.wait(0.5)

	fireproximityprompt(machine.prompt)
	task.wait(1)

	local training = LocalPlayer:GetAttribute("Training")
	isStartingTraining = false

	if training and training ~= "" then
		statusText = "Training at " .. machine.model.Name
		return true
	else
		statusText = "Failed to start — retrying"
		return false
	end
end

local function skipRebirthCutscene()
	local controllers = LocalPlayer.PlayerScripts:FindFirstChild("Controllers")
	if not controllers then return end
	local cutscene = controllers:FindFirstChild("RebirthCutscene")
	if not cutscene then return end
	local ok, mod = pcall(require, cutscene)
	if ok and type(mod) == "table" and mod.isPlaying and mod.isPlaying() then
		pcall(mod.stop)
	end
end

local function doRebirth()
	if isRebirthing then return end
	isRebirthing = true
	statusText = "Rebirthing..."

	local beforeRebirth = getState().Rebirth

	local training = LocalPlayer:GetAttribute("Training")
	if training and training ~= "" then
		TrainStopRemote:FireServer()
		task.wait(REBIRTH_STOP_DELAY)
	end

	RebirthRemote:FireServer()
	task.wait(1)
	skipRebirthCutscene()

	if getState().Rebirth <= beforeRebirth then
		statusText = "Moving to shrine..."
		local shrine = workspace:FindFirstChild("Lobby")
		if shrine then shrine = shrine:FindFirstChild("Stations") end
		if shrine then shrine = shrine:FindFirstChild("RebirthShrine") end
		if shrine then
			local root = getRoot()
			local part = shrine:FindFirstChildWhichIsA("BasePart", true)
			if root and part then
				root.CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0))
				task.wait(0.5)
				RebirthRemote:FireServer()
				task.wait(1)
				skipRebirthCutscene()
			end
		end
	end

	task.wait(0.5)
	isRebirthing = false

	if getState().Rebirth > beforeRebirth then
		statusText = "Rebirth done — resuming"
	else
		statusText = "Rebirth failed — will retry"
	end
end

-- ======================== GUI ========================

local gui = Instance.new("ScreenGui")
gui.Name = "GloryBoundAutoFarm"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 100
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(280, 260)
main.Position = UDim2.new(0, 20, 0.5, -130)
main.BackgroundColor3 = COL_BG
main.BorderSizePixel = 0
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = COL_BAR
mainStroke.Thickness = 1
mainStroke.Parent = main

local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = COL_BAR
titleBar.BorderSizePixel = 0
titleBar.Parent = main

local tbCorner = Instance.new("UICorner")
tbCorner.CornerRadius = UDim.new(0, 10)
tbCorner.Parent = titleBar

local tbFix = Instance.new("Frame")
tbFix.Size = UDim2.new(1, 0, 0, 10)
tbFix.Position = UDim2.new(0, 0, 1, -10)
tbFix.BackgroundColor3 = COL_BAR
tbFix.BorderSizePixel = 0
tbFix.Parent = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -40, 1, 0)
titleLabel.Position = UDim2.fromOffset(12, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "GloryBound Auto-Farm"
titleLabel.TextColor3 = COL_GOLD
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 14
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = titleBar

local minimizeBtn = Instance.new("TextButton")
minimizeBtn.Size = UDim2.fromOffset(28, 28)
minimizeBtn.Position = UDim2.new(1, -32, 0, 4)
minimizeBtn.BackgroundColor3 = COL_OFF
minimizeBtn.BorderSizePixel = 0
minimizeBtn.Text = "\u{2212}"
minimizeBtn.TextColor3 = COL_TEXT
minimizeBtn.Font = Enum.Font.GothamBold
minimizeBtn.TextSize = 18
minimizeBtn.Parent = titleBar

local mbCorner = Instance.new("UICorner")
mbCorner.CornerRadius = UDim.new(0, 6)
mbCorner.Parent = minimizeBtn

local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, -24, 1, -48)
content.Position = UDim2.fromOffset(12, 42)
content.BackgroundTransparency = 1
content.Parent = main

local contentLayout = Instance.new("UIListLayout")
contentLayout.Padding = UDim.new(0, 8)
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Parent = content

-- Equipment selector
local equipRow = Instance.new("Frame")
equipRow.Size = UDim2.new(1, 0, 0, 36)
equipRow.BackgroundColor3 = COL_BAR
equipRow.BorderSizePixel = 0
equipRow.LayoutOrder = 1
equipRow.Parent = content

local erCorner = Instance.new("UICorner")
erCorner.CornerRadius = UDim.new(0, 8)
erCorner.Parent = equipRow

local equipLabel = Instance.new("TextLabel")
equipLabel.Size = UDim2.new(1, -70, 1, 0)
equipLabel.Position = UDim2.fromOffset(12, 0)
equipLabel.BackgroundTransparency = 1
equipLabel.Text = "Equipment"
equipLabel.TextColor3 = COL_TEXT
equipLabel.Font = Enum.Font.Gotham
equipLabel.TextSize = 13
equipLabel.TextXAlignment = Enum.TextXAlignment.Left
equipLabel.Parent = equipRow

local equipBtn = Instance.new("TextButton")
equipBtn.Size = UDim2.fromOffset(52, 26)
equipBtn.Position = UDim2.new(1, -64, 0.5, -13)
equipBtn.BackgroundColor3 = COL_OFF
equipBtn.BorderSizePixel = 0
equipBtn.Text = "1.5x"
equipBtn.TextColor3 = COL_GOLD
equipBtn.Font = Enum.Font.GothamBold
equipBtn.TextSize = 12
equipBtn.Parent = equipRow

local ebCorner = Instance.new("UICorner")
ebCorner.CornerRadius = UDim.new(0, 6)
ebCorner.Parent = equipBtn

equipBtn.MouseButton1Click:Connect(function()
	if equipmentMode == "1.5x" then
		equipmentMode = "1x"
		equipBtn.Text = "1x"
		equipBtn.TextColor3 = COL_TEXT
	else
		equipmentMode = "1.5x"
		equipBtn.Text = "1.5x"
		equipBtn.TextColor3 = COL_GOLD
	end
	if autoTrain then
		local training = LocalPlayer:GetAttribute("Training")
		if training and training ~= "" then
			TrainStopRemote:FireServer()
		end
	end
end)

local function createToggle(name, order, callback)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 36)
	row.BackgroundColor3 = COL_BAR
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = content

	local rCorner = Instance.new("UICorner")
	rCorner.CornerRadius = UDim.new(0, 8)
	rCorner.Parent = row

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -70, 1, 0)
	label.Position = UDim2.fromOffset(12, 0)
	label.BackgroundTransparency = 1
	label.Text = name
	label.TextColor3 = COL_TEXT
	label.Font = Enum.Font.Gotham
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local toggle = Instance.new("TextButton")
	toggle.Size = UDim2.fromOffset(52, 26)
	toggle.Position = UDim2.new(1, -64, 0.5, -13)
	toggle.BackgroundColor3 = COL_OFF
	toggle.BorderSizePixel = 0
	toggle.Text = "OFF"
	toggle.TextColor3 = COL_TEXT
	toggle.Font = Enum.Font.GothamBold
	toggle.TextSize = 11
	toggle.Parent = row

	local tCorner = Instance.new("UICorner")
	tCorner.CornerRadius = UDim.new(0, 6)
	tCorner.Parent = toggle

	local on = false
	local function setOn(value)
		on = value
		toggle.Text = on and "ON" or "OFF"
		TweenService:Create(toggle, TweenInfo.new(0.15), {
			BackgroundColor3 = on and COL_GREEN or COL_OFF
		}):Play()
		callback(on)
	end

	toggle.MouseButton1Click:Connect(function()
		setOn(not on)
	end)

	return {setOn = setOn, isOn = function() return on end}
end

local trainToggle = createToggle("Auto Train  [T]", 2, function(on)
	autoTrain = on
	if not on then
		local training = LocalPlayer:GetAttribute("Training")
		if training and training ~= "" then
			TrainStopRemote:FireServer()
		end
		statusText = "Idle"
	end
end)

local rebirthToggle = createToggle("Auto Rebirth  [R]", 3, function(on)
	autoRebirth = on
end)

-- Strength display
local strRow = Instance.new("Frame")
strRow.Size = UDim2.new(1, 0, 0, 20)
strRow.BackgroundTransparency = 1
strRow.LayoutOrder = 4
strRow.Parent = content

local strLabel = Instance.new("TextLabel")
strLabel.Size = UDim2.new(0.5, 0, 1, 0)
strLabel.BackgroundTransparency = 1
strLabel.Text = "Strength"
strLabel.TextColor3 = COL_MUTED
strLabel.Font = Enum.Font.Gotham
strLabel.TextSize = 12
strLabel.TextXAlignment = Enum.TextXAlignment.Left
strLabel.Parent = strRow

local strValue = Instance.new("TextLabel")
strValue.Size = UDim2.new(0.5, 0, 1, 0)
strValue.Position = UDim2.new(0.5, 0, 0, 0)
strValue.BackgroundTransparency = 1
strValue.Text = "\u{2014}"
strValue.TextColor3 = COL_TEXT
strValue.Font = Enum.Font.GothamBold
strValue.TextSize = 12
strValue.TextXAlignment = Enum.TextXAlignment.Right
strValue.Parent = strRow

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 0, 24)
statusLabel.BackgroundColor3 = COL_BAR
statusLabel.BorderSizePixel = 0
statusLabel.Text = "Idle"
statusLabel.TextColor3 = COL_MUTED
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.LayoutOrder = 5
statusLabel.Parent = content

local slCorner = Instance.new("UICorner")
slCorner.CornerRadius = UDim.new(0, 6)
slCorner.Parent = statusLabel

-- Keybind hint
local kbHint = Instance.new("TextLabel")
kbHint.Size = UDim2.new(1, 0, 0, 14)
kbHint.BackgroundTransparency = 1
kbHint.Text = "T = Train   R = Rebirth   G = GUI"
kbHint.TextColor3 = COL_MUTED
kbHint.Font = Enum.Font.Gotham
kbHint.TextSize = 10
kbHint.LayoutOrder = 6
kbHint.Parent = content

-- Dragging
local dragging, dragStart, startPos = false, nil, nil

connect(titleBar.InputBegan, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = main.Position
	end
end)

connect(UserInputService.InputChanged, function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart
		main.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)

connect(UserInputService.InputEnded, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)

-- Minimize
minimizeBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	content.Visible = not minimized
	main.Size = minimized and UDim2.fromOffset(280, 36) or UDim2.fromOffset(280, 260)
	minimizeBtn.Text = minimized and "+" or "\u{2212}"
end)

-- Keybinds
connect(UserInputService.InputBegan, function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if input.KeyCode == Enum.KeyCode.T then
		trainToggle.setOn(not trainToggle.isOn())
	elseif input.KeyCode == Enum.KeyCode.R then
		rebirthToggle.setOn(not rebirthToggle.isOn())
	elseif input.KeyCode == Enum.KeyCode.G then
		guiVisible = not guiVisible
		main.Visible = guiVisible
	end
end)

-- ======================== LOOPS ========================

connect(RunService.Heartbeat, function()
	if not gui.Parent then return end
	local ok, state = pcall(getState)
	if ok and state then
		strValue.Text = string.format("%d / %d", state.Strength or 0, state.StrengthCap or 0)
	end
	statusLabel.Text = statusText
end)

-- Main auto-farm logic
task.spawn(function()
	while gui.Parent do
		if autoTrain and not isRebirthing and not isStartingTraining then
			local ok, state = pcall(getState)
			if ok and state then
				local training = LocalPlayer:GetAttribute("Training")
				local zone = LocalPlayer:GetAttribute("Zone")

				if zone == "Arena" then
					statusText = "In Arena \u{2014} paused"
				elseif autoRebirth and state.RebirthReady and (state.Rebirth or 0) < MAX_REBIRTH then
					doRebirth()
				elseif not training or training == "" then
					startTraining()
				else
					local now = os.clock()
					if now - lastRepTime >= REP_INTERVAL then
						TrainRepRemote:FireServer(1)
						lastRepTime = now
					end
					statusText = "Training..."
				end
			end
		elseif not autoTrain then
			statusText = "Idle"
		end
		task.wait(0.1)
	end
end)

-- Respawn handler
connect(LocalPlayer.CharacterAdded, function()
	if autoTrain then
		task.wait(1)
		lastRepTime = 0
	end
end)

-- Anti-AFK: simulate input when Roblox is about to kick for inactivity
connect(LocalPlayer.Idled, function()
	VirtualUser:CaptureController()
	VirtualUser:ClickButton2(Vector2.new())
end)

-- Cleanup on re-execution
getgenv().GloryBoundCleanup = function()
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	if gui.Parent then gui:Destroy() end
end

print("[GloryBound Auto-Farm] Loaded! Keybinds: T=Train, R=Rebirth, G=GUI")