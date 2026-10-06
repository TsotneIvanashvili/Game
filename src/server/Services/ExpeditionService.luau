--!strict
-- Expedition director + statistics.
--
-- Director (pacing for the vertical slice, randomized so runs differ):
--   * first player above the snowline -> snowfall rolls in (if the sky is calm)
--   * first player to sign Ridge Camp -> after 60-120 s the wind rises and a storm is
--     forced in. It still walks Cloudy -> Light -> Heavy -> Storm (telegraphed over ~2-3 min),
--     which is the moment players either shelter at camp or get caught building a tarp.
-- Stats: shown when a player completes the section (reaches the col above Ridge Camp).
-- Pings: team route markers (G).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local ZoneDefs = require(Shared.Config.ZoneDefs)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)

local ExpeditionService = {}

local rng = Random.new()
local snowTriggered = false
local stormScheduled = false

local function remote()
	return Registry.get("RemoteGuard")
end

function ExpeditionService.onCheckpoint(_player: Player, index: number)
	if index >= 2 and not stormScheduled then
		stormScheduled = true
		local delaySeconds = rng:NextNumber(60, 120)
		task.delay(delaySeconds, function()
			remote().notifyAll("The wind is picking up. Dark clouds are pouring over the ridge.", "warn")
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
	Registry.get("ProgressionService").award(player, ProgressionConfig.XP.SectionComplete, "Reached the Ridge Col")
	remote().notifyAll(player.DisplayName .. " reached the Ridge Col!", "good")
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

function ExpeditionService.Start()
	local snowline = 0
	for _, zone in ZoneDefs.List do
		if zone.id == "Snowline" then
			snowline = zone.minY
		end
	end
	task.spawn(function()
		while not snowTriggered do
			task.wait(2)
			for _, player in Players:GetPlayers() do
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root and root.Position.Y >= snowline and not snowTriggered then
					snowTriggered = true
					local weather = Registry.get("WeatherService")
					local current = weather.currentId()
					if current == "Clear" or current == "Cloudy" or current == "Windy" then
						weather.force("LightPrecip", 5)
					end
				end
			end
		end
	end)
end

return ExpeditionService
