--!strict
-- Server-authoritative inventory, clothing and backpack. The client only ever sends an
-- intent ("Use stack 7", "Give stack 3 to user 123"); this service checks ownership,
-- range, capacity and weight, mutates PlayerStore, then pushes a fresh snapshot.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local ItemDefs = require(Shared.Config.ItemDefs)
local LoadoutConfig = require(Shared.Config.LoadoutConfig)
local InjuryDefs = require(Shared.Config.InjuryDefs)
local InventoryModel = require(Shared.Logic.InventoryModel)
local SurvivalModel = require(Shared.Logic.SurvivalModel)
local InjuryModel = require(Shared.Logic.InjuryModel)
local Signal = require(Shared.Util.Signal)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)

local InventoryService = {}

InventoryService.Changed = Signal.new() -- (player)

local HOT_DRINK_SECONDS = 150

local function remote()
	return Registry.get("RemoteGuard")
end

-- Weight & capacity ------------------------------------------------------------------------

function InventoryService.packStats(record: PlayerStore.Record): ItemDefs.BackpackStats
	local def = ItemDefs.ById[record.backpackId]
	return (def and def.backpack) or (ItemDefs.ById[LoadoutConfig.DefaultBackpack].backpack :: any)
end

function InventoryService.totalWeight(record: PlayerStore.Record): number
	local total = InventoryModel.totalWeight(record.inventory)
	for _, itemId in record.worn do
		local def = ItemDefs.ById[itemId]
		if def then
			total += def.weight
		end
	end
	local pack = ItemDefs.ById[record.backpackId]
	if pack then
		total += pack.weight
	end
	return total
end

function InventoryService.weightRatio(record: PlayerStore.Record): number
	return InventoryService.totalWeight(record) / InventoryService.packStats(record).weightLimit
end

local function wouldExceedHardCap(record: PlayerStore.Record, addKg: number): boolean
	local limit = InventoryService.packStats(record).weightLimit * InventoryModel.HARD_CAP_RATIO
	return InventoryService.totalWeight(record) + addKg > limit + 1e-6
end

-- Snapshots ---------------------------------------------------------------------------------

function InventoryService.snapshot(record: PlayerStore.Record)
	local pack = InventoryService.packStats(record)
	return {
		stacks = InventoryModel.snapshot(record.inventory),
		worn = table.clone(record.worn),
		backpackId = record.backpackId,
		heldUid = record.heldUid,
		weight = InventoryService.totalWeight(record),
		weightLimit = pack.weightLimit,
		slots = pack.slots,
	}
end

function InventoryService.sync(player: Player)
	local record = PlayerStore.get(player)
	if not record then
		return
	end
	local snap = InventoryService.snapshot(record)
	player:SetAttribute("Weight", math.floor(snap.weight * 10 + 0.5) / 10)
	player:SetAttribute("WeightLimit", snap.weightLimit)
	player:SetAttribute(
		"HeldItem",
		if record.heldUid then (InventoryModel.find(record.inventory, record.heldUid) or {} :: any).itemId else nil
	)
	remote().fire(player, "InventorySync", snap)
	InventoryService.Changed:Fire(player)
end

-- Core mutations (used by every other service) ----------------------------------------------

-- Adds up to qty, respecting slots and the hard weight cap. Returns the amount added.
function InventoryService.add(
	player: Player,
	itemId: string,
	qty: number,
	data: { [string]: any }?,
	silent: boolean?
): number
	local record = PlayerStore.get(player)
	local def = ItemDefs.ById[itemId]
	if not record or not def then
		return 0
	end
	local slots = InventoryService.packStats(record).slots
	local fit = math.min(qty, InventoryModel.spaceFor(record.inventory, itemId, slots))
	-- Reduce until the weight fits under the hard cap.
	while fit > 0 and wouldExceedHardCap(record, InventoryModel.addedWeight(itemId, fit, data)) do
		fit -= 1
	end
	if fit <= 0 then
		return 0
	end
	local added = InventoryModel.add(record.inventory, itemId, fit, slots, data)
	if not silent then
		InventoryService.sync(player)
	end
	return added
end

function InventoryService.count(player: Player, itemId: string): number
	local record = PlayerStore.get(player)
	return if record then InventoryModel.count(record.inventory, itemId) else 0
end

function InventoryService.removeAll(player: Player, cost: { [string]: number }): boolean
	local record = PlayerStore.get(player)
	if not record then
		return false
	end
	local ok = InventoryModel.removeAll(record.inventory, cost)
	if ok then
		InventoryService.fixHeld(record)
		InventoryService.sync(player)
	end
	return ok
end

function InventoryService.fixHeld(record: PlayerStore.Record)
	if record.heldUid and not InventoryModel.find(record.inventory, record.heldUid) then
		record.heldUid = nil
	end
end

function InventoryService.heldItemId(record: PlayerStore.Record): string?
	if not record.heldUid then
		return nil
	end
	local stack = InventoryModel.find(record.inventory, record.heldUid)
	return if stack then stack.itemId else nil
end

-- Lighters and other tools with limited uses. Returns false if none / empty.
function InventoryService.useToolCharge(player: Player, itemId: string, amount: number): boolean
	local record = PlayerStore.get(player)
	local def = ItemDefs.ById[itemId]
	if not record or not def then
		return false
	end
	local stack = InventoryModel.firstOf(record.inventory, itemId)
	if not stack then
		return false
	end
	if def.durability then
		stack.data = stack.data or { uses = def.durability }
		local data = stack.data :: { [string]: any }
		data.uses = (data.uses or def.durability) - amount
		if data.uses <= 0 then
			InventoryModel.removeFromStack(record.inventory, stack.uid, 1)
			remote().notify(player, def.name .. " is used up.", "warn")
		end
	end
	InventoryService.sync(player)
	return true
end

-- Containers --------------------------------------------------------------------------------

local function isHot(def: ItemDefs.ItemDef, data: { [string]: any }): boolean
	if not data.hot then
		return false
	end
	if def.container and def.container.keepsHot then
		return true
	end
	return (data.hotUntil or 0) > os.time()
end

-- Fill every container in the pack. Returns litres added.
function InventoryService.fillContainers(player: Player, treated: boolean, hot: boolean): number
	local record = PlayerStore.get(player)
	if not record then
		return 0
	end
	local addedMl = 0
	for _, stack in record.inventory.stacks do
		local def = ItemDefs.ById[stack.itemId]
		if def and def.container then
			local data = stack.data or { ml = 0, treated = true }
			stack.data = data
			local space = def.container.capacityMl - (data.ml or 0)
			local room = InventoryService.packStats(record).weightLimit * InventoryModel.HARD_CAP_RATIO
				- InventoryService.totalWeight(record)
			space = math.min(space, math.floor(room / ItemDefs.WATER_KG_PER_ML))
			if space > 0 then
				-- Mixing untreated into treated water contaminates the whole bottle.
				local wasEmpty = (data.ml or 0) <= 0
				data.treated = if wasEmpty then treated else (data.treated and treated)
				data.hot = hot or (not wasEmpty and data.hot and isHot(def, data)) or false
				data.hotUntil = if hot then os.time() + HOT_DRINK_SECONDS else data.hotUntil
				data.ml = (data.ml or 0) + space
				addedMl += space
			end
		end
	end
	if addedMl > 0 then
		InventoryService.sync(player)
	end
	return addedMl / 1000
end

-- Boil: makes all water in the pack treated and hot (at a fire). Returns bottles affected.
function InventoryService.boilContainers(player: Player): number
	local record = PlayerStore.get(player)
	if not record then
		return 0
	end
	local count = 0
	for _, stack in record.inventory.stacks do
		local def = ItemDefs.ById[stack.itemId]
		local data = stack.data
		if def and def.container and data and (data.ml or 0) > 0 then
			data.treated = true
			data.hot = true
			data.hotUntil = os.time() + HOT_DRINK_SECONDS
			count += 1
		end
	end
	if count > 0 then
		InventoryService.sync(player)
	end
	return count
end

-- Cook every cookable item in the pack (canned stew -> hot stew). Returns items cooked.
function InventoryService.cookAll(player: Player): number
	local record = PlayerStore.get(player)
	if not record then
		return 0
	end
	local cooked = 0
	for _, stack in record.inventory.stacks do
		local def = ItemDefs.ById[stack.itemId]
		if def and def.cookedInto then
			stack.itemId = def.cookedInto
			cooked += stack.qty
		end
	end
	if cooked > 0 then
		InventoryService.sync(player)
	end
	return cooked
end

-- Helpers ------------------------------------------------------------------------------------

local function activeWithin(a: Player, b: Player, range: number): boolean
	local ra = a.Character and a.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local rb = b.Character and b.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not ra or not rb then
		return false
	end
	return (ra.Position - rb.Position).Magnitude <= range
end

local function nearTagged(player: Player, tag: string, attrName: string?, attrValue: any?): Instance?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	for _, inst in CollectionService:GetTagged(tag) do
		local pos: Vector3? = if inst:IsA("BasePart")
			then inst.Position
			elseif inst:IsA("Model") then inst:GetPivot().Position
			else nil
		if pos and (pos - root.Position).Magnitude <= GameConfig.INTERACT_RANGE + 4 then
			if attrName == nil or inst:GetAttribute(attrName) == attrValue then
				return inst
			end
		end
	end
	return nil
end

local function wornItems(record: PlayerStore.Record): { ItemDefs.ItemDef }
	local items = {}
	for _, itemId in record.worn do
		local def = ItemDefs.ById[itemId]
		if def then
			table.insert(items, def)
		end
	end
	return items
end
InventoryService.wornItems = wornItems

-- Actions -----------------------------------------------------------------------------------

local function drink(
	player: Player,
	record: PlayerStore.Record,
	stack: InventoryModel.Stack,
	def: ItemDefs.ItemDef
): (boolean, string)
	local container = def.container :: ItemDefs.ContainerStats
	local data = stack.data or { ml = 0 }
	stack.data = data
	local ml = data.ml or 0
	if ml <= 0 then
		return false, def.name .. " is empty."
	end
	local sip = math.min(container.sipMl, ml)
	local fraction = sip / container.sipMl
	local hot = isHot(def, data)
	local effect: any = { thirst = container.thirstPerSip * fraction }
	if hot then
		effect.warmthAll = 12 * fraction
	end
	SurvivalModel.applyUse(record.survival, def.id, effect)
	data.ml = ml - sip
	if data.ml <= 0 then
		data.hot = false
	end
	if not data.treated and math.random() < InjuryDefs.UntreatedWaterSicknessChance then
		if InjuryModel.add(record.survival.injuries, "StomachUpset") then
			record.stats.injuries += 1
			remote().notify(player, "That stream water didn't sit well. Treat or boil water next time.", "warn")
		end
	end
	record.stats.itemsConsumed += 1
	return true, if hot then "You drink something hot. Warmth spreads through you." else "You drink."
end

local function useItem(player: Player, record: PlayerStore.Record, stack: InventoryModel.Stack): (boolean, string)
	local def = ItemDefs.ById[stack.itemId]
	if not def then
		return false, "Unknown item."
	end
	if def.container then
		return drink(player, record, stack, def)
	end
	if def.id == "purification_tabs" then
		for _, other in record.inventory.stacks do
			local otherDef = ItemDefs.ById[other.itemId]
			if
				otherDef
				and otherDef.container
				and other.data
				and (other.data.ml or 0) > 0
				and not other.data.treated
			then
				other.data.treated = true
				InventoryModel.removeFromStack(record.inventory, stack.uid, 1)
				return true, "Water treated. Safe to drink."
			end
		end
		return false, "You have no untreated water."
	end
	if def.clothing then
		return InventoryService.equipClothing(player, record, stack)
	end
	if def.holdable then
		record.heldUid = if record.heldUid == stack.uid then nil else stack.uid
		return true,
			if record.heldUid then "You take out the " .. def.name .. "." else "You stow the " .. def.name .. "."
	end
	if not def.use or not def.consumable then
		return false, def.name .. " can't be used directly. Check the Build Book (B)."
	end
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	local health = if humanoid then humanoid.Health else 100
	local maxHealth = if humanoid then humanoid.MaxHealth else 100
	if not SurvivalModel.useWouldHelp(record.survival, def.id, def.use, health, maxHealth) then
		return false, "That wouldn't help right now."
	end
	local healthDelta, treated = SurvivalModel.applyUse(record.survival, def.id, def.use)
	if healthDelta ~= 0 then
		Registry.get("SurvivalService").changeHealth(player, healthDelta)
	end
	InventoryModel.removeFromStack(record.inventory, stack.uid, 1)
	record.stats.itemsConsumed += 1
	if #treated > 0 then
		local names = {}
		for _, id in treated do
			table.insert(names, InjuryDefs.ById[id].name)
		end
		return true, "Treated: " .. table.concat(names, ", ")
	end
	return true, "Used " .. def.name .. "."
end

function InventoryService.equipClothing(
	player: Player,
	record: PlayerStore.Record,
	stack: InventoryModel.Stack
): (boolean, string)
	local def = ItemDefs.ById[stack.itemId]
	if not def or not def.clothing then
		return false, "Not wearable."
	end
	local slot = def.clothing.slot
	local previous = record.worn[slot]
	InventoryModel.removeFromStack(record.inventory, stack.uid, 1)
	record.worn[slot] = def.id
	if previous then
		local slots = InventoryService.packStats(record).slots
		if InventoryModel.add(record.inventory, previous, 1, slots) == 0 then
			-- No room: undo.
			record.worn[slot] = previous
			InventoryModel.add(record.inventory, def.id, 1, slots + 1)
			return false, "No room in your pack for your old " .. ItemDefs.ById[previous].name .. "."
		end
	end
	Registry.get("SurvivalService").refreshGear(player)
	return true, "You put on the " .. def.name .. "."
end

local function unequipSlot(player: Player, record: PlayerStore.Record, slot: string): (boolean, string)
	local itemId = record.worn[slot]
	if not itemId then
		return false, "Nothing worn there."
	end
	local slots = InventoryService.packStats(record).slots
	if InventoryModel.add(record.inventory, itemId, 1, slots) == 0 then
		return false, "No room in your pack."
	end
	record.worn[slot] = nil
	Registry.get("SurvivalService").refreshGear(player)
	return true, "You take off the " .. ItemDefs.ById[itemId].name .. "."
end

local function giveItem(
	player: Player,
	record: PlayerStore.Record,
	stack: InventoryModel.Stack,
	targetId: number?
): (boolean, string)
	local target = if targetId then Players:GetPlayerByUserId(targetId) else nil
	if not target or target == player then
		return false, "No one to give that to."
	end
	local targetRecord = PlayerStore.get(target)
	if not targetRecord or not targetRecord.ready or not activeWithin(player, target, GameConfig.GIVE_RANGE) then
		return false, "Get closer to " .. (if target then target.DisplayName else "them") .. "."
	end
	local def = ItemDefs.ById[stack.itemId]
	local qty = if def and def.maxStack > 1 then 1 else stack.qty
	local data = stack.data
	local added = InventoryService.add(target, stack.itemId, qty, data, true)
	if added <= 0 then
		return false, target.DisplayName .. "'s pack is full or too heavy."
	end
	InventoryModel.removeFromStack(record.inventory, stack.uid, added)
	InventoryService.fixHeld(record)
	InventoryService.sync(target)
	remote().notify(target, player.DisplayName .. " gave you " .. (def and def.name or stack.itemId) .. ".", "good")
	return true, "Given to " .. target.DisplayName .. "."
end

local function treatOther(
	player: Player,
	record: PlayerStore.Record,
	stack: InventoryModel.Stack,
	targetId: number?
): (boolean, string)
	local def = ItemDefs.ById[stack.itemId]
	if not def or not def.treatOther or not def.use then
		return false, "That can't be used on someone else."
	end
	local target = if targetId then Players:GetPlayerByUserId(targetId) else nil
	if not target or target == player then
		return false, "Use it on yourself from your pack instead."
	end
	local targetRecord = PlayerStore.get(target)
	if not targetRecord or not activeWithin(player, target, GameConfig.GIVE_RANGE) then
		return false, "Get closer to treat them."
	end
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	local health = if humanoid then humanoid.Health else 100
	if
		not SurvivalModel.useWouldHelp(
			targetRecord.survival,
			def.id,
			def.use,
			health,
			if humanoid then humanoid.MaxHealth else 100
		)
	then
		return false, target.DisplayName .. " doesn't need that."
	end
	local healthDelta, treated = SurvivalModel.applyUse(targetRecord.survival, def.id, def.use)
	if healthDelta ~= 0 then
		Registry.get("SurvivalService").changeHealth(target, healthDelta)
	end
	InventoryModel.removeFromStack(record.inventory, stack.uid, 1)
	record.stats.itemsConsumed += 1
	remote().notify(target, player.DisplayName .. " treated you with a " .. def.name .. ".", "good")
	return true,
		if #treated > 0 then "Treated " .. target.DisplayName .. "." else "Helped " .. target.DisplayName .. "."
end

local function handleInventory(player: Player, action: string, uid: string, arg: number?): (boolean, string?)
	local record = PlayerStore.getActive(player)
	if not record then
		return false, "You can't do that right now."
	end
	if record.downed and action ~= "Drop" then
		return false, "You're incapacitated."
	end

	if action == "Unequip" then
		local ok, msg = unequipSlot(player, record, uid)
		InventoryService.sync(player)
		return ok, msg
	end
	if action == "Stow" then
		record.heldUid = nil
		InventoryService.sync(player)
		return true, nil
	end

	local stack = InventoryModel.find(record.inventory, uid)
	if not stack then
		return false, "You don't have that." -- stale UI or forged uid; harmless either way
	end

	local ok, msg
	if action == "Use" then
		ok, msg = useItem(player, record, stack)
	elseif action == "Equip" then
		local def = ItemDefs.ById[stack.itemId]
		if def and def.clothing then
			ok, msg = InventoryService.equipClothing(player, record, stack)
		elseif def and def.holdable then
			record.heldUid = stack.uid
			ok, msg = true, "You take out the " .. def.name .. "."
		elseif def and def.backpack then
			ok, msg = false, "Swap packs at the base camp outfitter."
		else
			ok, msg = false, "That can't be equipped."
		end
	elseif action == "Hold" then
		local def = ItemDefs.ById[stack.itemId]
		if def and def.holdable then
			record.heldUid = stack.uid
			ok, msg = true, nil
		else
			ok, msg = false, "You can't hold that."
		end
	elseif action == "Drop" then
		local qty = math.clamp(arg or stack.qty, 1, stack.qty)
		local itemId = stack.itemId
		local removed, data = InventoryModel.removeFromStack(record.inventory, uid, qty)
		InventoryService.fixHeld(record)
		local root = (player.Character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart
		Registry.get("ResourceService").spawnContainer(
			ItemDefs.ById[itemId].name,
			{ { itemId = itemId, qty = removed, data = data } },
			root.Position - Vector3.new(0, 2, 0) + root.CFrame.LookVector * 2
		)
		ok, msg = true, "Dropped."
	elseif action == "Give" then
		ok, msg = giveItem(player, record, stack, arg)
	elseif action == "Treat" then
		ok, msg = treatOther(player, record, stack, arg)
	else
		ok, msg = false, "Unknown action."
	end
	InventoryService.fixHeld(record)
	InventoryService.sync(player)
	return ok, msg
end

-- Outfitter / supply --------------------------------------------------------------------------

local function handleOutfit(player: Player, itemId: string): (boolean, string?)
	local record = PlayerStore.getActive(player)
	if not record then
		return false, "You can't do that right now."
	end
	if not nearTagged(player, "Outfitter") then
		return false, "You need to be at the outfitter."
	end
	local def = ItemDefs.ById[itemId]
	if not def or not table.find(LoadoutConfig.OutfitterStock, itemId) then
		return false, "Not available."
	end
	if Registry.get("ProgressionService").rankIndex(player) < def.unlockRank then
		return false, "Requires a higher rank."
	end
	local profile = Registry.get("DataService").get(player)

	if def.clothing then
		record.worn[def.clothing.slot] = itemId
		if profile then
			profile.loadout[def.clothing.slot] = itemId
			Registry.get("DataService").markDirty(player)
		end
		Registry.get("SurvivalService").refreshGear(player)
		InventoryService.sync(player)
		return true, "Wearing " .. def.name .. "."
	end

	if def.backpack then
		local newStats = def.backpack
		if #record.inventory.stacks > newStats.slots then
			return false, "Too many items for that pack. Drop some first."
		end
		local oldId = record.backpackId
		record.backpackId = itemId
		if wouldExceedHardCap(record, 0) then
			record.backpackId = oldId
			return false, "That pack can't carry what you have."
		end
		if profile then
			profile.loadout.Backpack = itemId
			Registry.get("DataService").markDirty(player)
		end
		InventoryService.sync(player)
		return true, "Switched to " .. def.name .. "."
	end

	if LoadoutConfig.OneOffTools[itemId] then
		if record.outfitterTaken[itemId] then
			return false, "You already took one this expedition."
		end
		local data = if def.container then { ml = 0, treated = true } else nil
		if InventoryService.add(player, itemId, 1, data) == 0 then
			return false, "No room in your pack."
		end
		record.outfitterTaken[itemId] = true
		return true, "Took " .. def.name .. "."
	end
	return false, "Not available."
end

local function handleSupply(player: Player, crateId: string, itemId: string): (boolean, string?)
	local record = PlayerStore.getActive(player)
	if not record then
		return false, "You can't do that right now."
	end
	if not nearTagged(player, "SupplyCrate", "CrateId", crateId) then
		return false, "You need to be at that supply crate."
	end
	local allowance = LoadoutConfig.SupplyAllowance[crateId]
	local limit = allowance and allowance[itemId]
	if not limit then
		return false, "Not in this crate."
	end
	local taken = record.supplyTaken[crateId] or {}
	record.supplyTaken[crateId] = taken
	if (taken[itemId] or 0) >= limit then
		return false, "You've taken your share of that."
	end
	if InventoryService.add(player, itemId, 1) == 0 then
		return false, "No room in your pack (or too heavy)."
	end
	taken[itemId] = (taken[itemId] or 0) + 1
	return true, nil
end

-- Lifecycle ----------------------------------------------------------------------------------

-- Called by PlayerService when the profile is loaded, before the first character.
function InventoryService.setupLoadout(player: Player, record: PlayerStore.Record, profile: any)
	table.clear(record.worn)
	for slot, itemId in LoadoutConfig.DefaultWorn do
		record.worn[slot] = itemId
	end
	for slot, itemId in profile.loadout do
		local def = ItemDefs.ById[itemId]
		if slot == "Backpack" then
			if def and def.backpack then
				record.backpackId = itemId
			end
		elseif def and def.clothing and def.clothing.slot == slot then
			record.worn[slot] = itemId
		end
	end
	if not ItemDefs.ById[record.backpackId] then
		record.backpackId = LoadoutConfig.DefaultBackpack
	end
	for _, entry in LoadoutConfig.StarterPack do
		InventoryService.add(player, entry.itemId, entry.qty, entry.data :: any, true)
	end
	-- Starter tools count as already taken so the outfitter doesn't hand out a second bottle.
	for _, entry in LoadoutConfig.StarterPack do
		if LoadoutConfig.OneOffTools[entry.itemId] then
			record.outfitterTaken[entry.itemId] = true
		end
	end
end

-- Empties the pack (used when a player is evacuated: their pack stays on the mountain).
function InventoryService.takeAll(player: Player): { InventoryModel.Stack }
	local record = PlayerStore.get(player)
	if not record then
		return {}
	end
	local stacks = record.inventory.stacks
	record.inventory.stacks = {}
	record.heldUid = nil
	InventoryService.sync(player)
	return stacks
end

function InventoryService.Init()
	local RemoteGuard = Registry.get("RemoteGuard")
	RemoteGuard.on("Inventory", handleInventory)
	RemoteGuard.on("Outfit", handleOutfit)
	RemoteGuard.on("Supply", handleSupply)
	RemoteGuard.on("GetSnapshot", function(player)
		local record = PlayerStore.get(player)
		return if record and record.ready then InventoryService.snapshot(record) else nil
	end)
end

function InventoryService.Start() end

return InventoryService
