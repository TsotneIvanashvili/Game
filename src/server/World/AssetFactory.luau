--!strict
-- Greybox asset construction from primitive parts.
--
-- These are NOT final art. They exist so every gameplay system has a physically sensible
-- stand-in at the right proportions, with real attachment points, until an artist delivers
-- meshes built to docs/ASSET_SPECS.md. Even in greybox we follow the realism rules:
--   * proportions are character-relative (R15 torso ~2 x 1.6 x 1 studs, 1 stud ~ 0.28 m),
--   * every component touches what it is attached to (straps reach the pack, the pick
--     meets the shaft, tarp edges meet stakes),
--   * no perfectly uniform colours: each part gets slight colour jitter, bottoms are dirtier.
--
-- Swapping in real meshes: replace a builder's body with a clone of the artist's model, but
-- keep the same returned attachment names so EquipmentService/BuildingService keep working.

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
-- WORLD PROPS (anchored, built at a CFrame on the ground)
---------------------------------------------------------------------------------------------

local function newModel(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

-- Campfire: stone ring, teepee of three barked logs with charred tips, ember bed, flame.
function AssetFactory.campfire(at: CFrame): Model
	local model = newModel("Campfire")
	local base = part(model, {
		name = "Base",
		size = Vector3.new(3.6, 0.2, 3.6),
		cframe = at * CFrame.new(0, 0.1, 0),
		color = Color3.fromRGB(40, 36, 34),
		material = Enum.Material.Ground,
	})
	model.PrimaryPart = base
	for i = 0, 8 do
		local a = i / 9 * math.pi * 2
		part(model, {
			name = "RingStone",
			size = Vector3.new(0.7 + rng:NextNumber(0, 0.3), 0.45 + rng:NextNumber(0, 0.2), 0.55),
			cframe = at
				* CFrame.new(math.cos(a) * 1.75, 0.3, math.sin(a) * 1.75)
				* CFrame.Angles(rng:NextNumber(-0.2, 0.2), -a, rng:NextNumber(-0.2, 0.2)),
			color = jitter(Color3.fromRGB(105, 102, 98), 0.08),
			material = Enum.Material.Slate,
		})
	end
	local apex = (at * CFrame.new(0, 2.1, 0)).Position
	for i = 0, 2 do
		local a = i / 3 * math.pi * 2 + 0.3
		local foot = (at * CFrame.new(math.cos(a) * 1.15, 0.25, math.sin(a) * 1.15)).Position
		local log = cylinderBetween(model, foot, apex:Lerp(foot, 0.15), 0.32, {
			name = "Log",
			color = jitter(Color3.fromRGB(95, 68, 45), 0.05),
			material = Enum.Material.Wood,
		})
		log.Anchored = true
		-- Charred upper end where the flame licks the wood.
		cylinderBetween(model, apex:Lerp(foot, 0.15), apex:Lerp(foot, 0.4), 0.33, {
			name = "Char",
			color = Color3.fromRGB(28, 24, 22),
			material = Enum.Material.Wood,
		})
	end
	local embers = part(model, {
		name = "Embers",
		size = Vector3.new(1.6, 0.12, 1.6),
		cframe = at * CFrame.new(0, 0.26, 0),
		color = Color3.fromRGB(255, 120, 40),
		material = Enum.Material.Neon,
		transparency = 0.25,
	})
	local flame = Instance.new("Fire")
	flame.Size = 6
	flame.Heat = 9
	flame.Color = Color3.fromRGB(255, 140, 50)
	flame.SecondaryColor = Color3.fromRGB(255, 60, 20)
	flame.Parent = embers
	local smoke = Instance.new("Smoke")
	smoke.Opacity = 0.08
	smoke.RiseVelocity = 4
	smoke.Size = 3
	smoke.Color = Color3.fromRGB(90, 90, 90)
	smoke.Parent = embers
	local light = Instance.new("PointLight")
	light.Brightness = 2.5
	light.Range = 22
	light.Color = Color3.fromRGB(255, 160, 80)
	light.Shadows = true
	light.Parent = embers
	return model
end

-- A-frame tarp shelter: two forked poles, a ridge line, a tarp pitched as two pairs of
-- panels (each pair dips slightly toward the middle: the fabric sags between supports),
-- staked corners and guy lines running from the pole tops to stakes beyond each end.
function AssetFactory.tarpShelter(at: CFrame): Model
	local model = newModel("TarpShelter")
	local length, halfWidth, ridge = 9, 3.6, 5.2
	local floor = part(model, {
		name = "Floor",
		size = Vector3.new(halfWidth * 2, 0.15, length),
		cframe = at * CFrame.new(0, 0.08, 0),
		color = Color3.fromRGB(70, 60, 50),
		material = Enum.Material.Ground,
	})
	model.PrimaryPart = floor
	local tarpColor = Color3.fromRGB(60, 110, 70)
	local poleTops = {}
	for _, z in { -length / 2, length / 2 } do
		local bottom = (at * CFrame.new(0, 0, z)).Position
		local topPos = (at * CFrame.new(0, ridge + 0.3, z)).Position
		cylinderBetween(
			model,
			bottom,
			topPos,
			0.22,
			{ name = "Pole", color = jitter(Color3.fromRGB(110, 80, 55)), material = Enum.Material.Wood }
		)
		table.insert(poleTops, topPos)
	end
	-- Ridge line (rope) between the pole tops.
	cylinderBetween(
		model,
		poleTops[1],
		poleTops[2],
		0.07,
		{ name = "RidgeLine", color = Color3.fromRGB(220, 110, 40), material = Enum.Material.Fabric }
	)
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
			local cf = CFrame.fromMatrix(centre, along, normal)
			part(model, {
				name = "TarpPanel",
				size = Vector3.new(length / 2, 0.06, slopeLength + 0.05),
				cframe = cf,
				color = jitter(tarpColor, 0.03),
				material = Enum.Material.Fabric,
				collide = true,
			})
		end
		-- Corner stakes and a reinforced grommet at each ground corner.
		for _, z in { -length / 2, 0, length / 2 } do
			local stakePos = (at * CFrame.new(side * (halfWidth + 0.1), 0.2, z)).Position
			part(model, {
				name = "Stake",
				size = Vector3.new(0.08, 0.6, 0.08),
				cframe = CFrame.new(stakePos) * CFrame.Angles(0, 0, math.rad(side * 15)),
				color = Color3.fromRGB(170, 170, 175),
				material = Enum.Material.Metal,
			})
		end
	end
	-- Guy lines from pole tops to stakes 2.5 studs beyond each end.
	for i, z in { -length / 2 - 2.5, length / 2 + 2.5 } do
		local stake = (at * CFrame.new(0, 0.2, z)).Position
		part(model, {
			name = "GuyStake",
			size = Vector3.new(0.08, 0.6, 0.08),
			cframe = CFrame.new(stake),
			color = Color3.fromRGB(170, 170, 175),
			material = Enum.Material.Metal,
		})
		cylinderBetween(
			model,
			poleTops[i],
			stake,
			0.05,
			{ name = "GuyLine", color = Color3.fromRGB(220, 110, 40), material = Enum.Material.Fabric }
		)
	end
	-- Snow that accumulates on the roof during snowfall (faded in by BuildingService).
	for _, side in { -1, 1 } do
		local cf = at * CFrame.new(side * halfWidth * 0.5, ridge * 0.55, 0) * CFrame.Angles(0, 0, math.rad(side * -55))
		part(model, {
			name = "RoofSnow",
			size = Vector3.new(halfWidth * 1.15, 0.08, length * 0.95),
			cframe = cf * CFrame.new(0, 0.08, 0),
			color = Color3.fromRGB(240, 244, 250),
			material = Enum.Material.Snow,
			transparency = 1,
		})
	end
	return model
end

-- Wind wall: stacked logs between two driven posts.
function AssetFactory.windWall(at: CFrame): Model
	local model = newModel("WindWall")
	local width, height = 11, 5
	local base = part(model, {
		name = "Base",
		size = Vector3.new(width, 0.2, 1.2),
		cframe = at * CFrame.new(0, 0.1, 0),
		color = Color3.fromRGB(70, 60, 50),
		material = Enum.Material.Ground,
	})
	model.PrimaryPart = base
	for _, x in { -width / 2, width / 2 } do
		cylinderBetween(
			model,
			(at * CFrame.new(x, -0.5, 0)).Position,
			(at * CFrame.new(x, height + 0.4, 0)).Position,
			0.3,
			{
				name = "Post",
				color = jitter(Color3.fromRGB(100, 72, 48)),
				material = Enum.Material.Wood,
				collide = true,
			}
		)
	end
	local rows = 7
	for i = 0, rows - 1 do
		local y = 0.35 + i * (height / rows)
		local z = if i % 2 == 0 then -0.15 else 0.15
		cylinderBetween(
			model,
			(at * CFrame.new(-width / 2 + 0.2, y, z)).Position,
			(at * CFrame.new(width / 2 - 0.2, y, z)).Position,
			0.62,
			{
				name = "Log",
				color = jitter(Color3.fromRGB(105, 76, 50), 0.06),
				material = Enum.Material.Wood,
				collide = true,
			}
		)
	end
	return model
end

-- Trail marker: a wooden stake with a bright flag that glows enough to read in fog.
function AssetFactory.trailMarker(at: CFrame): Model
	local model = newModel("TrailMarker")
	local stake =
		cylinderBetween(model, (at * CFrame.new(0, -0.6, 0)).Position, (at * CFrame.new(0, 5.6, 0)).Position, 0.22, {
			name = "Stake",
			color = jitter(Color3.fromRGB(120, 88, 58)),
			material = Enum.Material.Wood,
			collide = true,
		})
	model.PrimaryPart = stake
	local flag = part(model, {
		name = "Flag",
		size = Vector3.new(0.04, 0.8, 1.2),
		cframe = at * CFrame.new(0, 5.0, 0.6),
		color = Color3.fromRGB(255, 120, 20),
		material = Enum.Material.Fabric, -- the PointLight and billboard make it visible in fog
	})
	local light = Instance.new("PointLight")
	light.Range = 10
	light.Brightness = 1
	light.Color = Color3.fromRGB(255, 140, 60)
	light.Parent = flag
	return model
end

-- Pine with a tapering barked trunk and stacked boughs. `snowy` adds snow on each bough.
function AssetFactory.pineTree(at: CFrame, height: number, snowy: boolean, seed: number): Model
	local r = Random.new(seed)
	local model = newModel("Pine")
	local trunkD = height * 0.05
	local trunk = cylinderBetween(
		model,
		(at * CFrame.new(0, -1, 0)).Position,
		(at * CFrame.new(0, height * 0.9, 0)).Position,
		trunkD,
		{
			name = "Trunk",
			color = jitter(Color3.fromRGB(88, 62, 44), 0.06),
			material = Enum.Material.Wood,
			collide = true,
		}
	)
	model.PrimaryPart = trunk
	-- Root flare.
	part(model, {
		name = "RootFlare",
		size = Vector3.new(trunkD * 1.8, 0.8, trunkD * 1.8),
		cframe = at * CFrame.new(0, 0.2, 0) * CFrame.Angles(0, r:NextNumber(0, math.pi), 0),
		color = jitter(Color3.fromRGB(80, 58, 42), 0.05),
		material = Enum.Material.Wood,
	})
	local layers = 5
	local needle = jitter(Color3.fromRGB(46, 76, 52), 0.05)
	for i = 0, layers - 1 do
		local t = i / layers
		local y = height * (0.28 + t * 0.62)
		local w = height * (0.42 - t * 0.33)
		local th = height * 0.11
		local yaw = r:NextNumber(0, math.pi / 2)
		part(model, {
			name = "Bough",
			size = Vector3.new(w, th, w),
			cframe = at * CFrame.new(0, y, 0) * CFrame.Angles(0, yaw, 0),
			color = jitter(needle, 0.04),
			material = Enum.Material.Grass,
		})
		if snowy then
			part(model, {
				name = "BoughSnow",
				size = Vector3.new(w * 0.8, th * 0.25, w * 0.8),
				cframe = at * CFrame.new(0, y + th * 0.6, 0) * CFrame.Angles(0, yaw, 0),
				color = Color3.fromRGB(238, 242, 248),
				material = Enum.Material.Snow,
			})
		end
	end
	-- One dead broken branch stub low on the trunk.
	local a = r:NextNumber(0, math.pi * 2)
	cylinderBetween(
		model,
		(at * CFrame.new(0, height * 0.18, 0)).Position,
		(at * CFrame.new(math.cos(a) * height * 0.08, height * 0.2, math.sin(a) * height * 0.08)).Position,
		trunkD * 0.25,
		{
			name = "DeadBranch",
			color = Color3.fromRGB(70, 58, 48),
			material = Enum.Material.Wood,
		}
	)
	return model
end

-- Rock cluster from 2-4 fractured blocks, rotated and scaled so no two are identical.
function AssetFactory.rock(at: CFrame, size: number, snowy: boolean, seed: number): Model
	local r = Random.new(seed)
	local model = newModel("Rock")
	local base = Color3.fromRGB(110, 108, 104)
	local mats = { Enum.Material.Rock, Enum.Material.Slate, Enum.Material.Rock }
	local first: Part? = nil
	for i = 1, r:NextInteger(2, 4) do
		local s = size * r:NextNumber(0.45, 1)
		local p = part(model, {
			name = "Fragment",
			size = Vector3.new(s * r:NextNumber(0.8, 1.4), s * r:NextNumber(0.5, 0.9), s * r:NextNumber(0.8, 1.3)),
			cframe = at
				* CFrame.new(r:NextNumber(-size, size) * 0.4, s * 0.25, r:NextNumber(-size, size) * 0.4)
				* CFrame.Angles(r:NextNumber(-0.4, 0.4), r:NextNumber(0, math.pi), r:NextNumber(-0.4, 0.4)),
			color = jitter(base, 0.08),
			material = mats[(i - 1) % #mats + 1],
			collide = true,
		})
		first = first or p
		if snowy then
			part(model, {
				name = "Snow",
				size = Vector3.new(p.Size.X * 0.85, 0.2, p.Size.Z * 0.85),
				cframe = p.CFrame * CFrame.new(0, p.Size.Y / 2 + 0.05, 0),
				color = Color3.fromRGB(238, 242, 248),
				material = Enum.Material.Snow,
			})
		end
	end
	model.PrimaryPart = first
	return model
end

-- Fallen log: bark-covered trunk with a lighter sawn end and broken branch stubs.
function AssetFactory.fallenLog(at: CFrame, seed: number): Model
	local r = Random.new(seed)
	local model = newModel("FallenLog")
	local len = r:NextNumber(7, 11)
	local d = r:NextNumber(1, 1.4)
	local a = (at * CFrame.new(-len / 2, d / 2, 0)).Position
	local b = (at * CFrame.new(len / 2, d / 2, 0)).Position
	local log = cylinderBetween(model, a, b, d, {
		name = "Trunk",
		color = jitter(Color3.fromRGB(84, 64, 46), 0.06),
		material = Enum.Material.Wood,
		collide = true,
	})
	model.PrimaryPart = log
	cylinderBetween(
		model,
		b,
		b + (b - a).Unit * 0.05,
		d * 0.94,
		{ name = "SawnEnd", color = Color3.fromRGB(176, 140, 96), material = Enum.Material.Wood }
	)
	for _ = 1, 3 do
		local t = r:NextNumber(0.2, 0.8)
		local p = a:Lerp(b, t) + Vector3.new(0, d * 0.4, 0)
		cylinderBetween(
			model,
			p,
			p + Vector3.new(r:NextNumber(-0.6, 0.6), r:NextNumber(0.4, 0.9), r:NextNumber(-0.6, 0.6)),
			d * 0.18,
			{
				name = "BranchStub",
				color = Color3.fromRGB(72, 58, 44),
				material = Enum.Material.Wood,
			}
		)
	end
	return model
end

-- Simple log cabin with a doorway and pitched roof. Returns the model and interior box.
function AssetFactory.cabin(at: CFrame, size: Vector3): (Model, CFrame, Vector3)
	local model = newModel("Cabin")
	local w, h, d = size.X, size.Y, size.Z
	local wall = 0.8
	local logColor = Color3.fromRGB(110, 80, 54)
	local floor = part(model, {
		name = "Floor",
		size = Vector3.new(w, 0.6, d),
		cframe = at * CFrame.new(0, 0.3, 0),
		color = Color3.fromRGB(120, 92, 62),
		material = Enum.Material.WoodPlanks,
		collide = true,
	})
	model.PrimaryPart = floor
	local function wallPart(cf: CFrame, s: Vector3)
		part(model, {
			name = "Wall",
			size = s,
			cframe = at * cf,
			color = jitter(logColor, 0.03),
			material = Enum.Material.Wood,
			collide = true,
		})
	end
	wallPart(CFrame.new(0, h / 2, d / 2 - wall / 2), Vector3.new(w, h, wall)) -- back
	wallPart(CFrame.new(-w / 2 + wall / 2, h / 2, 0), Vector3.new(wall, h, d))
	wallPart(CFrame.new(w / 2 - wall / 2, h / 2, 0), Vector3.new(wall, h, d))
	local door = 5
	local side = (w - door) / 2
	wallPart(CFrame.new(-w / 2 + side / 2, h / 2, -d / 2 + wall / 2), Vector3.new(side, h, wall))
	wallPart(CFrame.new(w / 2 - side / 2, h / 2, -d / 2 + wall / 2), Vector3.new(side, h, wall))
	wallPart(CFrame.new(0, h - 1.5, -d / 2 + wall / 2), Vector3.new(door, 3, wall))
	-- Pitched roof: two slabs meeting at the ridge, overhanging the walls.
	local pitch = math.rad(30)
	local slab = (w / 2 + 1) / math.cos(pitch)
	for _, s in { -1, 1 } do
		part(model, {
			name = "Roof",
			size = Vector3.new(slab, 0.6, d + 2),
			cframe = at
				* CFrame.new(s * (w / 4 + 0.5), h + math.tan(pitch) * (w / 4), 0)
				* CFrame.Angles(0, 0, -s * pitch),
			color = jitter(Color3.fromRGB(70, 60, 55), 0.04),
			material = Enum.Material.WoodPlanks,
			collide = true,
		})
	end
	-- Interior volume for shelter checks.
	return model, at * CFrame.new(0, h / 2, 0), Vector3.new(w - wall * 2, h, d - wall * 2)
end

function AssetFactory.supplyCrate(at: CFrame): Model
	local model = newModel("SupplyCrate")
	local box = part(model, {
		name = "Box",
		size = Vector3.new(4, 2.6, 2.6),
		cframe = at * CFrame.new(0, 1.3, 0),
		color = Color3.fromRGB(150, 115, 70),
		material = Enum.Material.WoodPlanks,
		collide = true,
	})
	model.PrimaryPart = box
	for _, x in { -1.9, 1.9 } do
		part(model, {
			name = "Corner",
			size = Vector3.new(0.25, 2.7, 2.7),
			cframe = at * CFrame.new(x, 1.3, 0),
			color = Color3.fromRGB(70, 70, 72),
			material = Enum.Material.Metal,
		})
	end
	part(model, {
		name = "Label",
		size = Vector3.new(1.6, 0.9, 0.05),
		cframe = at * CFrame.new(0, 1.4, -1.33),
		color = Color3.fromRGB(200, 40, 40),
		material = Enum.Material.SmoothPlastic,
	})
	return model
end

function AssetFactory.outfitterRack(at: CFrame): Model
	local model = newModel("OutfitterRack")
	local bar = cylinderBetween(model, (at * CFrame.new(-4, 6, 0)).Position, (at * CFrame.new(4, 6, 0)).Position, 0.2, {
		name = "Bar",
		color = Color3.fromRGB(80, 80, 85),
		material = Enum.Material.Metal,
	})
	model.PrimaryPart = bar
	for _, x in { -4, 4 } do
		cylinderBetween(model, (at * CFrame.new(x, 0, 0)).Position, (at * CFrame.new(x, 6.1, 0)).Position, 0.25, {
			name = "Post",
			color = Color3.fromRGB(100, 75, 50),
			material = Enum.Material.Wood,
			collide = true,
		})
	end
	local jackets = {
		Color3.fromRGB(200, 70, 40),
		Color3.fromRGB(210, 170, 30),
		Color3.fromRGB(60, 120, 160),
		Color3.fromRGB(30, 40, 60),
	}
	for i, c in jackets do
		local x = -3 + (i - 1) * 2
		part(model, {
			name = "Jacket",
			size = Vector3.new(1.6, 2.4, 0.5),
			cframe = at * CFrame.new(x, 4.6, 0),
			color = jitter(c, 0.03),
			material = Enum.Material.Fabric,
		})
		part(model, {
			name = "Hanger",
			size = Vector3.new(1.2, 0.08, 0.08),
			cframe = at * CFrame.new(x, 5.85, 0),
			color = Color3.fromRGB(50, 50, 50),
			material = Enum.Material.Metal,
		})
	end
	return model
end

function AssetFactory.logbook(at: CFrame): Model
	local model = newModel("Logbook")
	local post = part(model, {
		name = "Post",
		size = Vector3.new(0.6, 3.4, 0.6),
		cframe = at * CFrame.new(0, 1.7, 0),
		color = Color3.fromRGB(100, 74, 50),
		material = Enum.Material.Wood,
		collide = true,
	})
	model.PrimaryPart = post
	part(model, {
		name = "Desk",
		size = Vector3.new(1.8, 0.15, 1.3),
		cframe = at * CFrame.new(0, 3.45, 0) * CFrame.Angles(math.rad(-15), 0, 0),
		color = Color3.fromRGB(110, 82, 56),
		material = Enum.Material.WoodPlanks,
	})
	part(model, {
		name = "Book",
		size = Vector3.new(1.3, 0.12, 0.9),
		cframe = at * CFrame.new(0, 3.58, 0) * CFrame.Angles(math.rad(-15), 0, 0),
		color = Color3.fromRGB(90, 30, 30),
		material = LEATHER,
	})
	-- Weathered expedition flag on a pole beside the book.
	cylinderBetween(model, (at * CFrame.new(1.4, 0, 0)).Position, (at * CFrame.new(1.4, 8, 0)).Position, 0.12, {
		name = "FlagPole",
		color = Color3.fromRGB(160, 160, 165),
		material = Enum.Material.Metal,
	})
	part(model, {
		name = "Flag",
		size = Vector3.new(0.04, 1.4, 2.2),
		cframe = at * CFrame.new(1.4, 7.2, 1.1),
		color = Color3.fromRGB(190, 60, 50),
		material = Enum.Material.Fabric,
	})
	return model
end

function AssetFactory.waterStation(at: CFrame, kind: string): Model
	local model = newModel(kind)
	local barrel =
		cylinderBetween(model, (at * CFrame.new(0, 0, 0)).Position, (at * CFrame.new(0, 3, 0)).Position, 2.2, {
			name = "Barrel",
			color = if kind == "Meltwater" then Color3.fromRGB(70, 80, 90) else Color3.fromRGB(60, 90, 120),
			material = Enum.Material.Metal,
			collide = true,
		})
	model.PrimaryPart = barrel
	part(model, {
		name = "Water",
		size = Vector3.new(1.9, 0.05, 1.9),
		cframe = at * CFrame.new(0, 2.95, 0),
		color = Color3.fromRGB(80, 130, 170),
		material = Enum.Material.Glass,
		transparency = 0.3,
	})
	return model
end

-- Dropped item / lost pack container on the ground.
function AssetFactory.groundBundle(at: CFrame, big: boolean): Model
	local model = newModel("Dropped")
	local s = if big then Vector3.new(1.6, 2.2, 1) else Vector3.new(0.9, 0.6, 0.7)
	local p = part(model, {
		name = "Bundle",
		size = s,
		cframe = at * CFrame.new(0, s.Y / 2, 0),
		color = if big then Color3.fromRGB(170, 60, 40) else Color3.fromRGB(120, 110, 90),
		material = Enum.Material.Fabric,
		collide = true,
	})
	model.PrimaryPart = p
	return model
end

return AssetFactory
