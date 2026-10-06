--!strict
-- Build Book. Every section from the design is listed so the book reads complete; only
-- recipes with `implemented = true` can be placed. The UI shows the rest as
-- "Blueprint missing" pages so players know there is more to find.

export type Recipe = {
	id: string,
	name: string,
	section: "Fire" | "Shelters" | "Climbing" | "Survival" | "Navigation" | "Advanced",
	description: string,
	cost: { [string]: number },
	requiresTool: string?, -- item that must be in the pack (not consumed except durability)
	toolDurabilityCost: number?,
	footprint: Vector3, -- studs, used for overlap checks and the placement ghost
	maxSlope: number, -- degrees
	unlockedByDefault: boolean,
	implemented: boolean,
	buildSeconds: number,
}

local function r(t: Recipe): Recipe
	return t
end

local list: { Recipe } = {
	r({
		id = "campfire",
		name = "Campfire",
		section = "Fire",
		description = "Three logs and a spark. Warms, dries clothes, boils water, cooks food.",
		cost = { wood = 3 },
		requiresTool = "lighter",
		toolDurabilityCost = 1,
		footprint = Vector3.new(5, 3, 5),
		maxSlope = 25,
		unlockedByDefault = true,
		implemented = true,
		buildSeconds = 3,
	}),
	r({
		id = "wind_fire",
		name = "Wind-Protected Fire",
		section = "Fire",
		description = "Fire ringed with a stone wall. Burns half as fast in strong wind.",
		cost = { wood = 4 },
		requiresTool = "lighter",
		footprint = Vector3.new(6, 3, 6),
		maxSlope = 20,
		unlockedByDefault = false,
		implemented = false,
		buildSeconds = 5,
	}),
	r({
		id = "tarp_shelter",
		name = "Emergency Tarp Shelter",
		section = "Shelters",
		description = "A-frame tarp on two poles and a ridge line. Blocks most wind and all snow.",
		cost = { wood = 4, rope = 2, tarp = 1 },
		footprint = Vector3.new(10, 7, 12),
		maxSlope = 22, -- must fit the safe ramp (~18.4 deg): that's where storms catch people
		unlockedByDefault = true,
		implemented = true,
		buildSeconds = 6,
	}),
	r({
		id = "wind_wall",
		name = "Wind Wall",
		section = "Shelters",
		description = "Stacked wood break. Cuts wind for anyone standing in its lee.",
		cost = { wood = 5 },
		footprint = Vector3.new(12, 6, 2),
		maxSlope = 22,
		unlockedByDefault = true,
		implemented = true,
		buildSeconds = 4,
	}),
	r({
		id = "snow_shelter",
		name = "Snow Shelter",
		section = "Shelters",
		description = "Dug-out snow trench. Needs a shovel.",
		cost = {},
		footprint = Vector3.new(8, 5, 10),
		maxSlope = 15,
		unlockedByDefault = false,
		implemented = false,
		buildSeconds = 12,
	}),
	r({
		id = "rope_anchor",
		name = "Rope Anchor",
		section = "Climbing",
		description = "Fixed line anchor for team climbing.",
		cost = { rope = 1 },
		footprint = Vector3.new(2, 2, 2),
		maxSlope = 90,
		unlockedByDefault = false,
		implemented = false,
		buildSeconds = 4,
	}),
	r({
		id = "snow_melter",
		name = "Snow Melter",
		section = "Survival",
		description = "Pot rig over a fire that melts snow into water.",
		cost = { wood = 1 },
		footprint = Vector3.new(3, 3, 3),
		maxSlope = 20,
		unlockedByDefault = false,
		implemented = false,
		buildSeconds = 3,
	}),
	r({
		id = "trail_marker",
		name = "Trail Marker",
		section = "Navigation",
		description = "A stake with an orange flag. Visible through fog to your whole team.",
		cost = { wood = 1 },
		footprint = Vector3.new(1, 6, 1),
		maxSlope = 40,
		unlockedByDefault = true,
		implemented = true,
		buildSeconds = 1.5,
	}),
	r({
		id = "signal_fire",
		name = "Signal Fire",
		section = "Navigation",
		description = "A tall smoky fire visible from far below.",
		cost = { wood = 8 },
		requiresTool = "lighter",
		footprint = Vector3.new(6, 6, 6),
		maxSlope = 20,
		unlockedByDefault = false,
		implemented = false,
		buildSeconds = 8,
	}),
	r({
		id = "avalanche_shelter",
		name = "Avalanche Shelter",
		section = "Advanced",
		description = "Reinforced lean-to tucked under rock.",
		cost = { wood = 8, rope = 2 },
		footprint = Vector3.new(10, 8, 10),
		maxSlope = 15,
		unlockedByDefault = false,
		implemented = false,
		buildSeconds = 15,
	}),
}

local byId: { [string]: Recipe } = {}
for _, recipe in list do
	assert(byId[recipe.id] == nil, "duplicate recipe id " .. recipe.id)
	byId[recipe.id] = recipe
end

return {
	List = list,
	ById = byId,
	Sections = { "Fire", "Shelters", "Climbing", "Survival", "Navigation", "Advanced" },
}
