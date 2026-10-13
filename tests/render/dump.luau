-- Preview-renderer scene dump. Runs the REAL world and gear builders in a headless mock and
-- prints the resulting scene to stdout as tab-separated records:
--
--   luaurun tests/render/dump.luau <repo root>  > scene.tsv
--
-- (tests/render/render.py runs this for you and splits the output into a work directory.)
--
-- What runs, unmodified, from src/:
--   * WorldBuilder.build(): terrain op replay (recorded only), snow skirt, backdrop peaks,
--     CampKit.build for every WorldLayout camp, tree/rock scatter, wood, hazards, summit,
--     RouteKit bridges / ladders / markers / signs / fences / fixed ropes.
--   * EquipmentService.refresh() on an R15-sized dummy wearing LoadoutConfig's default
--     loadout (worn items + default pack + StarterPack contents, set up by the real
--     InventoryService.setupLoadout), i.e. exactly the gear a new player spawns with.
--   * TerrainModel.new(TerrainModel.ops(WorldLayout)).heightAt sampled on a 2-stud grid.
--
-- Records (first field is the record type):
--   P     id path class shape meshType msx msy msz mox moy moz sx sy sz px py pz
--         r00 r10 r20 r01 r11 r21 r02 r12 r22 (rotation columns: right, up, back)
--         r g b transparency material castShadow canCollide ancestry (instance ids, "." joined)
--   TXT   kind(surface|billboard) partId face/offset text r g b sx sy
--   GRID  x0 z0 step nx nz          then one TR record per row: TR iz heights materials
--   OP    terrain op fields (for wall materials in the renderer)
--   CAMP  id name x y z radius
--   ROUTE route index x y z via id
--   CHAR  name x y z yaw            (a character standing on the ground at x, y, z)
--   LIGHT class partId range brightness r g b
--   LOG / WARN                     builder prints and warnings
-- selene: allow(global_usage)
local ROOT = ROOT
local Mock = __loadfile(ROOT .. "/tests/render/RobloxMock.luau")(ROOT)
local V3, CF = Mock.Vector3.new, Mock.CFrame
local Instance = Mock.Instance

local out = {}
local function emit(...)
	local fields = { ... }
	for i, f in fields do
		if type(f) == "number" then
			fields[i] = if f == math.floor(f) and math.abs(f) < 1e9
				then string.format("%d", f)
				else string.format("%.4f", f)
		else
			fields[i] = tostring(f)
		end
	end
	table.insert(out, table.concat(fields, "\t"))
end
Mock.env.print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do
		table.insert(parts, tostring((select(i, ...))))
	end
	emit("LOG", (table.concat(parts, " "):gsub("[\t\n]", " ")))
end

local shared, server = Mock.shared, Mock.server
local WorldLayout = Mock.require(shared.Config.WorldLayout)
local TerrainModel = Mock.require(shared.Logic.TerrainModel)
local LoadoutConfig = Mock.require(shared.Config.LoadoutConfig)

---------------------------------------------------------------------------------------------
-- 1. The world, exactly as the server builds it
---------------------------------------------------------------------------------------------
local WorldBuilder = Mock.require(server.World.WorldBuilder)
local ok, err = pcall(WorldBuilder.build)
if not ok then
	emit("WARN", "WorldBuilder.build raised: " .. tostring(err))
end
emit("LOG", "terrain write calls recorded: " .. Mock.terrainCalls)

---------------------------------------------------------------------------------------------
-- 2. A character in the default loadout
---------------------------------------------------------------------------------------------
-- Standard R15 (scale 1, classic block body) part sizes and rest offsets from the
-- HumanoidRootPart, which stands HipHeight 2 + 1 (half its height) above the floor... the
-- R15 block rig stacks: foot 0.3, lower leg 1.193, upper leg 1.217, lower torso 0.4,
-- upper torso 1.6, head (classic mesh head, 1.25 studs).
local R15 = {
	{ "LeftFoot", V3(1, 0.3, 1), V3(-0.5, 0.15, 0) },
	{ "RightFoot", V3(1, 0.3, 1), V3(0.5, 0.15, 0) },
	{ "LeftLowerLeg", V3(1, 1.193, 1), V3(-0.5, 0.8965, 0) },
	{ "RightLowerLeg", V3(1, 1.193, 1), V3(0.5, 0.8965, 0) },
	{ "LeftUpperLeg", V3(1, 1.217, 1), V3(-0.5, 2.1015, 0) },
	{ "RightUpperLeg", V3(1, 1.217, 1), V3(0.5, 2.1015, 0) },
	{ "LowerTorso", V3(2, 0.4, 1), V3(0, 2.91, 0) },
	{ "UpperTorso", V3(2, 1.6, 1), V3(0, 3.91, 0) },
	{ "LeftUpperArm", V3(1, 1.169, 1), V3(-1.5, 4.1255, 0) },
	{ "RightUpperArm", V3(1, 1.169, 1), V3(1.5, 4.1255, 0) },
	{ "LeftLowerArm", V3(1, 1.052, 1), V3(-1.5, 3.015, 0) },
	{ "RightLowerArm", V3(1, 1.052, 1), V3(1.5, 3.015, 0) },
	{ "LeftHand", V3(1, 0.3, 1), V3(-1.5, 2.339, 0) },
	{ "RightHand", V3(1, 0.3, 1), V3(1.5, 2.339, 0) },
	{ "Head", V3(2, 1, 1), V3(0, 5.335, 0) },
}
local SKIN = Mock.env.Color3.fromRGB(234, 184, 146)

local function makeCharacter(name: string, x: number, z: number, yawDeg: number)
	local y = WorldBuilder.groundAt(x, z)
	local base = CF.new(x, y, z) * CF.Angles(0, math.rad(yawDeg), 0)
	local character = Instance.new("Model")
	character.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = V3(2, 2, 1)
	root.Transparency = 1
	root.CFrame = base * CF.new(0, 3, 0)
	root.Parent = character
	character.PrimaryPart = root
	for _, def in R15 do
		local p = Instance.new("Part")
		p.Name = def[1]
		p.Size = def[2]
		p.CFrame = base * CF.new(def[3])
		p.Color = SKIN
		p.Material = Mock.env.Enum.Material.SmoothPlastic
		p.Parent = character
		if def[1] == "Head" then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Mock.env.Enum.MeshType.Head
			mesh.Scale = V3(1.25, 1.25, 1.25)
			mesh.Parent = p
		end
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character
	character.Parent = Mock.workspace
	emit("CHAR", name, x, y, z, yawDeg)
	return character
end

local function dressDefault(character)
	local Registry = Mock.require(server.Registry)
	local PlayerStore = Mock.require(server.PlayerStore)
	local player = Instance.new("Player")
	player.Name = "Preview"
	player.UserId = 1
	player.Character = character
	local record = PlayerStore.create(player)
	local inventoryOk, inventoryErr = pcall(function()
		local InventoryService = Mock.require(server.Services.InventoryService)
		Registry.register("InventoryService", InventoryService)
		local stub = setmetatable({}, {
			__index = function()
				return function() end
			end,
		})
		for _, name in { "RemoteGuard", "SurvivalService", "WeatherService" } do
			Registry.register(name, stub)
		end
		InventoryService.setupLoadout(player, record, { loadout = {} })
	end)
	if not inventoryOk then
		emit("WARN", "InventoryService.setupLoadout failed in the mock: " .. tostring(inventoryErr))
	end
	record.ready = true
	local worn = {}
	for slot, id in record.worn do
		table.insert(worn, slot .. "=" .. id)
	end
	table.sort(worn)
	emit("LOG", "default loadout: " .. table.concat(worn, " ") .. " pack=" .. record.backpackId)
	local EquipmentService = Mock.require(server.Services.EquipmentService)
	EquipmentService.refresh(player, true)
	if not character:FindFirstChild("Gear") then
		emit("WARN", "EquipmentService built no Gear folder")
	end
	return LoadoutConfig
end

-- The main preview character stands in Base Camp facing the equipment tent door. Copies of
-- it (same builder output, moved with PivotTo) stand where the other shots need a person.
local main = makeCharacter("Player", -20, -12, 18.4)
dressDefault(main)
local function placeCopy(name: string, x: number, z: number, yawDeg: number)
	local copy = main:Clone()
	copy.Name = name
	local y = WorldBuilder.groundAt(x, z)
	copy:PivotTo(CF.new(x, y + 3, z) * CF.Angles(0, math.rad(yawDeg), 0))
	copy.Parent = Mock.workspace
	emit("CHAR", name, x, y, z, yawDeg)
end
placeCopy("Closeup", 60, 160, 0) -- open snow beside the valley trail, for the gear close-ups
placeCopy("Climber", 200, 2292, 180) -- at the foot of the ice-wall ladder, facing it
placeCopy("Hiker", -84, 1769, 180) -- about to cross the first crevasse bridge

---------------------------------------------------------------------------------------------
-- 3. Dump parts and text
---------------------------------------------------------------------------------------------
local function pathOf(inst): string
	local names = {}
	local n = inst.Parent
	while n and n ~= Mock.workspace do
		table.insert(names, 1, (n.Name:gsub("[\t/]", "_")))
		n = n.Parent
	end
	return table.concat(names, "/")
end
-- Unique ids of the ancestors (outermost first), so same-named siblings stay apart.
local function ancestryOf(inst): string
	local ids = {}
	local n = inst.Parent
	while n and n ~= Mock.workspace do
		table.insert(ids, 1, tostring(rawget(n, "_id")))
		n = n.Parent
	end
	return table.concat(ids, ".")
end

local partIds = {}
local count = 0
for _, d in Mock.workspace:GetDescendants() do
	if d:IsA("BasePart") and d.Name ~= "Terrain" then
		count += 1
		partIds[d] = count
		local c, s = d.CFrame, d.Size
		local mesh = d:FindFirstChildOfClass("SpecialMesh")
		local meshType, ms, mo = "-", V3(1, 1, 1), V3(0, 0, 0)
		if mesh then
			meshType = mesh.MeshType.Name
			ms = mesh.Scale
			mo = mesh.Offset
		end
		emit(
			"P",
			count,
			pathOf(d) .. "/" .. d.Name,
			d.ClassName,
			d.Shape.Name,
			meshType,
			ms.X,
			ms.Y,
			ms.Z,
			mo.X,
			mo.Y,
			mo.Z,
			s.X,
			s.Y,
			s.Z,
			c.X,
			c.Y,
			c.Z,
			c.RightVector.X,
			c.RightVector.Y,
			c.RightVector.Z,
			c.UpVector.X,
			c.UpVector.Y,
			c.UpVector.Z,
			c.ZVector.X,
			c.ZVector.Y,
			c.ZVector.Z,
			d.Color.R,
			d.Color.G,
			d.Color.B,
			d.Transparency,
			d.Material.Name,
			tostring(d.CastShadow),
			tostring(d.CanCollide),
			ancestryOf(d) .. "." .. tostring(rawget(d, "_id"))
		)
	end
end
emit("LOG", "parts dumped: " .. count)

for _, d in Mock.workspace:GetDescendants() do
	if d.ClassName == "TextLabel" then
		local gui = d.Parent
		local adornee = gui and gui.Parent
		local id = adornee and partIds[adornee]
		if id and gui.Enabled ~= false then
			local color = d.TextColor3 or Mock.env.Color3.new(1, 1, 1)
			local text = tostring(d.Text or ""):gsub("[\t\n]", " ")
			if gui.ClassName == "SurfaceGui" then
				local face = gui.Face and gui.Face.Name or "Front"
				emit("TXT", "surface", id, face, text, color.R, color.G, color.B, 0, 0)
			elseif gui.ClassName == "BillboardGui" then
				local off = gui.StudsOffsetWorldSpace or gui.StudsOffset or V3(0, 0, 0)
				-- BillboardGui.Size scale components are studs: UDim2.new(xStuds, 0, yStuds, 0).
				local size = (gui.Size and gui.Size.args) or { 1, 0, 1, 0 }
				local stroke = d.TextStrokeColor3 or Mock.env.Color3.new(0, 0, 0)
				emit(
					"TXT",
					"billboard",
					id,
					string.format("%.3f,%.3f,%.3f", off.X, off.Y, off.Z),
					text,
					color.R,
					color.G,
					color.B,
					size[1] or 1,
					size[3] or 1,
					stroke.R,
					stroke.G,
					stroke.B
				)
			end
		end
	end
end

for _, d in Mock.workspace:GetDescendants() do
	local cls = d.ClassName
	if (cls == "PointLight" or cls == "SpotLight") and d.Enabled ~= false then
		local parent = d.Parent
		local id = parent and partIds[parent]
		if id then
			local c = d.Color or Mock.env.Color3.new(1, 1, 1)
			emit("LIGHT", cls, id, d.Range or 8, d.Brightness or 1, c.R, c.G, c.B)
		end
	end
end

---------------------------------------------------------------------------------------------
-- 4. Terrain: heightfield + top material from the model the builder itself uses
---------------------------------------------------------------------------------------------
local ops = TerrainModel.ops(WorldLayout)
local model = TerrainModel.new(ops)
local MAT_CODE = { Snow = "S", Glacier = "G", Rock = "R", Slate = "L", Air = "A", Ice = "I" }
local b = WorldLayout.Bounds
local step = 2
local nx = math.floor((b.x1 - b.x0) / step) + 1
local nz = math.floor((b.z1 - b.z0) / step) + 1
emit("GRID", b.x0, b.z0, step, nx, nz)
for iz = 0, nz - 1 do
	local z = b.z0 + iz * step
	local hs = table.create(nx)
	local ms = table.create(nx)
	for ix = 0, nx - 1 do
		local h, m = model.heightAt(b.x0 + ix * step, z)
		if h == -math.huge then
			h = -999
		end
		hs[ix + 1] = string.format("%.2f", h)
		ms[ix + 1] = MAT_CODE[m] or "?"
	end
	table.insert(out, "TR\t" .. iz .. "\t" .. table.concat(hs, ",") .. "\t" .. table.concat(ms))
end
for _, op in ops do
	emit(
		"OP",
		op.name,
		op.shape,
		op.mode,
		op.material,
		if op.source == "" then "-" else op.source,
		op.cx,
		op.cy,
		op.cz,
		op.rx,
		op.ry,
		op.rz,
		op.ux,
		op.uy,
		op.uz,
		op.bx,
		op.by,
		op.bz,
		op.sx,
		op.sy,
		op.sz,
		op.radius,
		op.height
	)
end

---------------------------------------------------------------------------------------------
-- 5. Layout metadata (camps, route) for the camera presets and the route map
---------------------------------------------------------------------------------------------
for _, camp in WorldLayout.Camps do
	local x, z = camp.center.X, camp.center.Z
	emit("CAMP", camp.id, camp.name, x, WorldBuilder.groundAt(x, z), z, camp.radius or 0)
end
for i, p in WorldLayout.Route do
	emit("ROUTE", "Main", i, p.at.X, p.at.Y, p.at.Z, p.via or "Walk", p.id or "-")
end
for _, alt in WorldLayout.Alternates do
	for i, p in alt.points do
		emit("ROUTE", alt.name, i, p.at.X, p.at.Y, p.at.Z, p.via or "Walk", p.id or "-")
	end
end
for _, w in Mock.warnings do
	emit("WARN", (w:gsub("[\t\n]", " ")))
end
for _, line in out do
	print(line)
end
