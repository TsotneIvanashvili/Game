--!strict
-- Creates every remote declared in Shared/Net/Remotes and is the ONLY place server code
-- connects to client input. Every request is:
--   1. rate limited per player per remote (token bucket),
--   2. validated against its schema (types, ranges, NaN/inf, argument count),
--   3. dispatched inside pcall so a handler bug can't break the remote for everyone.
-- Rejections are counted; a player who floods garbage is logged (kicking is left as a
-- config decision, see SUSPICION_KICK_THRESHOLD).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local Validate = require(Shared.Util.Validate)

local RemoteGuard = {}

local SUSPICION_KICK_THRESHOLD = 0 -- 0 = never kick automatically; set >0 once tuned in live tests
local SUSPICION_LOG_EVERY = 25

type Bucket = { tokens: number, last: number }

local folder: Folder
local remotes: { [string]: RemoteEvent | RemoteFunction } = {}
local handlers: { [string]: (Player, ...any) -> ...any } = {}
local buckets: { [Player]: { [string]: Bucket } } = {}
local suspicion: { [Player]: number } = {}

local function flag(player: Player, remoteName: string, reason: string)
	local count = (suspicion[player] or 0) + 1
	suspicion[player] = count
	if count % SUSPICION_LOG_EVERY == 1 then
		warn(string.format("[RemoteGuard] %s rejected on %s: %s (total %d)", player.Name, remoteName, reason, count))
	end
	if SUSPICION_KICK_THRESHOLD > 0 and count >= SUSPICION_KICK_THRESHOLD then
		player:Kick("Connection problem detected. Please rejoin.")
	end
end

local function allow(player: Player, name: string, spec: Remotes.RemoteSpec): boolean
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local now = os.clock()
	local bucket = perPlayer[name]
	if not bucket then
		bucket = { tokens = spec.burst, last = now }
		perPlayer[name] = bucket
	end
	bucket.tokens = math.min(spec.burst, bucket.tokens + (now - bucket.last) * spec.ratePerSecond)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function gate(player: Player, name: string, spec: Remotes.RemoteSpec, ...: any): boolean
	if not player.Parent then
		return false
	end
	if not allow(player, name, spec) then
		flag(player, name, "rate limit")
		return false
	end
	local args = table.pack(...)
	local ok, reason = Validate.args(spec.schema, args, args.n)
	if not ok then
		flag(player, name, reason or "invalid")
		return false
	end
	if not handlers[name] then
		return false
	end
	return true
end

function RemoteGuard.Init()
	folder = Instance.new("Folder")
	folder.Name = Remotes.FOLDER_NAME

	for name, spec in Remotes.ClientToServer do
		if spec.kind == "Event" then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
			remote.OnServerEvent:Connect(function(player, ...)
				if not gate(player, name, spec, ...) then
					return
				end
				local ok, err = pcall(handlers[name], player, ...)
				if not ok then
					warn("[RemoteGuard] " .. name .. " handler error: " .. tostring(err))
				end
			end)
			remotes[name] = remote
		else
			local remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = folder
			remote.OnServerInvoke = function(player, ...)
				if not gate(player, name, spec, ...) then
					return false, "Request rejected."
				end
				local results = table.pack(pcall(handlers[name], player, ...))
				if not results[1] then
					warn("[RemoteGuard] " .. name .. " handler error: " .. tostring(results[2]))
					return false, "Something went wrong."
				end
				return table.unpack(results, 2, results.n)
			end
			remotes[name] = remote
		end
	end

	for _, name in Remotes.ServerToClient do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		remotes[name] = remote
	end

	folder.Parent = ReplicatedStorage

	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
		suspicion[player] = nil
	end)
end

-- Register the single handler for a client->server remote.
function RemoteGuard.on(name: string, handler: (Player, ...any) -> ...any)
	assert(Remotes.ClientToServer[name], "unknown remote " .. name)
	assert(handlers[name] == nil, "handler already registered for " .. name)
	handlers[name] = handler
end

function RemoteGuard.fire(player: Player, name: string, ...: any)
	local remote = remotes[name]
	assert(remote and remote:IsA("RemoteEvent"), "unknown server event " .. name)
	if player.Parent then
		local event = remote :: RemoteEvent
		event:FireClient(player, ...)
	end
end

function RemoteGuard.fireAll(name: string, ...: any)
	local remote = remotes[name]
	assert(remote and remote:IsA("RemoteEvent"), "unknown server event " .. name)
	local event = remote :: RemoteEvent
	event:FireAllClients(...)
end

-- Severity: "info" | "good" | "warn" | "danger". `key` enables per-key cooldowns.
local lastNotify: { [Player]: { [string]: number } } = {}
function RemoteGuard.notify(player: Player, text: string, severity: string?, key: string?, cooldown: number?)
	if key then
		local perPlayer = lastNotify[player]
		if not perPlayer then
			perPlayer = {}
			lastNotify[player] = perPlayer
		end
		local now = os.clock()
		if perPlayer[key] and now - perPlayer[key] < (cooldown or 20) then
			return
		end
		perPlayer[key] = now
	end
	RemoteGuard.fire(player, "Notify", text, severity or "info", key)
end

function RemoteGuard.notifyAll(text: string, severity: string?)
	RemoteGuard.fireAll("Notify", text, severity or "info")
end

Players.PlayerRemoving:Connect(function(player)
	lastNotify[player] = nil
end)

return RemoteGuard
