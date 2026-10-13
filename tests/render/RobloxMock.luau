-- Headless Roblox stand-in for the preview renderer (tests/render/dump.luau). Not a test
-- suite and not tests/mock: just enough of the datatypes (real CFrame maths), the Instance
-- tree, a few services and a file-backed `require` to run the REAL world/gear builders in the
-- plain Luau VM (`luaurun`) and read back every part they make.
--
--   local Mock = __loadfile(ROOT .. "/tests/render/RobloxMock.luau")(ROOT)
--   local WorldBuilder = Mock.require(Mock.server.World.WorldBuilder)
--
-- Everything the builders see as globals (Vector3, CFrame, Instance, game, workspace, typeof,
-- warn, task, ...) lives in Mock.env, which is the environment of every module loaded through
-- Mock.require. Nothing is written to _G.
--
-- Known gaps: Random is a simple deterministic generator (Roblox's own sequence is not
-- reproducible here, so scattered props land in different but equally valid spots); terrain
-- writes are recorded, not voxelised (the renderer samples Shared/Logic/TerrainModel instead).

local ROOT = ...

local sqrt, cos, sin, abs = math.sqrt, math.cos, math.sin, math.abs

local Mock = {}
-- Builder globals; anything not mocked here (math, string, table, ...) falls through to the VM.
-- selene: allow(global_usage)
local env = setmetatable({}, { __index = _G })
Mock.env = env
Mock.warnings = {} :: { string }
Mock.terrainCalls = 0

---------------------------------------------------------------------------------------------
-- Vector3 / Vector2
---------------------------------------------------------------------------------------------
local V = {}
local function v3(x: number?, y: number?, z: number?)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V)
end
V.__index = function(v, k)
	if k == "Magnitude" then
		return sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif k == "Unit" then
		local m = sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return v3(0, 0, 0)
		end
		return v3(v.X / m, v.Y / m, v.Z / m)
	elseif k == "x" then
		return v.X
	elseif k == "y" then
		return v.Y
	elseif k == "z" then
		return v.Z
	end
	return rawget(V, k)
end
V.__add = function(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V.__sub = function(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V.__mul = function(a, b)
	if type(a) == "number" then
		return v3(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__div = function(a, b)
	if type(b) == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V.__unm = function(a)
	return v3(-a.X, -a.Y, -a.Z)
end
V.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V.__tostring = function(a)
	return string.format("%g, %g, %g", a.X, a.Y, a.Z)
end
function V.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V.Cross(a, b)
	return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V.Lerp(a, b, t)
	return v3(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end
function V.Abs(a)
	return v3(abs(a.X), abs(a.Y), abs(a.Z))
end
function V.Min(a, b)
	return v3(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
end
function V.Max(a, b)
	return v3(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
end
function V.FuzzyEq(a, b, eps)
	return (a - b).Magnitude <= (eps or 1e-5)
end
local function isV(x)
	return type(x) == "table" and getmetatable(x) == V
end
env.Vector3 = {
	new = v3,
	zero = v3(0, 0, 0),
	one = v3(1, 1, 1),
	xAxis = v3(1, 0, 0),
	yAxis = v3(0, 1, 0),
	zAxis = v3(0, 0, 1),
}
Mock.Vector3 = env.Vector3

local V2 = {}
V2.__index = function(v, k)
	if k == "Magnitude" then
		return sqrt(v.X * v.X + v.Y * v.Y)
	end
	return rawget(V2, k)
end
local function v2(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2)
end
V2.__add = function(a, b)
	return v2(a.X + b.X, a.Y + b.Y)
end
V2.__sub = function(a, b)
	return v2(a.X - b.X, a.Y - b.Y)
end
V2.__mul = function(a, b)
	if type(b) == "number" then
		return v2(a.X * b, a.Y * b)
	end
	return v2(a.X * b.X, a.Y * b.Y)
end
env.Vector2 = { new = v2, zero = v2(0, 0), one = v2(1, 1) }

---------------------------------------------------------------------------------------------
-- CFrame: position p and rotation columns x (right), y (up), z (back)
---------------------------------------------------------------------------------------------
local C = {}
local function cf(p, x, y, z)
	return setmetatable({ p = p, x = x, y = y, z = z }, C)
end
local function rotate(c, v)
	return v3(
		c.x.X * v.X + c.y.X * v.Y + c.z.X * v.Z,
		c.x.Y * v.X + c.y.Y * v.Y + c.z.Y * v.Z,
		c.x.Z * v.X + c.y.Z * v.Y + c.z.Z * v.Z
	)
end
local function isC(x)
	return type(x) == "table" and getmetatable(x) == C
end
local AX, AY, AZ, O = v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1), v3(0, 0, 0)
C.__index = function(c, k)
	if k == "Position" then
		return c.p
	elseif k == "X" then
		return c.p.X
	elseif k == "Y" then
		return c.p.Y
	elseif k == "Z" then
		return c.p.Z
	elseif k == "LookVector" then
		return -c.z
	elseif k == "RightVector" or k == "XVector" then
		return c.x
	elseif k == "UpVector" or k == "YVector" then
		return c.y
	elseif k == "ZVector" then
		return c.z
	elseif k == "Rotation" then
		return cf(O, c.x, c.y, c.z)
	end
	return rawget(C, k)
end
C.__mul = function(a, b)
	if isV(b) then
		return a.p + rotate(a, b)
	end
	return cf(a.p + rotate(a, b.p), rotate(a, b.x), rotate(a, b.y), rotate(a, b.z))
end
C.__add = function(a, v)
	return cf(a.p + v, a.x, a.y, a.z)
end
C.__sub = function(a, v)
	return cf(a.p - v, a.x, a.y, a.z)
end
C.__eq = function(a, b)
	return a.p == b.p and a.x == b.x and a.y == b.y and a.z == b.z
end
C.__tostring = function(c)
	return tostring(c.p)
end
function C.Inverse(c)
	local x = v3(c.x.X, c.y.X, c.z.X)
	local y = v3(c.x.Y, c.y.Y, c.z.Y)
	local z = v3(c.x.Z, c.y.Z, c.z.Z)
	local inv = cf(O, x, y, z)
	return cf(-rotate(inv, c.p), x, y, z)
end
function C.ToObjectSpace(a, b)
	return a:Inverse() * b
end
function C.ToWorldSpace(a, b)
	return a * b
end
function C.PointToWorldSpace(a, v)
	return a * v
end
function C.PointToObjectSpace(a, v)
	return a:Inverse() * v
end
function C.VectorToWorldSpace(a, v)
	return rotate(a, v)
end
function C.VectorToObjectSpace(a, v)
	return rotate(a:Inverse(), v)
end
function C.GetComponents(c)
	return c.p.X, c.p.Y, c.p.Z, c.x.X, c.y.X, c.z.X, c.x.Y, c.y.Y, c.z.Y, c.x.Z, c.y.Z, c.z.Z
end
C.components = C.GetComponents
function C.ToEulerAnglesXYZ(c)
	-- R = Rx * Ry * Rz; R02 = sin(ry)
	local r02 = math.clamp(c.z.X, -1, 1)
	local ry = math.asin(r02)
	local rx = math.atan2(-c.z.Y, c.z.Z)
	local rz = math.atan2(-c.y.X, c.x.X)
	return rx, ry, rz
end
function C.ToEulerAnglesYXZ(c)
	-- R = Ry * Rx * Rz; R12 = -sin(rx)
	local rx = math.asin(math.clamp(-c.z.Y, -1, 1))
	local ry = math.atan2(c.z.X, c.z.Z)
	local rz = math.atan2(c.x.Y, c.y.Y)
	return rx, ry, rz
end
C.ToOrientation = C.ToEulerAnglesYXZ

-- Quaternion helpers for Lerp.
local function toQuat(c)
	local m00, m01, m02 = c.x.X, c.y.X, c.z.X
	local m10, m11, m12 = c.x.Y, c.y.Y, c.z.Y
	local m20, m21, m22 = c.x.Z, c.y.Z, c.z.Z
	local tr = m00 + m11 + m22
	local w, x, y, z
	if tr > 0 then
		local s = sqrt(tr + 1) * 2
		w, x, y, z = 0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = sqrt(1 + m00 - m11 - m22) * 2
		w, x, y, z = (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s
	elseif m11 > m22 then
		local s = sqrt(1 + m11 - m00 - m22) * 2
		w, x, y, z = (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s
	else
		local s = sqrt(1 + m22 - m00 - m11) * 2
		w, x, y, z = (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s
	end
	return w, x, y, z
end
local function fromQuat(p, w, x, y, z)
	local n = sqrt(w * w + x * x + y * y + z * z)
	w, x, y, z = w / n, x / n, y / n, z / n
	return cf(
		p,
		v3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
		v3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
		v3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y))
	)
end
function C.Lerp(a, b, t)
	local p = a.p:Lerp(b.p, t)
	local aw, ax, ay, az = toQuat(a)
	local bw, bx, by, bz = toQuat(b)
	local d = aw * bw + ax * bx + ay * by + az * bz
	if d < 0 then
		bw, bx, by, bz, d = -bw, -bx, -by, -bz, -d
	end
	if d > 0.9995 then
		return fromQuat(p, aw + (bw - aw) * t, ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t)
	end
	local th = math.acos(d)
	local s0, s1 = sin((1 - t) * th) / sin(th), sin(t * th) / sin(th)
	return fromQuat(p, aw * s0 + bw * s1, ax * s0 + bx * s1, ay * s0 + by * s1, az * s0 + bz * s1)
end

local function rx(a)
	return cf(O, AX, v3(0, cos(a), sin(a)), v3(0, -sin(a), cos(a)))
end
local function ry(a)
	return cf(O, v3(cos(a), 0, -sin(a)), AY, v3(sin(a), 0, cos(a)))
end
local function rz(a)
	return cf(O, v3(cos(a), sin(a), 0), v3(-sin(a), cos(a), 0), AZ)
end
local function lookAt(at, target, up)
	up = up or AY
	local look = (target - at).Unit
	if abs(look:Dot(up)) > 0.9999 then
		up = AZ
	end
	local right = look:Cross(up).Unit
	local up2 = right:Cross(look)
	return cf(at, right, up2, -look)
end
local CFrame = {}
function CFrame.new(...)
	local n = select("#", ...)
	local a, b, c = ...
	if n == 0 then
		return cf(O, AX, AY, AZ)
	elseif isV(a) then
		if b ~= nil then
			return lookAt(a, b)
		end
		return cf(a, AX, AY, AZ)
	elseif n == 3 then
		return cf(v3(a, b, c), AX, AY, AZ)
	elseif n == 7 then
		local _, _, _, qx, qy, qz, qw = ...
		return fromQuat(v3(a, b, c), qw, qx, qy, qz)
	elseif n == 12 then
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = ...
		return cf(v3(x, y, z), v3(r00, r10, r20), v3(r01, r11, r21), v3(r02, r12, r22))
	end
	error("CFrame.new: unsupported argument list (" .. n .. ")")
end
function CFrame.Angles(a, b, c)
	return rx(a) * ry(b) * rz(c)
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
function CFrame.fromEulerAnglesYXZ(a, b, c)
	return ry(b) * rx(a) * rz(c)
end
CFrame.fromOrientation = CFrame.fromEulerAnglesYXZ
function CFrame.fromAxisAngle(axis, angle)
	local u = axis.Unit
	local s, co = sin(angle / 2), cos(angle / 2)
	return fromQuat(O, co, u.X * s, u.Y * s, u.Z * s)
end
function CFrame.fromMatrix(p, x, y, z)
	z = z or x:Cross(y).Unit
	return cf(p, x, y, z)
end
CFrame.lookAt = lookAt
function CFrame.lookAlong(at, dir, up)
	return lookAt(at, at + dir, up)
end
CFrame.identity = cf(O, AX, AY, AZ)
env.CFrame = CFrame
Mock.CFrame = CFrame

---------------------------------------------------------------------------------------------
-- Color3 and plain value types
---------------------------------------------------------------------------------------------
local Col = {}
Col.__index = Col
Col.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
local function col(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Col)
end
function Col.Lerp(a, b, t)
	return col(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end
function Col.ToHSV(c)
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
function Col.ToHex(c)
	return string.format("%02X%02X%02X", c.R * 255 + 0.5, c.G * 255 + 0.5, c.B * 255 + 0.5)
end
local function fromHSV(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	i %= 6
	if i == 0 then
		return col(v, t, p)
	elseif i == 1 then
		return col(q, v, p)
	elseif i == 2 then
		return col(p, v, t)
	elseif i == 3 then
		return col(p, q, v)
	elseif i == 4 then
		return col(t, p, v)
	end
	return col(v, p, q)
end
env.Color3 = {
	new = col,
	fromRGB = function(r, g, b)
		return col((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
	fromHSV = fromHSV,
	fromHex = function(hex: string)
		hex = hex:gsub("#", "")
		return col(
			tonumber(hex:sub(1, 2), 16) / 255,
			tonumber(hex:sub(3, 4), 16) / 255,
			tonumber(hex:sub(5, 6), 16) / 255
		)
	end,
}
local function isCol(x)
	return type(x) == "table" and getmetatable(x) == Col
end

local function plain(name: string)
	return {
		new = function(...)
			return { __type = name, args = { ... } }
		end,
	}
end
env.UDim2 = plain("UDim2")
env.UDim2.fromScale = env.UDim2.new
env.UDim2.fromOffset = env.UDim2.new
env.UDim = plain("UDim")
env.NumberSequence = plain("NumberSequence")
env.NumberSequenceKeypoint = plain("NumberSequenceKeypoint")
env.ColorSequence = plain("ColorSequence")
env.ColorSequenceKeypoint = plain("ColorSequenceKeypoint")
env.NumberRange = plain("NumberRange")
env.PhysicalProperties = plain("PhysicalProperties")
env.TweenInfo = plain("TweenInfo")
env.RaycastParams = plain("RaycastParams")
env.OverlapParams = plain("OverlapParams")
env.Region3 = {
	new = function(lo, hi)
		local r = { CFrame = cf((lo + hi) / 2, AX, AY, AZ), Size = hi - lo }
		function r.ExpandToGrid(self)
			return self
		end
		return r
	end,
}
env.BrickColor = {
	new = function(name)
		return { Name = name, Color = col(0.6, 0.6, 0.6) }
	end,
}

-- Deterministic generator (MINSTD, exact in doubles). Not Roblox's sequence.
local RandomMeta = {}
RandomMeta.__index = RandomMeta
local function stepRandom(r)
	r.s = (r.s * 48271) % 2147483647
	return r.s / 2147483647
end
function RandomMeta.NextNumber(r, a, b)
	local u = stepRandom(r)
	a = a or 0
	b = b or 1
	return a + (b - a) * u
end
function RandomMeta.NextInteger(r, a, b)
	return math.min(b, a + math.floor(stepRandom(r) * (b - a + 1)))
end
function RandomMeta.NextUnitVector(r)
	local z = r:NextNumber(-1, 1)
	local a = r:NextNumber(0, math.pi * 2)
	local s = sqrt(1 - z * z)
	return v3(s * cos(a), s * sin(a), z)
end
function RandomMeta.Clone(r)
	return setmetatable({ s = r.s }, RandomMeta)
end
env.Random = {
	new = function(seed)
		local s = math.floor(abs(seed or 1)) % 2147483646 + 1
		local r = setmetatable({ s = s }, RandomMeta)
		for _ = 1, 3 do
			stepRandom(r)
		end
		return r
	end,
}

---------------------------------------------------------------------------------------------
-- Enum (items are cached so == works; Material is checked against the real list)
---------------------------------------------------------------------------------------------
local MATERIALS = {}
for _, name in
	string.split(
		"Plastic SmoothPlastic Neon Wood WoodPlanks Marble Slate Concrete Granite Brick Pebble Cobblestone "
			.. "Rock Sandstone Basalt CrackedLava Limestone Pavement CorrodedMetal DiamondPlate Foil Metal Grass "
			.. "LeafyGrass Sand Fabric Snow Mud Ground Asphalt Salt Ice Glacier Glass ForceField Air Water "
			.. "Cardboard Carpet CeramicTiles ClayRoofTiles RoofShingles Leather Plaster Rubber",
		" "
	)
do
	MATERIALS[name] = true
end
local EnumItem = {}
EnumItem.__index = EnumItem
EnumItem.__tostring = function(e)
	return "Enum." .. e.EnumType .. "." .. e.Name
end
local enumCache = {}
env.Enum = setmetatable({}, {
	__index = function(_, enumType)
		local items = enumCache[enumType]
		if not items then
			items = setmetatable({}, {
				__index = function(t, item)
					if enumType == "Material" and not MATERIALS[item] then
						error(item .. " is not a valid member of Enum.Material")
					end
					local e = setmetatable({ Name = item, EnumType = enumType, Value = 0 }, EnumItem)
					rawset(t, item, e)
					return e
				end,
			})
			items.GetEnumItems = function()
				return {}
			end
			enumCache[enumType] = items
		end
		return items
	end,
})
local Enum = env.Enum

---------------------------------------------------------------------------------------------
-- Instances
---------------------------------------------------------------------------------------------
local PART_CLASSES = {
	Part = true,
	WedgePart = true,
	CornerWedgePart = true,
	TrussPart = true,
	SpawnLocation = true,
	MeshPart = true,
	Seat = true,
	UnionOperation = true,
}
local ISA = {
	BasePart = function(c)
		return PART_CLASSES[c] == true
	end,
	PVInstance = function(c)
		return PART_CLASSES[c] == true or c == "Model" or c == "Workspace"
	end,
	Part = function(c)
		return c == "Part" or c == "SpawnLocation" or c == "Seat"
	end,
	FormFactorPart = function(c)
		return c == "Part" or c == "SpawnLocation" or c == "WedgePart" or c == "CornerWedgePart"
	end,
	Model = function(c)
		return c == "Model" or c == "Workspace"
	end,
	Light = function(c)
		return c == "PointLight" or c == "SpotLight" or c == "SurfaceLight"
	end,
	GuiObject = function(c)
		return c == "TextLabel" or c == "Frame" or c == "ImageLabel" or c == "TextButton"
	end,
	LayerCollector = function(c)
		return c == "SurfaceGui" or c == "BillboardGui" or c == "ScreenGui"
	end,
	JointInstance = function(c)
		return c == "Weld" or c == "Motor6D"
	end,
	Constraint = function(c)
		return c == "RopeConstraint" or c == "RodConstraint"
	end,
}
local EVENTS = {
	Changed = true,
	ChildAdded = true,
	ChildRemoved = true,
	DescendantAdded = true,
	DescendantRemoving = true,
	AncestryChanged = true,
	Destroying = true,
	Touched = true,
	TouchEnded = true,
	Triggered = true,
	PromptShown = true,
	PromptHidden = true,
	CharacterAdded = true,
	CharacterRemoving = true,
	Died = true,
	HealthChanged = true,
	StateChanged = true,
	Heartbeat = true,
	Stepped = true,
	RenderStepped = true,
	PlayerAdded = true,
	PlayerRemoving = true,
	MoveToFinished = true,
}

local function signal()
	return {
		Connect = function()
			return { Disconnect = function() end, Connected = true }
		end,
		Once = function()
			return { Disconnect = function() end, Connected = true }
		end,
		Wait = function() end,
	}
end

local Inst = {}
Mock.InstanceMeta = Inst
local nextId = 0

local function defaults(className: string): { [string]: any }
	local p: { [string]: any } = { Name = className, Archivable = true }
	if PART_CLASSES[className] then
		p.CFrame = CFrame.identity
		p.Size = if className == "TrussPart"
			then v3(2, 2, 2)
			elseif className == "SpawnLocation" then v3(12, 1, 12)
			else v3(4, 1, 2)
		p.Transparency = 0
		p.Reflectance = 0
		p.CanCollide = true
		p.CanQuery = true
		p.CanTouch = true
		p.CastShadow = true
		p.Anchored = false
		p.Massless = false
		p.Locked = false
		p.Shape = Enum.PartType.Block
		p.Material = Enum.Material.Plastic
		p.Color = col(163 / 255, 162 / 255, 165 / 255)
		p.PivotOffset = CFrame.identity
	elseif className == "SpecialMesh" then
		p.MeshType = Enum.MeshType.Head
		p.Scale = v3(1, 1, 1)
		p.Offset = v3(0, 0, 0)
	elseif className == "Attachment" then
		p.CFrame = CFrame.identity
	elseif className == "Humanoid" then
		p.Health = 100
		p.MaxHealth = 100
		p.WalkSpeed = 16
		p.HipHeight = 2
	end
	return p
end

local function newInstance(className: string)
	nextId += 1
	local o = {
		_class = className,
		_id = nextId,
		_children = {},
		_tags = {},
		_attrs = {},
		_p = defaults(className),
	}
	return setmetatable(o, Inst)
end

Inst.__tostring = function(o)
	return o._p.Name
end
Inst.__index = function(o, k)
	if k == "Parent" then
		return rawget(o, "_parent")
	elseif k == "ClassName" then
		return o._class
	end
	local p = rawget(o, "_p")
	if k == "Position" and p.CFrame then
		if o._class == "Attachment" then
			return p.CFrame.p
		end
		return p.CFrame.p
	elseif k == "Orientation" and p.CFrame then
		local x, y, z = p.CFrame:ToOrientation()
		return v3(math.deg(x), math.deg(y), math.deg(z))
	elseif k == "WorldPosition" and o._class == "Attachment" then
		local parent = rawget(o, "_parent")
		if parent and parent._p.CFrame then
			return parent._p.CFrame * p.CFrame.p
		end
		return p.CFrame.p
	elseif k == "WorldCFrame" and o._class == "Attachment" then
		local parent = rawget(o, "_parent")
		if parent and parent._p.CFrame then
			return parent._p.CFrame * p.CFrame
		end
		return p.CFrame
	elseif k == "AssemblyLinearVelocity" or k == "AssemblyAngularVelocity" then
		return v3(0, 0, 0)
	end
	-- Per-instance values first: services and terrain carry their own method overrides.
	local v = p[k]
	if v ~= nil then
		return v
	end
	local m = rawget(Inst, k)
	if m then
		return m
	end
	if EVENTS[k] then
		local s = signal()
		p[k] = s
		return s
	end
	if k == "PrimaryPart" or k == "Adornee" or k == "Part0" or k == "Part1" then
		return nil
	end
	for _, c in o._children do
		if c._p.Name == k then
			return c
		end
	end
	return nil
end

local function setParent(o, v)
	local old = rawget(o, "_parent")
	if old == v then
		return
	end
	if old then
		local i = table.find(old._children, o)
		if i then
			table.remove(old._children, i)
		end
	end
	rawset(o, "_parent", v)
	if v then
		table.insert(v._children, o)
	end
end

Inst.__newindex = function(o, k, v)
	local p = o._p
	if k == "Parent" then
		setParent(o, v)
	elseif k == "Position" and p.CFrame then
		local c = p.CFrame
		p.CFrame = cf(v, c.x, c.y, c.z)
	elseif k == "Orientation" and p.CFrame then
		p.CFrame = cf(p.CFrame.p, AX, AY, AZ) * CFrame.fromEulerAnglesYXZ(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
	elseif k == "WorldPosition" and o._class == "Attachment" then
		local parent = rawget(o, "_parent")
		local local_ = if parent and parent._p.CFrame then parent._p.CFrame:PointToObjectSpace(v) else v
		p.CFrame = cf(local_, p.CFrame.x, p.CFrame.y, p.CFrame.z)
	elseif k == "WorldCFrame" and o._class == "Attachment" then
		local parent = rawget(o, "_parent")
		p.CFrame = if parent and parent._p.CFrame then parent._p.CFrame:ToObjectSpace(v) else v
	elseif k == "Size" and PART_CLASSES[o._class] then
		-- Roblox clamps part sizes to at least 0.001 per axis.
		p.Size = v3(math.max(v.X, 0.001), math.max(v.Y, 0.001), math.max(v.Z, 0.001))
	elseif k == "PrimaryPart" then
		p.PrimaryPart = v
	else
		if k == "Material" and type(v) == "table" and v.EnumType ~= "Material" then
			error("bad Material value")
		end
		p[k] = v
	end
end

function Inst.IsA(o, name)
	if o._class == name or name == "Instance" then
		return true
	end
	local f = ISA[name]
	return f ~= nil and f(o._class)
end
function Inst.IsDescendantOf(o, ancestor)
	local p = rawget(o, "_parent")
	while p do
		if p == ancestor then
			return true
		end
		p = rawget(p, "_parent")
	end
	return false
end
function Inst.IsAncestorOf(o, d)
	return d:IsDescendantOf(o)
end
function Inst.GetChildren(o)
	return table.clone(o._children)
end
function Inst.GetDescendants(o)
	local out = {}
	local function walk(n)
		for _, c in n._children do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(o)
	return out
end
function Inst.FindFirstChild(o, name, recursive)
	local list = if recursive then o:GetDescendants() else o._children
	for _, c in list do
		if c._p.Name == name then
			return c
		end
	end
	return nil
end
function Inst.WaitForChild(o, name)
	return o:FindFirstChild(name)
end
function Inst.FindFirstChildOfClass(o, cls)
	for _, c in o._children do
		if c._class == cls then
			return c
		end
	end
	return nil
end
function Inst.FindFirstChildWhichIsA(o, cls, recursive)
	local list = if recursive then o:GetDescendants() else o._children
	for _, c in list do
		if c:IsA(cls) then
			return c
		end
	end
	return nil
end
function Inst.FindFirstAncestor(o, name)
	local p = rawget(o, "_parent")
	while p do
		if p._p.Name == name then
			return p
		end
		p = rawget(p, "_parent")
	end
	return nil
end
function Inst.FindFirstAncestorWhichIsA(o, cls)
	local p = rawget(o, "_parent")
	while p do
		if p:IsA(cls) then
			return p
		end
		p = rawget(p, "_parent")
	end
	return nil
end
Inst.FindFirstAncestorOfClass = Inst.FindFirstAncestorWhichIsA
function Inst.SetAttribute(o, k, v)
	o._attrs[k] = v
end
function Inst.GetAttribute(o, k)
	return o._attrs[k]
end
function Inst.GetAttributes(o)
	return table.clone(o._attrs)
end
function Inst.GetAttributeChangedSignal()
	return signal()
end
function Inst.GetPropertyChangedSignal()
	return signal()
end
function Inst.AddTag(o, tag)
	o._tags[tag] = true
end
function Inst.HasTag(o, tag)
	return o._tags[tag] == true
end
function Inst.RemoveTag(o, tag)
	o._tags[tag] = nil
end
function Inst.GetTags(o)
	local out = {}
	for t in o._tags do
		table.insert(out, t)
	end
	return out
end
function Inst.Destroy(o)
	setParent(o, nil)
	rawset(o, "_destroyed", true)
end
function Inst.ClearAllChildren(o)
	for _, c in o:GetChildren() do
		c:Destroy()
	end
end
function Inst.Clone(o)
	local map = {}
	local function copy(src)
		local c = newInstance(src._class)
		map[src] = c
		for k, v in src._p do
			if type(v) ~= "table" or not v.Connect then
				c._p[k] = v
			end
		end
		c._attrs = table.clone(src._attrs)
		c._tags = table.clone(src._tags)
		for _, ch in src._children do
			copy(ch).Parent = c
		end
		return c
	end
	local root = copy(o)
	-- References inside the copied tree (PrimaryPart, weld parts) point at the copies.
	for _, c in map do
		for k, v in c._p do
			if type(v) == "table" and getmetatable(v) == Inst and map[v] then
				c._p[k] = map[v]
			end
		end
	end
	return root
end
function Inst.GetFullName(o)
	local names = {}
	local n = o
	while n do
		table.insert(names, 1, n._p.Name)
		n = rawget(n, "_parent")
	end
	return table.concat(names, ".")
end

local function partsOf(o)
	local out = {}
	if o:IsA("BasePart") then
		table.insert(out, o)
	end
	for _, d in o:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end
local function boundsOf(parts)
	local lo, hi = v3(math.huge, math.huge, math.huge), v3(-math.huge, -math.huge, -math.huge)
	for _, p in parts do
		local c, s = p._p.CFrame, p._p.Size / 2
		local ext = v3(
			abs(c.x.X) * s.X + abs(c.y.X) * s.Y + abs(c.z.X) * s.Z,
			abs(c.x.Y) * s.X + abs(c.y.Y) * s.Y + abs(c.z.Y) * s.Z,
			abs(c.x.Z) * s.X + abs(c.y.Z) * s.Y + abs(c.z.Z) * s.Z
		)
		lo = lo:Min(c.p - ext)
		hi = hi:Max(c.p + ext)
	end
	return lo, hi
end
Mock.boundsOf = boundsOf
Mock.partsOf = partsOf
function Inst.GetBoundingBox(o)
	local lo, hi = boundsOf(partsOf(o))
	return CFrame.new((lo + hi) / 2), hi - lo
end
function Inst.GetExtentsSize(o)
	local lo, hi = boundsOf(partsOf(o))
	return hi - lo
end
function Inst.GetPivot(o)
	if o:IsA("BasePart") then
		return o._p.CFrame * o._p.PivotOffset
	end
	local pp = o._p.PrimaryPart
	if pp then
		return pp._p.CFrame * pp._p.PivotOffset
	end
	if o._p.WorldPivot then
		return o._p.WorldPivot
	end
	local parts = partsOf(o)
	if #parts == 0 then
		return CFrame.identity
	end
	local lo, hi = boundsOf(parts)
	return CFrame.new((lo + hi) / 2)
end
function Inst.PivotTo(o, target)
	local delta = target * o:GetPivot():Inverse()
	if o:IsA("BasePart") then
		o._p.CFrame = delta * o._p.CFrame
	end
	for _, d in o:GetDescendants() do
		if d:IsA("BasePart") then
			d._p.CFrame = delta * d._p.CFrame
		end
	end
	if o._p.WorldPivot then
		o._p.WorldPivot = delta * o._p.WorldPivot
	end
end
function Inst.SetPrimaryPartCFrame(o, target)
	o:PivotTo(target)
end
function Inst.ScaleTo() end
function Inst.BreakJoints() end
function Inst.MakeJoints() end
function Inst.SetNetworkOwner() end
function Inst.Play() end
function Inst.Stop() end
function Inst.Emit() end
function Inst.MoveTo() end
function Inst.ChangeState() end
function Inst.GetPlayers()
	return {}
end
function Inst.LoadAnimation()
	return { Play = function() end, Stop = function() end }
end

local Instance = {
	new = function(className: string, parent: any?)
		local o = newInstance(className)
		if parent then
			o.Parent = parent
		end
		return o
	end,
}
env.Instance = Instance
Mock.Instance = Instance

---------------------------------------------------------------------------------------------
-- typeof, task, warn and friends
---------------------------------------------------------------------------------------------
env.typeof = function(x)
	if type(x) == "table" then
		local mt = getmetatable(x)
		if mt == Inst then
			return "Instance"
		elseif mt == V then
			return "Vector3"
		elseif mt == V2 then
			return "Vector2"
		elseif mt == C then
			return "CFrame"
		elseif mt == Col then
			return "Color3"
		elseif mt == EnumItem then
			return "EnumItem"
		elseif mt == RandomMeta then
			return "Random"
		elseif x.__type then
			return x.__type
		end
	end
	return type(x)
end
env.warn = function(...)
	local parts = {}
	for i = 1, select("#", ...) do
		table.insert(parts, tostring((select(i, ...))))
	end
	table.insert(Mock.warnings, table.concat(parts, " "))
end
env.task = {
	wait = function()
		return 0
	end,
	spawn = function() end,
	defer = function() end,
	delay = function() end,
	cancel = function() end,
}
env.wait = env.task.wait
env.spawn = env.task.spawn
env.delay = env.task.delay
env.tick = os.clock
env.time = os.clock
Mock.isCFrame = isC
Mock.isColor = isCol
Mock.isVector = isV

---------------------------------------------------------------------------------------------
-- Services, workspace, terrain
---------------------------------------------------------------------------------------------
local workspace = newInstance("Workspace")
workspace._p.Name = "Workspace"
local terrain = newInstance("Terrain")
terrain._p.Name = "Terrain"
terrain.Parent = workspace
local function terrainCall()
	Mock.terrainCalls += 1
end
terrain._p.FillBlock = terrainCall
terrain._p.FillBall = terrainCall
terrain._p.FillCylinder = terrainCall
terrain._p.FillWedge = terrainCall
terrain._p.ReplaceMaterial = terrainCall
terrain._p.WriteVoxels = terrainCall
terrain._p.Clear = terrainCall
Mock.materialColors = {}
terrain._p.SetMaterialColor = function(_, material, color)
	Mock.materialColors[material.Name] = color
end
workspace._p.Raycast = function(_, origin)
	return { Position = v3(origin.X, 0, origin.Z), Instance = terrain, Material = Enum.Material.Snow, Normal = AY }
end
workspace._p.Gravity = 196.2
env.workspace = workspace
Mock.workspace = workspace

local collection = {
	AddTag = function(_, inst, tag)
		inst._tags[tag] = true
	end,
	RemoveTag = function(_, inst, tag)
		inst._tags[tag] = nil
	end,
	HasTag = function(_, inst, tag)
		return inst._tags[tag] == true
	end,
	GetTagged = function(_, tag)
		local out = {}
		for _, d in workspace:GetDescendants() do
			if d._tags[tag] then
				table.insert(out, d)
			end
		end
		return out
	end,
	GetInstanceAddedSignal = function()
		return signal()
	end,
	GetInstanceRemovedSignal = function()
		return signal()
	end,
}

---------------------------------------------------------------------------------------------
-- File-backed module tree and require
---------------------------------------------------------------------------------------------
local moduleCache = {}
local overrides: { [string]: any } = {}
Mock.overrides = overrides -- path suffix ("/server/Registry") -> module value

local function exists(path: string): boolean
	return (pcall(__loadfile, path .. ".luau"))
end

local Node = {}
local function node(path: string)
	return setmetatable({ __path = path }, Node)
end
Node.__index = function(self, key)
	local path = rawget(self, "__path")
	if key == "Parent" then
		return node((path:match("^(.*)/[^/]+$")))
	elseif key == "Name" then
		return path:match("([^/]+)$")
	elseif key == "ClassName" then
		return if exists(path) then "ModuleScript" else "Folder"
	elseif key == "FindFirstChild" or key == "WaitForChild" then
		return function(_, name)
			local child = path .. "/" .. name
			if key == "FindFirstChild" and not exists(child) then
				return nil
			end
			return node(child)
		end
	elseif key == "IsA" then
		return function(_, cls)
			return cls == "Instance" or cls == (if exists(path) then "ModuleScript" else "Folder")
		end
	elseif key == "GetChildren" then
		return function()
			return {}
		end
	end
	return node(path .. "/" .. key)
end

local function req(target)
	local path = rawget(target, "__path")
	assert(path, "require: not a module node")
	for suffix, value in overrides do
		if path:sub(-#suffix) == suffix then
			return value
		end
	end
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end
	local fn = __loadfile(path .. ".luau")
	local menv = setmetatable({ script = target, require = req }, { __index = env })
	setfenv(fn, menv)
	local result = fn()
	moduleCache[path] = result
	return result
end
env.require = req
Mock.require = req
Mock.shared = node(ROOT .. "/src/shared")
Mock.server = node(ROOT .. "/src/server")

local replicated = newInstance("ReplicatedStorage")
replicated._p.Name = "ReplicatedStorage"
replicated._p.WaitForChild = function(_, name)
	if name == "Shared" then
		return Mock.shared
	end
	return replicated:FindFirstChild(name)
end
replicated._p.Shared = Mock.shared

local players = newInstance("Players")
players._p.Name = "Players"
players._p.GetPlayers = function()
	return {}
end

local services = {
	CollectionService = collection,
	Workspace = workspace,
	ReplicatedStorage = replicated,
	Players = players,
	RunService = {
		Heartbeat = signal(),
		Stepped = signal(),
		RenderStepped = signal(),
		IsServer = function()
			return true
		end,
		IsClient = function()
			return false
		end,
		IsStudio = function()
			return false
		end,
	},
}
local game = {
	GetService = function(_, name)
		local s = services[name]
		if not s then
			s = newInstance(name)
			s._p.Name = name
			services[name] = s
		end
		return s
	end,
	Workspace = workspace,
}
env.game = game
Mock.game = game

return Mock
