--!strict
-- Gatherable world resources and items lying on the ground.
--   WoodSource  (tag): fallen logs / deadwood. Attributes: Wood (per log), Respawn (s, -1 never)
--   WaterSource (tag): streams, pumps, meltwater. Attributes: Treated (bool)
--   Ground containers: dropped items and the packs of evacuated players.
-- Every grant goes through InventoryService.add, which enforces slots and the weight cap.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemDefs = require(Shared.Config.ItemDefs)
local InjuryDefs = require(Shared.Config.InjuryDefs)
local InjuryModel = require(Shared.Logic.InjuryModel)
local SurvivalModel = require(Shared.Logic.SurvivalModel)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)
local PromptUtil = require(script.Parent.PromptUtil)
local AssetFactory = require(script.Parent.Parent.World.AssetFactory)

local ResourceService = {}

local groundFolder: Folder
local setUp: { [Instance]: boolean } = {}

local function remote()
	return Registry.get("RemoteGuard")
end

local function anchorPart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	elseif inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function setVisible(inst: Instance, visible: boolean)
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			if d:GetAttribute("BaseTransparency") == nil then
				d:SetAttribute("BaseTransparency", d.Transparency)
			end
			d.Transparency = if visible then d:GetAttribute("BaseTransparency") :: number else 1
			d.CanCollide = visible and d:GetAttribute("BaseCollide") ~= false
		elseif d:IsA("ProximityPrompt") then
			d.Enabled = visible
		end
	end
end

local function setupWood(inst: Instance)
	local anchor = anchorPart(inst)
	if not anchor or setUp[inst] then
		return
	end
	setUp[inst] = true
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			d:SetAttribute("BaseCollide", d.CanCollide)
		end
	end
	local maxWood = inst:GetAttribute("Wood") or 3
	inst:SetAttribute("Remaining", maxWood)
	PromptUtil.create(anchor, {
		action = "Gather wood",
		object = "Deadwood",
		key = Enum.KeyCode.E,
		hold = 1.5,
		distance = 9,
		offset = Vector3.new(0, 1.5, 0),
	}, function(player)
		local record = PlayerStore.getActive(player)
		if not record or record.downed or record.carrying then
			return
		end
		local remaining = inst:GetAttribute("Remaining") or 0
		if remaining <= 0 then
			return
		end
		if Registry.get("InventoryService").add(player, "wood", 1) <= 0 then
			remote().notify(player, "Your pack is full or too heavy for more wood.", "warn")
			return
		end
		record.stats.resourcesCollected += 1
		record.survival.fatigue = math.min(100, record.survival.fatigue + 0.5)
		remaining -= 1
		inst:SetAttribute("Remaining", remaining)
		if remaining <= 0 then
			setVisible(inst, false)
			local respawn = inst:GetAttribute("Respawn")
			if typeof(respawn) == "number" and respawn > 0 then
				task.delay(respawn, function()
					if inst.Parent then
						inst:SetAttribute("Remaining", maxWood)
						setVisible(inst, true)
					end
				end)
			end
		end
	end)
end

local function setupWater(inst: Instance)
	local anchor = anchorPart(inst)
	if not anchor or setUp[inst] then
		return
	end
	setUp[inst] = true
	local treated = inst:GetAttribute("Treated") == true
	local label = if treated then "Clean water" else "Stream (untreated)"
	PromptUtil.create(
		anchor,
		{ action = "Fill bottles", object = label, key = Enum.KeyCode.E, hold = 1, distance = 10 },
		function(player)
			local record = PlayerStore.getActive(player)
			if not record or record.downed then
				return
			end
			local litres = Registry.get("InventoryService").fillContainers(player, treated, false)
			if litres > 0 then
				remote().notify(
					player,
					string.format(
						"Filled %.1f L.%s",
						litres,
						if treated then "" else " Treat or boil it before drinking."
					),
					"good"
				)
			else
				remote().notify(player, "No empty bottle space (or your pack is too heavy).", "info")
			end
		end
	)
	PromptUtil.create(anchor, {
		action = "Drink",
		object = label,
		key = Enum.KeyCode.F,
		hold = 0.5,
		distance = 10,
		offset = Vector3.new(0, 1.5, 0),
	}, function(player)
		local record = PlayerStore.getActive(player)
		if not record or record.downed then
			return
		end
		SurvivalModel.applyUse(record.survival, "stream", { thirst = 20 })
		if not treated and math.random() < InjuryDefs.UntreatedWaterSicknessChance then
			if InjuryModel.add(record.survival.injuries, "StomachUpset") then
				record.stats.injuries += 1
				remote().notify(player, "The water tasted off. Your stomach turns.", "warn")
			end
		end
	end)
end

-- Ground containers --------------------------------------------------------------------------

export type GroundStack = { itemId: string, qty: number, data: { [string]: any }? }

function ResourceService.spawnContainer(
	name: string,
	stacks: { GroundStack },
	position: Vector3,
	owner: string?
): Model?
	local valid = {}
	for _, s in stacks do
		if ItemDefs.ById[s.itemId] and s.qty > 0 then
			table.insert(valid, s)
		end
	end
	if #valid == 0 then
		return nil
	end
	local big = owner ~= nil or #valid > 2
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { groundFolder }
	local hit = workspace:Raycast(position + Vector3.new(0, 4, 0), Vector3.new(0, -30, 0), params)
	local ground = if hit then hit.Position else position
	local model = AssetFactory.groundBundle(CFrame.new(ground) * CFrame.Angles(0, math.random() * math.pi * 2, 0), big)
	model.Name = if owner then owner .. "'s pack" else name
	model.Parent = groundFolder
	local label = if owner then owner .. "'s pack" else name

	PromptUtil.create(model.PrimaryPart :: BasePart, {
		action = "Pick up",
		object = label,
		key = Enum.KeyCode.E,
		hold = if big then 1.5 else 0.3,
		distance = 9,
		offset = Vector3.new(0, 1.5, 0),
	}, function(player)
		local record = PlayerStore.getActive(player)
		if not record or record.downed or #valid == 0 then
			return
		end
		local InventoryService = Registry.get("InventoryService")
		local tookAny = false
		for i = #valid, 1, -1 do
			local s = valid[i]
			local added = InventoryService.add(player, s.itemId, s.qty, s.data, true)
			if added > 0 then
				tookAny = true
				s.qty -= added
				if s.qty <= 0 then
					table.remove(valid, i)
				end
			end
		end
		InventoryService.sync(player)
		if #valid == 0 then
			model:Destroy()
			if owner and owner ~= player.Name then
				remote().notify(player, "You recovered " .. owner .. "'s gear.", "good")
			end
		elseif not tookAny then
			remote().notify(player, "Your pack is full or too heavy.", "warn")
		else
			remote().notify(player, "You took what you could carry.", "info")
		end
	end)
	-- Ground items left alone eventually get buried (keeps the server tidy).
	task.delay(if owner then 1800 else 600, function()
		if model.Parent then
			model:Destroy()
		end
	end)
	return model
end

function ResourceService.Init()
	groundFolder = Instance.new("Folder")
	groundFolder.Name = "GroundItems"
	groundFolder.Parent = workspace
end

function ResourceService.Start()
	for _, inst in CollectionService:GetTagged("WoodSource") do
		setupWood(inst)
	end
	CollectionService:GetInstanceAddedSignal("WoodSource"):Connect(setupWood)
	for _, inst in CollectionService:GetTagged("WaterSource") do
		setupWater(inst)
	end
	CollectionService:GetInstanceAddedSignal("WaterSource"):Connect(setupWater)
end

return ResourceService
