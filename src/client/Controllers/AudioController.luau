--!strict
-- All game audio. Looped ambience (wind, rain/blizzard, fire) and body sounds (breathing,
-- heartbeat, shivering) fade with the weather in ReplicatedStorage.WorldState and the
-- Player attributes the server publishes; one-shots arrive through the PlaySound event
-- (key, optional world position) or from other controllers via AudioController.play.
--
-- Ids live in AudioConfig and are all "" until audio art supplies them. Any key with an
-- empty id is skipped entirely, so no Sound objects exist for it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local WeatherModel = require(Shared.Logic.WeatherModel)
local AudioConfig = require(script.Parent.Parent.AudioConfig)

local AudioController = {}

local player = Players.LocalPlayer

local UPDATE_SECONDS = 0.25
local FADE = 0.35 -- fraction of the gap closed per update
local LOOP_KEYS = { "Wind", "Rain", "Blizzard", "FireCrackle", "HeavyBreathing", "Heartbeat", "Shivering" }
local SNOW_FLOORS: { [Enum.Material]: boolean } = {
	[Enum.Material.Snow] = true,
	[Enum.Material.Glacier] = true,
	[Enum.Material.Ice] = true,
}
local ROCK_FLOORS: { [Enum.Material]: boolean } = {
	[Enum.Material.Rock] = true,
	[Enum.Material.Slate] = true,
	[Enum.Material.Basalt] = true,
	[Enum.Material.Granite] = true,
	[Enum.Material.Concrete] = true,
	[Enum.Material.Cobblestone] = true,
	[Enum.Material.Pavement] = true,
}

local folder: Folder
local loops: { [string]: Sound } = {}
local loopVolume: { [string]: number } = {}
local oneShots: { [string]: Sound } = {}
local worldState: Instance? = nil
local rng = Random.new()

local function idFor(key: string): string
	return AudioConfig.Sounds[key] or ""
end

local function baseVolume(key: string): number
	return AudioConfig.Volume[key] or 0.5
end

-- Plays a one-shot. With a position the sound is 3D (on a temporary invisible part);
-- without it the sound is 2D. Keys without an asset id are ignored.
function AudioController.play(key: string, position: Vector3?)
	local id = idFor(key)
	if id == "" then
		return
	end
	if position then
		local anchor = Instance.new("Part")
		anchor.Name = "Sound_" .. key
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Size = Vector3.one
		anchor.Position = position
		local sound = Instance.new("Sound")
		sound.SoundId = id
		sound.Volume = baseVolume(key)
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = 20
		sound.RollOffMaxDistance = 600
		sound.Parent = anchor
		anchor.Parent = folder
		sound.Ended:Connect(function()
			anchor:Destroy()
		end)
		sound:Play()
		task.delay(30, function()
			if anchor.Parent then
				anchor:Destroy()
			end
		end)
		return
	end
	local sound = oneShots[key]
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = key
		sound.SoundId = id
		sound.Volume = baseVolume(key)
		sound.Parent = folder
		oneShots[key] = sound
	end
	sound.PlaybackSpeed = rng:NextNumber(0.92, 1.08)
	sound:Play()
end

local function setLoop(key: string, intensity: number)
	local sound = loops[key]
	if not sound then
		return
	end
	local current = loopVolume[key] or 0
	current += (math.clamp(intensity, 0, 1) - current) * FADE
	if current < 0.005 then
		current = 0
	end
	loopVolume[key] = current
	sound.Volume = current * baseVolume(key)
	local shouldPlay = current > 0
	if shouldPlay and not sound.IsPlaying then
		sound:Play()
	elseif not shouldPlay and sound.IsPlaying then
		sound:Stop()
	end
end

local function attr(name: string, default: any): any
	local v = player:GetAttribute(name)
	if v == nil then
		return default
	end
	return v
end

local function updateLoops()
	worldState = worldState or ReplicatedStorage:FindFirstChild("WorldState")
	local windMs, precip = 0, 0
	if worldState then
		windMs = worldState:GetAttribute("WindMs") or 0
		precip = worldState:GetAttribute("Precipitation") or 0
	end
	local tempC = attr("TempC", 10)
	local shelter = if attr("InShelter", false) then 0.4 else 1
	local snow = WeatherModel.isSnow(tempC)

	setLoop("Wind", math.clamp(windMs / 20, 0, 1) * shelter)
	setLoop("Rain", if snow then 0 else precip * shelter)
	setLoop("Blizzard", if snow then precip * math.clamp(0.4 + windMs / 25, 0, 1) * shelter else 0)
	setLoop("FireCrackle", if attr("NearFire", false) then 1 else 0)

	local exertion = attr("Exertion", "idle")
	local breathing = if exertion == "sprint" or exertion == "climb" then 1 else 0
	if attr("Oxygen", 100) < 70 then
		breathing = math.max(breathing, 0.6)
	end
	setLoop("HeavyBreathing", breathing)

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local hurt = humanoid ~= nil and humanoid.MaxHealth > 0 and humanoid.Health / humanoid.MaxHealth < 0.3
	setLoop("Heartbeat", if attr("Downed", false) or hurt then 1 else 0)

	local cold = attr("ColdLevel", "None")
	setLoop("Shivering", if cold == "Critical" then 1 elseif cold == "Severe" then 0.7 else 0)
end

function AudioController.Init()
	folder = Instance.new("Folder")
	folder.Name = "GameAudio"
	folder.Parent = SoundService
	for _, key in LOOP_KEYS do
		local id = idFor(key)
		if id ~= "" then
			local sound = Instance.new("Sound")
			sound.Name = key
			sound.SoundId = id
			sound.Looped = true
			sound.Volume = 0
			sound.Parent = folder
			loops[key] = sound
		end
	end
end

function AudioController.Start()
	local playSound = Remotes.get("PlaySound") :: RemoteEvent
	playSound.OnClientEvent:Connect(function(key: string, position: Vector3?)
		if typeof(key) ~= "string" then
			return
		end
		AudioController.play(key, if typeof(position) == "Vector3" then position else nil)
	end)

	local updateTimer = 0
	local stepTimer = 0
	RunService.Heartbeat:Connect(function(dt)
		updateTimer += dt
		if updateTimer >= UPDATE_SECONDS then
			updateTimer = 0
			updateLoops()
		end

		-- Footsteps on snow/rock (local player only; teammates' steps would need replication).
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.MoveDirection.Magnitude < 0.1 or attr("Climbing", false) then
			stepTimer = 0
			return
		end
		stepTimer += dt
		local interval = if attr("Exertion", "") == "sprint" then 0.3 else 0.42
		if stepTimer >= interval then
			stepTimer = 0
			local floor = humanoid.FloorMaterial
			if SNOW_FLOORS[floor] then
				AudioController.play("SnowStep")
			elseif ROCK_FLOORS[floor] then
				AudioController.play("RockStep")
			end
		end
	end)
end

return AudioController
