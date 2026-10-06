--!strict
-- What a player starts with, what the base camp outfitter offers, and how much the
-- supply crates hand out per expedition (prevents infinite free-supply farming).

local LoadoutConfig = {
	-- Worn on first join (and whenever the saved loadout references an unknown item).
	DefaultWorn = {
		BaseLayer = "cotton_tee",
		Jacket = "fleece_jacket",
		Gloves = "liner_gloves",
		Pants = "hiking_pants",
		Boots = "trail_runners",
	},
	DefaultBackpack = "daypack_small",

	-- Items placed in the pack at spawn.
	StarterPack = {
		{ itemId = "water_bottle", qty = 1, data = { ml = 1000, treated = true } },
		{ itemId = "energy_bar", qty = 2 },
	},

	-- Clothing, packs and tools the outfitter lends. Swapping is free at base camp; the
	-- decision is weight and what you leave behind, not money.
	OutfitterStock = {
		"wool_beanie",
		"balaclava",
		"cotton_tee",
		"merino_base",
		"fleece_jacket",
		"shell_jacket",
		"insulated_parka",
		"liner_gloves",
		"insulated_gloves",
		"hiking_pants",
		"insulated_pants",
		"trail_runners",
		"alpine_boots",
		"daypack_small",
		"pack_medium",
		"pack_large",
		"pack_expedition",
		"ice_axe",
		"lighter",
		"thermos",
		"water_bottle",
	},

	-- Supply crates: per-player allowance for the whole expedition, per crate type.
	SupplyAllowance = {
		BaseCamp = {
			energy_bar = 4,
			chocolate = 2,
			trail_mix = 2,
			dried_meat = 2,
			canned_stew = 2,
			emergency_ration = 1,
			electrolyte_drink = 1,
			bandage = 3,
			splint = 1,
			first_aid_kit = 1,
			hand_warmer = 3,
			purification_tabs = 4,
			rope = 2,
			tarp = 1,
		},
		RidgeCamp = {
			energy_bar = 2,
			dried_meat = 1,
			hand_warmer = 2,
			bandage = 1,
			emergency_ration = 1,
		},
	},

	-- Tools the outfitter hands out at most once each per expedition.
	OneOffTools = { ice_axe = true, lighter = true, thermos = true, water_bottle = true },
}

return LoadoutConfig
