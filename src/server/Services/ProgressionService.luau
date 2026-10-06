--!strict
-- XP, ranks and blueprint unlocks. All awards originate from server-side events
-- (checkpoint signed, teammate revived, section completed); there is no client path.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local RecipeDefs = require(Shared.Config.RecipeDefs)
local Registry = require(script.Parent.Parent.Registry)

local ProgressionService = {}

local function publish(player: Player, xp: number)
	local rankIndex = ProgressionConfig.rankIndexFor(xp)
	player:SetAttribute("XP", xp)
	player:SetAttribute("RankIndex", rankIndex)
	player:SetAttribute("Rank", ProgressionConfig.Ranks[rankIndex].name)
end

function ProgressionService.Init() end

function ProgressionService.Start()
	Registry.get("DataService").ProfileLoaded:Connect(function(player, profile)
		publish(player, profile.xp)
	end)
end

function ProgressionService.award(player: Player, amount: number, reason: string)
	local DataService = Registry.get("DataService")
	local profile = DataService.get(player)
	if not profile or amount <= 0 then
		return
	end
	local before = ProgressionConfig.rankIndexFor(profile.xp)
	profile.xp += amount
	DataService.markDirty(player)
	publish(player, profile.xp)
	local RemoteGuard = Registry.get("RemoteGuard")
	RemoteGuard.notify(player, string.format("+%d XP  %s", amount, reason), "good")
	local after = ProgressionConfig.rankIndexFor(profile.xp)
	if after > before then
		RemoteGuard.notify(player, "Rank up: " .. ProgressionConfig.Ranks[after].name, "good")
	end
end

function ProgressionService.rankIndex(player: Player): number
	local profile = Registry.get("DataService").get(player)
	return if profile then ProgressionConfig.rankIndexFor(profile.xp) else 1
end

function ProgressionService.hasBlueprint(player: Player, recipeId: string): boolean
	local profile = Registry.get("DataService").get(player)
	local recipe = RecipeDefs.ById[recipeId]
	if not recipe then
		return false
	end
	if recipe.unlockedByDefault then
		return true
	end
	return profile ~= nil and profile.blueprints[recipeId] == true
end

function ProgressionService.unlockBlueprint(player: Player, recipeId: string)
	local DataService = Registry.get("DataService")
	local profile = DataService.get(player)
	local recipe = RecipeDefs.ById[recipeId]
	if not profile or not recipe or profile.blueprints[recipeId] then
		return
	end
	profile.blueprints[recipeId] = true
	DataService.markDirty(player)
	Registry.get("RemoteGuard").notify(player, "Blueprint found: " .. recipe.name, "good")
end

-- One-time achievements with a timestamp.
function ProgressionService.achieve(player: Player, id: string, xp: number?, label: string?)
	local DataService = Registry.get("DataService")
	local profile = DataService.get(player)
	if not profile or profile.achievements[id] then
		return
	end
	profile.achievements[id] = os.time()
	DataService.markDirty(player)
	if xp then
		ProgressionService.award(player, xp, label or id)
	end
end

return ProgressionService
