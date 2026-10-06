--!strict
-- What counts as climbable, shared by the client controller (instant feedback) and the
-- server (the authority). Names are Enum.Material member names.

return {
	RockMaterials = { "Rock", "Slate", "Basalt", "Limestone", "Sandstone", "Granite" },
	IceMaterials = { "Ice", "Glacier" },
	IceTool = "ice_axe",
	ClimbableTag = "Climbable", -- parts with this tag are climbable; attribute Ice=true makes them ice
	WallOffset = 1.15, -- studs between the wall surface and the climber's root
	MaxWallNormalY = 0.7, -- steeper than ~45 degrees from vertical is "floor", not wall
}
