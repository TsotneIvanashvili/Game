--!strict
-- End-of-section summary. When you reach the Ridge Col the server sends ExpeditionSummary
-- with your stats (ExpeditionService.summaryFor); this shows them in a centred panel until
-- you close it. Display only: nobody is teleported or reset from here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)

local SummaryController = {}

local PANEL_NAME = "Summary"
local T = UI.Theme

local panel: Frame
local subtitle: TextLabel
local rows: Frame

local function num(v: any): number
	return if typeof(v) == "number" then v else 0
end

local function formatTime(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", s // 60, s % 60)
end

local function addRow(order: number, label: string, value: string)
	local row = UI.create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = rows,
	})
	UI.label(label, 14, {
		Size = UDim2.new(0.45, 0, 0, 22),
		TextColor3 = T.Muted,
		Parent = row,
	})
	UI.label(value, 14, {
		Position = UDim2.fromScale(0.45, 0),
		Size = UDim2.new(0.55, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = T.FontBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})
end

local function render(stats: { [string]: any })
	for _, child in rows:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	subtitle.Text = if typeof(stats.name) == "string"
		then stats.name .. "  ·  Section complete"
		else "Section complete"

	local weather = {}
	if typeof(stats.weatherSurvived) == "table" then
		for _, name in stats.weatherSurvived do
			table.insert(weather, tostring(name))
		end
	end

	local entries = {
		{ "Max elevation", string.format("%d m", num(stats.maxElevationM)) },
		{ "Distance", string.format("%d m", num(stats.distanceM)) },
		{ "Time", formatTime(num(stats.timeSeconds)) },
		{ "Highest checkpoint", tostring(num(stats.highestCheckpoint)) },
		{ "Weather survived", if #weather > 0 then table.concat(weather, ", ") else "None" },
		{ "Disasters survived", tostring(num(stats.disastersSurvived)) },
		{ "Teammates rescued", tostring(num(stats.teammatesRescued)) },
		{ "Items consumed", tostring(num(stats.itemsConsumed)) },
		{ "Injuries", tostring(num(stats.injuries)) },
		{ "Resources collected", tostring(num(stats.resourcesCollected)) },
	}
	for i, entry in entries do
		addRow(i, entry[1], entry[2])
	end
end

local function close()
	if ClientState.openPanel == PANEL_NAME then
		ClientState.setPanel(nil)
	end
end

function SummaryController.Init()
	local gui = UI.screen("ExpeditionSummary", 4)
	panel = UI.panel("SummaryPanel", UDim2.fromOffset(440, 470), gui)
	UI.autoScale(panel)
	UI.label("RIDGE COL REACHED", 24, {
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = T.FontBold,
		TextColor3 = T.Accent,
		Parent = panel,
	})
	subtitle = UI.label("", 14, {
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = T.Muted,
		Parent = panel,
	})
	rows = UI.create("Frame", {
		Position = UDim2.fromOffset(28, 86),
		Size = UDim2.new(1, -56, 1, -150),
		BackgroundTransparency = 1,
		Parent = panel,
	}, { UI.list(Enum.FillDirection.Vertical, 4) })
	UI.button("Close", close, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(140, 34),
		Modal = true, -- frees the mouse while the panel is open
		Parent = panel,
	})
end

function SummaryController.Start()
	ClientState.PanelChanged:Connect(function(name)
		panel.Visible = name == PANEL_NAME
	end)
	local summary = Remotes.get("ExpeditionSummary") :: RemoteEvent
	summary.OnClientEvent:Connect(function(stats: any)
		if typeof(stats) ~= "table" then
			return
		end
		render(stats)
		ClientState.setPanel(PANEL_NAME)
		panel.Visible = true
	end)
end

return SummaryController
