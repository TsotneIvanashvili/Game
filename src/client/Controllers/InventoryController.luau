--!strict
-- The backpack screen (Tab / I, or the pack button on the left edge). Layout:
--   left: worn equipment slots        centre: pack contents by category
--   right: selected item + body status bottom: weight bar and slots
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
local SLOTS = { "Head", "Face", "Eyes", "BaseLayer", "Jacket", "Gloves", "Pants", "Boots" }
local SLOT_NAMES = {
	Head = "Head",
	Face = "Face",
	Eyes = "Goggles",
	BaseLayer = "Base layer",
	Jacket = "Jacket",
	Gloves = "Gloves",
	Pants = "Pants",
	Boots = "Boots",
}
local CATEGORIES = { "All", "Food", "Drink", "Medical", "Tool", "Material", "Clothing" }
local REGIONS = { "Head", "Torso", "Hands", "Legs", "Feet" }

local panel: Frame
local wornList: Frame
local packLabel: TextLabel
local grid: ScrollingFrame
local detail: Frame
local tabs: Frame
local footerText: TextLabel
local setWeightBar: (number, Color3?) -> ()
local bodyBars: { [string]: (number, Color3?) -> () } = {}
local bodyValues: { [string]: TextLabel } = {}
local wetLabel: TextLabel
local injuryLabel: TextLabel
local selectedUid: string? = nil
local category = "All"
local busy = false

-- Sends an Inventory request (Use/Drop/Equip/Unequip/Give/Treat/Hold/Stow) and toasts the
-- server's answer. Also used by the hotbar. The server decides every effect.
function InventoryController.invoke(action: string, uid: string, arg: number?)
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

local invoke = InventoryController.invoke

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
	UI.clear(detail)
	local stack = nil
	for _, s in snapshot.stacks do
		if s.uid == selectedUid then
			stack = s
		end
	end
	if not stack then
		UI.label("Select an item to see what it does.", 14, {
			Size = UDim2.new(1, 0, 0, 40),
			TextColor3 = T.Muted,
			Parent = detail,
		})
		return
	end
	local def = ItemDefs.ById[stack.itemId]
	if not def then
		return
	end
	local head = UI.create("Frame", {
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = detail,
	})
	UI.itemBadge(def, { Size = UDim2.fromOffset(52, 52), Parent = head })
	UI.title(def.name .. (if stack.qty > 1 then "  x" .. stack.qty else ""), 20, {
		Position = UDim2.fromOffset(62, 0),
		Size = UDim2.new(1, -62, 1, 0),
		Parent = head,
	})
	UI.label(def.description, 13, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextColor3 = T.Muted,
		LayoutOrder = 2,
		Parent = detail,
	})
	local extra = stackLine(stack, def)
	UI.label(
		string.format(
			"%s  ·  %s each%s",
			def.category,
			UI.formatKg(def.weight),
			if extra ~= "" then "  ·  " .. extra else ""
		),
		12,
		{ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = detail }
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
			{
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextColor3 = T.Cold,
				LayoutOrder = 4,
				Parent = detail,
			}
		)
	end

	local actions = UI.create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 5,
		Parent = detail,
	}, {
		UI.create("UIGridLayout", {
			CellSize = UDim2.new(0.5, -4, 0, 36),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local uid = stack.uid
	local function action(text: string, fn: () -> (), color: Color3?)
		UI.button(text, fn, { TextSize = 15, BackgroundColor3 = color or T.BlueLight, Parent = actions })
	end
	if def.clothing then
		action("Wear", function()
			invoke("Equip", uid)
		end, T.Green)
	elseif def.holdable then
		if snapshot.heldUid == uid then
			action("Stow", function()
				invoke("Stow", uid)
			end, T.Green)
		else
			action("Hold", function()
				invoke("Hold", uid)
			end, T.Green)
		end
	elseif def.consumable or def.container or def.id == "purification_tabs" then
		action(if def.category == "Drink" then "Drink" else "Use", function()
			invoke("Use", uid)
		end, T.Green)
	end
	action("Drop" .. (if stack.qty > 1 then " 1" else ""), function()
		invoke("Drop", uid, 1)
	end)
	if stack.qty > 1 then
		action("Drop all", function()
			invoke("Drop", uid, stack.qty)
		end)
	end
	for _, mate in nearbyTeammates() do
		action("Give " .. mate.DisplayName, function()
			invoke("Give", uid, mate.UserId)
		end)
		if def.treatOther then
			action("Treat " .. mate.DisplayName, function()
				invoke("Treat", uid, mate.UserId)
			end, T.Orange)
		end
	end
end

local function warmthColor(w: number): Color3
	if w > 70 then
		return Color3.fromRGB(255, 160, 60)
	elseif w > 50 then
		return Color3.fromRGB(245, 210, 120)
	elseif w > 30 then
		return Color3.fromRGB(140, 200, 255)
	end
	return Color3.fromRGB(90, 150, 255)
end

local function renderBody()
	for _, region in REGIONS do
		local w = math.floor(player:GetAttribute("Warm" .. region) or 100)
		bodyBars[region](w / 100, warmthColor(w))
		UI.setText(bodyValues[region], tostring(w))
	end
	UI.setText(wetLabel, string.format("Wet  %d%%", math.floor((player:GetAttribute("Wetness") or 0) * 100)))
	local injuries = {}
	for entry in string.gmatch(player:GetAttribute("Injuries") or "", "[^,]+") do
		local id = entry:gsub("%*$", "")
		local def = InjuryDefs.ById[id]
		if def then
			table.insert(injuries, def.name .. (if entry:sub(-1) == "*" then " (splinted)" else ""))
		end
	end
	UI.setText(injuryLabel, if #injuries > 0 then "Injuries: " .. table.concat(injuries, ", ") else "No injuries")
	injuryLabel.TextColor3 = if #injuries > 0 then T.Warn else T.Good
end

local function render()
	local snapshot = ClientState.inventory
	if not snapshot or not panel.Visible then
		return
	end
	-- Worn slots.
	UI.clear(wornList)
	for i, slot in SLOTS do
		local itemId = snapshot.worn[slot]
		local def = itemId and ItemDefs.ById[itemId]
		local row = UI.inset({ Size = UDim2.new(1, 0, 0, 44), LayoutOrder = i, Parent = wornList })
		if def then
			UI.itemBadge(def, {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 6, 0.5, 0),
				Size = UDim2.fromOffset(32, 32),
				Parent = row,
			})
		else
			UI.icon(UI.slotIconKind(slot), {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 10, 0.5, 0),
				Size = UDim2.fromOffset(24, 24),
				Parent = row,
			}, { fg = T.Disabled, bg = T.BlueDark, accent = T.Disabled })
		end
		UI.label(SLOT_NAMES[slot], 11, {
			Position = UDim2.fromOffset(46, 3),
			Size = UDim2.new(1, -84, 0, 14),
			TextColor3 = T.Muted,
			Parent = row,
		})
		UI.label(if def then def.name else "Empty", 14, {
			Position = UDim2.fromOffset(46, 18),
			Size = UDim2.new(1, -84, 0, 20),
			TextColor3 = if def then T.White else T.Disabled,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		})
		if def then
			UI.roundButton("close", 28, function()
				invoke("Unequip", slot)
			end, {
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				BackgroundColor3 = T.Red,
				Parent = row,
			})
		end
	end
	local pack = ItemDefs.ById[snapshot.backpackId]
	UI.setText(packLabel, "Pack: " .. (if pack then pack.name else "?"))

	-- Category tabs.
	for _, b in tabs:GetChildren() do
		if b:IsA("TextButton") then
			local selected = b.Name == category
			b.BackgroundColor3 = if selected then T.White else T.BlueDark
			b.TextColor3 = if selected then T.Blue else T.White
		end
	end

	-- Grid.
	UI.clear(grid)
	for i, stack in snapshot.stacks do
		local def = ItemDefs.ById[stack.itemId]
		if def and (category == "All" or def.category == category) then
			local selected = stack.uid == selectedUid
			local tile = UI.create("TextButton", {
				Text = "",
				LayoutOrder = i,
				BackgroundColor3 = if selected then T.BlueLight else T.BlueDark,
				AutoButtonColor = true,
				Parent = grid,
			}, { UI.corner(14), UI.stroke(if selected then T.Cyan else T.White, if selected then 4 else 2) })
			UI.itemBadge(def, {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 10),
				Size = UDim2.fromOffset(50, 50),
				Parent = tile,
			})
			UI.label(def.name, 12, {
				Position = UDim2.fromOffset(4, 64),
				Size = UDim2.new(1, -8, 0, 30),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Top,
				Parent = tile,
			})
			if stack.qty > 1 then
				UI.pill("x" .. stack.qty, T.Orange, {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -4, 0, 4),
					Size = UDim2.fromOffset(0, 20),
					TextSize = 12,
					Parent = tile,
				})
			end
			if def.container and stack.data then
				local track, set = UI.bar({
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.new(0.5, 0, 1, -6),
					Size = UDim2.new(1, -24, 0, 6),
					Parent = tile,
				}, if stack.data.treated then T.Cyan else T.Warn)
				set((stack.data.ml or 0) / def.container.capacityMl)
				track.Name = "Fill"
			end
			if snapshot.heldUid == stack.uid then
				UI.pill("IN HAND", T.Green, {
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.new(0.5, 0, 1, -4),
					Size = UDim2.fromOffset(0, 18),
					TextSize = 10,
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
	local ratio = if snapshot.weightLimit > 0 then snapshot.weight / snapshot.weightLimit else 0
	setWeightBar(ratio, if ratio > 1 then T.Red elseif ratio > 0.8 then T.Warn else T.Cyan)
	footerText.Text = string.format(
		"%s / %d kg   ·   %d / %d slots",
		UI.formatKg(snapshot.weight),
		snapshot.weightLimit,
		#snapshot.stacks,
		snapshot.slots
	)
	footerText.TextColor3 = if snapshot.weight > snapshot.weightLimit then T.Danger else T.White
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
	panel = UI.panel("Backpack", UDim2.fromOffset(980, 590), gui)
	UI.autoScale(panel)
	UI.header(panel, "BACKPACK", "pack", function()
		InventoryController.toggle(false)
	end)

	-- Left: worn.
	UI.title("WORN", 16, {
		Position = UDim2.fromOffset(20, 64),
		Size = UDim2.fromOffset(220, 20),
		Parent = panel,
	})
	wornList = UI.create("Frame", {
		Position = UDim2.fromOffset(20, 88),
		Size = UDim2.fromOffset(220, 8 * 48),
		BackgroundTransparency = 1,
		Parent = panel,
	}, { UI.list(Enum.FillDirection.Vertical, 4) })
	packLabel = UI.label("", 13, {
		Position = UDim2.fromOffset(20, 88 + 8 * 48 + 4),
		Size = UDim2.fromOffset(220, 18),
		TextColor3 = T.Muted,
		Parent = panel,
	})

	-- Centre: tabs + grid.
	tabs = UI.create("Frame", {
		Position = UDim2.fromOffset(256, 64),
		Size = UDim2.fromOffset(464, 30),
		BackgroundTransparency = 1,
		Parent = panel,
	}, { UI.list(Enum.FillDirection.Horizontal, 4) })
	for i, cat in CATEGORIES do
		UI.button(cat, function()
			category = cat
			render()
		end, {
			Name = cat,
			Size = UDim2.fromOffset(62, 28),
			TextSize = 13,
			Font = T.Font,
			BackgroundColor3 = T.BlueDark,
			LayoutOrder = i,
			Parent = tabs,
		})
			:FindFirstChildOfClass("UIStroke").Thickness =
			2
	end
	local gridHolder = UI.inset({
		Position = UDim2.fromOffset(256, 102),
		Size = UDim2.fromOffset(464, 410),
		BackgroundColor3 = T.BlueDeep,
		Parent = panel,
	})
	grid = UI.create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = T.White,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = gridHolder,
	}, {
		UI.padding(10),
		UI.create("UIGridLayout", {
			CellSize = UDim2.fromOffset(102, 112),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	-- Right: detail + body.
	local detailCard = UI.inset({
		Position = UDim2.fromOffset(736, 64),
		Size = UDim2.fromOffset(226, 290),
		Parent = panel,
	})
	detail = UI.create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = detailCard,
	}, { UI.padding(10), UI.list(Enum.FillDirection.Vertical, 6) })

	local body = UI.inset({
		Position = UDim2.fromOffset(736, 364),
		Size = UDim2.fromOffset(226, 148),
		Parent = panel,
	})
	UI.padding(10, 8).Parent = body
	UI.list(Enum.FillDirection.Vertical, 3).Parent = body
	UI.title("BODY", 14, { Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 0, Parent = body })
	for i, region in REGIONS do
		local row = UI.create("Frame", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			LayoutOrder = i,
			Parent = body,
		})
		UI.label(region, 11, { Size = UDim2.new(0, 48, 1, 0), TextColor3 = T.Muted, Parent = row })
		local _, set = UI.bar({
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 50, 0.5, 0),
			Size = UDim2.new(1, -84, 0, 8),
			Parent = row,
		})
		bodyBars[region] = set
		bodyValues[region] = UI.label("100", 11, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 30, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = row,
		})
	end
	wetLabel = UI.label("", 11, { Size = UDim2.new(1, 0, 0, 14), LayoutOrder = 10, Parent = body })
	injuryLabel = UI.label("", 11, {
		Size = UDim2.new(1, 0, 0, 14),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		LayoutOrder = 11,
		Parent = body,
	})

	-- Footer: weight.
	local weightTrack
	weightTrack, setWeightBar = UI.bar({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 256, 1, -26),
		Size = UDim2.fromOffset(300, 16),
		Parent = panel,
	})
	UI.stroke(T.White, 2).Parent = weightTrack
	footerText = UI.title("", 18, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 572, 1, -20),
		Size = UDim2.fromOffset(390, 26),
		TextWrapped = false,
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
		local snapshotRemote = Remotes.get("GetSnapshot") :: RemoteFunction
		local snapshot = snapshotRemote:InvokeServer()
		while not snapshot do
			task.wait(1)
			snapshot = snapshotRemote:InvokeServer()
		end
		if not ClientState.inventory then
			ClientState.setInventory(snapshot)
		end
	end)
	-- Body warmth drifts while the panel is open: refresh the bars (no new instances).
	task.spawn(function()
		while true do
			task.wait(1)
			if panel.Visible then
				renderBody()
			end
		end
	end)
	-- No on-screen CAS button: the round Pack button on the left edge covers touch.
	ContextActionService:BindAction("ToggleBackpack", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			InventoryController.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Tab, Enum.KeyCode.I)
end

return InventoryController
