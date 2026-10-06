--!strict
-- Elevation zones along the route: Base Camp (y~0) -> Camp 1 (~200) -> Camp 2 (~450) -> Summit (~800).
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

local function zone(id: string, name: string, index: number, minY: number, wind: number, wood: number): Zone
	return {
		id = id,
		name = name,
		index = index,
		minY = minY,
		windExposure = wind,
		woodAbundance = wood,
		snowCover = true,
	}
end

-- The mountain is snow from bottom to top (art direction v2). Zones differ in exposure and
-- scarcity: wood thins out with height, wind grows on the open ridge and summit.
local zones: { Zone } = {
	zone("Summit", "Summit", 6, 720, 1.8, 0),
	zone("HighRidge", "High Ridge", 5, 520, 1.5, 0),
	zone("UpperGlacier", "Upper Glacier", 4, 330, 1.2, 0.05),
	zone("Icefall", "Icefall", 3, 160, 1.0, 0.2),
	zone("LowerValley", "Lower Valley", 2, 40, 0.8, 0.6),
	zone("BaseValley", "Base Camp Valley", 1, -math.huge, 0.7, 1),
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
