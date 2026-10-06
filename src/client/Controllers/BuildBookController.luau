--!strict
-- Build Book (B) and placement mode. The book lists every section; pages you haven't found
-- or that aren't in the slice show as "Blueprint missing". Choosing a recipe enters
-- placement: a ghost of the footprint follows your aim (green = looks valid, red = not),
-- R rotates, click/Place confirms, right-click/Esc/B cancels. The server re-validates
-- everything, so the ghost colour is only a hint.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local RecipeDefs = require(Shared.Config.RecipeDefs)
local ItemDefs = require(Shared.Config.ItemDefs)
local GameConfig = require(Shared.Config.GameConfig)
local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)
local Notifications = require(script.Parent.NotificationController)

local BuildBookController = {}

local player = Players.LocalPlayer
local T = UI.Theme
local panel: Frame
local pages: ScrollingFrame
local sectionBar: Frame
local section = "Fire"
local placeButton: TextButton
local cancelButton: TextButton

local ghost: Part? = nil
local placingRecipe: RecipeDefs.Recipe? = nil
local yaw = 0
local lastValid = false
local renderConn: RBXScriptConnection? = nil
local inputConn: RBXScriptConnection? = nil

local function countItem(itemId: string): number
	local n = 0
	local snapshot = ClientState.inventory
	if snapshot then
		for _, s in snapshot.stacks do
			if s.itemId == itemId then
				n += s.qty
			end
		end
	end
	return n
end

local function canAfford(recipe: RecipeDefs.Recipe): boolean
	for itemId, qty in recipe.cost do
		if countItem(itemId) < qty then
			return false
		end
	end
	return recipe.requiresTool == nil or countItem(recipe.requiresTool) > 0
end

local function stopPlacing()
	placingRecipe = nil
	ClientState.placing = false
	if ghost then
		ghost:Destroy()
		ghost = nil
	end
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	placeButton.Visible = false
	cancelButton.Visible = false
	if inputConn then
		inputConn:Disconnect()
		inputConn = nil
	end
end

local function aimPoint(): (Vector3?, Vector3?)
	local camera = workspace.CurrentCamera
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil, nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { player.Character :: Model }
	if ghost then
		table.insert(exclude, ghost)
	end
	params.FilterDescendantsInstances = exclude
	local origin, direction
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		-- Touch: place a few studs in front of the character.
		local front = root.Position + root.CFrame.LookVector * 7
		origin, direction = front + Vector3.new(0, 6, 0), Vector3.new(0, -14, 0)
	else
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		origin, direction = ray.Origin, ray.Direction * 200
	end
	local hit = workspace:Raycast(origin, direction, params)
	if not hit then
		return nil, nil
	end
	-- Clamp to build range around the character.
	local offset = hit.Position - root.Position
	if offset.Magnitude > GameConfig.BUILD_RANGE - 1 then
		local clamped = root.Position + offset.Unit * (GameConfig.BUILD_RANGE - 1)
		local down = workspace:Raycast(clamped + Vector3.new(0, 8, 0), Vector3.new(0, -20, 0), params)
		if not down then
			return nil, nil
		end
		return down.Position, down.Normal
	end
	return hit.Position, hit.Normal
end

local function confirm()
	local recipe = placingRecipe
	if not recipe or not ghost then
		return
	end
	if not lastValid then
		Notifications.toast("You can't build there.", "warn")
		return
	end
	local frame = CFrame.new(ghost.Position - Vector3.new(0, recipe.footprint.Y / 2, 0)) * CFrame.Angles(0, yaw, 0)
	stopPlacing()
	local ok, success, message = pcall(function()
		return (Remotes.get("Build") :: RemoteFunction):InvokeServer(recipe.id, frame)
	end)
	if ok and message then
		Notifications.toast(message, if success then "good" else "warn")
	end
end

local function startPlacing(recipe: RecipeDefs.Recipe)
	stopPlacing()
	ClientState.setPanel(nil)
	placingRecipe = recipe
	ClientState.placing = true
	yaw = 0
	local g = Instance.new("Part")
	g.Name = "BuildGhost"
	g.Anchored = true
	g.CanCollide = false
	g.CanQuery = false
	g.CanTouch = false
	g.Material = Enum.Material.ForceField
	g.Size = recipe.footprint
	g.Parent = workspace
	ghost = g
	placeButton.Visible = true
	cancelButton.Visible = true

	renderConn = RunService.RenderStepped:Connect(function()
		local pos, normal = aimPoint()
		if not pos or not normal or not ghost then
			if ghost then
				ghost.Transparency = 1
			end
			lastValid = false
			return
		end
		local slope = math.deg(math.acos(math.clamp(normal.Y, -1, 1)))
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local inRange = root ~= nil and (pos - root.Position).Magnitude <= GameConfig.BUILD_RANGE
		lastValid = slope <= recipe.maxSlope and inRange and canAfford(recipe)
		ghost.Transparency = 0.5
		ghost.Color = if lastValid then Color3.fromRGB(90, 220, 110) else Color3.fromRGB(230, 70, 60)
		ghost.CFrame = CFrame.new(pos + Vector3.new(0, recipe.footprint.Y / 2, 0)) * CFrame.Angles(0, yaw, 0)
	end)

	-- UserInputService (not ContextActionService) so clicks the GUI already handled, such as
	-- the on-screen Place/Cancel buttons, never also count as "place here".
	inputConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			confirm()
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.Escape then
			stopPlacing()
		elseif input.KeyCode == Enum.KeyCode.R then
			yaw += math.rad(45)
		end
	end)
end

local function render()
	for _, b in sectionBar:GetChildren() do
		if b:IsA("TextButton") then
			b.BackgroundColor3 = if b.Name == section then T.Accent else T.PanelLight
		end
	end
	for _, c in pages:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	UI.list(Enum.FillDirection.Vertical, 8).Parent = pages
	local order = 0
	for _, recipe in RecipeDefs.List do
		if recipe.section == section then
			order += 1
			local card = UI.create("Frame", {
				Size = UDim2.new(1, -10, 0, 86),
				BackgroundColor3 = T.PanelLight,
				LayoutOrder = order,
				Parent = pages,
			}, { UI.corner(6) })
			if not recipe.implemented or not recipe.unlockedByDefault then
				-- Blueprints found during play are tracked server-side; the slice ships with the
				-- default set, so anything else reads as a missing page.
				UI.label(recipe.name, 15, {
					Position = UDim2.fromOffset(12, 6),
					Size = UDim2.new(1, -24, 0, 20),
					Font = T.FontBold,
					TextColor3 = T.Muted,
					Parent = card,
				})
				UI.label("Blueprint missing. Pages are found on the mountain.", 12, {
					Position = UDim2.fromOffset(12, 30),
					Size = UDim2.new(1, -24, 0, 18),
					TextColor3 = T.Muted,
					Parent = card,
				})
			else
				UI.label(recipe.name, 15, {
					Position = UDim2.fromOffset(12, 6),
					Size = UDim2.new(1, -150, 0, 20),
					Font = T.FontBold,
					Parent = card,
				})
				UI.label(recipe.description, 12, {
					Position = UDim2.fromOffset(12, 28),
					Size = UDim2.new(1, -150, 0, 30),
					TextColor3 = T.Muted,
					Parent = card,
				})
				local costs = {}
				for itemId, qty in recipe.cost do
					local def = ItemDefs.ById[itemId]
					local have = countItem(itemId)
					table.insert(costs, string.format("%s %d/%d", if def then def.name else itemId, have, qty))
				end
				if recipe.requiresTool then
					local def = ItemDefs.ById[recipe.requiresTool]
					table.insert(
						costs,
						string.format(
							"needs %s%s",
							if def then def.name else recipe.requiresTool,
							if countItem(recipe.requiresTool) > 0 then "" else " (missing)"
						)
					)
				end
				local affordable = canAfford(recipe)
				UI.label(table.concat(costs, "  ·  "), 12, {
					Position = UDim2.fromOffset(12, 60),
					Size = UDim2.new(1, -150, 0, 18),
					TextColor3 = if affordable then T.Good else T.Warn,
					Parent = card,
				})
				UI.button("Build", function()
					startPlacing(recipe)
				end, {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -10, 0.5, 0),
					Size = UDim2.fromOffset(110, 34),
					Parent = card,
				})
			end
		end
	end
end

function BuildBookController.toggle()
	if ClientState.openPanel == "BuildBook" then
		ClientState.setPanel(nil)
	else
		stopPlacing()
		ClientState.setPanel("BuildBook")
	end
end

function BuildBookController.Init()
	local gui = UI.screen("BuildBook", 3)
	panel = UI.panel("BuildBook", UDim2.fromOffset(640, 520), gui)
	UI.autoScale(panel)
	UI.label(
		"BUILD BOOK",
		18,
		{ Position = UDim2.fromOffset(16, 10), Size = UDim2.new(0, 200, 0, 24), Font = T.FontBold, Parent = panel }
	)
	UI.button("Close", function()
		ClientState.setPanel(nil)
	end, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 10),
		Size = UDim2.fromOffset(70, 26),
		Parent = panel,
		Modal = true,
	})
	sectionBar = UI.create("Frame", {
		Position = UDim2.fromOffset(16, 44),
		Size = UDim2.new(1, -32, 0, 28),
		BackgroundTransparency = 1,
		Parent = panel,
	}, {
		UI.list(Enum.FillDirection.Horizontal, 4),
	})
	for i, name in RecipeDefs.Sections do
		UI.button(name, function()
			section = name
			render()
		end, { Name = name, LayoutOrder = i, Size = UDim2.fromOffset(96, 26), TextSize = 12, Parent = sectionBar })
	end
	pages = UI.create("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 80),
		Size = UDim2.new(1, -32, 1, -92),
		BackgroundTransparency = 1,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = panel,
	})
	placeButton = UI.button("Place", confirm, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, -70, 1, -110),
		Size = UDim2.fromOffset(120, 40),
		Visible = false,
		Parent = gui,
	})
	cancelButton = UI.button("Cancel", function()
		stopPlacing()
	end, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 70, 1, -110),
		Size = UDim2.fromOffset(120, 40),
		Visible = false,
		Parent = gui,
	})
end

function BuildBookController.Start()
	ClientState.PanelChanged:Connect(function(name)
		panel.Visible = name == "BuildBook"
		if panel.Visible then
			render()
		end
	end)
	ClientState.InventoryChanged:Connect(function()
		if panel.Visible then
			render()
		end
	end)
	ContextActionService:BindAction("ToggleBuildBook", function(_, state)
		if state == Enum.UserInputState.Begin then
			if placingRecipe then
				stopPlacing()
			else
				BuildBookController.toggle()
			end
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.B)
	ContextActionService:SetTitle("ToggleBuildBook", "Build")
	player.CharacterRemoving:Connect(stopPlacing)
end

return BuildBookController
