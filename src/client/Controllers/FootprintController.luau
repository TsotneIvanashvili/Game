--!strict
-- Footprints in the snow behind every character (ART_DIRECTION 10). Client-only and purely
-- cosmetic: nothing here replicates or affects gameplay.
--
-- Every character walking on Snow or Glacier drops alternating left/right prints about every
-- STRIDE studs. Each print is a small flat dark translucent part laid on the surface found by
-- a short raycast down from the foot, turned to face the direction of travel. Prints come from
-- a fixed ring-buffer pool (POOL_SIZE parts built once in Init), so the oldest print is reused
-- when the pool runs out and no Instance is ever created while playing. Prints hold, then fade
-- out over LIFETIME seconds (shorter while it snows hard: fresh snow covers them).
--
-- Remote characters: Humanoid.FloorMaterial is computed by the owning client and may read Air
-- for other players' humanoids here, so for them the raycast alone decides whether the feet
-- are on snow.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FootprintController = {}

local localPlayer = Players.LocalPlayer

local POOL_SIZE = 200
local STRIDE = 2.2 -- studs between prints
local FOOT_SPACING = 0.45 -- studs either side of the root's centre line
local SAMPLE_SECONDS = 1 / 20
local FADE_SECONDS = 0.1
local LIFETIME = 20
local HOLD_FRACTION = 0.3 -- of the lifetime spent at full strength before fading
local START_TRANSPARENCY = 0.55
local MIN_MOVE = 0.05 -- studs per sample below which a character counts as standing still
local TELEPORT = 12 -- studs per sample above which we assume a teleport and reset
local MAX_CAMERA_DISTANCE = 300
local GROUND_SLACK = 1.2 -- studs of tolerance between hip height and the ground hit
local PRINT_SIZE = Vector3.new(0.55, 0.05, 0.95)
local PRINT_COLOR = Color3.fromRGB(112, 122, 138)
local PARK = CFrame.new(0, -5000, 0)

local SNOW: { [Enum.Material]: boolean } = {
	[Enum.Material.Snow] = true,
	[Enum.Material.Glacier] = true,
}

type Tracker = { lastPos: Vector3?, travelled: number, side: number }

local folder: Folder
local pool: { Part } = {}
local born: { number } = {} -- os.clock() when each pool slot was placed, 0 = free
local nextSlot = 1
local active = 0
local trackers: { [Player]: Tracker } = {}
local rayParams = RaycastParams.new()
local worldState: Instance? = nil

local function refreshFilter()
	local list: { Instance } = { folder }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

local function buildPool()
	folder = Instance.new("Folder")
	folder.Name = "Footprints"
	for i = 1, POOL_SIZE do
		local p = Instance.new("Part")
		p.Name = "Footprint"
		p.Size = PRINT_SIZE
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Locked = true
		p.Material = Enum.Material.SmoothPlastic
		p.Color = PRINT_COLOR
		p.Transparency = 1
		p.CFrame = PARK
		p.Parent = folder
		pool[i] = p
		born[i] = 0
	end
	folder.Parent = workspace
end

local function place(position: Vector3, normal: Vector3, heading: Vector3)
	-- Face the travel direction, flattened onto the slope.
	local look = heading - normal * heading:Dot(normal)
	if look.Magnitude < 1e-3 then
		return
	end
	look = look.Unit
	local right = look:Cross(normal)
	local slot = nextSlot
	nextSlot = nextSlot % POOL_SIZE + 1
	if born[slot] == 0 then
		active += 1
	end
	born[slot] = os.clock()
	local part = pool[slot]
	part.CFrame = CFrame.fromMatrix(position + normal * (PRINT_SIZE.Y * 0.5 + 0.02), right, normal)
	part.Transparency = START_TRANSPARENCY
end

local function stepCharacter(owner: Player, tracker: Tracker, cameraPos: Vector3?)
	local character = owner.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		tracker.lastPos = nil
		return
	end
	local pos = root.Position
	local last = tracker.lastPos
	tracker.lastPos = pos
	if not last then
		return
	end
	local moved = Vector3.new(pos.X - last.X, 0, pos.Z - last.Z)
	local dist = moved.Magnitude
	if dist < MIN_MOVE or dist > TELEPORT then
		return
	end
	if cameraPos and (pos - cameraPos).Magnitude > MAX_CAMERA_DISTANCE then
		return
	end
	local floor = humanoid.FloorMaterial
	local isLocal = owner == localPlayer
	if not (SNOW[floor] or (not isLocal and floor == Enum.Material.Air)) then
		tracker.travelled = 0
		return
	end
	if owner:GetAttribute("Climbing") == true then
		return
	end

	tracker.travelled += dist
	if tracker.travelled < STRIDE then
		return
	end
	tracker.travelled = 0
	tracker.side = -tracker.side

	local heading = moved / dist
	local right = Vector3.new(-heading.Z, 0, heading.X)
	local footOrigin = pos + right * (FOOT_SPACING * tracker.side)
	-- R15 HipHeight already includes the legs; R6 reports 0 and has 2-stud legs.
	local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else 0
	local reach = humanoid.HipHeight + legs + root.Size.Y * 0.5 + GROUND_SLACK
	local hit = workspace:Raycast(footOrigin, Vector3.new(0, -reach - 1, 0), rayParams)
	if not hit or not SNOW[hit.Material] or hit.Distance > reach then
		return -- airborne, or the foot is over something that isn't snow
	end
	if hit.Normal.Y < 0.35 then
		return -- too steep to leave a print
	end
	place(hit.Position, hit.Normal, heading)
end

local function fade()
	if active == 0 then
		return
	end
	local now = os.clock()
	local precip = 0
	worldState = worldState or ReplicatedStorage:FindFirstChild("WorldState")
	local ws = worldState
	if ws then
		local v = ws:GetAttribute("Precipitation")
		precip = if typeof(v) == "number" then math.clamp(v, 0, 1) else 0
	end
	local lifetime = LIFETIME * (1 - 0.5 * precip)
	local hold = lifetime * HOLD_FRACTION
	for i = 1, POOL_SIZE do
		local t0 = born[i]
		if t0 > 0 then
			local age = now - t0
			if age >= lifetime then
				born[i] = 0
				active -= 1
				local part = pool[i]
				part.Transparency = 1
				part.CFrame = PARK
			elseif age > hold then
				local f = (age - hold) / (lifetime - hold)
				pool[i].Transparency = START_TRANSPARENCY + (1 - START_TRANSPARENCY) * f
			end
		end
	end
end

local function track(p: Player)
	trackers[p] = { lastPos = nil, travelled = 0, side = 1 }
	p.CharacterAdded:Connect(function()
		local tracker = trackers[p]
		if tracker then
			tracker.lastPos = nil
			tracker.travelled = 0
		end
		refreshFilter()
	end)
	p.CharacterRemoving:Connect(function()
		task.defer(refreshFilter)
	end)
end

function FootprintController.Init()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true
	buildPool()
	refreshFilter()
end

function FootprintController.Start()
	for _, p in Players:GetPlayers() do
		track(p)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(p)
		trackers[p] = nil
		task.defer(refreshFilter)
	end)
	refreshFilter()

	local sampleTimer = 0
	local fadeTimer = 0
	RunService.Heartbeat:Connect(function(dt)
		sampleTimer += dt
		fadeTimer += dt
		if sampleTimer >= SAMPLE_SECONDS then
			sampleTimer = 0
			local camera = workspace.CurrentCamera
			local cameraPos = if camera then camera.CFrame.Position else nil
			for owner, tracker in trackers do
				stepCharacter(owner, tracker, cameraPos)
			end
		end
		if fadeTimer >= FADE_SECONDS then
			fadeTimer = 0
			fade()
		end
	end)
end

return FootprintController
