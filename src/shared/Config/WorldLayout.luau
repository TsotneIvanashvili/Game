--!strict
-- Hand-authored layout of the generated mountain (v3: a natural heightfield polar mountain),
-- as data. WorldBuilder turns this into terrain and props when the place has no hand-built
-- Workspace.Mountain. Shared/Logic/TerrainModel turns the same data into the heightfield
-- (surface height, slope, material), so everything is placed from the model, never by raycasts.
--
-- Axes: +Z is uphill, +Y is up, X is lateral. Units are studs. Elevation shown to players is
-- 300 m + 4 m/stud (GameConfig), so y = 0 reads 300 m and the summit (y = 800) reads 3500 m.
--
-- The route (about 8,000 studs, 15-25 minutes for a fit player):
--   Base Camp (flat basin among snowy peaks, y 0)
--   -> a long snow valley, gently climbing past an avalanche slope (west side)
--   -> the Headwall: switchbacks traversing a broad snow slope in a cirque
--   -> Camp 1 (y 200) on the lip
--   -> the crevasse plateau: four crevasses crossed by rope bridges (escape ramps inside)
--   -> a 48-stud ice wall across the valley: ladder, or the long ramp along its foot (west)
--   -> glacier switchbacks under a serac band (serac fall)
--   -> Camp 2 (y 450) at the foot of the ridge
--   -> the exposed knife-edge ridge: rope fences, a notch with a rope bridge, an ice step
--      with a ladder, fixed ropes on the final pitches
--   -> Summit (y 800): small flat top among dark rock outcrops, flag and cairn, SectionEnd
--
-- How the terrain is made (see TerrainModel): the main Route's points carry the trail
-- elevation; Relief (by route id, applying from that point on) says how the land around that
-- section looks: `up` = valley walls rising that high, `down` = ridge flanks falling that far,
-- `floor` = half-width of the flat-ish valley floor, `rough` = mountain noise strength,
-- `trail`/`blend` = corridor half-width and blend. Areas are flat or planar patches (camps,
-- the plateau, shelves); `locked` areas are hard cliffs no corridor may soften. Crevasses are
-- cut last. Not terrain: Scenery (Part-built backdrop peaks) and the Skirt (flat Snow Parts).

local V = Vector3.new

local function along(a: Vector3, b: Vector3, t: number): Vector3
	return V(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end

-- Key points (shared by terrain, route and props) ----------------------------------------------
local R0 = V(0, 450, 3100) -- ridge start, north of Camp 2
local R1 = V(-160, 520, 3380)
local R2 = V(60, 590, 3645) -- foot of the ridge ice step (its face is at z 3648)
local STEP = V(60, 618, 3700) -- north edge of the ice step's top
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
local NOTCH = along(R1, R2, 0.5)
local NOTCH_HALF = 13 / (R2 - R1).Magnitude -- bridge anchors 13 studs either side
local RIDGE_DIR = V(R2.X - R1.X, 0, R2.Z - R1.Z)

-- Crevasse plateau: its surface is y = 200 + 0.06 * (z - 1700).
local function plateauY(z: number): number
	return 200 + 0.06 * (z - 1700)
end

-- Serac band: an ice cliff above the T4 -> T5 switchback leg, parallel to it.
local T4, T5 = V(276, 390, 2666), V(-230, 438, 2800)
local SERAC = (function()
	local dx, dz = T5.X - T4.X, T5.Z - T4.Z
	local m = math.sqrt(dx * dx + dz * dz)
	local ux, uz = dx / m, dz / m
	local nx, nz = -uz, ux -- perpendicular, pointing uphill (+z side)
	if nz < 0 then
		nx, nz = -nx, -nz
	end
	local mid = along(T4, T5, 0.5)
	return {
		center = V(mid.X + nx * 62, 470, mid.Z + nz * 62),
		yaw = math.deg(math.atan2(nx, nz)), -- local +z = uphill
		ux = ux,
		uz = uz,
		nx = nx,
		nz = nz,
		mid = mid,
	}
end)()

-- Backdrop peaks in a ring outside the terrain, each turned (roughly) to face the mountain,
-- standing far enough out that no footprint reaches over the terrain's edge.
local BOUNDS = { x0 = -1024, z0 = -896, x1 = 1024, z1 = 4864 }
local function backdrop(): { any }
	-- Deterministic but irregular: heights, spacing, facing and distance all vary, and a second,
	-- taller row stands further out, so the horizon reads as a range, not a sawtooth.
	local state = 4242
	local function rand(lo: number, hi: number): number -- Park-Miller: exact in doubles
		state = (state * 16807) % 2147483647
		return lo + (hi - lo) * state / 2147483647
	end
	local peaks = {}
	local function add(x: number, z: number, top: number, yaw: number)
		table.insert(peaks, { x = x, z = z, top = top, yaw = yaw })
	end
	-- One side: `along` runs over [a0, a1]; place(t, out, top, yaw) positions a peak.
	local function side(a0: number, a1: number, place: (number, number, number, number) -> (), yaw: number)
		for row = 0, 1 do
			local t = a0 - 300 + rand(0, 300) + row * 260
			while t < a1 + 300 do
				local top = if row == 0 then rand(620, 980) else rand(900, 1150)
				-- Turned up to 12 degrees off square, a footprint corner reaches 0.95 * top
				-- towards the mountain (0.707 * top when square on).
				local out = top * 0.96 + 160 + row * rand(500, 800)
				place(t, out, top, yaw + rand(-12, 12))
				t += rand(380, 640) * (1 + row * 0.4)
			end
		end
	end
	side(BOUNDS.z0, BOUNDS.z1, function(t, out, top, yaw)
		add(BOUNDS.x0 - out, t, top, yaw)
	end, 90)
	side(BOUNDS.z0, BOUNDS.z1, function(t, out, top, yaw)
		add(BOUNDS.x1 + out, t, top, yaw)
	end, -90)
	side(BOUNDS.x0, BOUNDS.x1, function(t, out, top, yaw)
		add(t, BOUNDS.z0 - out, top, yaw)
	end, 0)
	side(BOUNDS.x0, BOUNDS.x1, function(t, out, top, yaw)
		add(t, BOUNDS.z1 + out, top, yaw)
	end, 180)
	return peaks
end

local WorldLayout = {
	Version = 3,
	Seed = 7331,

	-- The terrain heightfield covers Bounds (multiples of 4 = voxel aligned). Its rim eases
	-- down to y 0 over `edge` studs, onto a flat ring of Snow Parts (the skirt), with
	-- Part-built backdrop peaks beyond, so no sightline ever ends in the void.
	Bounds = BOUNDS,
	Landscape = { seed = 7331, edge = 260, noise = 220 },
	Skirt = { x0 = -3800, z0 = -3400, x1 = 3800, z1 = 8400, top = -0.5 },

	-- Columns overlapping this are written first (then camps are built, then the rest).
	FirstBuild = { x0 = -640, z0 = -640, x1 = 640, z1 = 640 },

	Relief = {
		BaseCamp = { up = 220, down = 0, floor = 190, rough = 0.6, trail = 12, blend = 36 },
		V1 = { up = 300, down = 0, floor = 90, rough = 1 },
		HeadwallFoot = { up = 320, down = 0, floor = 70, rough = 1, trail = 10, blend = 40 },
		Camp1 = { up = 360, down = 0, floor = 200, rough = 1 },
		ShelfEast = { up = 320, down = 0, floor = 80, rough = 1 },
		Camp2 = { up = 160, down = 0, floor = 70, rough = 0.8 },
		RidgeStart = { up = 0, down = 380, floor = 0, rough = 1, trail = 8, blend = 12 },
	},

	-- Flat / planar patches. pad: circle (x, z, r) at height y. rect: centre (x, z), size
	-- (sx, sz), `yaw` degrees (local +z = (sin yaw, cos yaw)), height y at the centre rising
	-- `grade` per stud along local +z. blend: studs (or per side n/s/e/w = local +z/-z/+x/-x;
	-- 0 = a hard cliff edge). locked = re-applied after the trail corridors. mode "raise" =
	-- only ever lifts the ground to y, never lowers it. jitter = studs of noise on the height
	-- (an irregular top and face).
	Areas = {
		{ name = "BaseCampFloor", kind = "pad", x = 0, z = 0, y = 0, r = 150, blend = 120, locked = true },
		-- The avalanche slope: a broad 31-degree snow face on the valley's west side.
		{
			name = "AvalancheSlope",
			kind = "rect",
			x = -230,
			z = 500,
			sx = 260,
			sz = 160,
			yaw = -90, -- local +z points west: the slope rises away from the trail
			y = 90,
			grade = 0.6,
			blend = 140,
		},
		{ name = "Camp1Floor", kind = "pad", x = -150, z = 1630, y = 200, r = 60, blend = 60, locked = true },
		{
			name = "Plateau",
			kind = "rect",
			x = 0,
			z = 2000,
			sx = 800,
			sz = 600,
			y = plateauY(2000),
			grade = 0.06,
			blend = { s = 40, e = 160, w = 160, n = 40 },
		},
		-- Top of the ice wall: its south face (z 2300) is the 48-stud wall across the valley.
		-- It only raises: where the valley walls are higher anyway it does nothing, so the wall
		-- simply ends where it meets them.
		{
			name = "IceWallTop",
			kind = "rect",
			x = 0,
			z = 2312,
			sx = 1200,
			sz = 24,
			y = 284,
			blend = { n = 48, e = 120, w = 120 },
			mode = "raise",
			locked = true,
		},
		{
			name = "SeracBand",
			kind = "rect",
			x = SERAC.center.X,
			z = SERAC.center.Z,
			sx = 200,
			sz = 40,
			yaw = SERAC.yaw,
			y = 470,
			blend = { n = 50, e = 90, w = 90 },
			jitter = 6,
			mode = "raise",
			locked = true,
		},
		{ name = "Camp2Floor", kind = "pad", x = -200, z = 3030, y = 450, r = 60, blend = 60, locked = true },
		-- The ridge ice step: x 32..88, z 3648..3700, sheer on every side but the top.
		{ name = "RidgeStep", kind = "rect", x = 60, z = 3674, sx = 56, sz = 52, y = 618, locked = true },
		{ name = "SummitTop", kind = "pad", x = SUMMIT.X, z = SUMMIT.Z, y = SUMMIT.Y, r = SUMMIT_RADIUS, blend = 10 },
	},

	Crevasses = {
		{
			name = "Crevasse1",
			at = V(-40, 0, 1800),
			dir = V(1, 0, 0),
			length = 640,
			width = 26,
			depth = 30,
			ramp = { side = -1, width = 8, low = -150, high = -210 },
		},
		{
			name = "Crevasse2",
			at = V(60, 0, 1920),
			dir = V(1, 0, 0),
			length = 600,
			width = 30,
			depth = 32,
			ramp = { side = -1, width = 8, low = 150, high = 214 },
		},
		{
			name = "Crevasse3",
			at = V(-60, 0, 2040),
			dir = V(1, 0, 0),
			length = 620,
			width = 24,
			depth = 30,
			ramp = { side = -1, width = 8, low = -150, high = -210 },
		},
		{
			name = "Crevasse4",
			at = V(40, 0, 2160),
			dir = V(1, 0, 0),
			length = 580,
			width = 26,
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

	-- Dark rock shows on steep faces only here (art direction: rare outcrops near the summit).
	RockZones = { { x = 0, z = 4140, r = 300 } },

	-- Backdrop peaks built from Parts (not terrain): apex at (x, top, z), one flat face turned
	-- by `yaw` degrees (0 = facing +Z) towards the mountain. All stand outside Bounds.
	Scenery = backdrop(),

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
			spawn = V(0, 0, -56), -- clear of the sleeping tent (x 3..29, z -48..-28)
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
		{ at = V(0, 0, 110) },
		{ id = "V1", at = V(70, 8, 380) },
		{ id = "V2", at = V(-50, 18, 620) },
		{ id = "V3", at = V(40, 28, 800) },
		{ id = "V4", at = V(-60, 36, 1000) },
		-- Headwall switchbacks across a 22-degree snow face
		{ id = "HeadwallFoot", at = V(-220, 44, 1100) },
		{ id = "H1", at = V(230, 80, 1160) },
		{ id = "H2", at = V(262, 86, 1205) },
		{ id = "H3", at = V(-240, 124, 1265) },
		{ id = "H4", at = V(-268, 130, 1310) },
		{ id = "H5", at = V(240, 166, 1370) },
		{ id = "H6", at = V(262, 172, 1415) },
		{ id = "H7", at = V(-40, 196, 1500) },
		{ id = "Camp1", at = V(-150, 200, 1630) },
		{ at = V(-110, 200, 1700) },
		-- Crevasse plateau
		{ id = "K1S", at = V(-80, plateauY(1783), 1783) },
		{ id = "K1N", at = V(-80, plateauY(1817), 1817), via = "Bridge" },
		{ id = "K2S", at = V(40, plateauY(1901), 1901) },
		{ id = "K2N", at = V(40, plateauY(1939), 1939), via = "Bridge" },
		{ id = "K3S", at = V(-40, plateauY(2024), 2024) },
		{ id = "K3N", at = V(-40, plateauY(2056), 2056), via = "Bridge" },
		{ id = "K4S", at = V(60, plateauY(2142), 2142) },
		{ id = "K4N", at = V(60, plateauY(2178), 2178), via = "Bridge" },
		{ id = "WallFoot", at = V(200, plateauY(2296), 2296) },
		{ id = "WallTop", at = V(200, 284, 2310), via = "Ladder" },
		-- Glacier switchbacks
		{ id = "ShelfEast", at = V(310, 284, 2336) },
		{ id = "T1", at = V(-250, 330, 2440) },
		{ id = "T2", at = V(-276, 336, 2496) },
		{ id = "T3", at = V(250, 384, 2610) },
		{ id = "T4", at = T4 },
		{ id = "T5", at = T5 },
		{ id = "T6", at = V(-262, 446, 2860) },
		{ id = "Camp2", at = V(-200, 450, 3030) },
		{ at = V(0, 450, 3070) },
		-- The ridge
		{ id = "RidgeStart", at = R0 },
		{ id = "R1", at = R1 },
		{ id = "NotchS", at = along(R1, R2, 0.5 - NOTCH_HALF) },
		{ id = "NotchN", at = along(R1, R2, 0.5 + NOTCH_HALF), via = "Bridge" },
		{ id = "R2", at = R2 },
		{ id = "StepTop", at = V(60, 618, 3654), via = "Ladder" },
		{ at = STEP },
		{ id = "R3", at = R3 },
		{ id = "R4", at = R4 },
		{ id = "SummitEdge", at = SUMMIT_EDGE },
		{ id = "Summit", at = SUMMIT },
	},

	-- Optional routes (also marked). They start and end on main-route points.
	Alternates = {
		{
			name = "IceWallBypass",
			-- A ramp along the foot of the ice wall, climbing to its top at the west end.
			points = {
				{ at = V(60, plateauY(2178), 2178) },
				{ at = V(140, plateauY(2280), 2280) },
				{ at = V(120, plateauY(2280), 2280) },
				{ at = V(-200, 284, 2280) },
				{ at = V(-200, 284, 2316) },
				{ at = V(200, 284, 2310) }, -- along the wall top to the ladder's top (WallTop)
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
		{ at = V(96, 0, 352), toward = V(0, 0, 110), text = "AVALANCHE RISK" },
		{ at = V(-140, 0, 1712), toward = V(-150, 0, 1630), text = "CREVASSES" },
		{ at = V(170, 0, 2272), toward = V(60, 0, 2178), text = "ICE WALL" },
		{ at = V(96, 0, 2252), toward = V(60, 0, 2178), text = "LONG WAY ROUND" },
		{ at = V(236, 0, 2650), toward = V(0, 0, 2600), text = "SERAC FALL" },
		{ at = V(-40, 0, 3060), toward = V(-200, 0, 3030), text = "HIGH WINDS" },
	},

	-- Deadwood (WoodSource): position (y from terrain), wood per log, respawn seconds (nil =
	-- never). Wood is scarce: ten logs around Base Camp and the valley, three near Camp 1,
	-- one finite woodpile at Camp 2. Nothing grows higher up.
	WoodSources = {
		{ pos = V(-95, 0, 110), wood = 3, respawn = 240 },
		{ pos = V(124, 0, -30), wood = 3, respawn = 240 },
		{ pos = V(-70, 0, 170), wood = 4, respawn = 240 },
		{ pos = V(110, 0, 190), wood = 3, respawn = 240 },
		{ pos = V(-40, 0, 270), wood = 3, respawn = 240 },
		{ pos = V(120, 0, 320), wood = 4, respawn = 240 },
		{ pos = V(-60, 0, 390), wood = 3, respawn = 240 },
		{ pos = V(130, 0, 470), wood = 3, respawn = 240 },
		{ pos = V(60, 0, 700), wood = 3, respawn = 240 },
		{ pos = V(110, 0, 650), wood = 3, respawn = 240 },
		{ pos = V(-250, 0, 1650), wood = 3, respawn = 420 },
		{ pos = V(-60, 0, 1640), wood = 2, respawn = 420 },
		{ pos = V(-20, 0, 1720), wood = 3, respawn = 420 },
		{ pos = V(-290, 0, 3060), wood = 8, respawn = nil, woodpile = true },
	},
	-- Melt water comes from snow at fires now; camps may add their own barrels.
	WaterSources = {} :: { Vector3 },

	-- Sparse snowy pine clusters, near Base Camp only: centre, radius, count.
	TreeClusters = {
		{ x = -140, z = 130, r = 22, count = 5 },
		{ x = 130, z = 100, r = 18, count = 4 },
		{ x = -90, z = 230, r = 24, count = 5 },
		{ x = 140, z = 260, r = 20, count = 4 },
		{ x = -110, z = 470, r = 18, count = 3 },
		{ x = 130, z = 560, r = 16, count = 3 },
	},
	-- Snow-covered rocks scattered beside the route (count, min/max distance off the trail).
	RockScatter = { count = 150, near = 14, far = 80, minSize = 2, maxSize = 7 },

	-- Rockfall / serac fall hazards (DisasterService contract: invisible box covering where
	-- players stand, Release attachments, PushDirection, optional Warning text). Release
	-- y = terrain + 4.
	RockfallZones = {
		{
			name = "ValleyAvalanche",
			warning = "AVALANCHE! SNOW IS SLIDING ABOVE YOU",
			zoneCenter = V(10, 25, 500),
			zoneSize = V(160, 60, 240),
			releasePoints = { V(-250, 0, 440), V(-250, 0, 500), V(-250, 0, 560) },
			pushDirection = V(1, 0, 0),
		},
		{
			name = "SeracFall",
			warning = "THE SERACS ARE COLLAPSING ABOVE YOU",
			zoneCenter = V(SERAC.mid.X, 412, SERAC.mid.Z),
			zoneSize = V(240, 60, 100),
			releasePoints = {
				V(SERAC.center.X - SERAC.ux * 70, 0, SERAC.center.Z - SERAC.uz * 70),
				V(SERAC.center.X, 0, SERAC.center.Z),
				V(SERAC.center.X + SERAC.ux * 70, 0, SERAC.center.Z + SERAC.uz * 70),
			},
			pushDirection = V(-SERAC.nx, 0, -SERAC.nz),
		},
	},

	SectionEnd = { pos = SUMMIT, radius = 16 },

	-- Below this height a player is "lost" and is recovered to their checkpoint. The terrain
	-- never goes below y 0, so only falling off the world triggers it.
	SafetyNetY = -30,
	-- Invisible catch floor far below the terrain so a fall never goes on forever.
	SafetyFloorY = -120,
}

return WorldLayout
