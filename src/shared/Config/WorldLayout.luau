--!strict
-- Hand-authored layout of the vertical-slice mountain section, as data.
-- WorldBuilder turns this into terrain and greybox props when the place file has no
-- hand-built "Mountain" model yet. Once a level designer builds the real map in Studio,
-- they tag objects with the same CollectionService tags and this file stops mattering.
--
-- Axes: +Z is uphill, +Y is up, X is lateral. Units are studs.
--
-- Routes in the slice:
--   Technical: forest trail -> 55-stud rock cliff (rest ledge halfway) -> snow slope -> Ridge Camp
--   Safe:      forest trail -> long gravel ramp on the east side (rockfall gully) -> Ridge Camp
--   Emergency: east ravine floor, a slow crawl back up if you fall off the safe ramp
--   Beyond camp: snow slope -> 30-stud ice wall (ice axe) or a longer walk round -> Ridge Col

-- A slab is a terrain block whose top surface runs along the line from -> to.
export type Slab = {
	name: string,
	from: Vector3,
	to: Vector3,
	width: number,
	thickness: number,
	material: string, -- Enum.Material name
}

export type Block = {
	name: string,
	center: Vector3,
	size: Vector3,
	material: string,
}

local V = Vector3.new

local WorldLayout = {
	Seed = 7331,

	Slabs = {
		{ name = "BaseCamp", from = V(0, 0, -120), to = V(0, 0, 90), width = 280, thickness = 40, material = "Grass" },
		{
			name = "ForestTrail",
			from = V(0, 0, 90),
			to = V(0, 60, 400),
			width = 260,
			thickness = 60,
			material = "Grass",
		},
		{
			name = "TrailPath",
			from = V(0, 0.2, 60),
			to = V(0, 60.2, 400),
			width = 12,
			thickness = 3,
			material = "Ground",
		},
		{
			name = "CliffBase",
			from = V(20, 60, 400),
			to = V(20, 60, 450),
			width = 300,
			thickness = 60,
			material = "Ground",
		},
		{
			name = "UpperPlateau",
			from = V(0, 115, 500),
			to = V(0, 115, 560),
			width = 200,
			thickness = 60,
			material = "Ground",
		},
		{
			name = "SnowSlope",
			from = V(0, 115, 560),
			to = V(0, 150, 720),
			width = 200,
			thickness = 60,
			material = "Snow",
		},
		{
			name = "RidgeCamp",
			from = V(20, 150, 720),
			to = V(20, 150, 830),
			width = 360,
			thickness = 60,
			material = "Snow",
		},
		{
			name = "SafeRamp",
			from = V(150, 60, 450),
			to = V(150, 150, 720),
			width = 40,
			thickness = 30,
			material = "Ground",
		},
		{
			name = "OuterRidge",
			from = V(188, 92, 450),
			to = V(188, 182, 720),
			width = 36,
			thickness = 70,
			material = "Rock",
		},
		{
			name = "Ravine",
			from = V(115, 40, 450),
			to = V(115, 150, 790),
			width = 34,
			thickness = 20,
			material = "Mud",
		},
		{
			name = "UpperSnow",
			from = V(0, 150, 830),
			to = V(0, 230, 1000),
			width = 220,
			thickness = 70,
			material = "Snow",
		},
		{
			name = "IceBypass",
			from = V(92, 230, 990),
			to = V(92, 260, 1080),
			width = 30,
			thickness = 40,
			material = "Snow",
		},
		{
			name = "RidgeCol",
			from = V(0, 260, 1030),
			to = V(0, 260, 1110),
			width = 200,
			thickness = 70,
			material = "Snow",
		},
		{
			name = "WestWall",
			from = V(-140, 25, -120),
			to = V(-140, 85, 400),
			width = 30,
			thickness = 120,
			material = "Rock",
		},
		{
			name = "EastWall",
			from = V(142, 25, -120),
			to = V(142, 80, 360),
			width = 26,
			thickness = 120,
			material = "Rock",
		},
	} :: { Slab },

	Blocks = {
		{ name = "Cliff", center = V(0, 72.5, 475), size = V(200, 85, 50), material = "Rock" },
		{ name = "RestLedge", center = V(0, 86, 446.5), size = V(36, 4, 7), material = "Slate" },
		{ name = "IceWall", center = V(0, 231, 1015), size = V(90, 62, 30), material = "Glacier" },
	} :: { Block },

	-- Shallow trench carved then filled with water: from, to, width.
	Stream = { from = V(-75, 0, 40), to = V(-75, 60, 400), width = 8, depth = 2 },

	Camps = {
		{
			id = "BaseCamp",
			name = "Base Camp",
			index = 1,
			center = V(0, 0, -40),
			spawn = V(0, 0, -58),
			fire = V(0, 0, -28),
			logbook = V(-12, 0, -14),
			supply = V(38, 0, -40),
			supplyTable = "BaseCamp",
			outfitter = V(24, 0, -58),
			water = { pos = V(-26, 0, -22), treated = true, kind = "Pump" },
			cabin = { pos = V(-48, 0, -62), size = V(26, 12, 20) },
		},
		{
			id = "RidgeCamp",
			name = "Ridge Camp",
			index = 2,
			center = V(0, 150, 775),
			spawn = V(0, 150, 786),
			fire = V(0, 150, 768),
			logbook = V(14, 150, 756),
			supply = V(34, 150, 778),
			supplyTable = "RidgeCamp",
			water = { pos = V(-16, 150, 760), treated = true, kind = "Meltwater" },
			cabin = { pos = V(-44, 150, 796), size = V(22, 11, 18) },
		},
	},

	-- Stream points where bottles can be refilled with untreated water.
	WaterSources = { V(-75, 18, 130), V(-75, 40, 270), V(-75, 56, 380) },

	-- Fallen logs (wood sources): position, wood per log, respawn seconds (nil = never).
	WoodSources = {
		{ pos = V(-40, 0, 40), wood = 4, respawn = 180 },
		{ pos = V(55, 0, 70), wood = 4, respawn = 180 },
		{ pos = V(-90, 10, 140), wood = 3, respawn = 180 },
		{ pos = V(80, 15, 170), wood = 4, respawn = 180 },
		{ pos = V(-30, 25, 220), wood = 3, respawn = 180 },
		{ pos = V(95, 35, 260), wood = 4, respawn = 180 },
		{ pos = V(-100, 45, 320), wood = 3, respawn = 180 },
		{ pos = V(40, 50, 350), wood = 3, respawn = 180 },
		{ pos = V(-60, 60, 425), wood = 3, respawn = 240 },
		{ pos = V(150, 95, 560), wood = 2, respawn = 300 },
		{ pos = V(-70, 115, 530), wood = 2, respawn = 300 },
		{ pos = V(60, 128, 620), wood = 2, respawn = 400 },
		{ pos = V(-120, 150, 800), wood = 6, respawn = nil }, -- the camp woodpile: finite
	},

	-- Trees: scattered by seed inside these rectangles (x0, z0, x1, z1, count, height scale).
	TreeRegions = {
		{ x0 = -120, z0 = 0, x1 = 120, z1 = 395, count = 120, scale = 1.0 },
		{ x0 = -125, z0 = -115, x1 = 125, z1 = 0, count = 30, scale = 1.0 },
		{ x0 = -95, z0 = 505, x1 = 95, z1 = 560, count = 10, scale = 0.7 },
		{ x0 = -95, z0 = 560, x1 = 95, z1 = 690, count = 8, scale = 0.5 },
	},
	TreeKeepClear = {
		-- x, z, radius: camp clearings and the path stay open
		{ x = 0, z = -40, r = 55 },
		{ x = 0, z = 775, r = 60 },
	},
	TrailHalfWidth = 9,

	Rocks = {
		{ x0 = -125, z0 = -110, x1 = 125, z1 = 440, count = 45 },
		{ x0 = -95, z0 = 500, x1 = 95, z1 = 1000, count = 30 },
	},

	RockfallZones = {
		{
			name = "EastGully",
			zoneCenter = V(150, 115, 600),
			zoneSize = V(70, 90, 130),
			releasePoints = { V(182, 150, 560), V(182, 158, 600), V(182, 165, 640) },
			pushDirection = V(-1, 0, 0),
		},
	},

	SectionEnd = { pos = V(0, 260, 1070), radius = 22 },

	-- Below this height a player is "lost in a crevasse" and is recovered to their checkpoint.
	SafetyNetY = -30,
	WorldFloor = { center = V(0, -42, 500), size = V(900, 4, 1500) },
}

return WorldLayout
