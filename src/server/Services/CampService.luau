--!strict
-- Checkpoint camps. A camp is a Model tagged "Camp" with attributes CampId, CampName,
-- Index, Radius and these children (any may be missing in a hand-built map):
--   Spawn (BasePart)          where players respawn after signing this camp's logbook
--   Logbook (Model)           "Sign the logbook" activates the checkpoint
--   Fire (Model)              permanent fire, registered with BuildingService
--   ShelterVolume (BasePart)  invisible box: cabin interior, blocks wind and snow
--   SupplyCrate / Outfitter   tagged separately, handled through panels
-- Resting is optional. Camps heal fractures and sprains only while you rest in them.

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LoadoutConfig = require(Shared.Config.LoadoutConfig)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)
local PromptUtil = require(script.Parent.PromptUtil)

local CampService = {}

type Camp = {
	model: Model,
	id: string,
	name: string,
	index: number,
	radius: number,
	center: Vector3,
	spawn: CFrame,
}

local camps: { [number]: Camp } = {}
local setUp: { [Instance]: boolean } = {}
local sectionEnds: { BasePart } = {}

local function remote()
	return Registry.get("RemoteGuard")
end

function CampService.isInCamp(pos: Vector3): boolean
	for _, camp in camps do
		if (camp.center - pos).Magnitude <= camp.radius then
			return true
		end
	end
	return false
end

function CampService.campByIndex(index: number): any
	return camps[index]
end

function CampService.spawnFor(record: PlayerStore.Record): CFrame?
	local camp = camps[record.checkpoint] or camps[1]
	return if camp then camp.spawn else nil
end

function CampService.recoverToCheckpoint(player: Player, message: string?)
	local record = PlayerStore.get(player)
	local character = player.Character
	if not record or not character then
		return
	end
	local spawn = CampService.spawnFor(record)
	if spawn then
		Registry.get("RescueService").releaseAll(player)
		record.climbing = nil
		record.peakY = nil
		record.lastPosition = nil
		character:PivotTo(spawn + Vector3.new(math.random(-3, 3), 3, math.random(-3, 3)))
	end
	if message then
		remote().notify(player, message, "warn")
	end
end

local function signLogbook(player: Player, camp: Camp)
	local record = PlayerStore.getActive(player)
	if not record or record.downed then
		return
	end
	local isNew = camp.index > record.stats.highestCheckpoint
	if camp.index >= record.checkpoint then
		record.checkpoint = camp.index
	end
	player:SetAttribute("Checkpoint", record.checkpoint)
	player:SetAttribute("CheckpointName", camps[record.checkpoint].name)
	if not isNew then
		remote().notify(player, "You signed the " .. camp.name .. " logbook. You'll return here if evacuated.", "info")
		return
	end
	record.stats.highestCheckpoint = camp.index
	local profile = Registry.get("DataService").get(player)
	if profile then
		profile.totals.checkpoints += 1
		Registry.get("DataService").markDirty(player)
	end
	Registry.get("ProgressionService").award(player, ProgressionConfig.XP.Checkpoint, "Reached " .. camp.name)
	remote().notifyAll(player.DisplayName .. " reached " .. camp.name .. ".", "good")
	Registry.get("ExpeditionService").onCheckpoint(player, camp.index)
end

local function setupCamp(model: Instance)
	if setUp[model] or not model:IsA("Model") then
		return
	end
	setUp[model] = true
	local index = model:GetAttribute("Index") :: number
	local spawnPart = model:FindFirstChild("Spawn") :: BasePart?
	local camp: Camp = {
		model = model,
		id = model:GetAttribute("CampId") or model.Name,
		name = model:GetAttribute("CampName") or model.Name,
		index = index,
		radius = model:GetAttribute("Radius") or 40,
		center = model:GetPivot().Position,
		spawn = if spawnPart then spawnPart.CFrame + Vector3.new(0, 3, 0) else model:GetPivot(),
	}
	camps[index] = camp

	local logbook = model:FindFirstChild("Logbook")
	local logPart = logbook and (if logbook:IsA("Model") then logbook.PrimaryPart else logbook)
	if logPart and logPart:IsA("BasePart") then
		PromptUtil.create(logPart, {
			action = "Sign the logbook",
			object = camp.name,
			key = Enum.KeyCode.E,
			hold = 1,
			distance = 10,
			offset = Vector3.new(0, 3.5, 0),
		}, function(player)
			signLogbook(player, camp)
		end)
	end

	local fire = model:FindFirstChild("Fire")
	if fire and fire:IsA("Model") then
		Registry.get("BuildingService").registerPermanentFire(fire, fire:GetPivot().Position + Vector3.new(0, 1, 0))
	end
	for _, child in model:GetChildren() do
		if child.Name == "ShelterVolume" and child:IsA("BasePart") then
			Registry.get("BuildingService").registerShelter(child.CFrame, child.Size, 0.05, true)
		end
	end
end

local function setupCrate(inst: Instance)
	if setUp[inst] then
		return
	end
	local part = if inst:IsA("Model") then inst.PrimaryPart else inst
	if not part or not part:IsA("BasePart") then
		return
	end
	setUp[inst] = true
	local crateId = inst:GetAttribute("CrateId") :: string
	PromptUtil.create(part, {
		action = "Open supply crate",
		object = "Supplies",
		key = Enum.KeyCode.E,
		distance = 10,
		offset = Vector3.new(0, 2, 0),
	}, function(player)
		local record = PlayerStore.getActive(player)
		if not record then
			return
		end
		local allowance = LoadoutConfig.SupplyAllowance[crateId] or {}
		local taken = record.supplyTaken[crateId] or {}
		local remaining = {}
		for itemId, limit in allowance do
			remaining[itemId] = limit - (taken[itemId] or 0)
		end
		remote().fire(player, "OpenPanel", "Supply", { crateId = crateId, remaining = remaining })
	end)
end

local function setupOutfitter(inst: Instance)
	if setUp[inst] then
		return
	end
	local part = if inst:IsA("Model") then inst.PrimaryPart else inst
	if not part or not part:IsA("BasePart") then
		return
	end
	setUp[inst] = true
	PromptUtil.create(part, {
		action = "Change gear",
		object = "Outfitter",
		key = Enum.KeyCode.E,
		distance = 12,
		offset = Vector3.new(0, -2, 0),
	}, function(player)
		local record = PlayerStore.getActive(player)
		if not record then
			return
		end
		remote().fire(player, "OpenPanel", "Outfitter", {
			stock = LoadoutConfig.OutfitterStock,
			taken = record.outfitterTaken,
			rankIndex = Registry.get("ProgressionService").rankIndex(player),
		})
	end)
end

function CampService.Init() end

function CampService.Start()
	for _, m in CollectionService:GetTagged("Camp") do
		setupCamp(m)
	end
	CollectionService:GetInstanceAddedSignal("Camp"):Connect(setupCamp)
	for _, c in CollectionService:GetTagged("SupplyCrate") do
		setupCrate(c)
	end
	CollectionService:GetInstanceAddedSignal("SupplyCrate"):Connect(setupCrate)
	for _, o in CollectionService:GetTagged("Outfitter") do
		setupOutfitter(o)
	end
	CollectionService:GetInstanceAddedSignal("Outfitter"):Connect(setupOutfitter)
	for _, p in CollectionService:GetTagged("SectionEnd") do
		if p:IsA("BasePart") then
			table.insert(sectionEnds, p)
		end
	end

	-- Section end detection: cheap distance check once a second.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				local record, _, _, root = PlayerStore.getActive(player)
				if record and root and not record.stats.sectionComplete and not record.downed then
					for _, marker in sectionEnds do
						local radius = marker:GetAttribute("Radius") or 20
						if (marker.Position - root.Position).Magnitude <= radius then
							Registry.get("ExpeditionService").sectionComplete(player)
						end
					end
				end
			end
		end
	end)
end

return CampService
