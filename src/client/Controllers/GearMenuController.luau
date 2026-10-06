--!strict
-- Gear toggles (H, or the helmet button on the left edge): show/hide Helmet, Mask, Goggles
-- and the helmet Light. The switch sends GearToggle(part, on) and the server owns the
-- result, published as Player attributes GearHelmet / GearMask / GearGoggles / GearLight.
-- nil means "shown" for worn items and "off" for the light (EquipmentService defaults).
-- A part you aren't wearing is locked (padlock); the light needs a headlamp helmet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local ItemDefs = require(Shared.Config.ItemDefs)
local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)

local GearMenuController = {}

local PANEL_NAME = "Gear"
local T = UI.Theme
local player = Players.LocalPlayer

-- part -> worn slot that has to be filled for the toggle to mean anything.
local PARTS = {
	{ part = "Helmet", slot = "Head", icon = "helmet", label = "Helmet" },
	{ part = "Mask", slot = "Face", icon = "mask", label = "Mask" },
	{ part = "Goggles", slot = "Eyes", icon = "goggles", label = "Goggles" },
	{ part = "Light", slot = "Head", icon = "light", label = "Light" },
}

type Row = { toggle: UI.Toggle, sub: TextLabel, name: TextLabel }

local panel: Frame
local rows: { [string]: Row } = {}
local pending: { [string]: { on: boolean, at: number } } = {}

local function wornItem(slot: string): any
	local snapshot = ClientState.inventory
	local itemId = snapshot and snapshot.worn and snapshot.worn[slot]
	return itemId and ItemDefs.ById[itemId]
end

local function isOn(part: string): boolean
	local p = pending[part]
	if p and os.clock() - p.at < 2 then
		return p.on
	end
	pending[part] = nil
	local value = player:GetAttribute("Gear" .. part)
	if part == "Light" then
		return value == true
	end
	return value ~= false
end

-- Whether the toggle can do anything, and the line shown under its name.
local function availability(entry: { part: string, slot: string }): (boolean, string)
	local def = wornItem(entry.slot)
	if not def then
		return false,
			if entry.part == "Light" then "Needs a helmet with a headlamp" else "Not worn  ·  get one at the outfitter"
	end
	if entry.part == "Light" and not (def.clothing and def.clothing.headlamp) then
		return false, def.name .. " has no headlamp"
	end
	return true, def.name
end

local function render()
	for _, entry in PARTS do
		local row = rows[entry.part]
		local usable, line = availability(entry)
		row.toggle.set(isOn(entry.part), usable)
		row.name.TextColor3 = if usable then T.White else T.Muted
		row.sub.Text = line
	end
end

local function flip(part: string, on: boolean)
	pending[part] = { on = on, at = os.clock() }
	local remote = Remotes.get("GearToggle") :: RemoteEvent
	remote:FireServer(part, on)
	render()
	-- Reconcile with the server's answer even if the attribute never changes (rejected).
	task.delay(2.1, render)
end

function GearMenuController.toggle()
	if ClientState.openPanel == PANEL_NAME then
		ClientState.setPanel(nil)
	else
		ClientState.setPanel(PANEL_NAME)
	end
end

function GearMenuController.Init()
	local gui = UI.screen("GearMenu", 3)
	panel = UI.panel("Gear", UDim2.fromOffset(380, 400), gui)
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 100, 0.5, 0)
	UI.autoScale(panel)
	UI.header(panel, "GEAR", "helmet", function()
		ClientState.setPanel(nil)
	end)
	local list = UI.create("Frame", {
		Position = UDim2.fromOffset(18, 70),
		Size = UDim2.new(1, -36, 1, -84),
		BackgroundTransparency = 1,
		Parent = panel,
	}, { UI.list(Enum.FillDirection.Vertical, 10) })
	for i, entry in PARTS do
		local row = UI.inset({ Size = UDim2.new(1, 0, 0, 68), LayoutOrder = i, Parent = list })
		local disc = UI.create("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 10, 0.5, 0),
			Size = UDim2.fromOffset(48, 48),
			BackgroundColor3 = T.Blue,
			BorderSizePixel = 0,
			Parent = row,
		}, { UI.round(), UI.stroke(T.White, 2) })
		UI.icon(entry.icon, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.64, 0.64),
			Parent = disc,
		})
		local name = UI.title(entry.label, 22, {
			Position = UDim2.fromOffset(70, 8),
			Size = UDim2.new(1, -160, 0, 28),
			TextWrapped = false,
			Parent = row,
		})
		local sub = UI.label("", 12, {
			Position = UDim2.fromOffset(70, 36),
			Size = UDim2.new(1, -160, 0, 24),
			TextColor3 = T.Muted,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		})
		local part = entry.part
		local toggle = UI.toggle({
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Parent = row,
		}, function(on)
			flip(part, on)
		end)
		rows[part] = { toggle = toggle, sub = sub, name = name }
	end
end

function GearMenuController.Start()
	ClientState.PanelChanged:Connect(function(name)
		panel.Visible = name == PANEL_NAME
		if panel.Visible then
			render()
		end
	end)
	ClientState.InventoryChanged:Connect(function()
		if panel.Visible then
			render()
		end
	end)
	for _, entry in PARTS do
		local part = entry.part
		player:GetAttributeChangedSignal("Gear" .. part):Connect(function()
			pending[part] = nil
			if panel.Visible then
				render()
			end
		end)
	end
	ContextActionService:BindAction("ToggleGearMenu", function(_, state)
		if state == Enum.UserInputState.Begin then
			GearMenuController.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.H)
end

return GearMenuController
