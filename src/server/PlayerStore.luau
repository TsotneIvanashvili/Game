--!strict
-- The single server-side record per player. Services read and mutate it; nothing on the
-- client is ever authoritative over these fields.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SurvivalModel = require(Shared.Logic.SurvivalModel)
local InventoryModel = require(Shared.Logic.InventoryModel)

export type ExpeditionStats = {
	startedAt: number,
	maxElevationM: number,
	distanceStuds: number,
	highestCheckpoint: number,
	weatherSurvived: { [string]: boolean },
	disastersSurvived: number,
	teammatesRescued: number,
	itemsConsumed: number,
	injuries: number,
	resourcesCollected: number,
	sectionComplete: boolean,
}

export type Record = {
	player: Player,
	ready: boolean,
	profile: any, -- DataService profile data (persisted)
	survival: SurvivalModel.State,
	inventory: InventoryModel.Inventory,
	worn: { [string]: string }, -- clothing slot -> item id
	backpackId: string,
	heldUid: string?, -- inventory stack held in hand (ice axe)

	-- Movement / action state.
	sprintRequested: boolean,
	exertion: string,
	climbing: { normal: Vector3, lastY: number, startedAt: number }?,
	resting: boolean,
	restingAtCamp: boolean,
	downed: boolean,
	bleedOut: number,
	carrying: Player?,
	carriedBy: Player?,

	-- Fall tracking.
	peakY: number?,
	airborne: boolean,

	-- Expedition-scoped bookkeeping.
	checkpoint: number,
	outfitterTaken: { [string]: boolean },
	supplyTaken: { [string]: { [string]: number } },
	stats: ExpeditionStats,
	lastPosition: Vector3?,
	lostSince: number?,

	-- Movement sanity (anti speed-hack / fly-hack).
	lastGoodPosition: Vector3?,
	speedViolation: number,
	groundY: number?,
}

local PlayerStore = {}

local records: { [Player]: Record } = {}

function PlayerStore.create(player: Player): Record
	local record: Record = {
		player = player,
		ready = false,
		profile = nil,
		survival = SurvivalModel.newState(),
		inventory = InventoryModel.new(),
		worn = {},
		backpackId = "daypack_small",
		heldUid = nil,
		sprintRequested = false,
		exertion = "idle",
		climbing = nil,
		resting = false,
		restingAtCamp = false,
		downed = false,
		bleedOut = 0,
		carrying = nil,
		carriedBy = nil,
		peakY = nil,
		airborne = false,
		checkpoint = 1,
		outfitterTaken = {},
		supplyTaken = {},
		stats = {
			startedAt = os.time(),
			maxElevationM = 0,
			distanceStuds = 0,
			highestCheckpoint = 1,
			weatherSurvived = {},
			disastersSurvived = 0,
			teammatesRescued = 0,
			itemsConsumed = 0,
			injuries = 0,
			resourcesCollected = 0,
			sectionComplete = false,
		},
		lastPosition = nil,
		lostSince = nil,
		lastGoodPosition = nil,
		speedViolation = 0,
		groundY = nil,
	}
	records[player] = record
	return record
end

-- Re-attach a stashed record (disconnect/rejoin within the grace window).
function PlayerStore.restore(player: Player, record: Record)
	records[player] = record
end

-- Call after any server-side teleport so movement checks and fall tracking start fresh
-- instead of reading the jump as a speed hack or a fall.
function PlayerStore.teleported(record: Record)
	record.lastPosition = nil
	record.lastGoodPosition = nil
	record.speedViolation = 0
	record.groundY = nil
	record.peakY = nil
end

function PlayerStore.get(player: Player): Record?
	return records[player]
end

-- Returns the record only when the player is fully loaded and has a live character.
function PlayerStore.getActive(player: Player): (Record?, Model?, Humanoid?, BasePart?)
	local record = records[player]
	if not record or not record.ready then
		return nil
	end
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.Health <= 0 then
		return nil
	end
	return record, character, humanoid, root
end

function PlayerStore.remove(player: Player)
	records[player] = nil
end

function PlayerStore.all(): { [Player]: Record }
	return records
end

return PlayerStore
