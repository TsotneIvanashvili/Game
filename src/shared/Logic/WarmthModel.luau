--!strict
-- Pure body-warmth simulation. No Roblox services: unit tested in tests/.
-- Each body region has a warmth value 0..100 that drifts toward balance depending on the
-- "felt" temperature at that region, which combines air temperature, wind that gets through
-- clothing, wetness, exertion heat, fire heat and the clothing's insulation.

local SurvivalConfig = require(script.Parent.Parent.Config.SurvivalConfig)

local W = SurvivalConfig.Warmth

export type Region = "Head" | "Torso" | "Hands" | "Legs" | "Feet"

export type RegionGear = {
	insulation: number,
	windproof: number,
	waterproof: number,
	wetPenalty: number,
}

export type Gear = { [Region]: RegionGear }

export type Environment = {
	airTempC: number,
	windMs: number, -- wind at the player's position after zone exposure and shelter
	precipitation: number, -- 0..1 reaching the player (0 under shelter)
	isSnow: boolean,
	inWater: boolean,
	fireHeatC: number, -- 0 when no fire nearby
	exertion: string,
}

local WarmthModel = {}

WarmthModel.Regions = { "Head", "Torso", "Hands", "Legs", "Feet" } :: { Region }

-- Combine the clothing worn into per-region protection. Insulation stacks across layers;
-- wind and water protection come from the best layer; wet penalty from the worst layer
-- (a soaked cotton tee under a parka still chills you).
function WarmthModel.computeGear(clothing: { any }): Gear
	local gear: Gear = {} :: any
	for _, region in WarmthModel.Regions do
		gear[region] = { insulation = 0, windproof = 0, waterproof = 0, wetPenalty = 0 }
	end
	for _, item in clothing do
		local stats = item.clothing
		if stats then
			for region, value in stats.insulation do
				local g = gear[region :: Region]
				if g then
					g.insulation += value
					g.windproof = math.max(g.windproof, stats.windproof)
					g.waterproof = math.max(g.waterproof, stats.waterproof)
					g.wetPenalty = math.max(g.wetPenalty, stats.wetPenalty)
				end
			end
		end
	end
	return gear
end

-- Average waterproofing of the torso and legs decides how fast you get soaked.
function WarmthModel.bodyWaterproof(gear: Gear): number
	return (gear.Torso.waterproof * 0.6 + gear.Legs.waterproof * 0.4)
end

function WarmthModel.feltTemperature(region: Region, gear: RegionGear, env: Environment, wetness: number): number
	local wind = env.windMs * (1 - gear.windproof)
	local chill = wind * W.WindChillPerMs
	local insulation = gear.insulation * (1 - wetness * gear.wetPenalty)
	local exertion = W.ExertionHeatC[env.exertion] or 0
	-- Hands and feet in deep snow or water lose extra heat.
	local contact = 0
	if region == "Feet" and env.inWater then
		contact = 8
	end
	return env.airTempC
		- chill
		- wetness * W.WetnessChillC
		+ exertion
		+ env.fireHeatC
		- contact
		+ insulation * W.InsulationToCelsius
end

-- Returns the new warmth for one region after dt seconds.
function WarmthModel.stepRegion(current: number, region: Region, felt: number, dt: number): number
	local delta = felt - W.ComfortTempC
	local nextValue
	if delta >= 0 then
		nextValue = current + math.min(delta, W.MaxWarmDelta) * W.WarmRatePerDegree * dt
	else
		local factor = W.RegionCoolFactor[region] or 1
		nextValue = current + delta * W.CoolRatePerDegree * factor * dt
	end
	return math.clamp(nextValue, 0, 100)
end

function WarmthModel.overall(warmth: { [Region]: number }): number
	local total = 0
	for region, weight in W.RegionWeight do
		total += (warmth[region :: Region] or 100) * weight
	end
	return total
end

export type ColdLevel = "None" | "Mild" | "Moderate" | "Severe" | "Critical"

function WarmthModel.coldLevel(overallWarmth: number): ColdLevel
	local t = W.Thresholds
	if overallWarmth < t.Critical then
		return "Critical"
	elseif overallWarmth < t.Severe then
		return "Severe"
	elseif overallWarmth < t.Moderate then
		return "Moderate"
	elseif overallWarmth < t.Mild then
		return "Mild"
	end
	return "None"
end

-- Wetness 0..1. Waterproof clothing sheds precipitation; fire dries fast.
function WarmthModel.stepWetness(wetness: number, gear: Gear, env: Environment, dt: number): number
	local cfg = SurvivalConfig.Wetness
	local gain = 0
	if env.precipitation > 0 then
		local rate = if env.isSnow then cfg.SnowGainPerSec else cfg.RainGainPerSec
		gain += env.precipitation * rate * (1 - WarmthModel.bodyWaterproof(gear))
	end
	if env.inWater then
		gain += cfg.WaterGainPerSec
	end
	if env.exertion ~= "idle" and env.exertion ~= "rest" then
		-- Fire heat is excluded: standing by a fire should dry you, not make you sweat.
		local torsoFelt = WarmthModel.feltTemperature("Torso", gear.Torso, env, wetness) - env.fireHeatC
		if torsoFelt > cfg.SweatAboveFeltC then
			gain += (torsoFelt - cfg.SweatAboveFeltC) * cfg.SweatPerDegreePerSec
		end
	end
	local dry = cfg.DryPerSec
	if env.fireHeatC > 0 then
		dry += cfg.FireDryPerSec * math.clamp(env.fireHeatC / SurvivalConfig.Fire.MaxHeatC, 0, 1)
	end
	if gain > 0 then
		dry *= 0.25 -- you barely dry while still being rained on
	end
	return math.clamp(wetness + (gain - dry) * dt, 0, 1)
end

-- Fire heat falls off linearly to zero at the heat radius.
function WarmthModel.fireHeatAt(distance: number, radius: number?, maxHeat: number?): number
	local r = radius or SurvivalConfig.Fire.HeatRadius
	local m = maxHeat or SurvivalConfig.Fire.MaxHeatC
	if distance >= r then
		return 0
	end
	return m * (1 - distance / r)
end

return WarmthModel
