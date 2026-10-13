--!strict
--!native
-- Pure terrain model for the generated mountain: one natural HEIGHTFIELD on Roblox's 4-stud
-- voxel grid. No Roblox services: it runs in the plain Luau test VM as well as in game.
--
-- TerrainModel.new(layout) shapes the surface in five passes:
--   1. Landscape. The main route is sampled every SAMPLE studs; each sample carries the trail
--      elevation and its section's relief (valley walls `up`, ridge drop `down`, flat `floor`
--      half-width, noise `rough`). Inverse-distance weighting spreads them into smooth fields,
--      and with d = distance to the route every column becomes
--          elevation + up * valley(d) - down * ridge(d) + mountain noise(d) + surface detail
--      so the trail runs along a valley floor or a ridge crest while fbm + ridged noise raise
--      real-looking mountains away from it. The edge of the world tapers down to the skirt.
--   2. Areas (camp pads, the crevasse plateau, shelves): flat or planar patches blended in.
--   3. Trail corridors: every walked segment levels a strip `trail` studs either side of its
--      line to the trail elevation, blending into the slope over `blend` studs (cut-and-fill
--      across a hillside, a crest walkway on a ridge).
--   4. Locked areas (the ice wall top, the ridge ice step, the serac band) are set again,
--      inside only, so a corridor can never round a cliff off.
--   5. Crevasses: slots cut down from the surface, with escape ramps along one wall.
-- Each column then gets a top material (Snow when gentler than ICE_ANGLE, else its body
-- material) and a body material (Glacier; Rock in the rare summit outcrop zones) that shows
-- on its cliff faces under a SNOW_DEPTH snow cap.
--
-- heightAt is bilinear between column centres, which is the surface WorldBuilder's voxels
-- (WriteVoxels, occupancy taken from the column height) produce, so camps, props, bridges and
-- markers are all placed from the model and never by raycasting freshly written terrain.
--
-- Positions are read through .X/.Y/.Z only, so Vector3 and the test stub both work.

local TerrainModel = {}

TerrainModel.CELL = 4 -- column size = Roblox terrain voxel size
TerrainModel.STEEP_ANGLE = 40 -- steeper than this is not walkable (Humanoid.MaxSlopeAngle 42)
TerrainModel.ICE_ANGLE = 48 -- columns steeper than this are bare Glacier (ice-axe climbable);
-- below it snow holds, so the mountains read white with teal ice on the real faces
TerrainModel.FLAT_ANGLE = 6
TerrainModel.SNOW_DEPTH = 4 -- snow cap on a gentle column; its cliff face shows the body below
TerrainModel.SHELL = 12 -- each column is solid this far below its lowest neighbour
TerrainModel.COARSE = 16 -- spacing of the smooth landscape fields
TerrainModel.SAMPLE = 32 -- route sample spacing for those fields
TerrainModel.MATERIALS = { "Snow", "Glacier", "Rock" }

local CELL = 4
local SNOW, GLACIER, ROCK = 1, 2, 3
local MAT_NAMES = TerrainModel.MATERIALS

-- Landscape shape constants (studs).
local IDW_SOFT = 30 * 30 -- inverse-distance softening (d^2 + IDW_SOFT)^-2
local VALLEY_WALL = 700 -- valley walls rise over this distance beyond the floor
local RIDGE_FALL = 240 -- ridge flanks fall off with this e-folding distance
local MOUNTAIN_RAMP = 500 -- big noise fades in over this distance beyond the floor
local DEFAULT_EDGE = 260
local RIM_FLOOR = 0.75

type Vec = { X: number, Y: number, Z: number }

export type Grid = {
	-- Column (i, k), 0-based, is the voxel column [x0 + 4i, x0 + 4i + 4] x [z0 + 4k, ...];
	-- its height is sampled at the column centre.
	x0: number,
	z0: number,
	nx: number,
	nz: number,
}

export type Model = {
	grid: Grid,
	-- Surface height (-math.huge outside the terrain), top material and the name of what
	-- shaped it ("Landscape", "Trail" or an area / crevasse name).
	heightAt: (x: number, z: number) -> (number, string, string),
	normalAt: (x: number, z: number) -> (number, number, number),
	slopeAt: (x: number, z: number) -> number,
	classify: (x: number, z: number) -> string,
	-- Column (i, k): surface height, bottom of its solid shell, top and body material codes.
	column: (i: number, k: number) -> (number, number, number, number),
	-- Material of the voxel containing (x, y, z): "Air", "Snow", "Glacier" or "Rock".
	voxelMaterial: (x: number, y: number, z: number) -> string,
	-- Solid voxels the builder writes (the terrain budget).
	solidVoxels: () -> number,
	buildSeconds: number,
}

export type RoutePoint = { x: number, y: number, z: number, id: string?, via: string? }
export type Segment = {
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
	via: string, -- "Walk" | "Bridge" | "Ladder"
	route: string,
	fromId: string?,
	toId: string?,
	trail: number, -- corridor half-width
	blend: number, -- corridor blend width
	afterLadder: boolean, -- starts at a ladder top (its corridor has a square start)
}
export type Marker = { x: number, y: number, z: number, yaw: number }

local function clamp01(t: number): number
	if t < 0 then
		return 0
	elseif t > 1 then
		return 1
	end
	return t
end

local function smooth01(t: number): number
	t = clamp01(t)
	return t * t * (3 - 2 * t)
end
TerrainModel.smooth01 = smooth01

local function norm(x: number, y: number, z: number): (number, number, number)
	local m = math.sqrt(x * x + y * y + z * z)
	if m < 1e-9 then
		return 0, 0, 0
	end
	return x / m, y / m, z / m
end

local function cross(ax: number, ay: number, az: number, bx: number, by: number, bz: number): (number, number, number)
	return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

function TerrainModel.classifySlope(degrees: number): string
	if degrees <= TerrainModel.FLAT_ANGLE then
		return "Flat"
	elseif degrees <= TerrainModel.STEEP_ANGLE then
		return "Walkable"
	end
	return "Steep"
end

-- Routes -------------------------------------------------------------------------------------

local DEFAULT_TRAIL, DEFAULT_BLEND = 10, 30

local function toPoints(list: { any }): { RoutePoint }
	local out = {}
	for _, p in list do
		table.insert(out, { x = p.at.X, y = p.at.Y, z = p.at.Z, id = p.id, via = p.via })
	end
	return out
end

-- Every route as segments: the main route, then each alternate. A segment's `via` comes from
-- its END point ("Bridge": a rope bridge spans it, "Ladder": a ladder climbs it). Trail width
-- and blend come from the layout's Relief sections (main route) or the alternate's own.
function TerrainModel.segments(layout: any): { Segment }
	local out: { Segment } = {}
	local relief = layout.Relief or {}
	local function add(name: string, points: { RoutePoint }, trail: number, blend: number, useRelief: boolean)
		for i = 2, #points do
			local a, b = points[i - 1], points[i]
			if useRelief and a.id and relief[a.id] then
				trail = relief[a.id].trail or trail
				blend = relief[a.id].blend or blend
			end
			table.insert(out, {
				ax = a.x,
				ay = a.y,
				az = a.z,
				bx = b.x,
				by = b.y,
				bz = b.z,
				via = b.via or "Walk",
				route = name,
				fromId = a.id,
				toId = b.id,
				trail = trail,
				blend = blend,
				afterLadder = a.via == "Ladder",
			})
		end
	end
	add("Main", toPoints(layout.Route or {}), DEFAULT_TRAIL, DEFAULT_BLEND, true)
	for _, alt in layout.Alternates or {} do
		add(alt.name, toPoints(alt.points), alt.trail or DEFAULT_TRAIL, alt.blend or DEFAULT_BLEND, false)
	end
	return out
end

function TerrainModel.segmentLength(s: Segment): number
	local dx, dy, dz = s.bx - s.ax, s.by - s.ay, s.bz - s.az
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Horizontal distance from (x, z) to the nearest route segment (any route).
function TerrainModel.distanceToRoute(segments: { Segment }, x: number, z: number): number
	local best = math.huge
	for _, s in segments do
		local dx, dz = s.bx - s.ax, s.bz - s.az
		local len2 = dx * dx + dz * dz
		local t = if len2 > 0 then math.clamp(((x - s.ax) * dx + (z - s.az) * dz) / len2, 0, 1) else 0
		local px, pz = s.ax + dx * t - x, s.az + dz * t - z
		best = math.min(best, math.sqrt(px * px + pz * pz))
	end
	return best
end

-- Find a named route point (main route first, then alternates).
function TerrainModel.point(layout: any, id: string): RoutePoint?
	for _, p in layout.Route or {} do
		if p.id == id then
			return { x = p.at.X, y = p.at.Y, z = p.at.Z, id = p.id, via = p.via }
		end
	end
	for _, alt in layout.Alternates or {} do
		for _, p in alt.points do
			if p.id == id then
				return { x = p.at.X, y = p.at.Y, z = p.at.Z, id = p.id, via = p.via }
			end
		end
	end
	return nil
end

-- Landscape fields -----------------------------------------------------------------------------

type Sample = { x: number, z: number, y: number, up: number, down: number, floor: number, rough: number }

-- Main-route samples every SAMPLE studs, each with the relief of the section it is in.
local function routeSamples(layout: any): { Sample }
	local relief = layout.Relief or {}
	local current = { up = 0, down = 0, floor = 60, rough = 1 }
	local out: { Sample } = {}
	local route = layout.Route or {}
	local function push(x: number, z: number, y: number)
		table.insert(out, {
			x = x,
			z = z,
			y = y,
			up = current.up or 0,
			down = current.down or 0,
			floor = current.floor or 60,
			rough = current.rough or 1,
		})
	end
	for i, p in route do
		if p.id and relief[p.id] then
			current = relief[p.id]
		end
		local nextPoint = route[i + 1]
		if not nextPoint then
			push(p.at.X, p.at.Z, p.at.Y)
			break
		end
		local a, b = p.at, nextPoint.at
		local dx, dz = b.X - a.X, b.Z - a.Z
		local n = math.max(1, math.ceil(math.sqrt(dx * dx + dz * dz) / TerrainModel.SAMPLE))
		for k = 0, n - 1 do
			local t = k / n
			push(a.X + dx * t, a.Z + dz * t, a.Y + (b.Y - a.Y) * t)
		end
	end
	return out
end

local function segmentDistance(s: Segment, x: number, z: number): (number, number)
	local dx, dz = s.bx - s.ax, s.bz - s.az
	local len2 = dx * dx + dz * dz
	local t = if len2 > 0 then ((x - s.ax) * dx + (z - s.az) * dz) / len2 else 0
	local tc = clamp01(t)
	local px, pz = s.ax + dx * tc - x, s.az + dz * tc - z
	return math.sqrt(px * px + pz * pz), t
end

-- Noise: fbm for the broad massifs plus ridged noise for sharp crests, roughly [-1, 1]. Few,
-- long octaves: the slopes stay broad and mostly snowy; only crests and big faces go to ice.
local function mountainNoise(x: number, z: number, seed: number): number
	local f = 1 / 1000
	local fbm, amp = 0, 1
	for octave = 0, 3 do
		fbm += math.noise(x * f, seed + octave * 7.31, z * f) * amp
		f *= 2
		amp *= 0.45
	end
	local g = 1 / 650
	local ridged, ramp = 0, 1
	for octave = 0, 1 do
		local r = 1 - math.abs(math.noise(x * g, seed + 50 + octave * 3.7, z * g))
		ridged += r * r * ramp
		g *= 2.2
		ramp *= 0.4
	end
	return fbm + (ridged - 0.55) * 0.9
end

-- Small rolling bumps everywhere (0 .. ~6 studs); trail corridors and areas level them.
local function surfaceDetail(x: number, z: number, seed: number): number
	return 2.6 + 2.6 * math.noise(x / 70, seed + 101.3, z / 70) + 1.1 * math.noise(x / 23, seed + 202.9, z / 23)
end

-- Areas ------------------------------------------------------------------------------------------

-- Weight of an area at (x, z): 1 inside, easing to 0 across its blend band, 0 beyond.
-- Returns the weight and the area's target height there.
local function areaWeight(def: any, x: number, z: number): (number, number)
	if def.kind == "pad" then
		local dx, dz = x - def.x, z - def.z
		local r = math.sqrt(dx * dx + dz * dz)
		local y = def.y
		if r <= def.r then
			return 1, y
		end
		local blend = def.blend or 0
		if blend <= 0 then
			return 0, y
		end
		return 1 - smooth01((r - def.r) / blend), y
	end
	-- "rect": centre (x, z), size (sx along local x, sz along local z), yaw in degrees (local
	-- +z = (sin yaw, cos yaw) in world x/z), height y at the centre rising `grade` per stud
	-- along local +z. Blend: a number, or per side { n = +z, s = -z, e = +x, w = -x }.
	local yaw = math.rad(def.yaw or 0)
	local sn, cs = math.sin(yaw), math.cos(yaw)
	local dx, dz = x - def.x, z - def.z
	local lx = dx * cs - dz * sn
	local lz = dx * sn + dz * cs
	local y = def.y + (def.grade or 0) * lz
	local hx, hz = def.sx / 2, def.sz / 2
	local ox, oz = 0, 0
	local blend = def.blend or 0
	local function side(key: string): number
		if type(blend) == "number" then
			return blend
		end
		return blend[key] or 0
	end
	if lx > hx then
		local b = side("e")
		if b <= 0 then
			return 0, y
		end
		ox = (lx - hx) / b
	elseif lx < -hx then
		local b = side("w")
		if b <= 0 then
			return 0, y
		end
		ox = (-hx - lx) / b
	end
	if lz > hz then
		local b = side("n")
		if b <= 0 then
			return 0, y
		end
		oz = (lz - hz) / b
	elseif lz < -hz then
		local b = side("s")
		if b <= 0 then
			return 0, y
		end
		oz = (-hz - lz) / b
	end
	if ox == 0 and oz == 0 then
		return 1, y
	end
	return 1 - smooth01(math.sqrt(ox * ox + oz * oz)), y
end
TerrainModel.areaWeight = areaWeight

-- World-space x/z bounds of an area including its blend band.
local function areaBounds(def: any): (number, number, number, number)
	local reach
	if def.kind == "pad" then
		reach = def.r + (def.blend or 0)
	else
		local blend = def.blend or 0
		local b = 0
		if type(blend) == "number" then
			b = blend
		else
			for _, v in blend do
				b = math.max(b, v)
			end
		end
		reach = math.sqrt(def.sx * def.sx + def.sz * def.sz) / 2 + b
	end
	return def.x - reach, def.z - reach, def.x + reach, def.z + reach
end

local function crevasseFrame(def: any): (number, number)
	local dx, dz = def.dir.X, def.dir.Z
	local m = math.sqrt(dx * dx + dz * dz)
	return dx / m, dz / m
end

-- The model ----------------------------------------------------------------------------------------

function TerrainModel.new(layout: any): Model
	local started = os.clock()
	local bounds = layout.Bounds
	local land = layout.Landscape or {}
	local seed = land.seed or layout.Seed or 1
	local edge = land.edge or DEFAULT_EDGE
	local noiseScale = land.noise or 220

	local gx0, gz0 = bounds.x0, bounds.z0
	local nx = math.floor((bounds.x1 - bounds.x0) / CELL)
	local nz = math.floor((bounds.z1 - bounds.z0) / CELL)
	local count = nx * nz
	local H = buffer.create(count * 4) -- f32 heights
	local mats = buffer.create(count) -- top + 4 * body
	local who = buffer.create(count) -- shaper id (index into `names`)
	local names = { "Landscape", "Trail" }
	local TRAIL_ID = 1

	local function colX(i: number): number
		return gx0 + 2 + CELL * i
	end
	local function colZ(k: number): number
		return gz0 + 2 + CELL * k
	end
	local function getH(i: number, k: number): number
		return buffer.readf32(H, (k * nx + i) * 4)
	end
	local function setH(i: number, k: number, h: number)
		buffer.writef32(H, (k * nx + i) * 4, h)
	end
	local function setWho(i: number, k: number, id: number)
		buffer.writeu8(who, k * nx + i, id)
	end
	-- Column index range covering world x/z [a, b] (clamped to the grid).
	local function colRange(a: number, b: number, origin: number, n: number): (number, number)
		local lo = math.max(0, math.ceil((a - origin - 2) / CELL))
		local hi = math.min(n - 1, math.floor((b - origin - 2) / CELL))
		return lo, hi
	end
	local function bilinear(x: number, z: number): number
		local fx = (x - gx0 - 2) / CELL
		local fz = (z - gz0 - 2) / CELL
		local i = math.clamp(math.floor(fx), 0, nx - 2)
		local k = math.clamp(math.floor(fz), 0, nz - 2)
		local tx, tz = clamp01(fx - i), clamp01(fz - k)
		local h00, h10 = getH(i, k), getH(i + 1, k)
		local h01, h11 = getH(i, k + 1), getH(i + 1, k + 1)
		return (h00 * (1 - tx) + h10 * tx) * (1 - tz) + (h01 * (1 - tx) + h11 * tx) * tz
	end

	-- 1. Landscape: smooth fields on coarse grids, then every column. ---------------------------
	-- The relief fields come from inverse-distance weighting the route samples on a 32-stud
	-- grid; the distance to the route needs more detail and gets a 16-stud grid.
	local samples = routeSamples(layout)
	local segments = TerrainModel.segments(layout)
	local function coarseGrid(step: number, fn: (x: number, z: number, idx: number) -> ()): number
		local cnx = math.floor((bounds.x1 - bounds.x0) / step) + 2
		local cnz = math.floor((bounds.z1 - bounds.z0) / step) + 2
		for ck = 0, cnz - 1 do
			for ci = 0, cnx - 1 do
				fn(gx0 + ci * step, gz0 + ck * step, ck * cnx + ci + 1)
			end
		end
		return cnx
	end
	local nS = #samples
	local sX, sZ, sY = table.create(nS, 0), table.create(nS, 0), table.create(nS, 0)
	local sU, sDn, sF, sR = table.create(nS, 0), table.create(nS, 0), table.create(nS, 0), table.create(nS, 0)
	for n, smp in samples do
		sX[n], sZ[n], sY[n] = smp.x, smp.z, smp.y
		sU[n], sDn[n], sF[n], sR[n] = smp.up, smp.down, smp.floor, smp.rough
	end
	local fE, fUp, fDown, fFloor, fRough, fD = {}, {}, {}, {}, {}, {}
	local IDW_STEP = 2 * TerrainModel.COARSE
	local inx = coarseGrid(IDW_STEP, function(x: number, z: number, idx: number)
		local sw, sy, su, sd, sf, sr = 0, 0, 0, 0, 0, 0
		for n = 1, nS do
			local dx, dz = x - sX[n], z - sZ[n]
			local q = dx * dx + dz * dz + IDW_SOFT
			local w = 1 / (q * q)
			sw += w
			sy += w * sY[n]
			su += w * sU[n]
			sd += w * sDn[n]
			sf += w * sF[n]
			sr += w * sR[n]
		end
		fE[idx], fUp[idx], fDown[idx] = sy / sw, su / sw, sd / sw
		fFloor[idx], fRough[idx] = sf / sw, sr / sw
	end)
	local nG = #segments
	local gAX, gAZ, gDX, gDZ, gL2 =
		table.create(nG, 0), table.create(nG, 0), table.create(nG, 0), table.create(nG, 0), table.create(nG, 0)
	for n, sg in segments do
		gAX[n], gAZ[n] = sg.ax, sg.az
		gDX[n], gDZ[n] = sg.bx - sg.ax, sg.bz - sg.az
		gL2[n] = math.max(gDX[n] * gDX[n] + gDZ[n] * gDZ[n], 1e-9)
	end
	local DSTEP = TerrainModel.COARSE
	local dnx = coarseGrid(DSTEP, function(x: number, z: number, idx: number)
		local best = math.huge
		for n = 1, nG do
			local t = clamp01(((x - gAX[n]) * gDX[n] + (z - gAZ[n]) * gDZ[n]) / gL2[n])
			local px, pz = gAX[n] + gDX[n] * t - x, gAZ[n] + gDZ[n] * t - z
			local d2 = px * px + pz * pz
			if d2 < best then
				best = d2
			end
		end
		fD[idx] = math.sqrt(best)
	end)
	-- Resample the relief fields onto the distance grid so each column reads one grid.
	local gE, gUp, gDown, gFloor, gRough = {}, {}, {}, {}, {}
	coarseGrid(DSTEP, function(x: number, z: number, idx: number)
		local fx, fz = (x - gx0) / IDW_STEP, (z - gz0) / IDW_STEP
		local ci, ck = math.floor(fx), math.floor(fz)
		local tx, tz = fx - ci, fz - ck
		local a = ck * inx + ci + 1
		local w00, w10, w01, w11 = (1 - tx) * (1 - tz), tx * (1 - tz), (1 - tx) * tz, tx * tz
		local b, c, d = a + 1, a + inx, a + inx + 1
		gE[idx] = fE[a] * w00 + fE[b] * w10 + fE[c] * w01 + fE[d] * w11
		gUp[idx] = fUp[a] * w00 + fUp[b] * w10 + fUp[c] * w01 + fUp[d] * w11
		gDown[idx] = fDown[a] * w00 + fDown[b] * w10 + fDown[c] * w01 + fDown[d] * w11
		gFloor[idx] = fFloor[a] * w00 + fFloor[b] * w10 + fFloor[c] * w01 + fFloor[d] * w11
		gRough[idx] = fRough[a] * w00 + fRough[b] * w10 + fRough[c] * w01 + fRough[d] * w11
	end)

	for k = 0, nz - 1 do
		local z = colZ(k)
		local fz = (z - gz0) / DSTEP
		local ck = math.floor(fz)
		local tz = fz - ck
		for i = 0, nx - 1 do
			local x = colX(i)
			local fx = (x - gx0) / DSTEP
			local ci = math.floor(fx)
			local tx = fx - ci
			local a = ck * dnx + ci + 1
			local b, c, d = a + 1, a + dnx, a + dnx + 1
			local w00, w10, w01, w11 = (1 - tx) * (1 - tz), tx * (1 - tz), (1 - tx) * tz, tx * tz
			local e = gE[a] * w00 + gE[b] * w10 + gE[c] * w01 + gE[d] * w11
			local up = gUp[a] * w00 + gUp[b] * w10 + gUp[c] * w01 + gUp[d] * w11
			local down = gDown[a] * w00 + gDown[b] * w10 + gDown[c] * w01 + gDown[d] * w11
			local floor = gFloor[a] * w00 + gFloor[b] * w10 + gFloor[c] * w01 + gFloor[d] * w11
			local rough = gRough[a] * w00 + gRough[b] * w10 + gRough[c] * w01 + gRough[d] * w11
			local dist = fD[a] * w00 + fD[b] * w10 + fD[c] * w01 + fD[d] * w11
			local h = e
				+ up * smooth01((dist - floor) / VALLEY_WALL)
				- down * (1 - math.exp(-dist / RIDGE_FALL))
				+ rough * noiseScale * mountainNoise(x, z, seed) * smooth01((dist - floor * 0.5) / MOUNTAIN_RAMP)
				+ surfaceDetail(x, z, seed)
			-- The world's rim eases down (to three quarters of its height at the very edge: a cliff
			-- that faces away from the mountain, so nobody inside ever sees it).
			local rim = math.min(x - bounds.x0, bounds.x1 - x, z - bounds.z0, bounds.z1 - z)
			h *= RIM_FLOOR + (1 - RIM_FLOOR) * smooth01(rim / edge)
			setH(i, k, math.max(h, 0))
		end
	end

	-- 2-4. Areas and trail corridors. -------------------------------------------------------------
	local areas = layout.Areas or {}
	local function applyArea(def: any, id: number, insideOnly: boolean)
		local raise = def.mode == "raise"
		local ax0, az0, ax1, az1 = areaBounds(def)
		local i0, i1 = colRange(ax0, ax1, gx0, nx)
		local k0, k1 = colRange(az0, az1, gz0, nz)
		for k = k0, k1 do
			local z = colZ(k)
			for i = i0, i1 do
				local w, y = areaWeight(def, colX(i), z)
				local h = getH(i, k)
				if raise and y <= h then
					continue -- a raising area never lowers the ground
				end
				if insideOnly then
					if w >= 1 then
						setH(i, k, y)
						setWho(i, k, id)
					end
				elseif w > 0 then
					setH(i, k, h + (y - h) * w)
					if w >= 0.02 then
						setWho(i, k, id)
					end
				end
			end
		end
	end
	local areaIds = {}
	for _, def in areas do
		table.insert(names, def.name)
		areaIds[def] = #names - 1
		applyArea(def, areaIds[def], false)
	end

	-- Corridors: for each column, the strongest corridor weight decides how much of the trail
	-- shows; the target is the trail height of every touching segment, weighted towards the
	-- nearest one, so joints and hairpins stay smooth and the centre line stays exact.
	-- Cliffs stop corridors: a trail on top of a locked area (or beside it) never blends
	-- across that area's hard edge, so a shelf-top path can't ramp the cliff face away.
	local locked = {}
	for _, def in areas do
		if def.locked then
			local bx0, bz0, bx1, bz1 = areaBounds(def)
			table.insert(locked, { def = def, x0 = bx0, z0 = bz0, x1 = bx1, z1 = bz1 })
		end
	end
	local function insideLocked(L: any, x: number, z: number): boolean
		if x < L.x0 or x > L.x1 or z < L.z0 or z > L.z1 then
			return false
		end
		return (areaWeight(L.def, x, z)) >= 1
	end
	-- True if the straight line Q -> P passes through the inside of locked area L.
	local function crossesLocked(L: any, qx: number, qz: number, px: number, pz: number): boolean
		if math.max(qx, px) < L.x0 or math.min(qx, px) > L.x1 then
			return false
		end
		if math.max(qz, pz) < L.z0 or math.min(qz, pz) > L.z1 then
			return false
		end
		local def = L.def
		if def.kind == "pad" then
			local dx, dz = px - qx, pz - qz
			local len2 = dx * dx + dz * dz
			local t = if len2 > 0 then clamp01(((def.x - qx) * dx + (def.z - qz) * dz) / len2) else 0
			local ex, ez = qx + dx * t - def.x, qz + dz * t - def.z
			return ex * ex + ez * ez <= def.r * def.r
		end
		-- Liang-Barsky clip of the segment against the rect in its local frame.
		local yaw = math.rad(def.yaw or 0)
		local sn, cs = math.sin(yaw), math.cos(yaw)
		local function toLocal(x: number, z: number): (number, number)
			local dx, dz = x - def.x, z - def.z
			return dx * cs - dz * sn, dx * sn + dz * cs
		end
		local ax, az = toLocal(qx, qz)
		local bx, bz = toLocal(px, pz)
		local t0, t1 = 0, 1
		for _, edge in
			{
				{ -(bx - ax), ax + def.sx / 2 },
				{ bx - ax, def.sx / 2 - ax },
				{ -(bz - az), az + def.sz / 2 },
				{ bz - az, def.sz / 2 - az },
			}
		do
			local p, q = edge[1], edge[2]
			if math.abs(p) < 1e-9 then
				if q < 0 then
					return false
				end
			else
				local r = q / p
				if p < 0 then
					t0 = math.max(t0, r)
				else
					t1 = math.min(t1, r)
				end
				if t0 > t1 then
					return false
				end
			end
		end
		return true
	end
	local cMax: { [number]: number } = {}
	local cSum: { [number]: number } = {}
	local cY: { [number]: number } = {}
	for _, s in segments do
		if s.via ~= "Walk" then
			continue
		end
		local reach = s.trail + s.blend
		local i0, i1 = colRange(math.min(s.ax, s.bx) - reach, math.max(s.ax, s.bx) + reach, gx0, nx)
		local k0, k1 = colRange(math.min(s.az, s.bz) - reach, math.max(s.az, s.bz) + reach, gz0, nz)
		for k = k0, k1 do
			local z = colZ(k)
			for i = i0, i1 do
				local x = colX(i)
				local d, t = segmentDistance(s, x, z)
				if d >= reach or (t < 0 and s.afterLadder) then
					continue
				end
				local tc = clamp01(t)
				local qx, qz = s.ax + (s.bx - s.ax) * tc, s.az + (s.bz - s.az) * tc
				local blocked = false
				for _, L in locked do
					-- Blocked when P lies beyond a hard edge (outside the area and its blend
					-- band) with the area in between.
					if
						not insideLocked(L, x, z)
						and (areaWeight(L.def, x, z)) <= 0
						and crossesLocked(L, qx, qz, x, z)
					then
						blocked = true
						break
					end
				end
				if blocked then
					continue
				end
				local w = if d <= s.trail then 1 else 1 - smooth01((d - s.trail) / s.blend)
				local y = s.ay + (s.by - s.ay) * tc
				local kw = w / ((d + 2) * (d + 2))
				local idx = k * nx + i
				cMax[idx] = math.max(cMax[idx] or 0, w)
				cSum[idx] = (cSum[idx] or 0) + kw
				cY[idx] = (cY[idx] or 0) + kw * y
			end
		end
	end
	for idx, w in cMax do
		local i, k = idx % nx, idx // nx
		local h = getH(i, k)
		local y = cY[idx] / cSum[idx]
		setH(i, k, h + (y - h) * w)
		if w >= 0.5 then
			setWho(i, k, TRAIL_ID)
		end
	end
	for _, def in areas do
		if def.locked then
			applyArea(def, areaIds[def], true)
		end
	end

	-- 5. Crevasses: cut relative to the surface built so far. ------------------------------------
	local iceCols: { [number]: boolean } = {}
	for _, def in layout.Crevasses or {} do
		table.insert(names, def.name)
		local id = #names - 1
		local dx, dz = crevasseFrame(def)
		local cx, cz = def.at.X, def.at.Z
		local lip = bilinear(cx, cz)
		local floorY = lip - def.depth
		local halfL, halfW = def.length / 2, def.width / 2
		local ramp = def.ramp
		local rampLip = lip
		if ramp then
			local off = (ramp.side or -1) * (halfW - ramp.width / 2)
			rampLip = bilinear(cx + dx * ramp.high - dz * off, cz + dz * ramp.high + dx * off)
		end
		local reach = halfL + halfW
		local i0, i1 = colRange(cx - reach, cx + reach, gx0, nx)
		local k0, k1 = colRange(cz - reach, cz + reach, gz0, nz)
		for k = k0, k1 do
			local z = colZ(k)
			for i = i0, i1 do
				local x = colX(i)
				local along = (x - cx) * dx + (z - cz) * dz
				local across = -(x - cx) * dz + (z - cz) * dx
				if math.abs(along) > halfL then
					continue
				end
				-- Lens shaped: full width along most of its length, pinching shut at the ends.
				local u4 = (along / halfL) ^ 4
				local localHalfW = halfW * math.sqrt(1 - u4)
				if math.abs(across) > localHalfW then
					continue
				end
				local cut = floorY
				if ramp and across * (ramp.side or -1) >= localHalfW - ramp.width then
					local u = (along - ramp.low) / (ramp.high - ramp.low)
					cut = floorY + (rampLip - floorY) * clamp01(u)
				end
				local h = getH(i, k)
				if cut < h then
					setH(i, k, cut)
					setWho(i, k, id)
					iceCols[k * nx + i] = true
				end
			end
		end
	end

	-- Materials: slope from neighbour differences, Rock only in the summit outcrop zones. --------
	local rockZones = layout.RockZones or {}
	local tanSteep = math.tan(math.rad(TerrainModel.ICE_ANGLE))
	for k = 0, nz - 1 do
		local z = colZ(k)
		for i = 0, nx - 1 do
			local x = colX(i)
			-- Steep only if the face continues on both sides: a cliff's top and bottom
			-- columns stay snow (a snow lip over an ice face), a real slope turns to ice.
			local h = getH(i, k)
			local gx, gz = 0, 0
			if i > 0 and i < nx - 1 then
				gx = math.min(math.abs(getH(i + 1, k) - h), math.abs(h - getH(i - 1, k))) / CELL
			end
			if k > 0 and k < nz - 1 then
				gz = math.min(math.abs(getH(i, k + 1) - h), math.abs(h - getH(i, k - 1))) / CELL
			end
			local steep = gx * gx + gz * gz > tanSteep * tanSteep
			local body = GLACIER
			if steep and not iceCols[k * nx + i] then
				for _, zone in rockZones do
					local ddx, ddz = x - zone.x, z - zone.z
					if ddx * ddx + ddz * ddz < zone.r * zone.r and math.noise(x / 40, seed + 303.3, z / 40) > -0.1 then
						body = ROCK
						break
					end
				end
			end
			buffer.writeu8(mats, k * nx + i, (if steep then body else SNOW) + 4 * body)
		end
	end

	-- Queries ---------------------------------------------------------------------------------------
	local x1, z1 = gx0 + nx * CELL, gz0 + nz * CELL

	local function nearest(x: number, z: number): (number, number)
		local i = math.clamp(math.floor((x - gx0) / CELL), 0, nx - 1)
		local k = math.clamp(math.floor((z - gz0) / CELL), 0, nz - 1)
		return i, k
	end

	local function heightAt(x: number, z: number): (number, string, string)
		if x < gx0 or x > x1 or z < gz0 or z > z1 then
			return -math.huge, "Air", ""
		end
		local i, k = nearest(x, z)
		local m = buffer.readu8(mats, k * nx + i)
		return bilinear(x, z), MAT_NAMES[m % 4], names[buffer.readu8(who, k * nx + i) + 1]
	end

	local function normalAt(x: number, z: number): (number, number, number)
		local d = 1
		local hx0, hx1 = heightAt(x - d, z), heightAt(x + d, z)
		local hz0, hz1 = heightAt(x, z - d), heightAt(x, z + d)
		if hx0 == -math.huge or hx1 == -math.huge or hz0 == -math.huge or hz1 == -math.huge then
			return 0, 0, 1 -- an edge into the void: report it as a wall
		end
		return norm(-(hx1 - hx0) / (2 * d), 1, -(hz1 - hz0) / (2 * d))
	end

	local function slopeAt(x: number, z: number): number
		local _, ny = normalAt(x, z)
		return math.deg(math.acos(math.clamp(ny, -1, 1)))
	end

	local function column(i: number, k: number): (number, number, number, number)
		local h = getH(i, k)
		local low = h
		if i > 0 then
			low = math.min(low, getH(i - 1, k))
		end
		if i < nx - 1 then
			low = math.min(low, getH(i + 1, k))
		end
		if k > 0 then
			low = math.min(low, getH(i, k - 1))
		end
		if k < nz - 1 then
			low = math.min(low, getH(i, k + 1))
		end
		local m = buffer.readu8(mats, k * nx + i)
		return h, low - TerrainModel.SHELL, m % 4, m // 4
	end

	local function columnMaterial(i: number, k: number, y: number): string
		local h, bottom, top, body = column(i, k)
		if y > h or y < bottom then
			return "Air"
		end
		if top == SNOW and y > h - TerrainModel.SNOW_DEPTH then
			return "Snow"
		end
		return MAT_NAMES[body]
	end

	local function voxelMaterial(x: number, y: number, z: number): string
		if x < gx0 or x > x1 or z < gz0 or z > z1 then
			return "Air"
		end
		local i, k = nearest(x, z)
		local mat = columnMaterial(i, k, y)
		if mat ~= "Air" or y > bilinear(x, z) then
			return mat
		end
		-- Under the (bilinear) surface of a cliff but past its voxel edge: the solid is the
		-- tallest column of the surrounding cell that reaches this height.
		local ci = math.clamp(math.floor((x - gx0 - 2) / CELL), 0, nx - 2)
		local ck = math.clamp(math.floor((z - gz0 - 2) / CELL), 0, nz - 2)
		local best, bestH = "Air", -math.huge
		for _, c in { { ci, ck }, { ci + 1, ck }, { ci, ck + 1 }, { ci + 1, ck + 1 } } do
			local m = columnMaterial(c[1], c[2], y)
			local h = getH(c[1], c[2])
			if m ~= "Air" and h > bestH then
				best, bestH = m, h
			end
		end
		return best
	end

	local function solidVoxels(): number
		local total = 0
		for k = 0, nz - 1 do
			for i = 0, nx - 1 do
				local h, bottom = column(i, k)
				total += math.ceil(h / CELL) - math.floor(bottom / CELL)
			end
		end
		return total
	end

	return {
		grid = { x0 = gx0, z0 = gz0, nx = nx, nz = nz },
		heightAt = heightAt,
		normalAt = normalAt,
		slopeAt = slopeAt,
		classify = function(x: number, z: number): string
			return TerrainModel.classifySlope(slopeAt(x, z))
		end,
		column = column,
		voxelMaterial = voxelMaterial,
		solidVoxels = solidVoxels,
		buildSeconds = os.clock() - started,
	}
end

-- Scenery peaks -----------------------------------------------------------------------------
-- Far backdrop mountains are Parts, not terrain: a cube standing on one corner reads as a
-- three-faced pyramid peak (faces at 54.7 degrees, i.e. Glacier-steep). The cube is sized so
-- the ground cuts it above its upper three corners: no face ever overhangs.

local INV_SQRT3 = 1 / math.sqrt(3)
local SQRT_TWO_THIRDS = math.sqrt(2 / 3)

-- Horizontal unit directions of the three upper faces' outward normals.
local function peakDirs(yawDegrees: number): { { number } }
	local out = {}
	for i = 0, 2 do
		local a = math.rad(yawDegrees + i * 120)
		table.insert(out, { math.sin(a), math.cos(a) })
	end
	return out
end

-- Cube side for a peak `top` studs above the ground (upper corners stay below ground).
function TerrainModel.peakSide(top: number): number
	return top * math.sqrt(3) + 40
end

-- Unit cube axes (a1, a2, a3), right-handed, with a1 + a2 + a3 pointing straight up.
function TerrainModel.peakAxes(yawDegrees: number): { { number } }
	local axes = {}
	for _, d in peakDirs(yawDegrees) do
		table.insert(axes, { d[1] * SQRT_TWO_THIRDS, INV_SQRT3, d[2] * SQRT_TWO_THIRDS })
	end
	local a, b, c = axes[1], axes[2], axes[3]
	local cx, cy, cz = cross(a[1], a[2], a[3], b[1], b[2], b[3])
	if cx * c[1] + cy * c[2] + cz * c[3] < 0 then
		axes[1], axes[2] = b, a
	end
	return axes
end

-- Height of the scenery peaks at (x, z) (-math.huge where there are none).
function TerrainModel.sceneryHeight(layout: any, x: number, z: number): number
	local best = -math.huge
	for _, p in layout.Scenery or {} do
		local dx, dz = x - p.x, z - p.z
		local reach = -math.huge
		for _, d in peakDirs(p.yaw or 0) do
			reach = math.max(reach, dx * d[1] + dz * d[2])
		end
		local h = p.top - math.sqrt(2) * reach
		if h >= 0 then
			best = math.max(best, h)
		end
	end
	return best
end

-- Route marker spots: every `spacing` studs along walked segments, `offset` studs to the
-- side (whichever side is solid, level ground), never inside camps or on bridges/ladders.
function TerrainModel.markers(layout: any, model: Model, spacing: number, offset: number): { Marker }
	local out: { Marker } = {}
	local camps = layout.Camps or {}
	local function inCamp(x: number, z: number): boolean
		for _, camp in camps do
			local c = camp.center
			local fx, fz = camp.footprint.X, camp.footprint.Z
			if math.abs(x - c.X) < fx / 2 + 12 and math.abs(z - c.Z) < fz / 2 + 12 then
				return true
			end
		end
		return false
	end
	local carried = 0
	local lastRoute = ""
	local all = TerrainModel.segments(layout)
	for _, s in all do
		if s.route ~= lastRoute then
			lastRoute = s.route
			carried = spacing * 0.5
		end
		local dx, dz = s.bx - s.ax, s.bz - s.az
		local flat = math.sqrt(dx * dx + dz * dz)
		if s.via ~= "Walk" or flat < 1 then
			carried = spacing * 0.5
			continue
		end
		local ux, uz = dx / flat, dz / flat
		local d = spacing - carried
		while d < flat - 4 do
			local t = d / flat
			local px, pz = s.ax + dx * t, s.az + dz * t
			local py = s.ay + (s.by - s.ay) * t
			if not inCamp(px, pz) and d > 4 then
				for _, side in { 1, -1 } do
					local mx, mz = px + uz * offset * side, pz - ux * offset * side
					local h = model.heightAt(mx, mz)
					if
						math.abs(h - py) < 3
						and model.slopeAt(mx, mz) < 35
						and TerrainModel.distanceToRoute(all, mx, mz) >= offset - 1
					then
						table.insert(out, { x = mx, y = h, z = mz, yaw = math.atan2(ux, uz) })
						break
					end
				end
			end
			d += spacing
		end
		carried = flat - (d - spacing)
	end
	return out
end

return TerrainModel
