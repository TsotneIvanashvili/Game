--!strict
-- Builds the generated polar mountain from Shared/Config/WorldLayout when the place has no
-- hand-built map (no Workspace.Mountain). Gameplay finds everything through CollectionService
-- tags, so a hand-built Studio map that uses the same tags replaces this file entirely:
--
--   Camp, SupplyCrate, Outfitter, WoodSource, WaterSource, RockfallZone, SectionEnd
--   (terrain Glacier/Rock is climbable by material; ladders are TrussParts, no tag needed)
--
-- Placement never raycasts terrain: Shared/Logic/TerrainModel evaluates the same operation
-- list we fill, so heights, slopes and materials are known exactly the moment we need them
-- (raycasts against terrain written in the same frame miss; that left v1 without props).
-- Camps come from the CampKit module (another workstream); a minimal camp is built here if
-- it is missing or fails, so the world always works.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WorldLayout = require(Shared.Config.WorldLayout)
local TerrainModel = require(Shared.Logic.TerrainModel)
local AssetFactory = require(script.Parent.AssetFactory)
local RouteKit = require(script.Parent.RouteKit)

local WorldBuilder = {}

local terrain = workspace.Terrain
local rng = Random.new(WorldLayout.Seed)
local model: TerrainModel.Model
local segments: { TerrainModel.Segment }
local mountain: Model

local SNOW_COLOR = Color3.fromRGB(236, 242, 250)
local GLACIER_COLOR = Color3.fromRGB(92, 205, 214)

local counts = {
	camps = 0,
	trees = 0,
	rocks = 0,
	wood = 0,
	bridges = 0,
	ladders = 0,
	markers = 0,
	hazards = 0,
	signs = 0,
}

local function materialNamed(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.Snow
end

local function folder(name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = mountain
	return f
end

-- Surface height from the model; 0 where there is no terrain (never happens inside Bounds).
function WorldBuilder.groundAt(x: number, z: number): number
	if not model then
		return 0
	end
	local h = model.heightAt(x, z)
	return if h == -math.huge then 0 else h
end
local groundAt = WorldBuilder.groundAt

local function onGround(x: number, z: number): Vector3
	return Vector3.new(x, groundAt(x, z), z)
end

-- Terrain ---------------------------------------------------------------------------------

local function boxFrame(op: TerrainModel.Op): CFrame
	return CFrame.fromMatrix(
		Vector3.new(op.cx, op.cy, op.cz),
		Vector3.new(op.rx, op.ry, op.rz),
		Vector3.new(op.ux, op.uy, op.uz),
		Vector3.new(op.bx, op.by, op.bz)
	)
end

local function applyOp(op: TerrainModel.Op)
	if op.mode == "Replace" then
		local half = Vector3.new(op.sx, op.sy, op.sz) / 2
		local center = Vector3.new(op.cx, op.cy, op.cz)
		local region = Region3.new(center - half, center + half):ExpandToGrid(4)
		terrain:ReplaceMaterial(region, 4, materialNamed(op.source), materialNamed(op.material))
		return
	end
	local material = if op.mode == "Carve" then Enum.Material.Air else materialNamed(op.material)
	if op.shape == "Box" then
		terrain:FillBlock(boxFrame(op), Vector3.new(op.sx, op.sy, op.sz), material)
	elseif op.shape == "Ball" then
		terrain:FillBall(Vector3.new(op.cx, op.cy, op.cz), op.radius, material)
	elseif op.shape == "Cylinder" then
		local frame = CFrame.new(op.cx, op.cy, op.cz)
		local ok = pcall(function()
			terrain:FillCylinder(frame, op.height, op.radius, material)
		end)
		if not ok then
			terrain:FillBlock(frame, Vector3.new(op.radius * 2, op.height, op.radius * 2), material)
		end
	end
end

-- Fills the ops of one build phase, in order. Yields a frame now and then so a long fill
-- never trips the script timeout. Returns the number of ops that failed.
local function buildTerrain(ops: { TerrainModel.Op }, phase: number): number
	local failed = 0
	local sliceStart = os.clock()
	for _, op in ops do
		if op.phase ~= phase then
			continue
		end
		local ok, err = pcall(applyOp, op)
		if not ok then
			failed += 1
			warn("[World] terrain op " .. op.name .. " failed: " .. tostring(err))
		end
		if os.clock() - sliceStart > 0.2 then
			RunService.Heartbeat:Wait()
			sliceStart = os.clock()
		end
	end
	terrain:SetMaterialColor(Enum.Material.Snow, SNOW_COLOR)
	terrain:SetMaterialColor(Enum.Material.Glacier, GLACIER_COLOR)
	terrain:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(104, 104, 112))
	terrain:SetMaterialColor(Enum.Material.Slate, Color3.fromRGB(92, 92, 100))
	return failed
end

local function setMaterial(part: BasePart, name: string, fallback: Enum.Material)
	local ok = pcall(function()
		part.Material = (Enum.Material :: any)[name]
	end)
	if not ok then
		part.Material = fallback
	end
end

-- The snow skirt: flat Snow Parts just under the terrain ground top, reaching far beyond the
-- terrain so every long sightline ends on snow. Walkable (a player who wanders off the
-- terrain still has ground under their feet).
local function buildSkirt()
	local sk = WorldLayout.Skirt
	local tile = 2048
	local x = sk.x0
	while x < sk.x1 do
		local z = sk.z0
		while z < sk.z1 do
			local w, d = math.min(tile, sk.x1 - x), math.min(tile, sk.z1 - z)
			local p = Instance.new("Part")
			p.Name = "SnowSkirt"
			p.Anchored = true
			p.CanCollide = true
			p.CanQuery = true
			p.CanTouch = false
			p.CastShadow = false
			p.Color = SNOW_COLOR
			setMaterial(p, "Snow", Enum.Material.SmoothPlastic)
			p.Size = Vector3.new(w, 4, d)
			p.CFrame = CFrame.new(x + w / 2, sk.top - 2, z + d / 2)
			p.Parent = mountain
			z += tile
		end
		x += tile
	end
end

-- Backdrop peaks: a Glacier-coloured cube standing on one corner (a three-faced pyramid above
-- the ground) with a smaller Snow cube on its tip as the snow cap. Pure scenery.
local function buildScenery()
	local scenery = folder("Scenery")
	local up = Vector3.new(0, 1, 0)
	for i, p in WorldLayout.Scenery do
		local axes = TerrainModel.peakAxes(p.yaw or 0)
		local a1 = Vector3.new(axes[1][1], axes[1][2], axes[1][3])
		local a2 = Vector3.new(axes[2][1], axes[2][2], axes[2][3])
		local a3 = Vector3.new(axes[3][1], axes[3][2], axes[3][3])
		local apex = Vector3.new(p.x, WorldLayout.Ground.top + p.top, p.z)
		local function cube(name: string, side: number, tip: Vector3, color: Color3, material: string)
			local part = Instance.new("Part")
			part.Name = name
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Color = color
			setMaterial(part, material, Enum.Material.SmoothPlastic)
			part.Size = Vector3.new(side, side, side)
			part.CFrame = CFrame.fromMatrix(tip - up * (side * math.sqrt(3) / 2), a1, a2, a3)
			part.Parent = scenery
		end
		cube("Peak" .. i, TerrainModel.peakSide(p.top), apex, GLACIER_COLOR, "Glacier")
		cube("PeakSnow" .. i, p.top * 0.52, apex + up, SNOW_COLOR, "Snow")
	end
end

-- Invisible catch floor tiles far below the terrain (parts max out at 2048 studs per axis).
local function buildSafetyFloor()
	local g = WorldLayout.Ground
	local tile = 2048
	local x = g.x0
	while x < g.x1 do
		local z = g.z0
		while z < g.z1 do
			local p = Instance.new("Part")
			p.Name = "SafetyFloor"
			p.Anchored = true
			p.CanCollide = true
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
			p.Transparency = 1
			p.Size = Vector3.new(tile, 4, tile)
			p.CFrame = CFrame.new(x + tile / 2, WorldLayout.SafetyFloorY, z + tile / 2)
			p.Parent = mountain
			z += tile
		end
		x += tile
	end
end

-- Camps -------------------------------------------------------------------------------------

local function loadCampKit(): any
	local moduleScript = script.Parent:FindFirstChild("CampKit")
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		warn("[World] CampKit module not found; building minimal fallback camps.")
		return nil
	end
	local ok, result = pcall(require, moduleScript)
	if ok and type(result) == "table" and type((result :: any).build) == "function" then
		return result
	end
	warn("[World] CampKit failed to load (" .. tostring(result) .. "); building minimal fallback camps.")
	return nil
end

local function tagCamp(camp: Model, def: any)
	if camp:GetAttribute("Index") == nil then
		camp:SetAttribute("Index", def.index)
	end
	if camp:GetAttribute("CampId") == nil then
		camp:SetAttribute("CampId", def.id)
	end
	if camp:GetAttribute("CampName") == nil then
		camp:SetAttribute("CampName", def.name)
	end
	if camp:GetAttribute("Radius") == nil then
		camp:SetAttribute("Radius", def.radius)
	end
	if not CollectionService:HasTag(camp, "Camp") then
		CollectionService:AddTag(camp, "Camp")
	end
end

-- Just enough camp for every system to work: pivot, spawn, fire, logbook, supply crate.
local function fallbackCamp(def: any): Model
	local camp = Instance.new("Model")
	camp.Name = def.id
	local center = Instance.new("Part")
	center.Name = "Center"
	center.Anchored = true
	center.CanCollide = false
	center.CanQuery = false
	center.CanTouch = false
	center.Transparency = 1
	center.Size = Vector3.one
	center.CFrame = CFrame.new(onGround(def.center.X, def.center.Z))
	center.Parent = camp
	camp.PrimaryPart = center

	local spawn: BasePart
	if def.index == 1 then
		local sl = Instance.new("SpawnLocation")
		sl.Neutral = true
		sl.Duration = 0
		sl.Material = Enum.Material.WoodPlanks
		sl.Color = Color3.fromRGB(214, 180, 120)
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
	spawn.CFrame = CFrame.new(onGround(def.spawn.X, def.spawn.Z) + Vector3.new(0, 0.5, 0))
	spawn.Parent = camp

	local c = def.center
	local function place(name: string, builder: () -> Instance?)
		local ok, result = pcall(builder)
		if ok and result then
			result.Name = name
			result.Parent = camp
		elseif not ok then
			warn("[World] fallback camp " .. name .. ": " .. tostring(result))
		end
	end
	place("Fire", function()
		return AssetFactory.campfire(CFrame.new(onGround(c.X, c.Z + 12)))
	end)
	place("Logbook", function()
		return AssetFactory.logbook(CFrame.new(onGround(c.X - 10, c.Z + 4)) * CFrame.Angles(0, math.rad(200), 0))
	end)
	place("SupplyCrate", function()
		local crate = AssetFactory.supplyCrate(CFrame.new(onGround(c.X + 14, c.Z)) * CFrame.Angles(0, math.rad(-90), 0))
		crate:SetAttribute("CrateId", def.supplyTable)
		CollectionService:AddTag(crate, "SupplyCrate")
		return crate
	end)
	if def.index == 1 then
		place("Outfitter", function()
			local rack = AssetFactory.outfitterRack(CFrame.new(onGround(c.X + 20, c.Z - 18)))
			CollectionService:AddTag(rack, "Outfitter")
			return rack
		end)
	end
	tagCamp(camp, def)
	return camp
end

local function buildCamps()
	local campsFolder = folder("Camps")
	local CampKit = loadCampKit()
	for _, def in WorldLayout.Camps do
		local camp: Model? = nil
		if CampKit then
			local ok, result = pcall(CampKit.build, def, groundAt)
			if ok and typeof(result) == "Instance" and result:IsA("Model") then
				camp = result
			else
				warn("[World] CampKit.build(" .. def.id .. ") failed: " .. tostring(result))
			end
		end
		local built: Model = camp or fallbackCamp(def)
		tagCamp(built, def)
		if not built.Parent then
			built.Parent = campsFolder
		end
		counts.camps += 1
	end
end

-- Scatter -----------------------------------------------------------------------------------

local function inCampArea(x: number, z: number, margin: number): boolean
	for _, camp in WorldLayout.Camps do
		local c = camp.center
		if math.abs(x - c.X) < camp.footprint.X / 2 + margin and math.abs(z - c.Z) < camp.footprint.Z / 2 + margin then
			return true
		end
	end
	return false
end

-- A spot is usable for a prop if it is snow, gentle, off the trail and out of the camps.
local function goodSpot(x: number, z: number, maxSlope: number, trailClearance: number): (boolean, number)
	local h, mat = model.heightAt(x, z)
	if h == -math.huge or mat ~= "Snow" then
		return false, 0
	end
	if model.slopeAt(x, z) > maxSlope then
		return false, 0
	end
	if inCampArea(x, z, 8) or TerrainModel.distanceToRoute(segments, x, z) < trailClearance then
		return false, 0
	end
	return true, h
end

local function scatterTrees()
	local trees = folder("Trees")
	local seed = 1
	for _, cluster in WorldLayout.TreeClusters do
		local placed, attempts = 0, 0
		while placed < cluster.count and attempts < cluster.count * 10 do
			attempts += 1
			local a = rng:NextNumber(0, math.pi * 2)
			local d = math.sqrt(rng:NextNumber()) * cluster.r
			local x, z = cluster.x + math.cos(a) * d, cluster.z + math.sin(a) * d
			local ok, h = goodSpot(x, z, 20, 12)
			if ok then
				local height = rng:NextNumber(16, 28)
				local built, tree = pcall(
					AssetFactory.pineTree,
					CFrame.new(x, h - 0.3, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
					height,
					true,
					seed
				)
				seed += 1
				if built and tree then
					tree.Parent = trees
					placed += 1
					counts.trees += 1
				end
			end
		end
	end
end

local function scatterRocks()
	local rocks = folder("Rocks")
	local spec = WorldLayout.RockScatter
	local walked: { TerrainModel.Segment } = {}
	local total = 0
	for _, s in segments do
		if s.via == "Walk" then
			table.insert(walked, s)
			total += TerrainModel.segmentLength(s)
		end
	end
	local seed = 1000
	local attempts = 0
	while counts.rocks < spec.count and attempts < spec.count * 6 do
		attempts += 1
		-- Pick a point along the walked route (by length), then step off to one side.
		local pick = rng:NextNumber(0, total)
		local s = walked[#walked]
		for _, candidate in walked do
			local l = TerrainModel.segmentLength(candidate)
			if pick <= l then
				s = candidate
				break
			end
			pick -= l
		end
		local dx, dz = s.bx - s.ax, s.bz - s.az
		local flat = math.max(math.sqrt(dx * dx + dz * dz), 1e-6)
		local t = rng:NextNumber()
		local side = if rng:NextNumber() < 0.5 then -1 else 1
		local off = rng:NextNumber(spec.near, spec.far) * side
		local x = s.ax + dx * t + dz / flat * off
		local z = s.az + dz * t - dx / flat * off
		local ok, h = goodSpot(x, z, 32, spec.near - 2)
		if ok then
			local size = rng:NextNumber(spec.minSize, spec.maxSize)
			local built, rock = pcall(
				AssetFactory.rock,
				CFrame.new(x, h - size * 0.2, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
				size,
				true,
				seed
			)
			seed += 1
			if built and rock then
				rock.Parent = rocks
				counts.rocks += 1
			end
		end
	end
end

-- Resources and hazards ---------------------------------------------------------------------

local function buildWood()
	local resources = folder("Resources")
	for i, def in WorldLayout.WoodSources do
		local base = CFrame.new(onGround(def.pos.X, def.pos.Z)) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0)
		local ok, source = pcall(function(): Model
			if def.woodpile then
				-- A finite camp woodpile: three logs stacked in a little pyramid.
				local pile = Instance.new("Model")
				pile.Name = "Woodpile"
				local first: BasePart? = nil
				for j, offset in { CFrame.new(0, 0, -0.75), CFrame.new(0, 0, 0.75), CFrame.new(0, 1.1, 0) } do
					local log = AssetFactory.fallenLog(base * offset, 900 + j)
					log.Parent = pile
					first = first or log.PrimaryPart
				end
				pile.PrimaryPart = first
				return pile
			end
			return AssetFactory.fallenLog(base, 500 + i)
		end)
		if ok and source then
			source:SetAttribute("Wood", def.wood)
			source:SetAttribute("Respawn", def.respawn or -1)
			source.Parent = resources
			CollectionService:AddTag(source, "WoodSource")
			counts.wood += 1
		else
			warn("[World] wood source " .. i .. ": " .. tostring(source))
		end
	end
	for _, pos in WorldLayout.WaterSources do
		local marker = Instance.new("Part")
		marker.Name = "WaterAccess"
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.Transparency = 1
		marker.Size = Vector3.new(2, 2, 2)
		marker.CFrame = CFrame.new(onGround(pos.X, pos.Z) + Vector3.new(0, 1, 0))
		marker:SetAttribute("Treated", false)
		marker.Parent = resources
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
			a.WorldPosition = onGround(pos.X, pos.Z) + Vector3.new(0, 4, 0)
		end
		zone.Parent = mountain
		CollectionService:AddTag(zone, "RockfallZone")
		counts.hazards += 1
	end
end

local function buildSummit()
	local def = WorldLayout.SectionEnd
	local at = onGround(def.pos.X, def.pos.Z)
	local marker = Instance.new("Part")
	marker.Name = "SectionEnd"
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.Transparency = 1
	marker.Size = Vector3.one
	marker.CFrame = CFrame.new(at)
	marker:SetAttribute("Radius", def.radius)
	marker.Parent = mountain
	CollectionService:AddTag(marker, "SectionEnd")
	RouteKit.summitFlag(at).Parent = mountain
end

-- Route props -------------------------------------------------------------------------------

-- Where the wall starts when walking from a ladder's foot towards its top.
local function wallDistance(s: TerrainModel.Segment): number
	local dx, dz = s.bx - s.ax, s.bz - s.az
	local flat = math.sqrt(dx * dx + dz * dz)
	local rise = s.by - s.ay
	local d = 0
	while d < flat do
		if model.heightAt(s.ax + dx / flat * d, s.az + dz / flat * d) > s.ay + rise * 0.5 then
			return d
		end
		d += 0.25
	end
	return flat
end

-- Points along the main route between two ids, `offset` studs to one side, every `step`.
local function routeLine(fromId: string, toId: string, offset: number, side: number, step: number): { Vector3 }
	local points = {}
	local active = false
	for _, s in segments do
		if s.route == "Main" then
			if s.fromId == fromId then
				active = true
			end
			if active and s.via == "Walk" then
				local dx, dz = s.bx - s.ax, s.bz - s.az
				local flat = math.sqrt(dx * dx + dz * dz)
				if flat > 1 then
					local px, pz = dz / flat * offset * side, -dx / flat * offset * side
					local n = math.max(1, math.floor(flat / step + 0.5))
					for k = (if #points == 0 then 0 else 1), n do
						local t = k / n
						table.insert(points, onGround(s.ax + dx * t + px, s.az + dz * t + pz))
					end
				end
			end
			if active and s.toId == toId then
				break
			end
		end
	end
	return points
end

local function buildRoute()
	local route = folder("Route")
	local width = WorldLayout.BridgeWidth
	for _, s in segments do
		if s.via == "Bridge" then
			local bridge = RouteKit.ropeBridge(onGround(s.ax, s.az), onGround(s.bx, s.bz), width)
			bridge.Parent = route
			counts.bridges += 1
		elseif s.via == "Ladder" then
			local dx, dz = s.bx - s.ax, s.bz - s.az
			local flat = math.sqrt(dx * dx + dz * dz)
			local ux, uz = dx / flat, dz / flat
			local face = wallDistance(s)
			-- The 2-stud truss stands with its back against the wall face.
			local foot = Vector3.new(s.ax + ux * (face - 1.05), s.ay, s.az + uz * (face - 1.05))
			local top = Vector3.new(s.ax + ux * (face + 2), s.by, s.az + uz * (face + 2))
			RouteKit.ladder(foot, top).Parent = route
			counts.ladders += 1
		end
	end

	local markers = Instance.new("Folder")
	markers.Name = "Markers"
	markers.Parent = route
	for _, m in TerrainModel.markers(WorldLayout, model, WorldLayout.MarkerSpacing, WorldLayout.MarkerOffset) do
		RouteKit.markerPole(Vector3.new(m.x, m.y, m.z), m.yaw).Parent = markers
		counts.markers += 1
	end

	for _, sign in WorldLayout.Signs do
		local at = onGround(sign.at.X, sign.at.Z)
		RouteKit.warningSign(at, sign.text, Vector3.new(sign.toward.X, at.Y, sign.toward.Z)).Parent = route
		counts.signs += 1
	end

	for _, fence in WorldLayout.Fences do
		for _, side in fence.sides do
			local points = routeLine(fence.from, fence.to, fence.offset, side, 12)
			if #points >= 2 then
				RouteKit.ropeFence(points).Parent = route
			end
		end
	end
	for _, rope in WorldLayout.FixedRopes do
		local points = routeLine(rope.from, rope.to, rope.offset, rope.side, 18)
		if #points >= 2 then
			RouteKit.fixedRope(points).Parent = route
		end
	end
end

local function buildAtmosphere()
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.32
		atmosphere.Offset = 0.15
		atmosphere.Color = Color3.fromRGB(214, 228, 240)
		atmosphere.Decay = Color3.fromRGB(150, 172, 196)
		atmosphere.Glare = 0.2
		atmosphere.Haze = 1.4
		atmosphere.Parent = Lighting
	end
end

-- Runs a build step; a failing step is reported but never stops the rest of the world.
local function step(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		warn("[World] " .. name .. " failed: " .. tostring(err))
	end
end

local function buildAll(started: number)
	mountain = Instance.new("Model")
	mountain.Name = "Mountain"
	mountain.Parent = workspace

	local ops = TerrainModel.ops(WorldLayout)
	model = TerrainModel.new(ops)
	segments = TerrainModel.segments(WorldLayout)

	-- Phase 1: the Base Camp basin and its surroundings, then the camps, then the rest.
	local failed = buildTerrain(ops, 1)
	buildSafetyFloor()
	step("skirt", buildSkirt)
	step("scenery", buildScenery)
	-- Let the engine settle the new voxels before anything else touches the terrain.
	for _ = 1, 3 do
		RunService.Heartbeat:Wait()
	end
	step("camps", buildCamps)
	failed += buildTerrain(ops, 2)
	for _ = 1, 3 do
		RunService.Heartbeat:Wait()
	end

	step("trees", scatterTrees)
	step("rocks", scatterRocks)
	step("wood", buildWood)
	step("hazards", buildHazards)
	step("summit", buildSummit)
	step("route", buildRoute)
	buildAtmosphere()

	-- Sanity check (the only terrain raycast): is there ground under Base Camp?
	local base = WorldLayout.Camps[1].center
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { terrain }
	local hit = workspace:Raycast(base + Vector3.new(0, 60, 0), Vector3.new(0, -120, 0), params)
	local terrainState = if failed == 0 and hit
		then "ok"
		else string.format("PROBLEM (%d failed ops, ground %s)", failed, if hit then "found" else "missing")

	print(
		string.format(
			"[World] terrain %s | camps %d | trees %d | rocks %d | wood %d | bridges %d | ladders %d | markers %d | hazards %d | built in %.2fs",
			terrainState,
			counts.camps,
			counts.trees,
			counts.rocks,
			counts.wood,
			counts.bridges,
			counts.ladders,
			counts.markers,
			counts.hazards,
			os.clock() - started
		)
	)
end

-- Builds the world (unless a hand-built Workspace.Mountain exists) and then, no matter what,
-- sets workspace attribute WorldReady = true: character spawning waits for it.
function WorldBuilder.build(): boolean
	if workspace:FindFirstChild("Mountain") then
		workspace:SetAttribute("WorldReady", true)
		return false -- a hand-built map is present
	end
	local started = os.clock()
	local ok, err = pcall(buildAll, started)
	if not ok then
		warn("[World] build failed: " .. tostring(err))
	end
	workspace:SetAttribute("WorldReady", true)
	return true
end

return WorldBuilder
