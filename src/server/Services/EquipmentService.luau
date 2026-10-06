--!strict
-- Makes what a player carries visible on their character (design sections 13-15, 53;
-- look: docs/ART_DIRECTION.md section 8). All parts come from World/GearFactory:
--   * clothing: jacket shells with ribbed cuffs, zipper, mountain chest patch and fur hood
--     ring; black pant shells; gauntlet gloves; chunky boots with crampons,
--   * head gear: helmet with headlamp (or beanie), knit mask, goggles; each can be hidden
--     with the GearToggle remote (Helmet / Mask / Goggles / Light), state kept in player
--     attributes GearHelmet / GearMask / GearGoggles / GearLight for the UI,
--   * the equipped backpack, sized by tier, with harness and (medium+) hip belt,
--   * stowed gear on the pack: ice axe in its loop, rope coil under the lid, tarp under the
--     base, wood strapped to the side (bundle grows with wood carried),
--   * a held ice axe in the right hand,
--   * wet fabric darkens; snow settles on the pack's top roll while you're out in snowfall.
-- Visuals are rebuilt only when a "signature" of the visible loadout changes. Toggles are
-- cosmetic: warmth always comes from what is worn (SurvivalService).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemDefs = require(Shared.Config.ItemDefs)
local InventoryModel = require(Shared.Logic.InventoryModel)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)
local AssetFactory = require(script.Parent.Parent.World.AssetFactory)
local GearFactory = require(script.Parent.Parent.World.GearFactory)

local EquipmentService = {}

local GEAR_FOLDER = "Gear"

-- GearToggle part -> player attribute, and the attribute defaults.
local TOGGLE_ATTR = { Helmet = "GearHelmet", Mask = "GearMask", Goggles = "GearGoggles", Light = "GearLight" }
local TOGGLE_DEFAULT = { GearHelmet = true, GearMask = true, GearGoggles = true, GearLight = false }

local SCALE = { BaseLayer = 1.03, Jacket = 1.1, Pants = 1.06 }
local STRIPE = Color3.fromRGB(95, 145, 225)
local LENS = Color3.fromRGB(0, 205, 240)
local LENS_STORM = Color3.fromRGB(0, 230, 255)

type Visual = {
	signature: string,
	shells: { { part: BasePart, base: Color3 } },
	snowCap: BasePart?,
	snow: number,
	wetBucket: number,
}

local visuals: { [Player]: Visual } = {}
local lastWarning: { [Player]: string } = {}

local function bodyPart(character: Model, ...: string): BasePart?
	for _, name in { ... } do
		local p = character:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

local function toggle(player: Player, attr: string): boolean
	local v = player:GetAttribute(attr)
	if typeof(v) == "boolean" then
		return v
	end
	return TOGGLE_DEFAULT[attr] == true
end

local function wornDef(record: PlayerStore.Record, slot: string): ItemDefs.ItemDef?
	local id = record.worn[slot]
	local def = id and ItemDefs.ById[id]
	return if def and def.clothing then def else nil
end

local function hasHeadlamp(record: PlayerStore.Record): boolean
	local def = wornDef(record, "Head")
	return def ~= nil and (def.clothing :: ItemDefs.ClothingStats).headlamp == true
end

local function helmetShown(player: Player, record: PlayerStore.Record): boolean
	return record.worn.Head ~= nil and toggle(player, "GearHelmet")
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

local function signatureFor(player: Player, record: PlayerStore.Record): string
	local axe, rope, tarp, wood = stowedState(record)
	local parts = { record.backpackId, tostring(Registry.get("InventoryService").heldItemId(record)) }
	for _, slot in { "Head", "Face", "Eyes", "BaseLayer", "Jacket", "Gloves", "Pants", "Boots" } do
		table.insert(parts, record.worn[slot] or "-")
	end
	table.insert(parts, string.format("%s%s%s%d", tostring(axe), tostring(rope), tostring(tarp), wood))
	-- Visibility toggles change which parts exist; the light is switched live instead.
	table.insert(
		parts,
		string.format(
			"%s%s%s",
			tostring(toggle(player, "GearHelmet")),
			tostring(toggle(player, "GearMask")),
			tostring(toggle(player, "GearGoggles"))
		)
	)
	return table.concat(parts, "|")
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

-- Builds every gear model into `folder` (not yet parented to the character). Returns the
-- visual, or nil and the reason it couldn't build.
local function build(player: Player, record: PlayerStore.Record, character: Model, folder: Folder): (Visual?, string?)
	local upper = bodyPart(character, "UpperTorso", "Torso")
	if not upper then
		return nil, "character has no UpperTorso/Torso"
	end
	local r15 = upper.Name == "UpperTorso"
	local visual: Visual =
		{ signature = signatureFor(player, record), shells = {}, snowCap = nil, snow = 0, wetBucket = -1 }

	local function add(model: Model, target: BasePart, offset: CFrame?)
		GearFactory.attach(model, target, folder, offset)
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d:GetAttribute(GearFactory.SHELL_ATTR) == true then
				table.insert(visual.shells, { part = d, base = d.Color })
			end
		end
	end

	local jacket = wornDef(record, "Jacket")
	local base = wornDef(record, "BaseLayer")
	local pants = wornDef(record, "Pants")
	local gloves = wornDef(record, "Gloves")
	local boots = wornDef(record, "Boots")
	local lower = bodyPart(character, "LowerTorso")

	-- Torso + arms: the jacket covers the base layer; a base layer alone shows as a thin shell.
	local torsoScale = 1
	if jacket then
		local stats = jacket.clothing :: ItemDefs.ClothingStats
		local down = stats.style == "down"
		local fur = stats.style == "parka" or (stats.style == nil and (stats.insulation.Head or 0) > 0)
		torsoScale = SCALE.Jacket
		add(
			GearFactory.torsoShell(upper.Size, stats.color, { scale = torsoScale, hem = not r15, baffles = down }),
			upper
		)
		if lower then
			add(
				GearFactory.torsoShell(lower.Size, stats.color, { scale = torsoScale, hem = true, baffles = false }),
				lower
			)
		end
		local head = bodyPart(character, "Head")
		local hs = if head then GearFactory.headSize(head) else Vector3.new(1.2, 1.2, 1.2)
		add(GearFactory.jacketDetails(upper.Size, hs, stats.color, torsoScale, fur), upper)
		for _, name in { "LeftUpperArm", "RightUpperArm" } do
			local arm = bodyPart(character, name)
			if arm then
				add(GearFactory.sleeve(arm.Size, stats.color, torsoScale, nil, down), arm)
			end
		end
		for _, name in { "LeftLowerArm", "RightLowerArm" } do
			local arm = bodyPart(character, name)
			if arm then
				add(GearFactory.sleeve(arm.Size, stats.color, torsoScale, 0, false), arm)
			end
		end
		for _, name in { "Left Arm", "Right Arm" } do -- R6: the hand is the bottom ~0.4 studs
			local arm = bodyPart(character, name)
			if arm then
				add(GearFactory.sleeve(arm.Size, stats.color, torsoScale, math.min(0.4, arm.Size.Y * 0.2), down), arm)
			end
		end
	elseif base then
		local stats = base.clothing :: ItemDefs.ClothingStats
		torsoScale = SCALE.BaseLayer
		add(GearFactory.torsoShell(upper.Size, stats.color, { scale = torsoScale }), upper)
		if lower then
			add(GearFactory.torsoShell(lower.Size, stats.color, { scale = torsoScale }), lower)
		end
		for _, name in { "LeftUpperArm", "RightUpperArm" } do
			local arm = bodyPart(character, name)
			if arm then
				add(GearFactory.sleeve(arm.Size, stats.color, torsoScale), arm)
			end
		end
	end

	-- Legs.
	if pants then
		local stats = pants.clothing :: ItemDefs.ClothingStats
		for _, name in { "LeftUpperLeg", "RightUpperLeg" } do
			local leg = bodyPart(character, name)
			if leg then
				add(GearFactory.legShell(leg.Size, stats.color, SCALE.Pants, false), leg)
			end
		end
		for _, name in { "LeftLowerLeg", "RightLowerLeg", "Left Leg", "Right Leg" } do
			local leg = bodyPart(character, name)
			if leg then
				add(GearFactory.legShell(leg.Size, stats.color, SCALE.Pants, true), leg)
			end
		end
	end

	-- Hands: R15 hands, or the bottom of an R6 arm.
	if gloves then
		local stats = gloves.clothing :: ItemDefs.ClothingStats
		local heated = stats.style == "heated"
		for _, name in { "LeftHand", "RightHand" } do
			local hand = bodyPart(character, name)
			if hand then
				add(GearFactory.glove(hand.Size, stats.color, heated), hand)
			end
		end
		if not r15 then
			for _, name in { "Left Arm", "Right Arm" } do
				local arm = bodyPart(character, name)
				if arm then
					local handSize = Vector3.new(arm.Size.X, 0.4, arm.Size.Z)
					add(GearFactory.glove(handSize, stats.color, heated), arm, CFrame.new(0, -arm.Size.Y / 2 + 0.2, 0))
				end
			end
		end
	end

	-- Feet: chunky boots (crampons for "crampon" style), shaft up the lower leg.
	if boots then
		local stats = boots.clothing :: ItemDefs.ClothingStats
		local style = stats.style or "boot"
		local opts: GearFactory.BootOpts = {
			stripe = if style == "crampon" then STRIPE else nil,
			spikes = style == "crampon",
			low = style == "shoe",
		}
		local tall = boots.id == "insulated_overboots"
		if r15 then
			for _, side in { "Left", "Right" } do
				local foot = bodyPart(character, side .. "Foot")
				if foot then
					add(GearFactory.boot(foot.Size, stats.color, opts), foot)
				end
				local shin = bodyPart(character, side .. "LowerLeg")
				if shin and style ~= "shoe" then
					local h = math.min(shin.Size.Y * (if tall then 0.75 else 0.5), shin.Size.Y)
					add(GearFactory.bootCuff(shin.Size, stats.color, h, opts.stripe), shin)
				end
			end
		else
			for _, name in { "Left Leg", "Right Leg" } do
				local leg = bodyPart(character, name)
				if leg then
					local foot = Vector3.new(leg.Size.X, 0.4, leg.Size.Z)
					add(GearFactory.boot(foot, stats.color, opts), leg, CFrame.new(0, -leg.Size.Y / 2 + 0.2, 0))
					if style ~= "shoe" then
						add(GearFactory.bootCuff(leg.Size, stats.color, if tall then 1.1 else 0.75, opts.stripe), leg)
					end
				end
			end
		end
	end

	-- Head gear, each piece subject to its visibility toggle.
	local head = bodyPart(character, "Head")
	local showHelmet = false
	if head then
		local hs = GearFactory.headSize(head)
		local headDef = wornDef(record, "Head")
		if headDef and toggle(player, "GearHelmet") then
			local stats = headDef.clothing :: ItemDefs.ClothingStats
			if stats.style == "helmet" then
				local lamp = stats.headlamp == true
				add(GearFactory.helmet(hs, stats.color, lamp and toggle(player, "GearLight"), lamp), head)
			else
				add(GearFactory.beanie(hs, stats.color), head)
			end
			showHelmet = true
		end
		local faceDef = wornDef(record, "Face")
		if faceDef and toggle(player, "GearMask") then
			add(GearFactory.mask(hs, (faceDef.clothing :: ItemDefs.ClothingStats).color), head)
		end
		local eyesDef = wornDef(record, "Eyes")
		if eyesDef and toggle(player, "GearGoggles") then
			local stats = eyesDef.clothing :: ItemDefs.ClothingStats
			local storm = stats.style == "storm_goggles"
			add(GearFactory.goggles(hs, stats.color, if storm then LENS_STORM else LENS, storm), head)
		end
	end
	setHeadAccessoriesHidden(character, showHelmet)

	-- Backpack + harness + hip belt + stowed equipment. The pack rests on the jacket's back.
	local packDef = ItemDefs.ById[record.backpackId]
	if packDef and packDef.backpack then
		local stats = packDef.backpack
		local shell = upper.Size * torsoScale
		local packOffset = CFrame.new(0, 0, shell.Z / 2)
		local packModel, anchors = GearFactory.backpack(stats.tier, stats.color, upper.Size)
		visual.snowCap = packModel:FindFirstChild("SnowCap") :: BasePart?
		add(packModel, upper, packOffset)
		add(GearFactory.harness(shell, stats.color), upper)
		if stats.tier ~= "Small" then
			if lower then
				add(GearFactory.hipBelt(lower.Size * torsoScale, stats.color), lower)
			else
				local beltSize = Vector3.new(shell.X, 0.4, shell.Z)
				add(GearFactory.hipBelt(beltSize, stats.color), upper, CFrame.new(0, -upper.Size.Y / 2 + 0.2, 0))
			end
		end

		local axe, rope, tarp, wood = stowedState(record)
		if axe then
			GearFactory.attach(AssetFactory.iceAxe(), upper, folder, packOffset * anchors.Axe)
		end
		if rope then
			GearFactory.attach(
				AssetFactory.ropeCoil(Color3.fromRGB(220, 110, 40)),
				upper,
				folder,
				packOffset * anchors.Rope
			)
		end
		if tarp then
			GearFactory.attach(AssetFactory.tarpRoll(), upper, folder, packOffset * anchors.Tarp)
		end
		if wood > 0 then
			GearFactory.attach(AssetFactory.woodBundle(wood), upper, folder, packOffset * anchors.Wood)
		end
	end

	-- Held ice axe in the right hand, head forward.
	if Registry.get("InventoryService").heldItemId(record) == "ice_axe" then
		local hand = bodyPart(character, "RightHand", "Right Arm")
		if hand then
			local offset = CFrame.new(0, -hand.Size.Y * 0.3, 0) * CFrame.Angles(math.rad(-90), 0, 0)
			GearFactory.attach(AssetFactory.iceAxe(), hand, folder, offset)
		end
	end

	return visual, nil
end

local function warnOnce(player: Player, reason: string)
	if lastWarning[player] ~= reason then
		lastWarning[player] = reason
		warn("[Equipment] " .. player.Name .. ": can't build gear (" .. reason .. ")")
	end
end

local function applyLight(player: Player)
	local character = player.Character
	local folder = character and character:FindFirstChild(GEAR_FOLDER)
	if folder then
		GearFactory.setHeadlamp(folder, toggle(player, "GearLight"))
	end
end

function EquipmentService.refresh(player: Player, force: boolean?)
	local record = PlayerStore.get(player)
	if not record or not record.ready then
		return
	end
	local character = player.Character
	if not character then
		if force then
			warnOnce(player, "no character")
		end
		return
	end
	-- The light can't stay on once the headlamp is gone (unequipped or swapped).
	if toggle(player, "GearLight") and not hasHeadlamp(record) then
		player:SetAttribute("GearLight", false)
	end
	local current = visuals[player]
	local signature = signatureFor(player, record)
	if not force and current and current.signature == signature and character:FindFirstChild(GEAR_FOLDER) then
		return
	end

	local old = character:FindFirstChild(GEAR_FOLDER)
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = GEAR_FOLDER
	local ok, visualOrError, reason = pcall(build, player, record, character, folder)
	if not ok then
		folder:Destroy()
		visuals[player] = nil
		warnOnce(player, "build error: " .. tostring(visualOrError))
		return
	end
	local visual = visualOrError :: Visual?
	if not visual then
		folder:Destroy()
		visuals[player] = nil
		warnOnce(player, reason or "unknown")
		return
	end
	folder.Parent = character
	visuals[player] = visual
	lastWarning[player] = nil
	local count = 0
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	print(string.format("[Equipment] %s: gear built (%d parts)", player.Name, count))
	EquipmentService.applyWetness(player, true)
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

-- GearToggle(part, on): show/hide a worn head item, or switch the headlamp.
local function onGearToggle(player: Player, which: string, on: boolean)
	local record = PlayerStore.get(player)
	if not record or not record.ready then
		return
	end
	local attr = TOGGLE_ATTR[which]
	if not attr then
		return
	end
	local RemoteGuard = Registry.get("RemoteGuard")
	if which == "Light" then
		if on then
			if not hasHeadlamp(record) then
				RemoteGuard.notify(player, "You need a helmet with a headlamp.", "warn", "GearToggle", 2)
				player:SetAttribute("GearLight", false)
				return
			end
			player:SetAttribute("GearHelmet", true) -- turning the lamp on puts the helmet back on show
		end
		player:SetAttribute("GearLight", on)
	else
		local slot = if which == "Helmet" then "Head" elseif which == "Mask" then "Face" else "Eyes"
		if not record.worn[slot] then
			RemoteGuard.notify(player, "You're not wearing that.", "warn", "GearToggle", 2)
			return
		end
		player:SetAttribute(attr, on)
		if which == "Helmet" and not on then
			player:SetAttribute("GearLight", false)
		end
	end
	EquipmentService.refresh(player)
	applyLight(player)
end

function EquipmentService.Init()
	Registry.get("RemoteGuard").on("GearToggle", onGearToggle)
end

function EquipmentService.Start()
	local InventoryService = Registry.get("InventoryService")
	InventoryService.Changed:Connect(function(player)
		EquipmentService.refresh(player)
	end)

	local function watch(player: Player)
		for attr, default in TOGGLE_DEFAULT do
			if typeof(player:GetAttribute(attr)) ~= "boolean" then
				player:SetAttribute(attr, default)
			end
		end
		player:GetAttributeChangedSignal("Wetness"):Connect(function()
			EquipmentService.applyWetness(player)
		end)
		player.CharacterAdded:Connect(function(character)
			visuals[player] = nil
			-- Accessories load after spawn; keep hats and hair hidden under a shown helmet.
			character.ChildAdded:Connect(function(child)
				if child:IsA("Accessory") then
					task.defer(function()
						local record = PlayerStore.get(player)
						if record and helmetShown(player, record) then
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
		lastWarning[player] = nil
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
