--!strict
-- Hand-authored layout of the generated mountain (v2: all-snow polar mountain), as data.
-- WorldBuilder turns this into terrain and props when the place has no hand-built
-- Workspace.Mountain. Shared/Logic/TerrainModel evaluates the same data analytically (surface
-- height, slope, top material), so everything is placed from the model, never by raycasts.
--
-- Axes: +Z is uphill, +Y is up, X is lateral. Units are studs. Elevation shown to players is
-- 300 m + 4 m/stud (GameConfig), so y = 0 reads 300 m and the summit (y = 800) reads 3500 m.
--
-- The route (about 8,000 studs, 15-25 minutes for a fit player):
--   Base Camp (flat basin, y 0)
--   -> snow valley (gentle, 0 -> 40) between glacier-flanked mountains (avalanche slope)
--   -> the Headwall: four snow benches stacked 40 studs apart, joined by ramps in the corners
--   -> Camp 1 (y 200)
--   -> crevasse field: four crevasses crossed by rope bridges (escape ramps inside)
--   -> 48-stud ice wall: ladder, or the long walk-round ramp to the west
--   -> glacier terraces: four more benches, serac fall from the ice cliff above the third
--   -> Camp 2 (y 450)
--   -> exposed knife-edge ridge: rope fences, a notch with a rope bridge, an ice step with a
--      ladder, fixed rope on the final slope
--   -> Summit (y 800): small flat top, flag and cairn, SectionEnd
--
-- Terrain primitives (TerrainModel.ops builds them in this order):
--   Ground    one-voxel Snow tiles under the play area (a Part skirt continues outwards)
--   Mountains Glacier domes (x, z, r, top) near the trail whose gentle tops are re-painted Snow
--   Crests    45-degree rolled prisms under the ridge walkway, on keels down to the ground
--   Slabs     route pieces: Glacier body + Snow top along from -> to (vertical Glacier sides)
--   Pads      round flat landings (Glacier body + Snow top)
--   Shelves   flat axis-aligned benches / camp shelves (min.Y = bottom, max.Y = top)
--   Crevasses Air cuts across the surface (depth below the local top) + escape ramps
--   Outcrops  small Rock balls near the summit
-- Not terrain: Scenery (Part-built backdrop peaks) and the Skirt (flat Snow Parts).

local V = Vector3.new

local function along(a: Vector3, b: Vector3, t: number): Vector3
	return V(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end

-- Key points (shared by terrain, route and props) ----------------------------------------------
local R0 = V(0, 450, 3100) -- ridge start, north edge of the Camp 2 shelf
local R1 = V(-160, 520, 3380)
local R2 = V(60, 590, 3640) -- foot of the ridge ice step
local STEP = V(60, 618, 3700) -- top of the ice step (north edge of its shelf)
local R3 = V(-60, 690, 3920)
local R4 = V(20, 755, 4060)
local SUMMIT = V(0, 800, 4160)
local SUMMIT_RADIUS = 18
-- Where the last pitch meets the flat summit pad's rim.
local SUMMIT_EDGE = (function()
	local dx, dz = SUMMIT.X - R4.X, SUMMIT.Z - R4.Z
	local t = 1 - SUMMIT_RADIUS / math.sqrt(dx * dx + dz * dz)
	return V(R4.X + dx * t, SUMMIT.Y, R4.Z + dz * t)
end)()
-- Flat bend landings on the ridge: the walkway runs rim to rim, `BEND` studs either side.
local BEND = 9
local function rim(center: Vector3, toward: Vector3, sign: number): Vector3
	local dx, dz = toward.X - center.X, toward.Z - center.Z
	local m = math.sqrt(dx * dx + dz * dz)
	return V(center.X + dx / m * BEND * sign, center.Y, center.Z + dz / m * BEND * sign)
end
local R1_IN, R1_OUT = rim(R1, R0, 1), rim(R1, R2, 1)
local R3_IN, R3_OUT = rim(R3, STEP, 1), rim(R3, R4, 1)
local R4_IN, R4_OUT = rim(R4, R3, 1), rim(R4, SUMMIT, 1)
local NOTCH = along(R1_OUT, R2, 0.5)
local NOTCH_HALF = 13 / (R2 - R1_OUT).Magnitude -- bridge anchors 13 studs either side
local RIDGE_DIR = V(R2.X - R1_OUT.X, 0, R2.Z - R1_OUT.Z)

-- Crevasse field: plateau top is y = 200 + 0.06 * (z - 1700).
local function plateauY(z: number): number
	return 200 + 0.06 * (z - 1700)
end

local WorldLayout = {
	Version = 2,
	Seed = 7331,

	-- Terrain ground (top y 0, one voxel thick) under the whole play area. Beyond it a flat
	-- ring of Snow Parts (the skirt) and Part-built backdrop peaks finish the view, so no
	-- sightline ever ends in the void while the terrain stays small.
	Ground = { x0 = -800, z0 = -700, x1 = 800, z1 = 4500, top = 0, thickness = 4, tile = 800 },
	Skirt = { x0 = -3200, z0 = -2800, x1 = 3200, z1 = 7200, top = -0.5 },

	-- Every point inside these bounds must have terrain (checked by tests).
	Bounds = { x0 = -800, z0 = -700, x1 = 800, z1 = 4500 },

	-- Filled first (then camps are built, then the rest of the mountain).
	FirstBuild = { x0 = -700, z0 = -700, x1 = 700, z1 = 700 },

	-- Terrain domes close to the trail: the Base Camp basin and the valley. Further up, the
	-- corridor is walled by Glacier canyon walls and the backdrop peaks stand beyond them.
	Mountains = {
		{ x = 0, z = -300, r = 170, top = 300 },
		{ x = -270, z = -240, r = 160, top = 280 },
		{ x = 270, z = -250, r = 160, top = 290 },
		{ x = -320, z = -20, r = 160, top = 270 },
		{ x = 320, z = 20, r = 160, top = 280 },
		{ x = -330, z = 250, r = 160, top = 280 },
		{ x = -330, z = 480, r = 170, top = 300 }, -- the avalanche slope
		{ x = 360, z = 300, r = 160, top = 270 },
		{ x = 360, z = 560, r = 160, top = 290 },
		{ x = 300, z = 760, r = 150, top = 260 },
		{ x = -430, z = 760, r = 160, top = 300 },
		-- Outside the canyon walls, so the view from the ridge is mountains, not a plain
		{ x = -600, z = 1300, r = 200, top = 380 },
		{ x = 600, z = 1350, r = 200, top = 390 },
		{ x = -620, z = 2000, r = 200, top = 400 },
		{ x = 620, z = 2050, r = 200, top = 390 },
		{ x = -620, z = 2700, r = 200, top = 400 },
		{ x = 620, z = 2750, r = 200, top = 400 },
		{ x = -580, z = 3450, r = 200, top = 390 },
		{ x = 560, z = 3500, r = 200, top = 400 },
	},

	-- Backdrop peaks built from Parts (not terrain): apex at (x, top, z), one flat face turned
	-- by `yaw` degrees (0 = facing +Z) towards the trail. All stand 600+ studs from the route.
	Scenery = {
		-- West (each stands 650 + 0.71 * top studs out, so its footprint stays 300+ off the trail)
		{ x = -1080, z = -350, top = 600, yaw = 90 },
		{ x = -1110, z = 300, top = 650, yaw = 90 },
		{ x = -1150, z = 900, top = 700, yaw = 90 },
		{ x = -1190, z = 1500, top = 760, yaw = 90 },
		{ x = -1220, z = 2100, top = 800, yaw = 90 },
		{ x = -1260, z = 2700, top = 860, yaw = 90 },
		{ x = -1290, z = 3300, top = 900, yaw = 90 },
		{ x = -1320, z = 3900, top = 940, yaw = 90 },
		{ x = -1050, z = 4750, top = 950, yaw = 135 },
		-- East
		{ x = 1090, z = -300, top = 620, yaw = -90 },
		{ x = 1080, z = 350, top = 600, yaw = -90 },
		{ x = 1150, z = 950, top = 700, yaw = -90 },
		{ x = 1190, z = 1550, top = 760, yaw = -90 },
		{ x = 1235, z = 2150, top = 820, yaw = -90 },
		{ x = 1260, z = 2750, top = 860, yaw = -90 },
		{ x = 1275, z = 3350, top = 880, yaw = -90 },
		{ x = 1300, z = 3950, top = 920, yaw = -90 },
		{ x = 1000, z = 4800, top = 980, yaw = -135 },
		-- South, behind Base Camp
		{ x = -450, z = -1100, top = 600, yaw = 0 },
		{ x = 400, z = -1150, top = 650, yaw = 0 },
		{ x = 0, z = -1450, top = 800, yaw = 0 },
		-- North, beyond the summit
		{ x = 0, z = 5250, top = 1000, yaw = 180 },
		{ x = -600, z = 5400, top = 900, yaw = 180 },
		{ x = 600, z = 5450, top = 900, yaw = 180 },
	},

	-- Knife-edge crests under the ridge walkway (top edge `drop` studs under the route line),
	-- each carried to the ground by a keel as wide as its 45-degree roof.
	Crests = {
		{ name = "CrestA", from = R0, to = R1_IN, size = 100, drop = 4 },
		{ name = "CrestB", from = R1_OUT, to = R2, size = 100, drop = 4 },
		{ name = "CrestC", from = STEP, to = R3_IN, size = 100, drop = 4 },
		{ name = "CrestD", from = R3_OUT, to = R4_IN, size = 100, drop = 4 },
		{ name = "CrestE", from = R4_OUT, to = SUMMIT_EDGE, size = 100, drop = 4 },
	},

	-- `bottom` = how far down the Glacier body goes. Terraces are hollow underneath: each
	-- body only reaches into the one below, and the canyon walls close the sides.
	Slabs = {
		-- Snow valley
		{ name = "Valley1", from = V(0, 0, 90), to = V(40, 12, 420), width = 200, bottom = -4 },
		{ name = "Valley2", from = V(40, 12, 420), to = V(-40, 26, 720), width = 200, bottom = -4 },
		{ name = "Valley3", from = V(-40, 26, 720), to = V(-250, 40, 920), width = 160, bottom = -4 },
		-- Headwall corner ramps (each climbs inside the lower bench's row)
		{ name = "HeadRamp1", from = V(250, 40, 980), to = V(250, 80, 1080), width = 50, bottom = 32 },
		{ name = "HeadRamp2", from = V(-250, 80, 1140), to = V(-250, 120, 1240), width = 50, bottom = 72 },
		{ name = "HeadRamp3", from = V(250, 120, 1300), to = V(250, 160, 1400), width = 50, bottom = 112 },
		{ name = "HeadRamp4", from = V(-250, 160, 1460), to = V(-250, 200, 1560), width = 50, bottom = 152 },
		-- Crevasse field (rises 36 over 600)
		{ name = "Plateau", from = V(0, 200, 1700), to = V(0, 236, 2300), width = 560, bottom = 150 },
		-- Ice wall walk-round: a long ramp along the foot of the wall
		{
			name = "WallBypass",
			from = V(120, plateauY(2288), 2288),
			to = V(-200, 284, 2288),
			width = 24,
			bottom = 228,
		},
		-- Glacier terrace corner ramps
		{ name = "TerraceRamp1", from = V(310, 284, 2360), to = V(310, 330, 2460), width = 50, bottom = 276 },
		{ name = "TerraceRamp2", from = V(-310, 330, 2520), to = V(-310, 380, 2640), width = 50, bottom = 322 },
		{ name = "TerraceRamp3", from = V(310, 380, 2700), to = V(310, 420, 2800), width = 50, bottom = 372 },
		{ name = "TerraceRamp4", from = V(-310, 420, 2860), to = V(-310, 450, 2960), width = 50, bottom = 412 },
		-- Ridge walkway (narrow, sits on the crests)
		{ name = "Ridge1", from = R0, to = R1_IN, width = 18, thickness = 24, extendTo = 0 },
		{ name = "Ridge2", from = R1_OUT, to = R2, width = 18, thickness = 24, extendTo = 4 },
		{ name = "Ridge3", from = STEP, to = R3_IN, width = 18, thickness = 24, extendTo = 0 },
		{ name = "Ridge4", from = R3_OUT, to = R4_IN, width = 18, thickness = 24, extendTo = 0 },
		{ name = "Ridge5", from = R4_OUT, to = SUMMIT_EDGE, width = 18, thickness = 24, extendTo = 0 },
	},

	Pads = {
		-- Bend fillers: they plug the outer corner where two slabs meet at an angle.
		{ name = "ValleyBend1", at = V(40, 12, 420), radius = 60, sink = 3, bottom = -4 },
		{ name = "ValleyBend2", at = V(-40, 26, 720), radius = 60, sink = 3, bottom = -4 },
		{ name = "RidgeBend1", at = R1, radius = BEND, bottom = R1.Y - 80 },
		{ name = "RidgeBend3", at = R3, radius = BEND, bottom = R3.Y - 80 },
		{ name = "RidgeBend4", at = R4, radius = BEND, bottom = R4.Y - 80 },
		{ name = "SummitTop", at = SUMMIT, radius = SUMMIT_RADIUS, bottom = 700 },
		-- The summit block: an ice tower under the summit pad, 20 studs lower.
		{ name = "SummitBlock", at = V(0, 780, 4160), radius = 50, bottom = 0 },
	},

	Shelves = {
		{ name = "BaseCampFloor", min = V(-110, -20, -90), max = V(110, 0, 90) },
		-- Headwall benches (flat, 40-stud Glacier risers between them)
		{ name = "Bench1", min = V(-280, 0, 920), max = V(280, 40, 1080) },
		{ name = "Bench2", min = V(-280, 28, 1080), max = V(280, 80, 1240) },
		{ name = "Bench3", min = V(-280, 68, 1240), max = V(280, 120, 1400) },
		{ name = "Bench4", min = V(-280, 108, 1400), max = V(280, 160, 1560) },
		{ name = "Camp1Shelf", min = V(-280, 148, 1560), max = V(280, 200, 1700) },
		-- Top of the ice wall (its south face at z 2300 is the wall)
		{ name = "IceWallTop", min = V(-340, 200, 2300), max = V(340, 284, 2460) },
		-- Glacier terraces
		{ name = "Terrace2", min = V(-340, 272, 2460), max = V(340, 330, 2640) },
		{ name = "Terrace3", min = V(-340, 318, 2640), max = V(340, 380, 2800) },
		{ name = "Terrace4", min = V(-340, 368, 2800), max = V(340, 420, 2960) },
		{ name = "Camp2Shelf", min = V(-340, 408, 2960), max = V(340, 450, 3100) },
		{ name = "Camp2NorthWall", min = V(-340, 0, 3060), max = V(340, 450, 3100) },
		-- Ridge ice step on its base ledge
		{ name = "RidgeStepBase", min = V(-20, 0, 3580), max = V(140, 510, 3745) },
		{ name = "RidgeStep", min = V(34, 500, 3644), max = V(86, 618, 3700) },
		-- Canyon walls: Glacier cliffs along both sides of the corridor, down to the ground.
		{ name = "HeadwallWallW", min = V(-320, 0, 920), max = V(-280, 230, 1700) },
		{ name = "HeadwallWallE", min = V(280, 0, 920), max = V(320, 230, 1700) },
		{ name = "PlateauWallW", min = V(-340, 0, 1700), max = V(-280, 280, 2300) },
		{ name = "PlateauWallE", min = V(280, 0, 1700), max = V(340, 270, 2300) },
		{ name = "TerraceWallW", min = V(-380, 0, 2300), max = V(-340, 490, 3100) },
		{ name = "TerraceWallE", min = V(340, 0, 2300), max = V(380, 480, 3100) },
	},

	Crevasses = {
		{
			name = "Crevasse1",
			at = V(0, 0, 1800),
			dir = V(1, 0, 0),
			length = 576,
			width = 26,
			depth = 30,
			ramp = { side = -1, width = 8, low = -150, high = -210 },
		},
		{
			name = "Crevasse2",
			at = V(0, 0, 1920),
			dir = V(1, 0, 0),
			length = 576,
			width = 30,
			depth = 32,
			ramp = { side = -1, width = 8, low = 150, high = 214 },
		},
		{
			name = "Crevasse3",
			at = V(0, 0, 2040),
			dir = V(1, 0, 0),
			length = 576,
			width = 24,
			depth = 30,
			ramp = { side = -1, width = 8, low = -150, high = -210 },
		},
		{
			name = "Crevasse4",
			at = V(0, 0, 2160),
			dir = V(1, 0, 0),
			length = 576,
			width = 28,
			depth = 32,
			ramp = { side = -1, width = 8, low = 150, high = 214 },
		},
		-- Notch in the ridge, crossed by a rope bridge.
		{
			name = "RidgeNotch",
			at = NOTCH,
			dir = V(RIDGE_DIR.Z, 0, -RIDGE_DIR.X),
			length = 80,
			width = 18,
			depth = 40,
		},
	},

	-- Small balls: Rock outcrops near the summit, and Glacier shoulders rounding the ridge bends.
	Outcrops = {
		{ x = R1.X, z = R1.Z, r = 45, top = R1.Y - 4, material = "Glacier" },
		{ x = R3.X, z = R3.Z, r = 45, top = R3.Y - 4, material = "Glacier" },
		{ x = R4.X, z = R4.Z, r = 45, top = R4.Y - 4, material = "Glacier" },
		{ x = 34, z = 4118, r = 12, top = 766 },
		{ x = -30, z = 4176, r = 10, top = 786 },
		{ x = 22, z = 4196, r = 9, top = 792 },
		{ x = -36, z = 4060, r = 14, top = 705 },
	},

	-- Camps. Passed as-is to CampKit.build(def, groundAt):
	--   id, name, index (1 = Base Camp), center (on the ground), size ("Base" | "Small"),
	--   supplyTable (LoadoutConfig.SupplyAllowance key), spawn (on the ground),
	--   yaw (degrees about +Y; 0 = the camp's front faces +Z, where the trail continues),
	--   footprint (X = width, Z = depth of the guaranteed-flat kit area), radius (CampService)
	Camps = {
		{
			id = "BaseCamp",
			name = "Base Camp",
			index = 1,
			center = V(0, 0, 0),
			size = "Base",
			supplyTable = "BaseCamp",
			spawn = V(0, 0, -45),
			yaw = 0,
			footprint = V(180, 0, 140),
			radius = 110,
		},
		{
			id = "Camp1",
			name = "Camp 1",
			index = 2,
			center = V(-150, 200, 1630),
			size = "Small",
			supplyTable = "Camp1",
			spawn = V(-150, 200, 1608),
			yaw = 0,
			footprint = V(70, 0, 60),
			radius = 50,
		},
		{
			id = "Camp2",
			name = "Camp 2",
			index = 3,
			center = V(-200, 450, 3030),
			size = "Small",
			supplyTable = "Camp2",
			spawn = V(-200, 450, 3008),
			yaw = 0,
			footprint = V(70, 0, 60),
			radius = 50,
		},
	},

	-- The main route, point by point. `via` names how the segment ARRIVING at a point is
	-- crossed: nil = walked, "Bridge" = rope bridge, "Ladder" = ladder (previous point = foot).
	Route = {
		{ id = "BaseCamp", at = V(0, 0, 0) },
		{ at = V(0, 0, 90) },
		{ at = V(40, 12, 420) },
		{ at = V(-40, 26, 720) },
		{ id = "HeadwallFoot", at = V(-250, 40, 920) },
		{ at = V(-250, 40, 950) },
		{ at = V(250, 40, 950) },
		{ at = V(250, 40, 980) },
		{ at = V(250, 80, 1080) },
		{ at = V(250, 80, 1110) },
		{ at = V(-250, 80, 1110) },
		{ at = V(-250, 80, 1140) },
		{ at = V(-250, 120, 1240) },
		{ at = V(-250, 120, 1270) },
		{ at = V(250, 120, 1270) },
		{ at = V(250, 120, 1300) },
		{ at = V(250, 160, 1400) },
		{ at = V(250, 160, 1430) },
		{ at = V(-250, 160, 1430) },
		{ at = V(-250, 160, 1460) },
		{ at = V(-250, 200, 1560) },
		{ id = "Camp1", at = V(-150, 200, 1630) },
		{ at = V(-110, 200, 1700) },
		{ id = "K1S", at = V(-80, plateauY(1783), 1783) },
		{ id = "K1N", at = V(-80, plateauY(1817), 1817), via = "Bridge" },
		{ id = "K2S", at = V(40, plateauY(1901), 1901) },
		{ id = "K2N", at = V(40, plateauY(1939), 1939), via = "Bridge" },
		{ id = "K3S", at = V(-40, plateauY(2024), 2024) },
		{ id = "K3N", at = V(-40, plateauY(2056), 2056), via = "Bridge" },
		{ id = "K4S", at = V(60, plateauY(2142), 2142) },
		{ id = "K4N", at = V(60, plateauY(2178), 2178), via = "Bridge" },
		{ id = "WallFoot", at = V(200, plateauY(2297), 2297) },
		{ id = "WallTop", at = V(200, 284, 2306), via = "Ladder" },
		{ id = "ShelfEast", at = V(310, 284, 2330) },
		{ at = V(310, 284, 2360) },
		{ at = V(310, 330, 2460) },
		{ at = V(310, 330, 2490) },
		{ at = V(-310, 330, 2490) },
		{ at = V(-310, 330, 2520) },
		{ at = V(-310, 380, 2640) },
		{ at = V(-310, 380, 2670) },
		{ at = V(310, 380, 2670) },
		{ at = V(310, 380, 2700) },
		{ at = V(310, 420, 2800) },
		{ at = V(310, 420, 2830) },
		{ at = V(-310, 420, 2830) },
		{ at = V(-310, 420, 2860) },
		{ at = V(-310, 450, 2960) },
		{ id = "Camp2", at = V(-200, 450, 3030) },
		{ at = V(0, 450, 3070) },
		{ id = "RidgeStart", at = R0 },
		{ at = R1_IN },
		{ id = "R1", at = R1 },
		{ at = R1_OUT },
		{ id = "NotchS", at = along(R1_OUT, R2, 0.5 - NOTCH_HALF) },
		{ id = "NotchN", at = along(R1_OUT, R2, 0.5 + NOTCH_HALF), via = "Bridge" },
		{ id = "R2", at = R2 },
		{ id = "StepTop", at = V(60, 618, 3650), via = "Ladder" },
		{ at = STEP },
		{ at = R3_IN },
		{ id = "R3", at = R3 },
		{ at = R3_OUT },
		{ at = R4_IN },
		{ id = "R4", at = R4 },
		{ at = R4_OUT },
		{ id = "SummitEdge", at = SUMMIT_EDGE },
		{ id = "Summit", at = SUMMIT },
	},

	-- Optional routes (also marked). They start and end on main-route points.
	Alternates = {
		{
			name = "IceWallBypass",
			points = {
				{ at = V(60, plateauY(2178), 2178) },
				{ at = V(140, plateauY(2288), 2288) },
				{ at = V(120, plateauY(2288), 2288) },
				{ at = V(-200, 284, 2288) },
				{ at = V(-200, 284, 2330) },
				{ at = V(310, 284, 2330) },
			},
		},
	},

	BridgeWidth = 5,
	MarkerSpacing = 40,
	MarkerOffset = 6,

	-- Rope fences along the exposed ridge (route ids, inclusive) at `offset` from the centre.
	Fences = {
		{ from = "RidgeStart", to = "R1", offset = 7.5, sides = { 1, -1 } },
		{ from = "R1", to = "NotchS", offset = 7.5, sides = { 1, -1 } },
		{ from = "NotchN", to = "R2", offset = 7.5, sides = { 1, -1 } },
		{ from = "R3", to = "R4", offset = 7.5, sides = { 1 } },
	},
	-- Fixed ropes on the steepest pitches (decorative handlines).
	FixedRopes = {
		{ from = "R4", to = "Summit", offset = 4, side = -1 },
		{ from = "R3", to = "R4", offset = 4, side = -1 },
	},

	-- Warning signs: position (y from terrain) and a point the sign faces.
	Signs = {
		{ at = V(70, 0, 380), toward = V(0, 0, 90), text = "AVALANCHE RISK" },
		{ at = V(-150, 0, 1712), toward = V(-150, 0, 1630), text = "CREVASSES" },
		{ at = V(170, 0, 2280), toward = V(60, 0, 2178), text = "ICE WALL" },
		{ at = V(110, 0, 2262), toward = V(60, 0, 2178), text = "LONG WAY ROUND" },
		{ at = V(240, 0, 2690), toward = V(-310, 0, 2670), text = "SERAC FALL" },
		{ at = V(-14, 0, 3090), toward = V(-200, 0, 3030), text = "HIGH WINDS" },
	},

	-- Deadwood (WoodSource): position (y from terrain), wood per log, respawn seconds (nil =
	-- never). Wood is scarce: ten logs near Base Camp, three near Camp 1, one finite woodpile
	-- at Camp 2. Nothing grows higher up.
	WoodSources = {
		{ pos = V(-95, 0, 110), wood = 3, respawn = 240 },
		{ pos = V(124, 0, -30), wood = 3, respawn = 240 },
		{ pos = V(-70, 0, 150), wood = 4, respawn = 240 },
		{ pos = V(100, 0, 190), wood = 3, respawn = 240 },
		{ pos = V(-40, 0, 250), wood = 3, respawn = 240 },
		{ pos = V(115, 0, 330), wood = 4, respawn = 240 },
		{ pos = V(-60, 0, 380), wood = 3, respawn = 240 },
		{ pos = V(120, 0, 450), wood = 3, respawn = 240 },
		{ pos = V(-90, 0, 560), wood = 3, respawn = 240 },
		{ pos = V(70, 0, 620), wood = 3, respawn = 240 },
		{ pos = V(-250, 0, 1650), wood = 3, respawn = 420 },
		{ pos = V(-40, 0, 1620), wood = 2, respawn = 420 },
		{ pos = V(110, 0, 1660), wood = 3, respawn = 420 },
		{ pos = V(-290, 0, 3060), wood = 8, respawn = nil, woodpile = true },
	},
	-- Melt water comes from snow at fires now; camps may add their own barrels.
	WaterSources = {} :: { Vector3 },

	-- Sparse snowy pine clusters, near Base Camp only: centre, radius, count.
	TreeClusters = {
		{ x = -130, z = 130, r = 22, count = 5 },
		{ x = 125, z = 110, r = 18, count = 4 },
		{ x = -80, z = 200, r = 24, count = 5 },
		{ x = 120, z = 270, r = 20, count = 4 },
		{ x = -100, z = 470, r = 18, count = 3 },
		{ x = 110, z = 560, r = 16, count = 3 },
	},
	-- Snow-covered rocks scattered beside the route (count, min/max distance off the trail).
	RockScatter = { count = 150, near = 14, far = 80, minSize = 2, maxSize = 7 },

	-- Rockfall / serac fall hazards (DisasterService contract: invisible box covering where
	-- players stand, Release attachments, PushDirection). Release y = terrain + 4.
	RockfallZones = {
		{
			name = "ValleyAvalanche",
			zoneCenter = V(-10, 40, 470),
			zoneSize = V(220, 90, 240),
			releasePoints = { V(-215, 0, 420), V(-210, 0, 480), V(-215, 0, 540) },
			pushDirection = V(1, 0, 0),
		},
		{
			name = "SeracFall",
			zoneCenter = V(0, 400, 2700),
			zoneSize = V(560, 60, 120),
			releasePoints = { V(-140, 0, 2812), V(0, 0, 2812), V(140, 0, 2812) },
			pushDirection = V(0, 0, -1),
		},
	},

	SectionEnd = { pos = SUMMIT, radius = 16 },

	-- Below this height a player is "lost" and is recovered to their checkpoint. The ground
	-- top is y 0, so only falling off the world triggers it.
	SafetyNetY = -30,
	-- Invisible catch floor far below the terrain so a fall never goes on forever.
	SafetyFloorY = -120,
}

return WorldLayout
