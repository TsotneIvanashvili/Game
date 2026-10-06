--!strict
-- Pure terrain model for the generated mountain. No Roblox services: it runs in the plain
-- Luau test VM as well as in game.
--
-- WorldLayout describes the terrain as primitives (route slabs, pads, shelves, mountains,
-- ridge crests, crevasses, rock outcrops). TerrainModel.ops turns that data into ONE ordered
-- list of operations. WorldBuilder replays the list with Terrain:FillBlock / FillBall /
-- FillCylinder / ReplaceMaterial, and TerrainModel.new evaluates the very same list
-- analytically, so props, camps, bridges and markers are placed from the model and never
-- depend on raycasting terrain that was written a moment earlier (that raycast misses).
--
-- Evaluation rules (mirroring how the fills overwrite each other, in order):
--   Fill    : a solid whose top is at or above the current surface becomes the surface
--             (later fills win ties, which is how a thin Snow layer tops a Glacier body).
--   Carve   : an Air box containing the current surface lowers it to the carve floor.
--   Replace : the surface material inside the box is swapped (Glacier -> Snow mountain caps).
--
-- Positions are read through .X/.Y/.Z only, so Vector3 and the test stub both work.

local TerrainModel = {}

TerrainModel.SNOW_DEPTH = 6 -- studs of Snow laid over every Glacier route body
TerrainModel.CAP_ANGLE = 38 -- mountain flanks gentler than this get a Snow cap
TerrainModel.STEEP_ANGLE = 40 -- steeper than this is Glacier / not walkable
TerrainModel.FLAT_ANGLE = 6
TerrainModel.DEFAULT_BOTTOM = -20 -- route bodies reach down to here unless told otherwise
TerrainModel.CELL = 64 -- spatial bucket size for queries
TerrainModel.EXTEND = 2 -- slabs overrun their end points a little so joints never gap

local EPS = 0.05
local SQRT_HALF = math.sqrt(0.5)

type Vec = { X: number, Y: number, Z: number }

export type Op = {
	name: string,
	shape: string, -- "Box" | "Ball" | "Cylinder"
	mode: string, -- "Fill" | "Carve" | "Replace"
	material: string, -- Fill: material. Carve: the exposed floor. Replace: target material.
	source: string, -- Replace: the material being replaced ("" otherwise)
	cx: number,
	cy: number,
	cz: number,
	-- Box: right / up / back unit axes (right x up = back) and the full size along each.
	rx: number,
	ry: number,
	rz: number,
	ux: number,
	uy: number,
	uz: number,
	bx: number,
	by: number,
	bz: number,
	sx: number,
	sy: number,
	sz: number,
	radius: number, -- Ball, Cylinder
	height: number, -- Cylinder (vertical axis)
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	voxels: number, -- 4x4x4 voxels touched, for the fill budget
}

export type Model = {
	ops: { Op },
	-- Surface height (-math.huge where there is no terrain), its material, and the name of the
	-- operation that decided it (for diagnostics).
	heightAt: (x: number, z: number) -> (number, string, string),
	normalAt: (x: number, z: number) -> (number, number, number),
	slopeAt: (x: number, z: number) -> number,
	classify: (x: number, z: number) -> string,
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
}
export type Marker = { x: number, y: number, z: number, yaw: number }

-- Vector helpers on plain numbers -------------------------------------------------------------

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

local function blank(name: string, shape: string, mode: string, material: string): Op
	return {
		name = name,
		shape = shape,
		mode = mode,
		material = material,
		source = "",
		cx = 0,
		cy = 0,
		cz = 0,
		rx = 1,
		ry = 0,
		rz = 0,
		ux = 0,
		uy = 1,
		uz = 0,
		bx = 0,
		by = 0,
		bz = 1,
		sx = 0,
		sy = 0,
		sz = 0,
		radius = 0,
		height = 0,
		minX = 0,
		maxX = 0,
		minZ = 0,
		maxZ = 0,
		voxels = 0,
	}
end

local function finishBox(op: Op): Op
	local hx, hy, hz = op.sx / 2, op.sy / 2, op.sz / 2
	local ex = math.abs(op.rx) * hx + math.abs(op.ux) * hy + math.abs(op.bx) * hz
	local ez = math.abs(op.rz) * hx + math.abs(op.uz) * hy + math.abs(op.bz) * hz
	op.minX, op.maxX = op.cx - ex, op.cx + ex
	op.minZ, op.maxZ = op.cz - ez, op.cz + ez
	op.voxels = op.sx * op.sy * op.sz / 64
	return op
end

-- Axis-aligned box from min/max corners.
function TerrainModel.aabbOp(
	name: string,
	mode: string,
	material: string,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): Op
	local op = blank(name, "Box", mode, material)
	op.cx, op.cy, op.cz = (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2
	op.sx, op.sy, op.sz = math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)
	return finishBox(op)
end

-- Frame whose look vector runs from -> to: back = -along, up is "world up" made
-- perpendicular to along, right = up x back (so right x up = back, like a Roblox CFrame).
local function frameAlong(
	from: Vec,
	to: Vec
): (number, number, number, number, number, number, number, number, number, number)
	local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	assert(length > 1e-6, "TerrainModel: zero-length segment")
	local ax, ay, az = dx / length, dy / length, dz / length
	assert(math.abs(ay) < 0.98, "TerrainModel: segment too close to vertical")
	local ux, uy, uz = norm(-ax * ay, 1 - ay * ay, -az * ay)
	local bx, by, bz = -ax, -ay, -az
	local rx, ry, rz = cross(ux, uy, uz, bx, by, bz)
	return rx, ry, rz, ux, uy, uz, bx, by, bz, length
end

-- A box whose TOP face runs along the line from -> to (lowered by `sink`), `width` wide and
-- `thickness` deep, overrunning both ends by `extend`.
function TerrainModel.slabOp(
	name: string,
	mode: string,
	material: string,
	from: Vec,
	to: Vec,
	width: number,
	thickness: number,
	extend: number?,
	sink: number?
): Op
	local rx, ry, rz, ux, uy, uz, bx, by, bz, length = frameAlong(from, to)
	local op = blank(name, "Box", mode, material)
	op.rx, op.ry, op.rz, op.ux, op.uy, op.uz, op.bx, op.by, op.bz = rx, ry, rz, ux, uy, uz, bx, by, bz
	local down = thickness / 2 + (sink or 0)
	op.cx = (from.X + to.X) / 2 - ux * down
	op.cy = (from.Y + to.Y) / 2 - uy * down
	op.cz = (from.Z + to.Z) / 2 - uz * down
	op.sx, op.sy, op.sz = width, thickness, length + 2 * (extend or TerrainModel.EXTEND)
	return finishBox(op)
end

-- A square prism rolled 45 degrees about from -> to, so its top EDGE runs along the line
-- (lowered by `drop`): a knife-edge ridge crest with 45-degree flanks.
function TerrainModel.crestOp(name: string, material: string, from: Vec, to: Vec, size: number, drop: number): Op
	local rx, ry, rz, ux, uy, uz, bx, by, bz, length = frameAlong(from, to)
	local op = blank(name, "Box", "Fill", material)
	-- Rotate right/up by 45 degrees about the back axis.
	op.rx, op.ry, op.rz = (rx - ux) * SQRT_HALF, (ry - uy) * SQRT_HALF, (rz - uz) * SQRT_HALF
	op.ux, op.uy, op.uz = (rx + ux) * SQRT_HALF, (ry + uy) * SQRT_HALF, (rz + uz) * SQRT_HALF
	op.bx, op.by, op.bz = bx, by, bz
	local down = size * SQRT_HALF + drop
	op.cx = (from.X + to.X) / 2 - ux * down
	op.cy = (from.Y + to.Y) / 2 - uy * down
	op.cz = (from.Z + to.Z) / 2 - uz * down
	op.sx, op.sy, op.sz = size, size, length + 2 * TerrainModel.EXTEND
	return finishBox(op)
end

function TerrainModel.ballOp(name: string, mode: string, material: string, center: Vec, radius: number): Op
	local op = blank(name, "Ball", mode, material)
	op.cx, op.cy, op.cz = center.X, center.Y, center.Z
	op.radius = radius
	op.minX, op.maxX, op.minZ, op.maxZ = center.X - radius, center.X + radius, center.Z - radius, center.Z + radius
	op.voxels = 4 / 3 * math.pi * radius ^ 3 / 64
	return op
end

-- Vertical cylinder from y0 (bottom) to y1 (top).
function TerrainModel.cylinderOp(
	name: string,
	mode: string,
	material: string,
	x: number,
	z: number,
	radius: number,
	y0: number,
	y1: number
): Op
	local op = blank(name, "Cylinder", mode, material)
	op.cx, op.cy, op.cz = x, (y0 + y1) / 2, z
	op.radius, op.height = radius, y1 - y0
	op.minX, op.maxX, op.minZ, op.maxZ = x - radius, x + radius, z - radius, z + radius
	op.voxels = math.pi * radius * radius * (y1 - y0) / 64
	return op
end

function TerrainModel.replaceOp(
	name: string,
	source: string,
	target: string,
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number
): Op
	local op = TerrainModel.aabbOp(name, "Replace", target, x0, y0, z0, x1, y1, z1)
	op.source = source
	return op
end

-- Vertical extent [lo, hi] of an op's solid along the vertical line at (x, z), or nil.
local function interval(op: Op, x: number, z: number): (number?, number?)
	local dx, dz = x - op.cx, z - op.cz
	if op.shape == "Ball" then
		local r2 = op.radius * op.radius - dx * dx - dz * dz
		if r2 < 0 then
			return nil, nil
		end
		local s = math.sqrt(r2)
		return op.cy - s, op.cy + s
	elseif op.shape == "Cylinder" then
		if dx * dx + dz * dz > op.radius * op.radius then
			return nil, nil
		end
		return op.cy - op.height / 2, op.cy + op.height / 2
	end
	local lo, hi = -math.huge, math.huge
	for axis = 1, 3 do
		local ax, ay, az, half
		if axis == 1 then
			ax, ay, az, half = op.rx, op.ry, op.rz, op.sx / 2
		elseif axis == 2 then
			ax, ay, az, half = op.ux, op.uy, op.uz, op.sy / 2
		else
			ax, ay, az, half = op.bx, op.by, op.bz, op.sz / 2
		end
		local b = dx * ax + dz * az -- coordinate along this axis is b + ay * (y - cy)
		if math.abs(ay) < 1e-9 then
			if math.abs(b) > half then
				return nil, nil
			end
		else
			local t1 = op.cy + (-half - b) / ay
			local t2 = op.cy + (half - b) / ay
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			lo = math.max(lo, t1)
			hi = math.min(hi, t2)
		end
	end
	if lo > hi then
		return nil, nil
	end
	return lo, hi
end
TerrainModel.interval = interval

local function cellKey(ix: number, iz: number): number
	return (ix + 4096) * 8192 + (iz + 4096)
end

function TerrainModel.new(ops: { Op }): Model
	local cell = TerrainModel.CELL
	local buckets: { [number]: { number } } = {}
	for i, op in ops do
		for ix = math.floor(op.minX / cell), math.floor(op.maxX / cell) do
			for iz = math.floor(op.minZ / cell), math.floor(op.maxZ / cell) do
				local key = cellKey(ix, iz)
				local list = buckets[key]
				if not list then
					list = {}
					buckets[key] = list
				end
				table.insert(list, i) -- ops are visited in order, so lists stay sorted
			end
		end
	end

	local function heightAt(x: number, z: number): (number, string, string)
		local h, mat, by = -math.huge, "Air", ""
		local list = buckets[cellKey(math.floor(x / cell), math.floor(z / cell))]
		if not list then
			return h, mat, by
		end
		for _, i in list do
			local op = ops[i]
			if x >= op.minX and x <= op.maxX and z >= op.minZ and z <= op.maxZ then
				local lo, hi = interval(op, x, z)
				if lo and hi then
					if op.mode == "Fill" then
						if hi >= h - EPS then
							h = math.max(h, hi)
							mat, by = op.material, op.name
						end
					elseif op.mode == "Carve" then
						if h >= lo and h <= hi + EPS then
							h = lo
							mat, by = op.material, op.name
						end
					elseif op.mode == "Replace" then
						if mat == op.source and h >= lo - EPS and h <= hi + EPS then
							mat = op.material
						end
					end
				end
			end
		end
		return h, mat, by
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

	return {
		ops = ops,
		heightAt = heightAt,
		normalAt = normalAt,
		slopeAt = slopeAt,
		classify = function(x: number, z: number): string
			return TerrainModel.classifySlope(slopeAt(x, z))
		end,
	}
end

function TerrainModel.classifySlope(degrees: number): string
	if degrees <= TerrainModel.FLAT_ANGLE then
		return "Flat"
	elseif degrees <= TerrainModel.STEEP_ANGLE then
		return "Walkable"
	end
	return "Steep"
end

-- Building the op list from WorldLayout ------------------------------------------------------

local function bottomOf(def: any): number
	return if typeof(def.bottom) == "number" then def.bottom else TerrainModel.DEFAULT_BOTTOM
end

-- Glacier body + Snow top along from -> to. Thickness reaches `bottom` under the HIGH end, so
-- the underside never shows a gap.
local function addRouteSlab(ops: { Op }, def: any)
	local from, to = def.from, def.to
	local thickness = def.thickness
	if typeof(thickness) ~= "number" then
		local _, _, _, _, uy = frameAlong(from, to)
		thickness = (math.max(from.Y, to.Y) - bottomOf(def)) / uy
	end
	local snow = TerrainModel.SNOW_DEPTH
	table.insert(ops, TerrainModel.slabOp(def.name, "Fill", "Glacier", from, to, def.width, thickness))
	table.insert(ops, TerrainModel.slabOp(def.name .. "Snow", "Fill", def.top or "Snow", from, to, def.width, snow))
end

local function addMountain(ops: { Op }, def: any, index: number)
	local name = def.name or ("Mountain" .. index)
	local r = def.r
	local cy = def.top - r
	table.insert(ops, TerrainModel.ballOp(name, "Fill", def.material or "Glacier", { X = def.x, Y = cy, Z = def.z }, r))
	-- Cap: above the circle where the flank reaches CAP_ANGLE the dome is gentle -> Snow.
	local a = math.rad(TerrainModel.CAP_ANGLE)
	local capY = cy + r * math.cos(a)
	local half = r * math.sin(a) + 4
	table.insert(
		ops,
		TerrainModel.replaceOp(
			name .. "Cap",
			"Glacier",
			"Snow",
			def.x - half,
			capY,
			def.z - half,
			def.x + half,
			def.top + 8,
			def.z + half
		)
	)
end

-- Returns the ordered op list for a layout. Order: ground, mountains, ridge crests, route
-- slabs, pads, shelves, crevasses (carve + escape ramps), rock outcrops.
function TerrainModel.ops(layout: any): { Op }
	local ops: { Op } = {}

	local g = layout.Ground
	if g then
		local tile = g.tile or 800
		local x = g.x0
		while x < g.x1 do
			local z = g.z0
			while z < g.z1 do
				table.insert(
					ops,
					TerrainModel.aabbOp(
						"Ground",
						"Fill",
						"Snow",
						x,
						g.top - g.thickness,
						z,
						math.min(x + tile, g.x1),
						g.top,
						math.min(z + tile, g.z1)
					)
				)
				z += tile
			end
			x += tile
		end
	end

	for i, def in layout.Mountains or {} do
		addMountain(ops, def, i)
	end

	for i, def in layout.Crests or {} do
		table.insert(
			ops,
			TerrainModel.crestOp(def.name or ("Crest" .. i), "Glacier", def.from, def.to, def.size, def.drop)
		)
	end

	for _, def in layout.Slabs or {} do
		addRouteSlab(ops, def)
	end

	-- Pads: round landings. `sink` lowers the top below `at` so a bend filler never makes a
	-- step where a sloping slab meets its rim.
	for _, def in layout.Pads or {} do
		local at = def.at
		local y0 = bottomOf(def)
		local top = at.Y - (def.sink or 0)
		table.insert(ops, TerrainModel.cylinderOp(def.name, "Fill", "Glacier", at.X, at.Z, def.radius, y0, top))
		table.insert(
			ops,
			TerrainModel.cylinderOp(
				def.name .. "Snow",
				"Fill",
				"Snow",
				at.X,
				at.Z,
				def.radius,
				top - TerrainModel.SNOW_DEPTH,
				top
			)
		)
	end

	for _, def in layout.Shelves or {} do
		local mn, mx = def.min, def.max
		-- min.Y is the bottom of the Glacier body, max.Y its (snow-topped) surface.
		table.insert(ops, TerrainModel.aabbOp(def.name, "Fill", "Glacier", mn.X, mn.Y, mn.Z, mx.X, mx.Y, mx.Z))
		table.insert(
			ops,
			TerrainModel.aabbOp(
				def.name .. "Snow",
				"Fill",
				def.top or "Snow",
				mn.X,
				mx.Y - TerrainModel.SNOW_DEPTH,
				mn.Z,
				mx.X,
				mx.Y,
				mx.Z
			)
		)
	end

	-- Crevasses are cut relative to the surface built so far.
	local crevasses = layout.Crevasses or {}
	if #crevasses > 0 then
		local before = TerrainModel.new(table.clone(ops))
		for _, def in crevasses do
			local c = def.at
			local top = before.heightAt(c.X, c.Z)
			local dx, dz = def.dir.X, def.dir.Z
			local m = math.sqrt(dx * dx + dz * dz)
			dx, dz = dx / m, dz / m
			local half = def.length / 2
			local from = { X = c.X - dx * half, Y = top + 30, Z = c.Z - dz * half }
			local to = { X = c.X + dx * half, Y = top + 30, Z = c.Z + dz * half }
			table.insert(ops, TerrainModel.slabOp(def.name, "Carve", "Glacier", from, to, def.width, def.depth + 30, 0))
			local ramp = def.ramp
			if ramp then
				-- Escape ramp hugging one wall: from the floor at `ramp.low` up to the lip at
				-- `ramp.high` (both are distances along the crevasse from its centre).
				local side = ramp.side or -1
				local off = side * (def.width / 2 - ramp.width / 2)
				local px, pz = -dz * off, dx * off -- perpendicular offset towards that wall
				local lx, lz = c.X + dx * ramp.low + px, c.Z + dz * ramp.low + pz
				local hx, hz = c.X + dx * ramp.high + px, c.Z + dz * ramp.high + pz
				local lip = before.heightAt(hx, hz) -- the surface the ramp climbs back up to
				if lip == -math.huge then
					lip = top
				end
				addRouteSlab(ops, {
					name = def.name .. "Ramp",
					from = { X = lx, Y = top - def.depth, Z = lz },
					to = { X = hx, Y = lip, Z = hz },
					width = ramp.width,
					bottom = top - def.depth - 4,
				})
			end
		end
	end

	for i, def in layout.Outcrops or {} do
		table.insert(
			ops,
			TerrainModel.ballOp(
				def.name or ("Outcrop" .. i),
				"Fill",
				def.material or "Rock",
				{ X = def.x, Y = def.top - def.r, Z = def.z },
				def.r
			)
		)
	end

	return ops
end

-- Total and largest fill sizes, in 4-stud voxels.
function TerrainModel.budget(ops: { Op }): (number, number, string)
	local total, largest, largestName = 0, 0, ""
	for _, op in ops do
		total += op.voxels
		if op.voxels > largest then
			largest, largestName = op.voxels, op.name
		end
	end
	return total, largest, largestName
end

-- Routes -------------------------------------------------------------------------------------

local function toPoints(list: { any }): { RoutePoint }
	local out = {}
	for _, p in list do
		table.insert(out, { x = p.at.X, y = p.at.Y, z = p.at.Z, id = p.id, via = p.via })
	end
	return out
end

-- Every route as segments: the main route, then each alternate. A segment's `via` comes from
-- its END point ("Bridge": a rope bridge spans it, "Ladder": a ladder climbs it).
function TerrainModel.segments(layout: any): { Segment }
	local out: { Segment } = {}
	local function add(name: string, points: { RoutePoint })
		for i = 2, #points do
			local a, b = points[i - 1], points[i]
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
			})
		end
	end
	add("Main", toPoints(layout.Route or {}))
	for _, alt in layout.Alternates or {} do
		add(alt.name, toPoints(alt.points))
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
