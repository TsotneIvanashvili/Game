--!strict
-- Sound asset ids by key. Every id is deliberately empty: asset ids are never invented in
-- code, so audio art fills these in ("rbxassetid://<id>") once real sounds are uploaded.
-- AudioController skips any key whose id is "", so the game is silent until then.
--
-- Keys used by the server's PlaySound event (e.g. "Rumble" from DisasterService) must exist here.

local AudioConfig = {}

AudioConfig.Sounds = {
	Wind = "", -- looped ambience, volume follows wind speed
	Snowfall = "", -- looped ambience, soft hiss of light/moderate snowfall
	Blizzard = "", -- looped ambience, heavy snow driven by strong wind (storms)
	Rumble = "", -- avalanche / rockfall (positional, from the server)
	StormBanner = "", -- sting when the "storm" banner appears (Banner event, kind "storm")
	FireCrackle = "", -- looped while near a fire
	HeavyBreathing = "", -- looped while sprinting/climbing or short of oxygen
	Heartbeat = "", -- looped while downed or badly hurt
	Shivering = "", -- looped at Severe/Critical cold
	SnowStep = "", -- footstep on snow (crunch)
	IceStep = "", -- footstep on glacier ice (falls back to SnowStep while empty)
	RockStep = "", -- footstep on rock
} :: { [string]: string }

-- Base volumes (0..1) per key; the controller scales loops by intensity on top.
AudioConfig.Volume = {
	Wind = 0.6,
	Snowfall = 0.35,
	Blizzard = 0.7,
	Rumble = 1,
	StormBanner = 0.8,
	FireCrackle = 0.5,
	HeavyBreathing = 0.4,
	Heartbeat = 0.6,
	Shivering = 0.4,
	SnowStep = 0.35,
	IceStep = 0.35,
	RockStep = 0.35,
} :: { [string]: number }

return AudioConfig
