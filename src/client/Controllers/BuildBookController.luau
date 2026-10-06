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
local placeBar: Frame

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
	placeBar.Visible = false
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
	placeBar.Visible = true

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

local SECTION_ICONS = {
	Fire = "flame",
	Shelters = "tent",
	Climbing = "rope",
	Survival = "drop",
	Navigation = "flag",
	Advanced = "hammer",
}

local function render()
	for _, b in sectionBar:GetChildren() do
		if b:IsA("TextButton") then
			local selected = b.Name == section
			b.BackgroundColor3 = if selected then T.White else T.BlueDark
			b.TextColor3 = if selected then T.Blue else T.White
		end
	end
	UI.clear(pages)
	local order = 0
	for _, recipe in RecipeDefs.List do
		if recipe.section == section then
			order += 1
			local available = recipe.implemented and recipe.unlockedByDefault
			local card = UI.inset({
				Size = UDim2.new(1, -12, 0, 112),
				LayoutOrder = order,
				Parent = pages,
			})
			UI.stroke(if available then T.White else T.Disabled, 2).Parent = card
			local disc = UI.create("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 14, 0.5, 0),
				Size = UDim2.fromOffset(64, 64),
				BackgroundColor3 = if available then T.Orange else T.Disabled,
				BorderSizePixel = 0,
				Parent = card,
			}, { UI.round(), UI.stroke(T.White, 3) })
			UI.icon(if available then SECTION_ICONS[recipe.section] or "hammer" else "lock", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.6, 0.6),
				Parent = disc,
			}, {
				bg = disc.BackgroundColor3,
				accent = if available then T.White else nil,
			})
			if not available then
				-- Blueprints found during play are tracked server-side; the slice ships with the
				-- default set, so anything else reads as a missing page.
				UI.title(recipe.name, 20, {
					Position = UDim2.fromOffset(92, 18),
					Size = UDim2.new(1, -110, 0, 26),
					TextColor3 = T.Muted,
					Parent = card,
				})
				UI.label("Blueprint missing. Pages are found on the mountain.", 13, {
					Position = UDim2.fromOffset(92, 50),
					Size = UDim2.new(1, -110, 0, 36),
					TextColor3 = T.Muted,
					Parent = card,
				})
			else
				UI.title(recipe.name, 20, {
					Position = UDim2.fromOffset(92, 8),
					Size = UDim2.new(1, -230, 0, 26),
					Parent = card,
				})
				UI.label(recipe.description, 12, {
					Position = UDim2.fromOffset(92, 34),
					Size = UDim2.new(1, -230, 0, 34),
					TextColor3 = T.Muted,
					TextYAlignment = Enum.TextYAlignment.Top,
					Parent = card,
				})
				local chips = UI.create("Frame", {
					Position = UDim2.fromOffset(92, 74),
					Size = UDim2.new(1, -230, 0, 26),
					BackgroundTransparency = 1,
					Parent = card,
				}, { UI.list(Enum.FillDirection.Horizontal, 6) })
				local ids = {}
				for itemId in recipe.cost do
					table.insert(ids, itemId)
				end
				table.sort(ids)
				for i, itemId in ids do
					local qty = recipe.cost[itemId]
					local def = ItemDefs.ById[itemId]
					local have = countItem(itemId)
					UI.pill(
						string.format("%s %d/%d", if def then def.name else itemId, have, qty),
						if have >= qty then T.Green else T.Red,
						{ LayoutOrder = i, Parent = chips }
					)
				end
				if recipe.requiresTool then
					local def = ItemDefs.ById[recipe.requiresTool]
					local has = countItem(recipe.requiresTool) > 0
					UI.pill(
						"needs " .. (if def then def.name else recipe.requiresTool),
						if has then T.Green else T.Red,
						{ LayoutOrder = 99, Parent = chips }
					)
				end
				local b = UI.button("Build", function()
					startPlacing(recipe)
				end, {
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -14, 0.5, 0),
					Size = UDim2.fromOffset(120, 46),
					TextSize = 22,
					Parent = card,
				})
				-- Still clickable when short: the ghost shows red and the server explains.
				UI.setButtonEnabled(b, canAfford(recipe), T.Green)
				b.AutoButtonColor = true
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
	panel = UI.panel("BuildBook", UDim2.fromOffset(720, 580), gui)
	UI.autoScale(panel)
	UI.header(panel, "BUILD BOOK", "hammer", function()
		ClientState.setPanel(nil)
	end)
	sectionBar = UI.create("Frame", {
		Position = UDim2.fromOffset(20, 66),
		Size = UDim2.new(1, -40, 0, 32),
		BackgroundTransparency = 1,
		Parent = panel,
	}, {
		UI.list(Enum.FillDirection.Horizontal, 6),
	})
	for i, name in RecipeDefs.Sections do
		local b = UI.button(name, function()
			section = name
			render()
		end, {
			Name = name,
			LayoutOrder = i,
			Size = UDim2.fromOffset(108, 30),
			TextSize = 14,
			Font = T.Font,
			BackgroundColor3 = T.BlueDark,
			Parent = sectionBar,
		})
		local stroke = b:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Thickness = 2
		end
	end
	local holder = UI.inset({
		Position = UDim2.fromOffset(18, 108),
		Size = UDim2.new(1, -36, 1, -126),
		BackgroundColor3 = T.BlueDeep,
		Parent = panel,
	})
	pages = UI.create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = T.White,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = holder,
	}, { UI.padding(12), UI.list(Enum.FillDirection.Vertical, 10) })

	-- Placement controls (above the hotbar).
	placeBar = UI.create("Frame", {
		Name = "Placement",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -190),
		Size = UDim2.fromOffset(300, 84),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	UI.autoScale(placeBar)
	UI.button("Place", confirm, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromOffset(140, 50),
		TextSize = 24,
		BackgroundColor3 = T.Green,
		Parent = placeBar,
	})
	UI.button("Cancel", function()
		stopPlacing()
	end, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(140, 50),
		TextSize = 24,
		BackgroundColor3 = T.Red,
		Parent = placeBar,
	})
	UI.title(
		if UserInputService.TouchEnabled and not UserInputService.MouseEnabled
			then "Walk to aim  ·  tap Place"
			else "Click to place  ·  R rotate  ·  right-click cancel",
		16,
		{
			Size = UDim2.new(1, 0, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false,
			Parent = placeBar,
		}
	)
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
	end, false, Enum.KeyCode.B) -- touch uses the round Build button on the left edge
	player.CharacterRemoving:Connect(stopPlacing)
end

return BuildBookController
