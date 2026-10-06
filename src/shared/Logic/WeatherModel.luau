--!strict
-- Pure weather math: blending between states, picking the next state, finding the path a
-- forced storm must walk through, and the temperature at a given elevation.

local WeatherDefs = require(script.Parent.Parent.Config.WeatherDefs)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)

export type Params = WeatherDefs.WeatherParams

local WeatherModel = {}

local KEYS = { "tempOffsetC", "windMs", "precipitation", "fog", "cloud", "disasterMult", "lightning" }

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

function WeatherModel.blend(a: Params, b: Params, t: number): Params
	local s = smoothstep(t)
	local out = {} :: any
	for _, key in KEYS do
		out[key] = (a :: any)[key] + ((b :: any)[key] - (a :: any)[key]) * s
	end
	return out
end

-- Weighted random neighbour. `rng` returns a float in [0, 1).
function WeatherModel.pickNext(stateId: string, rng: () -> number): string
	local state = WeatherDefs.States[stateId]
	local total = 0
	local ids = {}
	for id, weight in state.neighbours do
		table.insert(ids, id)
		total += weight
	end
	table.sort(ids) -- deterministic order for a given rng
	local roll = rng() * total
	for _, id in ids do
		roll -= state.neighbours[id]
		if roll < 0 then
			return id
		end
	end
	return ids[#ids]
end

-- Shortest path of states from `fromId` to `toId` (excluding `fromId`). Used when the
-- expedition director pushes in a storm: it still walks every intermediate state.
function WeatherModel.pathTo(fromId: string, toId: string): { string }
	if fromId == toId then
		return {}
	end
	local previous: { [string]: string } = {}
	local visited = { [fromId] = true }
	local queue = { fromId }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		local neighbours = {}
		for id in WeatherDefs.States[current].neighbours do
			table.insert(neighbours, id)
		end
		table.sort(neighbours)
		for _, id in neighbours do
			if not visited[id] then
				visited[id] = true
				previous[id] = current
				if id == toId then
					local path = { id }
					local node = current
					while node ~= fromId do
						table.insert(path, 1, node)
						node = previous[node]
					end
					return path
				end
				table.insert(queue, id)
			end
		end
	end
	return {}
end

function WeatherModel.elevationM(y: number): number
	return GameConfig.BASE_ELEVATION_M + y * GameConfig.ELEVATION_M_PER_STUD
end

function WeatherModel.airTemperature(elevationM: number, params: Params): number
	local above = (elevationM - GameConfig.BASE_ELEVATION_M) / 1000
	return WeatherDefs.BaseTempC - above * WeatherDefs.LapseRateCPer1000m + params.tempOffsetC
end

function WeatherModel.isSnow(airTempC: number): boolean
	return airTempC < WeatherDefs.RainSnowSplitC
end

function WeatherModel.displayName(stateId: string, airTempC: number): string
	local state = WeatherDefs.States[stateId]
	return if WeatherModel.isSnow(airTempC) then state.snowName else state.rainName
end

return WeatherModel
