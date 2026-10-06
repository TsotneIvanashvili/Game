--!strict
-- CampKit: builds a complete camp from a definition in the art-direction-v2 style
-- (docs/ART_DIRECTION.md sections 5 and 7) and wires it to the CampService tag contract.
--
--   local camp = CampKit.build(def, groundAt)   -- returns an UNPARENTED Model; parent it
--
--   def = {
--     id: string, name: string, index: number,
--     center: Vector3,            -- only X/Z are used; heights come from groundAt
--     size: "Base" | "Small"?,    -- default: "Base" for index 1, "Small" otherwise
--     supplyTable: string,        -- LoadoutConfig.SupplyAllowance key, becomes CrateId
--     spawn: Vector3?,            -- world X/Z of the respawn point (default: a spot near the fire)
--     uphill: Vector3?,           -- optional: direction to the next camp (rotates the layout)
--     yaw: number?,               -- optional: layout rotation in degrees (ignored if uphill)
--     radius: number?,            -- optional: overrides the Radius attribute
--     tents: number?,             -- optional (Small only): small tents besides the group tent, 1-3
--   }                             -- unknown fields are ignored
--   groundAt(x, z) -> number      -- terrain height at a world X/Z
--
-- Layout frame: origin = camp centre on the ground, local +Z = uphill (the way out along the
-- route), local -Z = where players arrive from. With no uphill/yaw, local axes = world axes.
-- Every prop stands on groundAt; tents and buildings sit on the highest ground under their
-- footprint with a snow-coloured plinth filling any drop, so nothing floats.
--
-- Contract (docs/ARCHITECTURE.md section 16 and CampService):
--   Model tagged "Camp", attributes CampId, CampName, Index, Radius; PrimaryPart "Center", so
--   the pivot is the camp centre. Direct children:
--     Spawn           BasePart: index 1 a SpawnLocation (Neutral, Duration 0), else invisible
--     Fire            campfire Model (BasePart child "Embers")
--     Logbook         Model, PrimaryPart "Post"
--     ShelterVolume   invisible boxes, one per tent / building interior
--     CheckpointRing  invisible BasePart at the ring centre, attribute Radius
--     SupplyCrate     Model tagged "SupplyCrate", attribute CrateId = def.supplyTable
--     Meltwater       Model tagged "WaterSource", attribute Treated = true
--     Outfitter       (Base only) the mannequin wall Model, tagged "Outfitter", PrimaryPart "Counter"
--     RescueSpawn     (Base only) invisible part on the rescue station deck, for evacuations
--   plus BaseParts named "Mat" tagged "SleepSpot" (one per sleeping mat) inside the tents.

local CollectionService = game:GetService("CollectionService")

local AssetFactory = require(script.Parent.AssetFactory)

local CampKit = {}

export type CampDef = {
	id: string,
	name: string,
	index: number,
	center: Vector3,
	size: string?,
	supplyTable: string,
	spawn: Vector3?,
	uphill: Vector3?,
	yaw: number?,
	radius: number?,
	tents: number?,
}

type Ground = (number, number) -> number

local P = AssetFactory.Palette
local TENT_COLORS = { P.yellow, P.blue, P.red, P.purple, P.orange }
local BASE_RADIUS = 70
local SMALL_RADIUS = 32

local function invisible(parent: Instance, name: string, cf: CFrame, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
	return p
end

local function countParts(model: Instance): number
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

function CampKit.build(def: CampDef, groundAt: Ground): Model
	local isBase = if def.size then def.size == "Base" else def.index == 1
	local model = Instance.new("Model")
	model.Name = def.id

	local yaw = math.rad(def.yaw or 0)
	local uphill = def.uphill
	if uphill and Vector3.new(uphill.X, 0, uphill.Z).Magnitude > 0.01 then
		yaw = math.atan2(uphill.X, uphill.Z) -- local +Z -> uphill
	end
	local rot = CFrame.Angles(0, yaw, 0)
	local cx, cz = def.center.X, def.center.Z

	-- Local layout coordinates -> world X/Z (Y = 0).
	local function world(lx: number, lz: number): Vector3
		local p = rot * Vector3.new(lx, 0, lz)
		return Vector3.new(cx + p.X, 0, cz + p.Z)
	end
	-- Ground frame at a local spot; `face` (degrees) turns the prop, 0 = its front toward local -Z.
	local function frame(lx: number, lz: number, face: number?): CFrame
		local p = world(lx, lz)
		return CFrame.new(p.X, groundAt(p.X, p.Z), p.Z) * rot * CFrame.Angles(0, math.rad(face or 0), 0)
	end
	-- Frame for a w x d footprint standing on its highest (or lowest) ground sample, plus the
	-- height difference across the footprint.
	local function footprint(
		lx: number,
		lz: number,
		face: number,
		w: number,
		d: number,
		high: boolean
	): (CFrame, number)
		local turn = rot * CFrame.Angles(0, math.rad(face), 0)
		local centre = world(lx, lz)
		local lo, hi = math.huge, -math.huge
		for _, u in { -0.5, 0, 0.5 } do
			for _, v in { -0.5, 0, 0.5 } do
				local p = centre + turn * Vector3.new(u * w, 0, v * d)
				local y = groundAt(p.X, p.Z)
				lo = math.min(lo, y)
				hi = math.max(hi, y)
			end
		end
		return CFrame.new(centre.X, if high then hi else lo, centre.Z) * turn, hi - lo
	end
	-- Heading (degrees) that turns a prop at (lx, lz) to face local point (tx, tz).
	local function facing(lx: number, lz: number, tx: number, tz: number): number
		return math.deg(math.atan2(-(tx - lx), -(tz - lz)))
	end
	local function plinth(cf: CFrame, w: number, d: number, drop: number)
		if drop > 0.15 then
			local h = drop + 1.2
			AssetFactory.part(model, {
				name = "Plinth",
				size = Vector3.new(w + 1, h, d + 1),
				cframe = cf * CFrame.new(0, -h / 2 + 0.05, 0),
				color = P.snow,
				collide = true,
			})
		end
	end
	local function shelter(cf: CFrame, size: Vector3)
		invisible(model, "ShelterVolume", cf, size)
	end
	local function put(m: Model, name: string?): Model
		if name then
			m.Name = name
		end
		m.Parent = model
		return m
	end
	-- Tent of `kind` ("dome" | "aframe" | "big") at a local spot, facing the fire unless told.
	local function tent(
		kind: string,
		lx: number,
		lz: number,
		color: Color3,
		size: Vector3?,
		face: number?
	): (Model, CFrame)
		local f = face or facing(lx, lz, 0, 0)
		local w = if size then size.X else 8
		local d = if size then size.Z else 8
		local cf, drop = footprint(lx, lz, f, w + 1, d + 1, true)
		local m: Model, interior: CFrame, isize: Vector3
		if kind == "dome" then
			m, interior, isize = AssetFactory.domeTent(cf, color, size)
		elseif kind == "aframe" then
			m, interior, isize = AssetFactory.aFrameTent(cf, color, size)
		else
			m, interior, isize = AssetFactory.bigTent(cf, color, size)
		end
		put(m)
		plinth(cf, w, d, drop)
		shelter(interior, isize)
		return m, cf
	end
	local function sleepSpot(parent: Instance, cf: CFrame)
		local mat = AssetFactory.sleepingMat(cf)
		mat.Parent = parent
		CollectionService:AddTag(mat.PrimaryPart :: BasePart, "SleepSpot")
	end
	-- Warm light hanging from a tent's centre pole.
	local function hangingLamp(parent: Instance, cf: CFrame)
		local bulb = AssetFactory.part(parent, {
			name = "Lantern",
			size = Vector3.new(0.9, 0.9, 0.9),
			cframe = cf,
			color = P.warmLight,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Ball,
		})
		bulb.CastShadow = false
		local light = Instance.new("PointLight")
		light.Range = 24
		light.Brightness = 1.2
		light.Color = P.warmLight
		light.Parent = bulb
	end
	-- Log bench at a local spot, lying tangent to the circle around the fire.
	local function bench(lx: number, lz: number)
		local a = math.atan2(lz, lx)
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a)) * 2.2
		local c = frame(lx, lz)
		local axis = rot * tangent
		AssetFactory.cylinderBetween(
			model,
			c.Position - axis + Vector3.new(0, 0.5, 0),
			c.Position + axis + Vector3.new(0, 0.5, 0),
			1.1,
			{
				name = "Bench",
				color = P.log,
				material = Enum.Material.Wood,
				collide = true,
			}
		)
	end
	local function lamp(lx: number, lz: number)
		put(AssetFactory.lampPost(frame(lx, lz, facing(lx, lz, 0, 0))))
	end
	local function flag(lx: number, lz: number, color: Color3)
		put(AssetFactory.flagPole(frame(lx, lz, facing(lx, lz, 0, 0)), color))
	end
	local function crates(lx: number, lz: number, n: number)
		local cf = footprint(lx, lz, facing(lx, lz, 0, 0), 6.4, 6.4, false)
		put(AssetFactory.crateStack(cf, n))
	end

	-- Centre (pivot) ------------------------------------------------------------------------
	local centreFrame = frame(0, 0)
	local centre = invisible(model, "Center", centreFrame, Vector3.one)
	model.PrimaryPart = centre

	-- Campfire, the social centre ----------------------------------------------------------
	put(AssetFactory.campfire(frame(0, 0)), "Fire")
	if isBase then
		for _, deg in { 45, 135, 225, 315 } do
			bench(math.cos(math.rad(deg)) * 6.5, math.sin(math.rad(deg)) * 6.5)
		end
	else
		bench(6.5, 0)
		bench(-6.5, 0)
	end

	-- Spawn ---------------------------------------------------------------------------------
	local spawnLocal = if isBase then Vector2.new(0, 16) else Vector2.new(-5, -4)
	local spawnFrame: CFrame
	if def.spawn then
		spawnFrame = CFrame.new(def.spawn.X, groundAt(def.spawn.X, def.spawn.Z), def.spawn.Z) * rot
	else
		spawnFrame = frame(spawnLocal.X, spawnLocal.Y)
	end
	if def.index == 1 then
		local sl = Instance.new("SpawnLocation")
		sl.Name = "Spawn"
		sl.Neutral = true
		sl.Duration = 0
		sl.Anchored = true
		sl.Size = Vector3.new(12, 0.6, 12)
		sl.CFrame = spawnFrame * CFrame.new(0, -0.1, 0)
		sl.Material = Enum.Material.WoodPlanks
		sl.Color = P.crate
		sl.TopSurface = Enum.SurfaceType.Smooth
		sl.BottomSurface = Enum.SurfaceType.Smooth
		sl.Parent = model
	else
		invisible(model, "Spawn", spawnFrame * CFrame.new(0, 0.5, 0), Vector3.new(6, 1, 6))
	end

	-- Checkpoint ring + logbook ------------------------------------------------------------
	local ringLocal = if isBase then Vector2.new(0, 28) else Vector2.new(0, -15)
	local ringFrame = frame(ringLocal.X, ringLocal.Y)
	local ringVisual = put(AssetFactory.checkpointRing(ringFrame, 5))
	for _, seg in ringVisual:GetChildren() do
		if seg:IsA("BasePart") and seg.Name == "Segment" then
			local p = seg.Position
			seg.CFrame += Vector3.new(0, groundAt(p.X, p.Z) + 0.1 - p.Y, 0)
		end
	end
	local trigger = invisible(model, "CheckpointRing", ringFrame * CFrame.new(0, 0.5, 0), Vector3.new(1, 1, 1))
	trigger:SetAttribute("Radius", 5.5)
	local logX, logZ = ringLocal.X + 7.5, ringLocal.Y - (if isBase then 1 else 0)
	put(AssetFactory.logbook(frame(logX, logZ, facing(logX, logZ, ringLocal.X, ringLocal.Y))), "Logbook")

	-- Camp name: floating cyan label and a wooden sign --------------------------------------
	local label = invisible(model, "CampLabel", centreFrame, Vector3.one)
	AssetFactory.billboard(
		label,
		def.name,
		P.cyan,
		P.navy,
		if isBase then Vector2.new(30, 7) else Vector2.new(22, 5),
		if isBase then 30 else 20,
		800
	)

	-- Supplies and water --------------------------------------------------------------------
	local crateLocal = if isBase then Vector2.new(-18, 4) else Vector2.new(13, -7)
	local crate = put(
		AssetFactory.supplyCrate(frame(crateLocal.X, crateLocal.Y, facing(crateLocal.X, crateLocal.Y, 0, 0))),
		"SupplyCrate"
	)
	crate:SetAttribute("CrateId", def.supplyTable)
	CollectionService:AddTag(crate, "SupplyCrate")
	local waterLocal = if isBase then Vector2.new(-14, 13) else Vector2.new(-12, -8)
	local water = put(
		AssetFactory.waterStation(
			frame(waterLocal.X, waterLocal.Y, facing(waterLocal.X, waterLocal.Y, 0, 0)),
			"Meltwater"
		)
	)
	water:SetAttribute("Treated", true)
	CollectionService:AddTag(water, "WaterSource")

	if isBase then
		-- Equipment tent: big yellow walk-in tent, door toward the fire --------------------
		local eq, eqf = tent("big", -28, -36, P.yellow, Vector3.new(40, 14, 28), 180)
		eq.Name = "EquipmentTent"
		local eqWall = 6.3 -- bigTent wall height for H = 14 (clamp(H * 0.45, 6, H - 2.5))
		local outfitter = Instance.new("Model")
		outfitter.Name = "Outfitter"
		local counter = AssetFactory.part(outfitter, {
			name = "Counter",
			size = Vector3.new(14, 3, 2.4),
			cframe = eqf * CFrame.new(0, 1.8, 3),
			color = P.crate,
			material = Enum.Material.WoodPlanks,
			collide = true,
		})
		outfitter.PrimaryPart = counter
		AssetFactory.part(outfitter, {
			name = "CounterTop",
			size = Vector3.new(14.6, 0.4, 3),
			cframe = eqf * CFrame.new(0, 3.5, 3),
			color = P.white,
		}).CastShadow =
			false
		local displays = {
			{ kind = "jacket", color = P.red },
			{ kind = "backpack", color = Color3.fromRGB(30, 50, 110) },
			{ kind = "helmet", color = P.blue },
			{ kind = "boots", color = Color3.fromRGB(30, 45, 90) },
			{ kind = "jacket", color = P.blue },
			{ kind = "backpack", color = P.orange },
		}
		for i, d in displays do
			local m = AssetFactory.mannequin(eqf * CFrame.new(-12.5 + (i - 1) * 5, 0.3, 8.5), d.kind, d.color)
			m.Parent = outfitter
		end
		outfitter.Parent = model
		CollectionService:AddTag(outfitter, "Outfitter")
		AssetFactory.banner(eqf * CFrame.new(0, 8, 13.3), "EQUIPMENT", 18).Parent = eq
		AssetFactory.banner(eqf * CFrame.new(0, eqWall + 2.6, -14.23), "EQUIPMENT", 16).Parent = eq
		AssetFactory.outfitterRack(eqf * CFrame.new(-17, 0.3, -2) * CFrame.Angles(0, math.rad(90), 0)).Parent = eq
		AssetFactory.crateStack(eqf * CFrame.new(15, 0.3, -6), 3).Parent = eq
		for _, z in { -7, 7 } do
			hangingLamp(eq, eqf * CFrame.new(0.75, 10, z))
		end

		-- Sleeping tent: blue walk-in tent with a row of mats ------------------------------
		local sl, slf = tent("big", 16, -38, P.blue, Vector3.new(24, 11, 18), 180)
		sl.Name = "SleepingTent"
		for i = 0, 5 do
			sleepSpot(sl, slf * CFrame.new(-8.75 + i * 3.5, 0.3, 4.6))
		end
		hangingLamp(sl, slf * CFrame.new(0.75, 7.5, -4.5))

		-- Rescue station, stairs toward the fire -------------------------------------------
		local rsf = footprint(46, -8, 90, 26, 38, true)
		local rs, rsInterior, rsSize = AssetFactory.rescueStation(rsf)
		put(rs)
		shelter(rsInterior, rsSize)
		invisible(model, "RescueSpawn", rsf * CFrame.new(0, 6.5, -6.5), Vector3.new(4, 1, 4))

		-- Ring of small coloured tents --------------------------------------------------------
		local ring = {
			{ x = -52, z = -12, kind = "dome" },
			{ x = -46, z = 6, kind = "aframe" },
			{ x = -44, z = 24, kind = "dome" },
			{ x = -32, z = 40, kind = "aframe" },
			{ x = -15, z = 48, kind = "dome" },
			{ x = 15, z = 48, kind = "aframe" },
			{ x = 32, z = 40, kind = "dome" },
			{ x = 44, z = 24, kind = "aframe" },
		}
		for i, slot in ring do
			local kind = slot.kind
			local size = if kind == "dome" and i % 3 == 0 then Vector3.new(10, 7, 9) else nil
			tent(kind, slot.x, slot.z, TENT_COLORS[(i - 1) % #TENT_COLORS + 1], size)
		end

		-- Supply area, flags, lamps ----------------------------------------------------------
		crates(-24, 10, 3)
		crates(-25, -1, 2)
		crates(-31, 5, 4)
		crates(-2, -22, 3)
		crates(22, 12, 2)
		flag(-7, -15, P.red)
		flag(0, -16.5, P.blue)
		flag(7, -15, P.yellow)
		flag(-9, 34, P.purple)
		flag(9, 34, P.orange)
		for _, l in { { -12, 8 }, { 12, 8 }, { -12, -10 }, { 12, -10 }, { -8, 22 }, { 8, 22 }, { 24, -2 } } do
			lamp(l[1], l[2])
		end
		put(AssetFactory.signPost(frame(0, 37, 180), def.name))
	else
		-- Group tent (walk-in, two sleep spots), uphill of the fire, door toward it --------
		local colour = TENT_COLORS[(def.index - 1) % #TENT_COLORS + 1]
		local gt, gtf = tent("big", 0, 17, colour, Vector3.new(16, 10, 12), 0)
		gt.Name = "GroupTent"
		for _, x in { -2.2, 2.2 } do
			sleepSpot(gt, gtf * CFrame.new(x, 0.3, 2.1))
		end
		hangingLamp(gt, gtf * CFrame.new(0.75, 6.8, 0))

		local slots = {
			{ x = -16, z = 4, kind = "dome" },
			{ x = 16, z = 4, kind = "aframe" },
			{ x = -17, z = 18, kind = "dome" },
		}
		local small = math.clamp(math.floor(def.tents or (1 + def.index % 3)), 1, #slots)
		for i = 1, small do
			local slot = slots[i]
			tent(slot.kind, slot.x, slot.z, TENT_COLORS[(def.index + i) % #TENT_COLORS + 1])
		end
		crates(17, -12, if def.index % 2 == 0 then 3 else 2)
		flag(-7.5, -19, TENT_COLORS[def.index % #TENT_COLORS + 1])
		lamp(6, -9)
		lamp(-6, 9)
		put(AssetFactory.signPost(frame(-8.5, -10, facing(-8.5, -10, 0, -30)), def.name))
	end

	local radius = def.radius or (if isBase then BASE_RADIUS else SMALL_RADIUS)
	model:SetAttribute("CampId", def.id)
	model:SetAttribute("CampName", def.name)
	model:SetAttribute("Index", def.index)
	model:SetAttribute("Radius", radius)
	CollectionService:AddTag(model, "Camp")
	print(string.format("[CampKit] %s: %d parts", def.name, countParts(model)))
	return model
end

return CampKit
