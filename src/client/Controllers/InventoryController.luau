--!strict
-- The backpack screen (Tab / I). Layout per design section 48:
--   left: worn equipment slots        centre: pack contents by category
--   right: selected item + body status bottom: weight and slots
-- Every button sends an intent to the server; the UI redraws from the next InventorySync.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local ItemDefs = require(Shared.Config.ItemDefs)
local GameConfig = require(Shared.Config.GameConfig)
local InjuryDefs = require(Shared.Config.InjuryDefs)
local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)
local Notifications = require(script.Parent.NotificationController)

local InventoryController = {}

local player = Players.LocalPlayer
local T = UI.Theme
local SLOTS = { "Head", "Face", "BaseLayer", "Jacket", "Gloves", "Pants", "Boots" }
local SLOT_NAMES = {
	Head = "Head",
	Face = "Face",
	BaseLayer = "Base layer",
	Jacket = "Jacket",
	Gloves = "Gloves",
	Pants = "Pants",
	Boots = "Boots",
}
local CATEGORIES = { "All", "Food", "Drink", "Medical", "Tool", "Material", "Clothing" }

local panel: Frame
local wornList: Frame
local grid: ScrollingFrame
local detail: Frame
local bodyStatus: TextLabel
local footer: TextLabel
local tabs: Frame
local selectedUid: string? = nil
local category = "All"
local busy = false

local function invoke(action: string, uid: string, arg: number?)
	if busy then
		return
	end
	busy = true
	local remote = Remotes.get("Inventory") :: RemoteFunction
	local ok, success, message = pcall(function()
		return remote:InvokeServer(action, uid, arg)
	end)
	busy = false
	if ok and message then
		Notifications.toast(message, if success then "good" else "warn")
	end
end

local function nearbyTeammates(): { Player }
	local out = {}
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return out
	end
	for _, other in Players:GetPlayers() do
		local r = other ~= player
			and other.Character
			and other.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r and (r.Position - root.Position).Magnitude <= GameConfig.GIVE_RANGE then
			table.insert(out, other)
		end
	end
	return out
end

local function clear(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function stackLine(stack: any, def: ItemDefs.ItemDef): string
	if def.container and stack.data then
		local d = stack.data
		local state = {}
		table.insert(state, string.format("%d / %d ml", d.ml or 0, def.container.capacityMl))
		if (d.ml or 0) > 0 then
			table.insert(state, if d.treated then "treated" else "UNTREATED")
			if d.hot then
				table.insert(state, "hot")
			end
		end
		return table.concat(state, " · ")
	end
	if def.durability and stack.data and stack.data.uses then
		return string.format("%d uses left", stack.data.uses)
	end
	return ""
end

local function renderDetail(snapshot: any)
	clear(detail)
	UI.list(Enum.FillDirection.Vertical, 6).Parent = detail
	local stack = nil
	for _, s in snapshot.stacks do
		if s.uid == selectedUid then
			stack = s
		end
	end
	if not stack then
		UI.label("Select an item.", 14, { TextColor3 = T.Muted, Parent = detail })
		return
	end
	local def = ItemDefs.ById[stack.itemId]
	if not def then
		return
	end
	UI.label(def.name .. (if stack.qty > 1 then "  x" .. stack.qty else ""), 18, { Font = T.FontBold, Parent = detail })
	UI.label(
		def.description,
		13,
		{ TextColor3 = T.Muted, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = detail }
	)
	local extra = stackLine(stack, def)
	UI.label(
		string.format(
			"%s  ·  %s each%s",
			def.category,
			UI.formatKg(def.weight),
			if extra ~= "" then "  ·  " .. extra else ""
		),
		12,
		{ TextColor3 = T.Muted, Parent = detail }
	)
	if def.clothing then
		local c = def.clothing
		local regions = {}
		for region, v in c.insulation do
			table.insert(regions, region .. " " .. v)
		end
		UI.label(
			string.format(
				"Warmth: %s  ·  Wind %d%%  ·  Water %d%%",
				table.concat(regions, ", "),
				c.windproof * 100,
				c.waterproof * 100
			),
			12,
			{ TextColor3 = T.Cold, Parent = detail }
		)
	end

	local actions = UI.create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = detail,
	}, {
		UI.create("UIGridLayout", { CellSize = UDim2.new(0.5, -4, 0, 30), CellPadding = UDim2.fromOffset(6, 6) }),
	})
	local uid = stack.uid
	if def.clothing then
		UI.button("Wear", function()
			invoke("Equip", uid)
		end, { Parent = actions })
	elseif def.holdable then
		if snapshot.heldUid == uid then
			UI.button("Stow", function()
				invoke("Stow", uid)
			end, { Parent = actions })
		else
			UI.button("Hold", function()
				invoke("Hold", uid)
			end, { Parent = actions })
		end
	elseif def.consumable or def.container or def.id == "purification_tabs" then
		UI.button(if def.category == "Drink" then "Drink" else "Use", function()
			invoke("Use", uid)
		end, { Parent = actions })
	end
	UI.button("Drop" .. (if stack.qty > 1 then " 1" else ""), function()
		invoke("Drop", uid, 1)
	end, { Parent = actions })
	if stack.qty > 1 then
		UI.button("Drop all", function()
			invoke("Drop", uid, stack.qty)
		end, { Parent = actions })
	end
	for _, mate in nearbyTeammates() do
		UI.button("Give " .. mate.DisplayName, function()
			invoke("Give", uid, mate.UserId)
		end, { Parent = actions })
		if def.treatOther then
			UI.button("Treat " .. mate.DisplayName, function()
				invoke("Treat", uid, mate.UserId)
			end, { Parent = actions })
		end
	end
end

local function renderBody()
	local parts = {}
	for _, region in { "Head", "Torso", "Hands", "Legs", "Feet" } do
		table.insert(parts, string.format("%s %d", region, math.floor(player:GetAttribute("Warm" .. region) or 100)))
	end
	local injuries = {}
	for entry in string.gmatch(player:GetAttribute("Injuries") or "", "[^,]+") do
		local id = entry:gsub("%*$", "")
		local def = InjuryDefs.ById[id]
		if def then
			table.insert(injuries, def.name .. (if entry:sub(-1) == "*" then " (splinted)" else ""))
		end
	end
	bodyStatus.Text = string.format(
		"Body warmth\n%s\n\nWet: %d%%\n\n%s",
		table.concat(parts, "  ·  "),
		math.floor((player:GetAttribute("Wetness") or 0) * 100),
		if #injuries > 0 then "Injuries:\n" .. table.concat(injuries, "\n") else "No injuries"
	)
end

local function render()
	local snapshot = ClientState.inventory
	if not snapshot or not panel.Visible then
		return
	end
	-- Worn slots.
	clear(wornList)
	UI.list(Enum.FillDirection.Vertical, 4).Parent = wornList
	for i, slot in SLOTS do
		local itemId = snapshot.worn[slot]
		local def = itemId and ItemDefs.ById[itemId]
		local row = UI.create(
			"Frame",
			{ Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = T.PanelLight, LayoutOrder = i, Parent = wornList },
			{ UI.corner(5) }
		)
		UI.label(
			SLOT_NAMES[slot],
			11,
			{ Position = UDim2.fromOffset(8, 1), Size = UDim2.new(1, -16, 0, 14), TextColor3 = T.Muted, Parent = row }
		)
		UI.label(
			if def then def.name else "-",
			13,
			{ Position = UDim2.fromOffset(8, 14), Size = UDim2.new(1, -40, 0, 18), Parent = row }
		)
		if def then
			UI.button("x", function()
				invoke("Unequip", slot)
			end, {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -4, 0.5, 0),
				Size = UDim2.fromOffset(24, 24),
				Parent = row,
			})
		end
	end
	local pack = ItemDefs.ById[snapshot.backpackId]
	UI.label(
		"Pack: " .. (if pack then pack.name else "?"),
		12,
		{ LayoutOrder = 99, TextColor3 = T.Muted, Parent = wornList }
	)

	-- Category tabs.
	for _, b in tabs:GetChildren() do
		if b:IsA("TextButton") then
			b.BackgroundColor3 = if b.Name == category then T.Accent else T.PanelLight
		end
	end

	-- Grid.
	clear(grid)
	UI.create("UIGridLayout", {
		CellSize = UDim2.fromOffset(92, 92),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	for i, stack in snapshot.stacks do
		local def = ItemDefs.ById[stack.itemId]
		if def and (category == "All" or def.category == category) then
			local tile = UI.create("TextButton", {
				Text = "",
				LayoutOrder = i,
				BackgroundColor3 = if stack.uid == selectedUid then T.Line else T.PanelLight,
				AutoButtonColor = true,
				Parent = grid,
			}, { UI.corner(6) })
			UI.create(
				"Frame",
				{ Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = def.color, BorderSizePixel = 0, Parent = tile }
			)
			UI.label(def.glyph, 24, {
				Position = UDim2.fromOffset(0, 10),
				Size = UDim2.new(1, 0, 0, 30),
				TextXAlignment = Enum.TextXAlignment.Center,
				Font = T.FontBold,
				TextColor3 = def.color,
				Parent = tile,
			})
			UI.label(def.name, 11, {
				Position = UDim2.fromOffset(4, 44),
				Size = UDim2.new(1, -8, 0, 28),
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = tile,
			})
			if stack.qty > 1 then
				UI.label("x" .. stack.qty, 12, {
					Position = UDim2.new(1, -30, 0, 6),
					Size = UDim2.fromOffset(26, 14),
					TextXAlignment = Enum.TextXAlignment.Right,
					Font = T.FontBold,
					Parent = tile,
				})
			end
			if snapshot.heldUid == stack.uid then
				UI.label("IN HAND", 10, {
					Position = UDim2.new(0, 4, 1, -16),
					Size = UDim2.new(1, -8, 0, 14),
					TextXAlignment = Enum.TextXAlignment.Center,
					TextColor3 = T.Accent,
					Parent = tile,
				})
			end
			tile.Activated:Connect(function()
				selectedUid = stack.uid
				render()
			end)
		end
	end

	renderDetail(snapshot)
	renderBody()
	footer.Text = string.format(
		"%s / %d kg   ·   %d / %d slots",
		UI.formatKg(snapshot.weight),
		snapshot.weightLimit,
		#snapshot.stacks,
		snapshot.slots
	)
	footer.TextColor3 = if snapshot.weight > snapshot.weightLimit then T.Danger else T.Text
end

function InventoryController.toggle(open: boolean?)
	local shouldOpen = if open == nil then not panel.Visible else open
	if shouldOpen then
		ClientState.setPanel("Inventory")
	elseif ClientState.openPanel == "Inventory" then
		ClientState.setPanel(nil)
	end
end

function InventoryController.Init()
	local gui = UI.screen("Backpack", 3)
	panel = UI.panel("Backpack", UDim2.fromOffset(940, 540), gui)
	UI.autoScale(panel)
	UI.label(
		"BACKPACK",
		18,
		{ Position = UDim2.fromOffset(16, 10), Size = UDim2.new(0, 200, 0, 24), Font = T.FontBold, Parent = panel }
	)
	UI.button("Close", function()
		InventoryController.toggle(false)
	end, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 10),
		Size = UDim2.fromOffset(70, 26),
		Parent = panel,
		Modal = true,
	})

	wornList = UI.create("Frame", {
		Position = UDim2.fromOffset(16, 46),
		Size = UDim2.new(0, 200, 1, -100),
		BackgroundTransparency = 1,
		Parent = panel,
	})

	tabs = UI.create("Frame", {
		Position = UDim2.fromOffset(228, 46),
		Size = UDim2.new(0, 440, 0, 26),
		BackgroundTransparency = 1,
		Parent = panel,
	}, {
		UI.list(Enum.FillDirection.Horizontal, 4),
	})
	for i, cat in CATEGORIES do
		UI.button(cat, function()
			category = cat
			render()
		end, { Name = cat, Size = UDim2.fromOffset(58, 24), TextSize = 12, LayoutOrder = i, Parent = tabs })
	end
	grid = UI.create("ScrollingFrame", {
		Position = UDim2.fromOffset(228, 78),
		Size = UDim2.new(0, 440, 1, -132),
		BackgroundTransparency = 1,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = panel,
	})
	detail = UI.create("Frame", {
		Position = UDim2.new(0, 680, 0, 46),
		Size = UDim2.new(0, 244, 0, 250),
		BackgroundTransparency = 1,
		Parent = panel,
	})
	bodyStatus = UI.label("", 12, {
		Position = UDim2.new(0, 680, 0, 306),
		Size = UDim2.new(0, 244, 0, 180),
		TextColor3 = T.Muted,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = panel,
	})
	footer = UI.label("", 15, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -12),
		Size = UDim2.new(1, -32, 0, 22),
		Font = T.FontBold,
		Parent = panel,
	})
end

function InventoryController.Start()
	local sync = Remotes.get("InventorySync") :: RemoteEvent
	sync.OnClientEvent:Connect(function(snapshot)
		ClientState.setInventory(snapshot)
	end)
	ClientState.InventoryChanged:Connect(render)
	ClientState.PanelChanged:Connect(function(name)
		panel.Visible = name == "Inventory"
		if panel.Visible then
			render()
		end
	end)
	task.spawn(function()
		local snapshot = (Remotes.get("GetSnapshot") :: RemoteFunction):InvokeServer()
		while not snapshot do
			task.wait(1)
			snapshot = (Remotes.get("GetSnapshot") :: RemoteFunction):InvokeServer()
		end
		if not ClientState.inventory then
			ClientState.setInventory(snapshot)
		end
	end)
	ContextActionService:BindAction("ToggleBackpack", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			InventoryController.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.Tab, Enum.KeyCode.I)
	ContextActionService:SetTitle("ToggleBackpack", "Pack")
end

return InventoryController
