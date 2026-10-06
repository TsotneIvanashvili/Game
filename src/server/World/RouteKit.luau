--!strict
-- Part-built route props in the ART_DIRECTION v2 style: chunky, bright, readable from afar.
--   ropeBridge(fromAnchor, toAnchor, width)  plank deck on rope rails, posts, mid-span sag
--   ladder(bottom, top)                      TrussPart core (native climbing) + metal rails
--   markerPole(pos, yaw?)                    red/white striped pole with a small red flag
--   warningSign(pos, text, toward?)          yellow triangle + text board on a post
--   ropeFence(points)                        posts with sagging rope between them
--   fixedRope(points)                        pickets with a taut handline along a pitch
--   summitFlag(pos)                          cairn of stones and a tall flag
-- Anchors / points are positions ON the terrain surface. Every builder returns a Model.
-- Decorative parts are CanCollide/CanQuery/CanTouch false; walkable parts (planks, posts,
-- the truss) collide and are queryable so ground checks and footsteps see them.

local RouteKit = {}

local WOOD = Color3.fromRGB(214, 180, 120) -- crate / plank wood
local ROPE = Color3.fromRGB(120, 85, 55) -- pole / rope brown
local MARKER_RED = Color3.fromRGB(220, 40, 40)
local MARKER_WHITE = Color3.fromRGB(245, 245, 245)
local SIGN_YELLOW = Color3.fromRGB(245, 200, 40)
local SIGN_DARK = Color3.fromRGB(30, 30, 34)
local ALUMINIUM = Color3.fromRGB(190, 196, 204)
local STONE = Color3.fromRGB(112, 112, 118)
local SNOW = Color3.fromRGB(236, 242, 250)

local UP = Vector3.new(0, 1, 0)

type PartProps = {
	name: string?,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?,
	collide: boolean?, -- default false (decorative)
	shadow: boolean?,
	transparency: number?,
	shape: Enum.PartType?,
}

local function part(parent: Instance, props: PartProps): BasePart
	local p = Instance.new("Part")
	p.Name = props.name or "Part"
	if props.shape then
		p.Shape = props.shape
	end
	p.Size = props.size
	p.CFrame = props.cframe
	p.Color = props.color
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	p.Anchored = true
	local collide = props.collide == true
	p.CanCollide = collide
	p.CanQuery = collide
	p.CanTouch = false
	p.CastShadow = props.shadow == true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function newModel(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

-- Orthonormal frame at `pos` whose look (-Z) vector is `dir`; safe for vertical dirs.
local function frameLooking(pos: Vector3, dir: Vector3): CFrame
	local look = if dir.Magnitude > 1e-6 then dir.Unit else Vector3.new(0, 0, -1)
	local ref = if math.abs(look.Y) < 0.99 then UP else Vector3.new(1, 0, 0)
	local right = look:Cross(ref).Unit
	local up = right:Cross(look).Unit
	return CFrame.fromMatrix(pos, right, up, -look)
end

-- A square-section beam (rope, rail, rung) from a to b.
local function beam(parent: Instance, a: Vector3, b: Vector3, thickness: number, props: { [string]: any }?): BasePart
	local length = math.max((b - a).Magnitude, 0.05)
	return part(parent, {
		name = props and props.name or "Rope",
		size = Vector3.new(thickness, thickness, length),
		cframe = frameLooking((a + b) / 2, b - a),
		color = props and props.color or ROPE,
		material = props and props.material,
		collide = props and props.collide,
	})
end

-- Horizontal unit direction and right vector from a to b.
local function horizontalAxes(a: Vector3, b: Vector3): (Vector3, Vector3)
	local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local dir = if flat.Magnitude > 1e-6 then flat.Unit else Vector3.new(0, 0, 1)
	local right = dir:Cross(UP).Unit
	return dir, right
end

-- A solid triangle (a, b, c) of the given thickness from two wedges.
local function triangle(parent: Instance, a: Vector3, b: Vector3, c: Vector3, thickness: number, color: Color3)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	for i = 1, 2 do
		local w = Instance.new("WedgePart")
		w.Name = "Sign"
		w.Anchored = true
		w.CanCollide = false
		w.CanQuery = false
		w.CanTouch = false
		w.CastShadow = false
		w.Material = Enum.Material.SmoothPlastic
		w.Color = color
		if i == 1 then
			w.Size = Vector3.new(thickness, height, math.abs(ab:Dot(back)))
			w.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
		else
			w.Size = Vector3.new(thickness, height, math.abs(ac:Dot(back)))
			w.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
		end
		w.Parent = parent
	end
end

-- Rope bridge -------------------------------------------------------------------------------

-- Deck height at fraction t across the span: straight line between anchors minus a sag.
local function deckY(a: Vector3, b: Vector3, sag: number, t: number): number
	return a.Y + (b.Y - a.Y) * t - sag * 4 * t * (1 - t)
end

function RouteKit.ropeBridge(fromAnchor: Vector3, toAnchor: Vector3, width: number): Model
	local model = newModel("RopeBridge")
	local dir, right = horizontalAxes(fromAnchor, toAnchor)
	local flat = Vector3.new(toAnchor.X - fromAnchor.X, 0, toAnchor.Z - fromAnchor.Z).Magnitude
	local sag = math.min(2.2, flat * 0.045)
	local lift = 0.35 -- deck top sits just above the snow at each end
	local a = fromAnchor + Vector3.new(0, lift, 0)
	local b = toAnchor + Vector3.new(0, lift, 0)
	local function at(t: number, side: number, height: number): Vector3
		local p = fromAnchor:Lerp(toAnchor, t)
		return Vector3.new(p.X, deckY(a, b, sag, t) + height, p.Z) + right * side
	end

	-- Planks: 1.1 deep with ~0.3 gaps, following the sag curve.
	local pitch = 1.4
	local count = math.max(2, math.floor(flat / pitch))
	local first: BasePart? = nil
	for i = 0, count do
		local t = i / count
		local t0, t1 = math.max(0, t - 0.01), math.min(1, t + 0.01)
		local tangent = at(t1, 0, 0) - at(t0, 0, 0)
		local center = at(t, 0, -0.2)
		local shade = if i % 3 == 0 then 0.88 else (if i % 3 == 1 then 1 else 0.94)
		local plank = part(model, {
			name = "Plank",
			size = Vector3.new(width, 0.4, 1.1),
			cframe = frameLooking(center, tangent),
			color = Color3.new(WOOD.R * shade, WOOD.G * shade, WOOD.B * shade),
			material = Enum.Material.WoodPlanks,
			collide = true,
		})
		first = first or plank
	end
	model.PrimaryPart = first

	-- Rope rails (hand height, sagging a bit more than the deck) and deck edge ropes.
	local half = width / 2 + 0.25
	local segments = math.max(4, math.floor(flat / 4))
	for _, side in { -half, half } do
		for s = 1, segments do
			local t0, t1 = (s - 1) / segments, s / segments
			local extra0, extra1 = 0.5 * 4 * t0 * (1 - t0), 0.5 * 4 * t1 * (1 - t1)
			beam(model, at(t0, side, 3.2 - extra0), at(t1, side, 3.2 - extra1), 0.22, { name = "HandRope" })
			beam(model, at(t0, side, -0.15), at(t1, side, -0.15), 0.2, { name = "DeckRope" })
		end
		-- Hangers from hand rope to deck every few planks.
		for s = 1, segments - 1 do
			local t = s / segments
			local extra = 0.5 * 4 * t * (1 - t)
			beam(model, at(t, side, -0.1), at(t, side, 3.2 - extra), 0.12, { name = "Hanger" })
		end
		-- Invisible guard so the bridge is not a balance beam.
		local g0, g1 = at(0, side + math.sign(side) * 0.2, 1.5), at(1, side + math.sign(side) * 0.2, 1.5)
		part(model, {
			name = "Guard",
			size = Vector3.new(0.3, 3, (g1 - g0).Magnitude),
			cframe = frameLooking((g0 + g1) / 2, g1 - g0),
			color = ROPE,
			transparency = 1,
			collide = true,
		})
	end

	-- Posts at both ends, planted in the snow, ropes tied to their tops.
	for _, endT in { 0, 1 } do
		local anchor = if endT == 0 then fromAnchor else toAnchor
		local back = if endT == 0 then -dir else dir
		for _, side in { -half - 0.3, half + 0.3 } do
			local base = anchor + right * side + back * 0.6
			part(model, {
				name = "Post",
				size = Vector3.new(0.7, 5, 0.7),
				cframe = CFrame.new(base + Vector3.new(0, 1.8, 0)),
				color = ROPE,
				material = Enum.Material.Wood,
				collide = true,
				shadow = true,
			})
			part(model, {
				name = "PostCap",
				size = Vector3.new(0.85, 0.3, 0.85),
				cframe = CFrame.new(base + Vector3.new(0, 4.4, 0)),
				color = SNOW,
				material = Enum.Material.Snow,
			})
		end
	end
	return model
end

-- Ladder ------------------------------------------------------------------------------------

-- `bottom`: where the ladder stands (on the lower ground, right against the wall).
-- `top`: a point on the upper level just past the lip (sets the height and facing).
function RouteKit.ladder(bottom: Vector3, top: Vector3): Model
	local model = newModel("Ladder")
	local dir, right = horizontalAxes(bottom, top)
	local rise = top.Y - bottom.Y + 3.5 -- runs past the lip so you can step off at the top
	local height = math.max(2, math.ceil(rise / 2) * 2) -- trusses come in 2-stud steps
	local base = Vector3.new(bottom.X, bottom.Y - 0.5, bottom.Z)
	local frame = CFrame.fromMatrix(base + Vector3.new(0, height / 2, 0), right, UP, -dir)

	local truss = Instance.new("TrussPart")
	truss.Name = "Truss"
	truss.Anchored = true
	truss.Size = Vector3.new(2, height, 2)
	truss.CFrame = frame
	truss.Material = Enum.Material.Metal
	truss.Color = ALUMINIUM
	truss.CanTouch = false
	pcall(function()
		local anyTruss: any = truss
		anyTruss.Style = Enum.Style.NoSupports
	end)
	truss.Parent = model
	model.PrimaryPart = truss

	-- Side rails and a pair of grab handles curling over the lip.
	for _, side in { -1.25, 1.25 } do
		part(model, {
			name = "Rail",
			size = Vector3.new(0.3, height + 1, 0.3),
			cframe = frame * CFrame.new(side, 0.5, 0),
			color = ALUMINIUM,
			material = Enum.Material.Metal,
			shadow = true,
		})
		local handleBase = (frame * CFrame.new(side, height / 2 + 1, 0)).Position
		beam(model, handleBase, handleBase + dir * 2.2 + Vector3.new(0, 0.6, 0), 0.26, {
			name = "Handle",
			color = ALUMINIUM,
			material = Enum.Material.Metal,
		})
	end
	-- Feet plates so it reads as planted.
	part(model, {
		name = "Foot",
		size = Vector3.new(3.2, 0.3, 1.2),
		cframe = CFrame.fromMatrix(base + Vector3.new(0, 0.6, 0), right, UP, -dir) * CFrame.new(0, 0, 0.4),
		color = ALUMINIUM,
		material = Enum.Material.Metal,
	})
	return model
end

-- Marker pole -------------------------------------------------------------------------------

function RouteKit.markerPole(pos: Vector3, yaw: number?): Model
	local model = newModel("RouteMarker")
	local base = CFrame.new(pos) * CFrame.Angles(0, yaw or 0, 0)
	local height = 7
	local pole = part(model, {
		name = "Pole",
		size = Vector3.new(0.35, height, 0.35),
		cframe = base * CFrame.new(0, height / 2 - 0.4, 0),
		color = MARKER_WHITE,
	})
	model.PrimaryPart = pole
	for i, y in { 1.2, 3.0, 4.8 } do
		part(model, {
			name = "Stripe" .. i,
			size = Vector3.new(0.4, 0.9, 0.4),
			cframe = base * CFrame.new(0, y, 0),
			color = MARKER_RED,
		})
	end
	part(model, {
		name = "Flag",
		size = Vector3.new(0.08, 0.9, 1.5),
		cframe = base * CFrame.new(0, height - 1.1, 0.8),
		color = MARKER_RED,
		material = Enum.Material.Fabric,
	})
	return model
end

-- Warning sign ------------------------------------------------------------------------------

local function signText(board: BasePart, face: Enum.NormalId, text: string)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.2
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = SIGN_DARK
	label.Text = text
	label.Parent = gui
	gui.Parent = board
end

-- `toward`: a point the sign faces (defaults to facing +Z).
function RouteKit.warningSign(pos: Vector3, text: string, toward: Vector3?): Model
	local model = newModel("WarningSign")
	local look = if toward then Vector3.new(toward.X - pos.X, 0, toward.Z - pos.Z) else Vector3.new(0, 0, 1)
	local frame = frameLooking(pos, look)
	local post = part(model, {
		name = "Post",
		size = Vector3.new(0.5, 7, 0.5),
		cframe = frame * CFrame.new(0, 3.1, 0.35),
		color = ROPE,
		material = Enum.Material.Wood,
		collide = true,
		shadow = true,
	})
	model.PrimaryPart = post

	-- Triangle (dark border behind a yellow face), apex up.
	local center = (frame * CFrame.new(0, 6.0, 0)).Position
	local r, u = frame.RightVector, frame.UpVector
	local fwd = frame.LookVector
	local function tri(size: number, offset: number, color: Color3)
		local h = size * math.sqrt(3) / 2
		local c = center + fwd * offset
		triangle(model, c - r * size / 2 - u * h / 3, c + r * size / 2 - u * h / 3, c + u * h * 2 / 3, 0.2, color)
	end
	tri(3.6, 0, SIGN_DARK)
	tri(3.0, 0.08, SIGN_YELLOW)
	-- Exclamation mark.
	part(model, {
		name = "Mark",
		size = Vector3.new(0.3, 0.9, 0.06),
		cframe = CFrame.fromMatrix(center + fwd * 0.2 + u * 0.15, r, u, -fwd),
		color = SIGN_DARK,
	})
	part(model, {
		name = "Dot",
		size = Vector3.new(0.3, 0.26, 0.06),
		cframe = CFrame.fromMatrix(center + fwd * 0.2 - u * 0.55, r, u, -fwd),
		color = SIGN_DARK,
	})

	-- Text board under the triangle, readable from both sides.
	local width = math.clamp(#text * 0.42 + 0.8, 3.2, 7.5)
	local board = part(model, {
		name = "Board",
		size = Vector3.new(width, 1.2, 0.2),
		cframe = frame * CFrame.new(0, 3.9, 0),
		color = SIGN_YELLOW,
		shadow = true,
	})
	signText(board, Enum.NormalId.Front, text)
	signText(board, Enum.NormalId.Back, text)
	return model
end

-- Fences and fixed ropes --------------------------------------------------------------------

-- Posts at every point (on the surface) with two sagging rope strands between neighbours.
function RouteKit.ropeFence(points: { Vector3 }): Model
	local model = newModel("RopeFence")
	for i, p in points do
		local post = part(model, {
			name = "Post",
			size = Vector3.new(0.4, 3.8, 0.4),
			cframe = CFrame.new(p + Vector3.new(0, 1.5, 0)),
			color = ROPE,
			material = Enum.Material.Wood,
			collide = true,
		})
		if i == 1 then
			model.PrimaryPart = post
		end
		local nextP = points[i + 1]
		if nextP then
			for _, h in { 1.5, 3.0 } do
				local a, b = p + Vector3.new(0, h, 0), nextP + Vector3.new(0, h, 0)
				local mid = (a + b) / 2 - Vector3.new(0, math.min(0.6, (b - a).Magnitude * 0.04), 0)
				beam(model, a, mid, 0.18)
				beam(model, mid, b, 0.18)
			end
		end
	end
	return model
end

-- Metal pickets at every point with a taut handline ~1 stud above the snow.
function RouteKit.fixedRope(points: { Vector3 }): Model
	local model = newModel("FixedRope")
	for i, p in points do
		local picket = part(model, {
			name = "Picket",
			size = Vector3.new(0.3, 1.8, 0.3),
			cframe = CFrame.new(p + Vector3.new(0, 0.5, 0)),
			color = ALUMINIUM,
			material = Enum.Material.Metal,
		})
		if i == 1 then
			model.PrimaryPart = picket
		end
		local nextP = points[i + 1]
		if nextP then
			beam(model, p + Vector3.new(0, 1.2, 0), nextP + Vector3.new(0, 1.2, 0), 0.2, {
				name = "Handline",
				color = MARKER_RED,
			})
		end
	end
	return model
end

-- Summit ------------------------------------------------------------------------------------

function RouteKit.summitFlag(pos: Vector3): Model
	local model = newModel("SummitFlag")
	-- Cairn: stacked, slightly rotated stones with snow on top.
	local sizes = { Vector3.new(4.2, 1.6, 3.8), Vector3.new(3.4, 1.4, 3.2), Vector3.new(2.6, 1.2, 2.4) }
	local y = 0
	local cairnBase = pos + Vector3.new(2.5, 0, 0)
	for i, size in sizes do
		local stone = part(model, {
			name = "CairnStone",
			size = size,
			cframe = CFrame.new(cairnBase + Vector3.new(0, y + size.Y / 2 - 0.2, 0)) * CFrame.Angles(0, i * 0.7, 0),
			color = STONE,
			material = Enum.Material.Slate,
			collide = true,
			shadow = true,
		})
		if i == 1 then
			model.PrimaryPart = stone
		end
		y += size.Y - 0.25
	end
	part(model, {
		name = "CairnSnow",
		size = Vector3.new(2.2, 0.3, 2.0),
		cframe = CFrame.new(cairnBase + Vector3.new(0, y + 0.05, 0)),
		color = SNOW,
		material = Enum.Material.Snow,
	})
	-- Flag pole and a big flag.
	local poleBase = pos + Vector3.new(-1.5, 0, 0)
	part(model, {
		name = "FlagPole",
		size = Vector3.new(0.45, 14, 0.45),
		cframe = CFrame.new(poleBase + Vector3.new(0, 6.6, 0)),
		color = ALUMINIUM,
		material = Enum.Material.Metal,
		collide = true,
		shadow = true,
	})
	part(model, {
		name = "Flag",
		size = Vector3.new(0.1, 3.2, 5),
		cframe = CFrame.new(poleBase + Vector3.new(0, 11.6, 2.7)),
		color = MARKER_RED,
		material = Enum.Material.Fabric,
		shadow = true,
	})
	part(model, {
		name = "FlagStripe",
		size = Vector3.new(0.12, 0.8, 5),
		cframe = CFrame.new(poleBase + Vector3.new(0, 11.6, 2.7)),
		color = MARKER_WHITE,
		material = Enum.Material.Fabric,
	})
	part(model, {
		name = "PoleTip",
		size = Vector3.new(0.8, 0.8, 0.8),
		cframe = CFrame.new(poleBase + Vector3.new(0, 13.8, 0)),
		color = Color3.fromRGB(245, 200, 40),
		shape = Enum.PartType.Ball,
	})
	return model
end

return RouteKit
