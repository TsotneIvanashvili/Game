--!strict
-- Bottom-centre quick slots, auto-filled from the latest InventorySync:
--   1 water  (first drink container, preferring one with water in it)
--   2 food   (first food)
--   3 first aid (first medical item; purification tablets last)
--   4 tool   (first hold-able item: Hold, or Stow when it's already in hand)
-- Keys 1-4 or a click/tap send the matching Inventory request. The client only picks the
-- stack; the server decides whether anything happens.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemDefs = require(Shared.Config.ItemDefs)
local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)
local InventoryController = require(script.Parent.InventoryController)

local HotbarController = {}

local T = UI.Theme
local KEYS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }

type SlotDef = { name: string, icon: string }
type Slot = {
	def: SlotDef,
	button: TextButton,
	stroke: UIStroke,
	iconHolder: Frame,
	count: TextLabel,
	itemId: string?,
	uid: string?,
	action: string?,
}

local SLOT_DEFS: { SlotDef } = {
	{ name = "Water", icon = "drop" },
	{ name = "Food", icon = "food" },
	{ name = "First aid", icon = "cross" },
	{ name = "Tool", icon = "axe" },
}

local gui: ScreenGui
local slots: { Slot } = {}

local function pick(snapshot: any): { { stack: any, action: string }? }
	local water, waterFallback, food, medical, medicalFallback, tool = nil, nil, nil, nil, nil, nil
	for _, stack in snapshot.stacks do
		local def = ItemDefs.ById[stack.itemId]
		if def then
			if def.container then
				if not water and stack.data and (stack.data.ml or 0) > 0 then
					water = stack
				elseif not waterFallback then
					waterFallback = stack
				end
			elseif def.category == "Food" and def.consumable and not food then
				food = stack
			elseif def.category == "Medical" and def.consumable then
				if def.id == "purification_tabs" then
					medicalFallback = medicalFallback or stack
				elseif not medical then
					medical = stack
				end
			elseif def.holdable and not tool then
				tool = stack
			end
		end
	end
	water = water or waterFallback
	medical = medical or medicalFallback
	local out: { { stack: any, action: string }? } = {}
	out[1] = if water then { stack = water, action = "Use" } else nil
	out[2] = if food then { stack = food, action = "Use" } else nil
	out[3] = if medical then { stack = medical, action = "Use" } else nil
	out[4] = if tool then { stack = tool, action = if snapshot.heldUid == tool.uid then "Stow" else "Hold" } else nil
	return out
end

local function setIcon(slot: Slot, itemId: string?)
	if slot.itemId == itemId and #slot.iconHolder:GetChildren() > 0 then
		return
	end
	slot.itemId = itemId
	UI.clear(slot.iconHolder)
	local def = itemId and ItemDefs.ById[itemId]
	if def then
		UI.itemBadge(def, { Size = UDim2.fromScale(1, 1), Parent = slot.iconHolder })
	else
		UI.icon(slot.def.icon, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.7, 0.7),
			Parent = slot.iconHolder,
		}, { fg = T.Disabled, bg = T.Blue, accent = T.Disabled })
	end
end

local function render()
	local snapshot = ClientState.inventory
	if not snapshot then
		return
	end
	local picks = pick(snapshot)
	for i, slot in slots do
		local entry = picks[i]
		if entry then
			local stack = entry.stack
			local def = ItemDefs.ById[stack.itemId]
			slot.uid = stack.uid
			slot.action = entry.action
			setIcon(slot, stack.itemId)
			local count = ""
			if def and def.container then
				count = string.format("%d ml", (stack.data and stack.data.ml) or 0)
			elseif stack.qty > 1 then
				count = "x" .. stack.qty
			elseif entry.action == "Stow" then
				count = "in hand"
			end
			UI.setText(slot.count, count)
			slot.stroke.Color = if entry.action == "Stow" then T.Cyan else T.White
			slot.button.BackgroundColor3 = T.Blue
		else
			slot.uid = nil
			slot.action = nil
			setIcon(slot, nil)
			UI.setText(slot.count, "")
			slot.stroke.Color = T.White
		end
	end
end

local function activate(i: number)
	local slot = slots[i]
	if not slot or not slot.uid or not slot.action then
		return
	end
	local uid, action = slot.uid, slot.action
	task.spawn(function()
		InventoryController.invoke(action :: string, uid :: string)
	end)
end

function HotbarController.Init()
	gui = UI.screen("Hotbar", 1)
	local bar = UI.create("Frame", {
		Name = "Hotbar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(4 * 78 + 3 * 10, 92),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		UI.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			Padding = UDim.new(0, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	UI.autoScale(bar)
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	for i, def in SLOT_DEFS do
		local button = UI.create("TextButton", {
			Name = def.name,
			Text = "",
			Size = UDim2.fromOffset(78, 86),
			BackgroundColor3 = T.Blue,
			AutoButtonColor = true,
			LayoutOrder = i,
			Parent = bar,
		}, { UI.corner(18) })
		local stroke = UI.stroke(T.White, 4)
		stroke.Parent = button
		local iconHolder = UI.create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 10),
			Size = UDim2.fromOffset(46, 46),
			BackgroundTransparency = 1,
			Parent = button,
		})
		UI.label(def.name, 11, {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -6),
			Size = UDim2.new(1, -8, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			Parent = button,
		})
		local count = UI.title("", 14, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -4, 0, 44),
			Size = UDim2.fromOffset(60, 16),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextWrapped = false,
			ZIndex = 3,
			Parent = button,
		})
		if not touchOnly then
			UI.create("TextLabel", {
				Position = UDim2.fromOffset(-6, -6),
				Size = UDim2.fromOffset(22, 22),
				BackgroundColor3 = T.BlueDark,
				Text = tostring(i),
				TextColor3 = T.White,
				Font = T.FontBold,
				TextSize = 14,
				ZIndex = 3,
				Parent = button,
			}, { UI.round(), UI.stroke(T.White, 2) })
		end
		local slot: Slot = {
			def = def,
			button = button,
			stroke = stroke,
			iconHolder = iconHolder,
			count = count,
		}
		slots[i] = slot
		setIcon(slot, nil)
		button.Activated:Connect(function()
			activate(i)
		end)
	end
end

function HotbarController.Start()
	ClientState.InventoryChanged:Connect(render)
	render()
	local function updateVisible(name: string?)
		gui.Enabled = name ~= "Title"
	end
	ClientState.PanelChanged:Connect(updateVisible)
	updateVisible(ClientState.openPanel)
	ContextActionService:BindAction("Hotbar", function(_, state, input)
		if state == Enum.UserInputState.Begin then
			for i, key in KEYS do
				if input.KeyCode == key then
					activate(i)
				end
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, table.unpack(KEYS))
end

return HotbarController
