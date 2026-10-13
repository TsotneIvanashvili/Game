-- World simulation: Workspace membership, a spatial hash of parts for raycasts and overlap
-- queries (oriented boxes, balls and wedges), terrain via an injected height function,
-- jointed assemblies (setting a part's CFrame moves everything welded to it, like the
-- engine), pivots/bounding boxes, and a kinematic humanoid controller.
--
-- NOT emulated (explicitly): rigid-body physics for loose parts (unanchored props stay where
-- they are put), Touched events from physics contacts, terrain voxels (only the injected
-- surface height exists; caves/overhangs are invisible to raycasts), cylinder/corner-wedge
-- exact shapes (treated as boxes), rendering.

return function(M)
	local S = M.S
	local T = M.types
	local Enum = M.Enum
	local v3, raw = M.v3, M.raw
	local classes = M.classes
	local sqrt, abs, floor, huge = math.sqrt, math.abs, math.floor, math.huge

	-- Membership flags + spatial index -------------------------------------------------------
	local CELL = 16
	local BIG = 512
	local cells: { [number]: { [any]: boolean } } = {}
	local bigParts: { [any]: boolean } = {}
	local indexed: { [any]: { number } | boolean } = {}
	local dirty: { [any]: boolean } = {}
	local humanoids: { [any]: boolean } = {}
	M.humanoids = humanoids
	local boxes: { [any]: { number } } = {} -- world AABB per indexed part
	local aligns: { [any]: boolean } = {} -- AlignPositions in Workspace

	local function key(ix: number, iz: number): number
		return (ix + 32768) * 65536 + (iz + 32768)
	end

	local function partAABB(part)
		local c = raw(part, "CFrame")
		local s = raw(part, "Size")
		local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
		local ex = abs(c[1]) * hx + abs(c[2]) * hy + abs(c[3]) * hz
		local ey = abs(c[4]) * hx + abs(c[5]) * hy + abs(c[6]) * hz
		local ez = abs(c[7]) * hx + abs(c[8]) * hy + abs(c[9]) * hz
		return c.X - ex, c.Y - ey, c.Z - ez, c.X + ex, c.Y + ey, c.Z + ez
	end
	M.partAABB = partAABB

	local function unindex(part)
		local entry = indexed[part]
		if entry == nil then
			return
		end
		if entry == true then
			bigParts[part] = nil
		else
			for _, k in entry :: { number } do
				local cell = cells[k]
				if cell then
					cell[part] = nil
				end
			end
		end
		indexed[part] = nil
		boxes[part] = nil
	end
	local cellRange: { [any]: { number } } = setmetatable({}, { __mode = "k" }) :: any
	local function index(part)
		local x0, y0, z0, x1, y1, z1 = partAABB(part)
		boxes[part] = { x0, y0, z0, x1, y1, z1 }
		if x1 - x0 > BIG or z1 - z0 > BIG or x0 ~= x0 then
			unindex(part)
			bigParts[part] = true
			indexed[part] = true
			return
		end
		local ix0, ix1, iz0, iz1 = floor(x0 / CELL), floor(x1 / CELL), floor(z0 / CELL), floor(z1 / CELL)
		local range = cellRange[part]
		if range and indexed[part] ~= nil and indexed[part] ~= true and range[1] == ix0 and range[2] == ix1 and range[3] == iz0 and range[4] == iz1 then
			return -- still in the same cells
		end
		unindex(part)
		cellRange[part] = { ix0, ix1, iz0, iz1 }
		local keys = {}
		for ix = ix0, ix1 do
			for iz = iz0, iz1 do
				local k = key(ix, iz)
				local cell = cells[k]
				if not cell then
					cell = {}
					cells[k] = cell
				end
				cell[part] = true
				table.insert(keys, k)
			end
		end
		indexed[part] = keys
	end
	local function flush()
		for part in dirty do
			if rawget(part, "_inWs") then
				index(part)
			end
		end
		table.clear(dirty)
	end

	function M.partMoved(part)
		if rawget(part, "_inWs") then
			dirty[part] = true
		end
	end

	local function isTerrain(inst)
		return inst._cls.name == "Terrain"
	end

	-- Called by Instance.Parent changes.
	function M.onReparent(self, _old, newParent)
		local inWs = newParent ~= nil and (newParent == M.workspace or rawget(newParent, "_inWs") == true)
		local inGame = newParent ~= nil and (rawget(newParent, "_isGame") == true or rawget(newParent, "_inGame") == true)
		if (rawget(self, "_inWs") == true) == inWs and (rawget(self, "_inGame") == true) == inGame then
			return
		end
		M.jointsChanged()
		local function apply(inst)
			local wasGame = rawget(inst, "_inGame") == true
			rawset(inst, "_inWs", inWs or nil)
			rawset(inst, "_inGame", inGame or nil)
			local cls = inst._cls
			if cls.isa.BasePart and not isTerrain(inst) then
				if inWs then
					dirty[inst] = true
				else
					dirty[inst] = nil
					unindex(inst)
				end
				if M.considerLoose then
					M.considerLoose(inst)
				end
			end
			if cls.name == "Humanoid" then
				humanoids[inst] = if inWs then true else nil
			elseif cls.name == "AlignPosition" then
				aligns[inst] = if inWs then true else nil
			end
			if wasGame ~= inGame then
				M.tagMembershipChanged(inst, inGame)
			end
			local children = rawget(inst, "_children")
			if children then
				for _, c in children do
					apply(c)
				end
			end
		end
		apply(self)
	end
	function M.onDestroy(self)
		unindex(self)
		dirty[self] = nil
		humanoids[self] = nil
		aligns[self] = nil
		M.jointsChanged()
		M.clearTags(self)
		local joints = rawget(self, "_jointsOf")
		if joints then
			M.setJointParts(self, nil, nil)
		end
	end

	-- Joints / assemblies ---------------------------------------------------------------------
	local function jointList(part)
		local j = rawget(part, "_joints")
		if not j then
			j = {}
			rawset(part, "_joints", j)
		end
		return j
	end
	-- Records which parts a joint connects (called from Part0/Part1 setters).
	function M.setJointParts(joint, p0, p1)
		local old = rawget(joint, "_jointsOf")
		if old then
			for _, p in old do
				local j = rawget(p, "_joints")
				if j then
					j[joint] = nil
				end
			end
		end
		local list = {}
		if p0 then
			jointList(p0)[joint] = true
			table.insert(list, p0)
		end
		if p1 then
			jointList(p1)[joint] = true
			table.insert(list, p1)
		end
		if M.loose then
			for _, p in list do
				M.loose[p] = nil
			end
		end
		rawset(joint, "_jointsOf", list)
		M.jointsChanged()
	end
	local function jointActive(joint): boolean
		if rawget(joint, "_destroyed") or not rawget(joint, "_inWs") then
			return false
		end
		if joint._p.Enabled == false then
			return false
		end
		local p0, p1 = joint._p.Part0, joint._p.Part1
		return p0 ~= nil and p1 ~= nil and rawget(p0, "_inWs") == true and rawget(p1, "_inWs") == true
	end
	-- Every part rigidly connected to `part` through active joints (including itself).
	-- Cached until any joint or Workspace membership changes.
	local jointsVersion = 0
	local asmCache: { [any]: { version: number, parts: { any } } } = setmetatable({}, { __mode = "k" }) :: any
	function M.jointsChanged()
		jointsVersion += 1
	end
	function M.assembly(part): { any }
		if not rawget(part, "_joints") or not rawget(part, "_inWs") then
			return { part }
		end
		local cached = asmCache[part]
		if cached and cached.version == jointsVersion then
			return cached.parts
		end
		local out = { part }
		local seen = { [part] = true }
		local i = 1
		while i <= #out do
			local p = out[i]
			local joints = rawget(p, "_joints")
			if joints then
				for joint in joints do
					if jointActive(joint) then
						for _, q in { joint._p.Part0, joint._p.Part1 } do
							if not seen[q] then
								seen[q] = true
								table.insert(out, q)
							end
						end
					end
				end
			end
			i += 1
		end
		asmCache[part] = { version = jointsVersion, parts = out }
		return out
	end
	local function jointPartSpec(cls, key)
		local spec = cls.props[key]
		spec.set = function(self, v)
			M.store(self, key, v)
			M.setJointParts(self, self._p.Part0, self._p.Part1)
		end
	end
	jointPartSpec(classes.JointInstance, "Part0")
	jointPartSpec(classes.JointInstance, "Part1")
	jointPartSpec(classes.WeldConstraint, "Part0")
	jointPartSpec(classes.WeldConstraint, "Part1")
	for _, cls in { classes.JointInstance, classes.WeldConstraint } do
		cls.props.Enabled.set = function(self, v)
			M.store(self, "Enabled", v)
			M.jointsChanged()
		end
	end

	-- Script-side CFrame write: moves the whole assembly (engine semantics for CFrame; a
	-- Position write moves only the part).
	local function engineSetCFrame(part, cf)
		M.storeShared(part, "CFrame", cf)
		M.changed(part, "Position", nil)
		M.partMoved(part)
	end
	M.engineSetCFrame = engineSetCFrame
	local cfSpec = classes.BasePart.props.CFrame
	cfSpec.set = function(self, v)
		local old = raw(self, "CFrame")
		M.store(self, "CFrame", v)
		M.changed(self, "Position", nil)
		M.changed(self, "Orientation", nil)
		M.partMoved(self)
		if rawget(self, "_joints") and rawget(self, "_inWs") then
			local delta = v * old:Inverse()
			for _, q in M.assembly(self) do
				if q ~= self then
					M.store(q, "CFrame", delta * raw(q, "CFrame"))
					M.partMoved(q)
				end
			end
		end
	end
	-- Position writes keep the plain store (no assembly move) — already the class default.

	function M.partMass(part): number
		local s = raw(part, "Size")
		local density = 0.7
		local pp = raw(part, "CustomPhysicalProperties")
		if pp then
			density = pp.Density
		end
		if raw(part, "Massless") then
			return 0
		end
		return s.X * s.Y * s.Z * density
	end

	-- Pivots / bounding boxes ----------------------------------------------------------------------
	local function descendantParts(inst)
		local out = {}
		for _, d in M.descendantsRaw(inst, {}) do
			if d._cls.isa.BasePart then
				table.insert(out, d)
			end
		end
		return out
	end
	M.descendantParts = descendantParts

	local function boundsIn(frame, parts)
		local inv = frame:Inverse()
		local x0, y0, z0, x1, y1, z1 = huge, huge, huge, -huge, -huge, -huge
		for _, p in parts do
			local c = inv * raw(p, "CFrame")
			local s = raw(p, "Size")
			local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
			local ex = abs(c[1]) * hx + abs(c[2]) * hy + abs(c[3]) * hz
			local ey = abs(c[4]) * hx + abs(c[5]) * hy + abs(c[6]) * hz
			local ez = abs(c[7]) * hx + abs(c[8]) * hy + abs(c[9]) * hz
			x0, y0, z0 = math.min(x0, c.X - ex), math.min(y0, c.Y - ey), math.min(z0, c.Z - ez)
			x1, y1, z1 = math.max(x1, c.X + ex), math.max(y1, c.Y + ey), math.max(z1, c.Z + ez)
		end
		if x0 == huge then
			return frame, v3(0, 0, 0)
		end
		local center = frame * v3((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
		return frame.Rotation + center, v3(x1 - x0, y1 - y0, z1 - z0)
	end

	function M.getPivot(self)
		local cls = self._cls
		if cls.isa.BasePart then
			return raw(self, "CFrame") * raw(self, "PivotOffset")
		elseif cls.isa.Model then
			local pp = raw(self, "PrimaryPart")
			if pp then
				return raw(pp, "CFrame") * raw(pp, "PivotOffset")
			end
			local stored = self._p.WorldPivot
			if stored then
				return stored
			end
			local frame = boundsIn(T.CFrame.identity, descendantParts(self))
			return frame
		elseif cls.name == "Camera" then
			return raw(self, "CFrame")
		end
		return T.CFrame.identity
	end
	function M.boundingBox(model)
		local pivot = M.getPivot(model)
		return boundsIn(pivot.Rotation, descendantParts(model))
	end
	function M.pivotTo(self, target)
		local cls = self._cls
		if cls.isa.BasePart then
			self.CFrame = target * raw(self, "PivotOffset"):Inverse()
			return
		end
		if cls.name == "Camera" then
			self.CFrame = target
			return
		end
		local current = M.getPivot(self)
		local delta = target * current:Inverse()
		-- Rigid move of every descendant part (assemblies inside are moved by this loop too,
		-- so write each part directly instead of through the assembly-moving setter).
		local moved = {}
		for _, p in descendantParts(self) do
			moved[p] = true
			M.store(p, "CFrame", delta * raw(p, "CFrame"))
			M.changed(p, "Position", nil)
			M.partMoved(p)
		end
		-- Parts welded to this model from outside (e.g. a carried player) follow too.
		for p in moved do
			if rawget(p, "_joints") then
				for _, q in M.assembly(p) do
					if not moved[q] then
						moved[q] = true
						M.store(q, "CFrame", delta * raw(q, "CFrame"))
						M.partMoved(q)
					end
				end
			end
		end
		if not raw(self, "PrimaryPart") then
			self._p.WorldPivot = target
		end
	end

	-- Terrain ---------------------------------------------------------------------------------------
	M.terrainOps = {}
	M.terrainHeight = nil :: ((x: number, z: number) -> (number, string))?
	M.terrainNormal = nil :: ((x: number, z: number) -> (number, number, number))?
	function M.terrainOp(_terrain, kind, ...)
		table.insert(M.terrainOps, { kind = kind, args = table.pack(...) })
	end
	-- Inject the terrain surface (e.g. from Shared/Logic/TerrainModel) so ground raycasts work.
	-- `materialAt(x, y, z)` (optional) names the voxel material at a point, so rays hitting
	-- a cliff face report the face's material instead of the material on top.
	function M.setTerrainSurface(heightAt, normalAt, materialAt)
		M.terrainHeight = heightAt
		M.terrainNormal = normalAt
		M.terrainMaterial = materialAt
	end

	-- Filters -----------------------------------------------------------------------------------------
	local function makeFilter(params)
		if params == nil then
			return function(_)
				return true
			end, true
		end
		local props = rawget(params, "_props")
		local set = {}
		for _, inst in props.FilterDescendantsInstances do
			set[inst] = true
		end
		local include = props.FilterType == Enum.RaycastFilterType.Include or props.FilterType == Enum.RaycastFilterType.Whitelist
		local respectCollide = props.RespectCanCollide
		local function listed(inst)
			local node = inst
			while node do
				if set[node] then
					return true
				end
				node = rawget(node, "_parent")
			end
			return false
		end
		local function accept(part)
			if respectCollide and not raw(part, "CanCollide") then
				return false
			end
			local l = listed(part)
			if include then
				return l
			end
			return not l
		end
		local terrainOk = if include then set[M.terrain] == true else not set[M.terrain]
		return accept, terrainOk, props
	end

	local function candidates(x0, z0, x1, z1)
		flush()
		local out = {}
		local seen = {}
		local ix0, ix1, iz0, iz1 = floor(x0 / CELL), floor(x1 / CELL), floor(z0 / CELL), floor(z1 / CELL)
		if ix0 == ix1 and iz0 == iz1 then
			-- Single cell (vertical rays, small boxes): no de-duplication needed.
			local cell = cells[key(ix0, iz0)]
			if cell then
				for part in cell do
					table.insert(out, part)
				end
			end
			for part in bigParts do
				table.insert(out, part)
			end
			return out
		end
		if (ix1 - ix0 + 1) * (iz1 - iz0 + 1) > 4096 then
			-- Huge query: scan every indexed part.
			for part in indexed do
				table.insert(out, part)
			end
			return out
		end
		for ix = ix0, ix1 do
			for iz = iz0, iz1 do
				local cell = cells[key(ix, iz)]
				if cell then
					for part in cell do
						if not seen[part] then
							seen[part] = true
							table.insert(out, part)
						end
					end
				end
			end
		end
		for part in bigParts do
			table.insert(out, part)
		end
		return out
	end

	local function queryable(part, ctx)
		return raw(part, "CanQuery") and M.visibleTo(part, ctx)
	end

	-- Ray vs one part. Returns t (0..1 along `dir`), normal (world) or nil.
	local function rayPart(part, o, d)
		local c = raw(part, "CFrame")
		local s = raw(part, "Size")
		local ox, oy, oz = o.X - c.X, o.Y - c.Y, o.Z - c.Z
		-- local = R^T * v
		local lox = c[1] * ox + c[4] * oy + c[7] * oz
		local loy = c[2] * ox + c[5] * oy + c[8] * oz
		local loz = c[3] * ox + c[6] * oy + c[9] * oz
		local ldx = c[1] * d.X + c[4] * d.Y + c[7] * d.Z
		local ldy = c[2] * d.X + c[5] * d.Y + c[8] * d.Z
		local ldz = c[3] * d.X + c[6] * d.Y + c[9] * d.Z
		local cls = part._cls
		if cls.name == "Part" and raw(part, "Shape") == Enum.PartType.Ball then
			local r = math.min(s.X, s.Y, s.Z) / 2
			local a = ldx * ldx + ldy * ldy + ldz * ldz
			local b = 2 * (lox * ldx + loy * ldy + loz * ldz)
			local cc = lox * lox + loy * loy + loz * loz - r * r
			if cc <= 0 then
				return nil -- origin inside: the engine ignores the part
			end
			local disc = b * b - 4 * a * cc
			if disc < 0 or a == 0 then
				return nil
			end
			local t = (-b - sqrt(disc)) / (2 * a)
			if t < 0 or t > 1 then
				return nil
			end
			local hx, hy, hz = lox + ldx * t, loy + ldy * t, loz + ldz * t
			local n = M.vectorToWorld(c, v3(hx, hy, hz)).Unit
			return t, n
		end
		local half = { s.X / 2, s.Y / 2, s.Z / 2 }
		local lo = { lox, loy, loz }
		local ld = { ldx, ldy, ldz }
		local tmin, tmax = -huge, huge
		local nAxis, nSign = 0, 0
		local inside = true
		for axis = 1, 3 do
			local h = half[axis]
			if abs(lo[axis]) > h then
				inside = false
			end
			if abs(ld[axis]) < 1e-12 then
				if abs(lo[axis]) > h then
					return nil
				end
			else
				local t1 = (-h - lo[axis]) / ld[axis]
				local t2 = (h - lo[axis]) / ld[axis]
				local sign = -1
				if t1 > t2 then
					t1, t2 = t2, t1
					sign = 1
				end
				if t1 > tmin then
					tmin = t1
					nAxis, nSign = axis, sign
				end
				if t2 < tmax then
					tmax = t2
				end
				if tmin > tmax then
					return nil
				end
			end
		end
		if inside then
			return nil
		end
		local wedge = cls.name == "WedgePart"
		if wedge then
			-- Solid where y/sy <= z/sz (slope rises toward +Z / back). Clip the box interval
			-- with the half-space f(t) = y/sy - z/sz <= 0.
			local f0 = lo[2] / s.Y - lo[3] / s.Z
			local fd = ld[2] / s.Y - ld[3] / s.Z
			if abs(fd) < 1e-12 then
				if f0 > 0 then
					return nil
				end
			else
				local tc = -f0 / fd
				if fd > 0 then
					tmax = math.min(tmax, tc)
				elseif tc > tmin then
					tmin = tc
					nAxis = 4
				end
			end
			if tmin > tmax then
				return nil
			end
		end
		if tmin < 0 or tmin > 1 then
			return nil
		end
		local ln
		if nAxis == 4 then
			ln = v3(0, 1 / s.Y, -1 / s.Z).Unit
		elseif nAxis == 1 then
			ln = v3(nSign, 0, 0)
		elseif nAxis == 2 then
			ln = v3(0, nSign, 0)
		else
			ln = v3(0, 0, nSign)
		end
		return tmin, M.vectorToWorld(c, ln)
	end

	local function rayTerrain(o, d)
		local hf = M.terrainHeight
		if not hf then
			return nil
		end
		local function f(t)
			local x, y, z = o.X + d.X * t, o.Y + d.Y * t, o.Z + d.Z * t
			local h = hf(x, z)
			return y - h
		end
		local horiz = sqrt(d.X * d.X + d.Z * d.Z)
		local len = d.Magnitude
		local steps = math.clamp(math.ceil(horiz / 2), 1, 2000)
		if horiz < 1e-6 then
			steps = 1
		end
		local prevT, prevF = 0, f(0)
		if prevF ~= prevF then
			return nil
		end
		for i = 1, steps do
			local t = i / steps
			local ft = f(t)
			if prevF > 0 and ft <= 0 then
				local a, b = prevT, t
				for _ = 1, 30 do
					local m = (a + b) / 2
					if f(m) > 0 then
						a = m
					else
						b = m
					end
				end
				local x, z = o.X + d.X * b, o.Z + d.Z * b
				local _, mat = hf(x, z)
				local nx, ny, nz = 0, 1, 0
				if M.terrainNormal then
					nx, ny, nz = M.terrainNormal(x, z)
				end
				if M.terrainMaterial then
					local y = o.Y + d.Y * b
					local inner = M.terrainMaterial(x - nx * 0.5, y - ny * 0.5, z - nz * 0.5)
					if inner and inner ~= "Air" then
						mat = inner
					end
				end
				local okMat, material = pcall(function()
					return (Enum.Material :: any)[mat or "Snow"]
				end)
				return b, v3(nx, ny, nz), if okMat then material else Enum.Material.Snow
			end
			prevT, prevF = t, ft
		end
		local _ = len
		return nil
	end

	-- Segment origin..origin+dir against an axis-aligned box {x0,y0,z0,x1,y1,z1}.
	local function segmentHitsBox(b, o, d): boolean
		local tmin, tmax = 0, 1
		local ox, oy, oz, dx, dy, dz = o.X, o.Y, o.Z, d.X, d.Y, d.Z
		for axis = 1, 3 do
			local oa, da, lo, hi
			if axis == 1 then
				oa, da, lo, hi = ox, dx, b[1], b[4]
			elseif axis == 2 then
				oa, da, lo, hi = oy, dy, b[2], b[5]
			else
				oa, da, lo, hi = oz, dz, b[3], b[6]
			end
			if abs(da) < 1e-12 then
				if oa < lo or oa > hi then
					return false
				end
			else
				local t1, t2 = (lo - oa) / da, (hi - oa) / da
				if t1 > t2 then
					t1, t2 = t2, t1
				end
				if t1 > tmin then
					tmin = t1
				end
				if t2 < tmax then
					tmax = t2
				end
				if tmin > tmax then
					return false
				end
			end
		end
		return true
	end

	function M.raycast(origin, direction, params)
		if M.typeof(origin) ~= "Vector3" then
			error("invalid argument #1 to 'Raycast' (Vector3 expected, got " .. M.typeof(origin) .. ")", 3)
		end
		if M.typeof(direction) ~= "Vector3" then
			error("invalid argument #2 to 'Raycast' (Vector3 expected, got " .. M.typeof(direction) .. ")", 3)
		end
		if params ~= nil and M.typeof(params) ~= "RaycastParams" then
			error("invalid argument #3 to 'Raycast' (RaycastParams expected, got " .. M.typeof(params) .. ")", 3)
		end
		if direction.Magnitude > 15000 then
			error("Raycast direction magnitude exceeds 15000 studs", 3)
		end
		local accept, terrainOk = makeFilter(params)
		local ctx = S.current
		local e = direction
		local x0, x1 = math.min(origin.X, origin.X + e.X), math.max(origin.X, origin.X + e.X)
		local z0, z1 = math.min(origin.Z, origin.Z + e.Z), math.max(origin.Z, origin.Z + e.Z)
		local bestT, bestPart, bestN = huge, nil, nil
		for _, part in candidates(x0, z0, x1, z1) do
			local box = boxes[part]
			if box and segmentHitsBox(box, origin, direction) and queryable(part, ctx) and accept(part) then
				local t, n = rayPart(part, origin, direction)
				if t and t < bestT then
					bestT, bestPart, bestN = t, part, n
				end
			end
		end
		local bestMat = if bestPart then raw(bestPart, "Material") else nil
		if terrainOk then
			local t, n, mat = rayTerrain(origin, direction)
			if t and t < bestT then
				bestT, bestPart, bestN, bestMat = t, M.terrain, n, mat
			end
		end
		if not bestPart then
			return nil
		end
		local pos = origin + direction * bestT
		return M.raycastResult(bestPart, pos, bestN, bestMat, direction.Magnitude * bestT)
	end

	-- Overlap (SAT between two oriented boxes) ------------------------------------------------------
	local function obbOverlap(ca, sa, cb, sb): boolean
		local A = { v3(ca[1], ca[4], ca[7]), v3(ca[2], ca[5], ca[8]), v3(ca[3], ca[6], ca[9]) }
		local B = { v3(cb[1], cb[4], cb[7]), v3(cb[2], cb[5], cb[8]), v3(cb[3], cb[6], cb[9]) }
		local ha = { sa.X / 2, sa.Y / 2, sa.Z / 2 }
		local hb = { sb.X / 2, sb.Y / 2, sb.Z / 2 }
		local t = v3(cb.X - ca.X, cb.Y - ca.Y, cb.Z - ca.Z)
		local axes = {}
		for i = 1, 3 do
			table.insert(axes, A[i])
			table.insert(axes, B[i])
			for j = 1, 3 do
				local c = A[i]:Cross(B[j])
				if c.Magnitude > 1e-6 then
					table.insert(axes, c.Unit)
				end
			end
		end
		for _, L in axes do
			local ra = 0
			local rb = 0
			for i = 1, 3 do
				ra += ha[i] * abs(A[i]:Dot(L))
				rb += hb[i] * abs(B[i]:Dot(L))
			end
			if abs(t:Dot(L)) > ra + rb + 1e-9 then
				return false
			end
		end
		return true
	end

	local function overlapQuery(x0, z0, x1, z1, params, test)
		if params ~= nil and M.typeof(params) ~= "OverlapParams" then
			error("invalid argument (OverlapParams expected, got " .. M.typeof(params) .. ")", 4)
		end
		local accept, _, props = makeFilter(params)
		local maxParts = if props then props.MaxParts else 0
		local ctx = S.current
		local out = {}
		for _, part in candidates(x0, z0, x1, z1) do
			if queryable(part, ctx) and accept(part) and test(part) then
				table.insert(out, part)
				if maxParts > 0 and #out >= maxParts then
					break
				end
			end
		end
		return out
	end

	function M.partBoundsInBox(frame, size, params)
		if M.typeof(frame) ~= "CFrame" then
			error("invalid argument #1 to 'GetPartBoundsInBox' (CFrame expected, got " .. M.typeof(frame) .. ")", 3)
		end
		if M.typeof(size) ~= "Vector3" then
			error("invalid argument #2 to 'GetPartBoundsInBox' (Vector3 expected, got " .. M.typeof(size) .. ")", 3)
		end
		local qx0, _, qz0, qx1, _, qz1 = (function()
			local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
			local c = frame
			local ex = abs(c[1]) * hx + abs(c[2]) * hy + abs(c[3]) * hz
			local ey = abs(c[4]) * hx + abs(c[5]) * hy + abs(c[6]) * hz
			local ez = abs(c[7]) * hx + abs(c[8]) * hy + abs(c[9]) * hz
			return c.X - ex, c.Y - ey, c.Z - ez, c.X + ex, c.Y + ey, c.Z + ez
		end)()
		return overlapQuery(qx0, qz0, qx1, qz1, params, function(part)
			-- The part's bounding box (axis aligned) against the query box.
			local x0, y0, z0, x1, y1, z1 = partAABB(part)
			local aabbFrame = T.CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
			return obbOverlap(frame, size, aabbFrame, v3(x1 - x0, y1 - y0, z1 - z0))
		end)
	end
	function M.partBoundsInRadius(pos, radius, params)
		if M.typeof(pos) ~= "Vector3" or type(radius) ~= "number" then
			error("invalid arguments to 'GetPartBoundsInRadius' (Vector3, number expected)", 3)
		end
		return overlapQuery(pos.X - radius, pos.Z - radius, pos.X + radius, pos.Z + radius, params, function(part)
			local x0, y0, z0, x1, y1, z1 = partAABB(part)
			local cx = math.clamp(pos.X, x0, x1)
			local cy = math.clamp(pos.Y, y0, y1)
			local cz = math.clamp(pos.Z, z0, z1)
			local dx, dy, dz = pos.X - cx, pos.Y - cy, pos.Z - cz
			return dx * dx + dy * dy + dz * dz <= radius * radius
		end)
	end
	function M.partsInPart(other, params)
		if not (M.isInstance(other) and other._cls.isa.BasePart) then
			error("invalid argument #1 to 'GetPartsInPart' (BasePart expected)", 3)
		end
		local c, s = raw(other, "CFrame"), raw(other, "Size")
		local x0, _, z0, x1, _, z1 = partAABB(other)
		return overlapQuery(x0, z0, x1, z1, params, function(part)
			return part ~= other and obbOverlap(c, s, raw(part, "CFrame"), raw(part, "Size"))
		end)
	end

	-- Humanoids ---------------------------------------------------------------------------------------
	local HS = Enum.HumanoidStateType
	function M.setHumanoidState(h, state)
		local old = rawget(h, "_state") or HS.Running
		if old == state then
			return
		end
		rawset(h, "_state", state)
		M.fire(M.getEvent(h, "StateChanged"), old, state)
		if state == HS.Jumping then
			rawset(h, "_wantJump", true)
		end
	end
	function M.humanoidDied(h)
		rawset(h, "_dead", true)
		rawset(h, "_state", HS.Dead)
		M.fire(M.getEvent(h, "StateChanged"), HS.Running, HS.Dead)
		M.fire(M.getEvent(h, "Died"))
		if M.onHumanoidDied then
			M.onHumanoidDied(h)
		end
	end

	-- Kinematic controller, once per frame before task resumption. Walks toward MoveTo targets
	-- or Move directions at WalkSpeed, stands HipHeight above the ground found by raycast,
	-- falls with workspace.Gravity, jumps with JumpHeight. It reads the humanoid's
	-- properties in the owning client's context (clients simulate their own character).
	local function stepHumanoid(h, dt)
		if rawget(h, "_dead") or rawget(h, "_destroyed") then
			return
		end
		local character = rawget(h, "_parent")
		if not character then
			return
		end
		local root = M.findChild(character, "HumanoidRootPart")
		if not root or not root._cls.isa.BasePart or raw(root, "Anchored") then
			return
		end
		local player = M.playerFromCharacter and M.playerFromCharacter(character)
		local prev = S.current
		S.current = if player then rawget(player, "_clientCtx") or M.serverCtx else M.serverCtx
		local ok, err = pcall(function()
			-- Welded to something anchored outside the character: it can't move.
			local asm = M.assembly(root)
			for _, q in asm do
				if raw(q, "Anchored") and not M.isAncestor(character, q) then
					return
				end
			end
			-- A client AlignPosition on the root (climbing) drives it instead of walking.
			for align in aligns do
				local a0 = raw(align, "Attachment0")
				if a0 and rawget(a0, "_parent") == root and raw(align, "Enabled") and not rawget(align, "_destroyed") then
					local target = raw(align, "Position")
					local cfr = raw(root, "CFrame")
					local delta = target - cfr.Position
					local maxStep = math.min(raw(align, "MaxVelocity"), 60) * dt
					if delta.Magnitude > maxStep then
						delta = delta.Unit * maxStep
					end
					M.engineMoveAssembly(root, cfr + delta, asm)
					M.storeShared(root, "AssemblyLinearVelocity", delta / dt)
					rawset(h, "_vy", 0)
					return
				end
			end
			-- Platform-standing / seated humanoids are not walked by the controller.
			if raw(h, "PlatformStand") or raw(h, "Sit") then
				return
			end
			local cfr = raw(root, "CFrame")
			local pos = cfr.Position
			local dir = v3(0, 0, 0)
			local target = rawget(h, "_moveTarget")
			if target then
				local flat = v3(target.pos.X - pos.X, 0, target.pos.Z - pos.Z)
				if flat.Magnitude < 1 then
					rawset(h, "_moveTarget", nil)
					M.fire(M.getEvent(h, "MoveToFinished"), true)
				elseif S.now - target.started > 8 then
					rawset(h, "_moveTarget", nil)
					M.fire(M.getEvent(h, "MoveToFinished"), false)
				else
					dir = flat.Unit
				end
			else
				local md = rawget(h, "_moveDir")
				if md and md.Magnitude > 1e-3 then
					dir = v3(md.X, 0, md.Z)
					if dir.Magnitude > 1 then
						dir = dir.Unit
					end
				end
			end
			local speed = raw(h, "WalkSpeed")
			local step = dir * speed * dt
			if target then
				local remaining = v3(target.pos.X - pos.X, 0, target.pos.Z - pos.Z).Magnitude
				if step.Magnitude > remaining then
					step = dir * remaining
				end
			end
			local params = T.RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			-- Characters don't stand on each other here (the engine would push them apart).
			local exclude = { character }
			for other in humanoids do
				local model = rawget(other, "_parent")
				if model and model ~= character then
					table.insert(exclude, model)
				end
			end
			params.FilterDescendantsInstances = exclude
			params.RespectCanCollide = true
			local rootHalf = raw(root, "Size").Y / 2
			local hip = raw(h, "HipHeight")
			local function groundAt(p)
				local hit = M.raycast(p + v3(0, 4, 0), v3(0, -400, 0), params)
				return hit
			end
			local nextPos = pos + step
			local hit = groundAt(nextPos)
			local vy = rawget(h, "_vy") or 0
			local standY = if hit then hit.Position.Y + hip + rootHalf else -huge
			if hit and step.Magnitude > 0 then
				-- Too steep to walk up (cliff / wall): stay put horizontally.
				local rise = standY - pos.Y
				local slope = math.deg(math.acos(math.clamp(hit.Normal.Y, -1, 1)))
				if rise > 2.5 and slope > raw(h, "MaxSlopeAngle") then
					nextPos = pos
					hit = groundAt(pos)
					standY = if hit then hit.Position.Y + hip + rootHalf else -huge
				end
			end
			local grounded = pos.Y <= standY + 0.6 and vy <= 0
			if grounded and math.abs(pos.Y - standY) < 0.01 then
				standY = pos.Y -- settled: don't re-snap by float noise every frame
			end
			local wantJump = raw(h, "Jump") or rawget(h, "_wantJump")
			if wantJump then
				rawset(h, "_wantJump", nil)
				if raw(h, "Jump") then
					M.store(h, "Jump", false)
				end
				if grounded and raw(h, "JumpHeight") > 0 and not (rawget(h, "_disabledStates") or {})[HS.Jumping] then
					local g = raw(M.workspace, "Gravity")
					vy = sqrt(2 * g * raw(h, "JumpHeight"))
					grounded = false
					M.setHumanoidState(h, HS.Jumping)
					M.fire(M.getEvent(h, "Jumping"), true)
				end
			end
			local y
			if grounded then
				y = standY
				vy = 0
				local state = rawget(h, "_state")
				if state == HS.Freefall or state == HS.Jumping then
					M.setHumanoidState(h, HS.Landed)
				end
				M.setHumanoidState(h, HS.Running)
			else
				local g = raw(M.workspace, "Gravity")
				vy -= g * dt
				y = pos.Y + vy * dt
				if y <= standY then
					y = standY
					vy = 0
					M.setHumanoidState(h, HS.Landed)
					M.setHumanoidState(h, HS.Running)
				elseif vy < 0 then
					M.setHumanoidState(h, HS.Freefall)
				end
			end
			rawset(h, "_vy", vy)
			local newPos = v3(nextPos.X, y, nextPos.Z)
			local rot = cfr.Rotation
			if dir.Magnitude > 0 and raw(h, "AutoRotate") then
				rot = T.CFrame.lookAt(v3(0, 0, 0), dir)
			end
			local newCF = rot + newPos
			local moved = (newPos - pos).Magnitude > 1e-4 or not rot:FuzzyEq(cfr.Rotation, 1e-6)
			if moved then
				M.engineMoveAssembly(root, newCF, asm)
			end
			M.storeShared(root, "AssemblyLinearVelocity", (newPos - pos) / dt)
			M.storeShared(h, "MoveDirection", dir)
			M.storeShared(h, "FloorMaterial", if grounded and hit then hit.Material else Enum.Material.Air)
			-- Fell out of the world.
			if y < raw(M.workspace, "FallenPartsDestroyHeight") then
				h.Health = 0
			end
		end)
		S.current = prev
		if not ok then
			S.report("mock humanoid controller: " .. tostring(err), nil, M.serverCtx)
		end
	end

	function M.engineMoveAssembly(root, newCF, asm)
		local old = raw(root, "CFrame")
		local delta = newCF * old:Inverse()
		for _, q in asm or M.assembly(root) do
			if q == root then
				engineSetCFrame(q, newCF)
			else
				engineSetCFrame(q, delta * raw(q, "CFrame"))
			end
		end
	end

	-- Loose parts: unanchored, unjointed parts outside characters fly ballistically (gravity +
	-- velocity), slide/stop on whatever is below them, and fire Touched/TouchEnded against
	-- character parts they overlap. A crude stand-in for the physics engine so code that
	-- launches parts (rockfall) and listens to Touched runs; not a rigid-body simulation.
	local loose: { [any]: boolean } = {}
	local touching: { [any]: { [any]: boolean } } = {}
	M.loose = loose
	local function considerLoose(part)
		if rawget(part, "_inWs") and part._cls.isa.BasePart and part._cls.name ~= "Terrain" and not raw(part, "Anchored") and not rawget(part, "_joints") then
			loose[part] = true
		else
			loose[part] = nil
		end
	end
	M.considerLoose = considerLoose
	classes.BasePart.props.Anchored.set = function(self, v)
		M.store(self, "Anchored", v)
		considerLoose(self)
	end
	local function characterOf(part)
		local node = rawget(part, "_parent")
		while node do
			if node._cls.name == "Model" and M.findChild(node, "Humanoid") then
				return node
			end
			node = rawget(node, "_parent")
		end
		return nil
	end
	local function stepLoose(part, dt)
		if rawget(part, "_destroyed") or not rawget(part, "_inWs") or raw(part, "Anchored") or rawget(part, "_joints") then
			loose[part] = nil
			return
		end
		if characterOf(part) then
			loose[part] = nil
			return
		end
		local cfr = raw(part, "CFrame")
		local pos = cfr.Position
		local vel = raw(part, "AssemblyLinearVelocity")
		local size = raw(part, "Size")
		local radius = math.min(size.X, size.Y, size.Z) / 2
		if rawget(part, "_asleep") and vel.Magnitude < 1e-3 then
			return
		end
		rawset(part, "_asleep", nil)
		local g = raw(M.workspace, "Gravity")
		vel = vel - v3(0, g * dt, 0)
		local move = vel * dt
		local params = T.RaycastParams.new()
		local exclude = { part }
		for h in humanoids do
			local model = rawget(h, "_parent")
			if model then
				table.insert(exclude, model)
			end
		end
		params.FilterDescendantsInstances = exclude
		params.RespectCanCollide = true
		local probe = move + (if move.Magnitude > 1e-6 then move.Unit * radius else v3(0, -radius, 0))
		local hit = M.raycast(pos, probe, params)
		local newPos
		if hit then
			newPos = hit.Position + hit.Normal * radius
			-- Remove the normal component, keep sliding along the surface with some friction.
			local n = hit.Normal
			vel = (vel - n * vel:Dot(n)) * 0.9
			if vel.Magnitude < 0.5 then
				vel = v3(0, 0, 0)
				rawset(part, "_asleep", true)
			end
		else
			newPos = pos + move
		end
		engineSetCFrame(part, cfr.Rotation + newPos)
		M.storeShared(part, "AssemblyLinearVelocity", vel)
		if newPos.Y < raw(M.workspace, "FallenPartsDestroyHeight") then
			loose[part] = nil
			part:Destroy()
			return
		end
		-- Touched against character parts.
		if not raw(part, "CanTouch") then
			return
		end
		local now = {}
		for h in humanoids do
			local model = rawget(h, "_parent")
			if model then
				for _, other in M.descendantsRaw(model, {}) do
					if other._cls.isa.BasePart and raw(other, "CanTouch") then
						local x0, y0, z0, x1, y1, z1 = partAABB(other)
						local cx = math.clamp(newPos.X, x0, x1)
						local cy = math.clamp(newPos.Y, y0, y1)
						local cz = math.clamp(newPos.Z, z0, z1)
						local dx, dy, dz = newPos.X - cx, newPos.Y - cy, newPos.Z - cz
						if dx * dx + dy * dy + dz * dz <= radius * radius then
							now[other] = true
						end
					end
				end
			end
		end
		local before = touching[part] or {}
		for other in now do
			if not before[other] then
				M.fire(M.getEvent(part, "Touched"), other)
				M.fire(M.getEvent(other, "Touched"), part)
			end
		end
		for other in before do
			if not now[other] then
				M.fire(M.getEvent(part, "TouchEnded"), other)
				M.fire(M.getEvent(other, "TouchEnded"), part)
			end
		end
		touching[part] = if next(now) then now else nil
	end

	table.insert(S.frameHooks, function(dt)
		for h in humanoids do
			stepHumanoid(h, dt)
		end
		local prev = S.current
		S.current = M.serverCtx
		for part in table.clone(loose) do
			local ok, err = pcall(stepLoose, part, dt)
			if not ok then
				S.report("mock loose-part physics: " .. tostring(err), nil, M.serverCtx)
				loose[part] = nil
			end
		end
		S.current = prev
	end)

	-- Camera helpers -------------------------------------------------------------------------------
	function M.cameraRay(cam, x, y, depth)
		local c = raw(cam, "CFrame")
		local vp = raw(cam, "ViewportSize")
		local fov = math.rad(raw(cam, "FieldOfView"))
		local h = math.tan(fov / 2)
		local aspect = vp.X / vp.Y
		local nx = (x / vp.X * 2 - 1) * h * aspect
		local ny = (1 - y / vp.Y * 2) * h
		local d = M.vectorToWorld(c, v3(nx, ny, -1)).Unit
		local o = c.Position + d * (depth or 0)
		return T.Ray.new(o, d)
	end
	function M.cameraProject(cam, p)
		local c = raw(cam, "CFrame")
		local vp = raw(cam, "ViewportSize")
		local fov = math.rad(raw(cam, "FieldOfView"))
		local h = math.tan(fov / 2)
		local aspect = vp.X / vp.Y
		local l = c:PointToObjectSpace(p)
		local depth = -l.Z
		if depth <= 1e-6 then
			return v3(0, 0, depth), false
		end
		local sx = (l.X / depth / (h * aspect) + 1) / 2 * vp.X
		local sy = (1 - l.Y / depth / h) / 2 * vp.Y
		local on = sx >= 0 and sx <= vp.X and sy >= 0 and sy <= vp.Y
		return v3(sx, sy, depth), on
	end

	-- GUI geometry (approximate: no layouts, 1920x1080 screen) ---------------------------------------
	local SCREEN = T.Vector2.new(1920, 1080)
	function M.guiAbsoluteSize(gui)
		local cls = gui._cls
		if cls.name == "ScreenGui" then
			return if raw(gui, "IgnoreGuiInset") then SCREEN else T.Vector2.new(1920, 1044)
		elseif cls.name == "BillboardGui" then
			local s = raw(gui, "Size")
			return T.Vector2.new(s.X.Offset + s.X.Scale * 100, s.Y.Offset + s.Y.Scale * 100)
		elseif cls.name == "SurfaceGui" then
			return raw(gui, "CanvasSize")
		elseif cls.isa.GuiObject then
			local parent = rawget(gui, "_parent")
			local ps = if parent and parent._cls.isa.GuiBase2d then M.guiAbsoluteSize(parent) else SCREEN
			local s = raw(gui, "Size")
			return T.Vector2.new(ps.X * s.X.Scale + s.X.Offset, ps.Y * s.Y.Scale + s.Y.Offset)
		end
		return SCREEN
	end
	function M.guiAbsolutePosition(gui)
		local cls = gui._cls
		if not cls.isa.GuiObject then
			return T.Vector2.zero
		end
		local parent = rawget(gui, "_parent")
		local pp = if parent and parent._cls.isa.GuiObject then M.guiAbsolutePosition(parent) else T.Vector2.zero
		local ps = if parent and parent._cls.isa.GuiBase2d then M.guiAbsoluteSize(parent) else SCREEN
		local p = raw(gui, "Position")
		local size = M.guiAbsoluteSize(gui)
		local anchor = raw(gui, "AnchorPoint")
		return T.Vector2.new(
			pp.X + ps.X * p.X.Scale + p.X.Offset - size.X * anchor.X,
			pp.Y + ps.Y * p.Y.Scale + p.Y.Offset - size.Y * anchor.Y
		)
	end
end
