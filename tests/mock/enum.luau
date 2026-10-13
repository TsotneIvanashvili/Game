-- Enum emulation. `Enum.X.Y` returns a stable EnumItem (same table every time, so == works)
-- with .Name / .Value / .EnumType. Enum types listed in KNOWN are strict: an item that does
-- not exist in Roblox errors exactly like the engine ("X is not a valid member of Enum Y"),
-- which catches typos such as Enum.Material.Snwo. Unlisted enum types are lazy: any item
-- name is accepted and gets the next value.

local KNOWN: { [string]: string } = {
	Material = "Plastic SmoothPlastic Neon Wood WoodPlanks Marble Basalt Slate CrackedLava Concrete Limestone Granite Pavement Brick Pebble Cobblestone Rock Sandstone CorrodedMetal DiamondPlate Foil Metal Grass LeafyGrass Sand Fabric Snow Mud Ground Asphalt Salt Ice Glacier Glass ForceField Air Water Cardboard Carpet CeramicTiles ClayRoofTiles RoofShingles Leather Plaster Rubber",
	PartType = "Ball Block Cylinder Wedge CornerWedge",
	NormalId = "Right Top Back Left Bottom Front",
	Axis = "X Y Z",
	KeyCode = "Unknown Backspace Tab Clear Return Pause Escape Space QuotedDouble Hash Dollar Percent Ampersand Quote LeftParenthesis RightParenthesis Asterisk Plus Comma Minus Period Slash Zero One Two Three Four Five Six Seven Eight Nine Colon Semicolon LessThan Equals GreaterThan Question At LeftBracket BackSlash RightBracket Caret Underscore Backquote A B C D E F G H I J K L M N O P Q R S T U V W X Y Z LeftCurly Pipe RightCurly Tilde Delete KeypadZero KeypadOne KeypadTwo KeypadThree KeypadFour KeypadFive KeypadSix KeypadSeven KeypadEight KeypadNine KeypadPeriod KeypadDivide KeypadMultiply KeypadMinus KeypadPlus KeypadEnter KeypadEquals Up Down Right Left Insert Home End PageUp PageDown LeftShift RightShift LeftMeta RightMeta LeftAlt RightAlt LeftControl RightControl CapsLock NumLock ScrollLock LeftSuper RightSuper Mode Compose Help Print SysReq Break Menu Power Euro Undo F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 F13 F14 F15 ButtonX ButtonY ButtonA ButtonB ButtonR1 ButtonL1 ButtonR2 ButtonL2 ButtonR3 ButtonL3 ButtonStart ButtonSelect DPadLeft DPadRight DPadUp DPadDown Thumbstick1 Thumbstick2 MouseLeftButton MouseRightButton MouseMiddleButton",
	UserInputType = "MouseButton1 MouseButton2 MouseButton3 MouseWheel MouseMovement Touch Keyboard Focus Accelerometer Gyro Gamepad1 Gamepad2 Gamepad3 Gamepad4 Gamepad5 Gamepad6 Gamepad7 Gamepad8 TextInput InputMethod None",
	UserInputState = "Begin Change End Cancel None",
	HumanoidStateType = "FallingDown Ragdoll GettingUp Jumping Swimming Freefall Flying Landed Running RunningNoPhysics StrafingNoPhysics Climbing Seated PlatformStanding Dead Physics None",
	HumanoidRigType = "R6 R15",
	EasingStyle = "Linear Sine Back Quad Quart Quint Bounce Elastic Exponential Circular Cubic",
	EasingDirection = "In Out InOut",
	PlaybackState = "Begin Delayed Playing Paused Completed Cancelled",
	RaycastFilterType = "Exclude Include Blacklist Whitelist",
	SortOrder = "Name Custom LayoutOrder",
	FillDirection = "Horizontal Vertical",
	HorizontalAlignment = "Center Left Right",
	VerticalAlignment = "Center Top Bottom",
	TextXAlignment = "Left Right Center",
	TextYAlignment = "Top Center Bottom",
	TextTruncate = "None AtEnd SplitWord",
	AutomaticSize = "None X Y XY",
	ZIndexBehavior = "Global Sibling",
	CoreGuiType = "PlayerList Health Backpack Chat All EmotesMenu SelfView Captures",
	CameraMode = "Classic LockFirstPerson",
	CameraType = "Fixed Attach Watch Track Follow Custom Scriptable Orbital",
	ContextActionResult = "Pass Sink",
	ContextActionPriority = "Low:1000 Medium:2000 Default:2000 High:3000",
	RenderPriority = "First:0 Input:100 Camera:200 Character:300 Last:2000",
	SurfaceType = "Smooth Glue Weld Studs Inlet Universal Hinge Motor SteppingMotor SmoothNoOutlines",
	MeshType = "Head Torso Wedge Prism Pyramid ParallelRamp RightAngleRamp CornerWedge Brick Sphere Cylinder FileMesh",
	AccessoryType = "Unknown Hat Hair Face Neck Shoulder Front Back Waist TShirt Shirt Pants Jacket Sweater Shorts LeftShoe RightShoe DressSkirt Eyebrow Eyelash",
	ApplyStrokeMode = "Contextual Border",
	LineJoinMode = "Round Bevel Miter",
	SurfaceGuiSizingMode = "FixedSize PixelsPerStud",
	RollOffMode = "Inverse Linear InverseTapered LinearSquare",
	PositionAlignmentMode = "OneAttachment TwoAttachment",
	OrientationAlignmentMode = "OneAttachment TwoAttachment",
	ParticleOrientation = "FacingCamera FacingCameraWorldUp VelocityParallel VelocityPerpendicular",
	ParticleEmitterShape = "Box Sphere Cylinder Disc",
	ParticleEmitterShapeStyle = "Volume Surface",
	ParticleEmitterShapeInOut = "Outward Inward InAndOut",
	Style = "AlternatingSupports BridgeStyleSupports NoSupports",
	Font = "Legacy Arial ArialBold SourceSans SourceSansBold SourceSansLight SourceSansItalic Bodoni Garamond Cartoon Code Highway SciFi Arcade Fantasy Antique SourceSansSemibold Gotham GothamMedium GothamBold GothamBlack AmaticSC Bangers Creepster DenkOne Fondamento FredokaOne GrenzeGotisch IndieFlower JosefinSans Jura Kalam LuckiestGuy Merriweather Michroma Nunito Oswald PatrickHand PermanentMarker Roboto RobotoCondensed RobotoMono Sarpanch SpecialElite TitilliumWeb Ubuntu BuilderSans BuilderSansMedium BuilderSansBold BuilderSansExtraBold Arimo ArimoBold Unknown",
	FontWeight = "Thin ExtraLight Light Regular Medium SemiBold Bold ExtraBold Heavy",
	FontStyle = "Normal Italic",
	ProximityPromptStyle = "Default Custom",
	ProximityPromptExclusivity = "OnePerButton OneGlobally AlwaysShow",
	ScaleType = "Stretch Slice Tile Fit Crop",
	FrameStyle = "Custom ChatBlue RobloxSquare RobloxRound ChatGreen ChatRed DropShadow",
	ButtonStyle = "Custom RobloxButtonDefault RobloxButton RobloxRoundButton RobloxRoundDefaultButton RobloxRoundDropdownButton",
	ScrollingDirection = "X Y XY",
	ScrollBarInset = "None ScrollBar Always",
	ElasticBehavior = "WhenScrollable Always Never",
	BorderMode = "Outline Middle Inset",
	SizeConstraint = "RelativeXY RelativeXX RelativeYY",
	AspectType = "FitWithinMaxSize ScaleWithParentSize",
	DominantAxis = "Width Height",
	StartCorner = "TopLeft TopRight BottomLeft BottomRight",
	ResamplerMode = "Default Pixelated",
	ModelStreamingMode = "Default Atomic Persistent PersistentPerPlayer Nonatomic",
	ModelLevelOfDetail = "Automatic StreamingMesh Disabled",
	HumanoidDisplayDistanceType = "Viewer Subject None",
	HumanoidHealthDisplayType = "DisplayWhenDamaged AlwaysOn AlwaysOff",
	NameOcclusion = "NoOcclusion EnemyOcclusion OccludeAll",
	Technology = "Legacy Voxel Compatibility ShadowMap Future Unified",
	RotationOrder = "XYZ XZY YZX YXZ ZXY ZYX",
	ActuatorRelativeTo = "Attachment0 Attachment1 World",
	ForceLimitMode = "Magnitude PerAxis",
	AlignType = "Parallel Perpendicular AllAxes PrimaryAxisParallel PrimaryAxisPerpendicular PrimaryAxisLookAt",
	VelocityConstraintMode = "Line Plane Vector",
	TextDirection = "Auto LeftToRight RightToLeft",
	AnimationPriority = "Idle Movement Action Action2 Action3 Action4 Core",
	DevComputerMovementMode = "UserChoice KeyboardMouse ClickToMove Scriptable",
	DevTouchMovementMode = "UserChoice Thumbstick DPad Thumbpad ClickToMove Scriptable DynamicThumbstick",
	MouseBehavior = "Default LockCenter LockCurrentPosition",
	SignalBehavior = "Default Immediate Deferred AncestryDeferred",
	StreamingPauseMode = "Default Disabled ClientPhysicsPause",
	SoundType = "NoSound Boing Bomb Break Click Clock Slingshot Page Ping Snap Splat Step StepOn Swoosh Victory",
	TeleportResult = "Success Failure GameNotFound GameEnded GameFull Unauthorized Flooded IsTeleporting",
	ExplosionType = "NoCraters Craters",
	DepthMode = "AlwaysOnTop Occluded",
	HighlightDepthMode = "AlwaysOnTop Occluded",
	TextureMode = "Stretch Wrap Static",
	TweenStatus = "Canceled Completed",
	ConnectionError = "OK Unknown DisconnectErrors",
	Platform = "Windows OSX IOS Android XBoxOne PS4 PS5 XBox360 WiiU NX Ouya AndroidTV Chromecast Linux SteamOS WebOS DOS BeOS UWP None",
	SelectionBehavior = "Escape Stop",
	MembershipType = "None BuildersClub TurboBuildersClub OutrageousBuildersClub Premium",
	DataStoreRequestType = "GetAsync SetIncrementAsync UpdateAsync GetSortedAsync SetIncrementSortedAsync OnUpdate",
	PathStatus = "Success ClosestNoPath ClosestOutOfRange FailStartNotEmpty FailFinishNotEmpty NoPath",
	PathWaypointAction = "Walk Jump Custom",
}

return function(M)
	local EnumItemMt = { __type = "EnumItem" }
	EnumItemMt.__tostring = function(item)
		return "Enum." .. rawget(item, "_typeName") .. "." .. item.Name
	end
	EnumItemMt.__index = function(item, k)
		if k == "IsA" then
			return function(self, typeName)
				return rawget(self, "_typeName") == typeName
			end
		end
		error(tostring(k) .. ' is not a valid member of "' .. tostring(item) .. '"', 2)
	end
	EnumItemMt.__newindex = function(_, k)
		error(tostring(k) .. " cannot be assigned to", 2)
	end

	local EnumMt = { __type = "Enum" }
	EnumMt.__tostring = function(e)
		return rawget(e, "_name")
	end
	local function addItem(e, name: string, value: number?)
		local items = rawget(e, "_items")
		local item = setmetatable(
			{ Name = name, Value = value or #items, EnumType = e, _typeName = rawget(e, "_name") },
			EnumItemMt
		)
		table.insert(items, item)
		rawset(e, name, item)
		return item
	end
	EnumMt.__index = function(e, k)
		if k == "GetEnumItems" then
			return function(self)
				return table.clone(rawget(self, "_items"))
			end
		elseif k == "FromName" then
			return function(self, name)
				return rawget(self, name)
			end
		elseif k == "FromValue" then
			return function(self, value)
				for _, item in rawget(self, "_items") do
					if item.Value == value then
						return item
					end
				end
				return nil
			end
		end
		if type(k) ~= "string" then
			error(tostring(k) .. ' is not a valid member of "Enum.' .. rawget(e, "_name") .. '"', 2)
		end
		if rawget(e, "_strict") then
			error(k .. ' is not a valid member of "Enum.' .. rawget(e, "_name") .. '"', 2)
		end
		return addItem(e, k)
	end
	EnumMt.__newindex = function(_, k)
		error(tostring(k) .. " cannot be assigned to", 2)
	end

	local function newEnum(name: string, list: string?)
		local e = setmetatable({ _name = name, _items = {}, _strict = false }, EnumMt)
		if list then
			for token in string.gmatch(list, "%S+") do
				-- "Name" or "Name:Value" (explicit engine value where code depends on it)
				local itemName, value = string.match(token, "^([%w_]+):?(%-?%d*)$")
				addItem(e, itemName :: string, tonumber(value))
			end
			rawset(e, "_strict", true)
		end
		return e
	end

	local EnumsMt = { __type = "Enums" }
	EnumsMt.__index = function(root, k)
		if k == "GetEnums" then
			return function()
				local out = {}
				for _, e in rawget(root, "_all") do
					table.insert(out, e)
				end
				return out
			end
		end
		if type(k) ~= "string" then
			error(tostring(k) .. " is not a valid member of Enum", 2)
		end
		local e = newEnum(k, KNOWN[k])
		rawset(root, k, e)
		rawget(root, "_all")[k] = e
		return e
	end
	EnumsMt.__newindex = function(_, k)
		error(tostring(k) .. " cannot be assigned to", 2)
	end
	EnumsMt.__tostring = function()
		return "Enums"
	end
	M.Enum = setmetatable({ _all = {} }, EnumsMt)

	-- Coerce a string/number into an EnumItem of `enumType` (property setters accept these).
	function M.coerceEnum(enumType, value): any
		local t = M.typeof(value)
		if t == "EnumItem" then
			return if value.EnumType == enumType then value else nil
		elseif t == "string" then
			return rawget(enumType, value)
		elseif t == "number" then
			for _, item in rawget(enumType, "_items") do
				if item.Value == value then
					return item
				end
			end
		end
		return nil
	end
end
