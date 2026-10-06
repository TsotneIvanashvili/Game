--!strict
-- Client half of climbing. Roblox gives each client physics ownership of its own character,
-- so the climb motion is driven here (AlignPosition/AlignOrientation hold you on the wall)
-- while the server decides whether you may climb and drains stamina. If the server says
-- your grip fails, you let go and fall: that is the danger of climbing tired or overloaded.
--
-- Controls: C to grab/let go, W/S up/down, A/D sideways, Space to jump off.
-- Mobile: the "Climb" button grabs/lets go; the thumbstick moves.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local ClimbConfig = require(Shared.Config.ClimbConfig)
local GameConfig = require(Shared.Config.GameConfig)
local Notifications = require(script.Parent.NotificationController)
local ClientState = require(script.Parent.Parent.ClientState)

local ClimbingController = {}

local player = Players.LocalPlayer

type ClimbState = {
	normal: Vector3,
	target: Vector3,
	attachment: Attachment,
	align: AlignPosition,
	orient: AlignOrientation,
	mantling: boolean,
	startedAt: number,
}

local state: ClimbState? = nil
local controls: any = nil

local ROCK: { [Enum.Material]: boolean } = {}
local ICE: { [Enum.Material]: boolean } = {}
for _, list in { { ClimbConfig.RockMaterials, ROCK }, { ClimbConfig.IceMaterials, ICE } } do
	for _, name in list[1] :: { string } do
		local ok, m = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		if ok and m then
			(list[2] :: any)[m] = true
		end
	end
end

local function character(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	if not char then
		return nil, nil, nil
	end
	return char, char:FindFirstChildOfClass("Humanoid"), char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function rayParams(char: Model): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { char }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	return params
end

local function classify(result: RaycastResult?): string
	if not result then
		return "None"
	end
	if result.Instance:IsA("Terrain") then
		if ROCK[result.Material] then
			return "Rock"
		elseif ICE[result.Material] then
			return "Ice"
		end
		return "None"
	end
	if CollectionService:HasTag(result.Instance, ClimbConfig.ClimbableTag) then
		return if result.Instance:GetAttribute("Ice") == true then "Ice" else "Rock"
	end
	return "None"
end

local function moveVector(): Vector3
	if controls then
		local ok, v = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(v) == "Vector3" then
			return v
		end
	end
	-- Keyboard fallback.
	local x, z = 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		z -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		z += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		x -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		x += 1
	end
	return Vector3.new(x, 0, z)
end

local function flatten(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, 1)
end

function ClimbingController.isClimbing(): boolean
	return state ~= nil
end

function ClimbingController.stop(jumpOff: boolean?, notifyServer: boolean?)
	local s = state
	if not s then
		return
	end
	state = nil
	s.align:Destroy()
	s.orient:Destroy()
	s.attachment:Destroy()
	local _, humanoid, root = character()
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end
	if jumpOff and root then
		root.AssemblyLinearVelocity = s.normal * 22 + Vector3.new(0, 18, 0)
	end
	if notifyServer ~= false then
		(Remotes.get("ClimbStop") :: RemoteEvent):FireServer(false)
	end
end

local function begin(normal: Vector3, wallPoint: Vector3)
	local _, humanoid, root = character()
	if not humanoid or not root then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "ClimbAttachment"
	attachment.Parent = root
	local align = Instance.new("AlignPosition")
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxForce = 1e6
	align.MaxVelocity = 40
	align.Responsiveness = 60
	align.Parent = root
	local orient = Instance.new("AlignOrientation")
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.MaxTorque = 1e6
	orient.Responsiveness = 60
	orient.Parent = root

	local target = Vector3.new(wallPoint.X, root.Position.Y, wallPoint.Z) + normal * ClimbConfig.WallOffset
	align.Position = target
	orient.CFrame = CFrame.lookAt(target, target - normal)
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	state = {
		normal = normal,
		target = target,
		attachment = attachment,
		align = align,
		orient = orient,
		mantling = false,
		startedAt = os.clock(),
	}
end

function ClimbingController.tryStart()
	if state or ClientState.placing then
		return
	end
	local char, humanoid, root = character()
	if not char or not humanoid or not root then
		return
	end
	if player:GetAttribute("CanClimb") == false then
		Notifications.toast("You're in no shape to climb (injury, cold or an overloaded pack).", "warn")
		return
	end
	if player:GetAttribute("Downed") then
		return
	end
	local params = rayParams(char)
	local look = flatten(root.CFrame.LookVector)
	local hit = workspace:Raycast(root.Position, look * 3.5, params)
		or workspace:Raycast(root.Position - Vector3.new(0, 1.5, 0), look * 3.5, params)
	if not hit or math.abs(hit.Normal.Y) > ClimbConfig.MaxWallNormalY then
		Notifications.toast("Face a rock wall to climb.", "info")
		return
	end
	local surface = classify(hit)
	if surface == "None" then
		Notifications.toast("You can't climb that.", "info")
		return
	end
	if surface == "Ice" and player:GetAttribute("HeldItem") ~= ClimbConfig.IceTool then
		Notifications.toast("Ice. Hold an ice axe to climb it (open your pack).", "warn")
		return
	end
	local normal = flatten(hit.Normal)
	begin(normal, hit.Position)
	local climbStart = Remotes.get("ClimbStart") :: RemoteEvent
	climbStart:FireServer(normal)
end

local function mantle(s: ClimbState, root: BasePart, params: RaycastParams)
	-- Find the top surface just over the lip.
	local probe = root.Position + Vector3.new(0, 4.5, 0) - s.normal * 1.6
	local top = workspace:Raycast(probe, Vector3.new(0, -6, 0), params)
	if not top or top.Normal.Y < 0.6 then
		return false
	end
	s.mantling = true
	(Remotes.get("ClimbStop") :: RemoteEvent):FireServer(true)
	local up = Vector3.new(root.Position.X, top.Position.Y + 3, root.Position.Z) + s.normal * 0.3
	local over = top.Position + Vector3.new(0, 3, 0)
	s.align.Position = up
	task.delay(0.25, function()
		if state == s then
			s.align.Position = over
			task.delay(0.25, function()
				if state == s then
					ClimbingController.stop(false, false)
				end
			end)
		end
	end)
	return true
end

local function step(dt: number)
	local s = state
	if not s or s.mantling then
		return
	end
	local char, humanoid, root = character()
	if not char or not humanoid or not root or humanoid.Health <= 0 then
		ClimbingController.stop(false)
		return
	end
	local params = rayParams(char)
	local wall = workspace:Raycast(root.Position, -s.normal * 4, params)
		or workspace:Raycast(root.Position - Vector3.new(0, 1.5, 0), -s.normal * 4, params)
	if wall and math.abs(wall.Normal.Y) < ClimbConfig.MaxWallNormalY then
		s.normal = flatten(s.normal:Lerp(flatten(wall.Normal), 0.25))
	end

	local input = moveVector()
	local upInput = -input.Z
	local rightInput = input.X
	local speed = player:GetAttribute("ClimbSpeed") or GameConfig.CLIMB_SPEED
	local upDir = Vector3.yAxis
	local rightDir = (-s.normal):Cross(upDir).Unit

	-- Reached the lip: head-height probe finds no wall while still moving up.
	if upInput > 0.1 then
		local head = workspace:Raycast(root.Position + Vector3.new(0, 2.6, 0), -s.normal * 4, params)
		if not head and wall then
			if mantle(s, root, params) then
				return
			end
		end
	end
	-- Climbed down to the ground: step off.
	if upInput < -0.1 then
		local floor = workspace:Raycast(root.Position, Vector3.new(0, -3.4, 0), params)
		if floor then
			ClimbingController.stop(false)
			return
		end
	end
	-- Lost the wall entirely (slid off a corner): fall.
	if not wall and os.clock() - s.startedAt > 0.3 then
		ClimbingController.stop(false)
		return
	end

	local move = (upDir * upInput + rightDir * rightInput)
	if move.Magnitude > 1 then
		move = move.Unit
	end
	local nextTarget = s.target + move * speed * dt
	if wall then
		-- Keep a constant distance from the rock face.
		local distance = (nextTarget - wall.Position):Dot(s.normal)
		nextTarget -= s.normal * (distance - ClimbConfig.WallOffset)
	end
	s.target = nextTarget
	s.align.Position = nextTarget
	s.orient.CFrame = CFrame.lookAt(nextTarget, nextTarget - s.normal)
end

function ClimbingController.Init() end

function ClimbingController.Start()
	task.spawn(function()
		local ok, module = pcall(function()
			return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript) :: any
		end)
		if ok and module then
			controls = module:GetControls()
		end
	end)

	RunService.Heartbeat:Connect(step)

	local forceStop = Remotes.get("ClimbForceStop") :: RemoteEvent
	forceStop.OnClientEvent:Connect(function(reason: string?)
		if state then
			ClimbingController.stop(false, false)
		end
		if reason and reason ~= "" then
			Notifications.toast(reason, "danger")
		end
	end)

	ContextActionService:BindAction("Climb", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			if state then
				ClimbingController.stop(false)
			else
				ClimbingController.tryStart()
			end
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.C, Enum.KeyCode.ButtonY)
	ContextActionService:SetTitle("Climb", "Climb")

	UserInputService.JumpRequest:Connect(function()
		if state and not state.mantling then
			ClimbingController.stop(true)
		end
	end)
	player.CharacterRemoving:Connect(function()
		state = nil
	end)
end

return ClimbingController
