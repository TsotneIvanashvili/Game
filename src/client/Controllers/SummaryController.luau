--!strict
-- End-of-expedition summary. When you reach the summit the server sends ExpeditionSummary
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
local tiles: Frame
local weatherLabel: TextLabel

local function num(v: any): number
	return if typeof(v) == "number" then v else 0
end

local function formatTime(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s >= 3600 then
		return string.format("%d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60)
	end
	return string.format("%02d:%02d", s // 60, s % 60)
end

local function addTile(order: number, label: string, value: string, highlight: boolean?)
	local tile = UI.inset({ LayoutOrder = order, Parent = tiles })
	UI.label(label, 12, {
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -24, 0, 16),
		TextColor3 = T.Muted,
		Parent = tile,
	})
	UI.title(value, 22, {
		Position = UDim2.fromOffset(12, 24),
		Size = UDim2.new(1, -24, 0, 28),
		TextColor3 = if highlight then T.Cyan else T.White,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = tile,
	})
end

local function render(stats: { [string]: any })
	UI.clear(tiles)
	subtitle.Text = if typeof(stats.name) == "string"
		then stats.name .. "  ·  Expedition complete"
		else "Expedition complete"

	local weather = {}
	if typeof(stats.weatherSurvived) == "table" then
		for _, name in stats.weatherSurvived do
			table.insert(weather, tostring(name))
		end
	end

	local entries = {
		{ "Max elevation", string.format("%d m", num(stats.maxElevationM)), true },
		{ "Time", formatTime(num(stats.timeSeconds)), true },
		{ "Distance", string.format("%d m", num(stats.distanceM)) },
		{ "Highest checkpoint", tostring(num(stats.highestCheckpoint)) },
		{ "Disasters survived", tostring(num(stats.disastersSurvived)) },
		{ "Teammates rescued", tostring(num(stats.teammatesRescued)) },
		{ "Items consumed", tostring(num(stats.itemsConsumed)) },
		{ "Injuries", tostring(num(stats.injuries)) },
		{ "Resources collected", tostring(num(stats.resourcesCollected)) },
	}
	for i, entry in entries do
		addTile(i, entry[1], entry[2], entry[3] == true)
	end
	weatherLabel.Text = "Weather survived: " .. (if #weather > 0 then table.concat(weather, ", ") else "None")
end

local function close()
	if ClientState.openPanel == PANEL_NAME then
		ClientState.setPanel(nil)
	end
end

function SummaryController.Init()
	local gui = UI.screen("ExpeditionSummary", 4)
	panel = UI.panel("SummaryPanel", UDim2.fromOffset(560, 600), gui)
	UI.autoScale(panel)
	UI.icon("mountain", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14),
		Size = UDim2.fromOffset(64, 64),
		Parent = panel,
	})
	UI.title("SUMMIT REACHED", 40, {
		Position = UDim2.fromOffset(0, 76),
		Size = UDim2.new(1, 0, 0, 46),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		Parent = panel,
	})
	subtitle = UI.label("", 15, {
		Position = UDim2.fromOffset(0, 122),
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = T.Muted,
		Parent = panel,
	})
	tiles = UI.create("Frame", {
		Position = UDim2.fromOffset(28, 154),
		Size = UDim2.new(1, -56, 0, 5 * 66),
		BackgroundTransparency = 1,
		Parent = panel,
	}, {
		UI.create("UIGridLayout", {
			CellSize = UDim2.new(0.5, -5, 0, 58),
			CellPadding = UDim2.fromOffset(10, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	weatherLabel = UI.label("", 13, {
		Position = UDim2.fromOffset(28, 154 + 5 * 66 + 2),
		Size = UDim2.new(1, -56, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = panel,
	})
	UI.button("Continue", close, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(200, 50),
		TextSize = 24,
		BackgroundColor3 = T.Green,
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
