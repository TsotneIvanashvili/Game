--!strict
-- Makes what a player carries visible on their character (design sections 13-15, 53):
--   * the equipped backpack, sized by tier, with harness straps over the shoulders and a
--     hip belt on medium+ packs,
--   * stowed gear on the pack: ice axe in its loop, rope coil under the lid, tarp under the
--     base, wood strapped to the side (bundle grows with wood carried),
--   * a held ice axe in the right hand,
--   * clothing layers as fabric shells over the body parts they cover,
--   * wet clothing darkens; snow settles on the pack lid while you're out in snowfall.
-- Visuals are rebuilt only when a "signature" of the visible loadout changes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemDefs = require(Shared.Config.ItemDefs)
local InventoryModel = require(Shared.Logic.InventoryModel)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)
local AssetFactory = require(script.Parent.Parent.World.AssetFactory)

local EquipmentService = {}

local GEAR_FOLDER = "Gear"

-- Body parts each clothing slot covers (R15 first, R6 fallback).
local SLOT_PARTS = {
	Jacket = {
		"UpperTorso",
		"LowerTorso",
		"LeftUpperArm",
		"RightUpperArm",
		"LeftLowerArm",
		"RightLowerArm",
		"Torso",
		"Left Arm",
		"Right Arm",
	},
	BaseLayer = { "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "Torso" },
	Pants = { "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "Left Leg", "Right Leg" },
	Gloves = { "LeftHand", "RightHand" },
	Boots = { "LeftFoot", "RightFoot" },
}
local SHELL_SCALE = { BaseLayer = 1.03, Jacket = 1.1, Pants = 1.06, Gloves = 1.12, Boots = 1.14 }

type Visual = {
	signature: string,
	shells: { { part: BasePart, base: Color3 } },
	snowCap: BasePart?,
	snow: number,
	wetBucket: number,
}

local visuals: { [Player]: Visual } = {}

local function bodyPart(character: Model, ...: string): BasePart?
	for _, name in { ... } do
		local p = character:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

-- Moves a model built around the origin into place relative to `frame`, then welds it.
local function mount(model: Model, frame: CFrame, attachTo: BasePart, parent: Instance)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CFrame = frame * d.CFrame
		end
	end
	local primary = model.PrimaryPart :: BasePart
	AssetFactory.weldCosmetic(model, primary)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = attachTo
	weld.Part1 = primary
	weld.Parent = primary
	model.Parent = parent
end

local function stowedState(record: PlayerStore.Record): (boolean, boolean, boolean, number)
	local heldId = Registry.get("InventoryService").heldItemId(record)
	local axe = InventoryModel.count(record.inventory, "ice_axe") > 0 and heldId ~= "ice_axe"
	local rope = InventoryModel.count(record.inventory, "rope") > 0
	local tarp = InventoryModel.count(record.inventory, "tarp") > 0
	local wood = InventoryModel.count(record.inventory, "wood")
	local woodVisual = if wood <= 0 then 0 elseif wood <= 2 then 1 elseif wood <= 5 then 2 else 3
	return axe, rope, tarp, woodVisual
end

local function signatureFor(record: PlayerStore.Record): string
	local axe, rope, tarp, wood = stowedState(record)
	local parts = { record.backpackId, tostring(Registry.get("InventoryService").heldItemId(record)) }
	for _, slot in { "Head", "Face", "BaseLayer", "Jacket", "Gloves", "Pants", "Boots" } do
		table.insert(parts, record.worn[slot] or "-")
	end
	table.insert(parts, string.format("%s%s%s%d", tostring(axe), tostring(rope), tostring(tarp), wood))
	return table.concat(parts, "|")
end

-- Final size/CFrame are set BEFORE the weld exists: moving a welded part afterwards would
-- drag the whole character assembly with it.
local function shell(
	folder: Instance,
	target: BasePart,
	scale: number,
	color: Color3,
	name: string,
	size: Vector3?,
	offset: CFrame?
): Part
	local p = AssetFactory.part(folder, {
		name = name,
		size = size or target.Size * scale,
		cframe = target.CFrame * (offset or CFrame.identity),
		color = color,
		material = Enum.Material.Fabric,
	})
	p.Anchored = false
	p.Massless = true
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = p
	weld.Parent = p
	return p
end

local function setHeadAccessoriesHidden(character: Model, hidden: boolean)
	for _, acc in character:GetChildren() do
		if acc:IsA("Accessory") then
			local accType = acc.AccessoryType
			if accType == Enum.AccessoryType.Hat or accType == Enum.AccessoryType.Hair then
				local handle = acc:FindFirstChild("Handle")
				if handle and handle:IsA("BasePart") then
					if hidden then
						if handle:GetAttribute("OriginalTransparency") == nil then
							handle:SetAttribute("OriginalTransparency", handle.Transparency)
						end
						handle.Transparency = 1
					else
						local original = handle:GetAttribute("OriginalTransparency")
						if typeof(original) == "number" then
							handle.Transparency = original
							handle:SetAttribute("OriginalTransparency", nil)
						end
					end
				end
			end
		end
	end
end

local function build(_player: Player, record: PlayerStore.Record, character: Model): Visual?
	local old = character:FindFirstChild(GEAR_FOLDER)
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = GEAR_FOLDER
	local visual: Visual = { signature = signatureFor(record), shells = {}, snowCap = nil, snow = 0, wetBucket = -1 }

	local upper = bodyPart(character, "UpperTorso", "Torso")
	if not upper then
		return nil
	end

	-- Clothing shells. Base layer only shows when no jacket covers it.
	for slot, names in SLOT_PARTS do
		local itemId = record.worn[slot]
		local def = itemId and ItemDefs.ById[itemId]
		local hiddenByJacket = slot == "BaseLayer" and record.worn.Jacket ~= nil
		if def and def.clothing and not hiddenByJacket then
			for _, name in names do
				local target = character:FindFirstChild(name)
				if target and target:IsA("BasePart") then
					local p = shell(folder, target, SHELL_SCALE[slot] or 1.05, def.clothing.color, slot .. "_" .. name)
					table.insert(visual.shells, { part = p, base = def.clothing.color })
				end
			end
		end
	end

	-- Jacket details: front zipper, chest pocket, hood bunched behind the neck.
	local jacket = record.worn.Jacket and ItemDefs.ById[record.worn.Jacket]
	if jacket and jacket.clothing then
		local s = upper.Size * 1.1
		local zip = AssetFactory.part(folder, {
			name = "JacketZip",
			size = Vector3.new(0.05, s.Y * 0.95, 0.03),
			cframe = upper.CFrame * CFrame.new(0.08, 0, -s.Z / 2 - 0.01),
			color = Color3.fromRGB(25, 25, 25),
			material = Enum.Material.SmoothPlastic,
		})
		local pocket = AssetFactory.part(folder, {
			name = "ChestPocket",
			size = Vector3.new(s.X * 0.3, s.Y * 0.25, 0.04),
			cframe = upper.CFrame * CFrame.new(-s.X * 0.22, s.Y * 0.2, -s.Z / 2 - 0.02),
			color = Color3.new(
				jacket.clothing.color.R * 0.85,
				jacket.clothing.color.G * 0.85,
				jacket.clothing.color.B * 0.85
			),
			material = Enum.Material.Fabric,
		})
		for _, p in { zip, pocket } do
			p.Anchored = false
			p.Massless = true
			local w = Instance.new("WeldConstraint")
			w.Part0 = upper
			w.Part1 = p
			w.Parent = p
		end
		if (jacket.clothing.insulation.Head or 0) > 0 then
			local hood = shell(
				folder,
				upper,
				1,
				jacket.clothing.color,
				"Hood",
				Vector3.new(s.X * 0.55, 0.45, 0.5),
				CFrame.new(0, s.Y / 2 - 0.05, s.Z / 2 - 0.05)
			)
			table.insert(visual.shells, { part = hood, base = jacket.clothing.color })
		end
	end

	-- Head: beanie and balaclava.
	local head = bodyPart(character, "Head")
	local headwear = false
	if head then
		local beanie = record.worn.Head and ItemDefs.ById[record.worn.Head]
		if beanie and beanie.clothing then
			local hs = head.Size
			local cap = shell(
				folder,
				head,
				1,
				beanie.clothing.color,
				"Beanie",
				Vector3.new(hs.X * 1.05, hs.Y * 0.45, hs.Z * 1.05),
				CFrame.new(0, hs.Y * 0.32, 0)
			)
			table.insert(visual.shells, { part = cap, base = beanie.clothing.color })
			headwear = true
		end
		local face = record.worn.Face and ItemDefs.ById[record.worn.Face]
		if face and face.clothing then
			local hs = head.Size
			local mask = shell(
				folder,
				head,
				1,
				face.clothing.color,
				"Balaclava",
				Vector3.new(hs.X * 1.04, hs.Y * 0.5, hs.Z * 1.04),
				CFrame.new(0, -hs.Y * 0.22, 0)
			)
			table.insert(visual.shells, { part = mask, base = face.clothing.color })
		end
	end
	setHeadAccessoriesHidden(character, headwear)

	-- Boot soles: aggressive dark rubber tread under each boot shell.
	if record.worn.Boots then
		for _, name in { "LeftFoot", "RightFoot" } do
			local foot = bodyPart(character, name)
			if foot then
				shell(
					folder,
					foot,
					1,
					Color3.fromRGB(25, 22, 20),
					"Sole",
					Vector3.new(foot.Size.X * 1.18, 0.12, foot.Size.Z * 1.2),
					CFrame.new(0, -foot.Size.Y / 2 - 0.02, 0)
				)
			end
		end
	end

	-- Backpack + harness + hip belt + stowed equipment.
	local packDef = ItemDefs.ById[record.backpackId]
	if packDef and packDef.backpack then
		local stats = packDef.backpack
		local packModel, anchors = AssetFactory.backpack(stats.tier, stats.color)
		local packFrame = upper.CFrame * CFrame.new(0, 0, upper.Size.Z / 2)
		-- Remember the pack's own body colours so wetness can darken them too.
		for _, d in packModel:GetDescendants() do
			if d:IsA("BasePart") and (d.Name == "Body" or d.Name == "UpperBody" or d.Name == "Lid") then
				table.insert(visual.shells, { part = d, base = d.Color })
			end
		end
		visual.snowCap = packModel:FindFirstChild("SnowCap") :: BasePart?
		mount(packModel, packFrame, upper, folder)

		mount(AssetFactory.harness(upper.Size, stats.color), upper.CFrame, upper, folder)
		local lower = bodyPart(character, "LowerTorso")
		if lower and stats.tier ~= "Small" then
			mount(AssetFactory.hipBelt(lower.Size, stats.color), lower.CFrame, lower, folder)
		end

		local axe, rope, tarp, wood = stowedState(record)
		if axe then
			mount(AssetFactory.iceAxe(), packFrame * anchors.Axe, upper, folder)
		end
		if rope then
			mount(AssetFactory.ropeCoil(Color3.fromRGB(220, 110, 40)), packFrame * anchors.Rope, upper, folder)
		end
		if tarp then
			mount(AssetFactory.tarpRoll(), packFrame * anchors.Tarp, upper, folder)
		end
		if wood > 0 then
			mount(AssetFactory.woodBundle(wood), packFrame * anchors.Wood, upper, folder)
		end
	end

	-- Held ice axe in the right hand, head forward.
	if Registry.get("InventoryService").heldItemId(record) == "ice_axe" then
		local hand = bodyPart(character, "RightHand", "Right Arm")
		if hand then
			local frame = hand.CFrame * CFrame.new(0, -hand.Size.Y * 0.3, 0) * CFrame.Angles(math.rad(-90), 0, 0)
			mount(AssetFactory.iceAxe(), frame, hand, folder)
		end
	end

	folder.Parent = character
	return visual
end

function EquipmentService.refresh(player: Player, force: boolean?)
	local record = PlayerStore.get(player)
	local character = player.Character
	if not record or not record.ready or not character then
		return
	end
	local current = visuals[player]
	local signature = signatureFor(record)
	if not force and current and current.signature == signature and character:FindFirstChild(GEAR_FOLDER) then
		return
	end
	local visual = build(player, record, character)
	visuals[player] = visual
	if visual then
		EquipmentService.applyWetness(player, true)
	end
end

function EquipmentService.applyWetness(player: Player, force: boolean?)
	local visual = visuals[player]
	if not visual then
		return
	end
	local wetness = player:GetAttribute("Wetness") or 0
	local bucket = math.floor(wetness * 10)
	if not force and bucket == visual.wetBucket then
		return
	end
	visual.wetBucket = bucket
	local f = 1 - 0.35 * (bucket / 10) -- soaked fabric reads ~35% darker
	for _, entry in visual.shells do
		if entry.part.Parent then
			entry.part.Color = Color3.new(entry.base.R * f, entry.base.G * f, entry.base.B * f)
		end
	end
end

function EquipmentService.Init() end

function EquipmentService.Start()
	local InventoryService = Registry.get("InventoryService")
	InventoryService.Changed:Connect(function(player)
		EquipmentService.refresh(player)
	end)

	local function watch(player: Player)
		player:GetAttributeChangedSignal("Wetness"):Connect(function()
			EquipmentService.applyWetness(player)
		end)
		player.CharacterAdded:Connect(function(character)
			visuals[player] = nil
			-- Accessories load after spawn; keep hats hidden under a beanie.
			character.ChildAdded:Connect(function(child)
				if child:IsA("Accessory") then
					task.defer(function()
						local record = PlayerStore.get(player)
						if record and record.worn.Head then
							setHeadAccessoriesHidden(character, true)
						end
					end)
				end
			end)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		visuals[player] = nil
	end)

	-- Snow settling on packs: slow, cheap loop.
	task.spawn(function()
		while true do
			task.wait(1)
			local weather = Registry.get("WeatherService")
			for player, visual in visuals do
				local cap = visual.snowCap
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if cap and cap.Parent and root then
					local sample = weather.sampleAt(root.Position)
					local sheltered = player:GetAttribute("InShelter") == true
					if sample.isSnow and sample.precipitation > 0.05 and not sheltered then
						visual.snow = math.min(1, visual.snow + 0.02 * sample.precipitation)
					else
						visual.snow =
							math.max(0, visual.snow - (if player:GetAttribute("NearFire") then 0.05 else 0.01))
					end
					local target = 1 - visual.snow * 0.95
					if math.abs(cap.Transparency - target) > 0.04 then
						cap.Transparency = target
					end
				end
			end
		end
	end)
end

return EquipmentService
