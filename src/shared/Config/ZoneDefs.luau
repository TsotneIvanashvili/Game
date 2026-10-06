--!strict
-- Elevation zones. The slice covers zones 1-4; the rest are defined so systems that key off
-- zones (resources, temperature, music) already handle them when the map grows upward.
-- `minY` is in studs; zones are evaluated top-down and the first match wins.

export type Zone = {
	id: string,
	name: string,
	index: number,
	minY: number,
	windExposure: number, -- multiplier on weather wind (ridges are exposed, forest is sheltered)
	woodAbundance: number, -- 0..1, scales wood source spawn and respawn
	snowCover: boolean,
}

local zones: { Zone } = {
	{ id = "Summit", name = "Summit", index = 8, minY = 1400, windExposure = 1.8, woodAbundance = 0, snowCover = true },
	{
		id = "HighAltitude",
		name = "High Altitude",
		index = 7,
		minY = 900,
		windExposure = 1.6,
		woodAbundance = 0,
		snowCover = true,
	},
	{
		id = "Glacier",
		name = "Glacier",
		index = 6,
		minY = 520,
		windExposure = 1.4,
		woodAbundance = 0,
		snowCover = true,
	},
	{
		id = "FrozenRidge",
		name = "Frozen Ridge",
		index = 5,
		minY = 330,
		windExposure = 1.5,
		woodAbundance = 0.05,
		snowCover = true,
	},
	{
		id = "Snowline",
		name = "Snowline",
		index = 4,
		minY = 135,
		windExposure = 1.25,
		woodAbundance = 0.25,
		snowCover = true,
	},
	{
		id = "AlpineMeadow",
		name = "Alpine Meadow",
		index = 3,
		minY = 95,
		windExposure = 1.1,
		woodAbundance = 0.4,
		snowCover = false,
	},
	{
		id = "RockyForest",
		name = "Rocky Forest",
		index = 2,
		minY = 30,
		windExposure = 0.8,
		woodAbundance = 0.8,
		snowCover = false,
	},
	{
		id = "BaseForest",
		name = "Base Forest",
		index = 1,
		minY = -math.huge,
		windExposure = 0.6,
		woodAbundance = 1,
		snowCover = false,
	},
}

local ZoneDefs = { List = zones }

function ZoneDefs.at(y: number): Zone
	for _, zone in zones do
		if y >= zone.minY then
			return zone
		end
	end
	return zones[#zones]
end

return ZoneDefs
