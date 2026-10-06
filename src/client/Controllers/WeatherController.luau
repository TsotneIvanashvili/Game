--!strict
-- Renders the server's weather. WeatherService publishes the blended state as attributes
-- on ReplicatedStorage.WorldState (Fog, Cloud, Precipitation, WindMs, WindDirection, ...);
-- this controller turns it into sky and particles. Purely cosmetic: survival uses the
-- server's numbers, never what the client draws.
--
--   * Lighting.Atmosphere density/haze/colour from Fog and Cloud (near-whiteout in a blizzard)
--   * Lighting brightness and outdoor ambient dim with cloud and storms
--   * one client-only emitter box 35 studs above the camera: snow below the rain/snow split
--     temperature, rain above it, rate from Precipitation, pushed by the wind
--   * particles hide while the server says we're sheltered (InShelter)
--   * lightning flashes (and Thunder via AudioController) in heavy rain
--
-- ART: both emitters keep the default ParticleEmitter texture. Art must supply proper
-- snowflake and raindrop textures (set ParticleEmitter.Texture); never invent asset ids here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeatherDefs = require(Shared.Config.WeatherDefs)
local WeatherModel = require(Shared.Logic.WeatherModel)
local AudioController = require(script.Parent.AudioController)

local WeatherController = {}

local player = Players.LocalPlayer

local SAMPLE_SECONDS = 0.25
local BOX_HEIGHT = 35
local SNOW_RATE = 350
local RAIN_RATE = 500
local WIND_ACCEL = 0.8
local CLEAR_BRIGHTNESS = 2.5
local STORM_BRIGHTNESS = 1.0
local LIGHTNING_MIN_PRECIP = 0.7

local ATMOS_CLEAR = Color3.fromRGB(199, 212, 228)
local ATMOS_STORM = Color3.fromRGB(158, 162, 170)
local DECAY_CLEAR = Color3.fromRGB(106, 112, 125)
local DECAY_STORM = Color3.fromRGB(88, 90, 95)
local AMBIENT_CLEAR = Color3.fromRGB(128, 128, 128)
local AMBIENT_STORM = Color3.fromRGB(68, 72, 80)
local SNOW_GRAVITY = Vector3.new(0, -3, 0)
local RAIN_GRAVITY = Vector3.new(0, -40, 0)

local atmosphere: Atmosphere
local clouds: Instance? = nil
local box: Part
local snow: ParticleEmitter
local rain: ParticleEmitter
local worldState: Instance? = nil
local rng = Random.new()

local baseBrightness = CLEAR_BRIGHTNESS
local boxOffset = Vector3.new(0, BOX_HEIGHT, 0)
local wasSheltered = false
local flashTime = 0 -- seconds left in the current flash
local flashDuration = 0
local flashStrength = 0

local function number(inst: Instance, name: string, default: number): number
	local v = inst:GetAttribute(name)
	return if typeof(v) == "number" then v else default
end

local function makeEmitter(name: string): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	-- Texture intentionally left at the default: art must supply the snowflake/raindrop texture.
	e.EmissionDirection = Enum.NormalId.Bottom
	e.LockedToPart = false
	e.Rate = 0
	e.Enabled = false
	-- Emit from anywhere inside the box rather than its surface. Shape/ShapeStyle are newer
	-- ParticleEmitter properties; guarded so an engine without them still runs.
	pcall(function()
		e.Shape = Enum.ParticleEmitterShape.Box
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	end)
	e.Parent = box
	return e
end

local function buildPrecipitation()
	box = Instance.new("Part")
	box.Name = "PrecipitationBox"
	box.Size = Vector3.new(80, 1, 80)
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.CastShadow = false
	box.Transparency = 1
	box.Locked = true

	snow = makeEmitter("Snow")
	snow.Color = ColorSequence.new(Color3.new(1, 1, 1))
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

	rain = makeEmitter("Rain")
	rain.Color = ColorSequence.new(Color3.fromRGB(196, 208, 222))
	rain.Size = NumberSequence.new(0.08)
	rain.Transparency = NumberSequence.new(0.4)
	rain.Lifetime = NumberRange.new(0.6, 0.9)
	rain.Speed = NumberRange.new(60, 75)
	rain.SpreadAngle = Vector2.new(3, 3)
	rain.Orientation = Enum.ParticleOrientation.VelocityParallel
	rain.Squash = NumberSequence.new(2.5) -- positive squash stretches along the velocity: streaks
	rain.Acceleration = RAIN_GRAVITY

	box.Parent = workspace
end

local function blendedLightning(): number
	local ws = worldState
	if not ws then
		return 0
	end
	local fromState = WeatherDefs.States[ws:GetAttribute("WeatherFrom") or ""]
	local toState = WeatherDefs.States[ws:GetAttribute("WeatherTo") or ""]
	if not fromState or not toState then
		return 0
	end
	return WeatherModel.blend(fromState.params, toState.params, number(ws, "WeatherBlend", 1)).lightning
end

local function flash()
	flashDuration = rng:NextNumber(0.12, 0.25)
	flashTime = flashDuration
	flashStrength = rng:NextNumber(2.5, 4)
	task.delay(rng:NextNumber(0.8, 4), function()
		AudioController.play("Thunder")
	end)
end

local function sample()
	worldState = worldState or ReplicatedStorage:FindFirstChild("WorldState")
	local ws = worldState
	if not ws then
		return
	end
	local fog = math.clamp(number(ws, "Fog", 0), 0, 1)
	local cloud = math.clamp(number(ws, "Cloud", 0), 0, 1)
	local precip = math.clamp(number(ws, "Precipitation", 0), 0, 1)
	local windMs = number(ws, "WindMs", 0)
	local windDirRaw = ws:GetAttribute("WindDirection")
	local windDir = if typeof(windDirRaw) == "Vector3" then windDirRaw else Vector3.zero
	local storm = math.clamp(cloud * 0.5 + precip * 0.5, 0, 1)

	-- Sky.
	atmosphere.Density = math.clamp(0.3 + fog * 0.55 + precip * fog * fog * 0.1, 0, 0.95)
	atmosphere.Haze = math.clamp(0.5 + cloud * 1.5 + fog * 2, 0, 10)
	atmosphere.Glare = (1 - cloud) * 0.4
	atmosphere.Color = ATMOS_CLEAR:Lerp(ATMOS_STORM, cloud)
	atmosphere.Decay = DECAY_CLEAR:Lerp(DECAY_STORM, cloud)
	baseBrightness = CLEAR_BRIGHTNESS + (STORM_BRIGHTNESS - CLEAR_BRIGHTNESS) * cloud
	if flashTime <= 0 then
		Lighting.Brightness = baseBrightness
	end
	Lighting.OutdoorAmbient = AMBIENT_CLEAR:Lerp(AMBIENT_STORM, storm)
	if clouds then
		local c = clouds :: any
		pcall(function()
			c.Cover = math.clamp(0.25 + cloud * 0.7, 0, 1)
			c.Density = math.clamp(0.3 + cloud * 0.5, 0, 1)
			c.Color = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(150, 154, 160), storm)
		end)
	end

	-- Precipitation.
	local tempC = player:GetAttribute("TempC")
	local isSnow = WeatherModel.isSnow(if typeof(tempC) == "number" then tempC else 10)
	local sheltered = player:GetAttribute("InShelter") == true
	local wind = windDir * windMs * WIND_ACCEL
	local falling = precip > 0.01 and not sheltered
	snow.Enabled = falling and isSnow
	rain.Enabled = falling and not isSnow
	snow.Rate = precip * SNOW_RATE
	rain.Rate = precip * RAIN_RATE
	snow.Acceleration = SNOW_GRAVITY + wind
	rain.Acceleration = RAIN_GRAVITY + wind
	if sheltered and not wasSheltered then
		-- Don't let already-falling particles drift through the roof.
		snow:Clear()
		rain:Clear()
	end
	wasSheltered = sheltered
	-- Shift the box upwind so wind-blown particles land around the camera, not downwind of it.
	local upwind = -windDir * math.min(windMs * 1.2, 25)
	boxOffset = Vector3.new(upwind.X, BOX_HEIGHT, upwind.Z)

	-- Lightning in heavy rain (it never strikes in snow).
	if precip > LIGHTNING_MIN_PRECIP and not isSnow and flashTime <= 0 then
		local perMinute = blendedLightning()
		if rng:NextNumber() < perMinute / 60 * SAMPLE_SECONDS then
			flash()
		end
	end
end

function WeatherController.Init()
	local existing = Lighting:FindFirstChildOfClass("Atmosphere")
	if existing then
		atmosphere = existing :: Atmosphere
	else
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Offset = 0.25
		atmosphere.Parent = Lighting
	end
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
	local accumulator = SAMPLE_SECONDS
	RunService.RenderStepped:Connect(function(dt)
		accumulator += dt
		if accumulator >= SAMPLE_SECONDS then
			accumulator = 0
			sample()
		end

		local camera = workspace.CurrentCamera
		if camera then
			box.Position = camera.CFrame.Position + boxOffset
		end

		if flashTime > 0 then
			flashTime -= dt
			if flashTime <= 0 then
				Lighting.Brightness = baseBrightness
			else
				-- Sharp attack, quick flicker, fast decay.
				local t = flashTime / flashDuration
				local flicker = if t > 0.45 and t < 0.6 then 0.35 else 1
				Lighting.Brightness = baseBrightness + flashStrength * t * flicker
			end
		end
	end)
end

return WeatherController
