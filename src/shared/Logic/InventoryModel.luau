--!strict
-- Pure inventory model. The server owns the only real copy; clients receive snapshots.
-- Every mutation is checked here first (slots, stack sizes, weight) so services stay thin.

local ItemDefs = require(script.Parent.Parent.Config.ItemDefs)

export type Stack = {
	uid: string,
	itemId: string,
	qty: number,
	data: { [string]: any }?,
}

export type Inventory = {
	stacks: { Stack },
	nextUid: number,
}

local InventoryModel = {}

InventoryModel.HARD_CAP_RATIO = 1.3 -- you can overload a pack to 130% and suffer for it

function InventoryModel.new(): Inventory
	return { stacks = {}, nextUid = 1 }
end

local function newUid(inv: Inventory): string
	local uid = tostring(inv.nextUid)
	inv.nextUid += 1
	return uid
end

local function cloneData(data: { [string]: any }?): { [string]: any }?
	if not data then
		return nil
	end
	return table.clone(data)
end

function InventoryModel.stackWeight(stack: Stack): number
	local def = ItemDefs.ById[stack.itemId]
	if not def then
		return 0
	end
	local w = def.weight * stack.qty
	if def.container and stack.data then
		w += (stack.data.ml or 0) * ItemDefs.WATER_KG_PER_ML
	end
	return w
end

function InventoryModel.totalWeight(inv: Inventory): number
	local total = 0
	for _, stack in inv.stacks do
		total += InventoryModel.stackWeight(stack)
	end
	return total
end

function InventoryModel.find(inv: Inventory, uid: string): (Stack?, number?)
	for i, stack in inv.stacks do
		if stack.uid == uid then
			return stack, i
		end
	end
	return nil, nil
end

function InventoryModel.count(inv: Inventory, itemId: string): number
	local n = 0
	for _, stack in inv.stacks do
		if stack.itemId == itemId then
			n += stack.qty
		end
	end
	return n
end

function InventoryModel.firstOf(inv: Inventory, itemId: string): Stack?
	for _, stack in inv.stacks do
		if stack.itemId == itemId then
			return stack
		end
	end
	return nil
end

-- How many of `itemId` fit, considering partial stacks and free slots (not weight).
-- Mirrors `add`'s merge rule: only data-less stacks merge, and never when adding with data
-- (previously partial stacks carrying data were counted as room `add` would never use).
function InventoryModel.spaceFor(inv: Inventory, itemId: string, slotLimit: number, data: { [string]: any }?): number
	local def = ItemDefs.ById[itemId]
	if not def then
		return 0
	end
	local space = 0
	if def.maxStack > 1 and data == nil then
		for _, stack in inv.stacks do
			if stack.itemId == itemId and stack.data == nil then
				space += math.max(0, def.maxStack - stack.qty)
			end
		end
	end
	local freeSlots = math.max(0, slotLimit - #inv.stacks)
	return space + freeSlots * def.maxStack
end

-- Weight that `qty` of an item would add (containers include their data's water).
function InventoryModel.addedWeight(itemId: string, qty: number, data: { [string]: any }?): number
	local def = ItemDefs.ById[itemId]
	if not def then
		return 0
	end
	local w = def.weight * qty
	if def.container and data then
		w += (data.ml or 0) * ItemDefs.WATER_KG_PER_ML
	end
	return w
end

-- Adds as many as fit. Returns the number actually added.
function InventoryModel.add(
	inv: Inventory,
	itemId: string,
	qty: number,
	slotLimit: number,
	data: { [string]: any }?
): number
	local def = ItemDefs.ById[itemId]
	if not def or qty <= 0 or qty ~= math.floor(qty) then
		return 0
	end
	local remaining = qty
	-- Containers and items with data never merge.
	if def.maxStack > 1 and data == nil then
		for _, stack in inv.stacks do
			if remaining <= 0 then
				break
			end
			if stack.itemId == itemId and stack.data == nil and stack.qty < def.maxStack then
				local take = math.min(def.maxStack - stack.qty, remaining)
				stack.qty += take
				remaining -= take
			end
		end
	end
	while remaining > 0 and #inv.stacks < slotLimit do
		local take = math.min(def.maxStack, remaining)
		table.insert(inv.stacks, { uid = newUid(inv), itemId = itemId, qty = take, data = cloneData(data) })
		remaining -= take
	end
	return qty - remaining
end

-- Remove `qty` from one stack. Returns removed amount and the stack's data (for drops/gives).
function InventoryModel.removeFromStack(inv: Inventory, uid: string, qty: number): (number, { [string]: any }?)
	local stack, index = InventoryModel.find(inv, uid)
	if not stack or not index or qty <= 0 then
		return 0, nil
	end
	local take = math.min(stack.qty, math.floor(qty))
	stack.qty -= take
	local data = cloneData(stack.data)
	if stack.qty <= 0 then
		table.remove(inv.stacks, index)
	end
	return take, data
end

-- Atomic multi-item removal for recipes. Either removes everything or nothing.
function InventoryModel.hasAll(inv: Inventory, cost: { [string]: number }): boolean
	for itemId, qty in cost do
		if InventoryModel.count(inv, itemId) < qty then
			return false
		end
	end
	return true
end

function InventoryModel.removeAll(inv: Inventory, cost: { [string]: number }): boolean
	if not InventoryModel.hasAll(inv, cost) then
		return false
	end
	for itemId, qty in cost do
		local remaining = qty
		for i = #inv.stacks, 1, -1 do
			local stack = inv.stacks[i]
			if remaining <= 0 then
				break
			end
			if stack.itemId == itemId then
				local take = math.min(stack.qty, remaining)
				stack.qty -= take
				remaining -= take
				if stack.qty <= 0 then
					table.remove(inv.stacks, i)
				end
			end
		end
	end
	return true
end

-- Network snapshot. Copies so the client-bound table can't alias server state.
function InventoryModel.snapshot(inv: Inventory): { Stack }
	local out = {}
	for _, stack in inv.stacks do
		table.insert(out, { uid = stack.uid, itemId = stack.itemId, qty = stack.qty, data = cloneData(stack.data) })
	end
	return out
end

return InventoryModel
