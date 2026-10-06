--!strict
-- Survival tuning. Rates are per second unless the name says otherwise.
-- Philosophy: stats exist to force decisions, not to nag. A well-prepared player should be
-- able to play ~25 minutes of the slice eating twice and drinking three times.

local SurvivalConfig = {
	Stamina = {
		Max = 100,
		RegenPerSec = 14,
		RegenDelay = 1.0,
		SprintCostPerSec = 11,
		ClimbCostPerSec = 7,
		CarryCostPerSec = 3.5,
		JumpCost = 9,
		MinToStartClimb = 15,
		MinToSprint = 5,
		ExhaustedLockoutUntil = 25, -- after hitting 0, sprint/climb locked until stamina recovers to this
		FatiguePenaltyAtMax = 0.45, -- fatigue 100 removes 45% of max stamina
		HungerPenalty = 15, -- flat max-stamina loss while starving
	},

	Hunger = {
		DrainPerSec = 100 / (30 * 60),
		LowThreshold = 25,
		StarvingDamagePerSec = 0.35,
	},

	Thirst = {
		DrainPerSec = 100 / (22 * 60),
		LowThreshold = 25,
		DehydratedDamagePerSec = 0.45,
		AltitudeDrainPer1000m = 0.15, -- extra fraction of drain per 1000 m above base camp
	},

	Fatigue = {
		BaseGainPerSec = 100 / (60 * 60),
		ExertionGainPerSec = 0.22,
		RestRecoverPerSec = 1.5,
		HighThreshold = 70,
		ExhaustedThreshold = 88,
	},

	-- Multipliers on hunger/thirst drain by activity.
	Exertion = {
		idle = 1.0,
		walk = 1.2,
		sprint = 2.2,
		climb = 2.6,
		carry = 2.0,
		rest = 0.7,
	},

	Warmth = {
		ComfortTempC = 8, -- felt temperature at which a region is in balance
		InsulationToCelsius = 6, -- each insulation point is worth this many degrees (tuned for -10..-40 °C)
		WindChillPerMs = 0.7, -- degrees lost per m/s of wind that reaches the skin
		WetnessChillC = 5, -- degrees lost at full wetness
		ExertionHeatC = { idle = 0, walk = 1.5, sprint = 5, climb = 5, carry = 4, rest = 0 },
		WarmRatePerDegree = 0.35,
		MaxWarmDelta = 20,
		CoolRatePerDegree = 0.02,
		-- Extremities lose heat faster, the core slower.
		RegionCoolFactor = { Head = 0.9, Torso = 0.8, Hands = 1.4, Legs = 1.0, Feet = 1.3 },
		RegionWeight = { Head = 0.15, Torso = 0.4, Hands = 0.125, Legs = 0.2, Feet = 0.125 },
		Thresholds = { Mild = 70, Moderate = 50, Severe = 30, Critical = 12 },
		CriticalDamagePerSec = 0.6,
		CriticalUnconsciousSeconds = 20,
	},

	Wetness = {
		RainGainPerSec = 0.02, -- at precipitation 1.0, before waterproofing
		SnowGainPerSec = 0.003,
		WaterGainPerSec = 0.25, -- standing in water
		DryPerSec = 0.004,
		FireDryPerSec = 0.03,
		-- Overdressing while working hard soaks your base layer from the inside.
		SweatAboveFeltC = 30,
		SweatPerDegreePerSec = 0.0003,
	},

	Frostbite = {
		Regions = { "Hands", "Feet", "Head" },
		WarningWarmth = 30,
		ExposureWarmth = 20,
		Stage1Exposure = 15,
		Stage2Exposure = 45,
		RecoverWarmth = 60,
		RecoverPerSec = 1.0,
	},

	Oxygen = {
		ThresholdM = 2500,
		FullLossM = 8000,
		MinOxygen = 35,
	},

	AltitudeSickness = {
		OnsetM = 3000,
		GainPerSecPer1000m = 0.08,
		RecoverPerSec = 0.15,
		SymptomThreshold = 40,
	},

	Fire = {
		HeatRadius = 16,
		MaxHeatC = 28,
	},
}

return SurvivalConfig
