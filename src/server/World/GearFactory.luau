--!strict
-- Character gear builders in the stylized look (docs/ART_DIRECTION.md section 8):
-- bright SmoothPlastic, chunky parts, readable silhouettes.
--
-- Every builder returns a Model built in the LOCAL SPACE of one body part (origin at that
-- part's centre, -Z = the way the character faces, +Y up) whose first part is its
-- PrimaryPart. `GearFactory.attach` moves it onto the body part and welds it. Sizes come from
-- the body part sizes passed in, so the gear fits R15, R6, scaled and Rthro avatars.
--
-- Parts that are fabric (they darken when wet) carry the attribute "GearShell" = true;
-- EquipmentService collects them for wetness darkening.
--
-- Construction rules kept from ASSET_SPECS.md: straps reach what they hold, spikes touch
-- the sole, the fur ring rests on the collar, the headlamp sits on its strap. Nothing floats.

local AssetFactory = require(script.Parent.AssetFactory)

local GearFactory = {}

GearFactory.SHELL_ATTR = "GearShell"

local SMOOTH = Enum.Material.SmoothPlastic
local FABRIC = Enum.Material.Fabric

local C = Color3.fromRGB
local STRAP = C(28, 30, 38)
local BUCKLE = C(205, 210, 220)
local STEEL = C(185, 190, 200)
local RUBBER = C(24, 24, 28)
local WHITE = C(245, 245, 245)
local NAVY = C(25, 40, 90)
local FUR_A = C(205, 170, 115)
local FUR_B = C(180, 145, 95)
local LAMP_OFF = C(255, 240, 190)
local LAMP_ON = C(255, 250, 225)

local function shade(color: Color3, f: number): Color3
	return Color3.new(math.clamp(color.R * f, 0, 1), math.clamp(color.G * f, 0, 1), math.clamp(color.B * f, 0, 1))
end

local function tint(color: Color3, toward: Color3, t: number): Color3
	return color:Lerp(toward, t)
end

-- The first part a builder adds becomes the model's PrimaryPart (no invisible roots: every
-- part costs replication and physics-solver time on every character).
local function newModel(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	return model
end

-- One gear part. `shell` marks fabric that darkens when wet.
local function piece(
	model: Model,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	shell: boolean?,
	material: Enum.Material?
): Part
	local p = AssetFactory.part(model, {
		name = name,
		size = size,
		cframe = cframe,
		color = color,
		material = material or SMOOTH,
	})
	p.Massless = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	if math.max(size.X, size.Y, size.Z) < 0.6 then
		p.CastShadow = false
	end
	if shell then
		p:SetAttribute(GearFactory.SHELL_ATTR, true)
	end
	if not model.PrimaryPart then
		model.PrimaryPart = p
	end
	return p
end

-- Upright cylinder (Roblox cylinders run along local X, so rotate X onto Y).
local function ring(
	model: Model,
	name: string,
	center: Vector3,
	diameter: number,
	height: number,
	color: Color3,
	shell: boolean?
): Part
	local p = piece(
		model,
		name,
		Vector3.new(height, diameter, diameter),
		CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2),
		color,
		shell
	)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- Non-uniform ellipsoid: a block with a Sphere SpecialMesh that fills the part's size.
local function ellipsoid(
	model: Model,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	shell: boolean?
): Part
	local p = piece(model, name, size, cframe, color, shell)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

---------------------------------------------------------------------------------------------
-- Mounting
---------------------------------------------------------------------------------------------

-- Moves a model built in local space onto `target` (optionally offset) and welds it.
-- Size and CFrame are final BEFORE any weld exists: moving a welded part afterwards would
-- drag the whole character assembly with it.
function GearFactory.attach(model: Model, target: BasePart, parent: Instance, offset: CFrame?)
	local frame = target.CFrame * (offset or CFrame.identity)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CFrame = frame * d.CFrame
		end
	end
	local primary = model.PrimaryPart :: BasePart
	AssetFactory.weldCosmetic(model, primary)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = primary
	weld.Parent = primary
	model.Parent = parent
end

-- Visual size of a head. Classic heads are a (2,1,1) Part with a "Head" SpecialMesh that
-- renders as a ~1.25 stud ball; mesh heads report their real bounds.
function GearFactory.headSize(head: BasePart): Vector3
	local size = head.Size
	local result: Vector3
	if head:IsA("MeshPart") then
		result = size
	else
		local mesh = head:FindFirstChildOfClass("SpecialMesh")
		local m = math.min(size.X, size.Y, size.Z)
		if mesh and mesh.MeshType == Enum.MeshType.Head then
			result = Vector3.new(m * mesh.Scale.X, m * mesh.Scale.Y, m * mesh.Scale.Z)
		elseif mesh then
			result = Vector3.one * m * 1.2
		else
			result = size
		end
	end
	return Vector3.new(math.clamp(result.X, 0.6, 3), math.clamp(result.Y, 0.6, 3), math.clamp(result.Z, 0.6, 3))
end

---------------------------------------------------------------------------------------------
-- HEAD (head space; hs = GearFactory.headSize(head))
---------------------------------------------------------------------------------------------

local HELMET_BAND_BOTTOM = 0.12 -- fractions of head height above the head centre
local HELMET_BAND_TOP = 0.4
local GOGGLE_Y = 0.06

-- Blue dome helmet: a band hugging the head, a dome on top of it (its lower half sits
-- inside the band and the head), a lighter ridge, a chin strap, and a headlamp on an
-- elastic strap round the band. The SpotLight child "Headlamp" is off unless `lightOn`.
function GearFactory.helmet(hs: Vector3, color: Color3, lightOn: boolean, hasLamp: boolean?): Model
	local model = newModel("Helmet")
	local d = math.max(hs.X, hs.Z) * 1.14
	local bandBottom, bandTop = hs.Y * HELMET_BAND_BOTTOM, hs.Y * HELMET_BAND_TOP
	local bandY = (bandBottom + bandTop) / 2
	ring(model, "HelmetBand", Vector3.new(0, bandY, 0), d, bandTop - bandBottom, color, true)
	ellipsoid(model, "HelmetDome", Vector3.new(d, hs.Y * 0.84, d), CFrame.new(0, bandTop, 0), color, true)
	ring(model, "HelmetRim", Vector3.new(0, bandBottom + 0.035, 0), d + 0.08, 0.07, shade(color, 0.6))
	-- Ridge along the crown: deep enough that both ends stay buried in the dome.
	piece(
		model,
		"HelmetRidge",
		Vector3.new(hs.X * 0.16, 0.14, d * 0.55),
		CFrame.new(0, bandTop + hs.Y * 0.38, 0),
		tint(color, WHITE, 0.3),
		true
	)
	-- Chin strap: down both cheeks from under the band, joined under the chin.
	local chinZ = -hs.Z * 0.12
	local strapTop = bandBottom + 0.02
	local strapBottom = -hs.Y * 0.5
	for _, side in { -1, 1 } do
		piece(
			model,
			"ChinStrap",
			Vector3.new(0.05, strapTop - strapBottom, 0.1),
			CFrame.new(side * (hs.X / 2 + 0.025), (strapTop + strapBottom) / 2, chinZ),
			STRAP,
			true
		)
	end
	piece(
		model,
		"ChinStrapUnder",
		Vector3.new(hs.X + 0.1, 0.06, 0.12),
		CFrame.new(0, strapBottom - 0.03, chinZ),
		STRAP,
		true
	)

	if hasLamp ~= false then
		ring(model, "HeadlampStrap", Vector3.new(0, bandY, 0), d + 0.05, 0.12, STRAP, true)
		-- Housing pressed onto the front of the band, tilted slightly down.
		local housingFrame = CFrame.new(0, bandY + hs.Y * 0.04, -d / 2 - 0.05) * CFrame.Angles(math.rad(-10), 0, 0)
		piece(model, "HeadlampHousing", Vector3.new(hs.X * 0.3, hs.Y * 0.2, 0.16), housingFrame, C(40, 42, 50))
		local lens = piece(
			model,
			"HeadlampLens",
			Vector3.new(hs.X * 0.2, hs.Y * 0.12, 0.06),
			housingFrame * CFrame.new(0, 0, -0.09),
			if lightOn then LAMP_ON else LAMP_OFF
		)
		lens.Material = if lightOn then Enum.Material.Neon else SMOOTH
		local light = Instance.new("SpotLight")
		light.Name = "Headlamp"
		light.Face = Enum.NormalId.Front
		light.Angle = 55
		light.Range = 45
		light.Brightness = 3
		light.Color = C(255, 244, 214)
		light.Shadows = true
		light.Enabled = lightOn
		light.Parent = lens
	end
	return model
end

-- Switches every headlamp under `container` on or off without rebuilding the gear.
function GearFactory.setHeadlamp(container: Instance, on: boolean)
	for _, d in container:GetDescendants() do
		if d:IsA("SpotLight") and d.Name == "Headlamp" then
			d.Enabled = on
		elseif d:IsA("BasePart") and d.Name == "HeadlampLens" then
			d.Material = if on then Enum.Material.Neon else SMOOTH
			d.Color = if on then LAMP_ON else LAMP_OFF
		end
	end
end

-- Knit beanie: folded cuff band, rounded crown, pom-pom.
function GearFactory.beanie(hs: Vector3, color: Color3): Model
	local model = newModel("Beanie")
	local d = math.max(hs.X, hs.Z) * 1.08
	ring(model, "BeanieCuff", Vector3.new(0, hs.Y * 0.22, 0), d, hs.Y * 0.2, shade(color, 0.85), true)
	ellipsoid(
		model,
		"BeanieCrown",
		Vector3.new(d * 0.98, hs.Y * 0.7, d * 0.98),
		CFrame.new(0, hs.Y * 0.3, 0),
		color,
		true
	)
	local pom = piece(
		model,
		"PomPom",
		Vector3.one * hs.X * 0.3,
		CFrame.new(0, hs.Y * 0.65 + 0.06, 0),
		tint(color, WHITE, 0.6),
		true
	)
	pom.Shape = Enum.PartType.Ball
	return model
end

-- Goggles: white rim, cyan lens band, hinges joining the rim to a strap round the head.
-- `storm` = bigger sealed frame.
function GearFactory.goggles(hs: Vector3, rimColor: Color3, lensColor: Color3, storm: boolean?): Model
	local model = newModel("Goggles")
	local gy = hs.Y * GOGGLE_Y
	local fz = -hs.Z / 2
	local w = if storm then 0.96 else 0.88
	local h = if storm then 0.34 else 0.28
	-- Frame back face sits 0.03 inside the face so it never floats off a rounded head.
	piece(model, "GoggleFrame", Vector3.new(hs.X * w, hs.Y * h, 0.14), CFrame.new(0, gy, fz - 0.04), rimColor)
	local lens = piece(
		model,
		"GoggleLens",
		Vector3.new(hs.X * (w - 0.1), hs.Y * (h - 0.09), 0.06),
		CFrame.new(0, gy, fz - 0.12),
		lensColor
	)
	lens.Reflectance = 0.25
	-- Small dark nose notch under the lens centre.
	piece(
		model,
		"GoggleNotch",
		Vector3.new(hs.X * 0.14, hs.Y * 0.07, 0.05),
		CFrame.new(0, gy - hs.Y * (h / 2 - 0.035), fz - 0.12),
		C(30, 32, 40)
	)
	local strapH = hs.Y * (if storm then 0.16 else 0.13)
	for _, side in { -1, 1 } do
		piece(
			model,
			"GoggleHinge",
			Vector3.new(hs.X * 0.12, hs.Y * 0.15, 0.1),
			CFrame.new(side * hs.X * 0.47, gy, fz),
			rimColor
		)
		piece(
			model,
			"GoggleStrapSide",
			Vector3.new(0.06, strapH, hs.Z),
			CFrame.new(side * (hs.X / 2 + 0.03), gy, 0),
			STRAP,
			true
		)
	end
	piece(
		model,
		"GoggleStrapBack",
		Vector3.new(hs.X + 0.12, strapH, 0.06),
		CFrame.new(0, gy, hs.Z / 2 + 0.03),
		STRAP,
		true
	)
	return model
end

-- Dark knit mask over nose, mouth and neck, with knit ribs and a breathing vent.
function GearFactory.mask(hs: Vector3, color: Color3): Model
	local model = newModel("Mask")
	local front = -hs.Z * 0.54
	piece(
		model,
		"MaskFace",
		Vector3.new(hs.X * 1.08, hs.Y * 0.5, hs.Z * 1.08),
		CFrame.new(0, -hs.Y * 0.27, 0),
		color,
		true,
		FABRIC
	)
	piece(
		model,
		"MaskNose",
		Vector3.new(hs.X * 0.22, hs.Y * 0.14, 0.08),
		CFrame.new(0, -hs.Y * 0.1, front - 0.02),
		color,
		true,
		FABRIC
	)
	for _, y in { -0.2, -0.4 } do
		piece(
			model,
			"MaskRib",
			Vector3.new(hs.X * 1.1, 0.04, hs.Z * 1.1),
			CFrame.new(0, hs.Y * y, 0),
			shade(color, 0.7),
			true
		)
	end
	piece(
		model,
		"MaskVent",
		Vector3.new(hs.X * 0.3, hs.Y * 0.1, 0.04),
		CFrame.new(0, -hs.Y * 0.3, front - 0.01),
		shade(color, 0.55)
	)
	piece(
		model,
		"MaskNeck",
		Vector3.new(hs.X * 0.82, 0.4, hs.Z * 0.82),
		CFrame.new(0, -hs.Y / 2 - 0.15, 0),
		color,
		true,
		FABRIC
	)
	return model
end

---------------------------------------------------------------------------------------------
-- BODY CLOTHING
---------------------------------------------------------------------------------------------

export type ShellOpts = {
	scale: number,
	hem: boolean?, -- darker band at the bottom (jacket hem)
	baffles: boolean?, -- puffy down-suit ridges
}

-- Torso shell (UpperTorso, LowerTorso or R6 Torso).
function GearFactory.torsoShell(size: Vector3, color: Color3, opts: ShellOpts): Model
	local model = newModel("TorsoShell")
	local s = size * opts.scale
	piece(model, "Shell", s, CFrame.identity, color, true)
	if opts.hem then
		piece(
			model,
			"Hem",
			Vector3.new(s.X + 0.04, math.min(0.16, s.Y * 0.4), s.Z + 0.04),
			CFrame.new(0, -s.Y / 2 + math.min(0.08, s.Y * 0.2), 0),
			shade(color, 0.75),
			true
		)
	end
	if opts.baffles and s.Y > 0.8 then
		for _, f in { -0.2, 0.15 } do
			piece(
				model,
				"Baffle",
				Vector3.new(s.X + 0.06, 0.07, s.Z + 0.06),
				CFrame.new(0, s.Y * f, 0),
				shade(color, 0.86),
				true
			)
		end
	end
	return model
end

-- Front zipper, a generic mountain chest patch (never a brand), the collar, and for hooded
-- parkas the tan fur ring around the neck. Torso space of the UpperTorso / R6 Torso.
function GearFactory.jacketDetails(torsoSize: Vector3, hs: Vector3, color: Color3, scale: number, fur: boolean): Model
	local model = newModel("JacketDetails")
	local s = torsoSize * scale
	local k = torsoSize.X / 2
	local front = -s.Z / 2

	piece(model, "Zipper", Vector3.new(0.07, s.Y * 0.9, 0.04), CFrame.new(0, -s.Y * 0.03, front - 0.015), C(25, 25, 30))
	piece(model, "ZipPull", Vector3.new(0.1, 0.16, 0.05), CFrame.new(0, s.Y * 0.36, front - 0.04), BUCKLE)

	-- Chest patch on the wearer's left (-X): white badge, two navy peaks with a snow tip.
	-- Peaks are 45-degree diamonds whose lower halves hide behind a white ground strip, so
	-- the shape reads as a triangle whichever way round the engine builds wedges.
	local px, py = -s.X * 0.24, s.Y * 0.22
	local patchFrame = CFrame.new(px, py, front - 0.02)
	piece(model, "ChestPatch", Vector3.new(0.46 * k, 0.38 * k, 0.04), patchFrame, WHITE)
	local diamond = CFrame.Angles(0, 0, math.rad(45))
	piece(
		model,
		"PatchPeakSmall",
		Vector3.new(0.14 * k, 0.14 * k, 0.03),
		patchFrame * CFrame.new(0.09 * k, -0.06 * k, -0.03) * diamond,
		C(70, 110, 190)
	)
	piece(
		model,
		"PatchPeak",
		Vector3.new(0.2 * k, 0.2 * k, 0.03),
		patchFrame * CFrame.new(-0.04 * k, -0.04 * k, -0.035) * diamond,
		NAVY
	)
	local peakTip = -0.04 * k + 0.2 * k * math.sqrt(0.5)
	local capHalf = 0.07 * k * math.sqrt(0.5)
	piece(
		model,
		"PatchSnow",
		Vector3.new(0.07 * k, 0.07 * k, 0.03),
		patchFrame * CFrame.new(-0.04 * k, peakTip - capHalf, -0.045) * diamond,
		WHITE
	)
	piece(
		model,
		"PatchGround",
		Vector3.new(0.42 * k, 0.15 * k, 0.03),
		patchFrame * CFrame.new(0, -0.115 * k, -0.05),
		WHITE
	)

	-- Collar: a jacket-coloured ring the fur (or nothing) rests on.
	local rx = math.max(hs.X * 0.55, s.X * 0.26)
	local rz = math.max(hs.Z * 0.5, s.Z * 0.5) + 0.05
	local collarH = 0.2
	piece(
		model,
		"Collar",
		Vector3.new(rx * 2, collarH, rz * 2),
		CFrame.new(0, s.Y / 2 + 0.04, 0),
		if fur then color else shade(color, 0.9),
		true
	)
	if fur then
		-- Rough fur ring: overlapping tan lumps round the collar, alternating tones and
		-- tilts, rising a little at the back where the hood is.
		local kk = math.clamp(hs.X / 1.25, 0.7, 1.5)
		local n = 12
		for i = 0, n - 1 do
			local a = (i / n) * math.pi * 2
			local x, z = rx * math.cos(a), rz * math.sin(a)
			local back = (z / rz + 1) / 2 -- 0 at the front, 1 at the back
			local y = s.Y / 2 + 0.1 + 0.12 * back
			local tilt = if i % 2 == 0 then 0.25 else -0.2
			piece(
				model,
				"FurTrim",
				Vector3.new(0.36, 0.3, 0.36) * kk,
				CFrame.new(x, y, z) * CFrame.Angles(0, -a, 0) * CFrame.Angles(tilt, 0, tilt * 0.6),
				if i % 2 == 0 then FUR_A else FUR_B,
				true,
				FABRIC
			)
		end
	end
	return model
end

-- Sleeve or base-layer arm shell, with an optional ribbed cuff `cuffFromBottom` studs above
-- the bottom of the part (0 for an R15 lower arm, the hand length for an R6 arm).
function GearFactory.sleeve(
	size: Vector3,
	color: Color3,
	scale: number,
	cuffFromBottom: number?,
	baffles: boolean?
): Model
	local model = newModel("Sleeve")
	local s = size * scale
	piece(model, "Shell", s, CFrame.identity, color, true)
	if cuffFromBottom then
		local k = math.clamp(size.X, 0.5, 2)
		local cuffH = 0.24 * k
		local cy = -size.Y / 2 + cuffFromBottom + cuffH / 2
		local cuffColor = shade(color, 0.72)
		piece(model, "Cuff", Vector3.new(s.X * 1.1, cuffH, s.Z * 1.1), CFrame.new(0, cy, 0), cuffColor, true)
		for _, dy in { -0.06, 0.06 } do
			piece(
				model,
				"CuffRib",
				Vector3.new(s.X * 1.13, 0.035, s.Z * 1.13),
				CFrame.new(0, cy + dy * k, 0),
				shade(color, 0.55),
				true
			)
		end
	end
	if baffles and s.Y > 0.8 then
		piece(model, "Baffle", Vector3.new(s.X + 0.06, 0.07, s.Z + 0.06), CFrame.identity, shade(color, 0.86), true)
	end
	return model
end

-- Pant leg shell. `knee` adds a reinforced knee panel at the top front (lower legs).
function GearFactory.legShell(size: Vector3, color: Color3, scale: number, knee: boolean?): Model
	local model = newModel("PantLeg")
	local s = size * scale
	piece(model, "Shell", s, CFrame.identity, color, true)
	if knee then
		piece(
			model,
			"KneePanel",
			Vector3.new(s.X * 0.62, math.min(0.34, s.Y * 0.3), 0.06),
			CFrame.new(0, s.Y / 2 - math.min(0.2, s.Y * 0.18), -s.Z / 2 - 0.02),
			tint(color, C(90, 90, 100), 0.45),
			true
		)
	end
	return model
end

-- Chunky gauntlet glove in hand space: mitt, thumb, gauntlet sealing over the cuff, cinch
-- strap (heated gloves get an orange heating band instead).
function GearFactory.glove(handSize: Vector3, color: Color3, heated: boolean?): Model
	local model = newModel("Glove")
	local k = math.clamp(handSize.X, 0.5, 2)
	local s = Vector3.new(handSize.X * 1.18, math.max(handSize.Y * 1.3, 0.36 * k), handSize.Z * 1.18)
	piece(model, "Mitt", s, CFrame.new(0, 0, 0), color, true)
	piece(
		model,
		"Thumb",
		Vector3.new(s.X * 0.3, s.Y * 0.7, 0.16 * k),
		CFrame.new(0, -s.Y * 0.05, -s.Z / 2 - 0.05 * k),
		color,
		true
	)
	local gH = 0.34 * k
	local g = Vector3.new(s.X * 1.12, gH, s.Z * 1.12)
	local gy = s.Y / 2 + gH / 2 - 0.05
	piece(model, "Gauntlet", g, CFrame.new(0, gy, 0), tint(color, C(120, 120, 130), 0.15), true)
	piece(
		model,
		if heated then "HeatBand" else "Cinch",
		Vector3.new(g.X + 0.03, 0.07 * k, g.Z + 0.03),
		CFrame.new(0, gy, 0),
		if heated then C(235, 110, 30) else STRAP,
		not heated
	)
	return model
end

export type BootOpts = {
	stripe: Color3?,
	spikes: boolean?, -- crampons under the sole
	low: boolean?, -- trail shoe: thinner sole
}

-- Chunky boot in foot space: upper, rounded toe, lighter stripe, rubber sole and (optional)
-- a crampon frame with spikes touching the sole.
function GearFactory.boot(footSize: Vector3, color: Color3, opts: BootOpts): Model
	local model = newModel("Boot")
	local k = math.clamp(footSize.X, 0.5, 2)
	local fy = footSize.Y
	local bottom = -fy / 2
	local u = Vector3.new(footSize.X * 1.24, math.max(fy * 1.6, 0.4 * k), footSize.Z * 1.22)
	piece(model, "Upper", u, CFrame.new(0, bottom + u.Y / 2, 0), color, true)
	local toeD = 0.26 * k
	piece(
		model,
		"Toe",
		Vector3.new(u.X * 0.96, u.Y * 0.55, toeD),
		CFrame.new(0, bottom + u.Y * 0.275, -u.Z / 2 - toeD * 0.4),
		color,
		true
	)
	if opts.stripe then
		piece(
			model,
			"Stripe",
			Vector3.new(u.X + 0.04, 0.09 * k, u.Z + 0.04),
			CFrame.new(0, bottom + u.Y * 0.55, 0),
			opts.stripe,
			true
		)
	end
	local soleH = (if opts.low then 0.08 else 0.14) * k
	local soleLen = u.Z + toeD * 0.6 + 0.06
	local soleZ = -toeD * 0.3
	piece(model, "Sole", Vector3.new(u.X * 1.06, soleH, soleLen), CFrame.new(0, bottom - soleH / 2, soleZ), RUBBER)
	if opts.spikes then
		local soleBottom = bottom - soleH
		local railH = 0.05 * k
		local railY = soleBottom - railH / 2 + 0.005
		for _, side in { -1, 1 } do
			local x = side * u.X * 0.38
			local rail = piece(
				model,
				"CramponRail",
				Vector3.new(0.05 * k, railH, soleLen * 0.9),
				CFrame.new(x, railY, soleZ),
				STEEL
			)
			rail.Reflectance = 0.15
			for _, f in { -0.3, 0.3 } do
				local spikeH = 0.16 * k
				local spike = piece(
					model,
					"CramponSpike",
					Vector3.new(0.07 * k, spikeH, 0.07 * k),
					CFrame.new(x, railY - railH / 2 - spikeH / 2 + 0.02 * k, soleZ + f * soleLen),
					STEEL
				)
				spike.Reflectance = 0.15
			end
			-- Front points angle forward and down from the toe end of the rail.
			local frontZ = soleZ - soleLen * 0.45
			local point = piece(
				model,
				"CramponFrontPoint",
				Vector3.new(0.06 * k, 0.06 * k, 0.2 * k),
				CFrame.new(x, railY - 0.02 * k, frontZ - 0.06 * k) * CFrame.Angles(math.rad(-25), 0, 0),
				STEEL
			)
			point.Reflectance = 0.15
		end
		piece(
			model,
			"CramponBar",
			Vector3.new(u.X * 0.8, railH, 0.05 * k),
			CFrame.new(0, railY, soleZ + soleLen * 0.1),
			STEEL
		)
	end
	return model
end

-- Boot shaft round the bottom of the lower leg, with a padded collar and laces.
-- `height` is in studs; the cuff's bottom sits at the bottom of the part.
function GearFactory.bootCuff(legSize: Vector3, color: Color3, height: number, stripe: Color3?): Model
	local model = newModel("BootCuff")
	local k = math.clamp(legSize.X, 0.5, 2)
	local c = Vector3.new(legSize.X * 1.24, height, legSize.Z * 1.22)
	local cy = -legSize.Y / 2 + height / 2
	piece(model, "Shaft", c, CFrame.new(0, cy, 0), color, true)
	piece(
		model,
		"Collar",
		Vector3.new(c.X + 0.06, 0.12 * k, c.Z + 0.06),
		CFrame.new(0, cy + height / 2 - 0.06 * k, 0),
		stripe or shade(color, 0.7),
		true
	)
	for i = 1, 3 do
		piece(
			model,
			"Lace",
			Vector3.new(c.X * 0.4, 0.04, 0.04),
			CFrame.new(0, cy - height * 0.3 + (i - 1) * height * 0.22, -c.Z / 2 - 0.015),
			C(220, 220, 225)
		)
	end
	return model
end

---------------------------------------------------------------------------------------------
-- BACKPACK AND HARNESS
---------------------------------------------------------------------------------------------

local PACK_DIMENSIONS = {
	-- height, width, depth (studs for a 2-stud-wide torso), extra height above shoulders
	Small = { 1.45, 1.45, 0.7, 0.0 },
	Medium = { 1.85, 1.6, 0.85, 0.15 },
	Large = { 2.15, 1.72, 1.0, 0.3 },
	Expedition = { 2.45, 1.85, 1.15, 0.5 },
}

-- Navy pack in "pack space": origin at the centre of the wearer's back surface, +Z away
-- from the body, +Y up. Lighter top roll, two vertical strap rails with buckles, front
-- pocket, side pockets, axe loop. Returns the model and named CFrames for stowed equipment
-- (Axe, Rope, Tarp, Wood: same names and meaning as AssetFactory.backpack).
function GearFactory.backpack(tier: string, color: Color3, torsoSize: Vector3): (Model, { [string]: CFrame })
	local dims = PACK_DIMENSIONS[tier] or PACK_DIMENSIONS.Small
	local k = math.clamp(torsoSize.X / 2, 0.6, 1.6)
	local h, w, d, lift = dims[1] * k, dims[2] * k, dims[3] * k, dims[4] * k
	local model = Instance.new("Model")
	model.Name = "Backpack"
	local cy = lift + (torsoSize.Y / 2 - h / 2) -- top of the bag near the shoulders

	-- Body spans cy-0.45h .. cy+0.35h; lid on top of it; roll on top of the lid.
	local body = piece(model, "Body", Vector3.new(w, h * 0.8, d), CFrame.new(0, cy - h * 0.05, d / 2), color, true)
	model.PrimaryPart = body
	piece(
		model,
		"BasePanel",
		Vector3.new(w + 0.02, h * 0.1, d + 0.02),
		CFrame.new(0, cy - h * 0.4, d / 2),
		shade(color, 0.6),
		true
	)
	local lidY = cy + h * 0.39
	local lidH = h * 0.12
	piece(model, "Lid", Vector3.new(w * 0.96, lidH, d * 1.06), CFrame.new(0, lidY, d * 0.52), shade(color, 0.85), true)

	-- Lighter top roll (sleeping mat) lying across the lid, with two straps round it.
	local rollD = math.min(d * 0.75, h * 0.24)
	local rollY = lidY + lidH / 2 + rollD / 2 - 0.03
	local rollColor = tint(color, C(200, 215, 240), 0.55)
	AssetFactory.cylinderBetween(
		model,
		Vector3.new(-w * 0.5, rollY, d * 0.5),
		Vector3.new(w * 0.5, rollY, d * 0.5),
		rollD,
		{ name = "TopRoll", color = rollColor }
	):SetAttribute(GearFactory.SHELL_ATTR, true)
	for _, x in { -w * 0.3, w * 0.3 } do
		AssetFactory.cylinderBetween(
			model,
			Vector3.new(x - 0.05, rollY, d * 0.5),
			Vector3.new(x + 0.05, rollY, d * 0.5),
			rollD + 0.04,
			{ name = "RollStrap", color = STRAP }
		)
	end

	-- Front pocket between the strap rails.
	local railX = w * 0.22
	piece(
		model,
		"FrontPocket",
		Vector3.new(w * 0.34, h * 0.36, 0.18 * k),
		CFrame.new(0, cy - h * 0.2, d + 0.09 * k - 0.01),
		shade(color, 0.8),
		true
	)
	-- Two vertical strap rails down the front, from the lid to the base, with buckles.
	local railTop, railBottom = lidY + lidH / 2, cy - h * 0.42
	for _, side in { -1, 1 } do
		piece(
			model,
			"StrapRail",
			Vector3.new(0.12 * k, railTop - railBottom, 0.05),
			CFrame.new(side * railX, (railTop + railBottom) / 2, d + 0.02),
			STRAP
		)
		for _, fy in { 0.18, -0.25 } do
			piece(
				model,
				"RailBuckle",
				Vector3.new(0.17 * k, 0.12 * k, 0.06),
				CFrame.new(side * railX, cy + h * fy, d + 0.05),
				BUCKLE
			)
		end
	end
	-- Side pockets and compression straps.
	for _, side in { -1, 1 } do
		piece(
			model,
			"SidePocket",
			Vector3.new(0.14 * k, h * 0.32, d * 0.75),
			CFrame.new(side * (w / 2 + 0.07 * k - 0.01), cy - h * 0.24, d * 0.5),
			shade(color, 0.75),
			true
		)
		piece(
			model,
			"CompressionStrap",
			Vector3.new(0.03, 0.09 * k, d * 0.92),
			CFrame.new(side * (w / 2 + 0.01), cy + h * 0.12, d * 0.5),
			STRAP
		)
	end
	-- Axe loop at the bottom of the outer face, outside the right rail.
	local axeX = w * 0.38
	piece(model, "AxeLoop", Vector3.new(0.14, 0.14, 0.06), CFrame.new(axeX, cy - h * 0.42, d + 0.03), STRAP)
	-- Haul loop behind the roll.
	piece(model, "HaulLoop", Vector3.new(0.25, 0.08, 0.05), CFrame.new(0, lidY + lidH / 2 + 0.03, 0.08), STRAP)
	-- Snow that settles on the top roll; EquipmentService fades it in during snowfall.
	local cap = piece(
		model,
		"SnowCap",
		Vector3.new(w * 0.9, 0.06, rollD * 0.7),
		CFrame.new(0, rollY + rollD / 2 - 0.01, d * 0.5),
		C(240, 244, 250),
		false,
		Enum.Material.Snow
	)
	cap.Transparency = 1

	local anchors = {
		-- Ice axe head-down in the axe loop, shaft up the face. The axe model's grip origin
		-- sits 1.6 studs from its head; rotated 180 degrees so the head is down.
		Axe = CFrame.new(axeX, cy - h * 0.42 + 1.6, d + 0.12) * CFrame.Angles(0, 0, math.pi),
		-- Rope coil under the lid, over the rails.
		Rope = CFrame.new(0, lidY - h * 0.16, d + 0.14),
		-- Tarp rolled under the base (roll radius 0.17 touches the base).
		Tarp = CFrame.new(0, cy - h * 0.45 - 0.17, d * 0.5),
		-- Wood strapped to the right side, logs touching the body.
		Wood = CFrame.new(w / 2 + 0.12, cy - h * 0.05, d * 0.5),
	}
	return model, anchors
end

-- Harness in torso space. `shellSize` is the OUTER size of whatever covers the torso (jacket
-- shell or bare torso) so the straps lie on top of it. Shoulder pads run from the pack over
-- each shoulder, padded straps run down the chest, webbing tails wrap to the pack's sides,
-- and a sternum strap with a buckle joins them.
function GearFactory.harness(shellSize: Vector3, packColor: Color3): Model
	local model = newModel("Harness")
	local s = shellSize
	local k = math.clamp(s.X / 2.2, 0.6, 1.6)
	local strapColor = shade(packColor, 0.7)
	local front = -s.Z / 2
	local padY = s.Y / 2 + 0.04
	local strapBottom = -s.Y * 0.18
	for _, side in { -1, 1 } do
		local x = side * s.X * 0.24
		piece(model, "ShoulderPad", Vector3.new(0.34 * k, 0.14, s.Z + 0.24), CFrame.new(x, padY, 0), strapColor, true)
		piece(
			model,
			"ChestStrap",
			Vector3.new(0.3 * k, padY - strapBottom, 0.1),
			CFrame.new(x, (padY + strapBottom) / 2, front - 0.05),
			strapColor,
			true
		)
		-- Webbing tail: from the strap's foot round the side to the pack's lower corner.
		local a = Vector3.new(x, strapBottom + 0.05, front - 0.04)
		local mid = Vector3.new(side * (s.X / 2 + 0.03), -s.Y * 0.3, 0)
		local b = Vector3.new(side * (s.X / 2 - 0.05), -s.Y * 0.35, s.Z / 2 + 0.1)
		for _, seg in { { a, mid }, { mid, b } } do
			AssetFactory.cylinderBetween(model, seg[1], seg[2], 0.06, { name = "StrapTail", color = STRAP })
		end
	end
	piece(
		model,
		"SternumStrap",
		Vector3.new(s.X * 0.48 + 0.3 * k, 0.07, 0.05),
		CFrame.new(0, s.Y * 0.22, front - 0.11),
		STRAP
	)
	piece(model, "SternumBuckle", Vector3.new(0.16, 0.12, 0.05), CFrame.new(0, s.Y * 0.22, front - 0.14), BUCKLE)
	return model
end

-- Hip belt in lower-torso space (`shellSize` = outer size of the lower torso cover).
function GearFactory.hipBelt(shellSize: Vector3, packColor: Color3): Model
	local model = newModel("HipBelt")
	local s = shellSize
	local hx, hz = s.X / 2, s.Z / 2
	for _, side in { -1, 1 } do
		piece(
			model,
			"HipWing",
			Vector3.new(0.12, math.min(0.36, s.Y * 0.9), s.Z * 0.95 + 0.1),
			CFrame.new(side * (hx + 0.05), 0, 0.05),
			shade(packColor, 0.7),
			true
		)
	end
	piece(model, "BeltWebbing", Vector3.new(s.X + 0.12, 0.1, 0.05), CFrame.new(0, 0, -hz - 0.03), STRAP)
	piece(model, "BeltBuckle", Vector3.new(0.3, 0.16, 0.06), CFrame.new(0, 0, -hz - 0.07), BUCKLE)
	return model
end

return GearFactory
