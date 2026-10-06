--!strict
-- Global constants shared by server and client. Anything a designer may want to tune
-- lives in a Config module, never inline in a service.

local GameConfig = {
	-- Scale: Roblox characters are ~5 studs tall, so 1 stud ~= 0.28 m for prop proportions.
	METERS_PER_STUD = 0.28,

	-- Altitude is compressed for gameplay: every stud of height represents this many meters of
	-- "virtual" elevation. A 250-stud climb therefore reads as ~2000 m on the altimeter.
	BASE_ELEVATION_M = 300,
	ELEVATION_M_PER_STUD = 4, -- base camp y=0 reads 300 m; the summit (y~800) reads ~3500 m

	-- Server simulation cadence. One loop updates every player; never one thread per stat.
	SURVIVAL_TICK_SECONDS = 0.2,
	WORLD_STATE_PUBLISH_SECONDS = 0.5,
	AUTOSAVE_SECONDS = 120,

	-- Movement (studs/second). Final speed = base * product of modifiers.
	WALK_SPEED = 14,
	SPRINT_SPEED = 22,
	CRAWL_SPEED = 2,
	CLIMB_SPEED = 6,
	JUMP_HEIGHT = 6.5,

	-- Interaction ranges (studs). Server re-validates every interaction against these.
	INTERACT_RANGE = 12,
	GIVE_RANGE = 10,
	BUILD_RANGE = 14,
	PING_RANGE = 600,
	PING_LIFETIME = 8,

	-- Fall damage (studs of vertical drop).
	FALL_SAFE_STUDS = 18,
	FALL_DAMAGE_PER_STUD = 2.2,
	FALL_SPRAIN_STUDS = 24,
	FALL_BREAK_STUDS = 38,
	FALL_DOWNED_STUDS = 75,

	-- Downed / rescue.
	BLEED_OUT_SECONDS = 120,
	REVIVE_HOLD_SECONDS = 4,
	REVIVE_HEALTH = 30,
	REVIVE_HEALTH_WITH_KIT = 60,
	CARRY_SPEED_MULTIPLIER = 0.55,

	-- Expedition / server.
	MAX_PLAYERS_HINT = 6, -- Set the real value in Game Settings > Places; code only uses it for UI.
	EVACUATION_STAT_FLOOR = { Hunger = 60, Thirst = 60, Warmth = 70 },
}

return GameConfig
