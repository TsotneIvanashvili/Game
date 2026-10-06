--!strict
-- Player lifecycle: join -> profile load -> loadout -> ready; character spawn -> placed at
-- the last signed camp, gear rebuilt; leave -> carry released, expedition state stashed.
--
-- Disconnect/rejoin: a player's expedition (pack, injuries, checkpoint, stats) is kept for
-- REJOIN_GRACE_SECONDS. Rejoining the same server restores it, so a dropped connection
-- doesn't wipe your progress. The pack is never also dropped in the world, so the stash is
-- the only copy: no duplication.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)

local PlayerService = {}

local REJOIN_GRACE_SECONDS = 600

type Stash = { at: number, record: PlayerStore.Record }
local departed: { [number]: Stash } = {}

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not root or character.Parent == nil then
		return
	end
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = GameConfig.JUMP_HEIGHT
	humanoid.WalkSpeed = GameConfig.WALK_SPEED

	local record = PlayerStore.get(player)
	if record then
		record.climbing = nil
		record.resting = false
		record.carrying = nil
		record.carriedBy = nil
		record.peakY = nil
		record.lastPosition = nil
		player:SetAttribute("Climbing", false)
		player:SetAttribute("Carrying", nil)
		player:SetAttribute("CarriedBy", nil)
		-- Respawns go to the last camp whose logbook you signed.
		if record.checkpoint > 1 then
			local spawn = Registry.get("CampService").spawnFor(record)
			if spawn then
				task.defer(function()
					if character.Parent then
						character:PivotTo(spawn + Vector3.new(math.random(-4, 4), 0, math.random(-4, 4)))
					end
				end)
			end
		end
	end

	humanoid.Died:Connect(function()
		-- Deaths bypassing the downed system (e.g. exploits, engine kill planes) just respawn.
		local r = PlayerStore.get(player)
		if r then
			r.downed = false
			player:SetAttribute("Downed", false)
		end
	end)

	Registry.get("SurvivalService").refreshCharacterFilter()
	-- Appearance (body parts) can still be loading; build gear once it settles.
	task.delay(0.5, function()
		if character.Parent then
			Registry.get("EquipmentService").refresh(player, true)
		end
	end)
	if not player:HasAppearanceLoaded() then
		task.spawn(function()
			player.CharacterAppearanceLoaded:Wait()
			if character.Parent then
				Registry.get("EquipmentService").refresh(player, true)
			end
		end)
	end
end

local function onProfileLoaded(player: Player, profile: any, readOnly: boolean)
	local stash = departed[player.UserId]
	departed[player.UserId] = nil
	local record: PlayerStore.Record
	if stash and os.time() - stash.at <= REJOIN_GRACE_SECONDS then
		record = stash.record
		record.player = player
		PlayerStore.restore(player, record)
		Registry.get("RemoteGuard").notify(player, "Welcome back. Your expedition was waiting for you.", "good")
	else
		record = PlayerStore.create(player)
		Registry.get("InventoryService").setupLoadout(player, record, profile)
		local DataService = Registry.get("DataService")
		profile.totals.expeditions += 1
		DataService.markDirty(player)
	end
	record.profile = profile
	record.ready = true
	player:SetAttribute("Checkpoint", record.checkpoint)
	Registry.get("SurvivalService").refreshGear(player)
	Registry.get("InventoryService").sync(player)
	if readOnly then
		Registry.get("RemoteGuard").notify(
			player,
			"Your saved progress couldn't be loaded. You can play, but nothing will be saved this session.",
			"danger"
		)
	end
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

function PlayerService.Init() end

function PlayerService.Start()
	Registry.get("DataService").ProfileLoaded:Connect(onProfileLoaded)

	local function hook(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local record = PlayerStore.get(player)
		if record then
			Registry.get("RescueService").releaseAll(player)
			record.climbing = nil
			record.resting = false
			record.ready = false
			record.downed = false -- you come back conscious; the bleed-out isn't carried over
			departed[player.UserId] = { at = os.time(), record = record }
		end
		PlayerStore.remove(player)
	end)

	-- Expire stale stashes.
	task.spawn(function()
		while true do
			task.wait(60)
			for userId, stash in departed do
				if os.time() - stash.at > REJOIN_GRACE_SECONDS then
					departed[userId] = nil
				end
			end
		end
	end)
end

return PlayerService
