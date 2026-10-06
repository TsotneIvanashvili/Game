--!strict
-- What a player starts with, what the base camp outfitter offers, and how much the
-- supply crates hand out per expedition (prevents infinite free-supply farming).

local LoadoutConfig = {
	-- Worn on first join (and whenever the saved loadout references an unknown item).
	-- Keys are clothing slots and must equal each item's clothing.slot (tests/spec.luau).
	DefaultWorn = {
		BaseLayer = "merino_base",
		Jacket = "expedition_parka_red",
		Pants = "insulated_pants_black",
		Boots = "expedition_boots",
		Gloves = "expedition_gloves",
		Head = "helmet",
		Face = "knit_mask",
		Eyes = "goggles",
	},
	DefaultBackpack = "pack_medium",

	-- Items placed in the pack at spawn: a real starter kit. Entries that are also in
	-- OneOffTools count as already taken from the outfitter this expedition.
	StarterPack = {
		{ itemId = "water_bottle", qty = 1, data = { ml = 1000, treated = true } },
		{ itemId = "thermos", qty = 1, data = { ml = 0, treated = true } },
		{ itemId = "energy_bar", qty = 3 },
		{ itemId = "chocolate", qty = 1 },
		{ itemId = "hand_warmer", qty = 2 },
		{ itemId = "bandage", qty = 1 },
		{ itemId = "lighter", qty = 1 },
		{ itemId = "ice_axe", qty = 1 },
	},

	-- Clothing, packs and tools the outfitter lends. Swapping is free at base camp; the
	-- decision is weight and what you leave behind, not money.
	OutfitterStock = {
		-- head, face, eyes
		"helmet",
		"wool_beanie",
		"knit_mask",
		"balaclava",
		"goggles",
		"storm_goggles",
		-- body
		"cotton_tee",
		"merino_base",
		"expedition_parka_red",
		"expedition_parka_blue",
		"down_suit_top",
		"fleece_jacket",
		"shell_jacket",
		"insulated_parka",
		-- hands, legs, feet
		"expedition_gloves",
		"heated_gloves",
		"liner_gloves",
		"insulated_gloves",
		"insulated_pants_black",
		"hiking_pants",
		"insulated_pants",
		"expedition_boots",
		"insulated_overboots",
		"trail_runners",
		"alpine_boots",
		-- packs
		"daypack_small",
		"pack_medium",
		"pack_large",
		"pack_expedition",
		-- tools (one each per expedition)
		"ice_axe",
		"lighter",
		"thermos",
		"water_bottle",
		"tent_pack",
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
		Camp1 = {
			energy_bar = 2,
			dried_meat = 1,
			hand_warmer = 2,
			bandage = 1,
		},
		Camp2 = {
			energy_bar = 2,
			dried_meat = 1,
			hand_warmer = 2,
			bandage = 1,
			emergency_ration = 1,
			first_aid_kit = 1,
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
	OneOffTools = { ice_axe = true, lighter = true, thermos = true, water_bottle = true, tent_pack = true },
}

return LoadoutConfig
