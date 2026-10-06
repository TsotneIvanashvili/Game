--!strict
-- Ranks and XP. Progression unlocks gear and routes, never raw power you can buy.

local ProgressionConfig = {
	Ranks = {
		{ name = "Beginner Mountaineer", xp = 0 },
		{ name = "Hiker", xp = 500 },
		{ name = "Climber", xp = 1500 },
		{ name = "Alpine Climber", xp = 4000 },
		{ name = "Expedition Leader", xp = 9000 },
	},
	XP = {
		Checkpoint = 150,
		Revive = 100,
		FirstShelter = 25,
		SectionComplete = 300,
		Summit = 1000,
	},
}

function ProgressionConfig.rankIndexFor(xp: number): number
	local index = 1
	for i, rank in ProgressionConfig.Ranks do
		if xp >= rank.xp then
			index = i
		end
	end
	return index
end

return ProgressionConfig
