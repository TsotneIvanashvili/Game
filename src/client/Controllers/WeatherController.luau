--!strict
-- Renders the server's weather and the time of day. Purely cosmetic: survival uses the
-- server's numbers, never what the client draws.
--
-- Inputs (read at 10 Hz):
--   * ReplicatedStorage.WorldState attributes: Fog, Cloud, Precipitation, WindMs, WindDirection
--   * Lighting.ClockTime (the server owns the clock; this controller never writes it)
--   * Player attributes: InShelter
--
-- The world is always snow (ART_DIRECTION 2, 10): there is no rain path at all, whatever the
-- temperature. Outputs:
--   * Atmosphere: crisp blue sky in Clear, bright grey-white whiteout in storms/fog
--   * Lighting: time-of-day look (bright neutral day, golden hour, blue cold night), dimmed
--     and flattened by cloud; FogColor follows the atmosphere
--   * post effects StyleGrade (ColorCorrection), Bloom and SunRays, created if missing
--   * Terrain Clouds (cumulus cover) and an existing Sky's stars/celestial bodies, if present
--   * a snowfall emitter that never fully stops, plus wind-blown snow streaks near the camera
--     when the wind is above STREAK_MIN_WIND
--
-- Every input is smoothed (exponential follow), so nothing snaps even when an attribute or
-- the clock jumps. All Lighting writes happen at APPLY_HZ; per frame only the two emitter
-- boxes follow the camera.
--
-- ART: both emitters keep the default ParticleEmitter texture. Art should supply a proper
-- snowflake / streak texture (ParticleEmitter.Texture); never invent asset ids here. No Sky
-- is created: a Sky placed in Lighting by art is used, otherwise the default sky shows.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local WeatherController = {}

local player = Players.LocalPlayer

local APPLY_SECONDS = 0.1 -- 10 Hz
local FOLLOW_SECONDS = 2.5 -- time constant of the smoothing on every input

-- Precipitation.
local BOX_HEIGHT = 35
local SNOW_MIN_RATE = 30 -- always a few flakes, even in Clear
local SNOW_MAX_RATE = 420
local WIND_ACCEL = 0.8
local SNOW_GRAVITY = Vector3.new(0, -3, 0)
local STREAK_MIN_WIND = 8
local STREAK_FULL_WIND = 20
local STREAK_MAX_RATE = 260
local STREAK_UPWIND = 30 -- studs upwind of the camera the streak box sits
local STREAK_GRAVITY = Vector3.new(0, -1.5, 0)

-- Weather looks.
local ATMOS_CLEAR_DENSITY = 0.25
local ATMOS_STORM_DENSITY = 0.9
local ATMOS_STORM_DAY = Color3.fromRGB(220, 228, 236)
local ATMOS_STORM_NIGHT = Color3.fromRGB(92, 100, 118)
local OUTDOOR_STORM_DAY = Color3.fromRGB(176, 182, 192)
local OUTDOOR_STORM_NIGHT = Color3.fromRGB(70, 80, 100)
local CLOUD_CLEAR_COLOR = Color3.new(1, 1, 1)
local CLOUD_STORM_COLOR = Color3.fromRGB(205, 210, 218)
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local STAR_COUNT = 3000

-- Post effects created when Lighting has none.
local BLOOM_INTENSITY = 0.4
local BLOOM_THRESHOLD = 0.95
local BLOOM_SIZE = 24
local SUNRAYS_INTENSITY = 0.05
local SUNRAYS_SPREAD = 0.5

-- Time-of-day looks, keyed on Lighting.ClockTime. Weather is layered on top in apply().
type Look = {
	outdoor: Color3, -- Lighting.OutdoorAmbient
	ambient: Color3, -- Lighting.Ambient (indoors / occluded)
	brightness: number,
	shiftTop: Color3, -- Lighting.ColorShift_Top (sun/moon-facing tint)
	diffuse: number, -- EnvironmentDiffuseScale
	specular: number, -- EnvironmentSpecularScale
	atmosColor: Color3, -- clear-sky Atmosphere.Color
	atmosDecay: Color3, -- clear-sky Atmosphere.Decay
	saturation: number, -- StyleGrade
	contrast: number,
	tint: Color3,
	bloom: number, -- multiplier on the bloom's base intensity
	sunRays: number, -- multiplier on the sun rays' base intensity
}

local NIGHT: Look = {
	outdoor = Color3.fromRGB(60, 80, 120),
	ambient = Color3.fromRGB(38, 46, 66),
	brightness = 0.8,
	shiftTop = Color3.fromRGB(20, 34, 70),
	diffuse = 0.4,
	specular = 0.2,
	atmosColor = Color3.fromRGB(62, 76, 108),
	atmosDecay = Color3.fromRGB(28, 36, 60),
	saturation = 0,
	contrast = 0.04,
	tint = Color3.fromRGB(214, 226, 255),
	bloom = 0.6,
	sunRays = 0,
}
local BLUE_HOUR: Look = {
	outdoor = Color3.fromRGB(80, 96, 138),
	ambient = Color3.fromRGB(52, 58, 80),
	brightness = 1.0,
	shiftTop = Color3.fromRGB(70, 60, 90),
	diffuse = 0.55,
	specular = 0.3,
	atmosColor = Color3.fromRGB(120, 128, 170),
	atmosDecay = Color3.fromRGB(80, 70, 110),
	saturation = 0.08,
	contrast = 0.05,
	tint = Color3.fromRGB(226, 230, 255),
	bloom = 0.8,
	sunRays = 0,
}
local DAWN: Look = {
	outdoor = Color3.fromRGB(150, 132, 128),
	ambient = Color3.fromRGB(92, 82, 80),
	brightness = 1.7,
	shiftTop = Color3.fromRGB(150, 100, 60),
	diffuse = 0.75,
	specular = 0.4,
	atmosColor = Color3.fromRGB(226, 206, 196),
	atmosDecay = Color3.fromRGB(196, 132, 104),
	saturation = 0.18,
	contrast = 0.06,
	tint = Color3.fromRGB(255, 242, 228),
	bloom = 1.1,
	sunRays = 1.2,
}
local DAY: Look = {
	outdoor = Color3.fromRGB(140, 146, 156),
	ambient = Color3.fromRGB(105, 110, 120),
	brightness = 2.4,
	shiftTop = Color3.fromRGB(12, 10, 6),
	diffuse = 1,
	specular = 0.5,
	atmosColor = Color3.fromRGB(199, 220, 240),
	atmosDecay = Color3.fromRGB(92, 122, 164),
	saturation = 0.15,
	contrast = 0.05,
	tint = WHITE,
	bloom = 1,
	sunRays = 1,
}
local DUSK: Look = {
	outdoor = Color3.fromRGB(156, 126, 116),
	ambient = Color3.fromRGB(94, 78, 74),
	brightness = 1.6,
	shiftTop = Color3.fromRGB(175, 100, 50),
	diffuse = 0.7,
	specular = 0.4,
	atmosColor = Color3.fromRGB(232, 196, 176),
	atmosDecay = Color3.fromRGB(204, 116, 86),
	saturation = 0.2,
	contrast = 0.07,
	tint = Color3.fromRGB(255, 236, 218),
	bloom = 1.2,
	sunRays = 1.3,
}

local KEYFRAMES: { { hour: number, look: Look } } = {
	{ hour = 0, look = NIGHT },
	{ hour = 5.0, look = NIGHT },
	{ hour = 5.7, look = BLUE_HOUR },
	{ hour = 6.5, look = DAWN },
	{ hour = 8.2, look = DAY },
	{ hour = 16.4, look = DAY },
	{ hour = 17.8, look = DUSK },
	{ hour = 18.7, look = BLUE_HOUR },
	{ hour = 20.0, look = NIGHT },
	{ hour = 24, look = NIGHT },
}

-- Instances.
local atmosphere: Atmosphere
local grade: ColorCorrectionEffect
local bloom: BloomEffect
local sunRays: SunRaysEffect
local clouds: Instance? = nil
local box: Part
local snow: ParticleEmitter
local streakBox: Part
local streaks: ParticleEmitter
local worldState: Instance? = nil

local bloomBase = BLOOM_INTENSITY
local sunRaysBase = SUNRAYS_INTENSITY

-- Smoothed inputs.
local initialised = false
local fog = 0
local cloud = 0
local precip = 0
local windMs = 0
local windDir = Vector3.new(1, 0, 0)
local clock = 12
local night = 0

-- Per-frame placement (computed at APPLY_HZ).
local boxOffset = Vector3.new(0, BOX_HEIGHT, 0)
local streakOffset = Vector3.new(-STREAK_UPWIND, 2, 0)
local wasSheltered = false
local lastStarCount = -1
local lastBodiesShown: boolean? = nil

local function number(inst: Instance, name: string, default: number): number
	local v = inst:GetAttribute(name)
	return if typeof(v) == "number" then v else default
end

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- 0 at full day, 1 at full night. Read by AmbienceController for lamp/fire strength.
local function nightFromClock(h: number): number
	if h < 5 or h >= 20 then
		return 1
	elseif h < 7.2 then
		return 1 - smoothstep((h - 5) / 2.2)
	elseif h < 17.3 then
		return 0
	end
	return smoothstep((h - 17.3) / 2.7)
end

local mixed: Look = table.clone(DAY)

local function lookAt(h: number): Look
	local a, b = KEYFRAMES[1], KEYFRAMES[2]
	for i = 1, #KEYFRAMES - 1 do
		if h >= KEYFRAMES[i].hour and h < KEYFRAMES[i + 1].hour then
			a, b = KEYFRAMES[i], KEYFRAMES[i + 1]
			break
		end
	end
	local t = smoothstep((h - a.hour) / math.max(b.hour - a.hour, 1e-3))
	local la, lb = a.look, b.look
	if la == lb then
		return la
	end
	mixed.outdoor = la.outdoor:Lerp(lb.outdoor, t)
	mixed.ambient = la.ambient:Lerp(lb.ambient, t)
	mixed.brightness = lerp(la.brightness, lb.brightness, t)
	mixed.shiftTop = la.shiftTop:Lerp(lb.shiftTop, t)
	mixed.diffuse = lerp(la.diffuse, lb.diffuse, t)
	mixed.specular = lerp(la.specular, lb.specular, t)
	mixed.atmosColor = la.atmosColor:Lerp(lb.atmosColor, t)
	mixed.atmosDecay = la.atmosDecay:Lerp(lb.atmosDecay, t)
	mixed.saturation = lerp(la.saturation, lb.saturation, t)
	mixed.contrast = lerp(la.contrast, lb.contrast, t)
	mixed.tint = la.tint:Lerp(lb.tint, t)
	mixed.bloom = lerp(la.bloom, lb.bloom, t)
	mixed.sunRays = lerp(la.sunRays, lb.sunRays, t)
	return mixed
end

local function makeBox(name: string, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Locked = true
	return p
end

local function makeEmitter(name: string, parent: Part, direction: Enum.NormalId): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	-- Texture intentionally left at the default: art must supply the flake/streak texture.
	e.EmissionDirection = direction
	e.LockedToPart = false
	e.Rate = 0
	e.Enabled = false
	-- Emit from anywhere inside the box rather than its surface. Shape/ShapeStyle are newer
	-- ParticleEmitter properties; guarded so an engine without them still runs.
	pcall(function()
		e.Shape = Enum.ParticleEmitterShape.Box
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	end)
	e.Parent = parent
	return e
end

local function buildPrecipitation()
	box = makeBox("SnowfallBox", Vector3.new(80, 1, 80))
	snow = makeEmitter("Snow", box, Enum.NormalId.Bottom)
	snow.Color = ColorSequence.new(WHITE)
	snow.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.18, 0.06),
		NumberSequenceKeypoint.new(1, 0.18, 0.06),
	})
	snow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.08, 0.15),
		NumberSequenceKeypoint.new(0.9, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	snow.Lifetime = NumberRange.new(6, 9)
	snow.Speed = NumberRange.new(4, 8)
	snow.SpreadAngle = Vector2.new(25, 25)
	snow.Drag = 0.6
	snow.Rotation = NumberRange.new(0, 360)
	snow.RotSpeed = NumberRange.new(-90, 90)
	snow.Acceleration = SNOW_GRAVITY

	-- Wind-blown streaks: emitted out of the box's Front face, which apply() points downwind.
	streakBox = makeBox("WindStreakBox", Vector3.new(50, 16, 4))
	streaks = makeEmitter("WindStreaks", streakBox, Enum.NormalId.Front)
	streaks.Color = ColorSequence.new(Color3.fromRGB(240, 246, 255))
	streaks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.07, 0.03),
		NumberSequenceKeypoint.new(1, 0.07, 0.03),
	})
	streaks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.12, 0.25),
		NumberSequenceKeypoint.new(0.85, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	streaks.Lifetime = NumberRange.new(0.9, 1.3)
	streaks.Speed = NumberRange.new(45, 65)
	streaks.SpreadAngle = Vector2.new(4, 10)
	streaks.Drag = 0
	streaks.Orientation = Enum.ParticleOrientation.VelocityParallel
	streaks.Squash = NumberSequence.new(2.5) -- positive squash stretches along the velocity
	streaks.Acceleration = STREAK_GRAVITY

	box.Parent = workspace
	streakBox.Parent = workspace
end

local function setSky()
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		return
	end
	local stars = math.floor(STAR_COUNT * (1 - math.max(cloud, fog)) * night + 0.5)
	local shown = cloud < 0.85 and fog < 0.6
	if stars == lastStarCount and shown == lastBodiesShown then
		return
	end
	lastStarCount = stars
	lastBodiesShown = shown
	pcall(function()
		sky.StarCount = stars
		sky.CelestialBodiesShown = shown
	end)
end

local function apply()
	local look = lookAt(clock)
	local day = 1 - night
	-- Whiteout: fog and heavy snow both wash the world to bright grey-white.
	local whiteout = smoothstep(math.max(fog, precip * 0.85))
	local overcast = math.clamp(cloud, 0, 1)

	-- Atmosphere.
	local stormColor = ATMOS_STORM_NIGHT:Lerp(ATMOS_STORM_DAY, day)
	local atmosColor = look.atmosColor:Lerp(stormColor, whiteout)
	atmosphere.Density = lerp(ATMOS_CLEAR_DENSITY, ATMOS_STORM_DENSITY, whiteout) + overcast * 0.04
	atmosphere.Haze = math.clamp(0.8 + overcast * 0.8 + whiteout * 7.5, 0, 10)
	atmosphere.Glare = (1 - overcast) * (1 - whiteout) * 0.3 * day
	atmosphere.Color = atmosColor
	atmosphere.Decay = look.atmosDecay:Lerp(stormColor, whiteout)
	Lighting.FogColor = atmosColor

	-- Lighting: time of day, flattened and dimmed by cloud.
	local stormOutdoor = OUTDOOR_STORM_NIGHT:Lerp(OUTDOOR_STORM_DAY, day)
	Lighting.OutdoorAmbient = look.outdoor:Lerp(stormOutdoor, math.clamp(overcast * 0.6 + whiteout * 0.4, 0, 1))
	Lighting.Ambient = look.ambient
	Lighting.Brightness = look.brightness * (1 - 0.5 * overcast)
	Lighting.ColorShift_Top = look.shiftTop:Lerp(BLACK, overcast)
	Lighting.EnvironmentDiffuseScale = look.diffuse
	Lighting.EnvironmentSpecularScale = look.specular * (1 - 0.5 * overcast)

	-- Post: punchy by clear day, flat in a whiteout.
	grade.Saturation = look.saturation * (1 - 0.8 * whiteout)
	grade.Contrast = look.contrast * (1 - whiteout) - 0.03 * whiteout
	grade.TintColor = look.tint:Lerp(WHITE, whiteout * 0.5)
	bloom.Intensity = bloomBase * look.bloom * (1 - 0.6 * whiteout)
	sunRays.Intensity = sunRaysBase * look.sunRays * (1 - overcast) * (1 - whiteout)

	-- Clouds: scattered cumulus when clear, a lid in a storm.
	local c = clouds
	if c then
		pcall(function()
			local cl = c :: any
			cl.Cover = math.clamp(0.45 + overcast * 0.5, 0, 1)
			cl.Density = math.clamp(0.35 + overcast * 0.5, 0, 1)
			cl.Color = CLOUD_CLEAR_COLOR:Lerp(CLOUD_STORM_COLOR, overcast)
		end)
	end
	setSky()

	-- Snow. Never fully stops; heavier with precipitation; hidden while sheltered.
	local sheltered = player:GetAttribute("InShelter") == true
	local wind = windDir * windMs * WIND_ACCEL
	snow.Enabled = not sheltered
	snow.Rate = SNOW_MIN_RATE + precip * (SNOW_MAX_RATE - SNOW_MIN_RATE)
	snow.Acceleration = SNOW_GRAVITY + wind

	local streakT = math.clamp((windMs - STREAK_MIN_WIND) / (STREAK_FULL_WIND - STREAK_MIN_WIND), 0, 1)
	streaks.Enabled = streakT > 0.01 and not sheltered
	streaks.Rate = STREAK_MAX_RATE * streakT * (0.4 + 0.6 * math.max(precip, 0.3))
	if sheltered and not wasSheltered then
		-- Don't let already-falling particles drift through the roof.
		snow:Clear()
		streaks:Clear()
	end
	wasSheltered = sheltered

	-- Shift the snow box upwind so blown flakes land around the camera, not downwind of it.
	local upwind = -windDir * math.min(windMs * 1.2, 25)
	boxOffset = Vector3.new(upwind.X, BOX_HEIGHT, upwind.Z)
	streakOffset = -windDir * STREAK_UPWIND + Vector3.new(0, 2, 0)
end

local function sample(dt: number)
	worldState = worldState or ReplicatedStorage:FindFirstChild("WorldState")
	local ws = worldState
	local tFog, tCloud, tPrecip, tWind = 0, 0.1, 0, 2
	local tDir = windDir
	if ws then
		tFog = math.clamp(number(ws, "Fog", 0), 0, 1)
		tCloud = math.clamp(number(ws, "Cloud", 0.1), 0, 1)
		tPrecip = math.clamp(number(ws, "Precipitation", 0), 0, 1)
		tWind = math.max(0, number(ws, "WindMs", 0))
		local raw = ws:GetAttribute("WindDirection")
		if typeof(raw) == "Vector3" then
			local flat = Vector3.new(raw.X, 0, raw.Z)
			if flat.Magnitude > 1e-3 then
				tDir = flat.Unit
			end
		end
	end
	local tClock = Lighting.ClockTime

	if not initialised then
		initialised = true
		fog, cloud, precip, windMs, windDir, clock = tFog, tCloud, tPrecip, tWind, tDir, tClock
	else
		local k = 1 - math.exp(-dt / FOLLOW_SECONDS)
		fog = lerp(fog, tFog, k)
		cloud = lerp(cloud, tCloud, k)
		precip = lerp(precip, tPrecip, k)
		windMs = lerp(windMs, tWind, k)
		local d = windDir:Lerp(tDir, k)
		if d.Magnitude > 1e-3 then
			windDir = d.Unit
		end
		-- Shortest way round the 24 h dial, so 23:59 -> 00:00 doesn't sweep through the day.
		local delta = ((tClock - clock + 12) % 24) - 12
		clock = (clock + delta * k) % 24
	end
	night = nightFromClock(clock)
	apply()
end

-- 0 = full day, 1 = full night (smoothed). Safe to call any time.
function WeatherController.nightFactor(): number
	return night
end

local function findOrCreate(className: string, name: string): (Instance, boolean)
	local existing = Lighting:FindFirstChildOfClass(className)
	if existing then
		return existing, false
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = Lighting
	return inst, true
end

function WeatherController.Init()
	local atmos, created = findOrCreate("Atmosphere", "Atmosphere")
	atmosphere = atmos :: Atmosphere
	if created then
		-- The server's Atmosphere may replicate a moment later; two Atmospheres stack their
		-- density. When it arrives, drop ours and drive the server's instead.
		local ours = atmosphere
		local conn: RBXScriptConnection? = nil
		conn = Lighting.ChildAdded:Connect(function(child)
			if child:IsA("Atmosphere") and child ~= ours then
				atmosphere = child
				ours:Destroy()
				if conn then
					conn:Disconnect()
				end
			end
		end)
	end

	-- StyleGrade is always ours (by name), never a ColorCorrection someone else owns.
	local existingGrade = Lighting:FindFirstChild("StyleGrade")
	if existingGrade and existingGrade:IsA("ColorCorrectionEffect") then
		grade = existingGrade :: ColorCorrectionEffect
	else
		grade = Instance.new("ColorCorrectionEffect")
		grade.Name = "StyleGrade"
		grade.Parent = Lighting
	end

	local bloomInst, bloomCreated = findOrCreate("BloomEffect", "StyleBloom")
	bloom = bloomInst :: BloomEffect
	if bloomCreated then
		bloom.Intensity = BLOOM_INTENSITY
		bloom.Threshold = BLOOM_THRESHOLD
		bloom.Size = BLOOM_SIZE
	end
	bloomBase = bloom.Intensity

	local raysInst, raysCreated = findOrCreate("SunRaysEffect", "StyleSunRays")
	sunRays = raysInst :: SunRaysEffect
	if raysCreated then
		sunRays.Intensity = SUNRAYS_INTENSITY
		sunRays.Spread = SUNRAYS_SPREAD
	end
	sunRaysBase = sunRays.Intensity

	-- Terrain Clouds are optional; guarded in case the class isn't creatable on this client.
	pcall(function()
		local terrain = workspace.Terrain
		local found = terrain:FindFirstChildOfClass("Clouds")
		if not found then
			found = Instance.new("Clouds")
			found.Parent = terrain
		end
		clouds = found
	end)
	buildPrecipitation()
end

function WeatherController.Start()
	local accumulator = APPLY_SECONDS
	RunService.RenderStepped:Connect(function(dt)
		accumulator += dt
		if accumulator >= APPLY_SECONDS then
			local step = accumulator
			accumulator = 0
			sample(step)
		end

		local camera = workspace.CurrentCamera
		if camera then
			local at = camera.CFrame.Position
			box.Position = at + boxOffset
			local origin = at + streakOffset
			streakBox.CFrame = CFrame.lookAt(origin, origin + windDir)
		end
	end)
end

return WeatherController
