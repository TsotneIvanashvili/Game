--!strict
-- Build Book construction, fires, shelters and wind breaks, plus the queries every other
-- system uses to ask "how warm / sheltered is this spot?".
--
-- Placement is fully server validated: blueprint unlocked, recipe implemented, materials
-- and tool present, within reach, on solid ground (not water, not a player), slope within
-- the recipe's limit, not overlapping another structure. Materials are only taken after the
-- build timer completes and are re-checked at that moment (no dupes via give-during-build).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local RecipeDefs = require(Shared.Config.RecipeDefs)
local ZoneDefs = require(Shared.Config.ZoneDefs)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local WarmthModel = require(Shared.Logic.WarmthModel)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)
local PromptUtil = require(script.Parent.PromptUtil)
local AssetFactory = require(script.Parent.Parent.World.AssetFactory)

local BuildingService = {}

local MAX_STRUCTURES = 80
local FIRE_START_FUEL = 180
local FIRE_FUEL_PER_WOOD = 90
local FIRE_MAX_FUEL = 600
local SHELTER_DECAY_WIND = 15 -- m/s; stronger wind than this wears a tarp down
local TENT_DECAY_WIND = 19 -- a staked dome tent shrugs off all but the worst storm
local WIND_WALL_RADIUS = 8

export type Structure = {
	id: number,
	kind: string,
	model: Model?,
	position: Vector3,
	radius: number,
	permanent: boolean,
	-- fire
	fuel: number?,
	maxHeat: number?,
	heatRadius: number?,
	-- shelter
	shelterFrame: CFrame?,
	shelterSize: Vector3?,
	windFactor: number?,
	precipBlocked: boolean?,
	durability: number?,
	roofSnow: { BasePart }?,
	snow: number?,
	warned: boolean?,
}

local structures: { Structure } = {}
local nextId = 1
local building: { [Player]: boolean } = {}
local folder: Folder

local function remote()
	return Registry.get("RemoteGuard")
end

local function register(s: Structure): Structure
	s.id = nextId
	nextId += 1
	table.insert(structures, s)
	return s
end

local function removeStructure(s: Structure)
	local index = table.find(structures, s)
	if index then
		table.remove(structures, index)
	end
	if s.model then
		s.model:Destroy()
	end
end

local function insideBox(frame: CFrame, size: Vector3, pos: Vector3): boolean
	local p = frame:PointToObjectSpace(pos)
	return math.abs(p.X) <= size.X / 2 and math.abs(p.Y) <= size.Y / 2 and math.abs(p.Z) <= size.Z / 2
end

-- Public queries ------------------------------------------------------------------------------

function BuildingService.environmentAt(pos: Vector3): {
	fireHeatC: number,
	windFactor: number,
	precipBlocked: boolean,
	inShelter: boolean,
}
	local heat, wind, blocked, inShelter = 0, 1, false, false
	for _, s in structures do
		if s.fuel and s.fuel > 0 then
			local d = (s.position - pos).Magnitude
			heat = math.max(heat, WarmthModel.fireHeatAt(d, s.heatRadius, s.maxHeat))
		end
		if s.shelterFrame and s.shelterSize and insideBox(s.shelterFrame, s.shelterSize, pos) then
			wind = math.min(wind, s.windFactor or 1)
			blocked = blocked or s.precipBlocked == true
			inShelter = true
			-- Simplification: a wind wall shelters everyone within its radius regardless of wind
			-- direction. A true lee check against WorldState.WindDirection is a planned refinement.
		elseif s.kind == "wind_wall" and (s.position - pos).Magnitude <= WIND_WALL_RADIUS then
			wind = math.min(wind, s.windFactor or 1)
		end
	end
	return { fireHeatC = heat, windFactor = wind, precipBlocked = blocked, inShelter = inShelter }
end

function BuildingService.nearestFire(pos: Vector3, range: number): Structure?
	local best, bestD = nil, range
	for _, s in structures do
		if s.fuel and s.fuel > 0 then
			local d = (s.position - pos).Magnitude
			if d <= bestD then
				best, bestD = s, d
			end
		end
	end
	return best
end

-- Camps register their permanent fire and cabin through these.
function BuildingService.registerPermanentFire(model: Model, position: Vector3)
	local s = register({
		id = 0,
		kind = "campfire",
		model = model,
		position = position,
		radius = 3,
		permanent = true,
		fuel = math.huge,
		maxHeat = 30,
		heatRadius = 20,
	})
	BuildingService.attachFirePrompts(s)
end

function BuildingService.registerShelter(frame: CFrame, size: Vector3, windFactor: number, precipBlocked: boolean)
	register({
		id = 0,
		kind = "cabin",
		model = nil,
		position = frame.Position,
		radius = math.max(size.X, size.Z) / 2,
		permanent = true,
		shelterFrame = frame,
		shelterSize = size,
		windFactor = windFactor,
		precipBlocked = precipBlocked,
	})
end

-- Fire interactions ---------------------------------------------------------------------------

function BuildingService.attachFirePrompts(s: Structure)
	local model = s.model :: Model
	local anchor = (model:FindFirstChild("Embers") or model.PrimaryPart) :: BasePart
	PromptUtil.create(anchor, {
		action = "Rest by the fire",
		object = "Fire",
		key = Enum.KeyCode.E,
		offset = Vector3.new(0, 2, 0),
		distance = 12,
	}, function(player)
		if s.fuel and s.fuel > 0 then
			Registry.get("SurvivalService").setResting(player, true)
		end
	end)
	PromptUtil.create(anchor, {
		action = "Cook food & boil water",
		object = "Fire",
		key = Enum.KeyCode.Q,
		offset = Vector3.new(0, 3, 0),
		hold = 2,
		distance = 9,
	}, function(player)
		if not s.fuel or s.fuel <= 0 then
			return
		end
		local InventoryService = Registry.get("InventoryService")
		local cooked = InventoryService.cookAll(player)
		local boiled = InventoryService.boilContainers(player)
		local melted = 0
		local weather = Registry.get("WeatherService").sampleAt(s.position)
		-- Snow lying on the ground (snowline and above) or falling right now can be melted.
		if weather.isSnow or ZoneDefs.at(s.position.Y).snowCover then
			melted = InventoryService.fillContainers(player, true, true)
			if not s.permanent and melted > 0 then
				s.fuel = math.max(1, (s.fuel :: number) - melted * 15) -- melting snow eats fuel
			end
		end
		local parts = {}
		if cooked > 0 then
			table.insert(parts, cooked .. " food heated")
		end
		if boiled > 0 then
			table.insert(parts, boiled .. " bottle(s) boiled")
		end
		if melted > 0 then
			table.insert(parts, string.format("%.1f L of snow melted", melted))
		end
		remote().notify(
			player,
			if #parts > 0 then table.concat(parts, ", ") .. "." else "Nothing to cook or boil.",
			if #parts > 0 then "good" else "info"
		)
	end)
	if not s.permanent then
		PromptUtil.create(
			anchor,
			{ action = "Add wood", object = "Fire", key = Enum.KeyCode.F, offset = Vector3.new(0, 4, 0), distance = 9 },
			function(player)
				if not s.fuel or s.fuel <= 0 then
					return
				end
				if s.fuel >= FIRE_MAX_FUEL - 10 then
					remote().notify(player, "The fire is already roaring.", "info")
					return
				end
				if Registry.get("InventoryService").removeAll(player, { wood = 1 }) then
					s.fuel = math.min(FIRE_MAX_FUEL, (s.fuel :: number) + FIRE_FUEL_PER_WOOD)
					remote().notify(player, "You feed the fire.", "good")
				else
					remote().notify(player, "You have no wood.", "warn")
				end
			end
		)
	end
end

local function extinguish(s: Structure)
	s.fuel = 0
	local model = s.model
	if model then
		local embers = model:FindFirstChild("Embers") :: BasePart?
		if embers then
			for _, child in embers:GetChildren() do
				if child:IsA("Fire") or child:IsA("PointLight") or child:IsA("ProximityPrompt") then
					child:Destroy()
				elseif child:IsA("Smoke") then
					child.Opacity = 0.03
				end
			end
			embers.Material = Enum.Material.Slate
			embers.Color = Color3.fromRGB(45, 42, 40)
			embers.Transparency = 0
		end
		for _, d in model:GetDescendants() do
			if d:IsA("ProximityPrompt") then
				d:Destroy()
			end
		end
	end
	task.delay(90, function()
		removeStructure(s)
	end)
end

-- Placement validation -------------------------------------------------------------------------

local function groundAt(pos: Vector3): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { folder }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = false
	return workspace:Raycast(pos + Vector3.new(0, 6, 0), Vector3.new(0, -14, 0), params)
end

-- Returns the snapped CFrame or nil and a reason.
function BuildingService.validatePlacement(
	player: Player,
	recipe: RecipeDefs.Recipe,
	desired: CFrame
): (CFrame?, string?)
	local _, _, _, root = PlayerStore.getActive(player)
	if not root then
		return nil, "You can't build right now."
	end
	if (desired.Position - root.Position).Magnitude > GameConfig.BUILD_RANGE then
		return nil, "Too far away."
	end
	local hit = groundAt(desired.Position)
	if not hit then
		return nil, "There's no ground there."
	end
	if hit.Material == Enum.Material.Water then
		return nil, "You can't build in water."
	end
	local slope = math.deg(math.acos(math.clamp(hit.Normal.Y, -1, 1)))
	if slope > recipe.maxSlope then
		return nil, string.format("Too steep (%d°, max %d°).", slope, recipe.maxSlope)
	end
	-- Keep only yaw from the client's rotation.
	local look = Vector3.new(desired.LookVector.X, 0, desired.LookVector.Z)
	if look.Magnitude < 0.1 then
		look = Vector3.new(0, 0, -1)
	end
	local frame = CFrame.lookAt(hit.Position, hit.Position + look.Unit)
	local radius = math.max(recipe.footprint.X, recipe.footprint.Z) / 2
	for _, s in structures do
		if (s.position - frame.Position).Magnitude < radius + s.radius - 0.5 then
			return nil, "Something is already built there."
		end
	end
	-- Physical obstruction check (trees, rocks, cabins), ignoring characters and terrain.
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	overlap.FilterDescendantsInstances = exclude
	local box = frame * CFrame.new(0, recipe.footprint.Y / 2 + 0.5, 0)
	for _, p in workspace:GetPartBoundsInBox(box, recipe.footprint * 0.85, overlap) do
		if p.CanCollide and not p:IsA("Terrain") then
			return nil, "Blocked by " .. p.Name .. "."
		end
	end
	return frame, nil
end

-- Building ---------------------------------------------------------------------------------------

local function spawnStructure(player: Player, recipe: RecipeDefs.Recipe, frame: CFrame)
	if #structures >= MAX_STRUCTURES then
		for _, s in structures do
			if not s.permanent then
				removeStructure(s)
				break
			end
		end
	end
	local model: Model
	local s: Structure
	if recipe.id == "campfire" then
		model = AssetFactory.campfire(frame)
		s = register({
			id = 0,
			kind = recipe.id,
			model = model,
			position = frame.Position + Vector3.new(0, 1, 0),
			radius = 2.5,
			permanent = false,
			fuel = FIRE_START_FUEL,
		})
		model.Parent = folder
		BuildingService.attachFirePrompts(s)
	elseif recipe.id == "tarp_shelter" then
		model = AssetFactory.tarpShelter(frame)
		s = register({
			id = 0,
			kind = recipe.id,
			model = model,
			position = frame.Position,
			radius = 5.5,
			permanent = false,
			shelterFrame = frame * CFrame.new(0, 2.6, 0),
			shelterSize = Vector3.new(6.6, 5.2, 9),
			windFactor = 0.25,
			precipBlocked = true,
			durability = 100,
			snow = 0,
		})
		local roofSnow = {}
		for _, d in model:GetChildren() do
			if d:IsA("BasePart") and d.Name == "RoofSnow" then
				table.insert(roofSnow, d)
			end
		end
		s.roofSnow = roofSnow
		model.Parent = folder
		local anchor = model.PrimaryPart :: BasePart
		PromptUtil.create(anchor, {
			action = "Rest under the tarp",
			object = "Shelter",
			key = Enum.KeyCode.E,
			offset = Vector3.new(0, 1.5, 0),
			distance = 8,
		}, function(p)
			Registry.get("SurvivalService").setResting(p, true)
		end)
		PromptUtil.create(anchor, {
			action = "Reinforce (1 rope)",
			object = "Shelter",
			key = Enum.KeyCode.F,
			offset = Vector3.new(0, 3, 0),
			hold = 1.5,
			distance = 8,
		}, function(p)
			if (s.durability or 0) >= 95 then
				remote().notify(p, "The shelter is holding fine.", "info")
				return
			end
			if Registry.get("InventoryService").removeAll(p, { rope = 1 }) then
				s.durability = math.min(100, (s.durability or 0) + 60)
				s.warned = false
				remote().notify(p, "You re-tension the guy lines.", "good")
			else
				remote().notify(p, "You need rope.", "warn")
			end
		end)
		Registry.get("ProgressionService")
			.achieve(player, "first_shelter", ProgressionConfig.XP.FirstShelter, "First emergency shelter")
	elseif recipe.id == "tent" then
		-- A real tent: warmer and sturdier than a tarp, and it packs back up into your bag.
		local colors = {
			Color3.fromRGB(245, 200, 40),
			Color3.fromRGB(40, 120, 220),
			Color3.fromRGB(210, 45, 45),
			Color3.fromRGB(235, 110, 30),
		}
		local interiorFrame: CFrame, interiorSize: Vector3
		model, interiorFrame, interiorSize = AssetFactory.domeTent(frame, colors[math.random(1, #colors)], nil)
		s = register({
			id = 0,
			kind = recipe.id,
			model = model,
			position = frame.Position,
			radius = math.max(interiorSize.X, interiorSize.Z) / 2 + 1,
			permanent = false,
			shelterFrame = interiorFrame,
			shelterSize = interiorSize,
			windFactor = 0.1,
			precipBlocked = true,
			durability = 100,
			snow = 0,
		})
		model.Parent = folder
		local anchor = model.PrimaryPart :: BasePart
		PromptUtil.create(
			anchor,
			{
				action = "Sleep in tent",
				object = "Tent",
				key = Enum.KeyCode.E,
				offset = Vector3.new(0, 1.5, 0),
				distance = 8,
			},
			function(p)
				Registry.get("SurvivalService").setResting(p, true)
			end
		)
		PromptUtil.create(
			anchor,
			{
				action = "Pack up tent",
				object = "Tent",
				key = Enum.KeyCode.F,
				offset = Vector3.new(0, 3, 0),
				hold = 2,
				distance = 8,
			},
			function(p)
				if not table.find(structures, s) then
					return -- already packed by someone else
				end
				if Registry.get("InventoryService").add(p, "tent_pack", 1) <= 0 then
					remote().notify(p, "No room in your pack for the tent.", "warn")
					return
				end
				removeStructure(s)
				remote().notify(p, "You pack up the tent.", "good")
			end
		)
		Registry.get("ProgressionService")
			.achieve(player, "first_shelter", ProgressionConfig.XP.FirstShelter, "First emergency shelter")
	elseif recipe.id == "wind_wall" then
		model = AssetFactory.windWall(frame)
		s = register({
			id = 0,
			kind = recipe.id,
			model = model,
			position = frame.Position,
			radius = 5.5,
			permanent = false,
			windFactor = 0.4,
		})
		model.Parent = folder
	elseif recipe.id == "trail_marker" then
		model = AssetFactory.trailMarker(frame)
		s = register({
			id = 0,
			kind = recipe.id,
			model = model,
			position = frame.Position,
			radius = 0.8,
			permanent = false,
		})
		-- Visible through fog to everyone: that is the marker's whole purpose.
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(18, 18)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 400
		gui.StudsOffset = Vector3.new(0, 6.5, 0)
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromScale(1, 1)
		dot.BackgroundColor3 = Color3.fromRGB(255, 120, 20)
		dot.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = dot
		gui.Parent = model.PrimaryPart
		model.Parent = folder
	else
		return
	end
	model:SetAttribute("Builder", player.UserId)
end

local function handleBuild(player: Player, recipeId: string, desired: CFrame): (boolean, string?)
	local record = PlayerStore.getActive(player)
	if not record then
		return false, "You can't build right now."
	end
	if record.downed or record.climbing or record.carrying or record.carriedBy then
		return false, "Not now."
	end
	if building[player] then
		return false, "You're already building."
	end
	local recipe = RecipeDefs.ById[recipeId]
	if not recipe or not recipe.implemented then
		return false, "You don't know how to build that yet."
	end
	if not Registry.get("ProgressionService").hasBlueprint(player, recipeId) then
		return false, "You haven't found that blueprint."
	end
	local InventoryService = Registry.get("InventoryService")
	if recipe.requiresTool and InventoryService.count(player, recipe.requiresTool) <= 0 then
		return false, "You need a " .. recipe.requiresTool:gsub("_", " ") .. "."
	end
	for itemId, qty in recipe.cost do
		if InventoryService.count(player, itemId) < qty then
			return false, "Not enough materials."
		end
	end
	local frame, reason = BuildingService.validatePlacement(player, recipe, desired)
	if not frame then
		return false, reason
	end

	-- Build timer: stand still and stay alive.
	building[player] = true
	if record.resting then
		Registry.get("SurvivalService").setResting(player, false)
	end
	local _, _, _, root = PlayerStore.getActive(player)
	local start = (root :: BasePart).Position
	player:SetAttribute("BuildingUntil", workspace:GetServerTimeNow() + recipe.buildSeconds)
	local elapsed = 0
	while elapsed < recipe.buildSeconds do
		elapsed += task.wait(0.1)
		local r, _, _, currentRoot = PlayerStore.getActive(player)
		if not r or not currentRoot or r.downed or (currentRoot.Position - start).Magnitude > 4 then
			building[player] = nil
			player:SetAttribute("BuildingUntil", nil)
			return false, "Building interrupted."
		end
	end
	building[player] = nil
	player:SetAttribute("BuildingUntil", nil)

	-- Re-validate everything: inventory and the spot may have changed during the timer.
	local finalFrame, finalReason = BuildingService.validatePlacement(player, recipe, desired)
	if not finalFrame then
		return false, finalReason
	end
	if recipe.requiresTool and InventoryService.count(player, recipe.requiresTool) <= 0 then
		return false, "You lost your " .. recipe.requiresTool .. "."
	end
	if not InventoryService.removeAll(player, recipe.cost) then
		return false, "Not enough materials."
	end
	if recipe.requiresTool and recipe.toolDurabilityCost then
		InventoryService.useToolCharge(player, recipe.requiresTool, recipe.toolDurabilityCost)
	end
	spawnStructure(player, recipe, finalFrame)
	return true, recipe.name .. " built."
end

-- Simulation: fuel, shelter wear, snow on roofs ---------------------------------------------------

local function simulate(dt: number)
	local weather = Registry.get("WeatherService")
	for i = #structures, 1, -1 do
		local s = structures[i]
		if s.fuel and s.fuel > 0 and not s.permanent then
			local sample = weather.sampleAt(s.position)
			local env = BuildingService.environmentAt(s.position + Vector3.new(0, 1, 0))
			local burn = 1 + sample.windMs * env.windFactor / 20
			if not env.precipBlocked then
				burn += sample.precipitation * 1.5
			end
			s.fuel -= dt * burn
			if s.fuel <= 0 then
				extinguish(s)
			end
		end
		if s.durability and (s.kind == "tarp_shelter" or s.kind == "tent") then
			local sample = weather.sampleAt(s.position)
			local decayAbove = if s.kind == "tent" then TENT_DECAY_WIND else SHELTER_DECAY_WIND
			if sample.windMs > decayAbove then
				s.durability -= (sample.windMs - decayAbove) * 0.08 * dt
			end
			if sample.isSnow and sample.precipitation > 0.05 then
				s.snow = math.min(1, (s.snow or 0) + 0.01 * sample.precipitation * dt)
			else
				s.snow = math.max(0, (s.snow or 0) - 0.005 * dt)
			end
			for _, roof in s.roofSnow or {} do
				roof.Transparency = 1 - (s.snow :: number) * 0.9
			end
			if s.durability <= 25 and not s.warned then
				s.warned = true
				for _, p in Players:GetPlayers() do
					local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if root and (root.Position - s.position).Magnitude < 30 then
						remote().notify(
							p,
							if s.kind == "tent"
								then "The tent is straining in the wind!"
								else "The tarp is tearing loose in the wind! Reinforce it with rope.",
							"danger",
							"tarp" .. s.id,
							30
						)
					end
				end
			end
			if s.durability <= 0 then
				for _, p in Players:GetPlayers() do
					local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if root and (root.Position - s.position).Magnitude < 40 then
						remote().notify(
							p,
							if s.kind == "tent"
								then "The tent was torn apart by the storm!"
								else "The tarp shelter collapsed!",
							"danger"
						)
					end
				end
				removeStructure(s)
			end
		end
	end
end

function BuildingService.Init()
	folder = Instance.new("Folder")
	folder.Name = "Structures"
	folder.Parent = workspace
	Registry.get("RemoteGuard").on("Build", handleBuild)
end

function BuildingService.Start()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 1 then
			simulate(acc)
			acc = 0
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		building[player] = nil
	end)
end

return BuildingService
