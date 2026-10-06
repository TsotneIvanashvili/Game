--!strict
-- Minimal survival HUD. Everything is driven by Player attributes the server publishes,
-- so the HUD can never disagree with the simulation. Bars hide when they're full and
-- irrelevant (oxygen at low altitude) to keep the screen clean.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local InjuryDefs = require(Shared.Config.InjuryDefs)
local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)

local HUDController = {}

local player = Players.LocalPlayer
local T = UI.Theme

type Bar = { frame: Frame, fill: Frame, value: TextLabel, alwaysShow: boolean }

local bars: { [string]: Bar } = {}
local info: TextLabel
local subInfo: TextLabel
local injuriesRow: Frame
local weightLabel: TextLabel
local teammates: Frame
local statusLabel: TextLabel
local downedOverlay: Frame
local downedTimer: TextLabel
local buildBar: Frame
local buildFill: Frame
local hints: TextLabel

local function makeBar(
	parent: Instance,
	key: string,
	label: string,
	color: Color3,
	order: number,
	alwaysShow: boolean
): Bar
	local frame = UI.create("Frame", {
		Name = key,
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = parent,
	})
	UI.label(label, 12, {
		Size = UDim2.new(0, 64, 1, 0),
		TextColor3 = T.Muted,
		Font = T.FontBold,
		Parent = frame,
	})
	local back = UI.create("Frame", {
		Position = UDim2.fromOffset(66, 4),
		Size = UDim2.new(1, -110, 0, 10),
		BackgroundColor3 = Color3.fromRGB(40, 44, 50),
		BackgroundTransparency = 0.2,
		Parent = frame,
	}, { UI.corner(5) })
	local fill = UI.create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		Parent = back,
	}, { UI.corner(5) })
	local value = UI.label("100", 12, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 40, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = frame,
	})
	local bar = { frame = frame, fill = fill, value = value, alwaysShow = alwaysShow }
	bars[key] = bar
	return bar
end

local function setBar(key: string, current: number, max: number, color: Color3?)
	local bar = bars[key]
	if not bar then
		return
	end
	local ratio = if max > 0 then math.clamp(current / max, 0, 1) else 0
	bar.fill.Size = UDim2.fromScale(ratio, 1)
	bar.value.Text = tostring(math.floor(current + 0.5))
	if color then
		bar.fill.BackgroundColor3 = color
	end
	bar.frame.Visible = bar.alwaysShow or ratio < 0.97
end

local function warmthColor(w: number): Color3
	if w > 70 then
		return Color3.fromRGB(240, 150, 60)
	elseif w > 50 then
		return Color3.fromRGB(230, 200, 120)
	elseif w > 30 then
		return Color3.fromRGB(140, 190, 240)
	end
	return Color3.fromRGB(90, 140, 255)
end

local function attr(name: string, default: any): any
	local v = player:GetAttribute(name)
	if v == nil then
		return default
	end
	return v
end

local function refreshInjuries()
	for _, child in injuriesRow:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local text = attr("Injuries", "") :: string
	if text == "" then
		return
	end
	for entry in string.gmatch(text, "[^,]+") do
		local splinted = entry:sub(-1) == "*"
		local id = if splinted then entry:sub(1, -2) else entry
		local def = InjuryDefs.ById[id]
		if def then
			local color = if def.severity >= 3 then T.Danger elseif def.severity == 2 then T.Warn else T.Muted
			UI.label(def.name .. (if splinted then " (splinted)" else ""), 12, {
				Size = UDim2.new(0, 0, 0, 20),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundTransparency = 0.25,
				BackgroundColor3 = T.Panel,
				TextColor3 = color,
				Font = T.FontBold,
				Parent = injuriesRow,
			}).TextXAlignment =
				Enum.TextXAlignment.Center
		end
	end
end

local function refreshTeammates()
	for _, child in teammates:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local status = ""
			if other:GetAttribute("Downed") then
				status = "  DOWNED"
			elseif (other:GetAttribute("Injuries") or "") ~= "" then
				status = "  injured"
			elseif other:GetAttribute("ColdLevel") == "Severe" or other:GetAttribute("ColdLevel") == "Critical" then
				status = "  freezing"
			end
			local hum = other.Character and other.Character:FindFirstChildOfClass("Humanoid")
			local hp = if hum then math.floor(hum.Health) else 0
			UI.label(string.format("%s  %d hp%s", other.DisplayName, hp, status), 13, {
				TextColor3 = if status == "  DOWNED" then T.Danger elseif status ~= "" then T.Warn else T.Text,
				Parent = teammates,
			})
		end
	end
end

local function refresh()
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		setBar("Health", humanoid.Health, humanoid.MaxHealth)
	end
	setBar("Stamina", attr("Stamina", 100), attr("MaxStamina", 100))
	local warmth = attr("Warmth", 100)
	setBar("Warmth", warmth, 100, warmthColor(warmth))
	setBar("Hunger", attr("Hunger", 100), 100)
	setBar("Thirst", attr("Thirst", 100), 100)
	setBar("Energy", 100 - attr("Fatigue", 0), 100)
	setBar("Oxygen", attr("Oxygen", 100), 100)

	local elevation = attr("ElevationM", 0)
	info.Text = string.format("%s  ·  %s m", attr("Zone", "..."), tostring(math.floor(elevation)))
	local wet = attr("Wetness", 0)
	local extras = {}
	if attr("InShelter", false) then
		table.insert(extras, "sheltered")
	end
	if attr("NearFire", false) then
		table.insert(extras, "by a fire")
	end
	if wet > 0.25 then
		table.insert(extras, if wet > 0.6 then "soaked" else "damp")
	end
	subInfo.Text = string.format(
		"%s  ·  %d°C  ·  wind %d m/s%s",
		attr("Weather", "Clear"),
		math.floor(attr("TempC", 10) + 0.5),
		math.floor(attr("WindMs", 0) + 0.5),
		if #extras > 0 then "  ·  " .. table.concat(extras, ", ") else ""
	)

	local inv = player:GetAttribute("Weight")
	local limit = player:GetAttribute("WeightLimit")
	if inv and limit then
		weightLabel.Text = string.format("Pack %.1f / %d kg", inv, limit)
		weightLabel.TextColor3 = if inv > limit then T.Danger elseif inv > limit * 0.8 then T.Warn else T.Muted
	end

	-- Status line: what you're doing right now and how to stop.
	local status = ""
	if attr("Climbing", false) then
		status = "Climbing  ·  W/S up/down  ·  A/D sideways  ·  Space jump off  ·  C let go"
	elseif player:GetAttribute("Carrying") then
		status = "Carrying " .. tostring(player:GetAttribute("Carrying")) .. "  ·  X to set down"
	elseif player:GetAttribute("CarriedBy") then
		status = "Being carried by " .. tostring(player:GetAttribute("CarriedBy"))
	elseif attr("Resting", false) then
		status = "Resting  ·  move to get up"
	elseif attr("ColdLevel", "None") == "Critical" then
		status = "HYPOTHERMIA"
	end
	statusLabel.Text = status
	statusLabel.Visible = status ~= ""
	hints.Visible = ClientState.openPanel == nil and not ClientState.placing

	-- Downed overlay.
	local downed = attr("Downed", false)
	downedOverlay.Visible = downed == true
	if downed then
		local secs = attr("BleedOut", 0)
		downedTimer.Text = string.format("DOWNED  %d:%02d", secs // 60, secs % 60)
	end

	-- Build progress.
	local untilTime = player:GetAttribute("BuildingUntil")
	if typeof(untilTime) == "number" then
		buildBar.Visible = true
		local remaining = untilTime - workspace:GetServerTimeNow()
		local total = buildBar:GetAttribute("Total") or math.max(remaining, 0.1)
		if not buildBar:GetAttribute("Total") then
			buildBar:SetAttribute("Total", total)
		end
		buildFill.Size = UDim2.fromScale(math.clamp(1 - remaining / total, 0, 1), 1)
	else
		buildBar.Visible = false
		buildBar:SetAttribute("Total", nil)
	end
end

function HUDController.Init()
	local gui = UI.screen("HUD", 1)

	local stats = UI.create("Frame", {
		Name = "Stats",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.new(0, 260, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.Panel,
		BackgroundTransparency = 0.45,
		Parent = gui,
	}, { UI.corner(8), UI.padding(8), UI.list(Enum.FillDirection.Vertical, 3) })
	makeBar(stats, "Health", "HEALTH", Color3.fromRGB(220, 70, 70), 1, true)
	makeBar(stats, "Stamina", "STAMINA", Color3.fromRGB(150, 215, 90), 2, true)
	makeBar(stats, "Warmth", "WARMTH", Color3.fromRGB(240, 150, 60), 3, true)
	makeBar(stats, "Hunger", "FOOD", Color3.fromRGB(210, 160, 90), 4, false)
	makeBar(stats, "Thirst", "WATER", Color3.fromRGB(90, 160, 230), 5, false)
	makeBar(stats, "Energy", "ENERGY", Color3.fromRGB(180, 140, 220), 6, false)
	makeBar(stats, "Oxygen", "OXYGEN", Color3.fromRGB(200, 230, 255), 7, false)
	weightLabel = UI.label("", 12, { LayoutOrder = 8, TextColor3 = T.Muted, Parent = stats })

	injuriesRow = UI.create("Frame", {
		Name = "Injuries",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -200),
		Size = UDim2.new(0, 420, 0, 22),
		BackgroundTransparency = 1,
		Parent = gui,
	}, { UI.list(Enum.FillDirection.Horizontal, 6) })

	local readout = UI.create("Frame", {
		Name = "Readout",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 12),
		Size = UDim2.new(0, 360, 0, 50),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	info = UI.label("", 18, { TextXAlignment = Enum.TextXAlignment.Right, Font = T.FontBold, Parent = readout })
	subInfo = UI.label("", 13, {
		Position = UDim2.fromOffset(0, 24),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = T.Muted,
		Parent = readout,
	})

	teammates = UI.create("Frame", {
		Name = "Team",
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(0, 260, 0, 160),
		BackgroundTransparency = 1,
		Parent = gui,
	}, { UI.list(Enum.FillDirection.Vertical, 2) })

	statusLabel = UI.label("", 15, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -70),
		Size = UDim2.new(0.7, 0, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = T.FontBold,
		TextStrokeTransparency = 0.5,
		Visible = false,
		Parent = gui,
	})

	hints = UI.label(
		if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
			then ""
			else "Tab pack  ·  B build  ·  C climb  ·  Shift sprint  ·  G ping",
		12,
		{
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.new(0.6, 0, 0, 16),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = T.Muted,
			Parent = gui,
		}
	)

	buildBar = UI.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.62, 0),
		Size = UDim2.fromOffset(240, 10),
		BackgroundColor3 = Color3.fromRGB(40, 44, 50),
		Visible = false,
		Parent = gui,
	}, { UI.corner(5) })
	buildFill = UI.create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = T.Accent,
		Parent = buildBar,
	}, { UI.corner(5) })

	downedOverlay = UI.create("Frame", {
		Name = "Downed",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(80, 0, 0),
		BackgroundTransparency = 0.75,
		Visible = false,
		Parent = gui,
	})
	downedTimer = UI.label("DOWNED", 32, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.new(0.6, 0, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = T.FontBold,
		TextColor3 = T.Danger,
		Parent = downedOverlay,
	})
	UI.label("Crawl toward a fire or your team. They can revive or carry you.", 16, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.47),
		Size = UDim2.new(0.6, 0, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = downedOverlay,
	})
	local giveUp = UI.button("Give up (evacuate)", function() end, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.56),
		Size = UDim2.fromOffset(220, 36),
		Parent = downedOverlay,
	})
	-- Hold-to-confirm so nobody gives up by accident.
	local holdStart: number? = nil
	giveUp.MouseButton1Down:Connect(function()
		holdStart = os.clock()
		giveUp.Text = "Hold..."
	end)
	giveUp.MouseButton1Up:Connect(function()
		if holdStart and os.clock() - holdStart >= 1.5 then
			(Remotes.get("GiveUp") :: RemoteEvent):FireServer()
		end
		holdStart = nil
		giveUp.Text = "Give up (evacuate)"
	end)
end

function HUDController.Start()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator >= 0.1 then
			accumulator = 0
			refresh()
		end
	end)
	player:GetAttributeChangedSignal("Injuries"):Connect(refreshInjuries)
	refreshInjuries()
	task.spawn(function()
		while true do
			refreshTeammates()
			task.wait(1)
		end
	end)
end

return HUDController
