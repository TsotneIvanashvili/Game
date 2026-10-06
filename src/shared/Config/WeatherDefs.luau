--!strict
-- Weather states and the graph of allowed transitions. Weather only moves to a neighbour,
-- which is what makes it gradual: Clear can never jump straight to Storm.
-- Precipitation falls as rain where the ambient temperature is above RainSnowSplitC and
-- as snow below it, so one storm is a thunderstorm in the forest and a blizzard on the ridge.

export type WeatherParams = {
	tempOffsetC: number,
	windMs: number,
	precipitation: number, -- 0..1
	fog: number, -- 0..1
	cloud: number, -- 0..1
	disasterMult: number,
	lightning: number, -- strikes per minute near players when raining
}

export type WeatherState = {
	id: string,
	rainName: string,
	snowName: string,
	params: WeatherParams,
	durationRange: { number },
	neighbours: { [string]: number }, -- neighbour id -> natural transition weight
	severe: boolean,
}

local states: { [string]: WeatherState } = {
	Clear = {
		id = "Clear",
		rainName = "Clear",
		snowName = "Clear",
		params = {
			tempOffsetC = 2,
			windMs = 2,
			precipitation = 0,
			fog = 0,
			cloud = 0.1,
			disasterMult = 1,
			lightning = 0,
		},
		durationRange = { 150, 300 },
		neighbours = { Cloudy = 1 },
		severe = false,
	},
	Cloudy = {
		id = "Cloudy",
		rainName = "Overcast",
		snowName = "Overcast",
		params = {
			tempOffsetC = 0,
			windMs = 4,
			precipitation = 0,
			fog = 0.1,
			cloud = 0.6,
			disasterMult = 1,
			lightning = 0,
		},
		durationRange = { 120, 240 },
		neighbours = { Clear = 3, Windy = 2, Fog = 1, LightPrecip = 2 },
		severe = false,
	},
	Fog = {
		id = "Fog",
		rainName = "Dense Fog",
		snowName = "Whiteout Fog",
		params = {
			tempOffsetC = -1,
			windMs = 1,
			precipitation = 0,
			fog = 0.85,
			cloud = 0.8,
			disasterMult = 1,
			lightning = 0,
		},
		durationRange = { 90, 180 },
		neighbours = { Cloudy = 1 },
		severe = false,
	},
	Windy = {
		id = "Windy",
		rainName = "Strong Wind",
		snowName = "Strong Wind",
		params = {
			tempOffsetC = -2,
			windMs = 12,
			precipitation = 0,
			fog = 0.1,
			cloud = 0.5,
			disasterMult = 1.3,
			lightning = 0,
		},
		durationRange = { 90, 180 },
		neighbours = { Cloudy = 2, LightPrecip = 1 },
		severe = false,
	},
	LightPrecip = {
		id = "LightPrecip",
		rainName = "Light Rain",
		snowName = "Light Snow",
		params = {
			tempOffsetC = -2,
			windMs = 6,
			precipitation = 0.35,
			fog = 0.25,
			cloud = 0.8,
			disasterMult = 1.4,
			lightning = 0,
		},
		durationRange = { 120, 240 },
		neighbours = { Cloudy = 2, Windy = 1, HeavyPrecip = 1 },
		severe = false,
	},
	HeavyPrecip = {
		id = "HeavyPrecip",
		rainName = "Heavy Rain",
		snowName = "Heavy Snow",
		params = {
			tempOffsetC = -5,
			windMs = 10,
			precipitation = 0.75,
			fog = 0.5,
			cloud = 0.95,
			disasterMult = 2,
			lightning = 0.5,
		},
		durationRange = { 90, 180 },
		neighbours = { LightPrecip = 2, Storm = 1 },
		severe = true,
	},
	Storm = {
		id = "Storm",
		rainName = "Thunderstorm",
		snowName = "Blizzard",
		params = {
			tempOffsetC = -7, -- base camp stays just above freezing (rain), the ridge gets a blizzard
			windMs = 20,
			precipitation = 1,
			fog = 0.85,
			cloud = 1,
			disasterMult = 3,
			lightning = 2,
		},
		durationRange = { 150, 240 },
		neighbours = { HeavyPrecip = 1 },
		severe = true,
	},
}

return {
	States = states,
	Initial = "Clear",
	TransitionSeconds = 75, -- natural blend time between neighbours
	ForcedTransitionSeconds = 40, -- blend time per step when the director pushes a storm in
	RainSnowSplitC = 1,
	BaseTempC = 9, -- temperature at base camp elevation in clear weather
	LapseRateCPer1000m = 6.5,
	WindDirectionDriftDegPerSec = 1.5,
}
