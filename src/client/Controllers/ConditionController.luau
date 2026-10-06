--!strict
-- How the body feels, shown rather than told:
--   * breath vapor puffs from every character's mouth when their air is cold (TempC < 4),
--     faster while sprinting or climbing (all players, so you can read a teammate's state)
--   * local screen grading: colder = bluer and greyer, thin air = blur, downed = red,
--     near a fire = warm orange
--   * an edge vignette (gradient frames, no texture) that grows stronger and bluer as
--     ColdLevel worsens, glows faint orange by a fire and goes dark red when downed
--   * a subtle shiver at Severe/Critical cold
--   * the server's CameraShake event (falls, avalanches), capped so it never gets nauseating
--
-- Camera offsets are applied after the default camera (RenderPriority.Camera + 1) and removed
-- again before it runs next frame (Camera - 1), so the default camera scripts, which read
-- the current camera CFrame, never accumulate our rotation as drift.
--
-- ART: BreathVapor keeps the default ParticleEmitter texture; art should supply a soft puff.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local ConditionController = {}

local player = Players.LocalPlayer

local BREATH_MAX_TEMP_C = 4
local BREATH_RATE_CALM = 2.5
local BREATH_RATE_HARD = 7
local BREATH_OFFSET = Vector3.new(0, -0.15, -0.6) -- front of the head (Head looks down -Z)
local MAX_SHAKE_RAD = math.rad(1.5)
local SHIVER_RAD = { Severe = math.rad(0.15), Critical = math.rad(0.3) }

type Grade = { saturation: number, contrast: number, brightness: number, tint: Color3, blur: number }

local COLD_GRADE: { [string]: { saturation: number, tint: Color3 } } = {
	Moderate = { saturation = -0.12, tint = Color3.fromRGB(236, 243, 255) },
	Severe = { saturation = -0.28, tint = Color3.fromRGB(216, 229, 255) },
	Critical = { saturation = -0.5, tint = Color3.fromRGB(196, 214, 255) },
}
local WHITE = Color3.new(1, 1, 1)
local DOWNED_TINT = Color3.fromRGB(255, 196, 196)
local FIRE_TINT = Color3.fromRGB(255, 226, 196)
local FIRE_SATURATION = 0.06

-- Vignette strength (0..1 opacity at the very edge) and colour per cold level.
local COLD_VIGNETTE: { [string]: { strength: number, color: Color3 } } = {
	Mild = { strength = 0.12, color = Color3.fromRGB(200, 222, 245) },
	Moderate = { strength = 0.28, color = Color3.fromRGB(160, 200, 250) },
	Severe = { strength = 0.48, color = Color3.fromRGB(110, 165, 250) },
	Critical = { strength = 0.7, color = Color3.fromRGB(70, 125, 240) },
}
local FIRE_VIGNETTE = { strength = 0.16, color = Color3.fromRGB(255, 140, 50) }
local DOWNED_VIGNETTE = { strength = 0.6, color = Color3.fromRGB(110, 10, 10) }
local VIGNETTE_DEPTH = 0.32 -- fraction of the screen each edge band covers

local colorCorrection: ColorCorrectionEffect
local blur: BlurEffect
local current: Grade = { saturation = 0, contrast = 0, brightness = 0, tint = WHITE, blur = 0 }
local target: Grade = { saturation = 0, contrast = 0, brightness = 0, tint = WHITE, blur = 0 }

local vignetteGui: ScreenGui? = nil
local vignetteFrames: { Frame } = {}
local vignetteStrength = 0
local vignetteColor = WHITE
local targetVignetteStrength = 0
local targetVignetteColor = WHITE
local appliedVignetteStrength = -1
local appliedVignetteColor = WHITE

-- Camera shake state.
local shakeStart = 0
local shakeDuration = 0
local shakeIntensity = 0
local shiverAmplitude = 0
local appliedOffset = CFrame.identity
local seed = Random.new():NextNumber(0, 1000)

local function attr(name: string, default: any): any
	local v = player:GetAttribute(name)
	if v == nil then
		return default
	end
	return v
end

-- Breath vapor ---------------------------------------------------------------------------

local function ensureBreath(head: BasePart): ParticleEmitter
	local attachment = head:FindFirstChild("BreathAttachment") :: Attachment?
	if not attachment then
		local a = Instance.new("Attachment")
		a.Name = "BreathAttachment"
		a.Position = BREATH_OFFSET
		a.Parent = head
		attachment = a
	end
	local att = attachment :: Attachment
	local existing = att:FindFirstChild("BreathVapor") :: ParticleEmitter?
	if existing then
		return existing
	end
	local e = Instance.new("ParticleEmitter")
	e.Name = "BreathVapor"
	-- Texture left at the default; art must supply a soft vapor puff texture.
	e.Color = ColorSequence.new(WHITE)
	e.LightEmission = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(1, 0.55),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.5, 0.9)
	e.Speed = NumberRange.new(1.5, 2.5)
	e.SpreadAngle = Vector2.new(15, 15)
	e.Drag = 2
	e.EmissionDirection = Enum.NormalId.Front
	e.Acceleration = Vector3.new(0, 0.6, 0)
	e.LockedToPart = false
	e.Rate = BREATH_RATE_CALM
	e.Enabled = false
	e.Parent = att
	return e
end

local function updateBreath()
	for _, other in Players:GetPlayers() do
		local character = other.Character
		local head = character and character:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			local emitter = ensureBreath(head)
			local tempC = other:GetAttribute("TempC")
			local cold = typeof(tempC) == "number" and tempC < BREATH_MAX_TEMP_C
			local exertion = other:GetAttribute("Exertion")
			local hard = exertion == "sprint" or exertion == "climb"
			emitter.Enabled = cold and other:GetAttribute("Downed") ~= true
			emitter.Rate = if hard then BREATH_RATE_HARD else BREATH_RATE_CALM
		end
	end
end

-- Screen grading -------------------------------------------------------------------------

local function updateTarget()
	local level = attr("ColdLevel", "None")
	local cold = COLD_GRADE[level]
	target.saturation = if cold then cold.saturation else 0
	target.tint = if cold then cold.tint else WHITE
	target.contrast = 0
	target.brightness = 0

	local vignette = COLD_VIGNETTE[level]
	targetVignetteStrength = if vignette then vignette.strength else 0
	targetVignetteColor = if vignette then vignette.color else vignetteColor

	-- A fire's glow wins over the cold tint: you are warming up.
	if attr("NearFire", false) then
		target.tint = FIRE_TINT
		target.saturation = math.max(target.saturation * 0.4, FIRE_SATURATION)
		if targetVignetteStrength < FIRE_VIGNETTE.strength then
			targetVignetteStrength = FIRE_VIGNETTE.strength
			targetVignetteColor = FIRE_VIGNETTE.color
		end
	end

	local oxygen = attr("Oxygen", 100)
	local sickness = attr("AltitudeSickness", 0)
	local blurSize = 0
	if oxygen < 80 then
		blurSize = math.max(blurSize, (80 - oxygen) / 80 * 8)
	end
	if sickness > 40 then
		blurSize = math.max(blurSize, (sickness - 40) / 60 * 8)
	end

	if attr("Downed", false) then
		target.tint = DOWNED_TINT
		target.saturation = math.min(target.saturation, -0.3)
		target.contrast = 0.25
		target.brightness = -0.05
		blurSize = math.max(blurSize, 3)
		targetVignetteStrength = math.max(targetVignetteStrength, DOWNED_VIGNETTE.strength)
		targetVignetteColor = DOWNED_VIGNETTE.color
	end
	target.blur = math.clamp(blurSize, 0, 10)

	shiverAmplitude = SHIVER_RAD[level] or 0
end

local function approach(a: number, b: number, k: number): number
	return a + (b - a) * k
end

local function stepGrade(dt: number)
	local k = 1 - math.exp(-dt * 3)
	current.saturation = approach(current.saturation, target.saturation, k)
	current.contrast = approach(current.contrast, target.contrast, k)
	current.brightness = approach(current.brightness, target.brightness, k)
	current.blur = approach(current.blur, target.blur, k)
	if current.tint ~= target.tint then
		current.tint = current.tint:Lerp(target.tint, k)
	end
	colorCorrection.Saturation = current.saturation
	colorCorrection.Contrast = current.contrast
	colorCorrection.Brightness = current.brightness
	colorCorrection.TintColor = current.tint
	blur.Size = current.blur
	blur.Enabled = current.blur > 0.05

	-- Vignette: slower than the grade so it creeps in rather than pops.
	local kv = 1 - math.exp(-dt * 1.5)
	vignetteStrength = approach(vignetteStrength, targetVignetteStrength, kv)
	if vignetteColor ~= targetVignetteColor then
		vignetteColor = vignetteColor:Lerp(targetVignetteColor, kv)
	end
	local colorDrift = math.abs(vignetteColor.R - appliedVignetteColor.R)
		+ math.abs(vignetteColor.G - appliedVignetteColor.G)
		+ math.abs(vignetteColor.B - appliedVignetteColor.B)
	if math.abs(vignetteStrength - appliedVignetteStrength) > 0.002 or colorDrift > 0.004 then
		appliedVignetteStrength = vignetteStrength
		appliedVignetteColor = vignetteColor
		local gui = vignetteGui
		if gui then
			gui.Enabled = vignetteStrength > 0.005
		end
		for _, frame in vignetteFrames do
			frame.BackgroundTransparency = 1 - vignetteStrength
			frame.BackgroundColor3 = vignetteColor
		end
	end
end

-- Four edge bands whose UIGradient fades from opaque at the screen edge to clear inward;
-- the overlapping corners read darker, like a lens vignette. No texture needed.
local function buildVignette()
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "ConditionVignette"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 0 -- under every HUD screen (they use 1+)
	gui.Enabled = false
	local fade = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.35, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	-- The gradient's start (transparency 0) sits on the screen edge: rotation 0 starts at
	-- the left, 90 at the top, 180 at the right, -90 at the bottom.
	local side = VIGNETTE_DEPTH * 0.6 -- screens are wider than tall
	local bands: { { size: UDim2, position: UDim2, rotation: number } } = {
		{ size = UDim2.fromScale(1, VIGNETTE_DEPTH), position = UDim2.fromScale(0, 0), rotation = 90 },
		{
			size = UDim2.fromScale(1, VIGNETTE_DEPTH),
			position = UDim2.fromScale(0, 1 - VIGNETTE_DEPTH),
			rotation = -90,
		},
		{ size = UDim2.fromScale(side, 1), position = UDim2.fromScale(0, 0), rotation = 0 },
		{ size = UDim2.fromScale(side, 1), position = UDim2.fromScale(1 - side, 0), rotation = 180 },
	}
	for i, band in bands do
		local frame = Instance.new("Frame")
		frame.Name = "Edge" .. i
		frame.Size = band.size
		frame.Position = band.position
		frame.BorderSizePixel = 0
		frame.BackgroundColor3 = WHITE
		frame.BackgroundTransparency = 1
		frame.Active = false
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = band.rotation
		gradient.Transparency = fade
		gradient.Parent = frame
		frame.Parent = gui
		table.insert(vignetteFrames, frame)
	end
	gui.Parent = playerGui
	vignetteGui = gui
end

-- Camera shake ---------------------------------------------------------------------------

local function computeOffset(): CFrame
	local now = os.clock()
	local pitch, yaw, roll = 0, 0, 0
	local elapsed = now - shakeStart
	if elapsed < shakeDuration then
		local decay = 1 - elapsed / shakeDuration
		local amp = math.min(MAX_SHAKE_RAD, math.rad(shakeIntensity)) * decay * decay
		local f = now * 18
		-- math.noise is roughly within [-0.5, 0.5]; x2 brings it to the full amplitude.
		pitch += math.noise(f, seed) * amp * 2
		yaw += math.noise(seed, f) * amp * 2
		roll += math.noise(f, f, seed) * amp
	end
	if shiverAmplitude > 0 then
		local f = now * 9
		pitch += math.noise(f, seed + 50) * shiverAmplitude * 2
		yaw += math.noise(seed + 50, f) * shiverAmplitude * 2
	end
	pitch = math.clamp(pitch, -MAX_SHAKE_RAD, MAX_SHAKE_RAD)
	yaw = math.clamp(yaw, -MAX_SHAKE_RAD, MAX_SHAKE_RAD)
	roll = math.clamp(roll, -MAX_SHAKE_RAD, MAX_SHAKE_RAD)
	if pitch == 0 and yaw == 0 and roll == 0 then
		return CFrame.identity
	end
	return CFrame.Angles(pitch, yaw, roll)
end

function ConditionController.shake(intensity: number, duration: number)
	local now = os.clock()
	-- A stronger shake overrides; a weaker one never cuts a strong one short.
	local remaining = math.max(0, shakeDuration - (now - shakeStart))
	if remaining > 0 and intensity < shakeIntensity then
		return
	end
	shakeStart = now
	shakeDuration = math.clamp(duration, 0.05, 5)
	shakeIntensity = math.clamp(intensity, 0, 1.5)
end

function ConditionController.Init()
	colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "ConditionGrade"
	colorCorrection.Parent = Lighting
	blur = Instance.new("BlurEffect")
	blur.Name = "ConditionBlur"
	blur.Size = 0
	blur.Enabled = false
	blur.Parent = Lighting
	task.spawn(buildVignette)
end

function ConditionController.Start()
	local cameraShake = Remotes.get("CameraShake") :: RemoteEvent
	cameraShake.OnClientEvent:Connect(function(intensity: number, duration: number)
		if typeof(intensity) == "number" and typeof(duration) == "number" then
			ConditionController.shake(intensity, duration)
		end
	end)

	task.spawn(function()
		while true do
			updateBreath()
			task.wait(0.5)
		end
	end)

	local targetTimer = 0
	RunService.Heartbeat:Connect(function(dt)
		targetTimer += dt
		if targetTimer >= 0.2 then
			targetTimer = 0
			updateTarget()
		end
		stepGrade(dt)
	end)

	-- Undo last frame's offset before the default camera updates, then re-apply after it.
	RunService:BindToRenderStep("ConditionCameraUndo", Enum.RenderPriority.Camera.Value - 1, function()
		if appliedOffset ~= CFrame.identity then
			local camera = workspace.CurrentCamera
			if camera then
				camera.CFrame *= appliedOffset:Inverse()
			end
			appliedOffset = CFrame.identity
		end
	end)
	RunService:BindToRenderStep("ConditionCameraShake", Enum.RenderPriority.Camera.Value + 1, function()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local offset = computeOffset()
		if offset ~= CFrame.identity then
			camera.CFrame *= offset
		end
		appliedOffset = offset
	end)
end

return ConditionController
