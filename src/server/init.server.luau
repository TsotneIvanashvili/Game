--!strict
-- Server bootstrap. Order matters only for Init (create remotes and state); every service
-- is registered before any Init runs, so cross-service lookups in handlers always resolve.

local Registry = require(script.Registry)
local WorldBuilder = require(script.World.WorldBuilder)

local Services = script.Services

local ORDER = {
	{ "RemoteGuard", script.Security.RemoteGuard },
	{ "DataService", Services.DataService },
	{ "ProgressionService", Services.ProgressionService },
	{ "InventoryService", Services.InventoryService },
	{ "SurvivalService", Services.SurvivalService },
	{ "ClimbingService", Services.ClimbingService },
	{ "WeatherService", Services.WeatherService },
	{ "BuildingService", Services.BuildingService },
	{ "ResourceService", Services.ResourceService },
	{ "CampService", Services.CampService },
	{ "RescueService", Services.RescueService },
	{ "DisasterService", Services.DisasterService },
	{ "ExpeditionService", Services.ExpeditionService },
	{ "EquipmentService", Services.EquipmentService },
	{ "PlayerService", Services.PlayerService },
}

-- No characters until the world exists: players joining during terrain generation would
-- otherwise spawn over an empty map and fall. Spawning resumes once the build finishes.
local Players = game:GetService("Players")
Players.CharacterAutoLoads = false

local started = os.clock()
local built = WorldBuilder.build()
print(
	string.format(
		"[Server] world %s in %.2fs",
		if built then "generated" else "found (hand-built)",
		os.clock() - started
	)
)

-- Services are started below; then spawn everyone who joined while the world was building.
local function releaseSpawns()
	Players.CharacterAutoLoads = true
	for _, player in Players:GetPlayers() do
		if not player.Character then
			task.spawn(function()
				player:LoadCharacter()
			end)
		end
	end
end

local loaded = {}
for _, entry in ORDER do
	local service = require(entry[2]) :: any
	Registry.register(entry[1], service)
	table.insert(loaded, { entry[1], service })
end
for _, entry in loaded do
	if entry[2].Init then
		entry[2].Init()
	end
end
for _, entry in loaded do
	if entry[2].Start then
		entry[2].Start()
	end
end
print(string.format("[Server] %d services started in %.2fs", #loaded, os.clock() - started))
releaseSpawns()

-- Startup report: one line the player can paste back so problems are visible without Studio
-- access on our side. Zero of anything here means that part of the world failed to build.
task.defer(function()
	local CollectionService = game:GetService("CollectionService")
	local function count(tag: string): number
		return #CollectionService:GetTagged(tag)
	end
	local parts = 0
	local mountain = workspace:FindFirstChild("Mountain")
	if mountain then
		for _, d in mountain:GetDescendants() do
			if d:IsA("BasePart") then
				parts += 1
			end
		end
	end
	local rings = 0
	for _, camp in CollectionService:GetTagged("Camp") do
		if camp:FindFirstChild("CheckpointRing", true) then
			rings += 1
		end
	end
	print(
		string.format(
			"[Report] camps %d | checkpoint rings %d | sleep spots %d | supply crates %d | outfitters %d | wood %d | water %d | hazards %d | summit %d | world parts %d",
			count("Camp"),
			rings,
			count("SleepSpot"),
			count("SupplyCrate"),
			count("Outfitter"),
			count("WoodSource"),
			count("WaterSource"),
			count("RockfallZone"),
			count("SectionEnd"),
			parts
		)
	)
end)
