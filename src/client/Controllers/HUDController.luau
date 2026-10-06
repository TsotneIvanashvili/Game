--!strict
-- Survival HUD (ART_DIRECTION section 9). Everything is driven by Player attributes the
-- server publishes, so the HUD can never disagree with the simulation; the client only
-- adds the compass heading (camera) and formats the server-driven clock.
--
--   top-left      teammates (compact; DOWNED / injured / freezing)
--   top-centre    compass heading tab + clock
--   top-right     info card: altitude, temperature °C/°F + weather glyph, zone, wind
--   left edge     round buttons: Pack, Gear, Build, Route, Camera
--   bottom-centre status line + stamina bar (only when not full); HotbarController below
--   bottom-right  big stats: health, warmth, water, food, energy (+ oxygen when thin)
--
-- Instances are created once in Init; refresh() (10 Hz) only writes changed values.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local InjuryDefs = require(Shared.Config.InjuryDefs)
local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)
local InventoryController = require(script.Parent.InventoryController)
local BuildBookController = require(script.Parent.BuildBookController)
local GearMenuController = require(script.Parent.GearMenuController)

local HUDController = {}

local player = Players.LocalPlayer
local T = UI.Theme

-- North is +Z: the direction of the climb, so "heading North" means heading up the route.
local HEADINGS = { "North", "North-East", "East", "South-East", "South", "South-West", "West", "North-West" }
local ROUTE_PANEL = "Route"
local GIVE_UP_HOLD = 1.5

type Stat = { cell: Frame, value: TextLabel, critical: boolean? }
type MateRow = { frame: Frame, name: TextLabel, info: TextLabel, stroke: UIStroke }

local gui: ScreenGui
local routeGui: ScreenGui
local headingLabel: TextLabel
local clockLabel: TextLabel
local altitudeLabel: TextLabel
local tempLabel: TextLabel
local tempFLabel: TextLabel
local weatherIconHolder: Frame
local weatherIconKind = ""
local weatherLabel: TextLabel
local zoneLabel: TextLabel
local extrasLabel: TextLabel
local stats: { [string]: Stat } = {}
local injuriesRow: Frame
local staminaFrame: Frame
local setStamina: (number, Color3?) -> ()
local statusLabel: TextLabel
local hints: TextLabel
local teammates: Frame
local mateRows: { [Player]: MateRow } = {}
local buildBar: Frame
local setBuild: (number, Color3?) -> ()
local downedOverlay: Frame
local downedTimer: TextLabel
local leftButtons: { [string]: TextButton } = {}
local tooltip: TextLabel
local hovered: string? = nil
local packTip = "Backpack"
local routePanel: Frame
local routeRows: { { dot: Frame, name: TextLabel, state: TextLabel } } = {}
local routeAltitude: TextLabel
local bestElevation = 0
local firstPerson = false

local function attr(name: string, default: any): any
	local v = player:GetAttribute(name)
	if v == nil then
		return default
	end
	return v
end

local function worldState(): Instance?
	return ReplicatedStorage:FindFirstChild("WorldState")
end

local function clockTime(): number
	local ws = worldState()
	local t = ws and ws:GetAttribute("ClockTime")
	if typeof(t) == "number" then
		return t % 24
	end
	return Lighting.ClockTime % 24
end

local function formatClock(t: number): string
	local hours = math.floor(t)
	local minutes = math.floor((t - hours) * 60)
	local suffix = if hours >= 12 then "PM" else "AM"
	local h12 = hours % 12
	if h12 == 0 then
		h12 = 12
	end
	return string.format("%d:%02d %s", h12, minutes, suffix)
end

local function withCommas(n: number): string
	local s = tostring(math.floor(n))
	local sign = ""
	if s:sub(1, 1) == "-" then
		sign, s = "-", s:sub(2)
	end
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return sign .. out
end

local function weatherKind(name: string, t: number): string
	local n = name:lower()
	if n:find("blizzard") or n:find("storm") then
		return "storm"
	elseif n:find("snow") or n:find("rain") or n:find("sleet") then
		return "snow"
	elseif n:find("fog") or n:find("whiteout") or n:find("mist") then
		return "fog"
	elseif n:find("wind") then
		return "wind"
	elseif n:find("overcast") or n:find("cloud") then
		return "cloud"
	end
	return if t < 6 or t >= 19 then "moon" else "sun"
end

local function valueColor(pct: number): Color3
	if pct < 20 then
		return T.Danger
	elseif pct < 40 then
		return T.Warn
	end
	return T.White
end

local function setStat(key: string, pct: number, visible: boolean?)
	local stat = stats[key]
	if not stat then
		return
	end
	if visible ~= nil and stat.cell.Visible ~= visible then
		stat.cell.Visible = visible
	end
	local p = math.clamp(math.floor(pct + 0.5), 0, 100)
	UI.setText(stat.value, p .. "%")
	local color = valueColor(p)
	if stat.value.TextColor3 ~= color then
		stat.value.TextColor3 = color
	end
	local critical = p < 20
	if stat.critical ~= critical then
		stat.critical = critical
		stat.cell.BackgroundColor3 = if critical then Color3.fromRGB(150, 30, 45) else T.BlueDark
	end
end

local function makeStat(parent: Instance, key: string, iconKind: string, order: number, colors: UI.IconColors?)
	local cell = UI.inset({
		Name = key,
		Size = UDim2.fromOffset(68, 84),
		LayoutOrder = order,
		Parent = parent,
	})
	local c = colors or {}
	UI.icon(iconKind, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(40, 40),
		Parent = cell,
	}, { fg = c.fg, accent = c.accent, bg = T.BlueDark })
	local value = UI.title("100%", 22, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.new(1, 0, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		Parent = cell,
	})
	stats[key] = { cell = cell, value = value }
end

-- Injuries ------------------------------------------------------------------------------

local function refreshInjuries()
	UI.clear(injuriesRow)
	local text = attr("Injuries", "") :: string
	for entry in string.gmatch(text, "[^,]+") do
		local splinted = entry:sub(-1) == "*"
		local id = if splinted then entry:sub(1, -2) else entry
		local def = InjuryDefs.ById[id]
		if def then
			local color = if def.severity >= 3 then T.Red elseif def.severity == 2 then T.Orange else T.BlueDark
			UI.pill(def.name .. (if splinted then " (splinted)" else ""), color, { Parent = injuriesRow })
		end
	end
end

-- Teammates -----------------------------------------------------------------------------

local function mateRow(other: Player): MateRow
	local row = mateRows[other]
	if row then
		return row
	end
	local frame = UI.create("Frame", {
		Size = UDim2.fromOffset(230, 30),
		BackgroundColor3 = T.Blue,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Parent = teammates,
	}, { UI.round() })
	local stroke = UI.stroke(T.White, 2)
	stroke.Parent = frame
	UI.icon("person", { Position = UDim2.fromOffset(8, 6), Size = UDim2.fromOffset(18, 18), Parent = frame })
	local name = UI.label(other.DisplayName, 14, {
		Position = UDim2.fromOffset(32, 0),
		Size = UDim2.new(1, -110, 1, 0),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})
	local info = UI.label("", 13, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 0),
		Size = UDim2.new(0, 80, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextWrapped = false,
		Parent = frame,
	})
	row = { frame = frame, name = name, info = info, stroke = stroke }
	mateRows[other] = row
	return row
end

local function refreshTeammates()
	local present: { [Player]: boolean } = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			present[other] = true
			local row = mateRow(other)
			local hum = other.Character and other.Character:FindFirstChildOfClass("Humanoid")
			local hp = if hum and hum.MaxHealth > 0 then math.floor(hum.Health / hum.MaxHealth * 100 + 0.5) else 0
			local status, color = hp .. "%", T.White
			local cold = other:GetAttribute("ColdLevel")
			if other:GetAttribute("Downed") then
				status, color = "DOWNED", T.Red
			elseif (other:GetAttribute("Injuries") or "") ~= "" then
				status, color = "injured", T.Orange
			elseif cold == "Severe" or cold == "Critical" then
				status, color = "freezing", T.Cyan
			end
			UI.setText(row.info, status)
			row.info.TextColor3 = if color == T.White then T.Muted else color
			row.stroke.Color = color
			UI.setText(row.name, other.DisplayName)
		end
	end
	for other, row in mateRows do
		if not present[other] then
			row.frame:Destroy()
			mateRows[other] = nil
		end
	end
end

-- Route panel ---------------------------------------------------------------------------

local function campNames(): { string }
	local names = {}
	local layoutModule = Shared.Config:FindFirstChild("WorldLayout")
	if layoutModule then
		local ok, layout = pcall(require, layoutModule)
		if ok and typeof(layout) == "table" and typeof((layout :: any).Camps) == "table" then
			local camps = table.clone((layout :: any).Camps)
			table.sort(camps, function(a, b)
				return (a.index or 0) < (b.index or 0)
			end)
			for _, camp in camps do
				table.insert(names, tostring(camp.name))
			end
		end
	end
	if #names == 0 then
		names = { "Base Camp" }
	end
	if names[#names] ~= "Summit" then
		table.insert(names, "Summit")
	end
	return names
end

local function refreshRoute()
	local checkpoint = attr("Checkpoint", 1)
	for i, row in routeRows do
		local reached = i <= checkpoint
		local isNext = i == checkpoint + 1
		row.dot.BackgroundColor3 = if reached then T.Green elseif isNext then T.Orange else T.BlueDeep
		UI.setText(row.state, if reached then "Reached" elseif isNext then "Next" else "")
		row.name.TextColor3 = if reached or isNext then T.White else T.Muted
	end
	UI.setText(
		routeAltitude,
		string.format("Altitude %s m  ·  best %s m", withCommas(attr("ElevationM", 0)), withCommas(bestElevation))
	)
end

local function toggleRoute()
	if ClientState.openPanel == ROUTE_PANEL then
		ClientState.setPanel(nil)
	else
		ClientState.setPanel(ROUTE_PANEL)
	end
end

-- Camera --------------------------------------------------------------------------------

local function toggleCamera()
	firstPerson = not firstPerson
	if firstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	else
		player.CameraMode = Enum.CameraMode.Classic
		-- Push the camera back out of the head, then restore the player's zoom range.
		local minZoom = player.CameraMinZoomDistance
		player.CameraMinZoomDistance = math.max(minZoom, 10)
		task.delay(0.1, function()
			player.CameraMinZoomDistance = minZoom
		end)
	end
end

-- Refresh -------------------------------------------------------------------------------

local function refresh()
	local titleOpen = ClientState.openPanel == "Title"
	gui.Enabled = not titleOpen
	if titleOpen then
		return
	end

	-- Compass + clock.
	local camera = workspace.CurrentCamera
	if camera then
		local look = camera.CFrame.LookVector
		local bearing = math.deg(math.atan2(-look.X, look.Z)) % 360
		UI.setText(headingLabel, HEADINGS[math.floor((bearing + 22.5) / 45) % 8 + 1])
	end
	local t = clockTime()
	UI.setText(clockLabel, formatClock(t))

	-- Info card.
	local elevation = attr("ElevationM", 0)
	bestElevation = math.max(bestElevation, elevation)
	UI.setText(altitudeLabel, withCommas(elevation) .. " m")
	local tempC = attr("TempC", 10)
	UI.setText(tempLabel, string.format("%d°C", math.floor(tempC + 0.5)))
	UI.setText(tempFLabel, string.format("%d°F", math.floor(tempC * 9 / 5 + 32 + 0.5)))
	tempLabel.TextColor3 = if tempC <= -15 then T.Cyan elseif tempC <= 0 then T.Cold else T.White
	local weather = tostring(attr("Weather", "Clear"))
	local kind = weatherKind(weather, t)
	if kind ~= weatherIconKind then
		weatherIconKind = kind
		UI.clear(weatherIconHolder)
		UI.icon(kind, { Parent = weatherIconHolder })
	end
	UI.setText(weatherLabel, string.format("%s  ·  wind %d m/s", weather, math.floor(attr("WindMs", 0) + 0.5)))
	UI.setText(zoneLabel, tostring(attr("Zone", "...")))
	local extras = {}
	if attr("InShelter", false) then
		table.insert(extras, "Sheltered")
	end
	if attr("NearFire", false) then
		table.insert(extras, "By a fire")
	end
	local wet = attr("Wetness", 0)
	if wet > 0.25 then
		table.insert(extras, if wet > 0.6 then "Soaked" else "Damp")
	end
	UI.setText(extrasLabel, table.concat(extras, "  ·  "))
	extrasLabel.Visible = #extras > 0

	-- Big stats.
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.MaxHealth > 0 then
		setStat("Health", humanoid.Health / humanoid.MaxHealth * 100)
	end
	setStat("Warmth", attr("Warmth", 100))
	setStat("Water", attr("Thirst", 100))
	setStat("Food", attr("Hunger", 100))
	setStat("Energy", 100 - attr("Fatigue", 0))
	local oxygen = attr("Oxygen", 100)
	setStat("Oxygen", oxygen, oxygen < 97)

	-- Stamina: only while not full.
	local maxStamina = attr("MaxStamina", 100)
	local ratio = if maxStamina > 0 then attr("Stamina", 100) / maxStamina else 1
	staminaFrame.Visible = ratio < 0.98
	setStamina(ratio, if ratio < 0.25 then T.Orange else Color3.fromRGB(150, 235, 90))

	-- Pack weight (left button outline + tooltip).
	local weight = player:GetAttribute("Weight")
	local limit = player:GetAttribute("WeightLimit")
	if typeof(weight) == "number" and typeof(limit) == "number" and limit > 0 then
		packTip = string.format("Backpack  ·  %.1f / %d kg", weight, limit)
		local stroke = leftButtons.Pack:FindFirstChildOfClass("UIStroke")
		if stroke and ClientState.openPanel ~= "Inventory" then
			stroke.Color = if weight > limit then T.Danger elseif weight > limit * 0.8 then T.Warn else T.White
		end
		if hovered == "Pack" then
			UI.setText(tooltip, packTip)
		end
	end

	-- Status line: what you're doing right now and how to stop.
	local status = ""
	local statusColor = T.White
	if attr("Climbing", false) then
		status = "Climbing  ·  W/S up/down  ·  A/D sideways  ·  Space jump off  ·  C let go"
	elseif player:GetAttribute("Carrying") then
		status = "Carrying " .. tostring(player:GetAttribute("Carrying")) .. "  ·  X to set down"
	elseif player:GetAttribute("CarriedBy") then
		status = "Being carried by " .. tostring(player:GetAttribute("CarriedBy"))
	elseif attr("Resting", false) then
		status = "Resting  ·  move to get up"
	elseif attr("ColdLevel", "None") == "Critical" then
		status, statusColor = "HYPOTHERMIA  ·  get to a fire or shelter", T.Danger
	end
	UI.setText(statusLabel, status)
	statusLabel.TextColor3 = statusColor
	statusLabel.Visible = status ~= ""
	hints.Visible = ClientState.openPanel == nil and not ClientState.placing

	-- Downed overlay.
	local downed = attr("Downed", false)
	downedOverlay.Visible = downed == true
	if downed then
		local secs = math.max(0, math.floor(attr("BleedOut", 0)))
		UI.setText(downedTimer, string.format("%d:%02d", secs // 60, secs % 60))
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
		setBuild(1 - remaining / total)
	else
		buildBar.Visible = false
		buildBar:SetAttribute("Total", nil)
	end

	if routePanel.Visible then
		refreshRoute()
	end
end

-- Build ---------------------------------------------------------------------------------

local function buildTop()
	-- Compass tab + clock.
	local top = UI.create("Frame", {
		Name = "Compass",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 4),
		Size = UDim2.fromOffset(230, 90),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	UI.autoScale(top)
	local tab = UI.card({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(220, 48),
		Parent = top,
	})
	headingLabel = UI.title("North", 28, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		Parent = tab,
	})
	local clock = UI.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 54),
		Size = UDim2.fromOffset(124, 30),
		BackgroundColor3 = T.BlueDark,
		BorderSizePixel = 0,
		Parent = top,
	}, { UI.round(), UI.stroke(T.White, 3) })
	clockLabel = UI.title("12:00 PM", 20, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		Parent = clock,
	})

	-- Right info card.
	local card = UI.card({
		Name = "Info",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 6),
		Size = UDim2.fromOffset(236, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = gui,
	})
	UI.autoScale(card)
	UI.padding(14, 10).Parent = card
	UI.list(Enum.FillDirection.Vertical, 4).Parent = card
	local altRow = UI.create(
		"Frame",
		{ Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 1, Parent = card }
	)
	UI.icon("mountain", { Size = UDim2.fromOffset(40, 40), Parent = altRow })
	altitudeLabel = UI.title("0 m", 32, {
		Position = UDim2.fromOffset(50, 0),
		Size = UDim2.new(1, -50, 1, 0),
		TextColor3 = T.Cyan,
		TextWrapped = false,
		Parent = altRow,
	})
	local tempRow = UI.create(
		"Frame",
		{ Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 2, Parent = card }
	)
	weatherIconHolder = UI.create("Frame", {
		Size = UDim2.fromOffset(40, 40),
		BackgroundTransparency = 1,
		Parent = tempRow,
	})
	tempLabel = UI.title("0°C", 28, {
		Position = UDim2.fromOffset(50, 0),
		Size = UDim2.new(0, 90, 1, 0),
		TextWrapped = false,
		Parent = tempRow,
	})
	tempFLabel = UI.title("32°F", 20, {
		Position = UDim2.fromOffset(140, 4),
		Size = UDim2.new(1, -140, 1, -4),
		TextColor3 = T.Muted,
		TextWrapped = false,
		Parent = tempRow,
	})
	weatherLabel = UI.label("", 14, { LayoutOrder = 3, TextWrapped = false, Parent = card })
	zoneLabel = UI.label("", 14, { LayoutOrder = 4, TextColor3 = T.Muted, TextWrapped = false, Parent = card })
	extrasLabel = UI.label("", 13, { LayoutOrder = 5, TextColor3 = T.Good, Visible = false, Parent = card })
end

local function buildStats()
	local card = UI.card({
		Name = "Stats",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -14, 1, -14),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Parent = gui,
	})
	UI.autoScale(card)
	UI.padding(10).Parent = card
	UI.list(Enum.FillDirection.Horizontal, 8).Parent = card
	makeStat(card, "Health", "heart", 1, { fg = Color3.fromRGB(255, 85, 100) })
	makeStat(card, "Warmth", "thermo", 2)
	makeStat(card, "Water", "drop", 3, { fg = Color3.fromRGB(110, 205, 255) })
	makeStat(card, "Food", "food", 4, { fg = Color3.fromRGB(255, 120, 90) })
	makeStat(card, "Energy", "bolt", 5, { fg = T.Yellow })
	makeStat(card, "Oxygen", "O2", 6)
	stats.Oxygen.cell.Visible = false

	injuriesRow = UI.create("Frame", {
		Name = "Injuries",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -14, 1, -134),
		Size = UDim2.fromOffset(460, 26),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		UI.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	UI.autoScale(injuriesRow)
end

local function buildBottom()
	local holder = UI.create("Frame", {
		Name = "Centre",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -110),
		Size = UDim2.fromOffset(640, 60),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	UI.autoScale(holder)
	statusLabel = UI.title("", 20, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, 0, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		Parent = holder,
	})
	staminaFrame, setStamina = UI.bar({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.fromOffset(300, 12),
		Visible = false,
		Parent = holder,
	}, Color3.fromRGB(150, 235, 90))
	UI.stroke(T.White, 2).Parent = staminaFrame

	hints = UI.label(
		if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
			then ""
			else "C climb  ·  Shift sprint  ·  G ping  ·  X set down  ·  1-4 quick use",
		12,
		{
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 16, 1, -10),
			Size = UDim2.fromOffset(420, 16),
			TextColor3 = T.White,
			TextWrapped = false,
			Parent = gui,
		}
	)
	UI.textStroke(T.BlueDeep, 1.5).Parent = hints

	buildBar, setBuild = UI.bar({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.62, 0),
		Size = UDim2.fromOffset(280, 18),
		Visible = false,
		Parent = gui,
	}, T.Cyan)
	UI.stroke(T.White, 3).Parent = buildBar
	UI.title("Building...", 18, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -4),
		Size = UDim2.fromOffset(280, 22),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = buildBar,
	})
end

local function buildLeft()
	local column = UI.create("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.fromOffset(70, 5 * 70),
		BackgroundTransparency = 1,
		Parent = gui,
	}, { UI.list(Enum.FillDirection.Vertical, 12) })
	UI.autoScale(column)

	tooltip = UI.pill("", T.BlueDark, {
		Size = UDim2.fromOffset(0, 30),
		TextSize = 14,
		Visible = false,
		ZIndex = 5,
		Parent = gui,
	})

	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local defs = {
		{ key = "Pack", icon = "pack", hint = "Tab", tip = "Backpack", action = InventoryController.toggle },
		{ key = "Gear", icon = "helmet", hint = "H", tip = "Gear toggles", action = GearMenuController.toggle },
		{ key = "Build", icon = "hammer", hint = "B", tip = "Build Book", action = BuildBookController.toggle },
		{ key = "Route", icon = "compass", hint = "M", tip = "Route and camps", action = toggleRoute },
		{ key = "Camera", icon = "camera", hint = "V", tip = "First / third person", action = toggleCamera },
	}
	for i, def in defs do
		local button = UI.roundButton(def.icon, 58, function()
			def.action()
		end, { Name = def.key, LayoutOrder = i, Parent = column })
		leftButtons[def.key] = button
		if not touchOnly then
			UI.create("TextLabel", {
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, 6, 1, 4),
				Size = UDim2.fromOffset(0, 20),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = T.BlueDark,
				Text = def.hint,
				TextColor3 = T.White,
				Font = T.Font,
				TextSize = 11,
				Parent = button,
			}, { UI.round(), UI.padding(6, 0), UI.stroke(T.White, 2) })
		end
		button.MouseEnter:Connect(function()
			hovered = def.key
			tooltip.Text = if def.key == "Pack" then packTip else def.tip
			local pos = button.AbsolutePosition
			local size = button.AbsoluteSize
			tooltip.Position = UDim2.fromOffset(pos.X + size.X + 12, pos.Y + size.Y / 2 - 15)
			tooltip.Visible = true
		end)
		button.MouseLeave:Connect(function()
			if hovered == def.key then
				hovered = nil
				tooltip.Visible = false
			end
		end)
	end
end

local function buildRoute()
	routeGui = UI.screen("Route", 3)
	routePanel = UI.panel("Route", UDim2.fromOffset(380, 420), routeGui)
	routePanel.AnchorPoint = Vector2.new(0, 0.5)
	routePanel.Position = UDim2.new(0, 100, 0.5, 0)
	UI.autoScale(routePanel)
	UI.header(routePanel, "ROUTE", "compass", function()
		ClientState.setPanel(nil)
	end)
	local list = UI.create("Frame", {
		Position = UDim2.fromOffset(20, 70),
		Size = UDim2.new(1, -40, 1, -130),
		BackgroundTransparency = 1,
		Parent = routePanel,
	}, { UI.list(Enum.FillDirection.Vertical, 8) })
	for i, name in campNames() do
		local row = UI.inset({ Size = UDim2.new(1, 0, 0, 48), LayoutOrder = i, Parent = list })
		local dot = UI.create("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 10, 0.5, 0),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = T.BlueDeep,
			BorderSizePixel = 0,
			Parent = row,
		}, { UI.round(), UI.stroke(T.White, 2) })
		UI.icon(if name == "Summit" then "mountain" else "flag", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.6, 0.6),
			Parent = dot,
		}, { accent = T.White })
		local label = UI.title(name, 20, {
			Position = UDim2.fromOffset(52, 0),
			Size = UDim2.new(1, -140, 1, 0),
			TextWrapped = false,
			Parent = row,
		})
		local state = UI.label("", 13, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 0),
			Size = UDim2.new(0, 80, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = row,
		})
		table.insert(routeRows, { dot = dot, name = label, state = state })
	end
	routeAltitude = UI.label("", 14, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -18),
		Size = UDim2.new(1, -40, 0, 36),
		TextColor3 = T.Muted,
		Parent = routePanel,
	})
end

local function buildDowned()
	downedOverlay = UI.create("Frame", {
		Name = "Downed",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(120, 0, 10),
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	})
	local card = UI.card({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(460, 270),
		Parent = downedOverlay,
	})
	UI.autoScale(card)
	UI.title("DOWNED", 48, {
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 52),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = T.Danger,
		Parent = card,
	})
	downedTimer = UI.title("0:00", 30, {
		Position = UDim2.fromOffset(0, 70),
		Size = UDim2.new(1, 0, 0, 34),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = card,
	})
	UI.label("Crawl toward a fire or your team. They can revive or carry you.", 15, {
		Position = UDim2.fromOffset(30, 110),
		Size = UDim2.new(1, -60, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = card,
	})
	local giveUp = UI.create("TextButton", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -22),
		Size = UDim2.fromOffset(280, 54),
		BackgroundColor3 = T.Orange,
		AutoButtonColor = false,
		Text = "",
		ClipsDescendants = true,
		Modal = true,
		Parent = card,
	}, { UI.corner(16), UI.stroke(T.White, 3) })
	local holdFill = UI.create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = T.Red,
		BorderSizePixel = 0,
		Parent = giveUp,
	})
	local holdText = UI.title("Hold to give up (evacuate)", 18, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 2,
		Parent = giveUp,
	})

	-- Hold-to-confirm so nobody gives up by accident. Works for mouse and touch.
	local holdStart: number? = nil
	local fired = false
	local function release()
		holdStart = nil
		fired = false
		holdFill.Size = UDim2.fromScale(0, 1)
		holdText.Text = "Hold to give up (evacuate)"
	end
	giveUp.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			holdStart = os.clock()
			holdText.Text = "Keep holding..."
		end
	end)
	giveUp.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			release()
		end
	end)
	RunService.Heartbeat:Connect(function()
		local started = holdStart
		if not started or fired then
			return
		end
		if not downedOverlay.Visible then
			release()
			return
		end
		local progress = (os.clock() - started) / GIVE_UP_HOLD
		holdFill.Size = UDim2.fromScale(math.clamp(progress, 0, 1), 1)
		if progress >= 1 then
			fired = true
			holdText.Text = "Evacuating..."
			local remote = Remotes.get("GiveUp") :: RemoteEvent
			remote:FireServer()
		end
	end)
end

function HUDController.Init()
	gui = UI.screen("HUD", 1)
	teammates = UI.create("Frame", {
		Name = "Team",
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.fromOffset(240, 200),
		BackgroundTransparency = 1,
		Parent = gui,
	}, { UI.list(Enum.FillDirection.Vertical, 4) })
	UI.autoScale(teammates)
	buildTop()
	buildStats()
	buildBottom()
	buildLeft()
	buildRoute()
	buildDowned()
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
	player:GetAttributeChangedSignal("Checkpoint"):Connect(refreshRoute)
	Players.PlayerRemoving:Connect(function(other)
		local row = mateRows[other]
		if row then
			row.frame:Destroy()
			mateRows[other] = nil
		end
	end)
	task.spawn(function()
		while true do
			refreshTeammates()
			task.wait(1)
		end
	end)

	ClientState.PanelChanged:Connect(function(name)
		routePanel.Visible = name == ROUTE_PANEL
		routeGui.Enabled = name ~= "Title"
		if routePanel.Visible then
			refreshRoute()
		end
		local active = {
			Pack = name == "Inventory",
			Gear = name == "Gear",
			Build = name == "BuildBook",
			Route = name == ROUTE_PANEL,
		}
		for key, button in leftButtons do
			local stroke = button:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = if active[key] then T.Cyan else T.White
			end
		end
	end)

	ContextActionService:BindAction("ToggleRoute", function(_, state)
		if state == Enum.UserInputState.Begin then
			toggleRoute()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.M)
	ContextActionService:BindAction("ToggleCamera", function(_, state)
		if state == Enum.UserInputState.Begin then
			toggleCamera()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.V)
end

return HUDController
