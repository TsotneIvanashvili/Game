--!strict
-- Single source of truth for every remote. The server creates them (Server/Security/RemoteGuard),
-- the client looks them up through `Remotes.get`. Each client->server remote has a schema
-- and a rate limit; the server never handles a request that fails either.
--
-- Most world interactions do NOT use remotes at all: they are server-created
-- ProximityPrompts whose Triggered event already fires on the server with the player.

local Validate = require(script.Parent.Parent.Util.Validate)

export type RemoteSpec = {
	kind: "Event" | "Function",
	schema: { Validate.Checker },
	ratePerSecond: number, -- sustained rate
	burst: number, -- bucket size
}

local MAX_WORLD = 20000

local ClientToServer: { [string]: RemoteSpec } = {
	SetSprint = { kind = "Event", schema = { Validate.boolean() }, ratePerSecond = 8, burst = 12 },
	ReportJump = { kind = "Event", schema = {}, ratePerSecond = 3, burst = 4 },
	ClimbStart = { kind = "Event", schema = { Validate.vector3(1.5) }, ratePerSecond = 4, burst = 6 },
	ClimbStop = { kind = "Event", schema = { Validate.optional(Validate.boolean()) }, ratePerSecond = 6, burst = 8 },
	Ping = { kind = "Event", schema = { Validate.vector3(MAX_WORLD) }, ratePerSecond = 0.5, burst = 3 },
	StopRest = { kind = "Event", schema = {}, ratePerSecond = 4, burst = 4 },
	DropCarried = { kind = "Event", schema = {}, ratePerSecond = 2, burst = 3 },
	GiveUp = { kind = "Event", schema = {}, ratePerSecond = 0.5, burst = 2 },

	-- action, stack uid, optional argument (target userId for Give/Treat, quantity for Drop)
	Inventory = {
		kind = "Function",
		schema = {
			Validate.oneOf({ "Use", "Drop", "Equip", "Unequip", "Give", "Treat", "Hold", "Stow" }),
			Validate.string(12),
			Validate.optional(Validate.integer(1, 2 ^ 53)),
		},
		ratePerSecond = 6,
		burst = 10,
	},
	-- Outfitter: take an item id from the base camp rack.
	Outfit = { kind = "Function", schema = { Validate.string(32) }, ratePerSecond = 4, burst = 8 },
	-- Supply crate: crate id, item id.
	Supply = { kind = "Function", schema = { Validate.string(32), Validate.string(32) }, ratePerSecond = 4, burst = 8 },
	-- Build: recipe id, desired CFrame.
	Build = {
		kind = "Function",
		schema = { Validate.string(32), Validate.cframe(MAX_WORLD) },
		ratePerSecond = 1,
		burst = 3,
	},
	GetSnapshot = { kind = "Function", schema = {}, ratePerSecond = 2, burst = 4 },
	-- Head-gear visibility toggles: Helmet | Mask | Goggles | Light.
	GearToggle = {
		kind = "Event",
		schema = { Validate.oneOf({ "Helmet", "Mask", "Goggles", "Light" }), Validate.boolean() },
		ratePerSecond = 4,
		burst = 8,
	},
}

-- Server -> client events (no schema: the server is trusted).
local ServerToClient = {
	"InventorySync", -- (snapshot)
	"Notify", -- (text, severity, key?)
	"OpenPanel", -- (panelName, data)
	"ClimbForceStop", -- (reason)
	"PingBroadcast", -- (position, fromName, fromUserId)
	"CameraShake", -- (intensity, duration)
	"ExpeditionSummary", -- (stats)
	"PlaySound", -- (soundKey, position?)
	"Banner", -- (text, kind) big orange pill at top centre: "storm", "checkpoint", "info"
}

local Remotes = {
	ClientToServer = ClientToServer,
	ServerToClient = ServerToClient,
	FOLDER_NAME = "Remotes",
}

-- Client-side lookup. Waits for the server to create the folder.
function Remotes.get(name: string): Instance
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:WaitForChild(Remotes.FOLDER_NAME)
	return folder:WaitForChild(name)
end

return Remotes
