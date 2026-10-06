--!strict
-- Outfitter and supply-crate panels, opened by the server when you use those prompts.
-- The panels only send requests; the server checks you're still standing at the rack/crate.

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
local panel: Frame
local title: TextLabel
local list: ScrollingFrame
local current: { kind: string, data: any }? = nil
local openedAt: Vector3? = nil

local function close()
	if ClientState.openPanel == "Outfitter" or ClientState.openPanel == "Supply" then
		ClientState.setPanel(nil)
	end
end

local function describe(def: ItemDefs.ItemDef): string
	if def.clothing then
		local c = def.clothing
		local parts = {}
		for region, v in c.insulation do
			table.insert(parts, region .. " +" .. v)
		end
		return string.format(
			"%s · %s · wind %d%% · water %d%% · %.2f kg",
			c.slot,
			table.concat(parts, " "),
			c.windproof * 100,
			c.waterproof * 100,
			def.weight
		)
	elseif def.backpack then
		return string.format(
			"%d slots · carries %d kg · %.1f kg empty",
			def.backpack.slots,
			def.backpack.weightLimit,
			def.weight
		)
	end
	return string.format("%s · %.2f kg", def.category, def.weight)
end

local function row(def: ItemDefs.ItemDef, order: number, buttonText: string, enabled: boolean, onClick: () -> ())
	local r = UI.create(
		"Frame",
		{ Size = UDim2.new(1, -10, 0, 54), BackgroundColor3 = T.PanelLight, LayoutOrder = order, Parent = list },
		{ UI.corner(6) }
	)
	UI.create("Frame", { Size = UDim2.new(0, 4, 1, 0), BackgroundColor3 = def.color, BorderSizePixel = 0, Parent = r })
	UI.label(
		def.name,
		15,
		{ Position = UDim2.fromOffset(12, 4), Size = UDim2.new(1, -150, 0, 20), Font = T.FontBold, Parent = r }
	)
	UI.label(
		describe(def),
		12,
		{ Position = UDim2.fromOffset(12, 26), Size = UDim2.new(1, -150, 0, 22), TextColor3 = T.Muted, Parent = r }
	)
	local b = UI.button(buttonText, onClick, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(120, 32),
		Parent = r,
	})
	if not enabled then
		b.AutoButtonColor = false
		b.TextColor3 = T.Muted
	end
end

local function render()
	if not current then
		return
	end
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	UI.list(Enum.FillDirection.Vertical, 6).Parent = list
	local snapshot = ClientState.inventory
	if current.kind == "Outfitter" then
		title.Text = "OUTFITTER  ·  swap gear for free at base camp. Weight is the real cost."
		local rank = current.data.rankIndex or 1
		for i, itemId in current.data.stock do
			local def = ItemDefs.ById[itemId]
			if def then
				local locked = rank < def.unlockRank
				local text, enabled = "Take", true
				if locked then
					text, enabled = ProgressionConfig.Ranks[def.unlockRank].name, false
				elseif def.clothing then
					local wearing = snapshot and snapshot.worn[def.clothing.slot] == itemId
					text, enabled = if wearing then "Wearing" else "Wear", not wearing
				elseif def.backpack then
					local using = snapshot and snapshot.backpackId == itemId
					text, enabled = if using then "Using" else "Use pack", not using
				elseif current.data.taken[itemId] then
					text, enabled = "Taken", false
				end
				row(def, i, text, enabled, function()
					if not enabled then
						return
					end
					local ok, success, message = pcall(function()
						return (Remotes.get("Outfit") :: RemoteFunction):InvokeServer(itemId)
					end)
					if ok then
						if success and not def.clothing and not def.backpack then
							current.data.taken[itemId] = true
						end
						if message then
							Notifications.toast(message, if success then "good" else "warn")
						end
					end
					render()
				end)
			end
		end
	else
		title.Text = "SUPPLY CRATE  ·  your share for this expedition"
		local ids = {}
		for itemId in current.data.remaining do
			table.insert(ids, itemId)
		end
		table.sort(ids)
		for i, itemId in ids do
			local def = ItemDefs.ById[itemId]
			local left = current.data.remaining[itemId]
			if def then
				row(def, i, if left > 0 then "Take (" .. left .. " left)" else "None left", left > 0, function()
					if current.data.remaining[itemId] <= 0 then
						return
					end
					local ok, success, message = pcall(function()
						return (Remotes.get("Supply") :: RemoteFunction):InvokeServer(current.data.crateId, itemId)
					end)
					if ok and success then
						current.data.remaining[itemId] -= 1
					elseif ok and message then
						Notifications.toast(message, "warn")
					end
					render()
				end)
			end
		end
	end
end

function PanelController.Init()
	local gui = UI.screen("Panels", 3)
	panel = UI.panel("Panel", UDim2.fromOffset(620, 520), gui)
	UI.autoScale(panel)
	title = UI.label(
		"",
		15,
		{ Position = UDim2.fromOffset(16, 12), Size = UDim2.new(1, -110, 0, 22), Font = T.FontBold, Parent = panel }
	)
	UI.button("Close", close, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 10),
		Size = UDim2.fromOffset(70, 26),
		Parent = panel,
		Modal = true,
	})
	list = UI.create("ScrollingFrame", {
		Position = UDim2.fromOffset(12, 48),
		Size = UDim2.new(1, -24, 1, -60),
		BackgroundTransparency = 1,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = panel,
	})
end

function PanelController.Start()
	(Remotes.get("OpenPanel") :: RemoteEvent).OnClientEvent:Connect(function(kind: string, data: any)
		if kind ~= "Outfitter" and kind ~= "Supply" then
			return
		end
		current = { kind = kind, data = data }
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		openedAt = root and root.Position
		ClientState.setPanel(kind)
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
