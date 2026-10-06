--!strict
-- Server-owned weather. Weather walks the neighbour graph in WeatherDefs, blending
-- parameters over TransitionSeconds so it never snaps from sun to blizzard.
-- The blended state is published as attributes on ReplicatedStorage.WorldState; clients
-- render it (sky, fog, particles, audio) but the server alone uses it for survival.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeatherDefs = require(Shared.Config.WeatherDefs)
local GameConfig = require(Shared.Config.GameConfig)
local WeatherModel = require(Shared.Logic.WeatherModel)
local Signal = require(Shared.Util.Signal)
local Registry = require(script.Parent.Parent.Registry)

local WeatherService = {}

WeatherService.StateChanged = Signal.new() -- (fromId, toId)

local rng = Random.new()
local worldState: Folder

local fromId = WeatherDefs.Initial
local toId = WeatherDefs.Initial
local blend = 1
local transitionSeconds = WeatherDefs.TransitionSeconds
local holdRemaining = 0
local forcedPath: { string } = {}
local params: WeatherModel.Params = WeatherDefs.States[WeatherDefs.Initial].params
local windAngle = rng:NextNumber(0, math.pi * 2)
local clockTime = WeatherDefs.StartClockTime

local function beginTransition(nextId: string, seconds: number)
	fromId = toId
	toId = nextId
	blend = 0
	transitionSeconds = seconds
	WeatherService.StateChanged:Fire(fromId, toId)
end

local function currentParams(): WeatherModel.Params
	return WeatherModel.blend(WeatherDefs.States[fromId].params, WeatherDefs.States[toId].params, blend)
end

local function step(dt: number)
	if blend < 1 then
		blend = math.min(1, blend + dt / transitionSeconds)
		if blend >= 1 then
			local range = WeatherDefs.States[toId].durationRange
			holdRemaining = if #forcedPath > 0 then 2 else rng:NextNumber(range[1], range[2])
		end
	else
		holdRemaining -= dt
		if holdRemaining <= 0 then
			if #forcedPath > 0 then
				beginTransition(table.remove(forcedPath, 1) :: string, WeatherDefs.ForcedTransitionSeconds)
			else
				beginTransition(
					WeatherModel.pickNext(toId, function()
						return rng:NextNumber()
					end),
					WeatherDefs.TransitionSeconds
				)
			end
		end
	end
	params = currentParams()
	clockTime = (clockTime + dt * 24 / WeatherDefs.DayLengthSeconds) % 24
	windAngle += math.rad(WeatherDefs.WindDirectionDriftDegPerSec) * dt * (rng:NextNumber() - 0.3)
end

local function publish()
	worldState:SetAttribute("WeatherFrom", fromId)
	worldState:SetAttribute("WeatherTo", toId)
	worldState:SetAttribute("WeatherBlend", math.floor(blend * 100 + 0.5) / 100)
	worldState:SetAttribute("WindMs", math.floor(params.windMs * 10 + 0.5) / 10)
	worldState:SetAttribute("WindDirection", Vector3.new(math.cos(windAngle), 0, math.sin(windAngle)))
	worldState:SetAttribute("Precipitation", math.floor(params.precipitation * 100 + 0.5) / 100)
	worldState:SetAttribute("Fog", math.floor(params.fog * 100 + 0.5) / 100)
	worldState:SetAttribute("Cloud", math.floor(params.cloud * 100 + 0.5) / 100)
	worldState:SetAttribute("TempOffsetC", math.floor(params.tempOffsetC * 10 + 0.5) / 10)
	worldState:SetAttribute("ClockTime", math.floor(clockTime * 100 + 0.5) / 100)
	-- The server owns time of day; Lighting.ClockTime replicates to every client.
	Lighting.ClockTime = clockTime
end

-- Weather as experienced at a point (temperature depends on elevation).
function WeatherService.sampleAt(position: Vector3)
	local elevation = WeatherModel.elevationM(position.Y)
	local airTemp = WeatherModel.airTemperature(elevation, params, clockTime)
	local dominant = if blend >= 0.5 then toId else fromId
	return {
		airTempC = airTemp,
		windMs = params.windMs,
		precipitation = params.precipitation,
		isSnow = WeatherModel.isSnow(airTemp),
		fog = params.fog,
		name = WeatherModel.displayName(dominant, airTemp),
		severe = WeatherDefs.States[dominant].severe,
		lightning = params.lightning,
	}
end

function WeatherService.params(): WeatherModel.Params
	return params
end

function WeatherService.clockTime(): number
	return clockTime
end

function WeatherService.currentId(): string
	return if blend >= 0.5 then toId else fromId
end

-- Expedition director hook: walk to `targetId` through every intermediate state.
-- `warningSeconds` delays the first step so players get a heads-up.
function WeatherService.force(targetId: string, warningSeconds: number?)
	assert(WeatherDefs.States[targetId], "unknown weather " .. targetId)
	local startFrom = toId
	forcedPath = WeatherModel.pathTo(startFrom, targetId)
	if #forcedPath == 0 then
		return
	end
	if blend >= 1 then
		holdRemaining = warningSeconds or 0
	end
end

function WeatherService.Init()
	worldState = Instance.new("Folder")
	worldState.Name = "WorldState"
	worldState.Parent = ReplicatedStorage
	publish()
	holdRemaining = rng:NextNumber(WeatherDefs.States[toId].durationRange[1], WeatherDefs.States[toId].durationRange[2])
end

function WeatherService.Start()
	local publishTimer = 0
	RunService.Heartbeat:Connect(function(dt)
		step(dt)
		publishTimer += dt
		if publishTimer >= GameConfig.WORLD_STATE_PUBLISH_SECONDS then
			publishTimer = 0
			publish()
		end
	end)
	WeatherService.StateChanged:Connect(function(previousId, nextId)
		local RemoteGuard = Registry.get("RemoteGuard")
		if nextId == "Storm" then
			RemoteGuard.fireAll("Banner", "A blizzard is coming. Find shelter!", "storm")
		elseif nextId == "HeavyPrecip" and previousId ~= "Storm" then
			RemoteGuard.fireAll("Banner", "Heavy snow rolling in. Stay close to the route markers.", "storm")
		elseif nextId == "Fog" then
			RemoteGuard.fireAll("Banner", "Whiteout fog. Follow the red markers.", "info")
		elseif previousId == "Storm" then
			RemoteGuard.fireAll("Banner", "The storm is passing.", "info")
		end
		local state = WeatherDefs.States[nextId]
		if state.severe then
			RemoteGuard.notifyAll("SEVERE WEATHER APPROACHING: " .. string.upper(state.snowName), "danger")
		end
	end)
end

return WeatherService
