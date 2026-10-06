--!strict
-- Expedition director + statistics.
--
-- Director (pacing, randomized so runs differ). The first player to reach Camp 1 and the
-- first to reach Camp 2 each set off a storm 60-150 s later. It still walks Cloudy -> Light
-- -> Heavy -> Storm (telegraphed over ~2-3 min with banners), which is the moment players
-- either shelter in camp or get caught pitching a tent on the route.
-- Stats: shown when a player reaches the summit.
-- Pings: team route markers (G).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)

local ExpeditionService = {}

local rng = Random.new()
local stormsTriggered: { [number]: boolean } = {}

local function remote()
	return Registry.get("RemoteGuard")
end

function ExpeditionService.onCheckpoint(_player: Player, index: number)
	if index >= 2 and not stormsTriggered[index] then
		stormsTriggered[index] = true
		local delaySeconds = rng:NextNumber(60, 150)
		task.delay(delaySeconds, function()
			remote().fireAll("Banner", "The wind is picking up. Dark clouds over the ridge.", "storm")
			Registry.get("WeatherService").force("Storm", 20)
		end)
	end
end

function ExpeditionService.summaryFor(player: Player)
	local record = PlayerStore.get(player)
	if not record then
		return nil
	end
	local s = record.stats
	local weather = {}
	for name in s.weatherSurvived do
		table.insert(weather, name)
	end
	table.sort(weather)
	return {
		name = player.DisplayName,
		maxElevationM = math.floor(s.maxElevationM),
		distanceM = math.floor(s.distanceStuds * GameConfig.METERS_PER_STUD),
		timeSeconds = os.time() - s.startedAt,
		highestCheckpoint = s.highestCheckpoint,
		weatherSurvived = weather,
		disastersSurvived = s.disastersSurvived,
		teammatesRescued = s.teammatesRescued,
		itemsConsumed = s.itemsConsumed,
		injuries = s.injuries,
		resourcesCollected = s.resourcesCollected,
		sectionComplete = s.sectionComplete,
	}
end

function ExpeditionService.sectionComplete(player: Player)
	local record = PlayerStore.get(player)
	if not record or record.stats.sectionComplete then
		return
	end
	record.stats.sectionComplete = true
	local DataService = Registry.get("DataService")
	local profile = DataService.get(player)
	if profile then
		profile.totals.sectionsCompleted += 1
		profile.totals.maxElevationM = math.max(profile.totals.maxElevationM, record.stats.maxElevationM)
		DataService.markDirty(player)
	end
	Registry.get("ProgressionService").award(player, ProgressionConfig.XP.Summit, "Reached the summit")
	if profile then
		profile.totals.summits += 1
	end
	remote().notifyAll(player.DisplayName .. " reached the summit!", "good")
	remote().fireAll("Banner", player.DisplayName .. " reached the summit!", "checkpoint")
	remote().fire(player, "ExpeditionSummary", ExpeditionService.summaryFor(player))
end

function ExpeditionService.Init()
	Registry.get("RemoteGuard").on("Ping", function(player: Player, position: Vector3)
		local record, _, _, root = PlayerStore.getActive(player)
		if not record or not root then
			return
		end
		if (position - root.Position).Magnitude > GameConfig.PING_RANGE then
			return
		end
		remote().fireAll("PingBroadcast", position, player.DisplayName, player.UserId)
	end)
end

function ExpeditionService.Start() end

return ExpeditionService
