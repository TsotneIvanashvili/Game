--!strict
-- Camp light at night (ART_DIRECTION 10): fires flicker and swell after dark, lamps glow a
-- little stronger at night and softer by day. Client-only; the server's lights are untouched
-- on the server and nothing replicates.
--
-- Lights are found, never scanned for per frame: a one-time sweep (in batches across frames)
-- of Workspace.Mountain and Workspace.Structures when each appears, plus their DescendantAdded
-- events, which also catch player-built fires and anything streamed in later. New lights
-- queue up and are registered a few hundred per update. A light whose Parent goes nil (a fire
-- burning out, streaming out) is dropped on the next update.
--
-- Fire lights are PointLights whose parent is named "Embers" (AssetFactory campfire); every
-- other PointLight under those roots counts as a lamp.

local RunService = game:GetService("RunService")

local WeatherController = require(script.Parent.WeatherController)

local AmbienceController = {}

local WATCHED_ROOTS = { "Mountain", "Structures" }
local UPDATE_SECONDS = 1 / 12
local SCAN_BATCH = 500 -- descendants per frame in the initial sweep
local REGISTER_BATCH = 200 -- queued lights registered per update
local FLICKER_DISTANCE = 350 -- fires further from the camera than this hold steady

local FIRE_NIGHT_BOOST = 0.35 -- brightness multiplier added at full night
local FIRE_RANGE_NIGHT_BOOST = 0.12
local LAMP_DAY = 0.7
local LAMP_NIGHT = 1.3

type Entry = {
	light: PointLight,
	anchor: BasePart?,
	fire: boolean,
	baseBrightness: number,
	baseRange: number,
	seed: number,
	applied: number,
}

local entries: { Entry } = {}
local known: { [Instance]: boolean } = {}
local pending: { PointLight } = {}
local watched: { [Instance]: boolean } = {}
local rng = Random.new()

local function consider(inst: Instance)
	if inst:IsA("PointLight") and not known[inst] then
		known[inst] = true
		table.insert(pending, inst)
	end
end

local function register(light: PointLight)
	local parent = light.Parent
	if not parent then
		known[light] = nil
		return
	end
	local anchor: BasePart? = nil
	if parent:IsA("BasePart") then
		anchor = parent
	elseif parent:IsA("Attachment") and parent.Parent and parent.Parent:IsA("BasePart") then
		anchor = parent.Parent :: BasePart
	end
	table.insert(entries, {
		light = light,
		anchor = anchor,
		fire = parent.Name == "Embers",
		baseBrightness = light.Brightness,
		baseRange = light.Range,
		seed = rng:NextNumber(0, 1000),
		applied = -1,
	})
end

local function watchRoot(root: Instance)
	if watched[root] then
		return
	end
	watched[root] = true
	root.DescendantAdded:Connect(consider)
	task.spawn(function()
		local list = root:GetDescendants()
		for i, d in list do
			consider(d)
			if i % SCAN_BATCH == 0 then
				task.wait()
			end
		end
	end)
end

local function update()
	-- Register a bounded number of newly found lights.
	local n = math.min(#pending, REGISTER_BATCH)
	for _ = 1, n do
		local light = table.remove(pending) :: PointLight
		register(light)
	end

	local night = WeatherController.nightFactor()
	local now = os.clock()
	local camera = workspace.CurrentCamera
	local cameraPos = if camera then camera.CFrame.Position else nil
	local lampScale = LAMP_DAY + (LAMP_NIGHT - LAMP_DAY) * night

	-- Reverse walk so a swap-remove only moves an entry we've already handled.
	for i = #entries, 1, -1 do
		local e = entries[i]
		local light = e.light
		if light.Parent == nil then
			known[light] = nil
			entries[i] = entries[#entries]
			entries[#entries] = nil
		elseif e.fire then
			local anchor = e.anchor
			local near = cameraPos == nil or anchor == nil or (anchor.Position - cameraPos).Magnitude < FLICKER_DISTANCE
			if near then
				-- math.noise is roughly within [-0.5, 0.5]: a slow swell plus a quicker flutter.
				local swell = math.noise(now * 1.3, e.seed)
				local flutter = math.noise(now * 4.5, e.seed + 17.3)
				local f = 1 + swell * 0.35 + flutter * 0.25
				light.Brightness = e.baseBrightness * (1 + FIRE_NIGHT_BOOST * night) * f
				light.Range = e.baseRange * (1 + FIRE_RANGE_NIGHT_BOOST * night) * (1 + swell * 0.08)
			end
		else
			local b = e.baseBrightness * lampScale
			if math.abs(b - e.applied) > 0.01 then
				e.applied = b
				light.Brightness = b
			end
		end
	end
end

function AmbienceController.Start()
	for _, name in WATCHED_ROOTS do
		local root = workspace:FindFirstChild(name)
		if root then
			watchRoot(root)
		end
	end
	workspace.ChildAdded:Connect(function(child)
		if table.find(WATCHED_ROOTS, child.Name) then
			watchRoot(child)
		end
	end)

	local timer = 0
	RunService.Heartbeat:Connect(function(dt)
		timer += dt
		if timer >= UPDATE_SECONDS then
			timer = 0
			update()
		end
	end)
end

return AmbienceController
