--!strict
-- Injuries change how you play; none of them just subtract HP and disappear.
-- Every injury has a cure path that does not require dying.

export type InjuryEffect = {
	moveMult: number?,
	sprintCostMult: number?,
	climbCostMult: number?,
	climbSpeedMult: number?,
	canSprint: boolean?,
	canClimb: boolean?,
	healthPerSec: number?,
	hungerDrainMult: number?,
	thirstDrainMult: number?,
}

export type InjuryDef = {
	id: string,
	name: string,
	description: string,
	effect: InjuryEffect,
	splintedEffect: InjuryEffect?, -- replaces `effect` once treated with a splint
	naturalHealSeconds: number?, -- heals on its own after this long (nil = needs treatment)
	healsWithCampRestSeconds: number?, -- resting at a checkpoint camp this long cures it
	removedBy: { string }?, -- item ids that cure it outright
	severity: number, -- 1 minor .. 3 severe (UI colour, rescue priority)
}

local defs: { [string]: InjuryDef } = {
	SprainedAnkle = {
		id = "SprainedAnkle",
		name = "Sprained Ankle",
		description = "Painful to walk on. A splint helps a lot.",
		effect = { moveMult = 0.75, sprintCostMult = 1.6, climbCostMult = 1.2 },
		splintedEffect = { moveMult = 0.92, sprintCostMult = 1.2 },
		naturalHealSeconds = 360,
		healsWithCampRestSeconds = 30,
		severity = 1,
	},
	BrokenLeg = {
		id = "BrokenLeg",
		name = "Broken Leg",
		description = "You cannot climb or sprint. Splint it and get to a camp, or get carried.",
		effect = { moveMult = 0.4, canSprint = false, canClimb = false },
		splintedEffect = { moveMult = 0.62, canSprint = false, canClimb = false },
		healsWithCampRestSeconds = 75,
		severity = 3,
	},
	Bleeding = {
		id = "Bleeding",
		name = "Bleeding",
		description = "Losing blood. Bandage it.",
		effect = { healthPerSec = -0.45 },
		removedBy = { "bandage", "first_aid_kit" },
		severity = 2,
	},
	HandInjury = {
		id = "HandInjury",
		name = "Injured Hand",
		description = "Gripping hurts. Climbing costs much more stamina.",
		effect = { climbCostMult = 1.5, climbSpeedMult = 0.8 },
		naturalHealSeconds = 240,
		healsWithCampRestSeconds = 30,
		removedBy = { "first_aid_kit" },
		severity = 1,
	},
	FrostbiteHands1 = {
		id = "FrostbiteHands1",
		name = "Frostnip (Hands)",
		description = "Fingers numb and clumsy. Warm them at a fire.",
		effect = { climbCostMult = 1.25 },
		severity = 1,
	},
	FrostbiteHands2 = {
		id = "FrostbiteHands2",
		name = "Frostbite (Hands)",
		description = "Fingers white and hard. Needs a first aid kit and warmth.",
		effect = { climbCostMult = 1.6, climbSpeedMult = 0.7 },
		removedBy = { "first_aid_kit" },
		severity = 2,
	},
	FrostbiteFeet1 = {
		id = "FrostbiteFeet1",
		name = "Frostnip (Feet)",
		description = "Toes numb. Warm them at a fire.",
		effect = { moveMult = 0.92 },
		severity = 1,
	},
	FrostbiteFeet2 = {
		id = "FrostbiteFeet2",
		name = "Frostbite (Feet)",
		description = "Toes frozen. Walking is slow. Needs a first aid kit and warmth.",
		effect = { moveMult = 0.8, sprintCostMult = 1.4 },
		removedBy = { "first_aid_kit" },
		severity = 2,
	},
	FrostbiteHead1 = {
		id = "FrostbiteHead1",
		name = "Frostnip (Face)",
		description = "Nose and ears numb. Cover your face, find warmth.",
		effect = {},
		severity = 1,
	},
	FrostbiteHead2 = {
		id = "FrostbiteHead2",
		name = "Frostbite (Face)",
		description = "Frozen skin on nose and ears. Needs a first aid kit and warmth.",
		effect = { healthPerSec = -0.1 },
		removedBy = { "first_aid_kit" },
		severity = 2,
	},
	StomachUpset = {
		id = "StomachUpset",
		name = "Stomach Upset",
		description = "Bad water. You burn through food and water faster for a while.",
		effect = { hungerDrainMult = 1.8, thirstDrainMult = 1.6 },
		naturalHealSeconds = 240,
		severity = 1,
	},
}

return {
	ById = defs,
	-- Chance that drinking untreated stream water upsets your stomach.
	UntreatedWaterSicknessChance = 0.35,
}
