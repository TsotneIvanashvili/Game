--!strict
-- Disasters for the slice: ROCKFALL. Dangerous, but always telegraphed:
--   T-5s  rumble + camera shake for nearby players, dust from the release point,
--         pebbles trickling down, "ROCKS ARE LOOSENING ABOVE YOU"
--   T+0   3-5 boulders released down the gully (server-owned physics, pooled parts)
--   T+10  boulders recycled; players in the zone who stayed up count it as survived
--
-- Zones are parts tagged "RockfallZone" (invisible boxes) with Attachments named "Release"
-- and a PushDirection attribute. Probability scales with the weather's disasterMult.
-- Architecture is ready for more disaster types (avalanche next): each is a trigger check
-- plus a telegraph -> event -> aftermath sequence.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)

local DisasterService = {}

local CHECK_SECONDS = 5
local BASE_CHANCE = 0.07 -- per check while someone is in the zone, at disasterMult 1
local COOLDOWN = 75
local WARNING_SECONDS = 5
local POOL_SIZE = 10
local HIT_SPEED = 18

type Zone = { part: BasePart, releases: { Vector3 }, push: Vector3, lastAt: number, active: boolean }

local zones: { Zone } = {}
local pool: { BasePart } = {}
local storage: Folder
local rng = Random.new()

local function inside(zone: Zone, pos: Vector3): boolean
	local p = zone.part.CFrame:PointToObjectSpace(pos)
	local h = zone.part.Size / 2
	return math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y and math.abs(p.Z) <= h.Z
end

local function playersNear(pos: Vector3, radius: number): { Player }
	local out = {}
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - pos).Magnitude <= radius then
			table.insert(out, player)
		end
	end
	return out
end

local hitCooldown: { [BasePart]: { [Player]: number } } = {}

local function onBoulderTouched(boulder: BasePart, other: BasePart)
	local character = other:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	local speed = boulder.AssemblyLinearVelocity.Magnitude
	if speed < HIT_SPEED then
		return
	end
	local perBoulder = hitCooldown[boulder]
	if not perBoulder then
		perBoulder = {}
		hitCooldown[boulder] = perBoulder
	end
	local now = os.clock()
	if perBoulder[player] and now - perBoulder[player] < 1.5 then
		return
	end
	perBoulder[player] = now
	local SurvivalService = Registry.get("SurvivalService")
	local damage = math.clamp(speed * 0.7, 12, 45) * (boulder.Size.X / 5)
	if rng:NextNumber() < 0.4 then
		SurvivalService.addInjury(player, "Bleeding")
	end
	if rng:NextNumber() < 0.25 then
		SurvivalService.addInjury(player, "HandInjury")
	end
	Registry.get("RemoteGuard").fire(player, "CameraShake", 1.2, 0.5)
	SurvivalService.changeHealth(player, -damage, "rockfall")
end

local function getBoulder(): BasePart
	local b = table.remove(pool)
	if b then
		return b
	end
	local part = Instance.new("Part")
	part.Name = "Boulder"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Slate
	part.Color = Color3.fromRGB(100, 96, 92)
	part.CanCollide = true
	part.CustomPhysicalProperties = PhysicalProperties.new(2.7, 0.6, 0.2) -- rock density
	part.Touched:Connect(function(other)
		onBoulderTouched(part, other)
	end)
	return part
end

local function recycle(part: BasePart)
	part.Anchored = true
	-- Out of the world. `storage` lives in Workspace, so pooled boulders parented there stayed
	-- visible and collidable where they stopped (an invisible-rockfall's worth of obstacles).
	part.Parent = nil
	hitCooldown[part] = nil
	if #pool < POOL_SIZE then
		table.insert(pool, part)
	else
		part:Destroy()
	end
end

local function trigger(zone: Zone)
	zone.active = true
	zone.lastAt = os.clock()
	local center = zone.releases[1] or zone.part.Position
	local nearby = playersNear(center, 140)
	local RemoteGuard = Registry.get("RemoteGuard")

	-- Telegraph.
	for _, player in nearby do
		RemoteGuard.notify(player, "ROCKS ARE LOOSENING ABOVE YOU", "danger")
		RemoteGuard.fire(player, "CameraShake", 0.35, WARNING_SECONDS)
		RemoteGuard.fire(player, "PlaySound", "Rumble", center)
	end
	local emitters = {}
	for _, pos in zone.releases do
		local dust = Instance.new("Part")
		dust.Anchored = true
		dust.CanCollide = false
		dust.CanQuery = false
		dust.Transparency = 1
		dust.Size = Vector3.new(1, 1, 1)
		dust.Position = pos
		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(Color3.fromRGB(150, 140, 125))
		emitter.Size = NumberSequence.new(3, 8)
		emitter.Transparency = NumberSequence.new(0.5, 1)
		emitter.Lifetime = NumberRange.new(2, 3)
		emitter.Rate = 18
		emitter.Speed = NumberRange.new(2, 5)
		emitter.SpreadAngle = Vector2.new(60, 60)
		emitter.Acceleration = Vector3.new(0, -4, 0)
		emitter.Parent = dust
		dust.Parent = storage
		table.insert(emitters, dust)
	end
	-- Pebbles first: small, harmless, the real warning sign.
	for _ = 1, 6 do
		local pos = zone.releases[rng:NextInteger(1, #zone.releases)]
		local pebble = Instance.new("Part")
		pebble.Shape = Enum.PartType.Ball
		pebble.Size = Vector3.one * rng:NextNumber(0.4, 0.9)
		pebble.Material = Enum.Material.Slate
		pebble.Color = Color3.fromRGB(110, 105, 100)
		pebble.Position = pos + Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-3, 3))
		pebble.AssemblyLinearVelocity = zone.push * 10
		pebble.Parent = storage
		task.delay(8, function()
			pebble:Destroy()
		end)
	end

	task.delay(WARNING_SECONDS, function()
		local boulders = {}
		for i = 1, rng:NextInteger(3, 5) do
			local pos = zone.releases[(i - 1) % #zone.releases + 1]
			local b = getBoulder()
			b.Size = Vector3.one * rng:NextNumber(3.5, 6)
			b.Anchored = false
			b.CFrame = CFrame.new(pos + Vector3.new(rng:NextNumber(-2, 2), rng:NextNumber(0, 3), rng:NextNumber(-4, 4)))
			b.Parent = workspace
			b:SetNetworkOwner(nil) -- server-authoritative physics: clients can't steer boulders
			b.AssemblyLinearVelocity = zone.push * rng:NextNumber(22, 32) + Vector3.new(0, -5, rng:NextNumber(-4, 4))
			b.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-5, 5), 0, rng:NextNumber(-5, 5))
			table.insert(boulders, b)
		end
		for _, d in emitters do
			local e = d:FindFirstChildOfClass("ParticleEmitter")
			if e then
				e.Rate = 6
			end
		end
		task.delay(10, function()
			for _, b in boulders do
				recycle(b)
			end
			for _, d in emitters do
				d:Destroy()
			end
			for _, player in nearby do
				local record = PlayerStore.get(player)
				if record and not record.downed and player.Parent then
					record.stats.disastersSurvived += 1
				end
			end
			zone.active = false
		end)
	end)
end

function DisasterService.Init()
	storage = Instance.new("Folder")
	storage.Name = "DisasterEffects"
	storage.Parent = workspace
end

function DisasterService.Start()
	local function addZone(inst: Instance)
		if not inst:IsA("BasePart") then
			return
		end
		local releases = {}
		for _, child in inst:GetChildren() do
			if child:IsA("Attachment") and child.Name == "Release" then
				table.insert(releases, child.WorldPosition)
			end
		end
		local push = inst:GetAttribute("PushDirection")
		table.insert(zones, {
			part = inst,
			releases = releases,
			push = if typeof(push) == "Vector3" then push.Unit else Vector3.new(-1, 0, 0),
			lastAt = -math.huge,
			active = false,
		})
	end
	for _, inst in CollectionService:GetTagged("RockfallZone") do
		addZone(inst)
	end
	CollectionService:GetInstanceAddedSignal("RockfallZone"):Connect(addZone)

	task.spawn(function()
		while true do
			task.wait(CHECK_SECONDS)
			local mult = Registry.get("WeatherService").params().disasterMult
			for _, zone in zones do
				if not zone.active and #zone.releases > 0 and os.clock() - zone.lastAt > COOLDOWN then
					local occupied = false
					for _, player in Players:GetPlayers() do
						local root = player.Character
							and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
						if root and inside(zone, root.Position) then
							occupied = true
							break
						end
					end
					if occupied and rng:NextNumber() < BASE_CHANCE * mult then
						trigger(zone)
					end
				end
			end
		end
	end)
end

-- Test hook (Studio command bar): require(...).forceRockfall()
function DisasterService.forceRockfall()
	if zones[1] and #zones[1].releases > 0 and not zones[1].active then
		trigger(zones[1])
	end
end

return DisasterService
