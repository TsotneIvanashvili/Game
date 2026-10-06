--!strict
-- Outfitter and supply-crate panels, opened by the server when you use those prompts.
-- The outfitter renders like a shop: big cards grouped by slot (Head, Face, Goggles, ...,
-- Packs, Supplies). The panels only send requests; the server checks you're still standing
-- at the rack/crate and decides everything.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local ItemDefs = require(Shared.Config.ItemDefs)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)
local Notifications = require(script.Parent.NotificationController)

local PanelController = {}

local T = UI.Theme
local player = Players.LocalPlayer

-- Outfitter sections, in shop order.
local GROUPS = {
	{ key = "Head", title = "Head", icon = "helmet" },
	{ key = "Face", title = "Face", icon = "mask" },
	{ key = "Eyes", title = "Goggles", icon = "goggles" },
	{ key = "BaseLayer", title = "Base layer", icon = "shirt" },
	{ key = "Jacket", title = "Jackets", icon = "shirt" },
	{ key = "Gloves", title = "Gloves", icon = "glove" },
	{ key = "Pants", title = "Pants", icon = "pants" },
	{ key = "Boots", title = "Boots", icon = "boot" },
	{ key = "Backpack", title = "Packs", icon = "pack" },
	{ key = "Other", title = "Supplies", icon = "box" },
}

local panel: Frame
local title: TextLabel
local subtitle: TextLabel
local list: ScrollingFrame
local current: { kind: string, data: any }? = nil
local openedAt: Vector3? = nil

local function close()
	if ClientState.openPanel == "Outfitter" or ClientState.openPanel == "Supply" then
		ClientState.setPanel(nil)
	end
end

local function groupOf(def: ItemDefs.ItemDef): string
	if def.clothing then
		return def.clothing.slot
	elseif def.backpack then
		return "Backpack"
	end
	return "Other"
end

local function statLines(def: ItemDefs.ItemDef): string
	if def.clothing then
		local c = def.clothing
		local warmth = 0
		for _, v in c.insulation do
			warmth += v
		end
		return string.format(
			"Warmth +%d\nWind %d%%  ·  Water %d%%\n%.2f kg",
			warmth,
			c.windproof * 100,
			c.waterproof * 100,
			def.weight
		)
	elseif def.backpack then
		return string.format(
			"%d slots\nCarries %d kg\n%.1f kg empty",
			def.backpack.slots,
			def.backpack.weightLimit,
			def.weight
		)
	end
	return string.format("%s\n%.2f kg", def.category, def.weight)
end

local function card(
	parent: Instance,
	def: ItemDefs.ItemDef,
	order: number,
	buttonText: string,
	enabled: boolean,
	locked: boolean,
	onClick: () -> ()
)
	local c = UI.inset({
		Size = UDim2.fromOffset(170, 236),
		LayoutOrder = order,
		Parent = parent,
	})
	UI.stroke(T.White, 2).Parent = c
	UI.itemBadge(def, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(68, 68),
		Parent = c,
	})
	if locked then
		local lockDisc = UI.create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 28, 0, 72),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = T.BlueDeep,
			BorderSizePixel = 0,
			ZIndex = 2,
			Parent = c,
		}, { UI.round(), UI.stroke(T.White, 2) })
		UI.icon("lock", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.62, 0.62),
			Parent = lockDisc,
		}, { bg = T.BlueDeep })
	end
	UI.title(def.name, 17, {
		Position = UDim2.fromOffset(8, 86),
		Size = UDim2.new(1, -16, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Parent = c,
	})
	UI.label(statLines(def), 12, {
		Position = UDim2.fromOffset(8, 128),
		Size = UDim2.new(1, -16, 0, 52),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = T.Muted,
		Parent = c,
	})
	local b = UI.button(buttonText, onClick, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.new(1, -20, 0, 38),
		TextSize = if #buttonText > 14 then 13 else 17,
		BackgroundColor3 = T.Green,
		Parent = c,
	})
	UI.setButtonEnabled(b, enabled, T.Green)
end

local function section(order: number, text: string, iconKind: string): Frame
	local holder = UI.create("Frame", {
		Size = UDim2.new(1, -12, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = list,
	}, { UI.list(Enum.FillDirection.Vertical, 8) })
	local head = UI.create("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = holder,
	})
	UI.icon(iconKind, { Size = UDim2.fromOffset(26, 26), Position = UDim2.fromOffset(2, 2), Parent = head })
	UI.title(text, 22, { Position = UDim2.fromOffset(36, 0), Size = UDim2.new(1, -36, 1, 0), Parent = head })
	return UI.create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = holder,
	}, {
		UI.create("UIGridLayout", {
			CellSize = UDim2.fromOffset(170, 236),
			CellPadding = UDim2.fromOffset(12, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
end

local function render()
	local open = current
	if not open then
		return
	end
	UI.clear(list)
	local snapshot = ClientState.inventory
	if open.kind == "Outfitter" then
		title.Text = "OUTFITTER"
		subtitle.Text = "Swap gear for free at base camp. Weight is the real cost."
		local rank = open.data.rankIndex or 1
		local byGroup: { [string]: { string } } = {}
		for _, itemId in open.data.stock do
			local def = ItemDefs.ById[itemId]
			if def then
				local key = groupOf(def)
				byGroup[key] = byGroup[key] or {}
				table.insert(byGroup[key], itemId)
			end
		end
		for g, group in GROUPS do
			local ids = byGroup[group.key]
			if ids then
				local grid = section(g, group.title, group.icon)
				for i, itemId in ids do
					local def = ItemDefs.ById[itemId]
					local locked = rank < def.unlockRank
					local text, enabled = "Take", true
					if locked then
						local rankDef = ProgressionConfig.Ranks[def.unlockRank]
						text, enabled = if rankDef then rankDef.name else "Locked", false
					elseif def.clothing then
						local wearing = snapshot and snapshot.worn[def.clothing.slot] == itemId
						text, enabled = if wearing then "Wearing" else "Wear", not wearing
					elseif def.backpack then
						local using = snapshot and snapshot.backpackId == itemId
						text, enabled = if using then "Using" else "Use pack", not using
					elseif open.data.taken[itemId] then
						text, enabled = "Taken", false
					end
					card(grid, def, i, text, enabled, locked, function()
						if not enabled then
							return
						end
						local outfit = Remotes.get("Outfit") :: RemoteFunction
						local ok, success, message = pcall(function()
							return outfit:InvokeServer(itemId)
						end)
						if ok then
							if success and not def.clothing and not def.backpack then
								open.data.taken[itemId] = true
							end
							if message then
								Notifications.toast(message, if success then "good" else "warn")
							end
						end
						render()
					end)
				end
			end
		end
	else
		title.Text = "SUPPLY CRATE"
		subtitle.Text = "Your share for this expedition."
		local ids = {}
		for itemId in open.data.remaining do
			table.insert(ids, itemId)
		end
		table.sort(ids)
		local grid = section(1, "Supplies", "box")
		for i, itemId in ids do
			local def = ItemDefs.ById[itemId]
			local left = open.data.remaining[itemId]
			if def then
				card(
					grid,
					def,
					i,
					if left > 0 then "Take (" .. left .. " left)" else "None left",
					left > 0,
					false,
					function()
						if open.data.remaining[itemId] <= 0 then
							return
						end
						local supply = Remotes.get("Supply") :: RemoteFunction
						local ok, success, message = pcall(function()
							return supply:InvokeServer(open.data.crateId, itemId)
						end)
						if ok and success then
							open.data.remaining[itemId] -= 1
						elseif ok and message then
							Notifications.toast(message, "warn")
						end
						render()
					end
				)
			end
		end
	end
end

function PanelController.Init()
	local gui = UI.screen("Panels", 3)
	panel = UI.panel("Panel", UDim2.fromOffset(840, 580), gui)
	UI.autoScale(panel)
	title = UI.header(panel, "", "box", close)
	subtitle = UI.label("", 14, {
		Position = UDim2.fromOffset(64, 52),
		Size = UDim2.new(1, -140, 0, 18),
		TextColor3 = T.Muted,
		Parent = panel,
	})
	local holder = UI.inset({
		Position = UDim2.fromOffset(18, 80),
		Size = UDim2.new(1, -36, 1, -98),
		BackgroundColor3 = T.BlueDeep,
		Parent = panel,
	})
	list = UI.create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = T.White,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = holder,
	}, { UI.padding(14), UI.list(Enum.FillDirection.Vertical, 16) })
end

function PanelController.Start()
	local openRemote = Remotes.get("OpenPanel") :: RemoteEvent
	openRemote.OnClientEvent:Connect(function(kind: string, data: any)
		if kind ~= "Outfitter" and kind ~= "Supply" then
			return
		end
		current = { kind = kind, data = data }
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		openedAt = root and root.Position
		ClientState.setPanel(kind)
		if panel.Visible then
			render() -- same panel kind already open: setPanel was a no-op
		end
	end)
	ClientState.PanelChanged:Connect(function(name)
		panel.Visible = name == "Outfitter" or name == "Supply"
		if panel.Visible then
			render()
		end
	end)
	ClientState.InventoryChanged:Connect(function()
		if panel.Visible then
			render()
		end
	end)
	-- Walking away closes the panel.
	RunService.Heartbeat:Connect(function()
		if panel.Visible and openedAt then
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not root or (root.Position - openedAt).Magnitude > 14 then
				close()
			end
		end
	end)
end

return PanelController
