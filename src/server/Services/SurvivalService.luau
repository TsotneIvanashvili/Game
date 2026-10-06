--!strict
-- The survival heartbeat. ONE loop at SURVIVAL_TICK_SECONDS updates every player:
--   sample environment (weather, zone, fire, shelter, water) -> SurvivalModel.step
--   -> apply health / movement / jump rules -> fall damage -> publish attributes.
-- Clients only ever see the results (Player attributes); they can't write any of it.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local SurvivalConfig = require(Shared.Config.SurvivalConfig)
local InjuryDefs = require(Shared.Config.InjuryDefs)
local ZoneDefs = require(Shared.Config.ZoneDefs)
local WorldLayout = require(Shared.Config.WorldLayout)
local SurvivalModel = require(Shared.Logic.SurvivalModel)
local WarmthModel = require(Shared.Logic.WarmthModel)
local InjuryModel = require(Shared.Logic.InjuryModel)
local WeatherModel = require(Shared.Logic.WeatherModel)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)

local SurvivalService = {}

local gearCache: { [Player]: WarmthModel.Gear } = {}
local characterList: { Instance } = {}
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = false

local COLD_WARNINGS = {
	Mild = nil,
	Moderate = "You're getting cold.",
	Severe = "YOU ARE FREEZING. Find a fire or shelter.",
	Critical = "HYPOTHERMIA. You will pass out soon.",
}

local REGION_WARNINGS = {
	Hands = "YOUR HANDS ARE LOSING SENSITIVITY",
	Feet = "You can't feel your toes.",
	Head = "Your face is going numb.",
}

local function remote()
	return Registry.get("RemoteGuard")
end

-- Attribute publishing: only write when the value moved by at least `step`, so idle
-- players cost zero network traffic.
local function publish(player: Player, name: string, value: any, step: number?)
	local old = player:GetAttribute(name)
	if typeof(value) == "number" and typeof(old) == "number" and step then
		if math.abs(old - value) < step then
			return
		end
		value = math.floor(value / step + 0.5) * step
	end
	if old ~= value then
		player:SetAttribute(name, value)
	end
end

local function refreshCharacterFilter()
	table.clear(characterList)
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(characterList, p.Character)
		end
	end
	for _, model in CollectionService:GetTagged("IgnoreGroundRaycast") do
		table.insert(characterList, model)
	end
	raycastParams.FilterDescendantsInstances = characterList
end
SurvivalService.refreshCharacterFilter = refreshCharacterFilter

function SurvivalService.groundRaycastParams(): RaycastParams
	return raycastParams
end

function SurvivalService.refreshGear(player: Player)
	local record = PlayerStore.get(player)
	if not record then
		return
	end
	gearCache[player] = WarmthModel.computeGear(Registry.get("InventoryService").wornItems(record))
end

function SurvivalService.gloveMobility(record: PlayerStore.Record): number
	local mobility = 1
	for _, def in Registry.get("InventoryService").wornItems(record) do
		if def.clothing then
			mobility *= def.clothing.mobility
		end
	end
	return mobility
end

-- Every source of damage and healing goes through here, so a player at 0 HP is DOWNED,
-- never killed outright. Death only happens if a rescue never comes (see RescueService).
function SurvivalService.changeHealth(player: Player, delta: number, cause: string?)
	local record, _, humanoid = PlayerStore.getActive(player)
	if not record or not humanoid then
		return
	end
	if record.downed then
		if delta < 0 then
			record.bleedOut = math.max(0, record.bleedOut + delta * 0.25) -- damage while down speeds bleed-out
		end
		return
	end
	local newHealth = humanoid.Health + delta
	if newHealth <= 0 then
		humanoid.Health = 1
		Registry.get("RescueService").down(player, cause or "injuries")
	else
		humanoid.Health = math.min(newHealth, humanoid.MaxHealth)
	end
end

function SurvivalService.addInjury(player: Player, injuryId: string)
	local record = PlayerStore.get(player)
	if not record then
		return
	end
	if InjuryModel.add(record.survival.injuries, injuryId) then
		record.stats.injuries += 1
		remote().notify(
			player,
			InjuryDefs.ById[injuryId].name .. ": " .. InjuryDefs.ById[injuryId].description,
			"danger"
		)
	end
end

local function isGrounded(root: BasePart, humanoid: Humanoid): boolean
	local length = humanoid.HipHeight + root.Size.Y / 2 + 1.5
	local result = workspace:Raycast(root.Position, Vector3.new(0, -length, 0), raycastParams)
	return result ~= nil
end

local function inWater(position: Vector3): boolean
	for _, volume in CollectionService:GetTagged("WaterVolume") do
		if volume:IsA("BasePart") then
			local localPos = volume.CFrame:PointToObjectSpace(position - Vector3.new(0, 2.5, 0))
			local half = volume.Size / 2
			if math.abs(localPos.X) <= half.X and math.abs(localPos.Y) <= half.Y and math.abs(localPos.Z) <= half.Z then
				return true
			end
		end
	end
	return false
end

local function applyFall(player: Player, record: PlayerStore.Record, drop: number)
	if drop <= GameConfig.FALL_SAFE_STUDS then
		return
	end
	if drop >= GameConfig.FALL_DOWNED_STUDS then
		SurvivalService.addInjury(player, "BrokenLeg")
		SurvivalService.changeHealth(player, -1000, "a long fall")
		return
	end
	local damage = (drop - GameConfig.FALL_SAFE_STUDS) * GameConfig.FALL_DAMAGE_PER_STUD
	if drop >= GameConfig.FALL_BREAK_STUDS then
		SurvivalService.addInjury(player, if math.random() < 0.6 then "BrokenLeg" else "SprainedAnkle")
	elseif drop >= GameConfig.FALL_SPRAIN_STUDS and math.random() < 0.5 then
		SurvivalService.addInjury(player, "SprainedAnkle")
	end
	remote().fire(player, "CameraShake", math.clamp(drop / 40, 0.3, 1.5), 0.4)
	SurvivalService.changeHealth(player, -damage, "a fall")
	record.survival.stamina = math.max(0, record.survival.stamina - 15)
end

local function determineExertion(
	record: PlayerStore.Record,
	horizontalSpeed: number,
	mods: SurvivalModel.Modifiers
): string
	if record.downed or record.carriedBy then
		return "idle"
	end
	if record.climbing then
		return "climb"
	end
	if record.carrying then
		return "carry"
	end
	if record.resting then
		return "rest"
	end
	local moving = horizontalSpeed > 2
	if
		moving
		and record.sprintRequested
		and mods.canSprint
		and record.survival.stamina > SurvivalConfig.Stamina.MinToSprint
	then
		return "sprint"
	end
	return if moving then "walk" else "idle"
end

local function tickPlayer(
	player: Player,
	record: PlayerStore.Record,
	_character: Model,
	humanoid: Humanoid,
	root: BasePart,
	dt: number
)
	local pos = root.Position
	local velocity = root.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

	-- Resting ends when you walk away.
	if record.resting and horizontalSpeed > 3 then
		SurvivalService.setResting(player, false)
	end

	-- Environment.
	local zone = ZoneDefs.at(pos.Y)
	local elevationM = WeatherModel.elevationM(pos.Y)
	local weather = Registry.get("WeatherService").sampleAt(pos)
	local site = Registry.get("BuildingService").environmentAt(pos)
	local wet = inWater(pos)
	local env: WarmthModel.Environment = {
		airTempC = weather.airTempC,
		windMs = weather.windMs * zone.windExposure * site.windFactor,
		precipitation = if site.precipBlocked then 0 else weather.precipitation,
		isSnow = weather.isSnow,
		inWater = wet,
		fireHeatC = site.fireHeatC,
		exertion = "idle",
	}

	local gear = gearCache[player]
	if not gear then
		SurvivalService.refreshGear(player)
		gear = gearCache[player]
	end

	local weightRatio = Registry.get("InventoryService").weightRatio(record)
	local preMods = SurvivalModel.modifiers(record.survival, weightRatio)
	local exertion = determineExertion(record, horizontalSpeed, preMods)
	record.exertion = exertion
	env.exertion = exertion

	local campResting = record.resting and Registry.get("CampService").isInCamp(pos)
	record.restingAtCamp = campResting

	local events, healthDelta = SurvivalModel.step(record.survival, {
		exertion = exertion,
		elevationM = elevationM,
		env = env,
		gear = gear,
		weightRatio = weightRatio,
		campResting = campResting,
	}, dt)

	-- Events -> feedback.
	for _, event in events do
		if event == "StaminaDepleted" then
			remote().notify(player, "You're out of breath.", "warn", "stamina", 15)
			if record.climbing then
				Registry.get("ClimbingService").forceStop(player, "Your grip fails!")
			end
		elseif event == "Unconscious" then
			Registry.get("RescueService").down(player, "hypothermia")
		elseif event:sub(1, 7) == "Injury:" then
			local id = event:sub(8)
			record.stats.injuries += 1
			remote().notify(player, InjuryDefs.ById[id].name .. ": " .. InjuryDefs.ById[id].description, "danger")
		elseif event:sub(1, 7) == "Healed:" then
			local def = InjuryDefs.ById[event:sub(8)]
			if def then
				remote().notify(player, def.name .. " has healed.", "good")
			end
		elseif event:sub(1, 9) == "Warn:Cold" then
			local region = event:sub(10)
			remote().notify(player, REGION_WARNINGS[region] or "You're freezing.", "danger", "cold" .. region, 30)
		end
	end

	local mods = SurvivalModel.modifiers(record.survival, weightRatio)
	local warning = COLD_WARNINGS[mods.coldLevel]
	if warning and not site.precipBlocked and site.fireHeatC <= 0 then
		remote().notify(
			player,
			warning,
			if mods.coldLevel == "Moderate" then "warn" else "danger",
			"coldLevel" .. mods.coldLevel,
			45
		)
	end
	if record.survival.thirst < SurvivalConfig.Thirst.LowThreshold then
		remote().notify(player, "You're very thirsty.", "warn", "thirst", 60)
	end
	if record.survival.hunger < SurvivalConfig.Hunger.LowThreshold then
		remote().notify(player, "You're hungry. Your strength is fading.", "warn", "hunger", 60)
	end
	if record.survival.oxygen < 80 then
		remote().notify(player, "LOW OXYGEN. Pace yourself.", "warn", "oxygen", 60)
	end
	if weightRatio > 1 then
		remote().notify(player, "Your pack is overloaded. You're slow and tire fast.", "warn", "overweight", 45)
	end

	if healthDelta ~= 0 then
		SurvivalService.changeHealth(player, healthDelta, "the cold")
	elseif
		not record.downed
		and humanoid.Health < humanoid.MaxHealth
		and record.survival.hunger > 50
		and record.survival.thirst > 50
	then
		-- Slow natural recovery when fed, watered and not bleeding.
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 0.15 * dt * (if record.resting then 4 else 1))
	end

	-- Movement rules.
	if record.downed then
		humanoid.WalkSpeed = if record.carriedBy then 0 else GameConfig.CRAWL_SPEED
		humanoid.JumpHeight = 0
	elseif record.carriedBy then
		humanoid.WalkSpeed = 0
		humanoid.JumpHeight = 0
	else
		local base = if exertion == "sprint" then GameConfig.SPRINT_SPEED else GameConfig.WALK_SPEED
		local speed = base * mods.moveMult
		if record.carrying then
			speed *= GameConfig.CARRY_SPEED_MULTIPLIER
		end
		if record.resting then
			speed = GameConfig.WALK_SPEED * mods.moveMult -- allow standing up and walking away
		end
		if math.abs(humanoid.WalkSpeed - speed) > 0.05 then
			humanoid.WalkSpeed = speed
		end
		local canJump = record.survival.stamina >= SurvivalConfig.Stamina.JumpCost
			and not record.carrying
			and not InjuryModel.has(record.survival.injuries, "BrokenLeg")
		local jump = if canJump then GameConfig.JUMP_HEIGHT else 0
		if humanoid.JumpHeight ~= jump then
			humanoid.JumpHeight = jump
		end
	end

	-- Climbing upkeep (wall still there, stamina, speed sanity).
	if record.climbing then
		Registry.get("ClimbingService").tick(player, record, root, dt)
	end

	-- Fall tracking.
	if record.climbing or record.carriedBy then
		record.peakY = nil
	else
		local grounded = isGrounded(root, humanoid)
		if grounded then
			if record.peakY then
				local drop = record.peakY - pos.Y
				record.peakY = nil
				applyFall(player, record, drop)
			end
		else
			record.peakY = math.max(record.peakY or pos.Y, pos.Y)
		end
	end

	-- Safety net: fell off the world.
	if pos.Y < WorldLayout.SafetyNetY then
		record.lostSince = record.lostSince or os.clock()
		if os.clock() - (record.lostSince :: number) > 3 then
			record.lostSince = nil
			Registry.get("CampService").recoverToCheckpoint(player, "You were recovered from the ravine, exhausted.")
			record.survival.fatigue = math.min(100, record.survival.fatigue + 20)
		end
	else
		record.lostSince = nil
	end

	-- Expedition stats.
	if record.lastPosition then
		local step = Vector3.new(pos.X - record.lastPosition.X, 0, pos.Z - record.lastPosition.Z).Magnitude
		if step < 40 then -- ignore teleports
			record.stats.distanceStuds += step
		end
	end
	record.lastPosition = pos
	record.stats.maxElevationM = math.max(record.stats.maxElevationM, elevationM)
	if weather.severe and site.windFactor > 0.5 and not record.downed then
		record.stats.weatherSurvived[weather.name] = true
	end

	-- Publish.
	local s = record.survival
	publish(player, "Stamina", s.stamina, 0.5)
	publish(player, "MaxStamina", mods.maxStamina, 0.5)
	publish(player, "Hunger", s.hunger, 0.5)
	publish(player, "Thirst", s.thirst, 0.5)
	publish(player, "Fatigue", s.fatigue, 0.5)
	publish(player, "Oxygen", s.oxygen, 0.5)
	publish(player, "AltitudeSickness", s.altitudeSickness, 1)
	publish(player, "Warmth", SurvivalModel.overallWarmth(s), 0.5)
	for _, region in WarmthModel.Regions do
		publish(player, "Warm" .. region, s.warmth[region], 1)
	end
	publish(player, "Wetness", s.wetness, 0.02)
	publish(player, "ColdLevel", mods.coldLevel)
	publish(player, "Exertion", exertion)
	publish(player, "Injuries", InjuryModel.serialize(s.injuries))
	publish(player, "Zone", zone.name)
	publish(player, "ElevationM", elevationM, 5)
	publish(player, "TempC", env.airTempC, 0.5)
	publish(player, "WindMs", env.windMs, 0.5)
	publish(player, "Weather", weather.name)
	publish(player, "InShelter", site.precipBlocked or site.windFactor < 0.5)
	publish(player, "NearFire", site.fireHeatC > 0)
	publish(player, "CanSprint", mods.canSprint)
	publish(player, "CanClimb", mods.canClimb and not record.carrying and not record.downed and not record.carriedBy)
	publish(
		player,
		"ClimbSpeed",
		GameConfig.CLIMB_SPEED * mods.climbSpeedMult * SurvivalService.gloveMobility(record),
		0.1
	)
	publish(player, "Resting", record.resting)
end

function SurvivalService.setResting(player: Player, resting: boolean)
	local record, _, humanoid = PlayerStore.getActive(player)
	if not record or not humanoid then
		return
	end
	if resting and (record.downed or record.carrying or record.carriedBy or record.climbing) then
		return
	end
	record.resting = resting
	humanoid.Sit = resting
	player:SetAttribute("Resting", resting)
end

function SurvivalService.Init()
	local RemoteGuard = Registry.get("RemoteGuard")
	RemoteGuard.on("SetSprint", function(player, on: boolean)
		local record = PlayerStore.get(player)
		if record then
			record.sprintRequested = on
		end
	end)
	RemoteGuard.on("ReportJump", function(player)
		local record = PlayerStore.getActive(player)
		if not record or record.downed or record.climbing then
			return
		end
		local s = record.survival
		s.stamina = math.max(0, s.stamina - SurvivalConfig.Stamina.JumpCost)
		s.staminaCooldown = SurvivalConfig.Stamina.RegenDelay
	end)
	RemoteGuard.on("StopRest", function(player)
		SurvivalService.setResting(player, false)
	end)
end

function SurvivalService.Start()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			task.defer(refreshCharacterFilter)
		end)
		player.CharacterRemoving:Connect(function()
			task.defer(refreshCharacterFilter)
		end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function()
			task.defer(refreshCharacterFilter)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		gearCache[player] = nil
		task.defer(refreshCharacterFilter)
	end)
	refreshCharacterFilter()

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < GameConfig.SURVIVAL_TICK_SECONDS then
			return
		end
		local step = math.min(accumulator, 1) -- never simulate a huge step after a hitch
		accumulator = 0
		for player in PlayerStore.all() do
			local record, character, humanoid, root = PlayerStore.getActive(player)
			if record and character and humanoid and root then
				local ok, err = pcall(tickPlayer, player, record, character, humanoid, root, step)
				if not ok then
					warn("[SurvivalService] tick error for " .. player.Name .. ": " .. tostring(err))
				end
			end
		end
	end)
end

return SurvivalService
