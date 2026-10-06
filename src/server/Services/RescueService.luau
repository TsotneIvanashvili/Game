--!strict
-- Downed state, revives, carrying and evacuation (design sections 41-42).
--
-- Reaching 0 HP (or passing out from hypothermia) never kills you outright. You are DOWNED:
-- you can crawl, your bleed-out timer runs, and teammates can revive you (a first aid kit
-- makes the revive much stronger), treat you from their pack, or carry you to a fire.
-- If the timer runs out you are EVACUATED: you wake at your last signed camp, but your pack
-- contents stay on the mountain where you fell, recoverable by anyone. One mistake costs
-- you time and gear, not your expedition.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local InjuryModel = require(Shared.Logic.InjuryModel)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)
local PromptUtil = require(script.Parent.PromptUtil)

local RescueService = {}

type CarryState = { weld: WeldConstraint, changed: { BasePart } }

local carryStates: { [Player]: CarryState } = {} -- keyed by carrier
local downedUi: { [Player]: { prompts: { ProximityPrompt }, gui: BillboardGui? } } = {}

local function remote()
	return Registry.get("RemoteGuard")
end

local function rootOf(player: Player): BasePart?
	return player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function clearDownedUi(player: Player)
	local ui = downedUi[player]
	if ui then
		for _, p in ui.prompts do
			if p.Parent then
				(p.Parent :: Instance):Destroy() -- the prompt's attachment
			end
		end
		if ui.gui then
			ui.gui:Destroy()
		end
	end
	downedUi[player] = nil
end

-- Carrying ------------------------------------------------------------------------------------

function RescueService.release(carrier: Player)
	local state = carryStates[carrier]
	carryStates[carrier] = nil
	local record = PlayerStore.get(carrier)
	local target = record and record.carrying
	if record then
		record.carrying = nil
	end
	carrier:SetAttribute("Carrying", nil)
	if state then
		if state.weld.Parent then
			state.weld:Destroy()
		end
		for _, part in state.changed do
			if part.Parent then
				part.Massless = false
			end
		end
	end
	if target then
		local targetRecord = PlayerStore.get(target)
		if targetRecord and targetRecord.carriedBy ~= carrier then
			return -- stale link; the target is not ours to release (never touch another carry)
		end
		if targetRecord then
			targetRecord.carriedBy = nil
			targetRecord.peakY = nil
		end
		target:SetAttribute("CarriedBy", nil)
		local targetRoot = rootOf(target)
		local carrierRoot = rootOf(carrier)
		local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.PlatformStand = false
		end
		if targetRoot then
			if carrierRoot then
				targetRoot.CFrame = carrierRoot.CFrame * CFrame.new(2.5, 0, 0)
			end
			pcall(function()
				targetRoot:SetNetworkOwner(target)
			end)
		end
	end
end

-- Release any carry relationship this player is part of (either side).
function RescueService.releaseAll(player: Player)
	local record = PlayerStore.get(player)
	if not record then
		return
	end
	if record.carrying then
		RescueService.release(player)
	end
	if record.carriedBy then
		RescueService.release(record.carriedBy)
	end
end

-- The player's character is dying or being replaced. Drop any carry relationship and the
-- downed prompts/marker so nothing keeps pointing at (or welded to) the old character.
-- Without this a carrier who died/respawned left the target flagged `carriedBy` forever
-- (PlatformStand, massless, uncarryable).
function RescueService.resetCharacter(player: Player)
	RescueService.releaseAll(player)
	clearDownedUi(player)
end

local function carry(carrier: Player, target: Player)
	local cRecord, _, _, cRoot = PlayerStore.getActive(carrier)
	local tRecord, tChar, tHumanoid, tRoot = PlayerStore.getActive(target)
	if not cRecord or not tRecord or not cRoot or not tRoot or not tChar or not tHumanoid then
		return
	end
	if carrier == target or cRecord.downed or cRecord.carrying or cRecord.carriedBy or cRecord.climbing then
		return
	end
	if not tRecord.downed or tRecord.carriedBy then
		return
	end
	if (cRoot.Position - tRoot.Position).Magnitude > GameConfig.INTERACT_RANGE then
		return
	end
	if cRecord.resting then
		Registry.get("SurvivalService").setResting(carrier, false)
	end
	-- Fireman's carry: across the shoulders, massless so the carrier's physics stay sane.
	local changed = {}
	for _, d in tChar:GetDescendants() do
		if d:IsA("BasePart") and not d.Massless then
			d.Massless = true
			table.insert(changed, d)
		end
	end
	tHumanoid.PlatformStand = true
	tRoot.CFrame = cRoot.CFrame * CFrame.new(0, 1.6, 0.4) * CFrame.Angles(0, 0, math.rad(90))
	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = cRoot
	weld.Part1 = tRoot
	weld.Parent = cRoot
	pcall(function()
		cRoot:SetNetworkOwner(carrier)
	end)
	carryStates[carrier] = { weld = weld, changed = changed }
	cRecord.carrying = target
	tRecord.carriedBy = carrier
	carrier:SetAttribute("Carrying", target.DisplayName)
	target:SetAttribute("CarriedBy", carrier.DisplayName)
	remote().notify(carrier, "You're carrying " .. target.DisplayName .. ". Press X to set them down.", "info")
	remote().notify(target, carrier.DisplayName .. " is carrying you.", "good")
end

-- Downed / revive -----------------------------------------------------------------------------

function RescueService.down(player: Player, cause: string)
	local record, character, humanoid, root = PlayerStore.getActive(player)
	if not record or record.downed or not character or not humanoid or not root then
		return
	end
	record.downed = true
	record.bleedOut = GameConfig.BLEED_OUT_SECONDS
	record.stats.injuries += 1
	Registry.get("ClimbingService").forceStop(player, "")
	if record.resting then
		Registry.get("SurvivalService").setResting(player, false)
	end
	if record.carrying then
		RescueService.release(player)
	end
	humanoid.Health = 1
	player:SetAttribute("Downed", true)
	player:SetAttribute("BleedOut", record.bleedOut)

	local prompts = {}
	table.insert(
		prompts,
		PromptUtil.create(root, {
			action = "Revive",
			object = player.DisplayName,
			key = Enum.KeyCode.E,
			hold = GameConfig.REVIVE_HOLD_SECONDS,
			distance = 8,
			name = "RevivePrompt",
		}, function(rescuer)
			RescueService.revive(rescuer, player)
		end)
	)
	table.insert(
		prompts,
		PromptUtil.create(root, {
			action = "Carry",
			object = player.DisplayName,
			key = Enum.KeyCode.F,
			hold = 1,
			distance = 8,
			offset = Vector3.new(0, 1.5, 0),
			name = "CarryPrompt",
		}, function(carrier)
			carry(carrier, player)
		end)
	)
	for _, p in prompts do
		p:SetAttribute("OwnerUserId", player.UserId) -- the downed player's client hides its own prompts
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "DownedMarker"
	gui.Size = UDim2.fromOffset(160, 40)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 500
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 80, 70)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "DOWNED"
	label.Parent = gui
	gui.Parent = root
	downedUi[player] = { prompts = prompts, gui = gui }

	remote().notifyAll(player.DisplayName .. " is down (" .. cause .. ")! Revive or carry them to a fire.", "danger")
	remote().notify(
		player,
		"You're down. Crawl to cover; your team can revive you, or give up to be evacuated.",
		"danger"
	)
end

function RescueService.revive(rescuer: Player, target: Player)
	if rescuer == target then
		return
	end
	local rRecord, _, _, rRoot = PlayerStore.getActive(rescuer)
	local tRecord, _, tHumanoid, tRoot = PlayerStore.getActive(target)
	if not rRecord or not tRecord or not rRoot or not tRoot or not tHumanoid then
		return
	end
	if rRecord.downed or not tRecord.downed then
		return
	end
	if (rRoot.Position - tRoot.Position).Magnitude > GameConfig.INTERACT_RANGE then
		return
	end
	local InventoryService = Registry.get("InventoryService")
	local health = GameConfig.REVIVE_HEALTH
	local usedKit = false
	if
		InventoryService.count(rescuer, "first_aid_kit") > 0
		and InventoryService.removeAll(rescuer, { first_aid_kit = 1 })
	then
		health = GameConfig.REVIVE_HEALTH_WITH_KIT
		usedKit = true
		InjuryModel.remove(tRecord.survival.injuries, "Bleeding")
	end
	if tRecord.carriedBy then
		RescueService.release(tRecord.carriedBy)
	end
	tRecord.downed = false
	tRecord.bleedOut = 0
	tRecord.survival.criticalColdTime = 0
	tHumanoid.Health = health
	target:SetAttribute("Downed", false)
	target:SetAttribute("BleedOut", nil)
	clearDownedUi(target)
	rRecord.stats.teammatesRescued += 1
	local profile = Registry.get("DataService").get(rescuer)
	if profile then
		profile.totals.rescues += 1
		Registry.get("DataService").markDirty(rescuer)
	end
	Registry.get("ProgressionService").award(rescuer, ProgressionConfig.XP.Revive, "Revived " .. target.DisplayName)
	remote().notify(
		target,
		rescuer.DisplayName .. " got you back on your feet" .. (if usedKit then " with a first aid kit." else "."),
		"good"
	)
	remote().notifyAll(rescuer.DisplayName .. " revived " .. target.DisplayName .. ".", "good")
end

-- Bleed-out ran out (or the player gave up): wake at the last camp, pack left behind.
local evacuating: { [Player]: boolean } = {}

-- `leaving`: the player disconnected while downed. Same outcome as bleeding out (pack left
-- where they fell, stats floored) but no respawn; the emptied record is what PlayerService
-- stashes, so the pack exists exactly once (on the ground) and a disconnect can't be used
-- to dodge the evacuation penalty.
function RescueService.evacuate(player: Player, leaving: boolean?)
	local record = PlayerStore.get(player)
	if not record or evacuating[player] then
		return
	end
	evacuating[player] = true
	RescueService.releaseAll(player)
	local root = rootOf(player)
	local dropAt = if root then root.Position else record.lastPosition
	local InventoryService = Registry.get("InventoryService")
	local stacks = InventoryService.takeAll(player)
	if dropAt and #stacks > 0 then
		local ground = {}
		for _, s in stacks do
			table.insert(ground, { itemId = s.itemId, qty = s.qty, data = s.data })
		end
		Registry.get("ResourceService").spawnContainer("Pack", ground, dropAt, player.DisplayName)
	end
	clearDownedUi(player)
	record.downed = false
	record.bleedOut = 0
	player:SetAttribute("Downed", false)
	player:SetAttribute("BleedOut", nil)

	-- The rescue team patched you up, but you are spent.
	local s = record.survival
	local floor = GameConfig.EVACUATION_STAT_FLOOR
	s.hunger = math.max(s.hunger, floor.Hunger)
	s.thirst = math.max(s.thirst, floor.Thirst)
	for region, w in s.warmth do
		s.warmth[region] = math.max(w, floor.Warmth)
	end
	for region in s.frostExposure do
		s.frostExposure[region] = 0
	end
	table.clear(s.injuries)
	s.wetness = 0
	s.criticalColdTime = 0
	s.fatigue = math.min(100, s.fatigue + 25)
	s.stamina = 40
	InventoryService.add(player, "water_bottle", 1, { ml = 500, treated = true }, true)
	InventoryService.add(player, "energy_bar", 1, nil, true)
	InventoryService.sync(player)

	if leaving then
		evacuating[player] = nil
		remote().notifyAll(player.DisplayName .. " left while down. Their pack is still on the mountain.", "warn")
		return
	end
	if player.Parent then
		player:LoadCharacter() -- PlayerService moves the new character to the last camp
	end
	evacuating[player] = nil
	remote().notify(player, "You were evacuated to your last camp. Your gear is where you fell.", "warn")
	remote().notifyAll(player.DisplayName .. " was evacuated. Their pack is still on the mountain.", "warn")
end

function RescueService.Init()
	local RemoteGuard = Registry.get("RemoteGuard")
	RemoteGuard.on("DropCarried", function(player)
		local record = PlayerStore.get(player)
		if record and record.carrying then
			RescueService.release(player)
		end
	end)
	RemoteGuard.on("GiveUp", function(player)
		local record = PlayerStore.get(player)
		if record and record.downed then
			RescueService.evacuate(player)
		end
	end)
end

function RescueService.Start()
	Players.PlayerRemoving:Connect(function(player)
		RescueService.releaseAll(player)
		clearDownedUi(player)
		evacuating[player] = nil
	end)

	-- Bleed-out clock and carry upkeep, once a second.
	task.spawn(function()
		while true do
			task.wait(1)
			for player, record in PlayerStore.all() do
				-- pcall per player: one bad record must not kill this loop (and every
				-- future bleed-out) for the whole server.
				local ok, err = pcall(function()
					if record.downed then
						local root = rootOf(player)
						local rate = 1
						if InjuryModel.has(record.survival.injuries, "Bleeding") then
							rate *= 1.5
						end
						if record.carriedBy then
							rate *= 0.5
						end
						if root and Registry.get("BuildingService").environmentAt(root.Position).fireHeatC > 0 then
							rate *= 0.5
						end
						record.bleedOut -= rate
						player:SetAttribute("BleedOut", math.max(0, math.floor(record.bleedOut)))
						local ui = downedUi[player]
						local label = ui and ui.gui and ui.gui:FindFirstChild("Label") :: TextLabel?
						if label then
							local secs = math.max(0, math.floor(record.bleedOut))
							label.Text = string.format("DOWNED  %d:%02d", secs // 60, secs % 60)
						end
						if record.bleedOut <= 0 then
							record.bleedOut = math.huge -- guard against re-entry while evacuating
							task.spawn(RescueService.evacuate, player) -- LoadCharacter yields
						end
					end
					-- A carrier who starts climbing or goes down drops their load. Also drop it if
					-- the target's side of the relationship or character is gone (defensive).
					local target = record.carrying
					if target then
						local targetRecord = PlayerStore.get(target)
						local exhausted = record.survival.stamina <= 0
						if exhausted and not record.climbing and not record.downed then
							remote().notify(
								player,
								"You're spent and have to set " .. target.DisplayName .. " down.",
								"warn"
							)
						end
						if
							exhausted
							or record.climbing
							or record.downed
							or not target.Parent
							or not targetRecord
							or targetRecord.carriedBy ~= player
							or not rootOf(target)
						then
							RescueService.release(player)
						end
					end
				end)
				if not ok then
					warn("[RescueService] tick error for " .. player.Name .. ": " .. tostring(err))
				end
			end
		end
	end)
end

return RescueService
