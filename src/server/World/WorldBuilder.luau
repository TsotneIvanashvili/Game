--!strict
-- Builds the vertical-slice mountain section from Shared/Config/WorldLayout when the place
-- has no hand-built map (no Workspace.Mountain). Everything gameplay needs is exposed through
-- CollectionService tags, so a hand-built Studio map that uses the same tags replaces this
-- file entirely:
--
--   Camp, SupplyCrate, Outfitter, WoodSource, WaterSource, WaterVolume, RockfallZone,
--   SectionEnd, Climbable (parts only; terrain rock/ice is climbable by material)
--
-- Environmental logic applied while placing props (design section 63): trees shrink and
-- thin out with altitude and stop at the treeline, snow sits on boughs and rocks above the
-- snowline, nothing grows on the trail, in the stream or on cliff faces.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WorldLayout = require(Shared.Config.WorldLayout)
local ZoneDefs = require(Shared.Config.ZoneDefs)
local AssetFactory = require(script.Parent.AssetFactory)

local WorldBuilder = {}

local terrain = workspace.Terrain
local rng = Random.new(WorldLayout.Seed)
local mountain: Model
local snowlineY = 135
for _, zone in ZoneDefs.List do
	if zone.id == "Snowline" then
		snowlineY = zone.minY
	end
end

local function materialNamed(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.Ground
end

local function slabFrame(from: Vector3, to: Vector3, thickness: number, sink: number?): (CFrame, number)
	local mid = from:Lerp(to, 0.5)
	local length = (to - from).Magnitude
	local frame = CFrame.lookAt(mid, to) * CFrame.new(0, -thickness / 2 - (sink or 0), 0)
	return frame, length
end

local function buildTerrain()
	for _, slab in WorldLayout.Slabs do
		local frame, length = slabFrame(slab.from, slab.to, slab.thickness)
		terrain:FillBlock(frame, Vector3.new(slab.width, slab.thickness, length + 4), materialNamed(slab.material))
	end
	for _, block in WorldLayout.Blocks do
		terrain:FillBlock(CFrame.new(block.center), block.size, materialNamed(block.material))
	end
	-- Stream: carve a trench, then fill it with water below the bank.
	local stream = WorldLayout.Stream
	local carve, length = slabFrame(stream.from, stream.to, stream.depth)
	terrain:FillBlock(carve, Vector3.new(stream.width, stream.depth, length), Enum.Material.Air)
	local waterFrame = slabFrame(stream.from, stream.to, stream.depth - 0.5, 0.5)
	terrain:FillBlock(waterFrame, Vector3.new(stream.width - 1, stream.depth - 0.5, length), Enum.Material.Water)
	local volume = Instance.new("Part")
	volume.Name = "StreamVolume"
	volume.Anchored = true
	volume.CanCollide = false
	volume.CanQuery = false
	volume.CanTouch = false
	volume.Transparency = 1
	volume.CFrame = carve
	volume.Size = Vector3.new(stream.width, stream.depth + 1, length)
	volume.Parent = mountain
	CollectionService:AddTag(volume, "WaterVolume")

	terrain:SetMaterialColor(Enum.Material.Grass, Color3.fromRGB(86, 110, 64))
	terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(102, 88, 70))
	terrain:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(112, 110, 106))
	terrain:SetMaterialColor(Enum.Material.Slate, Color3.fromRGB(92, 92, 96))
	terrain:SetMaterialColor(Enum.Material.Snow, Color3.fromRGB(236, 241, 248))
	terrain:SetMaterialColor(Enum.Material.Glacier, Color3.fromRGB(170, 205, 230))
	terrain:SetMaterialColor(Enum.Material.Mud, Color3.fromRGB(78, 64, 52))

	local floor = Instance.new("Part")
	floor.Name = "WorldFloor"
	floor.Anchored = true
	floor.Size = WorldLayout.WorldFloor.size
	floor.CFrame = CFrame.new(WorldLayout.WorldFloor.center)
	floor.Material = Enum.Material.Slate
	floor.Color = Color3.fromRGB(60, 58, 56)
	floor.Parent = mountain
end

local terrainOnly = RaycastParams.new()
terrainOnly.FilterType = Enum.RaycastFilterType.Include

-- Ground hit at (x, z) on terrain, searching down from well above the mountain.
local function ground(x: number, z: number): RaycastResult?
	terrainOnly.FilterDescendantsInstances = { terrain }
	return workspace:Raycast(Vector3.new(x, 600, z), Vector3.new(0, -800, 0), terrainOnly)
end

local function groundY(x: number, z: number, fallback: number): number
	local hit = ground(x, z)
	return if hit then hit.Position.Y else fallback
end

local function keepClear(x: number, z: number): boolean
	for _, c in WorldLayout.TreeKeepClear do
		if (Vector3.new(x, 0, z) - Vector3.new(c.x, 0, c.z)).Magnitude < c.r then
			return true
		end
	end
	if math.abs(x) < WorldLayout.TrailHalfWidth and z > 40 and z < 420 then
		return true
	end
	local stream = WorldLayout.Stream
	if math.abs(x - stream.from.X) < stream.width and z > stream.from.Z - 5 and z < stream.to.Z + 5 then
		return true
	end
	return false
end

local function scatterTrees(folder: Folder)
	local seed = 1
	for _, region in WorldLayout.TreeRegions do
		local placed, attempts = 0, 0
		while placed < region.count and attempts < region.count * 8 do
			attempts += 1
			local x = rng:NextNumber(region.x0, region.x1)
			local z = rng:NextNumber(region.z0, region.z1)
			local hit = ground(x, z)
			if
				hit
				and not keepClear(x, z)
				and hit.Normal.Y > 0.82
				and hit.Material ~= Enum.Material.Water
				and hit.Material ~= Enum.Material.Rock
			then
				local y = hit.Position.Y
				-- Trees shrink with altitude and stop entirely at the treeline.
				local altitudeScale = math.clamp(1 - math.max(0, y - 40) / 220, 0.35, 1)
				if y < snowlineY + 30 then
					local height = rng:NextNumber(16, 30) * region.scale * altitudeScale
					local tree = AssetFactory.pineTree(
						CFrame.new(hit.Position) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
						height,
						y >= snowlineY - 10,
						seed
					)
					tree.Parent = folder
					seed += 1
					placed += 1
				end
			end
		end
	end
end

local function scatterRocks(folder: Folder)
	local seed = 1000
	for _, region in WorldLayout.Rocks do
		for _ = 1, region.count do
			local x = rng:NextNumber(region.x0, region.x1)
			local z = rng:NextNumber(region.z0, region.z1)
			local hit = ground(x, z)
			if hit and hit.Material ~= Enum.Material.Water and not keepClear(x, z) then
				local size = rng:NextNumber(2, 7)
				local rock = AssetFactory.rock(
					CFrame.new(hit.Position - Vector3.new(0, size * 0.2, 0)),
					size,
					hit.Position.Y >= snowlineY,
					seed
				)
				rock.Parent = folder
				seed += 1
			end
		end
	end
end

local function placeOnGround(pos: Vector3): CFrame
	return CFrame.new(pos.X, groundY(pos.X, pos.Z, pos.Y), pos.Z)
end

local function buildCamp(def: any)
	local model = Instance.new("Model")
	model.Name = def.id
	local centerFrame = placeOnGround(def.center)
	local center = Instance.new("Part")
	center.Name = "Center"
	center.Anchored = true
	center.CanCollide = false
	center.CanQuery = false
	center.Transparency = 1
	center.Size = Vector3.one
	center.CFrame = centerFrame
	center.Parent = model
	model.PrimaryPart = center

	-- Spawn: base camp uses a real SpawnLocation (where new players appear); later camps use
	-- a plain marker part that PlayerService teleports respawning players to.
	local spawnFrame = placeOnGround(def.spawn)
	local spawn: BasePart
	if def.index == 1 then
		local sl = Instance.new("SpawnLocation")
		sl.Neutral = true
		sl.Duration = 0
		sl.Material = Enum.Material.WoodPlanks
		sl.Color = Color3.fromRGB(120, 92, 62)
		spawn = sl
	else
		spawn = Instance.new("Part")
		spawn.Transparency = 1
		spawn.CanCollide = false
		spawn.CanQuery = false
	end
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(10, 1, 10)
	spawn.CFrame = spawnFrame * CFrame.new(0, 0.5, 0)
	spawn.Parent = model

	local fire = AssetFactory.campfire(placeOnGround(def.fire))
	fire.Name = "Fire"
	fire.Parent = model

	local logbook = AssetFactory.logbook(placeOnGround(def.logbook) * CFrame.Angles(0, math.rad(200), 0))
	logbook.Name = "Logbook"
	logbook.Parent = model

	local cabinFrame = placeOnGround(def.cabin.pos) * CFrame.Angles(0, math.rad(180), 0)
	local cabin, interior, interiorSize = AssetFactory.cabin(cabinFrame, def.cabin.size)
	cabin.Parent = model
	local shelter = Instance.new("Part")
	shelter.Name = "ShelterVolume"
	shelter.Anchored = true
	shelter.CanCollide = false
	shelter.CanQuery = false
	shelter.CanTouch = false
	shelter.Transparency = 1
	shelter.CFrame = interior
	shelter.Size = interiorSize
	shelter.Parent = model

	local crate = AssetFactory.supplyCrate(placeOnGround(def.supply) * CFrame.Angles(0, math.rad(-90), 0))
	crate:SetAttribute("CrateId", def.supplyTable)
	crate.Parent = model
	CollectionService:AddTag(crate, "SupplyCrate")

	if def.outfitter then
		local rack = AssetFactory.outfitterRack(placeOnGround(def.outfitter))
		rack.Name = "Outfitter"
		rack.Parent = model
		CollectionService:AddTag(rack, "Outfitter")
	end

	local water = AssetFactory.waterStation(placeOnGround(def.water.pos), def.water.kind)
	water:SetAttribute("Treated", def.water.treated)
	water.Parent = model
	CollectionService:AddTag(water, "WaterSource")

	model:SetAttribute("CampId", def.id)
	model:SetAttribute("CampName", def.name)
	model:SetAttribute("Index", def.index)
	model:SetAttribute("Radius", 45)
	model.Parent = mountain
	CollectionService:AddTag(model, "Camp")
end

local function buildResources(folder: Folder)
	for i, def in WorldLayout.WoodSources do
		local frame = placeOnGround(def.pos) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0)
		local log = AssetFactory.fallenLog(frame, 500 + i)
		log:SetAttribute("Wood", def.wood)
		log:SetAttribute("Respawn", def.respawn or -1)
		log.Parent = folder
		CollectionService:AddTag(log, "WoodSource")
	end
	for _, pos in WorldLayout.WaterSources do
		local marker = Instance.new("Part")
		marker.Name = "StreamAccess"
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.Transparency = 1
		marker.Size = Vector3.new(2, 2, 2)
		marker.CFrame = CFrame.new(pos.X, groundY(pos.X, pos.Z, pos.Y) + 1, pos.Z)
		marker:SetAttribute("Treated", false)
		marker.Parent = folder
		CollectionService:AddTag(marker, "WaterSource")
	end
end

local function buildHazards()
	for _, def in WorldLayout.RockfallZones do
		local zone = Instance.new("Part")
		zone.Name = "RockfallZone_" .. def.name
		zone.Anchored = true
		zone.CanCollide = false
		zone.CanQuery = false
		zone.CanTouch = false
		zone.Transparency = 1
		zone.CFrame = CFrame.new(def.zoneCenter)
		zone.Size = def.zoneSize
		zone:SetAttribute("PushDirection", def.pushDirection)
		for _, pos in def.releasePoints do
			local a = Instance.new("Attachment")
			a.Name = "Release"
			a.Parent = zone
			a.WorldPosition = Vector3.new(pos.X, groundY(pos.X, pos.Z, pos.Y) + 4, pos.Z)
		end
		zone.Parent = mountain
		CollectionService:AddTag(zone, "RockfallZone")
	end

	-- Ridge Col: the end of the slice, marked by a cairn and a weathered flag.
	local endDef = WorldLayout.SectionEnd
	local at = placeOnGround(endDef.pos)
	local marker = Instance.new("Part")
	marker.Name = "SectionEnd"
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.Transparency = 1
	marker.Size = Vector3.one
	marker.CFrame = at
	marker:SetAttribute("Radius", endDef.radius)
	marker.Parent = mountain
	CollectionService:AddTag(marker, "SectionEnd")
	local cairn = AssetFactory.rock(at, 4, true, 4242)
	cairn.Name = "Cairn"
	cairn.Parent = mountain
	local flag = AssetFactory.logbook(at * CFrame.new(3, 0, 0))
	flag.Name = "ColFlag"
	flag.Parent = mountain
end

function WorldBuilder.build(): boolean
	if workspace:FindFirstChild("Mountain") then
		return false -- a hand-built map is present
	end
	mountain = Instance.new("Model")
	mountain.Name = "Mountain"
	mountain.Parent = workspace

	buildTerrain()

	local trees = Instance.new("Folder")
	trees.Name = "Trees"
	trees.Parent = mountain
	scatterTrees(trees)

	local rocks = Instance.new("Folder")
	rocks.Name = "Rocks"
	rocks.Parent = mountain
	scatterRocks(rocks)

	for _, camp in WorldLayout.Camps do
		buildCamp(camp)
	end

	local resources = Instance.new("Folder")
	resources.Name = "Resources"
	resources.Parent = mountain
	buildResources(resources)

	buildHazards()

	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.3
		atmosphere.Offset = 0.1
		atmosphere.Color = Color3.fromRGB(199, 214, 230)
		atmosphere.Decay = Color3.fromRGB(106, 120, 140)
		atmosphere.Glare = 0.2
		atmosphere.Haze = 1.2
		atmosphere.Parent = Lighting
	end
	return true
end

return WorldBuilder
