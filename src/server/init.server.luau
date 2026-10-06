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

local started = os.clock()
local built = WorldBuilder.build()
print(
	string.format(
		"[Server] world %s in %.2fs",
		if built then "generated" else "found (hand-built)",
		os.clock() - started
	)
)

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
