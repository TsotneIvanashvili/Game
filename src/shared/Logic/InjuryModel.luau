--!strict
-- Pure injury bookkeeping: adding, treating, healing over time, and the combined gameplay
-- modifiers of everything a player is suffering from.

local InjuryDefs = require(script.Parent.Parent.Config.InjuryDefs)

export type Injury = {
	id: string,
	age: number, -- seconds since received
	splinted: boolean,
	campRest: number, -- seconds rested at a checkpoint camp while injured
}

export type Injuries = { [string]: Injury }

export type Combined = {
	moveMult: number,
	sprintCostMult: number,
	climbCostMult: number,
	climbSpeedMult: number,
	canSprint: boolean,
	canClimb: boolean,
	healthPerSec: number,
	hungerDrainMult: number,
	thirstDrainMult: number,
}

local InjuryModel = {}

function InjuryModel.add(injuries: Injuries, id: string): boolean
	assert(InjuryDefs.ById[id], "unknown injury " .. id)
	if injuries[id] then
		injuries[id].age = 0 -- re-injury resets natural healing
		return false
	end
	injuries[id] = { id = id, age = 0, splinted = false, campRest = 0 }
	return true
end

function InjuryModel.remove(injuries: Injuries, id: string)
	injuries[id] = nil
end

function InjuryModel.has(injuries: Injuries, id: string): boolean
	return injuries[id] ~= nil
end

-- Which injuries this item would help with. Splints don't remove fractures; they set
-- `splinted`. Returns the ids affected (empty = item would do nothing).
function InjuryModel.treatableBy(injuries: Injuries, itemId: string, treats: { string }?): { string }
	local result = {}
	if not treats then
		return result
	end
	for _, injuryId in treats do
		local injury = injuries[injuryId]
		if injury then
			local def = InjuryDefs.ById[injuryId]
			local removable = def.removedBy and table.find(def.removedBy, itemId) ~= nil
			local splintable = def.splintedEffect ~= nil and not injury.splinted and itemId == "splint"
			if removable or splintable then
				table.insert(result, injuryId)
			end
		end
	end
	return result
end

function InjuryModel.treat(injuries: Injuries, itemId: string, treats: { string }?): { string }
	local affected = InjuryModel.treatableBy(injuries, itemId, treats)
	for _, injuryId in affected do
		local def = InjuryDefs.ById[injuryId]
		if def.removedBy and table.find(def.removedBy, itemId) then
			injuries[injuryId] = nil
		else
			injuries[injuryId].splinted = true
		end
	end
	-- A first aid kit downgrades severe frostbite to frostnip rather than erasing it outright.
	if itemId == "first_aid_kit" then
		for _, region in { "Hands", "Feet", "Head" } do
			if table.find(affected, "Frostbite" .. region .. "2") then
				injuries["Frostbite" .. region .. "1"] =
					{ id = "Frostbite" .. region .. "1", age = 0, splinted = false, campRest = 0 }
			end
		end
	end
	return affected
end

-- Advance timers. `campResting` is true while resting inside a checkpoint camp.
-- Returns the ids that healed this step.
function InjuryModel.step(injuries: Injuries, dt: number, campResting: boolean): { string }
	local healed = {}
	for id, injury in injuries do
		injury.age += dt
		local def = InjuryDefs.ById[id]
		if campResting then
			injury.campRest += dt
		end
		local naturallyHealed = def.naturalHealSeconds ~= nil and injury.age >= def.naturalHealSeconds
		local restHealed = def.healsWithCampRestSeconds ~= nil and injury.campRest >= def.healsWithCampRestSeconds
		if naturallyHealed or restHealed then
			table.insert(healed, id)
		end
	end
	for _, id in healed do
		injuries[id] = nil
	end
	return healed
end

function InjuryModel.combine(injuries: Injuries): Combined
	local c: Combined = {
		moveMult = 1,
		sprintCostMult = 1,
		climbCostMult = 1,
		climbSpeedMult = 1,
		canSprint = true,
		canClimb = true,
		healthPerSec = 0,
		hungerDrainMult = 1,
		thirstDrainMult = 1,
	}
	for id, injury in injuries do
		local def = InjuryDefs.ById[id]
		local e = if injury.splinted and def.splintedEffect then def.splintedEffect else def.effect
		c.moveMult *= e.moveMult or 1
		c.sprintCostMult *= e.sprintCostMult or 1
		c.climbCostMult *= e.climbCostMult or 1
		c.climbSpeedMult *= e.climbSpeedMult or 1
		c.healthPerSec += e.healthPerSec or 0
		c.hungerDrainMult *= e.hungerDrainMult or 1
		c.thirstDrainMult *= e.thirstDrainMult or 1
		if e.canSprint == false then
			c.canSprint = false
		end
		if e.canClimb == false then
			c.canClimb = false
		end
	end
	return c
end

-- Compact form for replication as a string attribute: "BrokenLeg*,Bleeding" (* = splinted).
function InjuryModel.serialize(injuries: Injuries): string
	local parts = {}
	for id, injury in injuries do
		table.insert(parts, if injury.splinted then id .. "*" else id)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

return InjuryModel
