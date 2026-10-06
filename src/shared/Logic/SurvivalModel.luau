--!strict
-- Pure survival simulation for one player. The server calls `step` on a fixed tick and
-- `modifiers` whenever it needs movement/climbing rules. Everything here is deterministic
-- given its inputs (randomness lives in services), so it is fully unit tested.
--
-- Interactions (design section 5):
--   low hunger  -> slower stamina regen, lower max stamina when starving
--   low thirst  -> slower regen, costlier exertion
--   cold        -> slower regen, slower movement, costlier climbing, frostbite, unconsciousness
--   fatigue     -> lower max stamina, slower movement
--   altitude    -> less oxygen -> costlier exertion and slower regen; altitude sickness
--   weight      -> slower movement, costlier exertion, no climbing when badly overloaded
--   injuries    -> see InjuryDefs

local SurvivalConfig = require(script.Parent.Parent.Config.SurvivalConfig)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local WarmthModel = require(script.Parent.WarmthModel)
local InjuryModel = require(script.Parent.InjuryModel)

local S = SurvivalConfig.Stamina

export type State = {
	stamina: number,
	hunger: number,
	thirst: number,
	fatigue: number,
	oxygen: number,
	altitudeSickness: number,
	wetness: number,
	warmth: { [string]: number },
	frostExposure: { [string]: number },
	staminaCooldown: number,
	exhaustedLock: boolean,
	criticalColdTime: number,
	injuries: InjuryModel.Injuries,
	buffs: { [string]: number },
}

export type Context = {
	exertion: string, -- idle | walk | sprint | climb | carry | rest
	elevationM: number,
	env: WarmthModel.Environment,
	gear: WarmthModel.Gear,
	weightRatio: number, -- carried weight / pack limit
	campResting: boolean,
}

export type Modifiers = {
	maxStamina: number,
	moveMult: number,
	staminaCostMult: number,
	sprintCostMult: number,
	climbCostMult: number,
	climbSpeedMult: number,
	staminaRegenMult: number,
	canSprint: boolean,
	canClimb: boolean,
	coldLevel: WarmthModel.ColdLevel,
}

local SurvivalModel = {}

function SurvivalModel.newState(): State
	local warmth = {}
	for _, region in WarmthModel.Regions do
		warmth[region] = 100
	end
	return {
		stamina = S.Max,
		hunger = 100,
		thirst = 100,
		fatigue = 0,
		oxygen = 100,
		altitudeSickness = 0,
		wetness = 0,
		warmth = warmth,
		frostExposure = { Hands = 0, Feet = 0, Head = 0 },
		staminaCooldown = 0,
		exhaustedLock = false,
		criticalColdTime = 0,
		injuries = {},
		buffs = {},
	}
end

function SurvivalModel.oxygenAt(elevationM: number): number
	local cfg = SurvivalConfig.Oxygen
	if elevationM <= cfg.ThresholdM then
		return 100
	end
	local t = math.clamp((elevationM - cfg.ThresholdM) / (cfg.FullLossM - cfg.ThresholdM), 0, 1)
	return 100 - t * (100 - cfg.MinOxygen)
end

function SurvivalModel.overallWarmth(state: State): number
	return WarmthModel.overall(state.warmth :: any)
end

-- Weight effects. Under half the pack's limit you don't notice it.
function SurvivalModel.weightEffects(ratio: number): (number, number, boolean, boolean)
	local move, cost = 1, 1
	if ratio > 0.5 then
		local over = math.min(ratio, 1) - 0.5
		move -= over * 0.3
		cost += over * 0.8
	end
	if ratio > 1 then
		move -= (ratio - 1) * 1.2
		cost += (ratio - 1) * 1.5
	end
	local canSprint = ratio <= 1.1
	local canClimb = ratio <= 1.15
	return math.max(move, 0.35), cost, canSprint, canClimb
end

function SurvivalModel.modifiers(state: State, weightRatio: number): Modifiers
	local m: Modifiers = {
		maxStamina = S.Max,
		moveMult = 1,
		staminaCostMult = 1,
		sprintCostMult = 1,
		climbCostMult = 1,
		climbSpeedMult = 1,
		staminaRegenMult = 1,
		canSprint = true,
		canClimb = true,
		coldLevel = "None",
	}

	-- Fatigue and hunger shrink the stamina pool.
	m.maxStamina = S.Max * (1 - (state.fatigue / 100) * S.FatiguePenaltyAtMax)
	if state.hunger <= 0 then
		m.maxStamina -= S.HungerPenalty
	end

	local hungerCfg, thirstCfg, fatigueCfg = SurvivalConfig.Hunger, SurvivalConfig.Thirst, SurvivalConfig.Fatigue
	if state.hunger < hungerCfg.LowThreshold then
		m.staminaRegenMult *= 0.6
	end
	if state.thirst < thirstCfg.LowThreshold then
		m.staminaRegenMult *= 0.5
		m.staminaCostMult *= 1.15
	end
	if state.fatigue > fatigueCfg.ExhaustedThreshold then
		m.moveMult *= 0.8
		m.staminaRegenMult *= 0.6
	elseif state.fatigue > fatigueCfg.HighThreshold then
		m.moveMult *= 0.9
	end

	-- Cold.
	local level = WarmthModel.coldLevel(SurvivalModel.overallWarmth(state))
	m.coldLevel = level
	if level == "Moderate" then
		m.staminaRegenMult *= 0.75
	elseif level == "Severe" then
		m.staminaRegenMult *= 0.55
		m.moveMult *= 0.85
		m.climbCostMult *= 1.3
	elseif level == "Critical" then
		m.staminaRegenMult *= 0.3
		m.moveMult *= 0.6
		m.canClimb = false
		m.canSprint = false
	end
	-- Cold hands specifically make gripping harder, even if the core is fine.
	local hands = state.warmth.Hands or 100
	if hands < 30 then
		m.climbCostMult *= 1 + (30 - hands) / 30 * 0.5
	end

	-- Thin air.
	local oxygenFactor = state.oxygen / 100
	m.staminaCostMult *= 1 + (1 - oxygenFactor) * 0.8
	m.staminaRegenMult *= oxygenFactor
	if state.altitudeSickness > SurvivalConfig.AltitudeSickness.SymptomThreshold then
		m.moveMult *= 0.9
		m.staminaRegenMult *= 0.8
	end

	-- Weight.
	local wMove, wCost, wSprint, wClimb = SurvivalModel.weightEffects(weightRatio)
	m.moveMult *= wMove
	m.staminaCostMult *= wCost
	m.canSprint = m.canSprint and wSprint
	m.canClimb = m.canClimb and wClimb

	-- Injuries.
	local inj = InjuryModel.combine(state.injuries)
	m.moveMult *= inj.moveMult
	m.sprintCostMult *= inj.sprintCostMult
	m.climbCostMult *= inj.climbCostMult
	m.climbSpeedMult *= inj.climbSpeedMult
	m.canSprint = m.canSprint and inj.canSprint
	m.canClimb = m.canClimb and inj.canClimb

	-- Buffs.
	if state.buffs.Electrolytes then
		m.staminaRegenMult *= 1.4
	end

	if state.exhaustedLock then
		m.canSprint = false
		m.canClimb = false
	end

	m.maxStamina = math.max(m.maxStamina, 20)
	return m
end

local function isSpending(exertion: string): boolean
	return exertion == "sprint" or exertion == "climb" or exertion == "carry"
end

-- Advance the simulation. Returns a list of event ids for the service to turn into
-- notifications/effects, and the health change to apply.
function SurvivalModel.step(state: State, ctx: Context, dt: number): ({ string }, number)
	local events: { string } = {}
	local health = 0
	local exertion = ctx.exertion
	local injuries = InjuryModel.combine(state.injuries)

	-- Hunger and thirst.
	local exertionMult = SurvivalConfig.Exertion[exertion] or 1
	local altitudeAbove = math.max(0, ctx.elevationM - GameConfig.BASE_ELEVATION_M) / 1000
	state.hunger -= SurvivalConfig.Hunger.DrainPerSec * exertionMult * injuries.hungerDrainMult * dt
	state.thirst -= SurvivalConfig.Thirst.DrainPerSec * exertionMult * injuries.thirstDrainMult * (1 + altitudeAbove * SurvivalConfig.Thirst.AltitudeDrainPer1000m) * dt
	state.hunger = math.clamp(state.hunger, 0, 100)
	state.thirst = math.clamp(state.thirst, 0, 100)

	-- Fatigue.
	local fatigueCfg = SurvivalConfig.Fatigue
	if exertion == "rest" then
		local rate = fatigueCfg.RestRecoverPerSec * (if ctx.campResting then 2 else 1)
		state.fatigue -= rate * dt
	else
		state.fatigue += fatigueCfg.BaseGainPerSec * dt
		if isSpending(exertion) then
			state.fatigue += fatigueCfg.ExertionGainPerSec * dt
		end
	end
	state.fatigue = math.clamp(state.fatigue, 0, 100)

	-- Altitude.
	state.oxygen = SurvivalModel.oxygenAt(ctx.elevationM)
	local sick = SurvivalConfig.AltitudeSickness
	if ctx.elevationM > sick.OnsetM and exertion ~= "rest" then
		state.altitudeSickness += sick.GainPerSecPer1000m * ((ctx.elevationM - sick.OnsetM) / 1000 + 0.5) * dt
	else
		state.altitudeSickness -= sick.RecoverPerSec * dt
	end
	state.altitudeSickness = math.clamp(state.altitudeSickness, 0, 100)

	-- Warmth, region by region.
	for _, region in WarmthModel.Regions do
		local felt = WarmthModel.feltTemperature(region, ctx.gear[region], ctx.env, state.wetness)
		if region == "Hands" and state.buffs.HandWarmer then
			felt += 20
		end
		state.warmth[region] = WarmthModel.stepRegion(state.warmth[region], region, felt, dt)
	end
	state.wetness = WarmthModel.stepWetness(state.wetness, ctx.gear, ctx.env, dt)

	-- Frostbite: localized, staged, always recoverable.
	local fb = SurvivalConfig.Frostbite
	for _, region in fb.Regions do
		local w = state.warmth[region]
		local exposure = state.frostExposure[region]
		if w < fb.ExposureWarmth then
			exposure += (fb.ExposureWarmth - w) / fb.ExposureWarmth * dt
		elseif w > fb.RecoverWarmth then
			exposure -= fb.RecoverPerSec * dt
		end
		exposure = math.clamp(exposure, 0, fb.Stage2Exposure + 10)
		state.frostExposure[region] = exposure

		local stage1, stage2 = "Frostbite" .. region .. "1", "Frostbite" .. region .. "2"
		local freezing = w < fb.ExposureWarmth
		if freezing and exposure >= fb.Stage2Exposure and not state.injuries[stage2] then
			InjuryModel.remove(state.injuries, stage1)
			InjuryModel.add(state.injuries, stage2)
			table.insert(events, "Injury:" .. stage2)
		elseif
			freezing
			and exposure >= fb.Stage1Exposure
			and not state.injuries[stage1]
			and not state.injuries[stage2]
		then
			InjuryModel.add(state.injuries, stage1)
			table.insert(events, "Injury:" .. stage1)
		elseif exposure <= 0 and state.injuries[stage1] and w > fb.RecoverWarmth then
			InjuryModel.remove(state.injuries, stage1)
			table.insert(events, "Healed:" .. stage1)
		end
		if w < fb.WarningWarmth and exposure < fb.Stage1Exposure then
			table.insert(events, "Warn:Cold" .. region)
		end
	end

	-- Stamina.
	local mods = SurvivalModel.modifiers(state, ctx.weightRatio)
	if isSpending(exertion) then
		local cost = 0
		if exertion == "sprint" then
			cost = S.SprintCostPerSec * mods.sprintCostMult
		elseif exertion == "climb" then
			cost = S.ClimbCostPerSec * mods.climbCostMult
		elseif exertion == "carry" then
			cost = S.CarryCostPerSec
		end
		state.stamina -= cost * mods.staminaCostMult * dt
		state.staminaCooldown = S.RegenDelay
	else
		state.staminaCooldown = math.max(0, state.staminaCooldown - dt)
		if state.staminaCooldown <= 0 then
			local regen = S.RegenPerSec * mods.staminaRegenMult
			if exertion == "rest" then
				regen *= 2
			end
			state.stamina += regen * dt
		end
	end
	state.stamina = math.clamp(state.stamina, 0, mods.maxStamina)
	if state.stamina <= 0 and not state.exhaustedLock then
		state.exhaustedLock = true
		table.insert(events, "StaminaDepleted")
	elseif state.exhaustedLock and state.stamina >= S.ExhaustedLockoutUntil then
		state.exhaustedLock = false
	end

	-- Health drains.
	if state.hunger <= 0 then
		health -= SurvivalConfig.Hunger.StarvingDamagePerSec * dt
	end
	if state.thirst <= 0 then
		health -= SurvivalConfig.Thirst.DehydratedDamagePerSec * dt
	end
	if mods.coldLevel == "Critical" then
		health -= SurvivalConfig.Warmth.CriticalDamagePerSec * dt
		state.criticalColdTime += dt
		if state.criticalColdTime >= SurvivalConfig.Warmth.CriticalUnconsciousSeconds then
			state.criticalColdTime = 0
			table.insert(events, "Unconscious")
		end
	else
		state.criticalColdTime = math.max(0, state.criticalColdTime - dt * 2)
	end
	health += injuries.healthPerSec * dt

	-- Injury timers.
	for _, id in InjuryModel.step(state.injuries, dt, ctx.campResting) do
		table.insert(events, "Healed:" .. id)
	end

	-- Buff timers.
	for id, remaining in state.buffs do
		remaining -= dt
		if remaining <= 0 then
			state.buffs[id] = nil
		else
			state.buffs[id] = remaining
		end
	end

	return events, health
end

-- Apply an eaten/drunk/used item's effect. Returns health change and treated injuries.
function SurvivalModel.applyUse(state: State, itemId: string, effect: any): (number, { string })
	local health = 0
	if effect.hunger then
		state.hunger = math.clamp(state.hunger + effect.hunger, 0, 100)
	end
	if effect.thirst then
		state.thirst = math.clamp(state.thirst + effect.thirst, 0, 100)
	end
	if effect.fatigue then
		state.fatigue = math.clamp(state.fatigue + effect.fatigue, 0, 100)
	end
	if effect.stamina then
		state.stamina = math.clamp(state.stamina + effect.stamina, 0, S.Max)
		state.staminaCooldown = 0
	end
	if effect.warmthAll then
		for region, value in state.warmth do
			state.warmth[region] = math.clamp(value + effect.warmthAll, 0, 100)
		end
	end
	if effect.warmthRegion then
		for region, amount in effect.warmthRegion do
			state.warmth[region] = math.clamp((state.warmth[region] or 100) + amount, 0, 100)
		end
	end
	if effect.buff then
		state.buffs[effect.buff.id] = effect.buff.duration
	end
	if effect.health then
		health += effect.health
	end
	local treated = InjuryModel.treat(state.injuries, itemId, effect.treats)
	-- Treating severe frostbite also pulls the exposure back below the stage-2 line so it
	-- does not instantly re-trigger.
	local fb = SurvivalConfig.Frostbite
	for _, region in fb.Regions do
		if table.find(treated, "Frostbite" .. region .. "2") then
			state.frostExposure[region] = math.min(state.frostExposure[region], fb.Stage1Exposure + 5)
		end
	end
	return health, treated
end

-- Would using this item do anything at all? Prevents wasting a splint with nothing to splint.
function SurvivalModel.useWouldHelp(
	state: State,
	itemId: string,
	effect: any,
	health: number,
	maxHealth: number
): boolean
	if effect.hunger or effect.thirst or effect.stamina or effect.warmthAll or effect.warmthRegion or effect.buff then
		return true
	end
	if effect.health and health < maxHealth then
		return true
	end
	return #InjuryModel.treatableBy(state.injuries, itemId, effect.treats) > 0
end

return SurvivalModel
