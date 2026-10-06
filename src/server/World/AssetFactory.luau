--!strict
-- Asset construction from primitive parts (no meshes or texture ids).
--
-- CHARACTER EQUIPMENT (backpack, harness, hipBelt, iceAxe, ropeCoil, tarpRoll, woodBundle) is
-- built at the origin with real attachment points; EquipmentService positions and welds it:
--   * proportions are character-relative (R15 torso ~2 x 1.6 x 1 studs, 1 stud ~ 0.28 m),
--   * every component touches what it is attached to (straps reach the pack, the pick
--     meets the shaft, tarp edges meet stakes),
--   * slight colour jitter so nothing looks perfectly uniform.
--
-- WORLD PROPS (campfire, tents, camp dressing, trees, rocks...) follow art direction v2
-- (docs/ART_DIRECTION.md): stylized, bright and chunky. See the section header further down.
--
-- Swapping in real meshes: replace a builder's body with a clone of the artist's model, but
-- keep the same returned attachment / child names so the services keep working.

local AssetFactory = {}

local rng = Random.new(91827)

-- Material lookup that never errors on an enum member this engine build doesn't have.
local function material(name: string, fallback: Enum.Material): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else fallback
end

local RUBBER = material("Rubber", Enum.Material.SmoothPlastic)
local LEATHER = material("Leather", Enum.Material.Fabric)

local function jitter(color: Color3, amount: number?): Color3
	local a = amount or 0.04
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, math.clamp(s + rng:NextNumber(-a, a), 0, 1), math.clamp(v + rng:NextNumber(-a, a), 0, 1))
end

local function darker(color: Color3, f: number): Color3
	return Color3.new(color.R * f, color.G * f, color.B * f)
end

type PartProps = {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3?,
	material: Enum.Material?,
	shape: Enum.PartType?,
	transparency: number?,
	collide: boolean?,
	anchored: boolean?,
}

local function part(parent: Instance, props: PartProps): Part
	local p = Instance.new("Part")
	p.Name = props.name or "Part"
	p.Size = props.size
	p.CFrame = props.cframe
	p.Color = props.color or Color3.fromRGB(128, 128, 128)
	p.Material = props.material or Enum.Material.SmoothPlastic
	if props.shape then
		p.Shape = props.shape
	end
	p.Transparency = props.transparency or 0
	p.CanCollide = props.collide == true
	p.Anchored = props.anchored ~= false
	p.CanTouch = false
	p.CanQuery = props.collide == true
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end
AssetFactory.part = part

-- Cylinder along the segment a -> b (Roblox cylinders run along their local X axis).
local function cylinderBetween(
	parent: Instance,
	a: Vector3,
	b: Vector3,
	diameter: number,
	props: { [string]: any }?
): Part
	local length = math.max((b - a).Magnitude, 0.01)
	local mid = (a + b) / 2
	-- Build the basis explicitly (X along the segment). CFrame.lookAt degenerates for
	-- vertical segments such as tree trunks and poles.
	local dir = if (b - a).Magnitude > 1e-4 then (b - a).Unit else Vector3.xAxis
	local ref = if math.abs(dir.Y) < 0.99 then Vector3.yAxis else Vector3.xAxis
	local z = dir:Cross(ref).Unit
	local y = z:Cross(dir)
	local cf = CFrame.fromMatrix(mid, dir, y, z)
	local p = part(parent, {
		name = props and props.name or "Cylinder",
		size = Vector3.new(length, diameter, diameter),
		cframe = cf,
		color = props and props.color,
		material = props and props.material,
		shape = Enum.PartType.Cylinder,
		collide = props and props.collide,
		anchored = props and props.anchored,
	})
	return p
end
AssetFactory.cylinderBetween = cylinderBetween

-- Welds every BasePart in `model` to `primary` and makes them physics-free cosmetics.
function AssetFactory.weldCosmetic(model: Instance, primary: BasePart)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.Massless = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			if d ~= primary then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = primary
				weld.Part1 = d
				weld.Parent = d
			end
		end
	end
end

---------------------------------------------------------------------------------------------
-- CHARACTER EQUIPMENT (built at the origin; EquipmentService positions and welds them)
---------------------------------------------------------------------------------------------

local PACK_DIMENSIONS = {
	-- height, width, depth (studs), extra height above shoulders, hip belt
	Small = { 1.45, 1.45, 0.7, 0.0, false },
	Medium = { 1.85, 1.6, 0.85, 0.15, true },
	Large = { 2.15, 1.72, 1.0, 0.3, true },
	Expedition = { 2.45, 1.85, 1.15, 0.5, true },
}

-- Backpack in "pack space": origin at the centre of the wearer's back surface, +Z away from
-- the body, +Y up. Returns the model and named CFrames for stowed equipment.
function AssetFactory.backpack(tier: string, color: Color3): (Model, { [string]: CFrame })
	local dims = PACK_DIMENSIONS[tier] or PACK_DIMENSIONS.Small
	local h, w, d, lift = dims[1], dims[2], dims[3], dims[4]
	local model = Instance.new("Model")
	model.Name = "Backpack"
	local cy = lift + (0.8 - h / 2) -- top aligned near the shoulders
	local bodyColor = jitter(color, 0.03)

	-- Main bag: ripstop body. Slightly narrower at the top (load lifter taper) via two blocks.
	local body = part(model, {
		name = "Body",
		size = Vector3.new(w, h * 0.78, d),
		cframe = CFrame.new(0, cy - h * 0.06, d / 2),
		color = bodyColor,
		material = Enum.Material.Fabric,
	})
	model.PrimaryPart = body
	part(model, {
		name = "UpperBody",
		size = Vector3.new(w * 0.92, h * 0.16, d * 0.92),
		cframe = CFrame.new(0, cy + h * 0.39 - 0.02, d * 0.46),
		color = bodyColor,
		material = Enum.Material.Fabric,
	})
	-- Abrasion-resistant base panel: darker, dirtier fabric.
	part(model, {
		name = "BasePanel",
		size = Vector3.new(w + 0.02, h * 0.12, d + 0.02),
		cframe = CFrame.new(0, cy - h * 0.45 - h * 0.06 + h * 0.06, d / 2),
		color = darker(jitter(Color3.fromRGB(48, 44, 40)), 0.9),
		material = Enum.Material.Fabric,
	})
	-- Top lid: overhangs the body front and back, sits on the throat.
	local lidY = cy + h * 0.5
	part(model, {
		name = "Lid",
		size = Vector3.new(w * 0.96, h * 0.13, d * 1.08),
		cframe = CFrame.new(0, lidY, d * 0.52),
		color = darker(bodyColor, 0.92),
		material = Enum.Material.Fabric,
	})
	-- Lid zipper seam + metal pull on the outer face of the lid.
	part(model, {
		name = "LidZip",
		size = Vector3.new(w * 0.85, 0.035, 0.035),
		cframe = CFrame.new(0, lidY - 0.01, d * 1.06),
		color = Color3.fromRGB(25, 25, 25),
		material = Enum.Material.SmoothPlastic,
	})
	part(model, {
		name = "ZipPull",
		size = Vector3.new(0.06, 0.1, 0.03),
		cframe = CFrame.new(w * 0.3, lidY - 0.06, d * 1.075),
		color = Color3.fromRGB(150, 150, 155),
		material = Enum.Material.Metal,
	})
	-- Lid straps: webbing from lid down to buckles on the body front.
	for _, x in { -w * 0.28, w * 0.28 } do
		part(model, {
			name = "LidStrap",
			size = Vector3.new(0.12, h * 0.22, 0.03),
			cframe = CFrame.new(x, lidY - h * 0.12, d + 0.02),
			color = Color3.fromRGB(30, 30, 30),
			material = Enum.Material.Fabric,
		})
		part(model, {
			name = "LidBuckle",
			size = Vector3.new(0.16, 0.12, 0.05),
			cframe = CFrame.new(x, lidY - h * 0.23, d + 0.035),
			color = Color3.fromRGB(20, 20, 22),
			material = Enum.Material.SmoothPlastic,
		})
	end
	-- Side pockets (stretch mesh): lower half of each side.
	for _, side in { -1, 1 } do
		part(model, {
			name = "SidePocket",
			size = Vector3.new(0.14, h * 0.32, d * 0.75),
			cframe = CFrame.new(side * (w / 2 + 0.07), cy - h * 0.24, d * 0.5),
			color = darker(bodyColor, 0.75),
			material = Enum.Material.Fabric,
		})
		-- Compression straps: two per side, wrapping onto the side face.
		for _, fy in { 0.12, -0.08 } do
			part(model, {
				name = "CompressionStrap",
				size = Vector3.new(0.03, 0.09, d * 0.9),
				cframe = CFrame.new(side * (w / 2 + 0.015), cy + h * fy, d * 0.5),
				color = Color3.fromRGB(30, 30, 30),
				material = Enum.Material.Fabric,
			})
		end
	end
	-- Daisy chain on the outer face: where tools clip.
	part(model, {
		name = "DaisyChain",
		size = Vector3.new(0.1, h * 0.55, 0.03),
		cframe = CFrame.new(0, cy - h * 0.05, d + 0.015),
		color = Color3.fromRGB(35, 35, 35),
		material = Enum.Material.Fabric,
	})
	-- Ice axe loop at the bottom of the outer face.
	part(model, {
		name = "AxeLoop",
		size = Vector3.new(0.14, 0.14, 0.06),
		cframe = CFrame.new(w * 0.22, cy - h * 0.42, d + 0.03), -- under the stowed axe's head
		color = Color3.fromRGB(30, 30, 30),
		material = Enum.Material.Fabric,
	})
	-- Haul loop on top.
	part(model, {
		name = "HaulLoop",
		size = Vector3.new(0.25, 0.08, 0.05),
		cframe = CFrame.new(0, lidY + h * 0.07, 0.08),
		color = Color3.fromRGB(30, 30, 30),
		material = Enum.Material.Fabric,
	})
	-- Snow that settles on the lid; EquipmentService fades it in during snowfall.
	part(model, {
		name = "SnowCap",
		size = Vector3.new(w * 0.9, 0.05, d * 0.95),
		cframe = CFrame.new(0, lidY + h * 0.065 + 0.025, d * 0.52),
		color = Color3.fromRGB(240, 244, 250),
		material = Enum.Material.Snow,
		transparency = 1,
	})

	local anchors = {
		-- Ice axe, stowed the way climbers do it: head down in the axe loop at the base,
		-- shaft up the daisy chain, spike poking just above the lid. The axe model's grip
		-- origin sits 1.6 studs from its head, hence the offset; rotated 180 deg so the head is down.
		Axe = CFrame.new(w * 0.22, cy - h * 0.42 + 1.6, d + 0.12) * CFrame.Angles(0, 0, math.pi),
		-- Rope coil under the lid straps.
		Rope = CFrame.new(0, lidY - h * 0.14, d + 0.12),
		-- Tarp rolled under the base.
		Tarp = CFrame.new(0, cy - h * 0.5 - 0.17, d * 0.5),
		-- Wood strapped to the right side.
		Wood = CFrame.new(w / 2 + 0.2, cy - h * 0.05, d * 0.5),
	}
	return model, anchors
end

-- Harness in "torso space": origin at UpperTorso centre, torso size given.
-- Shoulder straps run from the top of the pack over each shoulder and down the chest,
-- joined by a sternum strap with a buckle. Hip belt is built separately on the LowerTorso.
function AssetFactory.harness(torsoSize: Vector3, packColor: Color3): Model
	local model = Instance.new("Model")
	model.Name = "Harness"
	local hx, hy, hz = torsoSize.X / 2, torsoSize.Y / 2, torsoSize.Z / 2
	local strapColor = darker(packColor, 0.45)
	local anchor = part(model, {
		name = "HarnessRoot",
		size = Vector3.new(0.05, 0.05, 0.05),
		cframe = CFrame.new(),
		transparency = 1,
	})
	model.PrimaryPart = anchor
	for _, side in { -1, 1 } do
		local x = side * hx * 0.48
		-- Over the shoulder.
		part(model, {
			name = "ShoulderPad",
			size = Vector3.new(0.32, 0.12, torsoSize.Z + 0.12),
			cframe = CFrame.new(x, hy + 0.05, 0),
			color = strapColor,
			material = Enum.Material.Fabric,
		})
		-- Down the chest (padded).
		part(model, {
			name = "ChestStrap",
			size = Vector3.new(0.3, hy * 1.25, 0.1),
			cframe = CFrame.new(x, hy * 0.4, -hz - 0.05),
			color = strapColor,
			material = Enum.Material.Fabric,
		})
		-- Webbing tail to the side of the pack.
		part(model, {
			name = "StrapTail",
			size = Vector3.new(0.08, hy * 0.6, 0.04),
			cframe = CFrame.new(side * (hx + 0.02), -hy * 0.35, -hz * 0.2) * CFrame.Angles(math.rad(20), 0, 0),
			color = Color3.fromRGB(30, 30, 30),
			material = Enum.Material.Fabric,
		})
	end
	part(model, {
		name = "SternumStrap",
		size = Vector3.new(hx * 0.96 + 0.3, 0.07, 0.05),
		cframe = CFrame.new(0, hy * 0.25, -hz - 0.11),
		color = Color3.fromRGB(30, 30, 30),
		material = Enum.Material.Fabric,
	})
	part(model, {
		name = "SternumBuckle",
		size = Vector3.new(0.16, 0.12, 0.05),
		cframe = CFrame.new(0, hy * 0.25, -hz - 0.14),
		color = Color3.fromRGB(15, 15, 18),
		material = Enum.Material.SmoothPlastic,
	})
	return model
end

-- Hip belt in "lower torso space".
function AssetFactory.hipBelt(lowerSize: Vector3, packColor: Color3): Model
	local model = Instance.new("Model")
	model.Name = "HipBelt"
	local hx, hz = lowerSize.X / 2, lowerSize.Z / 2
	local anchor = part(model, {
		name = "BeltRoot",
		size = Vector3.new(0.05, 0.05, 0.05),
		cframe = CFrame.new(),
		transparency = 1,
	})
	model.PrimaryPart = anchor
	for _, side in { -1, 1 } do
		part(model, {
			name = "HipWing",
			size = Vector3.new(0.12, 0.36, lowerSize.Z * 0.95),
			cframe = CFrame.new(side * (hx + 0.06), 0, 0.05),
			color = darker(packColor, 0.5),
			material = Enum.Material.Fabric,
		})
	end
	part(model, {
		name = "BeltWebbing",
		size = Vector3.new(lowerSize.X + 0.1, 0.1, 0.05),
		cframe = CFrame.new(0, 0, -hz - 0.03),
		color = Color3.fromRGB(28, 28, 28),
		material = Enum.Material.Fabric,
	})
	part(model, {
		name = "BeltBuckle",
		size = Vector3.new(0.3, 0.16, 0.06),
		cframe = CFrame.new(0, 0, -hz - 0.07),
		color = Color3.fromRGB(15, 15, 18),
		material = Enum.Material.SmoothPlastic,
	})
	return model
end

-- Ice axe, ~65 cm: built along +Y with the grip origin at (0,0,0) so it can be held.
-- Pick and adze are both joined to a solid head block riveted to the shaft top.
function AssetFactory.iceAxe(): Model
	local model = Instance.new("Model")
	model.Name = "IceAxe"
	local shaftLen = 1.9
	local shaftBottom = -0.35
	local shaft = part(model, {
		name = "Shaft",
		size = Vector3.new(0.13, shaftLen, 0.17), -- oval-ish alloy shaft
		cframe = CFrame.new(0, shaftBottom + shaftLen / 2, 0),
		color = Color3.fromRGB(70, 110, 170),
		material = Enum.Material.Metal,
	})
	model.PrimaryPart = shaft
	local top = shaftBottom + shaftLen
	-- Rubberised grip on the lower third.
	part(model, {
		name = "Grip",
		size = Vector3.new(0.16, 0.55, 0.2),
		cframe = CFrame.new(0, shaftBottom + 0.38, 0),
		color = Color3.fromRGB(28, 28, 30),
		material = RUBBER,
	})
	-- Spike: a short tapered steel point pressed into the shaft's end.
	part(model, {
		name = "SpikeCollar",
		size = Vector3.new(0.15, 0.12, 0.19),
		cframe = CFrame.new(0, shaftBottom - 0.04, 0),
		color = Color3.fromRGB(150, 150, 155),
		material = Enum.Material.Metal,
	})
	local spike = Instance.new("WedgePart")
	spike.Name = "Spike"
	spike.Size = Vector3.new(0.08, 0.2, 0.14)
	spike.CFrame = CFrame.new(0, shaftBottom - 0.2, 0) * CFrame.Angles(math.rad(180), 0, 0)
	spike.Color = Color3.fromRGB(165, 165, 170)
	spike.Material = Enum.Material.Metal
	spike.CanCollide = false
	spike.Anchored = true
	spike.Parent = model
	-- Head: forged steel block, riveted (two rivet heads visible).
	local headY = top + 0.05
	part(model, {
		name = "Head",
		size = Vector3.new(0.17, 0.22, 0.24),
		cframe = CFrame.new(0, headY, 0),
		color = Color3.fromRGB(155, 155, 160),
		material = Enum.Material.Metal,
	})
	for _, y in { -0.05, 0.05 } do
		part(model, {
			name = "Rivet",
			size = Vector3.new(0.19, 0.04, 0.04),
			cframe = CFrame.new(0, headY + y, 0),
			color = Color3.fromRGB(110, 110, 115),
			material = Enum.Material.Metal,
		})
	end
	-- Pick: long, slightly drooping, toothed underside (two segments give the droop).
	part(model, {
		name = "Pick",
		size = Vector3.new(0.06, 0.12, 0.4),
		cframe = CFrame.new(0, headY + 0.01, -0.3) * CFrame.Angles(math.rad(-6), 0, 0),
		color = Color3.fromRGB(150, 150, 155),
		material = Enum.Material.Metal,
	})
	part(model, {
		name = "PickTip",
		size = Vector3.new(0.05, 0.08, 0.2),
		cframe = CFrame.new(0, headY - 0.04, -0.58) * CFrame.Angles(math.rad(-16), 0, 0),
		color = Color3.fromRGB(175, 175, 180), -- worn bright at the edge
		material = Enum.Material.Metal,
	})
	-- Adze: wide flat blade on the opposite side.
	part(model, {
		name = "Adze",
		size = Vector3.new(0.3, 0.05, 0.3),
		cframe = CFrame.new(0, headY + 0.02, 0.25) * CFrame.Angles(math.rad(8), 0, 0),
		color = Color3.fromRGB(150, 150, 155),
		material = Enum.Material.Metal,
	})
	-- Attachment hole ring and wrist leash hanging from it.
	part(model, {
		name = "LeashRing",
		size = Vector3.new(0.17, 0.06, 0.06),
		cframe = CFrame.new(0, top - 0.25, 0),
		color = Color3.fromRGB(90, 90, 95),
		material = Enum.Material.Metal,
	})
	part(model, {
		name = "Leash",
		size = Vector3.new(0.04, 0.9, 0.07),
		cframe = CFrame.new(0.09, top - 0.72, 0.03) * CFrame.Angles(0, 0, math.rad(6)),
		color = Color3.fromRGB(200, 60, 40),
		material = Enum.Material.Fabric,
	})
	return model
end

-- Rope coil: two concentric loops of short segments so it reads as many wraps of a
-- braided rope (not a solid tube), with a whipping wrap where the coil is tied.
function AssetFactory.ropeCoil(color: Color3): Model
	local model = Instance.new("Model")
	model.Name = "RopeCoil"
	local root = part(model, {
		name = "CoilRoot",
		size = Vector3.new(0.05, 0.05, 0.05),
		cframe = CFrame.new(),
		transparency = 1,
	})
	model.PrimaryPart = root
	for loop, radius in { 0.42, 0.36 } do
		local segments = 14
		for i = 0, segments - 1 do
			local a0 = (i / segments) * math.pi * 2
			local a1 = ((i + 1) / segments) * math.pi * 2
			local p0 = Vector3.new(math.cos(a0) * radius, math.sin(a0) * radius * 0.55, (loop - 1.5) * 0.09)
			local p1 = Vector3.new(math.cos(a1) * radius, math.sin(a1) * radius * 0.55, (loop - 1.5) * 0.09)
			cylinderBetween(
				model,
				p0,
				p1,
				0.1,
				{ name = "RopeSeg", color = jitter(color, 0.05), material = Enum.Material.Fabric }
			)
		end
	end
	part(model, {
		name = "Whipping",
		size = Vector3.new(0.22, 0.2, 0.26),
		cframe = CFrame.new(0, 0.22, 0),
		color = darker(color, 0.7),
		material = Enum.Material.Fabric,
	})
	return model
end

function AssetFactory.tarpRoll(): Model
	local model = Instance.new("Model")
	model.Name = "TarpRoll"
	local roll = cylinderBetween(model, Vector3.new(-0.7, 0, 0), Vector3.new(0.7, 0, 0), 0.34, {
		name = "Roll",
		color = jitter(Color3.fromRGB(60, 110, 70)),
		material = Enum.Material.Fabric,
	})
	model.PrimaryPart = roll
	for _, x in { -0.45, 0.45 } do
		cylinderBetween(model, Vector3.new(x - 0.04, 0, 0), Vector3.new(x + 0.04, 0, 0), 0.37, {
			name = "Strap",
			color = Color3.fromRGB(25, 25, 25),
			material = Enum.Material.Fabric,
		})
	end
	return model
end

-- 1-3 split logs strapped together, oriented vertically for the side of a pack.
function AssetFactory.woodBundle(count: number): Model
	local model = Instance.new("Model")
	model.Name = "WoodBundle"
	local root = part(model, {
		name = "BundleRoot",
		size = Vector3.new(0.05, 0.05, 0.05),
		cframe = CFrame.new(),
		transparency = 1,
	})
	model.PrimaryPart = root
	local logs = math.clamp(count, 1, 3)
	for i = 1, logs do
		local offset = Vector3.new(0, 0, (i - (logs + 1) / 2) * 0.24)
		cylinderBetween(
			model,
			offset + Vector3.new(0, -0.7, 0),
			offset + Vector3.new(0, 0.7, 0),
			0.22 + rng:NextNumber(-0.03, 0.03),
			{
				name = "Log",
				color = jitter(Color3.fromRGB(105, 75, 50), 0.06),
				material = Enum.Material.Wood,
			}
		)
	end
	for _, y in { -0.35, 0.35 } do
		part(model, {
			name = "Strap",
			size = Vector3.new(0.28, 0.07, logs * 0.24 + 0.06),
			cframe = CFrame.new(0, y, 0),
			color = Color3.fromRGB(28, 28, 28),
			material = Enum.Material.Fabric,
		})
	end
	return model
end

---------------------------------------------------------------------------------------------
-- WORLD PROPS (art direction v2, docs/ART_DIRECTION.md)
---------------------------------------------------------------------------------------------
-- Every builder takes `at`, a CFrame standing on the ground; the prop's front (door, label,
-- face) points along at.LookVector (local -Z). Look: bright saturated colours on SmoothPlastic,
-- Fabric only for tent skins and carpets, Wood/WoodPlanks for crates and poles, Metal for
-- rails. Big readable silhouettes first, detail second, nothing thinner than ~0.2 studs.
-- Decorative parts never collide, query or touch; walls, floors, trunks and crates that players
-- walk in or bump against collide. Only big shapes cast shadows.

local PALETTE = {
	snow = Color3.fromRGB(236, 242, 250),
	snowCap = Color3.fromRGB(246, 249, 255),
	ice = Color3.fromRGB(92, 205, 214),
	yellow = Color3.fromRGB(245, 200, 40),
	blue = Color3.fromRGB(40, 120, 220),
	red = Color3.fromRGB(210, 45, 45),
	purple = Color3.fromRGB(120, 60, 180),
	orange = Color3.fromRGB(235, 110, 30),
	rescue = Color3.fromRGB(235, 95, 35),
	crate = Color3.fromRGB(214, 180, 120),
	pole = Color3.fromRGB(120, 85, 55),
	markerRed = Color3.fromRGB(220, 40, 40),
	white = Color3.fromRGB(245, 245, 245),
	green = Color3.fromRGB(40, 220, 60),
	navy = Color3.fromRGB(0, 70, 140),
	uiBlue = Color3.fromRGB(0, 110, 200),
	cyan = Color3.fromRGB(0, 230, 255),
	stone = Color3.fromRGB(132, 138, 148),
	stoneDark = Color3.fromRGB(108, 114, 126),
	pine = Color3.fromRGB(38, 128, 84),
	trunk = Color3.fromRGB(122, 80, 48),
	log = Color3.fromRGB(150, 98, 56),
	char = Color3.fromRGB(38, 30, 28),
	metal = Color3.fromRGB(150, 156, 166),
	dark = Color3.fromRGB(36, 38, 46),
	window = Color3.fromRGB(44, 62, 96),
	glass = Color3.fromRGB(120, 225, 245),
	rope = Color3.fromRGB(240, 238, 230),
	ember = Color3.fromRGB(255, 120, 30),
	warmLight = Color3.fromRGB(255, 196, 120),
}
AssetFactory.Palette = PALETTE

type Opts = {
	collide: boolean?, -- walls/floors/trunks: true; anything decorative: leave nil
	shadow: boolean?, -- default: only shapes 4+ studs across cast shadows
	transparency: number?,
	shape: Enum.PartType?,
}

local function newModel(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

local function shade(p: BasePart, opts: Opts?)
	if opts and opts.shadow ~= nil then
		p.CastShadow = opts.shadow
	else
		p.CastShadow = math.max(p.Size.X, p.Size.Y, p.Size.Z) >= 4
	end
end

local function block(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	mat: Enum.Material?,
	opts: Opts?
): Part
	local p = part(parent, {
		name = name,
		size = size,
		cframe = cf,
		color = color,
		material = mat,
		shape = opts and opts.shape,
		transparency = opts and opts.transparency,
		collide = opts and opts.collide,
	})
	shade(p, opts)
	return p
end

local function wedge(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	mat: Enum.Material?,
	opts: Opts?
): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Size = size
	w.CFrame = cf
	w.Color = color
	w.Material = mat or Enum.Material.SmoothPlastic
	w.Transparency = opts and opts.transparency or 0
	local collide = opts ~= nil and opts.collide == true
	w.CanCollide = collide
	w.CanQuery = collide
	w.CanTouch = false
	w.Anchored = true
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	shade(w, opts)
	w.Parent = parent
	return w
end

-- Cylinder from world point a to world point b.
local function rod(
	parent: Instance,
	name: string,
	a: Vector3,
	b: Vector3,
	diameter: number,
	color: Color3,
	mat: Enum.Material?,
	opts: Opts?
): Part
	local p = cylinderBetween(parent, a, b, diameter, {
		name = name,
		color = color,
		material = mat or Enum.Material.SmoothPlastic,
		collide = opts and opts.collide,
	})
	if opts and opts.transparency then
		p.Transparency = opts.transparency
	end
	shade(p, opts)
	return p
end

-- Ellipsoid filling `size` (a block with a built-in Sphere SpecialMesh; no asset id).
-- Collision, if any, is the block's box.
local function blob(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	mat: Enum.Material?,
	opts: Opts?
): (Part, SpecialMesh)
	local p = block(parent, name, size, cf, color, mat, opts)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p, mesh
end

-- Makes `p` the model's PrimaryPart with the model pivot at `pivot` (cylinders are rotated so
-- their axis runs along X; this keeps GetPivot()/PivotTo() upright).
local function setPrimary(model: Model, p: BasePart, pivot: CFrame)
	model.PrimaryPart = p
	p.PivotOffset = p.CFrame:ToObjectSpace(pivot)
end

-- Right-triangle wedge standing on the origin of `base`: its tall vertical edge is on the
-- base origin and its slope runs down along `dir` (a horizontal unit vector in base space),
-- `reach` studs out, `height` tall, `width` thick. Roblox WedgeParts slope down toward their
-- local -Z (front) face, so local -Z is aligned with `dir`.
local function fin(
	parent: Instance,
	name: string,
	base: CFrame,
	dir: Vector3,
	reach: number,
	height: number,
	width: number,
	color: Color3,
	mat: Enum.Material?,
	opts: Opts?
): WedgePart
	local pos = dir * (reach / 2) + Vector3.new(0, height / 2, 0)
	local right = dir:Cross(Vector3.yAxis)
	return wedge(
		parent,
		name,
		Vector3.new(width, height, reach),
		base * CFrame.fromMatrix(pos, right, Vector3.yAxis),
		color,
		mat,
		opts
	)
end

-- Isosceles gable wall (two fins back to back) in base's XY plane, `width` wide at the bottom.
local function gable(
	parent: Instance,
	name: string,
	base: CFrame,
	width: number,
	height: number,
	thick: number,
	color: Color3,
	mat: Enum.Material?,
	opts: Opts?
)
	fin(parent, name, base, Vector3.xAxis, width / 2, height, thick, color, mat, opts)
	fin(parent, name, base, -Vector3.xAxis, width / 2, height, thick, color, mat, opts)
end

-- Rectangular slab whose centre line runs from a to b (points in base space), `width` wide
-- along `across`, `thick` deep, pushed `lift` studs along its face normal; the normal is
-- flipped to agree with `outward`.
local function slab(
	parent: Instance,
	name: string,
	base: CFrame,
	a: Vector3,
	b: Vector3,
	across: Vector3,
	width: number,
	thick: number,
	lift: number,
	outward: Vector3,
	color: Color3,
	mat: Enum.Material?,
	opts: Opts?
): Part
	local along = (b - a).Unit
	local side = (across - along * across:Dot(along)).Unit
	local up = side:Cross(along)
	if up:Dot(outward) < 0 then
		up = -up
	end
	local centre = (a + b) / 2 + up * lift
	return block(
		parent,
		name,
		Vector3.new((b - a).Magnitude, thick, width),
		base * CFrame.fromMatrix(centre, along, up),
		color,
		mat,
		opts
	)
end

local function surfaceText(p: BasePart, face: Enum.NormalId, text: string, color: Color3): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label" .. face.Name
	gui.Face = face
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = p
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.92, 0.78)
	label.Position = UDim2.fromScale(0.04, 0.11)
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.Parent = gui
	return gui
end

-- Floating text label (BillboardGui) sized in studs so it reads as part of the world.
function AssetFactory.billboard(
	adornee: BasePart,
	text: string,
	color: Color3,
	stroke: Color3,
	sizeStuds: Vector2,
	offsetY: number,
	maxDistance: number
): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.new(sizeStuds.X, 0, sizeStuds.Y, 0)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.MaxDistance = maxDistance
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Parent = adornee
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeColor3 = stroke
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Parent = gui
	return gui
end

local function stake(parent: Instance, pos: Vector3)
	block(
		parent,
		"Stake",
		Vector3.new(0.3, 1, 0.3),
		CFrame.new(pos + Vector3.new(0, 0.1, 0)),
		PALETTE.metal,
		Enum.Material.Metal,
		{ shadow = false }
	)
end

local function guyLine(parent: Instance, from: Vector3, to: Vector3)
	rod(parent, "GuyLine", from, to + Vector3.new(0, 0.45, 0), 0.12, PALETTE.rope, nil, { shadow = false })
	stake(parent, to)
end

---------------------------------------------------------------------------------------------
-- Campfire: the social centre. Stone ring, chunky log teepee with charred tips, glowing ember
-- mound, two layered flames, rising sparks, a warm light and a wisp of smoke. The child part
-- "Embers" hosts the effects and BuildingService's prompts; extinguishing destroys its Fire and
-- PointLight children, which also switches the sparks off here.
function AssetFactory.campfire(at: CFrame): Model
	local model = newModel("Campfire")
	local base =
		blob(model, "Base", Vector3.new(4.6, 0.36, 4.6), at, Color3.fromRGB(84, 76, 72), nil, { shadow = false })
	model.PrimaryPart = base
	for i = 0, 9 do
		local a = i / 10 * math.pi * 2
		local w = 1.0 + rng:NextNumber(0, 0.3)
		local h = 0.75 + rng:NextNumber(0, 0.3)
		block(
			model,
			"RingStone",
			Vector3.new(w, h, 0.95),
			at
				* CFrame.new(math.cos(a) * 2.2, h / 2 - 0.1, math.sin(a) * 2.2)
				* CFrame.Angles(0, math.pi / 2 - a, rng:NextNumber(-0.1, 0.1)),
			jitter(PALETTE.stone, 0.05),
			nil,
			{ shadow = false }
		)
	end
	local apex = (at * CFrame.new(0, 3.3, 0)).Position
	for i = 0, 4 do
		local a = i / 5 * math.pi * 2 + 0.4
		local foot = (at * CFrame.new(math.cos(a) * 1.5, 0.15, math.sin(a) * 1.5)).Position
		rod(model, "Log", foot, apex:Lerp(foot, 0.22), 0.58, jitter(PALETTE.log, 0.04), Enum.Material.Wood, {
			shadow = true,
		})
		rod(model, "Char", apex:Lerp(foot, 0.22), apex:Lerp(foot, 0.06), 0.6, PALETTE.char, Enum.Material.Wood, {
			shadow = false,
		})
	end
	local embers = blob(
		model,
		"Embers",
		Vector3.new(2.6, 0.8, 2.6),
		at * CFrame.new(0, 0.12, 0),
		PALETTE.ember,
		Enum.Material.Neon,
		{ shadow = false }
	)
	local flame = Instance.new("Fire")
	flame.Name = "Flame"
	flame.Size = 8
	flame.Heat = 12
	flame.Color = Color3.fromRGB(255, 150, 40)
	flame.SecondaryColor = Color3.fromRGB(255, 70, 15)
	flame.Parent = embers
	local flicker = Instance.new("Fire")
	flicker.Name = "Flicker"
	flicker.Size = 4
	flicker.Heat = 20
	flicker.Color = Color3.fromRGB(255, 215, 90)
	flicker.SecondaryColor = Color3.fromRGB(255, 120, 25)
	flicker.Parent = embers
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "Sparks"
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 210, 90), Color3.fromRGB(255, 90, 20))
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.22), NumberSequenceKeypoint.new(1, 0) })
	sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.5) })
	sparks.Lifetime = NumberRange.new(1.2, 2.4)
	sparks.Rate = 14
	sparks.Speed = NumberRange.new(5, 9)
	sparks.SpreadAngle = Vector2.new(22, 22)
	sparks.Acceleration = Vector3.new(0, 1.5, 0)
	sparks.Drag = 1.2
	sparks.EmissionDirection = Enum.NormalId.Top
	sparks.Parent = embers
	local smoke = Instance.new("Smoke")
	smoke.Opacity = 0.05
	smoke.RiseVelocity = 7
	smoke.Size = 5
	smoke.Color = Color3.fromRGB(205, 205, 210)
	smoke.Parent = embers
	local light = Instance.new("PointLight")
	light.Brightness = 3
	light.Range = 28
	light.Color = Color3.fromRGB(255, 170, 90)
	light.Shadows = true
	light.Parent = embers
	-- When the fire goes out (BuildingService destroys the Fire children) stop the sparks too.
	embers.ChildRemoved:Connect(function(child)
		if child:IsA("Fire") then
			sparks.Enabled = false
		end
	end)
	return model
end

-- A-frame tarp shelter (player-built): two poles, a ridge line, a bright tarp pitched as two
-- pairs of panels sagging slightly between supports, staked edges and guy lines. BuildingService
-- relies on PrimaryPart "Floor" and the "RoofSnow" parts (faded in during snowfall); its
-- interior box (6.6 x 5.2 x 9) matches these dimensions.
function AssetFactory.tarpShelter(at: CFrame): Model
	local model = newModel("TarpShelter")
	local length, halfWidth, ridge = 9, 3.6, 5.2
	local floor = block(
		model,
		"Floor",
		Vector3.new(halfWidth * 2, 0.2, length),
		at * CFrame.new(0, 0.1, 0),
		Color3.fromRGB(60, 84, 120),
		Enum.Material.Fabric,
		{ shadow = false }
	)
	model.PrimaryPart = floor
	local tarpColor = PALETTE.orange
	local poleTops = {}
	for _, z in { -length / 2, length / 2 } do
		local bottom = (at * CFrame.new(0, -0.3, z)).Position
		local topPos = (at * CFrame.new(0, ridge + 0.5, z)).Position
		rod(model, "Pole", bottom, topPos, 0.36, PALETTE.pole, Enum.Material.Wood, { shadow = true })
		table.insert(poleTops, topPos)
	end
	rod(model, "RidgeLine", poleTops[1], poleTops[2], 0.16, PALETTE.rope, nil, { shadow = false })
	-- Tarp panels: for each side, two panels from the ridge to the ground edge.
	local sag = 0.25
	for _, side in { -1, 1 } do
		for _, half in { -1, 1 } do
			local zNear, zFar = 0, half * length / 2
			local ridgeMid = (at * CFrame.new(0, ridge - sag, zNear)).Position
			local ridgeEnd = (at * CFrame.new(0, ridge, zFar)).Position
			local groundMid = (at * CFrame.new(side * halfWidth, 0.25, zNear)).Position
			local ridgeCentre = (ridgeMid + ridgeEnd) / 2
			local groundCentre = (groundMid + (at * CFrame.new(side * halfWidth, 0.25, zFar)).Position) / 2
			local centre = (ridgeCentre + groundCentre) / 2
			local slopeLength = (ridgeCentre - groundCentre).Magnitude
			local along = (ridgeEnd - ridgeMid).Unit
			local down = (groundCentre - ridgeCentre).Unit
			local normal = along:Cross(down).Unit
			block(
				model,
				"TarpPanel",
				Vector3.new(length / 2 + 0.05, 0.22, slopeLength + 0.1),
				CFrame.fromMatrix(centre, along, normal),
				jitter(tarpColor, 0.02),
				Enum.Material.Fabric,
				{ collide = true, shadow = true }
			)
		end
		for _, z in { -length / 2, 0, length / 2 } do
			stake(model, (at * CFrame.new(side * (halfWidth + 0.15), 0, z)).Position)
		end
	end
	for i, z in { -length / 2 - 2.8, length / 2 + 2.8 } do
		guyLine(model, poleTops[i], (at * CFrame.new(0, 0, z)).Position)
	end
	-- Snow that accumulates on the roof during snowfall (faded in by BuildingService).
	for _, side in { -1, 1 } do
		local cf = at * CFrame.new(side * halfWidth * 0.5, ridge * 0.55, 0) * CFrame.Angles(0, 0, math.rad(side * -55))
		block(
			model,
			"RoofSnow",
			Vector3.new(halfWidth * 1.15, 0.25, length * 0.95),
			cf * CFrame.new(0, 0.2, 0),
			PALETTE.snowCap,
			nil,
			{ transparency = 1, shadow = false }
		)
	end
	return model
end

-- Wind wall: chunky stacked logs between two driven posts, a drift of snow along the top.
function AssetFactory.windWall(at: CFrame): Model
	local model = newModel("WindWall")
	local width, height = 11, 5
	local base = block(
		model,
		"Base",
		Vector3.new(width + 0.6, 0.5, 1.8),
		at * CFrame.new(0, 0.05, 0),
		PALETTE.snow,
		nil,
		{ shadow = false }
	)
	model.PrimaryPart = base
	for _, x in { -width / 2, width / 2 } do
		rod(
			model,
			"Post",
			(at * CFrame.new(x, -0.5, 0)).Position,
			(at * CFrame.new(x, height + 0.6, 0)).Position,
			0.5,
			darker(PALETTE.log, 0.8),
			Enum.Material.Wood,
			{ collide = true }
		)
	end
	local rows = 6
	for i = 0, rows - 1 do
		local y = 0.42 + i * (height / rows)
		local z = if i % 2 == 0 then -0.12 else 0.12
		rod(
			model,
			"Log",
			(at * CFrame.new(-width / 2 + 0.1, y, z)).Position,
			(at * CFrame.new(width / 2 - 0.1, y, z)).Position,
			0.84,
			jitter(PALETTE.log, 0.05),
			Enum.Material.Wood,
			{ collide = true }
		)
	end
	blob(
		model,
		"SnowCap",
		Vector3.new(width * 0.95, 0.6, 1.1),
		at * CFrame.new(0, 0.42 + (rows - 1) * (height / rows) + 0.4, 0),
		PALETTE.snowCap,
		nil,
		{ shadow = false }
	)
	return model
end

-- Route marker: red/white striped pole with a small red flag (PointLight so it reads in fog).
function AssetFactory.trailMarker(at: CFrame): Model
	local model = newModel("TrailMarker")
	local stake = rod(
		model,
		"Stake",
		(at * CFrame.new(0, -0.6, 0)).Position,
		(at * CFrame.new(0, 5.6, 0)).Position,
		0.3,
		PALETTE.white,
		nil,
		{ collide = true, shadow = false }
	)
	setPrimary(model, stake, at)
	for i = 0, 2 do
		local y0 = 0.5 + i * 1.6
		rod(
			model,
			"Stripe",
			(at * CFrame.new(0, y0, 0)).Position,
			(at * CFrame.new(0, y0 + 0.8, 0)).Position,
			0.34,
			PALETTE.markerRed,
			nil,
			{ shadow = false }
		)
	end
	local flag = block(
		model,
		"Flag",
		Vector3.new(0.12, 0.9, 1.3),
		at * CFrame.new(0, 5.05, 0.8),
		PALETTE.markerRed,
		Enum.Material.Fabric,
		{ shadow = false }
	)
	local light = Instance.new("PointLight")
	light.Range = 10
	light.Brightness = 1
	light.Color = Color3.fromRGB(255, 120, 90)
	light.Parent = flag
	return model
end

-- Stylized snowy pine: 3-4 stacked "cones", each a ring of five sloped wedge boughs; when snowy
-- every bough carries a thick snow layer (green sides and tips still show) and the top a cap.
-- About 32 parts snowy, 17 bare.
function AssetFactory.pineTree(at: CFrame, height: number, snowy: boolean, seed: number): Model
	local r = Random.new(seed)
	local model = newModel("Pine")
	local h = math.max(height, 6)
	local trunk = rod(
		model,
		"Trunk",
		(at * CFrame.new(0, -1, 0)).Position,
		(at * CFrame.new(0, h * 0.5, 0)).Position,
		math.max(0.8, h * 0.07),
		jitter(PALETTE.trunk, 0.04),
		Enum.Material.Wood,
		{ collide = true }
	)
	setPrimary(model, trunk, at)
	local tiers = if h >= 26 then 4 else 3
	local foliageBase = h * 0.16
	local tierH = (h - foliageBase) * (if tiers == 4 then 0.4 else 0.48)
	local step = (h - foliageBase - tierH) / (tiers - 1)
	local yaw0 = r:NextNumber(0, math.pi * 2)
	local green = jitter(PALETTE.pine, 0.04)
	-- Snow layer on each bough: a similar wedge 88% the size, lifted so its slope runs parallel
	-- to the bough's, `snowDepth` above it; the bough's green sides and tip still show.
	local snowDepth = math.clamp(h * 0.018, 0.25, 0.5)
	for i = 0, tiers - 1 do
		local t = i / (tiers - 1)
		local reach = h * (0.3 - 0.15 * t)
		local base = at * CFrame.new(0, foliageBase + i * step, 0)
		for k = 0, 4 do
			local a = yaw0 + i * 0.63 + k / 5 * math.pi * 2
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			fin(model, "Bough", base, dir, reach, tierH, reach * 0.8, darker(green, 0.84 + 0.16 * t), nil, {
				shadow = true,
			})
			if snowy then
				fin(
					model,
					"Snow",
					base * CFrame.new(0, tierH * 0.12 + snowDepth, 0),
					dir,
					reach * 0.88,
					tierH * 0.88,
					reach * 0.62,
					PALETTE.snowCap,
					nil,
					{ shadow = false }
				)
			end
		end
		if i == tiers - 1 then
			blob(
				model,
				if snowy then "SnowTip" else "Tip",
				Vector3.new(reach * 0.6, tierH * 0.4, reach * 0.6),
				base * CFrame.new(0, tierH + (if snowy then snowDepth else 0), 0),
				if snowy then PALETTE.snowCap else green,
				nil,
				{ shadow = false }
			)
		end
	end
	return model
end

-- Chunky grey rock cluster (2-3 blocks) with rounded snow pillows on top when snowy.
function AssetFactory.rock(at: CFrame, size: number, snowy: boolean, seed: number): Model
	local r = Random.new(seed)
	local model = newModel("Rock")
	local first: Part? = nil
	for i = 1, r:NextInteger(2, 3) do
		local s = size * (if i == 1 then 1 else r:NextNumber(0.45, 0.75))
		local sz = Vector3.new(s * r:NextNumber(0.95, 1.3), s * r:NextNumber(0.6, 0.85), s * r:NextNumber(0.85, 1.15))
		local off = if i == 1
			then Vector3.zero
			else Vector3.new(r:NextNumber(-0.55, 0.55) * size, 0, r:NextNumber(-0.55, 0.55) * size)
		local cf = at
			* CFrame.new(off.X, sz.Y * 0.35, off.Z)
			* CFrame.Angles(r:NextNumber(-0.1, 0.1), r:NextNumber(0, math.pi), r:NextNumber(-0.1, 0.1))
		local p = block(
			model,
			"Fragment",
			sz,
			cf,
			jitter(if i == 1 then PALETTE.stone else PALETTE.stoneDark, 0.04),
			nil,
			{ collide = true }
		)
		first = first or p
		if snowy then
			blob(
				model,
				"Snow",
				Vector3.new(sz.X * 0.92, math.max(0.6, sz.Y * 0.4), sz.Z * 0.92),
				cf * CFrame.new(0, sz.Y / 2, 0),
				PALETTE.snowCap
			)
		end
	end
	model.PrimaryPart = first
	return model
end

-- Fallen log: chunky trunk with a pale sawn end, branch stubs and snow along the top.
function AssetFactory.fallenLog(at: CFrame, seed: number): Model
	local r = Random.new(seed)
	local model = newModel("FallenLog")
	local len = r:NextNumber(7, 11)
	local d = r:NextNumber(1.2, 1.6)
	local a = (at * CFrame.new(-len / 2, d / 2, 0)).Position
	local b = (at * CFrame.new(len / 2, d / 2, 0)).Position
	local log = rod(model, "Trunk", a, b, d, jitter(PALETTE.log, 0.05), Enum.Material.Wood, { collide = true })
	setPrimary(model, log, at)
	rod(model, "SawnEnd", b, b + (b - a).Unit * 0.08, d * 0.9, Color3.fromRGB(232, 196, 140), Enum.Material.Wood)
	block(
		model,
		"Snow",
		Vector3.new(len * 0.85, 0.3, d * 0.55),
		at * CFrame.new(0, d * 0.97, 0),
		PALETTE.snowCap,
		nil,
		{ shadow = false }
	)
	for _ = 1, 2 do
		local t = r:NextNumber(0.2, 0.8)
		local p = a:Lerp(b, t) + Vector3.new(0, d * 0.3, 0)
		rod(
			model,
			"BranchStub",
			p,
			p + Vector3.new(r:NextNumber(-0.5, 0.5), r:NextNumber(0.6, 1.0), r:NextNumber(-0.5, 0.5)),
			d * 0.25,
			darker(PALETTE.log, 0.85),
			Enum.Material.Wood
		)
	end
	return model
end

-- Closed log cabin: walls with a front doorway, gable ends, a red pitched roof under snow,
-- cyan windows, a chimney and a porch lamp. Returns the model and its interior box.
function AssetFactory.cabin(at: CFrame, size: Vector3): (Model, CFrame, Vector3)
	local model = newModel("Cabin")
	local w, h, d = size.X, size.Y, size.Z
	local wall = 0.8
	local logColor = Color3.fromRGB(176, 116, 66)
	local floor = block(
		model,
		"Floor",
		Vector3.new(w, 0.6, d),
		at * CFrame.new(0, 0.3, 0),
		darker(PALETTE.crate, 0.8),
		Enum.Material.WoodPlanks,
		{ collide = true }
	)
	model.PrimaryPart = floor
	local function wallPart(cf: CFrame, s: Vector3)
		block(model, "Wall", s, at * cf, jitter(logColor, 0.02), Enum.Material.Wood, { collide = true })
	end
	local door = math.min(5, w * 0.3)
	local doorH = math.min(7, h - 1)
	local side = (w - door) / 2
	wallPart(CFrame.new(0, h / 2, d / 2 - wall / 2), Vector3.new(w, h, wall)) -- back
	wallPart(CFrame.new(-w / 2 + wall / 2, h / 2, 0), Vector3.new(wall, h, d - wall * 2))
	wallPart(CFrame.new(w / 2 - wall / 2, h / 2, 0), Vector3.new(wall, h, d - wall * 2))
	wallPart(CFrame.new(-w / 2 + side / 2, h / 2, -d / 2 + wall / 2), Vector3.new(side, h, wall))
	wallPart(CFrame.new(w / 2 - side / 2, h / 2, -d / 2 + wall / 2), Vector3.new(side, h, wall))
	wallPart(CFrame.new(0, (doorH + h) / 2, -d / 2 + wall / 2), Vector3.new(door, h - doorH, wall))
	-- Corner posts give the silhouette its chunky log-cabin corners.
	for _, x in { -1, 1 } do
		for _, z in { -1, 1 } do
			rod(
				model,
				"CornerPost",
				(at * CFrame.new(x * w / 2, 0, z * d / 2)).Position,
				(at * CFrame.new(x * w / 2, h + 0.2, z * d / 2)).Position,
				1.1,
				darker(logColor, 0.75),
				Enum.Material.Wood,
				{ collide = true }
			)
		end
	end
	-- Gables close the roof space (the old greybox left these open).
	local rise = (w / 2) * math.tan(math.rad(30))
	for _, z in { -d / 2 + wall / 2, d / 2 - wall / 2 } do
		gable(model, "Gable", at * CFrame.new(0, h, z), w, rise, wall, logColor, Enum.Material.Wood, {
			collide = true,
		})
	end
	-- Roof slabs with a snow layer, overhanging walls and gables.
	local ridgeL = Vector3.new(0, h + rise, 0)
	local over = 1.2
	for _, s in { -1, 1 } do
		local eave = Vector3.new(s * (w / 2 + over), h - over * math.tan(math.rad(30)), 0)
		local out = Vector3.new(s, 2, 0)
		slab(model, "Roof", at, ridgeL, eave, Vector3.zAxis, d + 2, 0.7, 0.35, out, Color3.fromRGB(196, 58, 46), nil, {
			collide = true,
		})
		slab(
			model,
			"RoofSnow",
			at,
			ridgeL,
			ridgeL:Lerp(eave, 0.94),
			Vector3.zAxis,
			d + 1.6,
			0.4,
			0.9,
			out,
			PALETTE.snowCap,
			nil,
			{ shadow = false }
		)
	end
	rod(
		model,
		"RidgeCap",
		(at * CFrame.new(0, h + rise + 0.75, -d / 2 - 1)).Position,
		(at * CFrame.new(0, h + rise + 0.75, d / 2 + 1)).Position,
		1,
		PALETTE.snowCap,
		nil,
		{ shadow = false }
	)
	-- Chimney through the roof.
	block(
		model,
		"Chimney",
		Vector3.new(1.8, rise + 2.5, 1.8),
		at * CFrame.new(w * 0.25, h + (rise + 2.5) / 2 + 0.6, d * 0.2),
		PALETTE.stoneDark,
		nil,
		{ shadow = true }
	)
	-- Windows on the side walls and beside the door.
	for _, s in { -1, 1 } do
		for _, z in { -d * 0.22, d * 0.22 } do
			block(
				model,
				"Window",
				Vector3.new(0.2, 2.4, 3),
				at * CFrame.new(s * (w / 2 + 0.05), h * 0.55, z),
				PALETTE.glass,
				nil,
				{ shadow = false }
			)
		end
		block(
			model,
			"Window",
			Vector3.new(2.6, 2.4, 0.2),
			at * CFrame.new(s * (door / 2 + side / 2), h * 0.55, -d / 2 - 0.05),
			PALETTE.glass,
			nil,
			{ shadow = false }
		)
	end
	local lamp = blob(
		model,
		"PorchLamp",
		Vector3.new(0.7, 0.9, 0.7),
		at * CFrame.new(door / 2 + 0.8, doorH + 0.2, -d / 2 - 0.5),
		PALETTE.warmLight,
		Enum.Material.Neon,
		{ shadow = false }
	)
	local light = Instance.new("PointLight")
	light.Range = 16
	light.Brightness = 1.4
	light.Color = PALETTE.warmLight
	light.Parent = lamp
	return model, at * CFrame.new(0, h / 2, 0), Vector3.new(w - wall * 2, h, d - wall * 2)
end

-- Wooden crate standing on `at` (bottom centre): planked core framed by darker bands, with an
-- optional diagonal brace on the front. Returns the core (collides).
local function crateBox(parent: Instance, at: CFrame, s: Vector3, name: string, brace: boolean): Part
	local core = block(
		parent,
		name,
		s,
		at * CFrame.new(0, s.Y / 2, 0),
		jitter(PALETTE.crate, 0.025),
		Enum.Material.WoodPlanks,
		{ collide = true, shadow = true }
	)
	local trim = darker(PALETTE.crate, 0.7)
	local band = math.min(0.36, s.Y * 0.12)
	for _, y in { -1, 1 } do
		block(
			parent,
			"Band",
			Vector3.new(s.X + 0.1, band, s.Z + 0.1),
			at * CFrame.new(0, s.Y / 2 + y * (s.Y / 2 - band / 2), 0),
			trim,
			Enum.Material.Wood,
			{ shadow = false }
		)
	end
	for _, x in { -1, 1 } do
		block(
			parent,
			"Band",
			Vector3.new(band, s.Y + 0.1, s.Z + 0.1),
			at * CFrame.new(x * (s.X / 2 - band / 2), s.Y / 2, 0),
			trim,
			Enum.Material.Wood,
			{ shadow = false }
		)
	end
	if brace then
		local w, h = s.X - band * 2, s.Y - band * 2
		block(
			parent,
			"Brace",
			Vector3.new(math.sqrt(w * w + h * h), band * 0.9, 0.12),
			at * CFrame.new(0, s.Y / 2, -s.Z / 2 - 0.04) * CFrame.Angles(0, 0, math.atan2(h, w)),
			trim,
			Enum.Material.Wood,
			{ shadow = false }
		)
	end
	return core
end

-- Supply crate (prompt anchor: PrimaryPart "Box"): a big framed crate with a red lid and a
-- white "SUPPLIES" plate on the front.
function AssetFactory.supplyCrate(at: CFrame): Model
	local model = newModel("SupplyCrate")
	local s = Vector3.new(4, 2.6, 2.6)
	local box = crateBox(model, at, s, "Box", false)
	model.PrimaryPart = box
	block(
		model,
		"Lid",
		Vector3.new(s.X + 0.3, 0.4, s.Z + 0.3),
		at * CFrame.new(0, s.Y + 0.2, 0),
		PALETTE.markerRed,
		nil,
		{ shadow = false }
	)
	local plate = block(
		model,
		"Plate",
		Vector3.new(2.8, 1.1, 0.12),
		at * CFrame.new(0, s.Y * 0.5, -s.Z / 2 - 0.07),
		PALETTE.white,
		nil,
		{ shadow = false }
	)
	surfaceText(plate, Enum.NormalId.Front, "SUPPLIES", PALETTE.markerRed)
	return model
end

-- Stack of `n` (1-7) crates: two-wide rows with crates bridged on top; a stuffed sack crowns
-- stacks of 3+.
local STACK_SLOTS = {
	{ -1.6, 0, -1.6 },
	{ 1.6, 0, -1.6 },
	{ 0, 1, -1.6 },
	{ -1.6, 0, 1.6 },
	{ 1.6, 0, 1.6 },
	{ 0, 1, 1.6 },
	{ 0, 2, 0 },
}
function AssetFactory.crateStack(at: CFrame, n: number): Model
	local model = newModel("CrateStack")
	local count = math.clamp(math.floor(n), 1, #STACK_SLOTS)
	local dz = if count <= 3 then 1.6 else 0
	local size = 3
	local top: CFrame? = nil
	local topLevel = -1
	for i = 1, count do
		local slot = STACK_SLOTS[i]
		local x = if count == 1 then 0 else slot[1]
		local frame = at
			* CFrame.new(x, slot[2] * size, slot[3] + dz)
			* CFrame.Angles(0, rng:NextNumber(-0.08, 0.08), 0)
		local core = crateBox(model, frame, Vector3.new(size, size, size), "Crate", i % 2 == 1)
		if i == 1 then
			model.PrimaryPart = core
		end
		if slot[2] > topLevel then
			topLevel = slot[2]
			top = frame
		end
	end
	if count >= 3 and top then
		blob(
			model,
			"Sack",
			Vector3.new(1.9, 1.1, 1.4),
			top * CFrame.new(0.2, size + 0.45, 0) * CFrame.Angles(0, 0.4, 0),
			if count % 2 == 0 then PALETTE.blue else PALETTE.orange,
			Enum.Material.Fabric,
			{ shadow = false }
		)
	end
	return model
end

-- Outfitter clothes rack: two posts, a rail, jackets on hangers (decorative).
function AssetFactory.outfitterRack(at: CFrame): Model
	local model = newModel("OutfitterRack")
	local bar = rod(
		model,
		"Bar",
		(at * CFrame.new(-4, 6, 0)).Position,
		(at * CFrame.new(4, 6, 0)).Position,
		0.25,
		PALETTE.metal,
		Enum.Material.Metal,
		{ shadow = false }
	)
	setPrimary(model, bar, at)
	for _, x in { -4, 4 } do
		rod(
			model,
			"Post",
			(at * CFrame.new(x, 0, 0)).Position,
			(at * CFrame.new(x, 6.2, 0)).Position,
			0.35,
			PALETTE.pole,
			Enum.Material.Wood,
			{ collide = true, shadow = false }
		)
		block(
			model,
			"Foot",
			Vector3.new(0.5, 0.3, 2.2),
			at * CFrame.new(x, 0.15, 0),
			PALETTE.dark,
			nil,
			{ shadow = false }
		)
	end
	local jackets = { PALETTE.red, PALETTE.yellow, PALETTE.blue, PALETTE.orange }
	for i, c in jackets do
		local x = -3 + (i - 1) * 2
		block(
			model,
			"Jacket",
			Vector3.new(1.7, 2.5, 0.7),
			at * CFrame.new(x, 4.5, 0),
			c,
			Enum.Material.Fabric,
			{ shadow = false }
		)
		block(
			model,
			"Hood",
			Vector3.new(1.2, 0.35, 0.8),
			at * CFrame.new(x, 5.85, 0),
			Color3.fromRGB(205, 175, 125),
			Enum.Material.Fabric,
			{ shadow = false }
		)
	end
	return model
end

-- Camp logbook lectern (prompt anchor: PrimaryPart "Post") with a small pennant.
function AssetFactory.logbook(at: CFrame): Model
	local model = newModel("Logbook")
	local post = block(
		model,
		"Post",
		Vector3.new(0.8, 3.4, 0.8),
		at * CFrame.new(0, 1.7, 0),
		PALETTE.pole,
		Enum.Material.Wood,
		{ collide = true, shadow = false }
	)
	model.PrimaryPart = post
	local deskFrame = at * CFrame.new(0, 3.5, 0) * CFrame.Angles(math.rad(-18), 0, 0)
	block(
		model,
		"Desk",
		Vector3.new(2.2, 0.25, 1.6),
		deskFrame,
		darker(PALETTE.crate, 0.8),
		Enum.Material.WoodPlanks,
		{ shadow = false }
	)
	block(
		model,
		"Book",
		Vector3.new(1.7, 0.2, 1.2),
		deskFrame * CFrame.new(0, 0.2, 0),
		PALETTE.markerRed,
		LEATHER,
		{ shadow = false }
	)
	block(
		model,
		"Pages",
		Vector3.new(1.5, 0.08, 1.05),
		deskFrame * CFrame.new(0, 0.33, 0),
		PALETTE.white,
		nil,
		{ shadow = false }
	)
	rod(
		model,
		"FlagPole",
		(at * CFrame.new(1.5, 0, 0)).Position,
		(at * CFrame.new(1.5, 7, 0)).Position,
		0.2,
		PALETTE.white,
		Enum.Material.Metal,
		{ shadow = false }
	)
	block(
		model,
		"Flag",
		Vector3.new(0.1, 1.2, 1.9),
		at * CFrame.new(1.5, 6.3, 0.95),
		PALETTE.markerRed,
		Enum.Material.Fabric,
		{ shadow = false }
	)
	return model
end

-- Water source: a chunky blue barrel with hoops, lid and tap ("Meltwater"), or a hand pump
-- ("Pump"). PrimaryPart "Barrel".
function AssetFactory.waterStation(at: CFrame, kind: string): Model
	local model = newModel(kind)
	local barrel = rod(
		model,
		"Barrel",
		(at * CFrame.new(0, 0, 0)).Position,
		(at * CFrame.new(0, 3.2, 0)).Position,
		2.6,
		PALETTE.blue,
		nil,
		{ collide = true, shadow = true }
	)
	setPrimary(model, barrel, at)
	for _, y in { 0.7, 2.5 } do
		rod(
			model,
			"Hoop",
			(at * CFrame.new(0, y - 0.15, 0)).Position,
			(at * CFrame.new(0, y + 0.15, 0)).Position,
			2.75,
			darker(PALETTE.blue, 0.6),
			nil,
			{ shadow = false }
		)
	end
	rod(
		model,
		"Lid",
		(at * CFrame.new(0, 3.2, 0)).Position,
		(at * CFrame.new(0, 3.45, 0)).Position,
		2.7,
		PALETTE.white,
		nil,
		{ shadow = false }
	)
	blob(
		model,
		"Snow",
		Vector3.new(2.2, 0.5, 2.2),
		at * CFrame.new(0, 3.45, 0),
		PALETTE.snowCap,
		nil,
		{ shadow = false }
	)
	rod(
		model,
		"Tap",
		(at * CFrame.new(0, 0.9, -1.2)).Position,
		(at * CFrame.new(0, 0.9, -1.75)).Position,
		0.35,
		PALETTE.metal,
		Enum.Material.Metal,
		{ shadow = false }
	)
	if kind == "Pump" then
		rod(
			model,
			"PumpBody",
			(at * CFrame.new(0, 3.4, 0)).Position,
			(at * CFrame.new(0, 5.2, 0)).Position,
			0.6,
			PALETTE.markerRed,
			Enum.Material.Metal,
			{ shadow = false }
		)
		rod(
			model,
			"Handle",
			(at * CFrame.new(0, 5, 0)).Position,
			(at * CFrame.new(1.6, 5.6, 0)).Position,
			0.22,
			PALETTE.dark,
			Enum.Material.Metal,
			{ shadow = false }
		)
	end
	return model
end

-- Dropped item / lost pack on the ground (PrimaryPart "Bundle").
function AssetFactory.groundBundle(at: CFrame, big: boolean): Model
	local model = newModel("Dropped")
	local s = if big then Vector3.new(1.7, 2.3, 1.1) else Vector3.new(1.1, 0.7, 0.8)
	local p = block(
		model,
		"Bundle",
		s,
		at * CFrame.new(0, s.Y / 2, 0),
		if big then PALETTE.red else PALETTE.orange,
		Enum.Material.Fabric,
		{ collide = true, shadow = false }
	)
	model.PrimaryPart = p
	block(
		model,
		"Strap",
		Vector3.new(s.X + 0.06, 0.18, s.Z + 0.06),
		at * CFrame.new(0, s.Y * 0.6, 0),
		PALETTE.dark,
		Enum.Material.Fabric,
		{ shadow = false }
	)
	return model
end

---------------------------------------------------------------------------------------------
-- TENTS. Each returns (model, interiorFrame, interiorSize): the box CampKit/BuildingService use
-- as a shelter volume. Size = Vector3(width X, height Y, length Z); the door is at the front
-- (local -Z). PrimaryPart is always the identity-oriented "Floor".
---------------------------------------------------------------------------------------------

-- A-frame tent (default 8 x 7 x 8): two sloped skins, closed back gable with a window, a
-- half-zipped darker door panel on the front, pole tips poking out at both ends and four guy
-- lines to stakes. Walk-in along the centre line.
function AssetFactory.aFrameTent(at: CFrame, color: Color3, size: Vector3?): (Model, CFrame, Vector3)
	local s = size or Vector3.new(8, 7, 8)
	local W, H, L = s.X, s.Y, s.Z
	local hw, hl = W / 2, L / 2
	local model = newModel("AFrameTent")
	local endColor = darker(color, 0.85)
	local doorColor = darker(color, 0.55)
	local floor = block(
		model,
		"Floor",
		Vector3.new(W - 0.8, 0.2, L - 0.3),
		at * CFrame.new(0, 0.1, 0),
		darker(color, 0.4),
		Enum.Material.Fabric,
		{ collide = true, shadow = false }
	)
	model.PrimaryPart = floor
	local thick = 0.35
	for _, side in { -1, 1 } do
		slab(
			model,
			"Skin",
			at,
			Vector3.new(0, H, 0),
			Vector3.new(side * hw, 0, 0),
			Vector3.zAxis,
			L + 0.6,
			thick,
			thick / 2,
			Vector3.new(side, 1, 0),
			color,
			Enum.Material.Fabric,
			{ collide = true, shadow = true }
		)
	end
	rod(
		model,
		"Ridge",
		(at * CFrame.new(0, H + 0.12, -hl - 0.35)).Position,
		(at * CFrame.new(0, H + 0.12, hl + 0.35)).Position,
		0.6,
		endColor,
		Enum.Material.Fabric,
		{ shadow = false }
	)
	gable(model, "EndWall", at * CFrame.new(0, 0, hl - thick / 2), W, H, thick, endColor, Enum.Material.Fabric, {
		collide = true,
	})
	-- Front: the left part is the zipped door panel, the right part is open (walk-in).
	local gap = math.min(0.8, hw * 0.3)
	local doorH = H * (1 - gap / hw)
	fin(
		model,
		"Door",
		at * CFrame.new(-gap, 0, -hl + thick / 2),
		-Vector3.xAxis,
		hw - gap,
		doorH,
		thick,
		doorColor,
		Enum.Material.Fabric,
		{ collide = true }
	)
	block(
		model,
		"Zip",
		Vector3.new(0.16, doorH * 0.92, 0.12),
		at * CFrame.new(-gap, doorH * 0.46, -hl - 0.02),
		PALETTE.dark,
		nil,
		{ shadow = false }
	)
	-- Rolled-back flap under the right skin's front edge.
	local inward = Vector3.new(-H, -hw, 0).Unit
	local p1 = Vector3.new(0, H, -hl + 0.1) + inward * 0.4
	local p2 = Vector3.new(hw, 0, -hl + 0.1) + inward * 0.4
	rod(
		model,
		"RolledFlap",
		at * p1:Lerp(p2, 0.12),
		at * p1:Lerp(p2, 0.85),
		0.55,
		doorColor,
		Enum.Material.Fabric,
		{ shadow = false }
	)
	block(
		model,
		"Window",
		Vector3.new(math.min(1.6, W * 0.2), math.min(1.2, H * 0.17), 0.12),
		at * CFrame.new(0, H * 0.42, hl + 0.05),
		PALETTE.window,
		nil,
		{ shadow = false }
	)
	for _, z in { -hl - 0.15, hl + 0.15 } do
		rod(
			model,
			"PoleTip",
			(at * CFrame.new(0, H - 0.5, z)).Position,
			(at * CFrame.new(0, H + 1.1, z)).Position,
			0.24,
			PALETTE.dark,
			nil,
			{ shadow = false }
		)
		block(
			model,
			"PoleCap",
			Vector3.new(0.5, 0.5, 0.5),
			at * CFrame.new(0, H + 1.15, z),
			PALETTE.white,
			nil,
			{ shape = Enum.PartType.Ball, shadow = false }
		)
		local zs = if z < 0 then -1 else 1
		for _, x in { -1, 1 } do
			guyLine(
				model,
				(at * CFrame.new(0, H + 0.85, z)).Position,
				(at * CFrame.new(x * W * 0.38, 0, z + zs * 3)).Position
			)
		end
	end
	return model, at * CFrame.new(0, H / 2, 0), Vector3.new(W * 0.55, H, L * 0.9)
end

-- Dome tent (default 8 x 6 x 7, the buildable 2-person tent): a smooth half-ellipsoid shell
-- (lower half buried) lined on the inside, two crossing pole arcs, a darker door panel bulging
-- from the front, side windows, a pole tip, guy lines and stakes. The shell is a mesh, so
-- invisible walls (with a gap at the door) do the colliding.
function AssetFactory.domeTent(at: CFrame, color: Color3, size: Vector3?): (Model, CFrame, Vector3)
	local s = size or Vector3.new(8, 6, 7)
	local W, H, L = s.X, s.Y, s.Z
	local a, c = W / 2, L / 2
	local model = newModel("DomeTent")
	local floor = block(
		model,
		"Floor",
		Vector3.new(W * 0.7, 0.2, L * 0.7),
		at * CFrame.new(0, 0.1, 0),
		darker(color, 0.4),
		Enum.Material.Fabric,
		{ collide = true, shadow = false }
	)
	model.PrimaryPart = floor
	blob(model, "Shell", Vector3.new(W, H * 2, L), at, color, Enum.Material.Fabric, { shadow = true })
	-- Inside-out copy (negative mesh scale flips the faces) so the walls show from inside.
	local _, liningMesh = blob(
		model,
		"Lining",
		Vector3.new(W - 0.3, H * 2 - 0.3, L - 0.3),
		at,
		darker(color, 0.8),
		Enum.Material.Fabric,
		{ shadow = false }
	)
	liningMesh.Scale = Vector3.new(-1, -1, -1)
	-- Point on the shell along the meridian through azimuth phi (0 = front), t = 0..pi running
	-- from one foot over the top to the opposite foot, pushed `lift` studs out along the normal.
	local function surf(phi: number, t: number, lift: number): (Vector3, Vector3)
		local x = a * math.cos(t) * math.sin(phi)
		local y = H * math.sin(t)
		local z = -c * math.cos(t) * math.cos(phi)
		local n = Vector3.new(x / (a * a), y / (H * H), z / (c * c)).Unit
		return Vector3.new(x, y, z) + n * lift, n
	end
	local poleColor = darker(color, 0.5)
	for _, phi in { math.rad(45), math.rad(135) } do
		local segs = 8
		for k = 0, segs - 1 do
			local p0 = surf(phi, k / segs * math.pi, 0.15)
			local p1 = surf(phi, (k + 1) / segs * math.pi, 0.15)
			rod(model, "Pole", at * p0, at * p1, 0.26, poleColor, nil, { shadow = false })
		end
	end
	-- Door: a dark ellipsoid set into the front so only an arch-shaped panel bulges out.
	blob(
		model,
		"Door",
		Vector3.new(W * 0.46, H * 1.5, 1.6),
		at * CFrame.new(0, 0, -c + 0.55) * CFrame.Angles(math.rad(6), 0, 0),
		darker(color, 0.5),
		Enum.Material.Fabric,
		{ shadow = false }
	)
	for _, phi in { math.rad(90), math.rad(270) } do
		local p, n = surf(phi, 0.8, -0.15)
		blob(
			model,
			"Window",
			Vector3.new(math.min(1.8, L * 0.26), math.min(1.3, H * 0.22), 0.6),
			at * CFrame.lookAt(p, p + n),
			PALETTE.window,
			nil,
			{ shadow = false }
		)
	end
	rod(
		model,
		"PoleTip",
		(at * CFrame.new(0, H - 0.3, 0)).Position,
		(at * CFrame.new(0, H + 0.9, 0)).Position,
		0.24,
		PALETTE.dark,
		nil,
		{ shadow = false }
	)
	block(
		model,
		"PoleCap",
		Vector3.new(0.5, 0.5, 0.5),
		at * CFrame.new(0, H + 0.95, 0),
		PALETTE.white,
		nil,
		{ shape = Enum.PartType.Ball, shadow = false }
	)
	for _, deg in { 60, 120, 240, 300 } do
		local phi = math.rad(deg)
		local anchor = surf(phi, 0.75, 0.1)
		local ground = Vector3.new(a * 1.7 * math.sin(phi), 0, -c * 1.7 * math.cos(phi))
		guyLine(model, at * anchor, at * ground)
	end
	-- Invisible collision ring (7 of 8 sides; the front one is the doorway).
	local wallH = H * 0.8
	for k = 1, 7 do
		local phi0, phi1 = (k - 0.5) / 8 * math.pi * 2, (k + 0.5) / 8 * math.pi * 2
		local p0 = Vector3.new(a * 0.88 * math.sin(phi0), 0, -c * 0.88 * math.cos(phi0))
		local p1 = Vector3.new(a * 0.88 * math.sin(phi1), 0, -c * 0.88 * math.cos(phi1))
		local along = p1 - p0
		block(
			model,
			"Wall",
			Vector3.new(along.Magnitude + 0.3, wallH, 0.4),
			at * CFrame.fromMatrix((p0 + p1) / 2 + Vector3.new(0, wallH / 2, 0), along.Unit, Vector3.yAxis),
			color,
			nil,
			{ collide = true, transparency = 1, shadow = false }
		)
	end
	-- Snow cap BuildingService may fade in (sits on the shell: rim at 55% of the radius).
	local capY = H * math.sqrt(1 - 0.55 * 0.55)
	blob(
		model,
		"RoofSnow",
		Vector3.new(W * 0.55, (H - capY + 0.15) * 2, L * 0.55),
		at * CFrame.new(0, capY, 0),
		PALETTE.snowCap,
		nil,
		{ transparency = 1, shadow = false }
	)
	return model, at * CFrame.new(0, H * 0.45, 0), Vector3.new(W * 0.7, H * 0.9, L * 0.7)
end
-- Big walk-in tent (default 40 x 14 x 28: the equipment / mess tent; smaller sizes make the
-- sleeping tent and the small camps' group tent). Carpet floor (dark blue Fabric), straight
-- side walls, a pitched roof with a ridge, closed gables, a wide doorway framed by poles with
-- the flap rolled up above it, centre poles, pennants on the pole tips, windows, white trim
-- bands and guy lines.
function AssetFactory.bigTent(at: CFrame, color: Color3, size: Vector3?): (Model, CFrame, Vector3)
	local s = size or Vector3.new(40, 14, 28)
	local W, H, L = s.X, s.Y, s.Z
	local hw, hl = W / 2, L / 2
	local wallH = math.clamp(H * 0.45, 6, math.max(6, H - 2.5))
	local rise = math.max(H - wallH, 1.5)
	H = wallH + rise
	local t = 0.5
	local model = newModel("BigTent")
	local trim = darker(color, 0.75)
	local fabric = Enum.Material.Fabric
	local wallOpts: Opts = { collide = true, shadow = true }
	local floor = block(
		model,
		"Floor",
		Vector3.new(W, 0.3, L),
		at * CFrame.new(0, 0.15, 0),
		PALETTE.navy,
		fabric,
		{ collide = true, shadow = false }
	)
	model.PrimaryPart = floor
	for _, x in { -1, 1 } do
		block(
			model,
			"Wall",
			Vector3.new(t, wallH, L),
			at * CFrame.new(x * (hw - t / 2), wallH / 2, 0),
			color,
			fabric,
			wallOpts
		)
	end
	block(model, "Wall", Vector3.new(W, wallH, t), at * CFrame.new(0, wallH / 2, hl - t / 2), color, fabric, wallOpts)
	local door = math.min(W * 0.35, 12)
	local sideW = (W - door) / 2
	for _, x in { -1, 1 } do
		block(
			model,
			"Wall",
			Vector3.new(sideW, wallH, t),
			at * CFrame.new(x * (door / 2 + sideW / 2), wallH / 2, -hl + t / 2),
			color,
			fabric,
			wallOpts
		)
		rod(
			model,
			"DoorPole",
			(at * CFrame.new(x * door / 2, 0, -hl - 0.1)).Position,
			(at * CFrame.new(x * door / 2, wallH + 0.2, -hl - 0.1)).Position,
			0.55,
			PALETTE.pole,
			Enum.Material.Wood,
			{ collide = true, shadow = false }
		)
	end
	for _, z in { -hl + t / 2, hl - t / 2 } do
		gable(model, "Gable", at * CFrame.new(0, wallH, z), W, rise, t, color, fabric, wallOpts)
	end
	rod(
		model,
		"Lintel",
		(at * CFrame.new(-door / 2 - 0.3, wallH, -hl - 0.1)).Position,
		(at * CFrame.new(door / 2 + 0.3, wallH, -hl - 0.1)).Position,
		0.55,
		PALETTE.pole,
		Enum.Material.Wood,
		{ shadow = false }
	)
	rod(
		model,
		"RolledFlap",
		(at * CFrame.new(-door / 2, wallH + 0.6, -hl - 0.4)).Position,
		(at * CFrame.new(door / 2, wallH + 0.6, -hl - 0.4)).Position,
		0.8,
		trim,
		fabric,
		{ shadow = false }
	)
	-- Roof skins overhanging the walls, ridge cap.
	local over = 0.8
	local ridgeP = Vector3.new(0, H, 0)
	for _, x in { -1, 1 } do
		local eave = Vector3.new(x * (hw + over), wallH - over * rise / hw, 0)
		slab(
			model,
			"Roof",
			at,
			ridgeP,
			eave,
			Vector3.zAxis,
			L + 1.2,
			t,
			t / 2,
			Vector3.new(x, 1, 0),
			color,
			fabric,
			wallOpts
		)
		block(
			model,
			"Trim",
			Vector3.new(0.16, 0.8, L + 0.1),
			at * CFrame.new(x * (hw + 0.05), wallH - 0.9, 0),
			PALETTE.white,
			nil,
			{ shadow = false }
		)
		block(
			model,
			"Trim",
			Vector3.new(sideW, 0.8, 0.16),
			at * CFrame.new(x * (door / 2 + sideW / 2), wallH - 0.9, -hl - 0.05),
			PALETTE.white,
			nil,
			{ shadow = false }
		)
		-- Windows along each side wall.
		local count = math.max(1, math.floor(L / 12))
		for i = 1, count do
			local z = -hl + L * i / (count + 1)
			block(
				model,
				"Window",
				Vector3.new(0.15, math.min(1.8, wallH * 0.3), math.min(2.8, L / (count + 1) * 0.6)),
				at * CFrame.new(x * (hw + 0.08), wallH * 0.5, z),
				PALETTE.window,
				nil,
				{ shadow = false }
			)
		end
		-- Guy lines from the eaves to stakes.
		for _, f in { -1 / 3, 0, 1 / 3 } do
			local z = f * L
			guyLine(
				model,
				(at * CFrame.new(x * (hw + over), wallH - over * rise / hw, z)).Position,
				(at * CFrame.new(x * (hw + over + 3.5), 0, z)).Position
			)
		end
	end
	block(
		model,
		"Trim",
		Vector3.new(W + 0.1, 0.8, 0.16),
		at * CFrame.new(0, wallH - 0.9, hl + 0.05),
		PALETTE.white,
		nil,
		{ shadow = false }
	)
	rod(
		model,
		"Ridge",
		(at * CFrame.new(0, H + 0.3, -hl - 0.7)).Position,
		(at * CFrame.new(0, H + 0.3, hl + 0.7)).Position,
		0.8,
		trim,
		fabric,
		{ shadow = false }
	)
	-- Centre poles (players bump into them) and pole tips with pennants above the ridge ends.
	for _, z in (if L >= 16 then { -L / 4, L / 4 } else { 0 }) do
		rod(
			model,
			"CentrePole",
			(at * CFrame.new(0, 0, z)).Position,
			(at * CFrame.new(0, H, z)).Position,
			0.7,
			PALETTE.pole,
			Enum.Material.Wood,
			{ collide = true, shadow = false }
		)
	end
	for _, z in { -hl - 0.4, hl + 0.4 } do
		local top = at * CFrame.new(0, H + 2.6, z)
		rod(
			model,
			"PoleTip",
			(at * CFrame.new(0, H - 0.4, z)).Position,
			top.Position,
			0.3,
			PALETTE.dark,
			nil,
			{ shadow = false }
		)
		fin(model, "Pennant", top * CFrame.new(0, -1, 0), Vector3.xAxis, 2, 1, 0.12, PALETTE.markerRed, fabric, {
			shadow = false,
		})
	end
	return model, at * CFrame.new(0, H * 0.45, 0), Vector3.new(W - 1, H * 0.9, L - 1)
end

---------------------------------------------------------------------------------------------
-- CAMP DRESSING
---------------------------------------------------------------------------------------------

-- Display mannequin on a black stand, facing at.LookVector. kind: "jacket" (jacket + pants),
-- "backpack", "helmet" (helmet + goggles + headlamp) or "boots"; `color` tints the item.
function AssetFactory.mannequin(at: CFrame, kind: string, color: Color3): Model
	local model = newModel("Mannequin")
	model:SetAttribute("Kind", kind)
	local standColor = Color3.fromRGB(28, 28, 32)
	local skin = Color3.fromRGB(70, 72, 82)
	local deco: Opts = { shadow = false }
	local function stand(poleTop: number)
		local base = rod(
			model,
			"Stand",
			at.Position,
			(at * CFrame.new(0, 0.3, 0)).Position,
			2.4,
			standColor,
			nil,
			{ collide = true, shadow = false }
		)
		setPrimary(model, base, at)
		if poleTop > 0.3 then
			rod(
				model,
				"StandPole",
				(at * CFrame.new(0, 0.3, 0)).Position,
				(at * CFrame.new(0, poleTop, 0)).Position,
				0.3,
				standColor,
				nil,
				deco
			)
		end
	end
	if kind == "boots" then
		local pedestal = block(
			model,
			"Stand",
			Vector3.new(2.8, 1.6, 2.1),
			at * CFrame.new(0, 0.8, 0),
			standColor,
			nil,
			{ collide = true, shadow = false }
		)
		model.PrimaryPart = pedestal
		local stripe = color:Lerp(PALETTE.white, 0.45)
		for _, x in { -0.65, 0.65 } do
			block(model, "Sole", Vector3.new(1.0, 0.3, 1.8), at * CFrame.new(x, 1.75, -0.1), PALETTE.dark, nil, deco)
			block(model, "Foot", Vector3.new(0.95, 0.75, 1.6), at * CFrame.new(x, 2.27, -0.12), color, nil, deco)
			block(model, "Stripe", Vector3.new(0.99, 0.22, 1.64), at * CFrame.new(x, 2.3, -0.12), stripe, nil, deco)
			block(model, "Shaft", Vector3.new(0.95, 1.4, 0.95), at * CFrame.new(x, 3.3, 0.22), color, nil, deco)
			block(
				model,
				"Cuff",
				Vector3.new(1.02, 0.32, 1.02),
				at * CFrame.new(x, 4.05, 0.22),
				darker(color, 0.7),
				nil,
				deco
			)
		end
	elseif kind == "backpack" then
		stand(3.2)
		block(
			model,
			"Pack",
			Vector3.new(2.0, 2.6, 1.25),
			at * CFrame.new(0, 4.4, 0),
			color,
			Enum.Material.Fabric,
			{ collide = true, shadow = false }
		)
		block(model, "Lid", Vector3.new(1.95, 0.55, 1.4), at * CFrame.new(0, 5.95, 0.02), darker(color, 0.8), nil, deco)
		rod(
			model,
			"TopRoll",
			(at * CFrame.new(-1.1, 6.55, 0.05)).Position,
			(at * CFrame.new(1.1, 6.55, 0.05)).Position,
			0.85,
			PALETTE.yellow,
			Enum.Material.Fabric,
			deco
		)
		block(
			model,
			"Pocket",
			Vector3.new(1.5, 1.0, 0.3),
			at * CFrame.new(0, 3.75, -0.72),
			darker(color, 0.8),
			nil,
			deco
		)
		block(model, "HipBelt", Vector3.new(2.3, 0.4, 0.9), at * CFrame.new(0, 3.3, 0.3), PALETTE.dark, nil, deco)
		for _, x in { -0.6, 0.6 } do
			block(model, "Rail", Vector3.new(0.24, 2.5, 0.12), at * CFrame.new(x, 4.4, -0.68), PALETTE.dark, nil, deco)
			block(
				model,
				"Buckle",
				Vector3.new(0.42, 0.28, 0.14),
				at * CFrame.new(x, 4.9, -0.76),
				PALETTE.metal,
				nil,
				deco
			)
		end
	elseif kind == "helmet" then
		stand(5.4)
		blob(model, "Head", Vector3.new(1.3, 1.45, 1.3), at * CFrame.new(0, 5.95, 0), skin, nil, deco)
		blob(model, "Helmet", Vector3.new(1.6, 1.25, 1.65), at * CFrame.new(0, 6.4, 0.02), color, nil, deco)
		blob(model, "GoggleStrap", Vector3.new(1.42, 0.26, 1.42), at * CFrame.new(0, 5.95, 0), PALETTE.dark, nil, deco)
		blob(model, "GoggleRim", Vector3.new(1.3, 0.55, 0.5), at * CFrame.new(0, 5.95, -0.52), PALETTE.white, nil, deco)
		blob(
			model,
			"GoggleLens",
			Vector3.new(1.05, 0.38, 0.3),
			at * CFrame.new(0, 5.95, -0.68),
			PALETTE.cyan,
			nil,
			deco
		)
		block(
			model,
			"Headlamp",
			Vector3.new(0.42, 0.3, 0.25),
			at * CFrame.new(0, 6.55, -0.8),
			Color3.fromRGB(255, 240, 190),
			Enum.Material.Neon,
			deco
		)
	else
		-- jacket + pants
		stand(0.3)
		local pants = Color3.fromRGB(40, 42, 50)
		for _, x in { -0.52, 0.52 } do
			block(
				model,
				"Leg",
				Vector3.new(0.95, 2.6, 1.0),
				at * CFrame.new(x, 1.6, 0),
				pants,
				Enum.Material.Fabric,
				deco
			)
		end
		block(
			model,
			"Hips",
			Vector3.new(2.05, 0.6, 1.05),
			at * CFrame.new(0, 3.2, 0),
			pants,
			Enum.Material.Fabric,
			deco
		)
		block(
			model,
			"Jacket",
			Vector3.new(2.2, 2.0, 1.2),
			at * CFrame.new(0, 4.4, 0),
			color,
			nil,
			{ collide = true, shadow = false }
		)
		block(model, "Hem", Vector3.new(2.26, 0.3, 1.26), at * CFrame.new(0, 3.5, 0), darker(color, 0.75), nil, deco)
		for _, x in { -1, 1 } do
			block(
				model,
				"Sleeve",
				Vector3.new(0.9, 2.0, 1.0),
				at * CFrame.new(x * 1.6, 4.35, 0) * CFrame.Angles(0, 0, x * 0.08),
				color,
				nil,
				deco
			)
			block(
				model,
				"Cuff",
				Vector3.new(0.95, 0.35, 1.05),
				at * CFrame.new(x * 1.68, 3.3, 0) * CFrame.Angles(0, 0, x * 0.08),
				darker(color, 0.7),
				nil,
				deco
			)
		end
		block(model, "Zip", Vector3.new(0.12, 1.9, 0.08), at * CFrame.new(0, 4.45, -0.63), PALETTE.dark, nil, deco)
		block(model, "Patch", Vector3.new(0.5, 0.42, 0.08), at * CFrame.new(0.55, 4.9, -0.63), PALETTE.white, nil, deco)
		blob(
			model,
			"FurHood",
			Vector3.new(2.0, 0.6, 1.5),
			at * CFrame.new(0, 5.45, 0.05),
			Color3.fromRGB(205, 175, 125),
			Enum.Material.Fabric,
			deco
		)
		blob(model, "Head", Vector3.new(1.15, 1.3, 1.15), at * CFrame.new(0, 6.25, 0), skin, nil, deco)
	end
	return model
end

-- Sleeping mat: blue mat, white pillow at the back (+Z) end, folded blanket at the foot.
-- PrimaryPart "Mat" (CampKit tags it SleepSpot).
function AssetFactory.sleepingMat(at: CFrame): Model
	local model = newModel("SleepingMat")
	local mat = block(
		model,
		"Mat",
		Vector3.new(2.8, 0.3, 6.6),
		at * CFrame.new(0, 0.15, 0),
		Color3.fromRGB(40, 110, 210),
		nil,
		{ shadow = false }
	)
	model.PrimaryPart = mat
	blob(model, "Pillow", Vector3.new(2.1, 0.7, 1.2), at * CFrame.new(0, 0.55, 2.55), PALETTE.white, nil, {
		shadow = false,
	})
	block(
		model,
		"Blanket",
		Vector3.new(2.65, 0.25, 2.1),
		at * CFrame.new(0, 0.42, -2.1),
		Color3.fromRGB(25, 70, 150),
		Enum.Material.Fabric,
		{ shadow = false }
	)
	return model
end

-- Flag pole: white pole on a stone footing, gold ball, a two-panel waving flag.
function AssetFactory.flagPole(at: CFrame, color: Color3): Model
	local model = newModel("FlagPole")
	local footing = block(
		model,
		"Footing",
		Vector3.new(1.4, 0.7, 1.4),
		at * CFrame.new(0, 0.2, 0),
		PALETTE.stone,
		nil,
		{ collide = true, shadow = false }
	)
	model.PrimaryPart = footing
	rod(
		model,
		"Pole",
		(at * CFrame.new(0, 0, 0)).Position,
		(at * CFrame.new(0, 16, 0)).Position,
		0.35,
		PALETTE.white,
		Enum.Material.Metal,
		{ collide = true, shadow = false }
	)
	block(
		model,
		"Finial",
		Vector3.new(0.75, 0.75, 0.75),
		at * CFrame.new(0, 16.25, 0),
		PALETTE.yellow,
		nil,
		{ shape = Enum.PartType.Ball, shadow = false }
	)
	local y = 14.3
	local p0, p1, p2 = Vector3.new(0.2, y, 0), Vector3.new(2.3, y - 0.1, -0.3), Vector3.new(4.3, y - 0.25, 0.1)
	for _, seg in { { p0, p1 }, { p1, p2 } } do
		slab(
			model,
			"Flag",
			at,
			seg[1],
			seg[2],
			Vector3.yAxis,
			2.6,
			0.12,
			0,
			Vector3.zAxis,
			color,
			Enum.Material.Fabric,
			{ shadow = false }
		)
	end
	return model
end

-- Lamp post with a warm bulb hanging toward its front.
function AssetFactory.lampPost(at: CFrame): Model
	local model = newModel("LampPost")
	local metal = Color3.fromRGB(52, 56, 66)
	local base = block(
		model,
		"Base",
		Vector3.new(1.3, 0.8, 1.3),
		at * CFrame.new(0, 0.2, 0),
		metal,
		Enum.Material.Metal,
		{ collide = true, shadow = false }
	)
	model.PrimaryPart = base
	rod(
		model,
		"Post",
		at.Position,
		(at * CFrame.new(0, 9, 0)).Position,
		0.4,
		metal,
		Enum.Material.Metal,
		{ collide = true, shadow = false }
	)
	rod(
		model,
		"Arm",
		(at * CFrame.new(0, 8.6, 0)).Position,
		(at * CFrame.new(0, 8.6, -1.8)).Position,
		0.25,
		metal,
		Enum.Material.Metal,
		{ shadow = false }
	)
	block(model, "Hood", Vector3.new(1.1, 0.45, 1.1), at * CFrame.new(0, 8.45, -1.8), metal, Enum.Material.Metal, {
		shadow = false,
	})
	local bulb = blob(
		model,
		"Bulb",
		Vector3.new(0.75, 0.65, 0.75),
		at * CFrame.new(0, 8.05, -1.8),
		PALETTE.warmLight,
		Enum.Material.Neon,
		{ shadow = false }
	)
	local light = Instance.new("PointLight")
	light.Range = 20
	light.Brightness = 1.6
	light.Color = PALETTE.warmLight
	light.Parent = bulb
	return model
end

-- Rescue station (where evacuated players wake up): an orange building on stilts with a white
-- "RESCUE" stripe, cyan windows, a red cross disc on the roof, stairs and railings, two cots
-- inside and a lookout tower with a little rotor and a red beacon. Front (stairs) faces -Z.
-- Returns (model, interiorFrame, interiorSize). Footprint about 26 x 30 including the stairs.
function AssetFactory.rescueStation(at: CFrame): (Model, CFrame, Vector3)
	local model = newModel("RescueStation")
	local deco: Opts = { shadow = false }
	local solid: Opts = { collide = true, shadow = true }
	local deckTop = 6
	local wood = Color3.fromRGB(176, 128, 80)
	local steel = Color3.fromRGB(92, 98, 110)
	local deck = block(
		model,
		"Deck",
		Vector3.new(26, 1, 18),
		at * CFrame.new(0, deckTop - 0.5, 0),
		wood,
		Enum.Material.WoodPlanks,
		solid
	)
	model.PrimaryPart = deck
	for _, x in { -12, 0, 12 } do
		for _, z in { -8, 8 } do
			rod(
				model,
				"Stilt",
				(at * CFrame.new(x, -3, z)).Position,
				(at * CFrame.new(x, deckTop - 1, z)).Position,
				0.9,
				steel,
				Enum.Material.Metal,
				{ collide = true, shadow = true }
			)
		end
	end
	for _, z in { -8, 8 } do
		for _, x in { -12, 0 } do
			rod(
				model,
				"Brace",
				(at * CFrame.new(x, 0.4, z)).Position,
				(at * CFrame.new(x + 12, deckTop - 1.3, z)).Position,
				0.35,
				steel,
				Enum.Material.Metal,
				deco
			)
		end
	end
	-- Building shell: 20 x 9 x 12 on the back of the deck, doorway in the front wall.
	local base = deckTop
	local wallH, z0, z1 = 9, -4.5, 7.5
	local zc = (z0 + z1) / 2
	local orange = PALETTE.rescue
	block(
		model,
		"Wall",
		Vector3.new(20, wallH, 0.6),
		at * CFrame.new(0, base + wallH / 2, z1 - 0.3),
		orange,
		nil,
		solid
	)
	for _, x in { -1, 1 } do
		block(
			model,
			"Wall",
			Vector3.new(0.6, wallH, 12),
			at * CFrame.new(x * 9.7, base + wallH / 2, zc),
			orange,
			nil,
			solid
		)
		block(
			model,
			"Wall",
			Vector3.new(8, wallH, 0.6),
			at * CFrame.new(x * 6, base + wallH / 2, z0 + 0.3),
			orange,
			nil,
			solid
		)
	end
	block(model, "Wall", Vector3.new(4, 2, 0.6), at * CFrame.new(0, base + 8, z0 + 0.3), orange, nil, solid)
	block(
		model,
		"Roof",
		Vector3.new(21.6, 0.8, 13.6),
		at * CFrame.new(0, base + wallH + 0.4, zc),
		PALETTE.white,
		nil,
		solid
	)
	-- Door frame.
	for _, x in { -2.2, 2.2 } do
		block(
			model,
			"DoorFrame",
			Vector3.new(0.4, 7, 0.3),
			at * CFrame.new(x, base + 3.5, z0 - 0.1),
			PALETTE.white,
			nil,
			deco
		)
	end
	block(
		model,
		"DoorFrame",
		Vector3.new(4.8, 0.4, 0.3),
		at * CFrame.new(0, base + 7, z0 - 0.1),
		PALETTE.white,
		nil,
		deco
	)
	-- White stripe band all round, with RESCUE lettering on the front.
	local bandY = base + 8
	local front = block(
		model,
		"Stripe",
		Vector3.new(20.2, 1.4, 0.2),
		at * CFrame.new(0, bandY, z0 - 0.1),
		PALETTE.white,
		nil,
		deco
	)
	surfaceText(front, Enum.NormalId.Front, "RESCUE", PALETTE.markerRed)
	block(model, "Stripe", Vector3.new(20.2, 1.4, 0.2), at * CFrame.new(0, bandY, z1 + 0.1), PALETTE.white, nil, deco)
	for _, x in { -1, 1 } do
		block(
			model,
			"Stripe",
			Vector3.new(0.2, 1.4, 12.2),
			at * CFrame.new(x * 10.1, bandY, zc),
			PALETTE.white,
			nil,
			deco
		)
	end
	-- Cyan windows.
	for _, x in { -6, 6 } do
		block(
			model,
			"Window",
			Vector3.new(3, 2.4, 0.15),
			at * CFrame.new(x, base + 4.8, z0 - 0.05),
			PALETTE.glass,
			nil,
			deco
		)
		block(
			model,
			"Window",
			Vector3.new(3, 2.4, 0.15),
			at * CFrame.new(x * 0.85, base + 4.8, z1 + 0.05),
			PALETTE.glass,
			nil,
			deco
		)
	end
	for _, x in { -1, 1 } do
		for _, z in { zc - 2.5, zc + 2.5 } do
			block(
				model,
				"Window",
				Vector3.new(0.15, 2.4, 3),
				at * CFrame.new(x * 10.05, base + 4.8, z),
				PALETTE.glass,
				nil,
				deco
			)
		end
	end
	-- Red cross disc standing on the roof front edge.
	local roofTop = base + wallH + 0.8
	local crossY = roofTop + 3.6
	for _, x in { -1.5, 1.5 } do
		rod(
			model,
			"SignLeg",
			(at * CFrame.new(x, roofTop, z0 + 1.1)).Position,
			(at * CFrame.new(x, crossY - 1.6, z0 + 1.1)).Position,
			0.3,
			steel,
			Enum.Material.Metal,
			deco
		)
	end
	rod(
		model,
		"CrossDisc",
		(at * CFrame.new(0, crossY, z0 + 1.3)).Position,
		(at * CFrame.new(0, crossY, z0 + 0.9)).Position,
		5,
		PALETTE.white,
		nil,
		{ shadow = true }
	)
	block(model, "Cross", Vector3.new(3.2, 1, 0.2), at * CFrame.new(0, crossY, z0 + 0.8), PALETTE.markerRed, nil, deco)
	block(model, "Cross", Vector3.new(1, 3.2, 0.2), at * CFrame.new(0, crossY, z0 + 0.8), PALETTE.markerRed, nil, deco)
	-- Porch light beside the door.
	local lamp = blob(
		model,
		"DoorLamp",
		Vector3.new(0.6, 0.8, 0.6),
		at * CFrame.new(3.2, base + 6.4, z0 - 0.4),
		PALETTE.warmLight,
		Enum.Material.Neon,
		deco
	)
	local lampLight = Instance.new("PointLight")
	lampLight.Range = 18
	lampLight.Brightness = 1.5
	lampLight.Color = PALETTE.warmLight
	lampLight.Parent = lamp
	-- Two cots inside.
	for _, x in { -6, 6 } do
		block(model, "Cot", Vector3.new(3, 0.9, 6.4), at * CFrame.new(x, base + 0.45, 3.6), PALETTE.metal, nil, deco)
		block(
			model,
			"Mattress",
			Vector3.new(2.8, 0.4, 6.2),
			at * CFrame.new(x, base + 1.1, 3.6),
			PALETTE.blue,
			nil,
			deco
		)
		blob(model, "Pillow", Vector3.new(2, 0.6, 1), at * CFrame.new(x, base + 1.5, 6.1), PALETTE.white, nil, deco)
	end
	-- Deck railings (gap at the top of the stairs).
	local railTop = deckTop + 3
	local posts = {
		{ -13, -9 },
		{ -7.75, -9 },
		{ -2.5, -9 },
		{ 2.5, -9 },
		{ 7.75, -9 },
		{ 13, -9 },
		{ -13, 0 },
		{ 13, 0 },
		{ -13, 9 },
		{ 0, 9 },
		{ 13, 9 },
	}
	for _, p in posts do
		rod(
			model,
			"RailPost",
			(at * CFrame.new(p[1], deckTop, p[2])).Position,
			(at * CFrame.new(p[1], railTop + 0.2, p[2])).Position,
			0.35,
			PALETTE.white,
			Enum.Material.Metal,
			{ collide = true, shadow = false }
		)
	end
	local rails = {
		{ -13, -9, -2.5, -9 },
		{ 2.5, -9, 13, -9 },
		{ -13, -9, -13, 9 },
		{ 13, -9, 13, 9 },
		{ -13, 9, 13, 9 },
	}
	for _, r in rails do
		for _, y in { railTop, deckTop + 1.5 } do
			rod(
				model,
				"Rail",
				(at * CFrame.new(r[1], y, r[2])).Position,
				(at * CFrame.new(r[3], y, r[4])).Position,
				0.3,
				PALETTE.white,
				Enum.Material.Metal,
				{ collide = y == railTop, shadow = false }
			)
		end
	end
	-- Stairs: 9 solid steps (sunk 2 studs so they never float) up to the deck front edge.
	local steps, run = 9, 1.2
	for i = 1, steps do
		local top = i * deckTop / steps
		block(
			model,
			"Step",
			Vector3.new(4.6, top + 2, run),
			at * CFrame.new(0, (top - 2) / 2, -9 - (steps - i + 0.5) * run),
			if i % 2 == 0 then wood else darker(wood, 0.9),
			Enum.Material.WoodPlanks,
			{ collide = true, shadow = false }
		)
	end
	local stairFoot = -9 - (steps - 0.5) * run
	for _, x in { -2.45, 2.45 } do
		rod(
			model,
			"RailPost",
			(at * CFrame.new(x, -0.5, stairFoot)).Position,
			(at * CFrame.new(x, deckTop / steps + 3.2, stairFoot)).Position,
			0.35,
			PALETTE.white,
			Enum.Material.Metal,
			{ collide = true, shadow = false }
		)
		rod(
			model,
			"Rail",
			(at * CFrame.new(x, deckTop / steps + 3, stairFoot)).Position,
			(at * CFrame.new(x, railTop, -9)).Position,
			0.3,
			PALETTE.white,
			Enum.Material.Metal,
			{ collide = true, shadow = false }
		)
	end
	-- Lookout tower on the roof: steel legs, a glazed orange cabin, a rotor and a beacon.
	local tx, tz = 6, 3
	local cabinY = roofTop + 6.2
	for _, dx in { -2, 2 } do
		for _, dz in { -2, 2 } do
			rod(
				model,
				"TowerLeg",
				(at * CFrame.new(tx + dx, roofTop - 0.2, tz + dz)).Position,
				(at * CFrame.new(tx + dx, cabinY, tz + dz)).Position,
				0.5,
				steel,
				Enum.Material.Metal,
				{ shadow = true }
			)
		end
	end
	for _, dx in { -2, 2 } do
		rod(
			model,
			"TowerBrace",
			(at * CFrame.new(tx + dx, roofTop + 0.4, tz - 2)).Position,
			(at * CFrame.new(tx - dx, cabinY - 0.6, tz - 2)).Position,
			0.3,
			steel,
			Enum.Material.Metal,
			deco
		)
	end
	block(model, "TowerFloor", Vector3.new(5.6, 0.5, 5.6), at * CFrame.new(tx, cabinY + 0.25, tz), orange, nil, solid)
	local panelY, glassY = cabinY + 0.5 + 0.8, cabinY + 0.5 + 1.6 + 0.7
	for _, side in { -1, 1 } do
		block(
			model,
			"TowerPanel",
			Vector3.new(5.6, 1.6, 0.3),
			at * CFrame.new(tx, panelY, tz + side * 2.65),
			orange,
			nil,
			deco
		)
		block(
			model,
			"TowerPanel",
			Vector3.new(0.3, 1.6, 5.6),
			at * CFrame.new(tx + side * 2.65, panelY, tz),
			orange,
			nil,
			deco
		)
		block(
			model,
			"TowerGlass",
			Vector3.new(5.6, 1.4, 0.3),
			at * CFrame.new(tx, glassY, tz + side * 2.65),
			PALETTE.glass,
			nil,
			deco
		)
		block(
			model,
			"TowerGlass",
			Vector3.new(0.3, 1.4, 5.6),
			at * CFrame.new(tx + side * 2.65, glassY, tz),
			PALETTE.glass,
			nil,
			deco
		)
	end
	local towerRoof = glassY + 0.7 + 0.25
	block(model, "TowerRoof", Vector3.new(6.4, 0.5, 6.4), at * CFrame.new(tx, towerRoof, tz), PALETTE.white, nil, {
		shadow = true,
	})
	rod(
		model,
		"RotorMast",
		(at * CFrame.new(tx, towerRoof + 0.25, tz)).Position,
		(at * CFrame.new(tx, towerRoof + 1.8, tz)).Position,
		0.25,
		PALETTE.dark,
		nil,
		deco
	)
	blob(
		model,
		"RotorHub",
		Vector3.new(0.6, 0.4, 0.6),
		at * CFrame.new(tx, towerRoof + 1.85, tz),
		PALETTE.dark,
		nil,
		deco
	)
	for _, yaw in { 0.3, 0.3 + math.pi / 2 } do
		block(
			model,
			"RotorBlade",
			Vector3.new(4, 0.12, 0.4),
			at * CFrame.new(tx, towerRoof + 1.95, tz) * CFrame.Angles(0, yaw, 0),
			PALETTE.dark,
			nil,
			deco
		)
	end
	local beacon = blob(
		model,
		"Beacon",
		Vector3.new(0.6, 0.6, 0.6),
		at * CFrame.new(tx + 2.6, towerRoof + 0.55, tz + 2.6),
		PALETTE.markerRed,
		Enum.Material.Neon,
		deco
	)
	local beaconLight = Instance.new("PointLight")
	beaconLight.Range = 12
	beaconLight.Brightness = 2
	beaconLight.Color = Color3.fromRGB(255, 60, 50)
	beaconLight.Parent = beacon
	return model, at * CFrame.new(0, base + wallH / 2, zc), Vector3.new(18.8, wallH, 10.8)
end

-- Checkpoint ring: a flat bright-green ring (about 10 studs across) of 16 segments lying on
-- the snow, with a floating green "Checkpoint" label. The invisible PrimaryPart "Centre" carries
-- the label and a Radius attribute. Named CheckpointRingVisual so it never shadows the camp's
-- "CheckpointRing" trigger part in a recursive FindFirstChild.
function AssetFactory.checkpointRing(at: CFrame, radius: number?): Model
	local R = radius or 5
	local model = newModel("CheckpointRingVisual")
	local centre = block(model, "Centre", Vector3.new(1, 0.2, 1), at * CFrame.new(0, 0.1, 0), PALETTE.green, nil, {
		transparency = 1,
		shadow = false,
	})
	centre:SetAttribute("Radius", R + 0.5)
	model.PrimaryPart = centre
	local n = 16
	local chord = 2 * R * math.sin(math.pi / n)
	for i = 0, n - 1 do
		local a = (i + 0.5) / n * math.pi * 2
		block(
			model,
			"Segment",
			Vector3.new(chord + 0.35, 0.5, 1.0),
			at * CFrame.new(math.cos(a) * R, 0.1, math.sin(a) * R) * CFrame.Angles(0, math.pi / 2 - a, 0),
			PALETTE.green,
			nil,
			{ shadow = false }
		)
	end
	AssetFactory.billboard(
		centre,
		"Checkpoint",
		PALETTE.green,
		Color3.fromRGB(10, 70, 25),
		Vector2.new(9, 2.2),
		4.5,
		250
	)
	return model
end

-- Banner: dark navy bar with white trim and bold white text (SurfaceGui) on its front face.
-- `at` is the centre of the board; the text faces at.LookVector.
function AssetFactory.banner(at: CFrame, text: string, width: number?): Model
	local w = width or 16
	local model = newModel("Banner")
	local board = block(model, "Board", Vector3.new(w, 2.8, 0.35), at, Color3.fromRGB(16, 30, 70), nil, {
		shadow = false,
	})
	model.PrimaryPart = board
	for _, y in { -1.55, 1.55 } do
		block(model, "Trim", Vector3.new(w + 0.3, 0.3, 0.45), at * CFrame.new(0, y, 0), PALETTE.white, nil, {
			shadow = false,
		})
	end
	surfaceText(board, Enum.NormalId.Front, text, PALETTE.white)
	return model
end

-- Wooden sign on two posts with `text` on both faces (camp names, directions).
function AssetFactory.signPost(at: CFrame, text: string): Model
	local model = newModel("Sign")
	local board = block(
		model,
		"Board",
		Vector3.new(5, 1.7, 0.3),
		at * CFrame.new(0, 4, 0),
		PALETTE.crate,
		Enum.Material.WoodPlanks,
		{ collide = true, shadow = false }
	)
	model.PrimaryPart = board
	for _, x in { -2, 2 } do
		rod(
			model,
			"Post",
			(at * CFrame.new(x, -0.5, 0)).Position,
			(at * CFrame.new(x, 5.1, 0)).Position,
			0.35,
			PALETTE.pole,
			Enum.Material.Wood,
			{ collide = true, shadow = false }
		)
	end
	block(model, "Snow", Vector3.new(5, 0.25, 0.4), at * CFrame.new(0, 4.95, 0), PALETTE.snowCap, nil, {
		shadow = false,
	})
	local textColor = Color3.fromRGB(70, 42, 22)
	surfaceText(board, Enum.NormalId.Front, text, textColor)
	surfaceText(board, Enum.NormalId.Back, text, textColor)
	return model
end

return AssetFactory
