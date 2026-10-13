-- Terrain / world layout tests: TerrainModel (pure heightfield) built from WorldLayout v3.
-- Run with: tests/run.sh

local H = __loadfile(ROOT .. "/tests/harness.luau")(ROOT)
local test, eq, near, truthy = H.test, H.eq, H.near, H.truthy
local Shared = H.Shared

local TerrainModel = H.require(Shared.Logic.TerrainModel)
local WorldLayout = H.require(Shared.Config.WorldLayout)
local GameConfig = H.require(Shared.Config.GameConfig)

local model = TerrainModel.new(WorldLayout)
local segments = TerrainModel.segments(WorldLayout)
local JUMP = GameConfig.JUMP_HEIGHT
local NO_GROUND = -math.huge

local function fmt(x: number, z: number): string
	return string.format("(%.0f, %.0f)", x, z)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Every column centre, in order.
local function eachColumn(stride: number, fn: (x: number, z: number, i: number, k: number) -> ())
	local g = model.grid
	for k = 0, g.nz - 1, stride do
		for i = 0, g.nx - 1, stride do
			fn(g.x0 + 2 + 4 * i, g.z0 + 2 + 4 * k, i, k)
		end
	end
end

-- Model basics ------------------------------------------------------------------------------

test("terrain: the heightfield covers Bounds on the 4-stud voxel grid and builds quickly", function()
	local b, g = WorldLayout.Bounds, model.grid
	for _, v in { b.x0, b.z0, b.x1, b.z1 } do
		eq(v % 4, 0, "bounds must be voxel aligned")
	end
	eq(g.x0, b.x0)
	eq(g.z0, b.z0)
	eq(g.nx * 4, b.x1 - b.x0)
	eq(g.nz * 4, b.z1 - b.z0)
	-- The plain test VM is slower than a Roblox server with native code generation.
	truthy(model.buildSeconds < 8, string.format("model built in %.2fs", model.buildSeconds))
	-- Column centres are exact grid samples; between them heights are bilinear.
	local h00 = model.heightAt(g.x0 + 2 + 4 * 100, g.z0 + 2 + 4 * 200)
	local h10 = model.heightAt(g.x0 + 2 + 4 * 101, g.z0 + 2 + 4 * 200)
	near(model.heightAt(g.x0 + 4 + 4 * 100, g.z0 + 2 + 4 * 200), (h00 + h10) / 2, 1e-4, "bilinear")
	eq(model.heightAt(b.x0 - 1, 0), NO_GROUND, "no terrain outside Bounds")
end)

test("terrain: every column has a finite height", function()
	local bad = 0
	local g = model.grid
	for k = 0, g.nz - 1 do
		for i = 0, g.nx - 1 do
			local h = model.column(i, k)
			if h ~= h or h == math.huge or h == -math.huge then
				bad += 1
			end
		end
	end
	eq(bad, 0, "columns with NaN or infinite height")
end)

test("terrain: voxel budget (at most 12M solid voxels)", function()
	local solid = model.solidVoxels()
	truthy(solid <= 12e6, string.format("%.1fM solid voxels", solid / 1e6))
	truthy(solid >= 1e6, "suspiciously little terrain")
end)

test("terrain: Base Camp is inside the first build phase", function()
	local first, base = WorldLayout.FirstBuild, WorldLayout.Camps[1]
	local c, f = base.center, base.footprint
	truthy(first.x0 <= c.X - f.X / 2 - 100 and first.x1 >= c.X + f.X / 2 + 100, "FirstBuild too narrow")
	truthy(first.z0 <= c.Z - f.Z / 2 - 100 and first.z1 >= c.Z + f.Z / 2 + 100, "FirstBuild too short")
end)

test("terrain: only snow, glacier on steep faces and a little rock near the summit", function()
	local counts = { Snow = 0, Glacier = 0, Rock = 0 }
	eachColumn(2, function(x, z)
		local _, mat = model.heightAt(x, z)
		truthy(counts[mat] ~= nil, "material " .. mat .. " at " .. fmt(x, z))
		counts[mat] += 1
		if mat == "Rock" then
			local inZone = false
			for _, zone in WorldLayout.RockZones do
				if (x - zone.x) ^ 2 + (z - zone.z) ^ 2 < zone.r ^ 2 then
					inZone = true
				end
			end
			truthy(inZone, "rock outside the summit zones at " .. fmt(x, z))
		end
	end)
	local total = counts.Snow + counts.Glacier + counts.Rock
	truthy(counts.Snow / total >= 0.6, string.format("mostly snow: %.0f%%", 100 * counts.Snow / total))
	truthy(counts.Glacier / total >= 0.05, "some glacier faces")
	truthy(counts.Rock >= 10 and counts.Rock / total <= 0.02, "rare rock outcrops: " .. counts.Rock)
end)

test("terrain: snow caps gentle columns, steep columns are ice through, air above and below", function()
	local camp = WorldLayout.Camps[1].center
	local h = model.heightAt(camp.X, camp.Z)
	eq(model.voxelMaterial(camp.X, h - 1, camp.Z), "Snow")
	eq(model.voxelMaterial(camp.X, h - 7, camp.Z), "Glacier", "ice body under the snow cap")
	eq(model.voxelMaterial(camp.X, h + 1, camp.Z), "Air")
	eq(model.voxelMaterial(camp.X, h - TerrainModel.SHELL - 6, camp.Z), "Air", "hollow below the shell")
	-- The ice wall's face: the column on top shows snow on top, ice in the face below.
	local top = model.heightAt(0, 2302)
	near(top, 284, 0.01, "ice wall top")
	eq(model.voxelMaterial(0, 282, 2302), "Snow")
	eq(model.voxelMaterial(0, 260, 2302), "Glacier")
	eq(model.voxelMaterial(0, 260, 2298), "Air", "in front of the wall")
	-- A crevasse floor column is ice; its walls are solid down to the floor.
	local floor = model.heightAt(0, 1800)
	local lip = model.heightAt(0, 1784)
	truthy(lip - floor >= 25, "crevasse depth")
	eq(model.voxelMaterial(0, floor + 4, 1786), "Glacier", "crevasse wall is solid ice")
end)

test("terrain: natural slopes everywhere except the designed cliffs", function()
	-- Column-to-column steps steeper than 80 degrees only come from cliffs the layout asks
	-- for (crevasses, locked shelves): the landscape and the trail never make one.
	local designed = { Landscape = false, Trail = false }
	local worst, at = 0, ""
	eachColumn(1, function(x, z, i, k)
		if i >= model.grid.nx - 1 or k >= model.grid.nz - 1 then
			return
		end
		local h, _, by = model.heightAt(x, z)
		if designed[by] == nil then
			return
		end
		for _, d in { { 4, 0 }, { 0, 4 } } do
			local h2, _, by2 = model.heightAt(x + d[1], z + d[2])
			if designed[by2] ~= nil then
				local deg = math.deg(math.atan(math.abs(h2 - h) / 4))
				if deg > worst then
					worst, at = deg, fmt(x, z) .. " " .. by .. "/" .. by2
				end
			end
		end
	end)
	truthy(worst <= 80, string.format("%.1f degree step at %s", worst, at))
	-- And most of the mountain is walkable snow, not a wall of ice.
	local steep, total = 0, 0
	eachColumn(3, function(x, z)
		total += 1
		if model.slopeAt(x, z) > TerrainModel.STEEP_ANGLE then
			steep += 1
		end
	end)
	truthy(
		steep / total <= 0.35,
		string.format("%.0f%% of the terrain is steeper than 40 degrees", 100 * steep / total)
	)
	truthy(steep / total >= 0.08, "no steep faces at all: a flat world")
end)

test("terrain: the ice wall is a real cliff across the valley; only the bypass ramp climbs it", function()
	-- East of the bypass ramp the wall is at least 40 studs; above the ramp (which climbs
	-- along its foot) it is still more than a jump, until the ramp's top at the west end.
	for x = -160, 330, 4 do
		local below, above = model.heightAt(x, 2298), model.heightAt(x, 2302)
		local need = if x >= 130 then 40 else JUMP + 1
		truthy(above - below >= need, string.format("ice wall only %.1f high at x %d", above - below, x))
	end
	-- The ridge ice step is sheer on its south, east and west sides.
	for x = 34, 86, 4 do
		local drop = model.heightAt(x, 3650) - model.heightAt(x, 3646)
		truthy(drop >= 20, string.format("ice step face only %.1f at x %d", drop, x))
	end
	for z = 3650, 3698, 4 do
		for _, side in { { 34, 30 }, { 86, 90 } } do
			local drop = model.heightAt(side[1], z) - model.heightAt(side[2], z)
			truthy(drop >= 20, string.format("ice step side only %.1f at %s", drop, fmt(side[1], z)))
		end
	end
end)

test("terrain: slope classification", function()
	eq(TerrainModel.classifySlope(0), "Flat")
	eq(TerrainModel.classifySlope(20), "Walkable")
	eq(TerrainModel.classifySlope(40), "Walkable")
	eq(TerrainModel.classifySlope(41), "Steep")
	eq(model.classify(0, 0), "Flat", "Base Camp")
	eq(model.classify(200, 2300), "Steep", "ice wall face")
	local h1 = TerrainModel.point(WorldLayout, "H1") :: TerrainModel.RoutePoint
	local h3 = TerrainModel.point(WorldLayout, "H3") :: TerrainModel.RoutePoint
	-- Between two headwall switchback legs: a walkable snow slope.
	local mx, mz = (h1.x + h3.x) / 2, (h1.z + h3.z) / 2
	eq(model.classify(mx, mz), "Walkable", "headwall slope at " .. fmt(mx, mz))
end)

test("terrain: the world bounds are fully covered and the skirt goes on beyond", function()
	local b = WorldLayout.Bounds
	for x = b.x0, b.x1, 50 do
		for z = b.z0, b.z1, 50 do
			local h = model.heightAt(math.clamp(x, b.x0 + 1, b.x1 - 1), math.clamp(z, b.z0 + 1, b.z1 - 1))
			truthy(h >= 0 and h > WorldLayout.SafetyNetY, "no ground at " .. fmt(x, z))
		end
	end
	local sk = WorldLayout.Skirt
	truthy(sk.x0 <= b.x0 - 1400 and sk.x1 >= b.x1 + 1400, "skirt too narrow in X")
	truthy(sk.z0 <= b.z0 - 1400 and sk.z1 >= b.z1 + 1400, "skirt too short in Z")
	truthy(sk.top <= 0 and sk.top > -4, "skirt sits just under the lowest terrain")
	truthy(WorldLayout.SafetyFloorY < WorldLayout.SafetyNetY, "safety floor sits below the safety net")
	truthy(WorldLayout.SafetyFloorY < -TerrainModel.SHELL - 20, "safety floor is under the terrain")
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

test("terrain: backdrop peaks are Parts outside the terrain, sized within Part limits", function()
	truthy(#WorldLayout.Scenery >= 16, "backdrop peaks")
	local b = WorldLayout.Bounds
	for _, p in WorldLayout.Scenery do
		local side = TerrainModel.peakSide(p.top)
		truthy(side <= 2048, "peak too big for one Part " .. fmt(p.x, p.z))
		-- Ground cuts the cube above its upper corners, so no face overhangs.
		truthy(p.top <= side / math.sqrt(3), "peak overhangs " .. fmt(p.x, p.z))
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
	-- No peak footprint reaches into the terrain.
	for x = b.x0, b.x1, 32 do
		for _, z in { b.z0, b.z1 } do
			eq(TerrainModel.sceneryHeight(WorldLayout, x, z), -math.huge, "peak over the terrain at " .. fmt(x, z))
		end
	end
	for z = b.z0, b.z1, 32 do
		for _, x in { b.x0, b.x1 } do
			eq(TerrainModel.sceneryHeight(WorldLayout, x, z), -math.huge, "peak over the terrain at " .. fmt(x, z))
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
			truthy(face and face <= 6, "wall face near the ladder foot")
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
	local top = assert(TerrainModel.point(WorldLayout, "WallTop"))
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
