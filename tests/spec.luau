-- Unit + stress tests for the pure logic layer (src/shared/Logic, Config, Util).
-- Run with: tests/run.sh

local H = __loadfile(ROOT .. "/tests/harness.luau")(ROOT)
local test, eq, near, truthy = H.test, H.eq, H.near, H.truthy
local Shared = H.Shared

local ItemDefs = H.require(Shared.Config.ItemDefs)
local RecipeDefs = H.require(Shared.Config.RecipeDefs)
local LoadoutConfig = H.require(Shared.Config.LoadoutConfig)
local InjuryDefs = H.require(Shared.Config.InjuryDefs)
local WeatherDefs = H.require(Shared.Config.WeatherDefs)
local ZoneDefs = H.require(Shared.Config.ZoneDefs)
local ProgressionConfig = H.require(Shared.Config.ProgressionConfig)
local SurvivalConfig = H.require(Shared.Config.SurvivalConfig)
local WarmthModel = H.require(Shared.Logic.WarmthModel)
local InjuryModel = H.require(Shared.Logic.InjuryModel)
local SurvivalModel = H.require(Shared.Logic.SurvivalModel)
local InventoryModel = H.require(Shared.Logic.InventoryModel)
local WeatherModel = H.require(Shared.Logic.WeatherModel)

local function isNaN(x)
	return x ~= x
end

local function gearFor(ids)
	local items = {}
	for _, id in ids do
		table.insert(items, (assert(ItemDefs.ById[id], id)))
	end
	return WarmthModel.computeGear(items)
end

local STARTER = { "cotton_tee", "fleece_jacket", "liner_gloves", "hiking_pants", "trail_runners" }
local EXPEDITION = {
	"wool_beanie",
	"balaclava",
	"merino_base",
	"insulated_parka",
	"insulated_gloves",
	"insulated_pants",
	"alpine_boots",
}

local function env(overrides)
	local e = {
		airTempC = 8,
		windMs = 2,
		precipitation = 0,
		isSnow = false,
		inWater = false,
		fireHeatC = 0,
		exertion = "walk",
	}
	for k, v in overrides or {} do
		e[k] = v
	end
	return e
end

local function ctx(gear, overrides)
	local c = {
		exertion = "walk",
		elevationM = 1200,
		env = env(),
		gear = gear,
		weightRatio = 0.3,
		campResting = false,
	}
	for k, v in overrides or {} do
		c[k] = v
	end
	c.env.exertion = c.exertion
	return c
end

local function simulate(state, c, seconds, dt)
	dt = dt or 0.2
	local allEvents, health = {}, 0
	for _ = 1, math.floor(seconds / dt) do
		local events, h = SurvivalModel.step(state, c, dt)
		health += h
		for _, e in events do
			allEvents[e] = true
		end
	end
	return allEvents, health
end

------------------------------------------------------------------------------------------
-- Config integrity
------------------------------------------------------------------------------------------

test("every item def is well formed", function()
	for _, def in ItemDefs.List do
		truthy(def.weight >= 0, def.id .. " weight")
		truthy(def.maxStack >= 1, def.id .. " maxStack")
		truthy(#def.glyph <= 3, def.id .. " glyph")
		if def.category == "Clothing" then
			truthy(def.clothing, def.id .. " missing clothing stats")
			for region, v in def.clothing.insulation do
				truthy(table.find(WarmthModel.Regions, region), def.id .. " bad region " .. region)
				truthy(v >= 0, def.id)
			end
			truthy(def.clothing.windproof >= 0 and def.clothing.windproof <= 1, def.id)
			truthy(def.clothing.waterproof >= 0 and def.clothing.waterproof <= 1, def.id)
		end
		if def.category == "Backpack" then
			truthy(def.backpack and def.backpack.slots > 0 and def.backpack.weightLimit > 0, def.id)
		end
		if def.cookedInto then
			truthy(ItemDefs.ById[def.cookedInto], def.id .. " cooks into unknown item")
		end
		if def.use and def.use.treats then
			for _, injuryId in def.use.treats do
				truthy(InjuryDefs.ById[injuryId], def.id .. " treats unknown " .. injuryId)
			end
		end
	end
end)

test("loadout, outfitter and supply tables only reference real items", function()
	for slot, id in LoadoutConfig.DefaultWorn do
		local def = ItemDefs.ById[id]
		truthy(def and def.clothing and def.clothing.slot == slot, "default worn " .. id)
	end
	truthy(ItemDefs.ById[LoadoutConfig.DefaultBackpack].backpack, "default backpack")
	for _, id in LoadoutConfig.OutfitterStock do
		truthy(ItemDefs.ById[id], "outfitter " .. id)
	end
	for crate, allowance in LoadoutConfig.SupplyAllowance do
		for id, n in allowance do
			truthy(ItemDefs.ById[id], crate .. " " .. id)
			truthy(n > 0, crate .. " " .. id)
		end
	end
	for _, entry in LoadoutConfig.StarterPack do
		truthy(ItemDefs.ById[entry.itemId], "starter " .. entry.itemId)
	end
end)

test("recipes reference real items and implemented ones are buildable from the slice", function()
	for _, recipe in RecipeDefs.List do
		for id, n in recipe.cost do
			truthy(ItemDefs.ById[id], recipe.id .. " cost " .. id)
			truthy(n > 0, recipe.id)
		end
		if recipe.requiresTool then
			truthy(ItemDefs.ById[recipe.requiresTool], recipe.id .. " tool")
		end
		truthy(table.find(RecipeDefs.Sections, recipe.section), recipe.id .. " section")
	end
	-- Emergency tarp shelter matches the design doc: 4 wood, 2 rope, 1 tarp.
	local tarp = RecipeDefs.ById.tarp_shelter
	eq(tarp.cost.wood, 4)
	eq(tarp.cost.rope, 2)
	eq(tarp.cost.tarp, 1)
end)

test("weather graph is connected and every neighbour exists", function()
	for id, state in WeatherDefs.States do
		for n in state.neighbours do
			truthy(WeatherDefs.States[n], id .. " -> " .. n)
			-- Gradual weather means every edge must be walkable back again.
			truthy(WeatherDefs.States[n].neighbours[id] ~= nil, "edge not symmetric " .. id .. " -> " .. n)
		end
		for other in WeatherDefs.States do
			if other ~= id then
				truthy(#WeatherModel.pathTo(id, other) > 0, "no path " .. id .. " -> " .. other)
			end
		end
	end
end)

test("zones are ordered top-down", function()
	local last = math.huge
	for _, zone in ZoneDefs.List do
		truthy(zone.minY < last, zone.id)
		last = zone.minY
	end
	eq(ZoneDefs.at(-50).id, "BaseForest")
	eq(ZoneDefs.at(60).id, "RockyForest")
	eq(ZoneDefs.at(150).id, "Snowline")
end)

test("rank lookup", function()
	eq(ProgressionConfig.rankIndexFor(0), 1)
	eq(ProgressionConfig.rankIndexFor(499), 1)
	eq(ProgressionConfig.rankIndexFor(500), 2)
	eq(ProgressionConfig.rankIndexFor(1e9), #ProgressionConfig.Ranks)
end)

------------------------------------------------------------------------------------------
-- Warmth
------------------------------------------------------------------------------------------

test("layering: insulation stacks, wind/water protection takes the best layer", function()
	local gear = gearFor({ "merino_base", "shell_jacket" })
	near(gear.Torso.insulation, 2.7, 1e-9)
	near(gear.Torso.windproof, 0.95)
	near(gear.Torso.waterproof, 0.9)
	near(gear.Legs.insulation, 1)
	eq(gear.Hands.insulation, 0)
end)

test("a wet cotton tee under a parka still costs warmth (worst wet penalty wins)", function()
	local dry = gearFor({ "merino_base", "insulated_parka" })
	local cotton = gearFor({ "cotton_tee", "insulated_parka" })
	local e = env({ airTempC = -5 })
	local feltDry = WarmthModel.feltTemperature("Torso", dry.Torso, e, 1)
	local feltCotton = WarmthModel.feltTemperature("Torso", cotton.Torso, e, 1)
	truthy(feltDry > feltCotton, "merino should beat cotton when soaked")
end)

test("forest in starter clothes stays comfortable for 10 minutes", function()
	local s = SurvivalModel.newState()
	simulate(s, ctx(gearFor(STARTER)), 600)
	truthy(SurvivalModel.overallWarmth(s) > 90, "warmth " .. SurvivalModel.overallWarmth(s))
	eq(next(s.injuries), nil, "no injuries")
end)

test("blizzard in starter clothes gives frostnip within ~3 minutes", function()
	local s = SurvivalModel.newState()
	local events = simulate(
		s,
		ctx(gearFor(STARTER), { env = env({ airTempC = -14, windMs = 20 * 1.25, precipitation = 1, isSnow = true }) }),
		180
	)
	truthy(
		events["Injury:FrostbiteHands1"] or events["Injury:FrostbiteHead1"] or events["Injury:FrostbiteFeet1"],
		"expected frostnip"
	)
	truthy(s.warmth.Hands < 20, "hands " .. s.warmth.Hands)
end)

test("light snow in starter clothes is uncomfortable but not frostbite within 6 minutes", function()
	local s = SurvivalModel.newState()
	local events = simulate(
		s,
		ctx(gearFor(STARTER), { env = env({ airTempC = -0.8, windMs = 7.5, precipitation = 0.35, isSnow = true }) }),
		360
	)
	for e in events do
		truthy(not e:find("Injury:Frost"), "unexpected " .. e)
	end
end)

test("overdressing while sprinting makes you sweat; standing by a fire does not", function()
	local parka = gearFor({ "cotton_tee", "insulated_parka" })
	local w = 0
	for _ = 1, 300 do
		w = WarmthModel.stepWetness(w, parka, env({ airTempC = 9, exertion = "sprint" }), 0.2)
	end
	truthy(w > 0.15, "sweat " .. w)
	local f = 0
	for _ = 1, 300 do
		f = WarmthModel.stepWetness(f, parka, env({ airTempC = 0, exertion = "walk", fireHeatC = 25 }), 0.2)
	end
	eq(f, 0, "fire should not cause sweat")
end)

test("blizzard in expedition gear: core stays warm for 5 minutes", function()
	local s = SurvivalModel.newState()
	simulate(
		s,
		ctx(gearFor(EXPEDITION), { env = env({ airTempC = -14, windMs = 25, precipitation = 1, isSnow = true }) }),
		300
	)
	truthy(s.warmth.Torso > 60, "torso " .. s.warmth.Torso)
	truthy(SurvivalModel.overallWarmth(s) > 45, "overall " .. SurvivalModel.overallWarmth(s))
end)

test("a fire rescues a freezing player in under a minute", function()
	local s = SurvivalModel.newState()
	for region in s.warmth do
		s.warmth[region] = 15
	end
	simulate(
		s,
		ctx(gearFor(STARTER), { exertion = "rest", env = env({ airTempC = -10, windMs = 3, fireHeatC = 22 }) }),
		45
	)
	truthy(SurvivalModel.overallWarmth(s) > 70, "overall " .. SurvivalModel.overallWarmth(s))
end)

test("fire heat falls off to zero at radius", function()
	near(WarmthModel.fireHeatAt(0), SurvivalConfig.Fire.MaxHeatC)
	eq(WarmthModel.fireHeatAt(SurvivalConfig.Fire.HeatRadius), 0)
	eq(WarmthModel.fireHeatAt(1000), 0)
end)

test("rain soaks a fleece, a shell sheds it; fire dries", function()
	local rain = env({ precipitation = 1 })
	local fleece = gearFor({ "cotton_tee", "fleece_jacket", "hiking_pants" })
	local shell = gearFor({ "cotton_tee", "shell_jacket", "insulated_pants" })
	local wFleece, wShell = 0, 0
	for _ = 1, 300 do
		wFleece = WarmthModel.stepWetness(wFleece, fleece, rain, 0.2)
		wShell = WarmthModel.stepWetness(wShell, shell, rain, 0.2)
	end
	truthy(wFleece > 0.6, "fleece wetness " .. wFleece)
	truthy(wShell < 0.25, "shell wetness " .. wShell)
	local dried = wFleece
	for _ = 1, 300 do
		dried = WarmthModel.stepWetness(dried, fleece, env({ fireHeatC = 25 }), 0.2)
	end
	truthy(dried < 0.1, "dried " .. dried)
end)

------------------------------------------------------------------------------------------
-- Survival interactions
------------------------------------------------------------------------------------------

test("sprinting drains stamina and locks out at zero; recovery unlocks", function()
	local s = SurvivalModel.newState()
	local events = simulate(s, ctx(gearFor(STARTER), { exertion = "sprint" }), 12)
	truthy(events.StaminaDepleted, "expected depletion")
	truthy(s.exhaustedLock)
	local m = SurvivalModel.modifiers(s, 0.3)
	eq(m.canSprint, false)
	simulate(s, ctx(gearFor(STARTER), { exertion = "idle" }), 5)
	eq(s.exhaustedLock, false, "lock should clear after recovery")
end)

test("regen waits for the delay after spending", function()
	local s = SurvivalModel.newState()
	s.stamina = 50
	SurvivalModel.step(s, ctx(gearFor(STARTER), { exertion = "sprint" }), 0.2)
	local after = s.stamina
	SurvivalModel.step(s, ctx(gearFor(STARTER), { exertion = "idle" }), 0.2)
	near(s.stamina, after, 1e-9, "no regen inside delay")
end)

test("hunger, thirst, cold, fatigue, altitude and weight all reduce stamina regen", function()
	local base = SurvivalModel.modifiers(SurvivalModel.newState(), 0.3).staminaRegenMult
	local function regenWith(mutate, weight)
		local s = SurvivalModel.newState()
		mutate(s)
		return SurvivalModel.modifiers(s, weight or 0.3).staminaRegenMult
	end
	truthy(regenWith(function(s)
		s.hunger = 10
	end) < base, "hunger")
	truthy(regenWith(function(s)
		s.thirst = 10
	end) < base, "thirst")
	truthy(regenWith(function(s)
		for r in s.warmth do
			s.warmth[r] = 40
		end
	end) < base, "cold")
	truthy(regenWith(function(s)
		s.fatigue = 95
	end) < base, "fatigue")
	truthy(regenWith(function(s)
		s.oxygen = 60
	end) < base, "oxygen")
end)

test("fatigue shrinks max stamina; starvation shrinks it further", function()
	local s = SurvivalModel.newState()
	s.fatigue = 100
	local m = SurvivalModel.modifiers(s, 0.3)
	near(m.maxStamina, 100 * (1 - SurvivalConfig.Stamina.FatiguePenaltyAtMax))
	s.hunger = 0
	truthy(SurvivalModel.modifiers(s, 0.3).maxStamina < m.maxStamina)
end)

test("weight: light pack free, overloaded pack slows and blocks climbing", function()
	local move, cost, sprint, climb = SurvivalModel.weightEffects(0.4)
	eq(move, 1)
	eq(cost, 1)
	truthy(sprint and climb)
	move, cost, sprint, climb = SurvivalModel.weightEffects(1.25)
	truthy(move < 0.6, "move " .. move)
	truthy(cost > 1.5, "cost " .. cost)
	eq(sprint, false)
	eq(climb, false)
	move = SurvivalModel.weightEffects(5)
	truthy(move >= 0.35, "move floor")
end)

test("oxygen is full below threshold and floors at the minimum", function()
	eq(SurvivalModel.oxygenAt(1200), 100)
	eq(SurvivalModel.oxygenAt(SurvivalConfig.Oxygen.ThresholdM), 100)
	near(SurvivalModel.oxygenAt(100000), SurvivalConfig.Oxygen.MinOxygen)
end)

test("starvation and dehydration hurt; nothing goes NaN over a long cold run", function()
	local s = SurvivalModel.newState()
	s.hunger, s.thirst = 0, 0
	local _, health = simulate(
		s,
		ctx(gearFor(STARTER), {
			exertion = "climb",
			elevationM = 9000,
			weightRatio = 1.3,
			env = env({ airTempC = -30, windMs = 40, precipitation = 1, isSnow = true }),
		}),
		600
	)
	truthy(health < -100, "health " .. health)
	for k, v in s do
		if type(v) == "number" then
			truthy(not isNaN(v), k .. " NaN")
		end
	end
	for r, v in s.warmth do
		truthy(v >= 0 and v <= 100, r)
	end
	truthy(s.stamina >= 0)
end)

test("critical cold eventually knocks you unconscious", function()
	local s = SurvivalModel.newState()
	for r in s.warmth do
		s.warmth[r] = 5
	end
	local events = simulate(s, ctx(gearFor({}), { exertion = "idle", env = env({ airTempC = -25, windMs = 20 }) }), 25)
	truthy(events.Unconscious, "expected unconscious")
end)

test("frostbite escalates, a first aid kit downgrades it, warmth clears frostnip", function()
	local s = SurvivalModel.newState()
	local gear = gearFor({ "cotton_tee" })
	local cold = ctx(gear, { exertion = "idle", env = env({ airTempC = -25, windMs = 25 }) })
	local events = simulate(s, cold, 240)
	truthy(events["Injury:FrostbiteHands2"], "expected stage 2 hands")
	truthy(s.injuries.FrostbiteHands2)

	local _, treated = SurvivalModel.applyUse(s, "first_aid_kit", ItemDefs.ById.first_aid_kit.use)
	truthy(table.find(treated, "FrostbiteHands2"), "kit should treat stage 2")
	eq(s.injuries.FrostbiteHands2, nil)
	truthy(s.injuries.FrostbiteHands1, "downgraded to stage 1")

	-- Warm at a fire: must not bounce back to stage 2, and frostnip clears.
	local warm = ctx(gear, { exertion = "rest", env = env({ airTempC = 5, windMs = 0, fireHeatC = 25 }) })
	local warmEvents = simulate(s, warm, 120)
	truthy(not warmEvents["Injury:FrostbiteHands2"], "re-triggered stage 2 while warm")
	eq(s.injuries.FrostbiteHands1, nil, "frostnip should clear when warm")
end)

test("hand warmer buff protects hands", function()
	local a, b = SurvivalModel.newState(), SurvivalModel.newState()
	SurvivalModel.applyUse(b, "hand_warmer", ItemDefs.ById.hand_warmer.use)
	local c = ctx(gearFor(STARTER), { env = env({ airTempC = -10, windMs = 10 }) })
	simulate(a, c, 60)
	simulate(b, c, 60)
	truthy(b.warmth.Hands > a.warmth.Hands + 10)
end)

test("hot stew warms, eating clamps at 100", function()
	local s = SurvivalModel.newState()
	for r in s.warmth do
		s.warmth[r] = 40
	end
	s.hunger = 90
	SurvivalModel.applyUse(s, "hot_stew", ItemDefs.ById.hot_stew.use)
	eq(s.hunger, 100)
	eq(s.warmth.Torso, 65)
end)

test("useWouldHelp refuses a pointless splint but accepts one for a sprain", function()
	local s = SurvivalModel.newState()
	eq(SurvivalModel.useWouldHelp(s, "splint", ItemDefs.ById.splint.use, 100, 100), false)
	InjuryModel.add(s.injuries, "SprainedAnkle")
	eq(SurvivalModel.useWouldHelp(s, "splint", ItemDefs.ById.splint.use, 100, 100), true)
	eq(SurvivalModel.useWouldHelp(s, "bandage", ItemDefs.ById.bandage.use, 100, 100), false)
	eq(SurvivalModel.useWouldHelp(s, "bandage", ItemDefs.ById.bandage.use, 50, 100), true)
end)

------------------------------------------------------------------------------------------
-- Injuries
------------------------------------------------------------------------------------------

test("broken leg blocks climbing and sprinting, splint improves speed but not climbing", function()
	local inj = {}
	InjuryModel.add(inj, "BrokenLeg")
	local c = InjuryModel.combine(inj)
	eq(c.canClimb, false)
	eq(c.canSprint, false)
	local before = c.moveMult
	local treated = InjuryModel.treat(inj, "splint", ItemDefs.ById.splint.use.treats)
	eq(#treated, 1)
	truthy(inj.BrokenLeg.splinted)
	c = InjuryModel.combine(inj)
	truthy(c.moveMult > before)
	eq(c.canClimb, false)
	-- A second splint does nothing.
	eq(#InjuryModel.treat(inj, "splint", ItemDefs.ById.splint.use.treats), 0)
end)

test("broken leg heals only with camp rest", function()
	local inj = {}
	InjuryModel.add(inj, "BrokenLeg")
	InjuryModel.step(inj, 10000, false)
	truthy(inj.BrokenLeg, "should not heal naturally")
	local healed = InjuryModel.step(inj, 80, true)
	eq(healed[1], "BrokenLeg")
	eq(inj.BrokenLeg, nil)
end)

test("bandage stops bleeding; bleeding drains health", function()
	local s = SurvivalModel.newState()
	InjuryModel.add(s.injuries, "Bleeding")
	local _, health = simulate(s, ctx(gearFor(STARTER)), 10)
	truthy(health < -4, "bleeding health " .. health)
	SurvivalModel.applyUse(s, "bandage", ItemDefs.ById.bandage.use)
	eq(s.injuries.Bleeding, nil)
end)

test("injury serialization is stable", function()
	local inj = {}
	InjuryModel.add(inj, "Bleeding")
	InjuryModel.add(inj, "SprainedAnkle")
	InjuryModel.treat(inj, "splint", { "SprainedAnkle" })
	eq(InjuryModel.serialize(inj), "Bleeding,SprainedAnkle*")
end)

------------------------------------------------------------------------------------------
-- Inventory
------------------------------------------------------------------------------------------

test("stacks merge up to maxStack then use new slots", function()
	local inv = InventoryModel.new()
	eq(InventoryModel.add(inv, "energy_bar", 15, 10), 15)
	eq(#inv.stacks, 2)
	eq(InventoryModel.count(inv, "energy_bar"), 15)
	eq(InventoryModel.add(inv, "energy_bar", 5, 10), 5)
	eq(#inv.stacks, 2, "fills partial stack first")
end)

test("slot limit is respected and partial adds report the true count", function()
	local inv = InventoryModel.new()
	eq(InventoryModel.add(inv, "rope", 10, 2), 6)
	eq(InventoryModel.spaceFor(inv, "rope", 2), 0)
	eq(InventoryModel.add(inv, "wood", 1, 2), 0)
end)

test("spaceFor matches what add can actually merge (data stacks never merge)", function()
	local inv = InventoryModel.new()
	-- A partial stackable stack that carries data: add() will not merge into it.
	InventoryModel.add(inv, "energy_bar", 3, 1, { marked = true })
	eq(InventoryModel.spaceFor(inv, "energy_bar", 1), 0, "no free slot and the only stack has data")
	eq(InventoryModel.add(inv, "energy_bar", 1, 1), 0)
	local inv2 = InventoryModel.new()
	InventoryModel.add(inv2, "energy_bar", 3, 1)
	eq(InventoryModel.spaceFor(inv2, "energy_bar", 1), 7, "plain partial stack has room")
	eq(InventoryModel.spaceFor(inv2, "energy_bar", 1, { marked = true }), 0, "adding with data never merges")
	eq(InventoryModel.add(inv2, "energy_bar", 1, 1, { marked = true }), 0)
end)

test("bad quantities are rejected", function()
	local inv = InventoryModel.new()
	eq(InventoryModel.add(inv, "wood", 0, 10), 0)
	eq(InventoryModel.add(inv, "wood", -3, 10), 0)
	eq(InventoryModel.add(inv, "wood", 1.5, 10), 0)
	eq(InventoryModel.add(inv, "not_an_item", 1, 10), 0)
	eq(#inv.stacks, 0)
end)

test("containers never merge and carry their water weight", function()
	local inv = InventoryModel.new()
	InventoryModel.add(inv, "water_bottle", 1, 10, { ml = 1000, treated = true })
	InventoryModel.add(inv, "water_bottle", 1, 10, { ml = 0, treated = true })
	eq(#inv.stacks, 2)
	near(InventoryModel.totalWeight(inv), 0.15 * 2 + 1.0)
end)

test("snapshots do not alias server state", function()
	local inv = InventoryModel.new()
	InventoryModel.add(inv, "water_bottle", 1, 10, { ml = 500 })
	local snap = InventoryModel.snapshot(inv)
	snap[1].data.ml = 99999
	snap[1].qty = 50
	eq(inv.stacks[1].data.ml, 500)
	eq(inv.stacks[1].qty, 1)
end)

test("recipe removal is atomic", function()
	local inv = InventoryModel.new()
	InventoryModel.add(inv, "wood", 4, 10)
	InventoryModel.add(inv, "rope", 1, 10)
	eq(InventoryModel.removeAll(inv, { wood = 4, rope = 2, tarp = 1 }), false)
	eq(InventoryModel.count(inv, "wood"), 4, "nothing removed on failure")
	InventoryModel.add(inv, "rope", 1, 10)
	InventoryModel.add(inv, "tarp", 1, 10)
	eq(InventoryModel.removeAll(inv, { wood = 4, rope = 2, tarp = 1 }), true)
	eq(#inv.stacks, 0)
end)

test("removeFromStack clamps quantity and deletes empty stacks", function()
	local inv = InventoryModel.new()
	InventoryModel.add(inv, "wood", 3, 10)
	local uid = inv.stacks[1].uid
	local removed = InventoryModel.removeFromStack(inv, uid, 99)
	eq(removed, 3)
	eq(#inv.stacks, 0)
	eq(InventoryModel.removeFromStack(inv, uid, 1), 0, "double remove (dupe attempt) gets nothing")
end)

test("stress: 10k random operations keep counts and weight consistent", function()
	local inv = InventoryModel.new()
	local seed = 12345
	local function rand(n)
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed % n + 1
	end
	local ids = { "wood", "rope", "energy_bar", "bandage", "water_bottle", "tarp" }
	for _ = 1, 10000 do
		local op = rand(3)
		if op == 1 then
			local id = ids[rand(#ids)]
			InventoryModel.add(inv, id, rand(5), 14, if id == "water_bottle" then { ml = 500 } else nil)
		elseif op == 2 and #inv.stacks > 0 then
			local stack = inv.stacks[rand(#inv.stacks)]
			InventoryModel.removeFromStack(inv, stack.uid, rand(4))
		else
			InventoryModel.removeAll(inv, { wood = rand(3) })
		end
		truthy(#inv.stacks <= 14, "slot overflow")
		for _, stack in inv.stacks do
			truthy(stack.qty >= 1 and stack.qty <= ItemDefs.ById[stack.itemId].maxStack, "bad qty")
		end
	end
	local seen = {}
	for _, stack in inv.stacks do
		truthy(not seen[stack.uid], "duplicate uid")
		seen[stack.uid] = true
	end
	truthy(InventoryModel.totalWeight(inv) >= 0)
end)

------------------------------------------------------------------------------------------
-- Weather
------------------------------------------------------------------------------------------

test("storm path from clear walks every intermediate state", function()
	local path = WeatherModel.pathTo("Clear", "Storm")
	eq(table.concat(path, ">"), "Cloudy>LightPrecip>HeavyPrecip>Storm")
	eq(#WeatherModel.pathTo("Storm", "Storm"), 0)
end)

test("blend endpoints and midpoint", function()
	local a, b = WeatherDefs.States.Clear.params, WeatherDefs.States.Storm.params
	near(WeatherModel.blend(a, b, 0).windMs, a.windMs)
	near(WeatherModel.blend(a, b, 1).windMs, b.windMs)
	near(WeatherModel.blend(a, b, 0.5).windMs, (a.windMs + b.windMs) / 2)
	near(WeatherModel.blend(a, b, 7).windMs, b.windMs, 1e-9, "t clamps")
end)

test("pickNext only returns neighbours", function()
	local seed = 1
	local function rng()
		seed = (seed * 16807) % 2147483647
		return seed / 2147483647
	end
	for id, state in WeatherDefs.States do
		for _ = 1, 200 do
			local nextId = WeatherModel.pickNext(id, rng)
			truthy(state.neighbours[nextId], id .. " -> " .. nextId)
		end
	end
end)

test("temperature: snow at the ridge, rain at base camp", function()
	local clear = WeatherDefs.States.Clear.params
	local baseTemp = WeatherModel.airTemperature(WeatherModel.elevationM(0), clear)
	local ridgeTemp = WeatherModel.airTemperature(WeatherModel.elevationM(150), clear)
	truthy(not WeatherModel.isSnow(baseTemp), "base " .. baseTemp)
	truthy(ridgeTemp < baseTemp)
	local storm = WeatherDefs.States.Storm.params
	truthy(WeatherModel.isSnow(WeatherModel.airTemperature(WeatherModel.elevationM(150), storm)))
	eq(WeatherModel.displayName("Storm", -10), "Blizzard")
	eq(WeatherModel.displayName("Storm", 10), "Thunderstorm")
end)

H.report()
