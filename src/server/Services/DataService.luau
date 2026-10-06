--!strict
-- Persistent player data (progression, unlocks, saved loadout, achievements, settings).
-- The expedition itself (pack contents, injuries, position) is deliberately NOT persisted:
-- an expedition is a session with friends; your progress and gear unlocks are what carry over.
--
-- Safety rules, in order of importance:
--   * Never overwrite good data with defaults. If a load fails we run the session
--     read-only (nothing is saved) and tell the player.
--   * Session locking: a profile is locked to one server (JobId) so two servers can't
--     write over each other when a player hops quickly. Stale locks (crashed server)
--     are stolen after LOCK_STALE_SECONDS.
--   * Every DataStore call is retried with exponential backoff.
--   * Saves on leave, on an autosave timer, and on shutdown (BindToClose).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local ItemDefs = require(Shared.Config.ItemDefs)
local RecipeDefs = require(Shared.Config.RecipeDefs)
local Signal = require(Shared.Util.Signal)

local DataService = {}

local STORE_NAME = "MountainProfiles_v1"
local SCHEMA_VERSION = 1
local MAX_ATTEMPTS = 5
local LOCK_STALE_SECONDS = 600
local LOCK_RETRY_SECONDS = 4
local LOCK_RETRIES = 6

export type Profile = {
	schema: number,
	xp: number,
	loadout: { [string]: string }, -- slot -> item id ("Backpack" included)
	blueprints: { [string]: boolean },
	achievements: { [string]: number },
	totals: {
		expeditions: number,
		sectionsCompleted: number,
		summits: number,
		rescues: number,
		checkpoints: number,
		maxElevationM: number,
	},
	settings: { cameraShake: boolean },
}

type Session = {
	data: Profile,
	readOnly: boolean,
	dirty: boolean,
	saving: boolean,
	released: boolean, -- a lock-releasing (final) save has started
}

local store: DataStore? = nil
local sessions: { [Player]: Session } = {}
local loading: { [Player]: boolean } = {}
-- userId -> number of final (lock-releasing) saves still in flight for a session that left.
local releasing: { [number]: number } = {}

DataService.ProfileLoaded = Signal.new() -- (player, profile, readOnly)

local function defaultProfile(): Profile
	local blueprints = {}
	for _, recipe in RecipeDefs.List do
		if recipe.unlockedByDefault then
			blueprints[recipe.id] = true
		end
	end
	return {
		schema = SCHEMA_VERSION,
		xp = 0,
		loadout = {},
		blueprints = blueprints,
		achievements = {},
		totals = {
			expeditions = 0,
			sectionsCompleted = 0,
			summits = 0,
			rescues = 0,
			checkpoints = 0,
			maxElevationM = 0,
		},
		settings = { cameraShake = true },
	}
end

-- Repairs anything malformed instead of trusting stored data blindly. Unknown item ids
-- (removed from the game) are dropped; numbers are clamped.
local function sanitize(raw: any): Profile
	local profile = defaultProfile()
	if typeof(raw) ~= "table" then
		return profile
	end
	if typeof(raw.xp) == "number" and raw.xp == raw.xp then
		profile.xp = math.clamp(math.floor(raw.xp), 0, 1e9)
	end
	if typeof(raw.loadout) == "table" then
		for slot, itemId in raw.loadout do
			if typeof(slot) == "string" and typeof(itemId) == "string" and ItemDefs.ById[itemId] then
				profile.loadout[slot] = itemId
			end
		end
	end
	if typeof(raw.blueprints) == "table" then
		for id, unlocked in raw.blueprints do
			if typeof(id) == "string" and RecipeDefs.ById[id] and unlocked == true then
				profile.blueprints[id] = true
			end
		end
	end
	if typeof(raw.achievements) == "table" then
		for id, t in raw.achievements do
			if typeof(id) == "string" and typeof(t) == "number" then
				profile.achievements[id] = t
			end
		end
	end
	if typeof(raw.totals) == "table" then
		for key in profile.totals do
			local v = raw.totals[key]
			if typeof(v) == "number" and v == v then
				(profile.totals :: any)[key] = math.clamp(v, 0, 1e9)
			end
		end
	end
	if typeof(raw.settings) == "table" and typeof(raw.settings.cameraShake) == "boolean" then
		profile.settings.cameraShake = raw.settings.cameraShake
	end
	return profile
end

local function retry<T>(label: string, fn: () -> T): (boolean, T?)
	local delay = 1
	for attempt = 1, MAX_ATTEMPTS do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(
			string.format("[DataService] %s failed (attempt %d/%d): %s", label, attempt, MAX_ATTEMPTS, tostring(result))
		)
		if attempt < MAX_ATTEMPTS then
			task.wait(delay)
			delay = math.min(delay * 2, 16)
		end
	end
	return false, nil
end

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

local function keyFor(player: Player): string
	return "u_" .. player.UserId
end

-- Load with session lock. Returns profile and whether the session must be read-only.
local function load(player: Player): (Profile, boolean)
	if not store then
		return defaultProfile(), false -- Studio without API access: in-memory session
	end
	local jobId = if game.JobId ~= "" then game.JobId else "studio"
	for lockAttempt = 1, LOCK_RETRIES do
		local lockedElsewhere = false
		local ok, stored = retry("load " .. player.Name, function()
			return (store :: DataStore):UpdateAsync(keyFor(player), function(old)
				local now = os.time()
				lockedElsewhere = false -- the transform can run more than once; judge the latest `old`
				if typeof(old) == "table" and typeof(old.lock) == "table" then
					local lock = old.lock
					if
						lock.jobId ~= jobId
						and typeof(lock.time) == "number"
						and now - lock.time < LOCK_STALE_SECONDS
					then
						lockedElsewhere = true
						return nil -- abort the write, keep the other server's lock
					end
				end
				local data = if typeof(old) == "table" then old else {}
				data.lock = { jobId = jobId, time = now }
				return data
			end)
		end)
		if not ok then
			return defaultProfile(), true -- DataStore down: play, but never save over real data
		end
		if not lockedElsewhere then
			return sanitize(if typeof(stored) == "table" then stored.profile else nil), false
		end
		if not player.Parent then
			return defaultProfile(), true
		end
		warn(string.format("[DataService] %s is locked by another server (attempt %d)", player.Name, lockAttempt))
		task.wait(LOCK_RETRY_SECONDS)
	end
	return defaultProfile(), true
end

-- Clears our session lock without writing profile data. Used when a player leaves while
-- their load is still in flight (the load took the lock, but no session exists to save).
local function releaseLock(player: Player)
	if not store then
		return
	end
	local jobId = if game.JobId ~= "" then game.JobId else "studio"
	retry("unlock " .. player.Name, function()
		return (store :: DataStore):UpdateAsync(keyFor(player), function(old)
			if typeof(old) == "table" and typeof(old.lock) == "table" and old.lock.jobId == jobId then
				old.lock = nil
				return old
			end
			return nil -- not our lock (or no lock): leave it alone
		end)
	end)
end

local function save(player: Player, release: boolean): boolean
	local session = sessions[player]
	if not session or session.readOnly or not store then
		return true
	end
	if session.saving and not release then
		return true -- an autosave is in flight; the next one will pick up changes
	end
	session.saving = true
	if release then
		session.released = true
	end
	local jobId = if game.JobId ~= "" then game.JobId else "studio"
	-- Deep copy: UpdateAsync may run the transform later, and gameplay keeps mutating the live table.
	local snapshot = deepCopy(session.data)
	local ok = retry("save " .. player.Name, function()
		return (store :: DataStore):UpdateAsync(keyFor(player), function(old)
			local data = if typeof(old) == "table" then old else {}
			-- If another server stole our lock (we were presumed dead), don't clobber it.
			if typeof(data.lock) == "table" and data.lock.jobId ~= jobId then
				return nil
			end
			-- An autosave that was still in flight when the player left must not land after the
			-- final save: it would re-take the lock (locking the player out of other servers)
			-- and write an older snapshot over the final one.
			if not release and session.released then
				return nil
			end
			data.profile = snapshot
			data.lock = if release then nil else { jobId = jobId, time = os.time() }
			return data
		end)
	end)
	session.saving = false
	if ok then
		session.dirty = false
	end
	return ok
end

function DataService.Init()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[DataService] DataStore unavailable, profiles are in-memory only: " .. tostring(result))
	end
	if RunService:IsStudio() then
		-- Studio without "Enable Studio Access to API Services" throws on first use; probe once.
		local probeOk = pcall(function()
			if store then
				store:GetAsync("probe")
			end
		end)
		if not probeOk then
			warn("[DataService] Studio has no DataStore access; running in-memory.")
			store = nil
		end
	end
end

function DataService.Start()
	Players.PlayerAdded:Connect(function(player)
		DataService.loadPlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		-- Deferred, not spawned: with no DataStore (Studio) load() never yields, so a spawned
		-- load would fire ProfileLoaded right now, before ProgressionService/PlayerService
		-- (which Start after us) have connected, and the player would never become ready.
		task.defer(DataService.loadPlayer, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		releasing[userId] = (releasing[userId] or 0) + 1
		save(player, true)
		sessions[player] = nil
		releasing[userId] -= 1
		if releasing[userId] <= 0 then
			releasing[userId] = nil
		end
	end)

	task.spawn(function()
		while true do
			task.wait(GameConfig.AUTOSAVE_SECONDS)
			for player in sessions do
				task.spawn(save, player, false)
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for player in sessions do
			pending += 1
			task.spawn(function()
				save(player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.25)
		end
	end)
end

function DataService.loadPlayer(player: Player)
	if sessions[player] or loading[player] then
		return
	end
	loading[player] = true
	-- Quick rejoin to this same server: the previous session's final save may still be in
	-- flight. Loading now would read stale data, and that save would then clear the lock
	-- this new session just took. Wait for it (bounded).
	local deadline = os.clock() + 30
	while releasing[player.UserId] and os.clock() < deadline and player.Parent do
		task.wait(0.5)
	end
	local profile, readOnly = load(player)
	loading[player] = nil
	if not player.Parent then
		-- Left mid-load: load() took the session lock but no session exists to release it,
		-- which would lock the player out of every other server for LOCK_STALE_SECONDS.
		if not readOnly and not Players:GetPlayerByUserId(player.UserId) then
			releaseLock(player)
		end
		return
	end
	sessions[player] = { data = profile, readOnly = readOnly, dirty = false, saving = false, released = false }
	DataService.ProfileLoaded:Fire(player, profile, readOnly)
end

function DataService.get(player: Player): Profile?
	local session = sessions[player]
	return if session then session.data else nil
end

function DataService.isReadOnly(player: Player): boolean
	local session = sessions[player]
	return session == nil or session.readOnly
end

function DataService.markDirty(player: Player)
	local session = sessions[player]
	if session then
		session.dirty = true
	end
end

return DataService
