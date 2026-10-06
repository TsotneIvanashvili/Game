-- Terrain / world layout tests: TerrainModel (pure) evaluated against WorldLayout v2.
-- Run with: tests/run.sh

local H = __loadfile(ROOT .. "/tests/harness.luau")(ROOT)
local test, eq, near, truthy = H.test, H.eq, H.near, H.truthy
local Shared = H.Shared

local TerrainModel = H.require(Shared.Logic.TerrainModel)
local WorldLayout = H.require(Shared.Config.WorldLayout)
local GameConfig = H.require(Shared.Config.GameConfig)

local ops = TerrainModel.ops(WorldLayout)
local model = TerrainModel.new(ops)
local segments = TerrainModel.segments(WorldLayout)
local JUMP = GameConfig.JUMP_HEIGHT
local NO_GROUND = -math.huge

local function fmt(x: number, z: number): string
	return string.format("(%.0f, %.0f)", x, z)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Model basics ------------------------------------------------------------------------------

test("terrain: box ops have orthonormal right-handed axes and positive sizes", function()
	for _, op in ops do
		if op.shape == "Box" then
			local function dot(ax, ay, az, bx, by, bz)
				return ax * bx + ay * by + az * bz
			end
			near(dot(op.rx, op.ry, op.rz, op.rx, op.ry, op.rz), 1, 1e-6, op.name .. " right")
			near(dot(op.ux, op.uy, op.uz, op.ux, op.uy, op.uz), 1, 1e-6, op.name .. " up")
			near(dot(op.bx, op.by, op.bz, op.bx, op.by, op.bz), 1, 1e-6, op.name .. " back")
			near(dot(op.rx, op.ry, op.rz, op.ux, op.uy, op.uz), 0, 1e-6, op.name .. " right.up")
			near(dot(op.ux, op.uy, op.uz, op.bx, op.by, op.bz), 0, 1e-6, op.name .. " up.back")
			-- right x up must equal back (a proper rotation, as CFrame.fromMatrix expects)
			local cx = op.ry * op.uz - op.rz * op.uy
			local cy = op.rz * op.ux - op.rx * op.uz
			local cz = op.rx * op.uy - op.ry * op.ux
			near(dot(cx, cy, cz, op.bx, op.by, op.bz), 1, 1e-6, op.name .. " handedness")
			truthy(op.sx > 0 and op.sy > 0 and op.sz > 0, op.name .. " size")
		end
	end
end)

test("terrain: fill budget (total at most 20M voxels, no single op over 2M)", function()
	local total, largest, name = TerrainModel.budget(ops)
	truthy(largest <= 2e6, string.format("%s fills %.2fM voxels", name, largest / 1e6))
	truthy(total <= 20e6, string.format("total %.1fM voxels", total / 1e6))
end)

test("terrain: the Base Camp area is filled first and later fills never change it", function()
	local seenLate = false
	local early = {}
	for _, op in ops do
		if op.phase == 1 then
			eq(seenLate, false, op.name .. " is phase 1 after a phase 2 op")
			table.insert(early, op)
		else
			eq(op.phase, 2)
			seenLate = true
		end
	end
	truthy(#early > 0 and seenLate, "both phases exist")
	local firstModel = TerrainModel.new(early)
	local base = WorldLayout.Camps[1]
	local fx, fz = base.footprint.X + 80, base.footprint.Z + 80
	for i = 0, 10 do
		for j = 0, 10 do
			local x = base.center.X - fx / 2 + fx * i / 10
			local z = base.center.Z - fz / 2 + fz * j / 10
			local h1, m1 = firstModel.heightAt(x, z)
			local h2, m2 = model.heightAt(x, z)
			near(h1, h2, 1e-6, "base camp ground changes after phase 1 at " .. fmt(x, z))
			eq(m1, m2)
		end
	end
end)

test("terrain: only snow, glacier and a little rock (no grass, mud or water)", function()
	local allowed = { Snow = true, Glacier = true, Rock = true }
	local rock = 0
	for _, op in ops do
		truthy(allowed[op.material], op.name .. " uses " .. op.material)
		if op.material == "Rock" then
			rock += 1
			truthy(op.cy + op.radius >= 700, op.name .. ": rock only near the summit")
		end
	end
	truthy(rock >= 1 and rock <= 8, "a few rock outcrops, got " .. rock)
end)

-- True if (x, y, z) is underground or inside some mountain ball (other than `skip`).
-- True if (x, y, z) is underground or inside any fill other than `skip`.
local function solidAt(x: number, y: number, z: number, skip: TerrainModel.Op?): boolean
	if y <= WorldLayout.Ground.top then
		return true
	end
	for _, op in ops do
		if op ~= skip and op.mode == "Fill" then
			local lo, hi = TerrainModel.interval(op, x, z)
			if lo and hi and y >= lo - 0.5 and y <= hi + 0.5 then
				return true
			end
		end
	end
	return false
end

test("terrain: no floating mountains or outcrops", function()
	for i, m in WorldLayout.Mountains do
		truthy(m.top - 2 * m.r <= WorldLayout.Ground.top, string.format("dome %d %s floats", i, fmt(m.x, m.z)))
	end
	for _, op in ops do
		if string.sub(op.name, 1, 7) == "Outcrop" then
			truthy(solidAt(op.cx, op.cy - op.radius + 1, op.cz, op), op.name .. " floats")
		end
	end
end)

test("terrain: ridge crest undersides rest on their keels (no visible overhangs)", function()
	local exposed, total = 0, 0
	for _, op in ops do
		if string.match(op.name, "^Crest%u$") then
			local inset = 1 - 1 / op.sx -- a hair inside the corner
			for k = 0, 20 do
				local t = (k / 20 - 0.5) * op.sz
				-- The two side corners and the bottom corner of the rolled square section.
				for _, c in { { 1, 1 }, { 1, -1 }, { -1, -1 } } do
					local a, b = c[1] * op.sx / 2 * inset, c[2] * op.sy / 2 * inset
					local x = op.cx + op.rx * a + op.ux * b + op.bx * t
					local y = op.cy + op.ry * a + op.uy * b + op.by * t
					local z = op.cz + op.rz * a + op.uz * b + op.bz * t
					total += 1
					if not solidAt(x, y, z, op) then
						exposed += 1
					end
				end
			end
		end
	end
	truthy(total > 0, "crests exist")
	truthy(exposed / total <= 0.02, string.format("%d of %d crest corners hang in the air", exposed, total))
end)

test("terrain: analytic intervals for a ball, a box and a cylinder", function()
	local ball = TerrainModel.ballOp("b", "Fill", "Snow", { X = 0, Y = 10, Z = 0 }, 5)
	local lo, hi = TerrainModel.interval(ball, 3, 0)
	near(lo :: number, 6, 1e-9)
	near(hi :: number, 14, 1e-9)
	eq(TerrainModel.interval(ball, 6, 0), nil)
	local slab = TerrainModel.slabOp("s", "Fill", "Snow", { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 10, Z = 100 }, 20, 8, 0)
	local _, top = TerrainModel.interval(slab, 0, 50)
	near(top :: number, 5, 1e-6, "slab top follows from -> to")
	local _, edge = TerrainModel.interval(slab, 9.9, 50)
	near(edge :: number, 5, 1e-6, "no roll: flat across the width")
	eq(TerrainModel.interval(slab, 10.1, 50), nil)
	local cyl = TerrainModel.cylinderOp("c", "Fill", "Snow", 0, 0, 4, -2, 6)
	local clo, chi = TerrainModel.interval(cyl, 3, 0)
	near(clo :: number, -2, 1e-9)
	near(chi :: number, 6, 1e-9)
end)

test("terrain: carve and replace rules", function()
	local m = TerrainModel.new({
		TerrainModel.aabbOp("ground", "Fill", "Glacier", -50, -20, -50, 50, 10, 50),
		TerrainModel.aabbOp("snow", "Fill", "Snow", -50, 4, -50, 50, 10, 50),
		TerrainModel.aabbOp("cut", "Carve", "Glacier", -5, -10, -50, 5, 40, 50),
		TerrainModel.replaceOp("paint", "Snow", "Glacier", 20, 0, -50, 50, 20, 50),
	})
	local h, mat = m.heightAt(0, 0)
	near(h, -10, 1e-9, "carved floor")
	eq(mat, "Glacier")
	h, mat = m.heightAt(-20, 0)
	near(h, 10, 1e-9)
	eq(mat, "Snow", "later fill with the same top wins")
	h, mat = m.heightAt(30, 0)
	eq(mat, "Glacier", "replace repaints the surface")
	eq(m.heightAt(80, 0), NO_GROUND)
end)

test("terrain: slope classification", function()
	eq(TerrainModel.classifySlope(0), "Flat")
	eq(TerrainModel.classifySlope(20), "Walkable")
	eq(TerrainModel.classifySlope(40), "Walkable")
	eq(TerrainModel.classifySlope(41), "Steep")
	-- A flat bench, a headwall ramp, and the riser between two benches.
	eq(model.classify(0, 1000), "Flat")
	eq(model.classify(250, 1030), "Walkable")
	eq(model.classify(0, 1080), "Steep")
	-- A mountain flank 60 degrees down from its apex is steep Glacier; its apex is Snow.
	local m = WorldLayout.Mountains[#WorldLayout.Mountains] -- the far north peak, isolated
	local a = math.rad(60)
	local fx, fz = m.x, m.z + m.r * math.sin(a)
	local _, flankMat = model.heightAt(fx, fz - 1)
	eq(model.classify(fx, fz - 1), "Steep", "mountain flank " .. fmt(fx, fz))
	eq(flankMat, "Glacier")
	local apex, apexMat = model.heightAt(m.x, m.z)
	near(apex, m.top, 0.01)
	eq(apexMat, "Snow")
	eq(model.classify(m.x, m.z), "Flat")
end)

test("terrain: the world bounds are fully covered (no void anywhere you can stand)", function()
	local b = WorldLayout.Bounds
	for x = b.x0, b.x1, 50 do
		for z = b.z0, b.z1, 50 do
			local h = model.heightAt(x, z)
			truthy(h >= 0 and h > WorldLayout.SafetyNetY, "no ground at " .. fmt(x, z))
		end
	end
	-- And the Part skirt reaches far past the terrain, so long sightlines end on snow.
	local g, sk = WorldLayout.Ground, WorldLayout.Skirt
	truthy(g.x0 <= b.x0 and g.x1 >= b.x1 and g.z0 <= b.z0 and g.z1 >= b.z1, "terrain ground covers the bounds")
	truthy(sk.x0 <= b.x0 - 1400 and sk.x1 >= b.x1 + 1400, "skirt too narrow in X")
	truthy(sk.z0 <= b.z0 - 1400 and sk.z1 >= b.z1 + 1400, "skirt too short in Z")
	truthy(sk.top <= g.top and sk.top > g.top - g.thickness, "skirt sits just under the terrain ground top")
	truthy(WorldLayout.SafetyFloorY < WorldLayout.SafetyNetY, "safety floor sits below the safety net")
	truthy(g.top - g.thickness > WorldLayout.SafetyFloorY, "safety floor is under the terrain")
end)

test("terrain: Base Camp is enclosed by high mountains on every side but the trail", function()
	local base = WorldLayout.Camps[1].center
	for i = 1, 7 do -- direction 0 (north) is the trail up the valley
		local a = i * math.pi / 4
		local dx, dz = math.sin(a), math.cos(a)
		local highest = 0
		for d = 150, 1600, 10 do
			local x, z = base.X + dx * d, base.Z + dz * d
			highest = math.max(highest, (model.heightAt(x, z)), TerrainModel.sceneryHeight(WorldLayout, x, z))
		end
		truthy(highest >= 200, string.format("direction %d only reaches %.0f", i, highest))
	end
end)

test("terrain: backdrop peaks are Parts far from the trail, sized within Part limits", function()
	truthy(#WorldLayout.Scenery >= 12, "backdrop peaks")
	for _, p in WorldLayout.Scenery do
		local side = TerrainModel.peakSide(p.top)
		truthy(side <= 2048, "peak too big for one Part " .. fmt(p.x, p.z))
		-- Ground cuts the cube above its upper corners, so no face overhangs.
		truthy(p.top <= side / math.sqrt(3), "peak overhangs " .. fmt(p.x, p.z))
		truthy(TerrainModel.distanceToRoute(segments, p.x, p.z) >= 600, "peak apex near the trail " .. fmt(p.x, p.z))
		near(TerrainModel.sceneryHeight(WorldLayout, p.x, p.z), p.top, 1e-6)
		-- Axes are orthonormal, right-handed, and sum to straight up.
		local a = TerrainModel.peakAxes(p.yaw)
		local sx, sy, sz = 0, 0, 0
		for _, v in a do
			near(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2, 1, 1e-9)
			sx += v[1]
			sy += v[2]
			sz += v[3]
		end
		near(sx, 0, 1e-9)
		near(sz, 0, 1e-9)
		near(sy, math.sqrt(3), 1e-9)
		local c1 = a[1][2] * a[2][3] - a[1][3] * a[2][2]
		local c2 = a[1][3] * a[2][1] - a[1][1] * a[2][3]
		local c3 = a[1][1] * a[2][2] - a[1][2] * a[2][1]
		near(c1 * a[3][1] + c2 * a[3][2] + c3 * a[3][3], 1, 1e-9, "right-handed")
	end
	-- Their footprints stay well clear of every walked segment.
	for _, s in segments do
		local n = math.max(1, math.floor(TerrainModel.segmentLength(s) / 40))
		for k = 0, n do
			local x, z = lerp(s.ax, s.bx, k / n), lerp(s.az, s.bz, k / n)
			for a = 0, 330, 30 do
				local px, pz = x + math.sin(math.rad(a)) * 300, z + math.cos(math.rad(a)) * 300
				eq(TerrainModel.sceneryHeight(WorldLayout, px, pz), -math.huge, "peak within 300 of " .. fmt(x, z))
			end
		end
	end
end)

-- Camps ---------------------------------------------------------------------------------------

test("terrain: camps sit on the surface at the planned heights", function()
	local expected = { BaseCamp = 0, Camp1 = 200, Camp2 = 450 }
	eq(#WorldLayout.Camps, 3)
	for i, camp in WorldLayout.Camps do
		eq(camp.index, i, camp.id .. " index")
		truthy(camp.size == "Base" or camp.size == "Small", camp.id .. " size")
		truthy(type(camp.supplyTable) == "string" and camp.supplyTable ~= "", camp.id .. " supplyTable")
		near(camp.center.Y, expected[camp.id], 10, camp.id .. " planned height")
		local h, mat = model.heightAt(camp.center.X, camp.center.Z)
		near(h, camp.center.Y, 0.5, camp.id .. " centre on the surface")
		eq(mat, "Snow", camp.id)
		local sh = model.heightAt(camp.spawn.X, camp.spawn.Z)
		near(sh, camp.spawn.Y, 0.5, camp.id .. " spawn on the surface")
	end
end)

test("terrain: camp footprints are flat and big enough for their kit", function()
	for _, camp in WorldLayout.Camps do
		local fx, fz = camp.footprint.X, camp.footprint.Z
		if camp.size == "Base" then
			truthy(fx >= 180 and fz >= 140, "base camp footprint")
		else
			truthy(fx >= 70 and fz >= 60, camp.id .. " footprint")
		end
		for i = 0, 8 do
			for j = 0, 8 do
				local x = camp.center.X - fx / 2 + fx * i / 8
				local z = camp.center.Z - fz / 2 + fz * j / 8
				local h = model.heightAt(x, z)
				near(h, camp.center.Y, 0.5, camp.id .. " not flat at " .. fmt(x, z))
				eq(model.classify(x, z), "Flat", camp.id .. " slope at " .. fmt(x, z))
			end
		end
	end
end)

-- Route ---------------------------------------------------------------------------------------

test("terrain: route visits Base Camp, Camp 1, Camp 2 and the summit in order, climbing", function()
	local order = {}
	for _, p in WorldLayout.Route do
		if p.id == "BaseCamp" or p.id == "Camp1" or p.id == "Camp2" or p.id == "Summit" then
			table.insert(order, p.id)
		end
	end
	eq(table.concat(order, ","), "BaseCamp,Camp1,Camp2,Summit")
	local first, last = WorldLayout.Route[1].at, WorldLayout.Route[#WorldLayout.Route].at
	near(first.Y, 0, 1)
	near(last.Y, 800, 10)
	for i, camp in WorldLayout.Camps do
		local p = TerrainModel.point(WorldLayout, camp.id)
		truthy(p, camp.id .. " is on the route")
		near((p :: any).x, camp.center.X, 0.01)
		near((p :: any).z, camp.center.Z, 0.01)
		eq(i, camp.index)
	end
end)

test("terrain: route is long enough for a 15-25 minute climb", function()
	local walk, ladder = 0, 0
	for _, s in segments do
		if s.route == "Main" then
			if s.via == "Ladder" then
				ladder += math.abs(s.by - s.ay)
			else
				walk += TerrainModel.segmentLength(s)
			end
		end
	end
	-- ~12 studs/s average walking, 6 studs/s climbing, plus camp stops.
	local minutes = (walk / 12 + ladder / 6) / 60
	truthy(walk >= 7000 and walk <= 12000, string.format("main route %.0f studs", walk))
	truthy(minutes >= 10 and minutes <= 17, string.format("%.1f minutes of pure movement", minutes))
end)

test("terrain: every walked segment follows the surface with no step above jump height", function()
	for i, s in segments do
		if s.via == "Walk" then
			local length = TerrainModel.segmentLength(s)
			local dx, dz = s.bx - s.ax, s.bz - s.az
			local flat = math.sqrt(dx * dx + dz * dz)
			local px, pz = dz / flat, -dx / flat
			local n = math.max(1, math.floor(length))
			local prev = nil
			for k = 0, n do
				local t = k / n
				local x, z = s.ax + dx * t, s.az + dz * t
				local expected = lerp(s.ay, s.by, t)
				local h, mat, by = model.heightAt(x, z)
				local where = string.format("segment %d (%s) at %s, by %s", i, s.route, fmt(x, z), by)
				truthy(math.abs(h - expected) <= 1.5, where .. string.format(": %.1f vs %.1f", h, expected))
				eq(mat, "Snow", where)
				if prev then
					truthy(math.abs(h - prev) <= JUMP, where .. ": step")
				end
				prev = h
				-- The walkway is at least 16 studs wide away from its ends.
				if t * length > 12 and (1 - t) * length > 12 then
					for _, off in { 8, -8 } do
						local lh = model.heightAt(x + px * off, z + pz * off)
						truthy(math.abs(lh - expected) <= 3, where .. " too narrow")
					end
				end
			end
			-- Average grade stays walkable.
			local grade = math.deg(math.atan(math.abs(s.by - s.ay) / math.max(flat, 1e-6)))
			truthy(grade <= TerrainModel.STEEP_ANGLE, string.format("segment %d grade %.1f", i, grade))
		end
	end
end)

test("terrain: every walked segment (main and walk-rounds) is 35 degrees or gentler", function()
	-- Humanoid.MaxSlopeAngle is 42: anything steeper must be a ladder or a bridge.
	local worst, at = 0, ""
	for i, s in segments do
		if s.via == "Walk" then
			local n = math.max(1, math.floor(TerrainModel.segmentLength(s) / 2))
			for k = 0, n do
				local x, z = lerp(s.ax, s.bx, k / n), lerp(s.az, s.bz, k / n)
				local slope = model.slopeAt(x, z)
				if slope > worst then
					worst, at = slope, string.format("segment %d (%s) at %s", i, s.route, fmt(x, z))
				end
			end
		end
	end
	truthy(worst <= 35, string.format("%.1f degrees at %s", worst, at))
end)

test("terrain: route segments are only walked, bridged or laddered", function()
	local bridges, ladders = 0, 0
	for _, s in segments do
		truthy(s.via == "Walk" or s.via == "Bridge" or s.via == "Ladder", s.via)
		if s.via == "Bridge" then
			bridges += 1
		elseif s.via == "Ladder" then
			ladders += 1
		end
	end
	truthy(bridges >= 5, "rope bridges: " .. bridges)
	truthy(ladders >= 2, "ladders: " .. ladders)
end)

test("terrain: bridges span real gaps between anchors on the surface", function()
	for _, s in segments do
		if s.via == "Bridge" then
			local ha, hb = model.heightAt(s.ax, s.az), model.heightAt(s.bx, s.bz)
			near(ha, s.ay, 1, "bridge start anchor " .. fmt(s.ax, s.az))
			near(hb, s.by, 1, "bridge end anchor " .. fmt(s.bx, s.bz))
			local span = TerrainModel.segmentLength(s)
			truthy(span >= 16 and span <= 60, string.format("span %.0f", span))
			local deepest = math.huge
			for k = 1, 19 do
				local t = k / 20
				deepest = math.min(deepest, (model.heightAt(lerp(s.ax, s.bx, t), lerp(s.az, s.bz, t))))
			end
			truthy(deepest < math.min(ha, hb) - 15, "no gap under bridge at " .. fmt(s.ax, s.az))
			-- Wider than a sprint jump (~11 studs), so the bridge is the way across.
			local gap = 0
			for k = 0, 100 do
				local t = k / 100
				if model.heightAt(lerp(s.ax, s.bx, t), lerp(s.az, s.bz, t)) < math.min(ha, hb) - 6 then
					gap += span / 100
				end
			end
			truthy(gap >= 14, string.format("gap only %.1f studs", gap))
		end
	end
end)

test("terrain: ladders climb a real wall from surface to surface", function()
	for _, s in segments do
		if s.via == "Ladder" then
			near(model.heightAt(s.ax, s.az), s.ay, 1, "ladder foot " .. fmt(s.ax, s.az))
			near(model.heightAt(s.bx, s.bz), s.by, 1, "ladder top " .. fmt(s.bx, s.bz))
			local rise = s.by - s.ay
			truthy(rise > JUMP * 2, "ladder rise " .. rise)
			local dx, dz = s.bx - s.ax, s.bz - s.az
			local flat = math.sqrt(dx * dx + dz * dz)
			truthy(flat >= 3 and flat <= 14, "ladder top is just past the lip")
			-- Walking from foot to top meets a vertical face (the wall) within a few studs.
			local face = nil
			for d = 0, flat, 0.25 do
				local h = model.heightAt(s.ax + dx / flat * d, s.az + dz / flat * d)
				if h > s.ay + rise * 0.9 then
					face = d
					break
				end
			end
			truthy(face and face <= 5, "wall face near the ladder foot")
			eq(model.classify(s.ax + dx / flat * (face :: number), s.az + dz / flat * (face :: number)), "Steep")
		end
	end
end)

test("terrain: the ice wall has a longer walk-round that is also continuous", function()
	local bypass = nil
	for _, alt in WorldLayout.Alternates do
		if alt.name == "IceWallBypass" then
			bypass = alt
		end
	end
	truthy(bypass, "IceWallBypass alternate")
	local length = 0
	for _, s in segments do
		if s.route == "IceWallBypass" then
			eq(s.via, "Walk")
			length += TerrainModel.segmentLength(s)
		end
	end
	local foot = assert(TerrainModel.point(WorldLayout, "K4N"))
	local top = assert(TerrainModel.point(WorldLayout, "ShelfEast"))
	local first, last = bypass.points[1].at, bypass.points[#bypass.points].at
	near(first.X, foot.x, 0.01)
	near(first.Z, foot.z, 0.01)
	near(last.X, top.x, 0.01)
	near(last.Z, top.z, 0.01)
	truthy(length > 600, "walk-round is the long way: " .. length)
end)

test("terrain: markers every ~40 studs, all on the surface beside the trail", function()
	local markers = TerrainModel.markers(WorldLayout, model, WorldLayout.MarkerSpacing, WorldLayout.MarkerOffset)
	truthy(#markers >= 180, "markers: " .. #markers)
	for _, m in markers do
		local h = model.heightAt(m.x, m.z)
		near(m.y, h, 1e-6, "marker on the surface " .. fmt(m.x, m.z))
		truthy(model.slopeAt(m.x, m.z) < 35, "marker on a steep slope " .. fmt(m.x, m.z))
		local d = TerrainModel.distanceToRoute(segments, m.x, m.z)
		truthy(d >= WorldLayout.MarkerOffset - 1 and d <= WorldLayout.MarkerOffset + 0.5, "marker offset " .. d)
	end
	-- Coverage: walked main-route length per marker stays near the spacing.
	local walked = 0
	for _, s in segments do
		if s.via == "Walk" then
			walked += TerrainModel.segmentLength(s)
		end
	end
	truthy(walked / #markers < WorldLayout.MarkerSpacing * 1.3, "markers too sparse")
end)

-- Props and hazards ---------------------------------------------------------------------------

test("terrain: fences, fixed ropes and signs reference real route points", function()
	for _, f in WorldLayout.Fences do
		truthy(TerrainModel.point(WorldLayout, f.from), "fence from " .. f.from)
		truthy(TerrainModel.point(WorldLayout, f.to), "fence to " .. f.to)
	end
	for _, r in WorldLayout.FixedRopes do
		truthy(TerrainModel.point(WorldLayout, r.from), "rope from " .. r.from)
		truthy(TerrainModel.point(WorldLayout, r.to), "rope to " .. r.to)
	end
	for _, sign in WorldLayout.Signs do
		local h = model.heightAt(sign.at.X, sign.at.Z)
		truthy(h > NO_GROUND, sign.text .. " has ground")
		truthy(model.slopeAt(sign.at.X, sign.at.Z) < 30, sign.text .. " on level ground")
		truthy(#sign.text <= 16, sign.text .. " fits on the board")
	end
end)

test("terrain: wood is scarce and placed on level ground off the trail", function()
	local camps = WorldLayout.Camps
	local nearBase, nearCamp1, finiteAtCamp2 = 0, 0, 0
	for _, w in WorldLayout.WoodSources do
		local h = model.heightAt(w.pos.X, w.pos.Z)
		truthy(h > NO_GROUND, "wood has ground " .. fmt(w.pos.X, w.pos.Z))
		truthy(model.slopeAt(w.pos.X, w.pos.Z) < 20, "wood on a slope " .. fmt(w.pos.X, w.pos.Z))
		truthy(TerrainModel.distanceToRoute(segments, w.pos.X, w.pos.Z) > 6, "wood on the trail")
		local function dist(c)
			return math.sqrt((w.pos.X - c.X) ^ 2 + (w.pos.Z - c.Z) ^ 2)
		end
		if dist(camps[1].center) < 800 then
			nearBase += 1
		elseif dist(camps[2].center) < 300 then
			nearCamp1 += 1
		elseif dist(camps[3].center) < 150 and w.respawn == nil then
			finiteAtCamp2 += 1
		else
			error("wood source far from every camp " .. fmt(w.pos.X, w.pos.Z))
		end
	end
	truthy(nearBase >= 8 and nearBase <= 12, "base camp wood " .. nearBase)
	truthy(nearCamp1 >= 2 and nearCamp1 <= 3, "camp 1 wood " .. nearCamp1)
	eq(finiteAtCamp2, 1, "one finite woodpile at Camp 2")
	eq(#WorldLayout.WaterSources, 0, "no streams: water comes from melting snow")
end)

test("terrain: trees only grow near Base Camp", function()
	local base = WorldLayout.Camps[1].center
	for _, c in WorldLayout.TreeClusters do
		local d = math.sqrt((c.x - base.X) ^ 2 + (c.z - base.Z) ^ 2)
		truthy(d < 700, "tree cluster too far up the mountain " .. fmt(c.x, c.z))
		truthy(model.heightAt(c.x, c.z) < 60, "trees stay low")
	end
end)

test("terrain: rockfall zones cover the trail and release from above it", function()
	eq(#WorldLayout.RockfallZones >= 1 and #WorldLayout.RockfallZones <= 2, true)
	for _, z in WorldLayout.RockfallZones do
		local c, size = z.zoneCenter, z.zoneSize
		local function inside(x, y, zz)
			return math.abs(x - c.X) <= size.X / 2
				and math.abs(y - c.Y) <= size.Y / 2
				and math.abs(zz - c.Z) <= size.Z / 2
		end
		local covered, trailY = 0, -math.huge
		for _, s in segments do
			if s.route == "Main" and s.via == "Walk" then
				for k = 0, 20 do
					local t = k / 20
					local x, y, zz = lerp(s.ax, s.bx, t), lerp(s.ay, s.by, t) + 2, lerp(s.az, s.bz, t)
					if inside(x, y, zz) then
						covered += 1
						trailY = math.max(trailY, y)
					end
				end
			end
		end
		truthy(covered >= 5, z.name .. " covers the trail")
		truthy(#z.releasePoints >= 1, z.name .. " has release points")
		for _, p in z.releasePoints do
			local h = model.heightAt(p.X, p.Z)
			truthy(h > NO_GROUND, z.name .. " release over terrain")
			truthy(h + 4 > trailY + 10, z.name .. " releases from above the trail")
		end
		local push = z.pushDirection
		truthy(push.Magnitude > 0.5, z.name .. " push direction")
	end
end)

test("terrain: summit is a small flat top with the SectionEnd on it", function()
	local s = WorldLayout.SectionEnd
	local h = model.heightAt(s.pos.X, s.pos.Z)
	near(h, s.pos.Y, 0.5, "SectionEnd on the surface")
	near(h, 800, 10, "summit height")
	truthy(s.radius >= 10 and s.radius <= 25, "SectionEnd radius")
	eq(model.classify(s.pos.X, s.pos.Z), "Flat")
	-- Nothing nearby is higher than the summit itself.
	for a = 0, 330, 30 do
		for d = 5, 80, 5 do
			local x = s.pos.X + math.sin(math.rad(a)) * d
			local z = s.pos.Z + math.cos(math.rad(a)) * d
			truthy(model.heightAt(x, z) <= h + 0.5, "higher ground next to the summit at " .. fmt(x, z))
		end
	end
end)

test("terrain: model queries are fast enough for prop placement", function()
	local t0 = os.clock()
	for i = 1, 20000 do
		model.heightAt((i * 37) % 1600 - 800, (i * 91) % 5000 - 400)
	end
	truthy(os.clock() - t0 < 2, string.format("20k queries took %.2fs", os.clock() - t0))
end)

H.report()
