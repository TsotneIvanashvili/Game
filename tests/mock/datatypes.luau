-- Roblox datatypes for the headless runtime (tests/mock). Plain Luau tables with metatables
-- that carry `__type`, so the mock's typeof() reports Roblox type names. Math follows the
-- engine: CFrame is a position plus a 3x3 rotation matrix (columns = right, up, back),
-- CFrame.Angles = Rx * Ry * Rz, Orientation = YXZ order in degrees.
--
-- Components are stored as raw fields (X/Y/Z, R/G/B, ...) for speed; that means writing
-- `v.X = 1` is not caught here (Luau's type checker catches it in src/ already).

return function(M)
	local sqrt, sin, cos, abs, atan2, asin, floor =
		math.sqrt, math.sin, math.cos, math.abs, math.atan2, math.asin, math.floor
	local fmt = string.format

	local function argError(fn: string, i: number, expected: string, got: any)
		error(fmt("invalid argument #%d to '%s' (%s expected, got %s)", i, fn, expected, M.typeof(got)), 3)
	end

	local function num(fn: string, i: number, v: any, default: number?): number
		if v == nil then
			if default ~= nil then
				return default
			end
			argError(fn, i, "number", v)
		end
		local t = type(v)
		if t == "number" then
			return v
		elseif t == "string" and tonumber(v) then
			return tonumber(v) :: number
		end
		argError(fn, i, "number", v)
		return 0
	end

	local function invalidMember(typeName: string, key: any)
		error(fmt("%s is not a valid member of %s", tostring(key), typeName), 3)
	end

	-- Vector3 ------------------------------------------------------------------------------
	local V3 = { __type = "Vector3" }
	local V3m = {}
	local function v3(x: number, y: number, z: number)
		return setmetatable({ X = x, Y = y, Z = z }, V3)
	end
	local function isV3(v)
		return type(v) == "table" and getmetatable(v) == V3
	end
	M.isVector3 = isV3
	V3.__index = function(v, k)
		local m = V3m[k]
		if m then
			return m
		end
		if k == "Magnitude" then
			return sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		elseif k == "Unit" then
			local m2 = sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
			return v3(v.X / m2, v.Y / m2, v.Z / m2) -- zero vector -> NaN, like the engine
		end
		invalidMember("Vector3", k)
		return nil
	end
	V3.__newindex = function(_, k)
		error(tostring(k) .. " cannot be assigned to", 2)
	end
	local function arith(op: string, a, b)
		error(fmt("attempt to perform arithmetic (%s) on %s and %s", op, M.typeof(a), M.typeof(b)), 3)
	end
	V3.__add = function(a, b)
		if isV3(a) and isV3(b) then
			return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
		end
		arith("add", a, b)
		return nil
	end
	V3.__sub = function(a, b)
		if isV3(a) and isV3(b) then
			return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
		end
		arith("sub", a, b)
		return nil
	end
	V3.__mul = function(a, b)
		if type(a) == "number" and isV3(b) then
			return v3(a * b.X, a * b.Y, a * b.Z)
		elseif isV3(a) and type(b) == "number" then
			return v3(a.X * b, a.Y * b, a.Z * b)
		elseif isV3(a) and isV3(b) then
			return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
		end
		arith("mul", a, b)
		return nil
	end
	V3.__div = function(a, b)
		if isV3(a) and type(b) == "number" then
			return v3(a.X / b, a.Y / b, a.Z / b)
		elseif isV3(a) and isV3(b) then
			return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
		elseif type(a) == "number" and isV3(b) then
			return v3(a / b.X, a / b.Y, a / b.Z)
		end
		arith("div", a, b)
		return nil
	end
	V3.__idiv = function(a, b)
		if isV3(a) and type(b) == "number" then
			return v3(a.X // b, a.Y // b, a.Z // b)
		elseif isV3(a) and isV3(b) then
			return v3(a.X // b.X, a.Y // b.Y, a.Z // b.Z)
		end
		arith("idiv", a, b)
		return nil
	end
	V3.__unm = function(a)
		return v3(-a.X, -a.Y, -a.Z)
	end
	V3.__eq = function(a, b)
		return isV3(a) and isV3(b) and a.X == b.X and a.Y == b.Y and a.Z == b.Z
	end
	V3.__tostring = function(a)
		return fmt("%g, %g, %g", a.X, a.Y, a.Z)
	end
	local function needV3(fn: string, i: number, v)
		if not isV3(v) then
			argError(fn, i, "Vector3", v)
		end
	end
	function V3m.Dot(a, b)
		needV3("Dot", 1, b)
		return a.X * b.X + a.Y * b.Y + a.Z * b.Z
	end
	function V3m.Cross(a, b)
		needV3("Cross", 1, b)
		return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
	end
	function V3m.Lerp(a, b, t)
		needV3("Lerp", 1, b)
		t = num("Lerp", 2, t)
		return v3(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
	end
	function V3m.FuzzyEq(a, b, eps)
		needV3("FuzzyEq", 1, b)
		eps = eps or 1e-5
		return abs(a.X - b.X) <= eps and abs(a.Y - b.Y) <= eps and abs(a.Z - b.Z) <= eps
	end
	function V3m.Abs(a)
		return v3(abs(a.X), abs(a.Y), abs(a.Z))
	end
	function V3m.Floor(a)
		return v3(floor(a.X), floor(a.Y), floor(a.Z))
	end
	function V3m.Ceil(a)
		return v3(math.ceil(a.X), math.ceil(a.Y), math.ceil(a.Z))
	end
	function V3m.Sign(a)
		return v3(math.sign(a.X), math.sign(a.Y), math.sign(a.Z))
	end
	function V3m.Min(a, ...)
		local x, y, z = a.X, a.Y, a.Z
		for i, b in { ... } do
			needV3("Min", i, b)
			x, y, z = math.min(x, b.X), math.min(y, b.Y), math.min(z, b.Z)
		end
		return v3(x, y, z)
	end
	function V3m.Max(a, ...)
		local x, y, z = a.X, a.Y, a.Z
		for i, b in { ... } do
			needV3("Max", i, b)
			x, y, z = math.max(x, b.X), math.max(y, b.Y), math.max(z, b.Z)
		end
		return v3(x, y, z)
	end
	function V3m.Angle(a, b, axis)
		needV3("Angle", 1, b)
		local c = a:Cross(b)
		local angle = atan2(c.Magnitude, a:Dot(b))
		if axis and c:Dot(axis) < 0 then
			angle = -angle
		end
		return angle
	end
	local Vector3 = {
		new = function(x, y, z)
			return v3(num("Vector3.new", 1, x, 0), num("Vector3.new", 2, y, 0), num("Vector3.new", 3, z, 0))
		end,
		zero = v3(0, 0, 0),
		one = v3(1, 1, 1),
		xAxis = v3(1, 0, 0),
		yAxis = v3(0, 1, 0),
		zAxis = v3(0, 0, 1),
	}
	M.v3 = v3
	M.types = {}
	M.types.Vector3 = Vector3

	-- Vector2 ------------------------------------------------------------------------------
	local V2 = { __type = "Vector2" }
	local V2m = {}
	local function v2(x: number, y: number)
		return setmetatable({ X = x, Y = y }, V2)
	end
	local function isV2(v)
		return type(v) == "table" and getmetatable(v) == V2
	end
	V2.__index = function(v, k)
		local m = V2m[k]
		if m then
			return m
		end
		if k == "Magnitude" then
			return sqrt(v.X * v.X + v.Y * v.Y)
		elseif k == "Unit" then
			local m2 = sqrt(v.X * v.X + v.Y * v.Y)
			return v2(v.X / m2, v.Y / m2)
		end
		invalidMember("Vector2", k)
		return nil
	end
	V2.__add = function(a, b)
		if isV2(a) and isV2(b) then
			return v2(a.X + b.X, a.Y + b.Y)
		end
		arith("add", a, b)
		return nil
	end
	V2.__sub = function(a, b)
		if isV2(a) and isV2(b) then
			return v2(a.X - b.X, a.Y - b.Y)
		end
		arith("sub", a, b)
		return nil
	end
	V2.__mul = function(a, b)
		if type(a) == "number" and isV2(b) then
			return v2(a * b.X, a * b.Y)
		elseif isV2(a) and type(b) == "number" then
			return v2(a.X * b, a.Y * b)
		elseif isV2(a) and isV2(b) then
			return v2(a.X * b.X, a.Y * b.Y)
		end
		arith("mul", a, b)
		return nil
	end
	V2.__div = function(a, b)
		if isV2(a) and type(b) == "number" then
			return v2(a.X / b, a.Y / b)
		elseif isV2(a) and isV2(b) then
			return v2(a.X / b.X, a.Y / b.Y)
		end
		arith("div", a, b)
		return nil
	end
	V2.__unm = function(a)
		return v2(-a.X, -a.Y)
	end
	V2.__eq = function(a, b)
		return isV2(a) and isV2(b) and a.X == b.X and a.Y == b.Y
	end
	V2.__tostring = function(a)
		return fmt("%g, %g", a.X, a.Y)
	end
	function V2m.Dot(a, b)
		return a.X * b.X + a.Y * b.Y
	end
	function V2m.Cross(a, b)
		return a.X * b.Y - a.Y * b.X
	end
	function V2m.Lerp(a, b, t)
		return v2(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t)
	end
	function V2m.FuzzyEq(a, b, eps)
		eps = eps or 1e-5
		return abs(a.X - b.X) <= eps and abs(a.Y - b.Y) <= eps
	end
	function V2m.Abs(a)
		return v2(abs(a.X), abs(a.Y))
	end
	function V2m.Min(a, b)
		return v2(math.min(a.X, b.X), math.min(a.Y, b.Y))
	end
	function V2m.Max(a, b)
		return v2(math.max(a.X, b.X), math.max(a.Y, b.Y))
	end
	M.types.Vector2 = {
		new = function(x, y)
			return v2(num("Vector2.new", 1, x, 0), num("Vector2.new", 2, y, 0))
		end,
		zero = v2(0, 0),
		one = v2(1, 1),
		xAxis = v2(1, 0),
		yAxis = v2(0, 1),
	}
	M.v2 = v2

	-- CFrame -------------------------------------------------------------------------------
	-- Raw fields: X, Y, Z position and [1..9] = R00 R01 R02 R10 R11 R12 R20 R21 R22.
	local CF = { __type = "CFrame" }
	local CFm = {}
	local function cf(x, y, z, a, b, c, d, e, f, g, h, i)
		-- selene: allow(mixed_table)
		return setmetatable({ X = x, Y = y, Z = z, a, b, c, d, e, f, g, h, i }, CF)
	end
	local function isCF(v)
		return type(v) == "table" and getmetatable(v) == CF
	end
	M.isCFrame = isCF
	-- Re-orthonormalize a rotation given its right and up columns (keeps right exact-ish).
	local function fromColumns(px, py, pz, rx, ry, rz, ux, uy, uz, bx, by, bz)
		return cf(px, py, pz, rx, ux, bx, ry, uy, by, rz, uz, bz)
	end
	CF.__index = function(c, k)
		local m = CFm[k]
		if m then
			return m
		end
		if k == "Position" or k == "p" then
			return v3(c.X, c.Y, c.Z)
		elseif k == "LookVector" or k == "lookVector" then
			return v3(-c[3], -c[6], -c[9])
		elseif k == "RightVector" or k == "XVector" or k == "rightVector" then
			return v3(c[1], c[4], c[7])
		elseif k == "UpVector" or k == "YVector" or k == "upVector" then
			return v3(c[2], c[5], c[8])
		elseif k == "ZVector" then
			return v3(c[3], c[6], c[9])
		elseif k == "Rotation" then
			return cf(0, 0, 0, c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9])
		end
		invalidMember("CFrame", k)
		return nil
	end
	CF.__newindex = function(_, k)
		error(tostring(k) .. " cannot be assigned to", 2)
	end
	local function mulCF(a, b)
		local a1, a2, a3, a4, a5, a6, a7, a8, a9 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]
		local b1, b2, b3, b4, b5, b6, b7, b8, b9 = b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9]
		return cf(
			a.X + a1 * b.X + a2 * b.Y + a3 * b.Z,
			a.Y + a4 * b.X + a5 * b.Y + a6 * b.Z,
			a.Z + a7 * b.X + a8 * b.Y + a9 * b.Z,
			a1 * b1 + a2 * b4 + a3 * b7,
			a1 * b2 + a2 * b5 + a3 * b8,
			a1 * b3 + a2 * b6 + a3 * b9,
			a4 * b1 + a5 * b4 + a6 * b7,
			a4 * b2 + a5 * b5 + a6 * b8,
			a4 * b3 + a5 * b6 + a6 * b9,
			a7 * b1 + a8 * b4 + a9 * b7,
			a7 * b2 + a8 * b5 + a9 * b8,
			a7 * b3 + a8 * b6 + a9 * b9
		)
	end
	local function pointToWorld(c, v)
		return v3(
			c.X + c[1] * v.X + c[2] * v.Y + c[3] * v.Z,
			c.Y + c[4] * v.X + c[5] * v.Y + c[6] * v.Z,
			c.Z + c[7] * v.X + c[8] * v.Y + c[9] * v.Z
		)
	end
	local function vectorToWorld(c, v)
		return v3(
			c[1] * v.X + c[2] * v.Y + c[3] * v.Z,
			c[4] * v.X + c[5] * v.Y + c[6] * v.Z,
			c[7] * v.X + c[8] * v.Y + c[9] * v.Z
		)
	end
	local function vectorToObject(c, v)
		return v3(
			c[1] * v.X + c[4] * v.Y + c[7] * v.Z,
			c[2] * v.X + c[5] * v.Y + c[8] * v.Z,
			c[3] * v.X + c[6] * v.Y + c[9] * v.Z
		)
	end
	local function inverse(c)
		-- Rotation is orthonormal: inverse = transpose.
		local x, y, z = c.X, c.Y, c.Z
		return cf(
			-(c[1] * x + c[4] * y + c[7] * z),
			-(c[2] * x + c[5] * y + c[8] * z),
			-(c[3] * x + c[6] * y + c[9] * z),
			c[1],
			c[4],
			c[7],
			c[2],
			c[5],
			c[8],
			c[3],
			c[6],
			c[9]
		)
	end
	CF.__mul = function(a, b)
		if isCF(a) and isCF(b) then
			return mulCF(a, b)
		elseif isCF(a) and isV3(b) then
			return pointToWorld(a, b)
		end
		arith("mul", a, b)
		return nil
	end
	CF.__add = function(a, b)
		if isCF(a) and isV3(b) then
			return cf(a.X + b.X, a.Y + b.Y, a.Z + b.Z, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9])
		end
		arith("add", a, b)
		return nil
	end
	CF.__sub = function(a, b)
		if isCF(a) and isV3(b) then
			return cf(a.X - b.X, a.Y - b.Y, a.Z - b.Z, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9])
		end
		arith("sub", a, b)
		return nil
	end
	CF.__eq = function(a, b)
		if not (isCF(a) and isCF(b)) then
			return false
		end
		if a.X ~= b.X or a.Y ~= b.Y or a.Z ~= b.Z then
			return false
		end
		for i = 1, 9 do
			if a[i] ~= b[i] then
				return false
			end
		end
		return true
	end
	CF.__tostring = function(c)
		return fmt(
			"%g, %g, %g, %g, %g, %g, %g, %g, %g, %g, %g, %g",
			c.X,
			c.Y,
			c.Z,
			c[1],
			c[2],
			c[3],
			c[4],
			c[5],
			c[6],
			c[7],
			c[8],
			c[9]
		)
	end
	local function needCF(fn: string, i: number, v)
		if not isCF(v) then
			argError(fn, i, "CFrame", v)
		end
	end
	function CFm.Inverse(c)
		return inverse(c)
	end
	function CFm.ToWorldSpace(a, ...)
		local out = {}
		for i, b in { ... } do
			needCF("ToWorldSpace", i, b)
			out[i] = mulCF(a, b)
		end
		return table.unpack(out)
	end
	function CFm.ToObjectSpace(a, ...)
		local inv = inverse(a)
		local out = {}
		for i, b in { ... } do
			needCF("ToObjectSpace", i, b)
			out[i] = mulCF(inv, b)
		end
		return table.unpack(out)
	end
	function CFm.PointToWorldSpace(a, ...)
		local out = {}
		for i, v in { ... } do
			needV3("PointToWorldSpace", i, v)
			out[i] = pointToWorld(a, v)
		end
		return table.unpack(out)
	end
	function CFm.PointToObjectSpace(a, ...)
		local out = {}
		for i, v in { ... } do
			needV3("PointToObjectSpace", i, v)
			out[i] = vectorToObject(a, v3(v.X - a.X, v.Y - a.Y, v.Z - a.Z))
		end
		return table.unpack(out)
	end
	function CFm.VectorToWorldSpace(a, ...)
		local out = {}
		for i, v in { ... } do
			needV3("VectorToWorldSpace", i, v)
			out[i] = vectorToWorld(a, v)
		end
		return table.unpack(out)
	end
	function CFm.VectorToObjectSpace(a, ...)
		local out = {}
		for i, v in { ... } do
			needV3("VectorToObjectSpace", i, v)
			out[i] = vectorToObject(a, v)
		end
		return table.unpack(out)
	end
	function CFm.GetComponents(c)
		return c.X, c.Y, c.Z, c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9]
	end
	CFm.components = CFm.GetComponents
	function CFm.ToEulerAnglesXYZ(c)
		local y = asin(math.clamp(c[3], -1, 1))
		local x = atan2(-c[6], c[9])
		local z = atan2(-c[2], c[1])
		return x, y, z
	end
	CFm.toEulerAnglesXYZ = CFm.ToEulerAnglesXYZ
	function CFm.ToEulerAnglesYXZ(c)
		local x = asin(math.clamp(-c[6], -1, 1))
		local y = atan2(c[3], c[9])
		local z = atan2(c[4], c[5])
		return x, y, z
	end
	CFm.ToOrientation = CFm.ToEulerAnglesYXZ
	-- Quaternion helpers (for Lerp / axis-angle).
	local function toQuat(c)
		local m00, m01, m02, m10, m11, m12, m20, m21, m22 = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9]
		local tr = m00 + m11 + m22
		local qw, qx, qy, qz
		if tr > 0 then
			local s = sqrt(tr + 1) * 2
			qw, qx, qy, qz = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
		elseif m00 > m11 and m00 > m22 then
			local s = sqrt(1 + m00 - m11 - m22) * 2
			qw, qx, qy, qz = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
		elseif m11 > m22 then
			local s = sqrt(1 + m11 - m00 - m22) * 2
			qw, qx, qy, qz = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
		else
			local s = sqrt(1 + m22 - m00 - m11) * 2
			qw, qx, qy, qz = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
		end
		return qx, qy, qz, qw
	end
	local function fromQuat(px, py, pz, qx, qy, qz, qw)
		local n = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
		if n == 0 then
			return cf(px, py, pz, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		end
		qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
		return cf(
			px,
			py,
			pz,
			1 - 2 * (qy * qy + qz * qz),
			2 * (qx * qy - qz * qw),
			2 * (qx * qz + qy * qw),
			2 * (qx * qy + qz * qw),
			1 - 2 * (qx * qx + qz * qz),
			2 * (qy * qz - qx * qw),
			2 * (qx * qz - qy * qw),
			2 * (qy * qz + qx * qw),
			1 - 2 * (qx * qx + qy * qy)
		)
	end
	function CFm.Lerp(a, b, t)
		needCF("Lerp", 1, b)
		t = num("Lerp", 2, t)
		local ax, ay, az, aw = toQuat(a)
		local bx, by, bz, bw = toQuat(b)
		local d = ax * bx + ay * by + az * bz + aw * bw
		if d < 0 then
			bx, by, bz, bw, d = -bx, -by, -bz, -bw, -d
		end
		local s0, s1
		if d > 0.9995 then
			s0, s1 = 1 - t, t
		else
			local theta = math.acos(d)
			local st = sin(theta)
			s0, s1 = sin((1 - t) * theta) / st, sin(t * theta) / st
		end
		return fromQuat(
			a.X + (b.X - a.X) * t,
			a.Y + (b.Y - a.Y) * t,
			a.Z + (b.Z - a.Z) * t,
			ax * s0 + bx * s1,
			ay * s0 + by * s1,
			az * s0 + bz * s1,
			aw * s0 + bw * s1
		)
	end
	function CFm.ToAxisAngle(c)
		local qx, qy, qz, qw = toQuat(c)
		local angle = 2 * math.acos(math.clamp(qw, -1, 1))
		local s = sqrt(math.max(0, 1 - qw * qw))
		if s < 1e-9 then
			return v3(1, 0, 0), 0
		end
		return v3(qx / s, qy / s, qz / s), angle
	end
	function CFm.FuzzyEq(a, b, eps)
		eps = eps or 1e-5
		local ca, cb = { a:GetComponents() }, { b:GetComponents() }
		for i = 1, 12 do
			if abs(ca[i] - cb[i]) > eps then
				return false
			end
		end
		return true
	end
	function CFm.Orthonormalize(c)
		local r = v3(c[1], c[4], c[7]).Unit
		local u = v3(c[2], c[5], c[8])
		local b = r:Cross(u).Unit
		u = b:Cross(r).Unit
		return fromColumns(c.X, c.Y, c.Z, r.X, r.Y, r.Z, u.X, u.Y, u.Z, b.X, b.Y, b.Z)
	end

	local function rotX(a)
		local c, s = cos(a), sin(a)
		return cf(0, 0, 0, 1, 0, 0, 0, c, -s, 0, s, c)
	end
	local function rotY(a)
		local c, s = cos(a), sin(a)
		return cf(0, 0, 0, c, 0, s, 0, 1, 0, -s, 0, c)
	end
	local function rotZ(a)
		local c, s = cos(a), sin(a)
		return cf(0, 0, 0, c, -s, 0, s, c, 0, 0, 0, 1)
	end
	local IDENTITY = cf(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)

	local function lookAt(at, target, up)
		up = up or v3(0, 1, 0)
		local look = target - at
		local m = look.Magnitude
		if m < 1e-9 then
			return cf(at.X, at.Y, at.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		end
		look = look / m
		local right = look:Cross(up)
		if right.Magnitude < 1e-6 then
			-- looking straight along `up`: pick any perpendicular right vector
			right = look:Cross(v3(0, 0, if look.Y > 0 then -1 else 1))
			if right.Magnitude < 1e-6 then
				right = v3(1, 0, 0)
			end
		end
		right = right.Unit
		local up2 = right:Cross(look).Unit
		return fromColumns(at.X, at.Y, at.Z, right.X, right.Y, right.Z, up2.X, up2.Y, up2.Z, -look.X, -look.Y, -look.Z)
	end

	local CFrame = {}
	function CFrame.new(...)
		local n = select("#", ...)
		local a, b = ...
		if n == 0 then
			return IDENTITY
		end
		if isV3(a) then
			if n == 1 or b == nil then
				return cf(a.X, a.Y, a.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
			end
			needV3("CFrame.new", 2, b)
			return lookAt(a, b)
		end
		local args = { ... }
		for i = 1, n do
			args[i] = num("CFrame.new", i, args[i])
		end
		if n == 3 then
			return cf(args[1], args[2], args[3], 1, 0, 0, 0, 1, 0, 0, 0, 1)
		elseif n == 7 then
			return fromQuat(args[1], args[2], args[3], args[4], args[5], args[6], args[7])
		elseif n == 12 then
			return cf(table.unpack(args, 1, 12))
		end
		error("Invalid number of arguments: " .. n, 2)
		return nil
	end
	function CFrame.lookAt(at, target, up)
		needV3("CFrame.lookAt", 1, at)
		needV3("CFrame.lookAt", 2, target)
		if up ~= nil then
			needV3("CFrame.lookAt", 3, up)
		end
		return lookAt(at, target, up)
	end
	function CFrame.lookAlong(at, direction, up)
		needV3("CFrame.lookAlong", 1, at)
		needV3("CFrame.lookAlong", 2, direction)
		return lookAt(at, at + direction, up)
	end
	function CFrame.Angles(rx, ry, rz)
		rx, ry, rz = num("CFrame.Angles", 1, rx, 0), num("CFrame.Angles", 2, ry, 0), num("CFrame.Angles", 3, rz, 0)
		return mulCF(mulCF(rotX(rx), rotY(ry)), rotZ(rz))
	end
	CFrame.fromEulerAnglesXYZ = CFrame.Angles
	function CFrame.fromEulerAnglesYXZ(rx, ry, rz)
		rx, ry, rz =
			num("CFrame.fromEulerAnglesYXZ", 1, rx, 0),
			num("fromEulerAnglesYXZ", 2, ry, 0),
			num("fromEulerAnglesYXZ", 3, rz, 0)
		return mulCF(mulCF(rotY(ry), rotX(rx)), rotZ(rz))
	end
	CFrame.fromOrientation = CFrame.fromEulerAnglesYXZ
	function CFrame.fromEulerAngles(rx, ry, rz, order)
		if order == nil or order == M.Enum.RotationOrder.XYZ then
			return CFrame.Angles(rx, ry, rz)
		end
		return CFrame.fromEulerAnglesYXZ(rx, ry, rz)
	end
	function CFrame.fromMatrix(pos, vx, vy, vz)
		needV3("CFrame.fromMatrix", 1, pos)
		needV3("CFrame.fromMatrix", 2, vx)
		needV3("CFrame.fromMatrix", 3, vy)
		if vz == nil then
			vz = vx:Cross(vy).Unit
		else
			needV3("CFrame.fromMatrix", 4, vz)
		end
		return fromColumns(pos.X, pos.Y, pos.Z, vx.X, vx.Y, vx.Z, vy.X, vy.Y, vy.Z, vz.X, vz.Y, vz.Z)
	end
	function CFrame.fromAxisAngle(axis, angle)
		needV3("CFrame.fromAxisAngle", 1, axis)
		local u = axis.Unit
		local h = num("CFrame.fromAxisAngle", 2, angle) / 2
		local s = sin(h)
		return fromQuat(0, 0, 0, u.X * s, u.Y * s, u.Z * s, cos(h))
	end
	CFrame.identity = IDENTITY
	M.types.CFrame = CFrame
	M.cf = cf

	-- Color3 -------------------------------------------------------------------------------
	local C3 = { __type = "Color3" }
	local C3m = {}
	local function c3(r, g, b)
		return setmetatable({ R = r, G = g, B = b }, C3)
	end
	local function isC3(v)
		return type(v) == "table" and getmetatable(v) == C3
	end
	C3.__index = function(_, k)
		local m = C3m[k]
		if m then
			return m
		end
		invalidMember("Color3", k)
		return nil
	end
	C3.__eq = function(a, b)
		return isC3(a) and isC3(b) and a.R == b.R and a.G == b.G and a.B == b.B
	end
	C3.__tostring = function(c)
		return fmt("%g, %g, %g", c.R, c.G, c.B)
	end
	function C3m.Lerp(a, b, t)
		if not isC3(b) then
			argError("Lerp", 1, "Color3", b)
		end
		t = num("Lerp", 2, t)
		return c3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
	end
	function C3m.ToHSV(c)
		local r, g, b = c.R, c.G, c.B
		local mx, mn = math.max(r, g, b), math.min(r, g, b)
		local d = mx - mn
		local h = 0
		if d > 0 then
			if mx == r then
				h = ((g - b) / d) % 6
			elseif mx == g then
				h = (b - r) / d + 2
			else
				h = (r - g) / d + 4
			end
			h /= 6
		end
		return h, if mx == 0 then 0 else d / mx, mx
	end
	function C3m.ToHex(c)
		local function byte(x)
			return math.clamp(floor(x * 255 + 0.5), 0, 255)
		end
		return fmt("%02X%02X%02X", byte(c.R), byte(c.G), byte(c.B))
	end
	local function hsv(h, s, v)
		h = (h % 1) * 6
		local i = floor(h)
		local f = h - i
		local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
		if i == 0 then
			return c3(v, t, p)
		elseif i == 1 then
			return c3(q, v, p)
		elseif i == 2 then
			return c3(p, v, t)
		elseif i == 3 then
			return c3(p, q, v)
		elseif i == 4 then
			return c3(t, p, v)
		end
		return c3(v, p, q)
	end
	local Color3 = {
		new = function(r, g, b)
			return c3(num("Color3.new", 1, r, 0), num("Color3.new", 2, g, 0), num("Color3.new", 3, b, 0))
		end,
		fromRGB = function(r, g, b)
			return c3(
				num("Color3.fromRGB", 1, r, 0) / 255,
				num("Color3.fromRGB", 2, g, 0) / 255,
				num("Color3.fromRGB", 3, b, 0) / 255
			)
		end,
		fromHSV = function(h, s, v)
			return hsv(num("Color3.fromHSV", 1, h), num("Color3.fromHSV", 2, s), num("Color3.fromHSV", 3, v))
		end,
		toHSV = function(c)
			return C3m.ToHSV(c)
		end,
		fromHex = function(hex)
			hex = string.gsub(tostring(hex), "#", "")
			return c3(
				(tonumber(hex:sub(1, 2), 16) or 0) / 255,
				(tonumber(hex:sub(3, 4), 16) or 0) / 255,
				(tonumber(hex:sub(5, 6), 16) or 0) / 255
			)
		end,
	}
	M.types.Color3 = Color3
	M.c3 = c3

	-- UDim / UDim2 -------------------------------------------------------------------------
	local UD = { __type = "UDim" }
	local function udim(s, o)
		return setmetatable({ Scale = s, Offset = o }, UD)
	end
	UD.__index = function(_, k)
		invalidMember("UDim", k)
	end
	UD.__eq = function(a, b)
		return a.Scale == b.Scale and a.Offset == b.Offset
	end
	UD.__add = function(a, b)
		return udim(a.Scale + b.Scale, a.Offset + b.Offset)
	end
	UD.__sub = function(a, b)
		return udim(a.Scale - b.Scale, a.Offset - b.Offset)
	end
	UD.__unm = function(a)
		return udim(-a.Scale, -a.Offset)
	end
	UD.__tostring = function(a)
		return fmt("%g, %g", a.Scale, a.Offset)
	end
	M.types.UDim = {
		new = function(s, o)
			return udim(num("UDim.new", 1, s, 0), num("UDim.new", 2, o, 0))
		end,
	}
	local UD2 = { __type = "UDim2" }
	local UD2m = {}
	local function udim2(xs, xo, ys, yo)
		return setmetatable({ X = udim(xs, xo), Y = udim(ys, yo) }, UD2)
	end
	UD2.__index = function(u, k)
		local m = UD2m[k]
		if m then
			return m
		end
		if k == "Width" then
			return rawget(u, "X")
		elseif k == "Height" then
			return rawget(u, "Y")
		end
		invalidMember("UDim2", k)
		return nil
	end
	UD2.__eq = function(a, b)
		return a.X == b.X and a.Y == b.Y
	end
	UD2.__add = function(a, b)
		return udim2(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset)
	end
	UD2.__sub = function(a, b)
		return udim2(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset)
	end
	UD2.__unm = function(a)
		return udim2(-a.X.Scale, -a.X.Offset, -a.Y.Scale, -a.Y.Offset)
	end
	UD2.__tostring = function(a)
		return fmt("{%g, %g}, {%g, %g}", a.X.Scale, a.X.Offset, a.Y.Scale, a.Y.Offset)
	end
	function UD2m.Lerp(a, b, t)
		local function l(x, y)
			return x + (y - x) * t
		end
		return udim2(
			l(a.X.Scale, b.X.Scale),
			l(a.X.Offset, b.X.Offset),
			l(a.Y.Scale, b.Y.Scale),
			l(a.Y.Offset, b.Y.Offset)
		)
	end
	M.types.UDim2 = {
		new = function(xs, xo, ys, yo)
			if type(xs) == "table" and getmetatable(xs) == UD then
				local y = xo
				if type(y) ~= "table" or getmetatable(y) ~= UD then
					argError("UDim2.new", 2, "UDim", y)
				end
				return udim2(xs.Scale, xs.Offset, y.Scale, y.Offset)
			end
			return udim2(
				num("UDim2.new", 1, xs, 0),
				num("UDim2.new", 2, xo, 0),
				num("UDim2.new", 3, ys, 0),
				num("UDim2.new", 4, yo, 0)
			)
		end,
		fromScale = function(x, y)
			return udim2(num("UDim2.fromScale", 1, x, 0), 0, num("UDim2.fromScale", 2, y, 0), 0)
		end,
		fromOffset = function(x, y)
			return udim2(0, num("UDim2.fromOffset", 1, x, 0), 0, num("UDim2.fromOffset", 2, y, 0))
		end,
	}

	-- Simple value types ----------------------------------------------------------------------
	local function valueType(name: string, fields: { [string]: any }?, methods: { [string]: any }?)
		local mt = { __type = name }
		mt.__index = function(v, k)
			if methods and methods[k] then
				return methods[k]
			end
			if fields and fields[k] then
				return fields[k](v)
			end
			invalidMember(name, k)
			return nil
		end
		mt.__newindex = function(_, k)
			error(tostring(k) .. " cannot be assigned to", 2)
		end
		mt.__tostring = function()
			return name
		end
		return mt
	end

	local NR = valueType("NumberRange")
	NR.__eq = function(a, b)
		return a.Min == b.Min and a.Max == b.Max
	end
	M.types.NumberRange = {
		new = function(min, max)
			min = num("NumberRange.new", 1, min)
			max = num("NumberRange.new", 2, max, min)
			if max < min then
				error("NumberRange: invalid range", 2)
			end
			return setmetatable({ Min = min, Max = max }, NR)
		end,
	}

	local NSK = valueType("NumberSequenceKeypoint")
	M.types.NumberSequenceKeypoint = {
		new = function(t, v, e)
			return setmetatable({
				Time = num("NumberSequenceKeypoint.new", 1, t),
				Value = num("NumberSequenceKeypoint.new", 2, v),
				Envelope = e or 0,
			}, NSK)
		end,
	}
	local function checkKeypoints(kind: string, kps)
		if #kps < 2 then
			error(kind .. ": requires at least 2 keypoints", 3)
		end
		if kps[1].Time ~= 0 or kps[#kps].Time ~= 1 then
			error(kind .. ": NumberSequence time must start at 0 and end at 1", 3)
		end
		for i = 2, #kps do
			if kps[i].Time < kps[i - 1].Time then
				error(kind .. ": keypoints must be ordered by time", 3)
			end
		end
	end
	local NS = valueType("NumberSequence")
	M.types.NumberSequence = {
		new = function(a, b)
			local kps
			if type(a) == "number" then
				b = if b == nil then a else num("NumberSequence.new", 2, b)
				kps = { M.types.NumberSequenceKeypoint.new(0, a), M.types.NumberSequenceKeypoint.new(1, b) }
			elseif type(a) == "table" and getmetatable(a) == nil then
				for i, k in a do
					if getmetatable(k) ~= NSK then
						argError("NumberSequence.new", i, "NumberSequenceKeypoint", k)
					end
				end
				kps = table.clone(a)
				checkKeypoints("NumberSequence", kps)
			else
				argError("NumberSequence.new", 1, "number or table", a)
			end
			return setmetatable({ Keypoints = kps }, NS)
		end,
	}
	local CSK = valueType("ColorSequenceKeypoint")
	M.types.ColorSequenceKeypoint = {
		new = function(t, c)
			if not isC3(c) then
				argError("ColorSequenceKeypoint.new", 2, "Color3", c)
			end
			return setmetatable({ Time = num("ColorSequenceKeypoint.new", 1, t), Value = c }, CSK)
		end,
	}
	local CS = valueType("ColorSequence")
	M.types.ColorSequence = {
		new = function(a, b)
			local kps
			if isC3(a) then
				b = b or a
				kps = { M.types.ColorSequenceKeypoint.new(0, a), M.types.ColorSequenceKeypoint.new(1, b) }
			elseif type(a) == "table" and getmetatable(a) == nil then
				for i, k in a do
					if getmetatable(k) ~= CSK then
						argError("ColorSequence.new", i, "ColorSequenceKeypoint", k)
					end
				end
				kps = table.clone(a)
				checkKeypoints("ColorSequence", kps)
			else
				argError("ColorSequence.new", 1, "Color3 or table", a)
			end
			return setmetatable({ Keypoints = kps }, CS)
		end,
	}

	local RectT = valueType("Rect", {
		Width = function(r)
			return r.Max.X - r.Min.X
		end,
		Height = function(r)
			return r.Max.Y - r.Min.Y
		end,
	})
	M.types.Rect = {
		new = function(a, b, c, d)
			if isV2(a) then
				return setmetatable({ Min = a, Max = b }, RectT)
			end
			return setmetatable({ Min = v2(a or 0, b or 0), Max = v2(c or 0, d or 0) }, RectT)
		end,
	}

	local RayT
	RayT = valueType("Ray", {
		Unit = function(r)
			return setmetatable({ Origin = r.Origin, Direction = r.Direction.Unit }, RayT)
		end,
	}, {
		ClosestPoint = function(r, p)
			local d = r.Direction.Unit
			local t = math.max(0, (p - r.Origin):Dot(d))
			return r.Origin + d * t
		end,
		Distance = function(r, p)
			return (p - r:ClosestPoint(p)).Magnitude
		end,
	})
	M.types.Ray = {
		new = function(o, d)
			needV3("Ray.new", 1, o)
			needV3("Ray.new", 2, d)
			return setmetatable({ Origin = o, Direction = d }, RayT)
		end,
	}

	local R3
	R3 = valueType("Region3", nil, {
		ExpandToGrid = function(r, res)
			local lo, hi = r._min, r._max
			local function down(x)
				return floor(x / res) * res
			end
			local function up(x)
				return math.ceil(x / res) * res
			end
			return M.types.Region3.new(v3(down(lo.X), down(lo.Y), down(lo.Z)), v3(up(hi.X), up(hi.Y), up(hi.Z)))
		end,
	})
	M.types.Region3 = {
		new = function(lo, hi)
			needV3("Region3.new", 1, lo)
			needV3("Region3.new", 2, hi)
			return setmetatable({
				_min = lo,
				_max = hi,
				CFrame = CFrame.new((lo + hi) / 2),
				Size = hi - lo,
			}, R3)
		end,
	}

	local PP = valueType("PhysicalProperties")
	M.types.PhysicalProperties = {
		new = function(density, friction, elasticity, fw, ew)
			if typeof(density) == "table" then -- Enum.Material
				return setmetatable(
					{ Density = 0.7, Friction = 0.3, Elasticity = 0.5, FrictionWeight = 1, ElasticityWeight = 1 },
					PP
				)
			end
			return setmetatable({
				Density = num("PhysicalProperties.new", 1, density),
				Friction = num("PhysicalProperties.new", 2, friction, 0.3),
				Elasticity = num("PhysicalProperties.new", 3, elasticity, 0.5),
				FrictionWeight = fw or 1,
				ElasticityWeight = ew or 1,
			}, PP)
		end,
	}

	local TI = valueType("TweenInfo")
	M.types.TweenInfo = {
		new = function(time, style, direction, repeatCount, reverses, delayTime)
			return setmetatable({
				Time = num("TweenInfo.new", 1, time, 1),
				EasingStyle = style or M.Enum.EasingStyle.Quad,
				EasingDirection = direction or M.Enum.EasingDirection.Out,
				RepeatCount = repeatCount or 0,
				Reverses = reverses or false,
				DelayTime = delayTime or 0,
			}, TI)
		end,
	}

	local FontT = valueType("Font")
	M.types.Font = {
		new = function(family, weight, style)
			return setmetatable({
				Family = family,
				Weight = weight or M.Enum.FontWeight.Regular,
				Style = style or M.Enum.FontStyle.Normal,
				Bold = false,
			}, FontT)
		end,
		fromEnum = function(e)
			return setmetatable({
				Family = "rbxasset://fonts/" .. e.Name,
				Weight = M.Enum.FontWeight.Regular,
				Style = M.Enum.FontStyle.Normal,
				Bold = false,
			}, FontT)
		end,
		fromName = function(name, weight, style)
			return M.types.Font.new("rbxasset://fonts/families/" .. name .. ".json", weight, style)
		end,
		fromId = function(id, weight, style)
			return M.types.Font.new("rbxassetid://" .. tostring(id), weight, style)
		end,
	}

	-- BrickColor: a small palette is enough; unknown names map to Medium stone grey.
	local BC = valueType("BrickColor")
	BC.__eq = function(a, b)
		return a.Number == b.Number
	end
	BC.__tostring = function(b)
		return b.Name
	end
	local palette = {
		{ 1, "White", 242, 243, 243 },
		{ 194, "Medium stone grey", 163, 162, 165 },
		{ 199, "Dark stone grey", 99, 95, 98 },
		{ 26, "Black", 27, 42, 53 },
		{ 21, "Bright red", 196, 40, 28 },
		{ 23, "Bright blue", 13, 105, 172 },
		{ 24, "Bright yellow", 245, 205, 48 },
		{ 37, "Bright green", 75, 151, 75 },
		{ 106, "Bright orange", 218, 133, 65 },
		{ 1001, "Institutional white", 248, 248, 248 },
		{ 1003, "Really black", 17, 17, 17 },
	}
	local function brick(entry)
		return setmetatable({
			Number = entry[1],
			Name = entry[2],
			Color = c3(entry[3] / 255, entry[4] / 255, entry[5] / 255),
			r = entry[3] / 255,
			g = entry[4] / 255,
			b = entry[5] / 255,
		}, BC)
	end
	local BrickColor = {}
	function BrickColor.new(a, b, c)
		if type(a) == "string" then
			for _, e in palette do
				if e[2] == a then
					return brick(e)
				end
			end
			return brick(palette[2])
		elseif type(a) == "number" and b == nil then
			for _, e in palette do
				if e[1] == a then
					return brick(e)
				end
			end
			return brick(palette[2])
		end
		local col = if isC3(a) then a else c3((a or 0) / 255, (b or 0) / 255, (c or 0) / 255)
		local best, bestD = palette[2], math.huge
		for _, e in palette do
			local d = (e[3] / 255 - col.R) ^ 2 + (e[4] / 255 - col.G) ^ 2 + (e[5] / 255 - col.B) ^ 2
			if d < bestD then
				best, bestD = e, d
			end
		end
		return brick(best)
	end
	BrickColor.palette = function(i)
		return brick(palette[(i % #palette) + 1])
	end
	BrickColor.random = function()
		return brick(palette[math.random(1, #palette)])
	end
	for _, e in palette do
		local short = (e[2]:gsub(" ", ""))
		BrickColor[short] = function()
			return brick(e)
		end
	end
	BrickColor.White = function()
		return brick(palette[1])
	end
	BrickColor.Black = function()
		return brick(palette[4])
	end
	BrickColor.Gray = function()
		return brick(palette[2])
	end
	BrickColor.Red = function()
		return brick(palette[5])
	end
	BrickColor.Blue = function()
		return brick(palette[6])
	end
	BrickColor.Yellow = function()
		return brick(palette[7])
	end
	BrickColor.Green = function()
		return brick(palette[8])
	end
	M.types.BrickColor = BrickColor

	-- Random: deterministic Park-Miller style generator over doubles. Random.new() without a
	-- seed takes the next value of a fixed counter so whole runs are reproducible.
	local RandomT = { __type = "Random" }
	local Rm = {}
	RandomT.__index = function(_, k)
		local m = Rm[k]
		if m then
			return m
		end
		invalidMember("Random", k)
		return nil
	end
	local MOD = 2147483647
	local function nextUnit(r): number
		r._s = (r._s * 48271) % MOD
		local a = r._s
		r._s = (r._s * 48271) % MOD
		-- 53 bits-ish of mantissa from two draws
		return ((a - 1) * (MOD - 1) + (r._s - 1)) / ((MOD - 1) * (MOD - 1))
	end
	function Rm.NextNumber(r, min, max)
		if min == nil and max == nil then
			return nextUnit(r)
		end
		min = num("NextNumber", 1, min)
		max = num("NextNumber", 2, max)
		return min + (max - min) * nextUnit(r)
	end
	function Rm.NextInteger(r, min, max)
		min = num("NextInteger", 1, min)
		max = num("NextInteger", 2, max)
		if min ~= floor(min) or max ~= floor(max) then
			min, max = floor(min), floor(max)
		end
		if max < min then
			error("invalid argument #2 to 'NextInteger' (interval is empty)", 2)
		end
		return min + math.min(max - min, floor(nextUnit(r) * (max - min + 1)))
	end
	function Rm.NextUnitVector(r)
		local z = r:NextNumber(-1, 1)
		local a = r:NextNumber(0, math.pi * 2)
		local s = sqrt(1 - z * z)
		return v3(s * cos(a), s * sin(a), z)
	end
	function Rm.Shuffle(r, t)
		for i = #t, 2, -1 do
			local j = r:NextInteger(1, i)
			t[i], t[j] = t[j], t[i]
		end
	end
	function Rm.Clone(r)
		return setmetatable({ _s = r._s }, RandomT)
	end
	local unseeded = 12345
	M.types.Random = {
		new = function(seed)
			if seed == nil then
				unseeded += 7919
				seed = unseeded
			end
			seed = floor(num("Random.new", 1, seed))
			local s = seed % (MOD - 1) + 1
			local r = setmetatable({ _s = s }, RandomT)
			nextUnit(r)
			return r
		end,
	}

	-- DateTime (enough for timestamps and ISO formatting).
	local DT = valueType("DateTime", nil, {
		ToIsoDate = function(d)
			return os.date("!%Y-%m-%dT%H:%M:%SZ", floor(d.UnixTimestamp))
		end,
		FormatUniversalTime = function(d, f)
			return os.date("!%Y-%m-%d %H:%M", floor(d.UnixTimestamp)) .. "|" .. tostring(f)
		end,
		FormatLocalTime = function(d, f)
			return os.date("%Y-%m-%d %H:%M", floor(d.UnixTimestamp)) .. "|" .. tostring(f)
		end,
		ToUniversalTime = function(d)
			return os.date("!*t", floor(d.UnixTimestamp))
		end,
		ToLocalTime = function(d)
			return os.date("*t", floor(d.UnixTimestamp))
		end,
	})
	M.types.DateTime = {
		now = function()
			local t = M.wallClock()
			return setmetatable({ UnixTimestamp = floor(t), UnixTimestampMillis = floor(t * 1000) }, DT)
		end,
		fromUnixTimestamp = function(t)
			return setmetatable({ UnixTimestamp = floor(t), UnixTimestampMillis = floor(t * 1000) }, DT)
		end,
		fromUnixTimestampMillis = function(t)
			return setmetatable({ UnixTimestamp = floor(t / 1000), UnixTimestampMillis = floor(t) }, DT)
		end,
	}

	-- RaycastParams / OverlapParams / RaycastResult -------------------------------------------
	local function paramsType(name: string, defaults: { [string]: any })
		local mt = { __type = name }
		mt.__index = function(p, k)
			if k == "AddToFilter" then
				return function(self, inst)
					local list = table.clone(rawget(self, "_props").FilterDescendantsInstances)
					if M.typeof(inst) == "Instance" then
						table.insert(list, inst)
					else
						for _, i in inst do
							table.insert(list, i)
						end
					end
					rawget(self, "_props").FilterDescendantsInstances = list
				end
			end
			local props = rawget(p, "_props")
			if defaults[k] == nil then
				invalidMember(name, k)
			end
			return props[k]
		end
		mt.__newindex = function(p, k, v)
			if defaults[k] == nil then
				error(tostring(k) .. " is not a valid member of " .. name, 2)
			end
			if k == "FilterDescendantsInstances" then
				if type(v) ~= "table" or getmetatable(v) ~= nil then
					error(
						"Unable to assign property FilterDescendantsInstances. Array expected, got " .. M.typeof(v),
						2
					)
				end
				local list = {}
				for i, inst in v do
					if M.typeof(inst) ~= "Instance" then
						error(
							fmt(
								"Unable to assign property FilterDescendantsInstances. Instance expected at index %s, got %s",
								tostring(i),
								M.typeof(inst)
							),
							2
						)
					end
					table.insert(list, inst)
				end
				v = list
			elseif k == "FilterType" then
				if M.typeof(v) ~= "EnumItem" or v.EnumType ~= M.Enum.RaycastFilterType then
					error("Unable to assign property FilterType. EnumItem expected", 2)
				end
			elseif typeof(defaults[k]) ~= "nil" and type(defaults[k]) ~= "table" and type(v) ~= type(defaults[k]) then
				error(fmt("Unable to assign property %s. %s expected, got %s", k, type(defaults[k]), M.typeof(v)), 2)
			end
			rawget(p, "_props")[k] = v
		end
		return mt
	end
	local function lazyEnum(typeName: string, item: string)
		return function()
			return (M.Enum :: any)[typeName][item]
		end
	end
	local function makeParams(mt, defaults)
		local props = {}
		for k, v in defaults do
			props[k] = if type(v) == "function" then v() else v
		end
		props.FilterDescendantsInstances = {}
		return setmetatable({ _props = props }, mt)
	end
	local rpDefaults = {
		FilterDescendantsInstances = {},
		FilterType = lazyEnum("RaycastFilterType", "Exclude"),
		IgnoreWater = false,
		CollisionGroup = "Default",
		RespectCanCollide = false,
		BruteForceAllSlow = false,
	}
	local RPmt = paramsType("RaycastParams", rpDefaults)
	M.types.RaycastParams = {
		new = function()
			return makeParams(RPmt, rpDefaults)
		end,
	}
	local opDefaults = {
		FilterDescendantsInstances = {},
		FilterType = lazyEnum("RaycastFilterType", "Exclude"),
		CollisionGroup = "Default",
		RespectCanCollide = false,
		MaxParts = 0,
		BruteForceAllSlow = false,
	}
	local OPmt = paramsType("OverlapParams", opDefaults)
	M.types.OverlapParams = {
		new = function()
			return makeParams(OPmt, opDefaults)
		end,
	}
	local RR = valueType("RaycastResult")
	function M.raycastResult(inst, pos, normal, material, distance)
		return setmetatable(
			{ Instance = inst, Position = pos, Normal = normal, Material = material, Distance = distance },
			RR
		)
	end

	-- Misc rarely used constructors (present so `typeof` and construction work).
	local function opaque(name)
		local mt = valueType(name)
		return {
			new = function(...)
				return setmetatable({ _args = { ... } }, mt)
			end,
		}
	end
	M.types.Axes = opaque("Axes")
	M.types.Faces = opaque("Faces")
	M.types.Vector3int16 = {
		new = function(x, y, z)
			return v3(floor(x or 0), floor(y or 0), floor(z or 0))
		end,
	}

	-- typeof --------------------------------------------------------------------------------
	local builtinTypeof = typeof
	function M.typeof(v: any): string
		local t = type(v)
		if t == "table" then
			local mt = getmetatable(v)
			if type(mt) == "table" then
				local name = rawget(mt, "__type")
				if name then
					return name
				end
			end
			return "table"
		end
		return builtinTypeof(v)
	end
	M.vectorToWorld = vectorToWorld
	M.vectorToObject = vectorToObject
	M.pointToWorld = pointToWorld
	M.cfInverse = inverse
	M.mulCF = mulCF
end
