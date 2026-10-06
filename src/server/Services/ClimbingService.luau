--!strict
-- Server half of climbing. The client moves its own character (Roblox gives each client
-- physics ownership of its character, so smooth climbing has to be client-driven), but the
-- server decides WHETHER you may climb and for how long:
--   * start: you must be next to a climbable surface (raycast from the server's view of
--     your position), have stamina, not be injured/overloaded/carrying, and hold an ice
--     axe for ice;
--   * every tick: stamina drains (SurvivalModel "climb" exertion), the wall must still be
--     there, and vertical speed must be plausible; otherwise the climb is ended and the
--     client is told to let go.
--
-- Climbable surfaces: terrain materials in ROCK/ICE below, or any part tagged "Climbable"
-- (attribute Ice=true marks a part as ice).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SurvivalConfig = require(Shared.Config.SurvivalConfig)
local ClimbConfig = require(Shared.Config.ClimbConfig)
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(script.Parent.Parent.Registry)
local PlayerStore = require(script.Parent.Parent.PlayerStore)

local ClimbingService = {}

local ROCK: { [Enum.Material]: boolean } = {}
local ICE: { [Enum.Material]: boolean } = {}
for _, name in ClimbConfig.RockMaterials do
	local ok, material = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	if ok and material then
		ROCK[material] = true
	end
end
for _, name in ClimbConfig.IceMaterials do
	local ok, material = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	if ok and material then
		ICE[material] = true
	end
end

local WALL_PROBE = 5.5 -- studs, generous for latency
local SPEED_TOLERANCE = 2.2

export type Surface = "Rock" | "Ice" | "None"

function ClimbingService.classify(result: RaycastResult?): Surface
	if not result then
		return "None"
	end
	local inst = result.Instance
	if inst:IsA("Terrain") then
		if ROCK[result.Material] then
			return "Rock"
		elseif ICE[result.Material] then
			return "Ice"
		end
		return "None"
	end
	if CollectionService:HasTag(inst, ClimbConfig.ClimbableTag) then
		return if inst:GetAttribute("Ice") == true then "Ice" else "Rock"
	end
	return "None"
end

local function probe(root: BasePart, normal: Vector3): RaycastResult?
	local params = Registry.get("SurvivalService").groundRaycastParams()
	-- Probe at chest and at hip height: either touching the wall counts.
	local result = workspace:Raycast(root.Position, -normal * WALL_PROBE, params)
	if not result then
		result = workspace:Raycast(root.Position - Vector3.new(0, 1.5, 0), -normal * WALL_PROBE, params)
	end
	return result
end

local function stop(player: Player, record: PlayerStore.Record, reason: string?)
	record.climbing = nil
	player:SetAttribute("Climbing", false)
	if reason then
		Registry.get("RemoteGuard").fire(player, "ClimbForceStop", reason)
	end
end

function ClimbingService.forceStop(player: Player, reason: string)
	local record = PlayerStore.get(player)
	if record and record.climbing then
		stop(player, record, reason)
	end
end

local function canStart(player: Player, record: PlayerStore.Record): (boolean, string?)
	if record.downed or record.carrying or record.carriedBy then
		return false, "You can't climb right now."
	end
	if player:GetAttribute("CanClimb") == false then
		return false, "You're in no shape to climb (injury, cold or an overloaded pack)."
	end
	if record.survival.stamina < SurvivalConfig.Stamina.MinToStartClimb then
		return false, "Catch your breath first."
	end
	return true, nil
end

local function handleStart(player: Player, normalHint: Vector3)
	local record, _, _, root = PlayerStore.getActive(player)
	if not record or not root then
		return
	end
	if record.climbing then
		return
	end
	local ok, reason = canStart(player, record)
	if not ok then
		Registry.get("RemoteGuard").fire(player, "ClimbForceStop", reason)
		return
	end
	-- Normal must be roughly horizontal (walls, not floors or ceilings).
	local flat = Vector3.new(normalHint.X, 0, normalHint.Z)
	if flat.Magnitude < math.sqrt(1 - ClimbConfig.MaxWallNormalY ^ 2) then
		Registry.get("RemoteGuard").fire(player, "ClimbForceStop", nil)
		return
	end
	local normal = flat.Unit
	local result = probe(root, normal)
	local surface = ClimbingService.classify(result)
	if surface == "None" then
		Registry.get("RemoteGuard").fire(player, "ClimbForceStop", "Nothing to climb here.")
		return
	end
	if surface == "Ice" and Registry.get("InventoryService").heldItemId(record) ~= ClimbConfig.IceTool then
		Registry.get("RemoteGuard").fire(player, "ClimbForceStop", "Ice. You need to hold an ice axe to climb it.")
		return
	end
	if record.resting then
		Registry.get("SurvivalService").setResting(player, false)
	end
	record.climbing = { normal = normal, lastY = root.Position.Y, startedAt = os.clock() }
	record.peakY = nil
	player:SetAttribute("Climbing", true)
end

-- Called from the survival tick while climbing.
function ClimbingService.tick(player: Player, record: PlayerStore.Record, root: BasePart, dt: number)
	local climb = record.climbing
	if not climb then
		return
	end
	if record.survival.stamina <= 0 then
		stop(player, record, "Your grip fails!")
		return
	end
	-- Speed sanity: vertical movement can't exceed climb speed by much.
	local maxRise = (player:GetAttribute("ClimbSpeed") or GameConfig.CLIMB_SPEED) * dt * SPEED_TOLERANCE + 1.5
	local rise = root.Position.Y - climb.lastY
	climb.lastY = root.Position.Y
	if rise > maxRise and os.clock() - climb.startedAt > 0.5 then
		-- Allow the mantle at the top (client sends ClimbStop with mantle=true first).
		stop(player, record, "")
		return
	end
	local result = probe(root, climb.normal)
	if not result then
		-- Topped out or slipped sideways off the wall: the client handles the mantle.
		stop(player, record, nil)
		return
	end
	if result.Normal.Y > -0.6 and math.abs(result.Normal.Y) < 0.7 then
		climb.normal = Vector3.new(result.Normal.X, 0, result.Normal.Z).Unit
	end
end

function ClimbingService.Init()
	local RemoteGuard = Registry.get("RemoteGuard")
	RemoteGuard.on("ClimbStart", handleStart)
	RemoteGuard.on("ClimbStop", function(player, _mantle: boolean?)
		local record = PlayerStore.get(player)
		if record and record.climbing then
			stop(player, record, nil)
		end
	end)
end

function ClimbingService.Start() end

return ClimbingService
