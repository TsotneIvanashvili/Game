--!strict
-- Local movement glue. The server owns speed, stamina and resting; this controller only
-- reports intent and polishes the feel:
--   * Shift (hold) / mobile "Sprint" button (toggle) -> SetSprint, sent only when it changes
--   * Humanoid entering Jumping -> ReportJump (the server charges stamina for it)
--   * moving or jumping while Resting -> StopRest (once, debounced)
--   * X / mobile "Drop" button while carrying someone -> DropCarried
--   * hides the downed player's own revive/carry prompts (they carry OwnerUserId)
--   * widens the FOV slightly while the server says we are sprinting
-- It also turns off the CoreGui backpack, player list and reset button: the game has its
-- own pack UI and resetting would skip the survival consequences.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local MovementController = {}

local player = Players.LocalPlayer

local BASE_FOV = 70
local SPRINT_FOV = 76
local FOV_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STOP_REST_DEBOUNCE = 1
local MOVE_THRESHOLD = 0.15

local setSprintRemote: RemoteEvent
local reportJumpRemote: RemoteEvent
local stopRestRemote: RemoteEvent
local dropCarriedRemote: RemoteEvent

local controls: any = nil
local sprintHeld = false -- keyboard / gamepad hold
local sprintToggled = false -- touch button toggle
local sprintSent = false
local resting = false
local stopRestSentAt = -math.huge
local jumpConn: RBXScriptConnection? = nil
local fovTween: Tween? = nil
local dropBound = false

local function updateSprint()
	local want = sprintHeld or sprintToggled
	if want == sprintSent then
		return
	end
	sprintSent = want
	setSprintRemote:FireServer(want)
end

local function requestStopRest()
	if not resting then
		return
	end
	local now = os.clock()
	if now - stopRestSentAt < STOP_REST_DEBOUNCE then
		return
	end
	stopRestSentAt = now
	stopRestRemote:FireServer()
end

local function moveInput(): Vector3
	if controls then
		local ok, v = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(v) == "Vector3" then
			return v
		end
	end
	-- Keyboard fallback if the PlayerModule isn't available.
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

local function bindCharacter(character: Model)
	if jumpConn then
		jumpConn:Disconnect()
		jumpConn = nil
	end
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid or player.Character ~= character then
		return
	end
	jumpConn = humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			reportJumpRemote:FireServer()
			requestStopRest()
		end
	end)
end

local function setFov(target: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	if fovTween then
		fovTween:Cancel()
	end
	local tween = TweenService:Create(camera, FOV_TWEEN, { FieldOfView = target })
	fovTween = tween
	tween:Play()
end

local function onExertionChanged()
	setFov(if player:GetAttribute("Exertion") == "sprint" then SPRINT_FOV else BASE_FOV)
end

local function onCarryingChanged()
	local carrying = player:GetAttribute("Carrying") ~= nil
	if carrying == dropBound then
		return
	end
	dropBound = carrying
	if carrying then
		-- Bound only while carrying so the mobile "Drop" button appears exactly when useful.
		ContextActionService:BindAction("DropCarried", function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				dropCarriedRemote:FireServer()
			end
			return Enum.ContextActionResult.Sink
		end, true, Enum.KeyCode.X, Enum.KeyCode.ButtonB)
		ContextActionService:SetTitle("DropCarried", "Drop")
	else
		ContextActionService:UnbindAction("DropCarried")
	end
end

-- SetCore callbacks are registered by the CoreScripts some time after the client starts,
-- so the first calls can error. Retry for a while.
local function disableReset()
	for _ = 1, 20 do
		local ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
		if ok then
			return
		end
		task.wait(0.5)
	end
	warn("[MovementController] could not disable the reset button")
end

function MovementController.Init()
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
	task.spawn(disableReset)
end

function MovementController.Start()
	setSprintRemote = Remotes.get("SetSprint") :: RemoteEvent
	reportJumpRemote = Remotes.get("ReportJump") :: RemoteEvent
	stopRestRemote = Remotes.get("StopRest") :: RemoteEvent
	dropCarriedRemote = Remotes.get("DropCarried") :: RemoteEvent

	task.spawn(function()
		local ok, module = pcall(function()
			return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript) :: any
		end)
		if ok and module then
			controls = module:GetControls()
		end
	end)

	-- Sprint. Bound above the default priority so LeftShift sprints instead of toggling
	-- shift-lock (RightShift still toggles shift-lock where it's enabled).
	ContextActionService:BindActionAtPriority("Sprint", function(_, inputState, input)
		if input.UserInputType == Enum.UserInputType.Touch then
			if inputState == Enum.UserInputState.Begin then
				sprintToggled = not sprintToggled
				ContextActionService:SetTitle("Sprint", if sprintToggled then "Walk" else "Sprint")
			end
		elseif inputState == Enum.UserInputState.Begin then
			sprintHeld = true
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			sprintHeld = false
		end
		updateSprint()
		return Enum.ContextActionResult.Sink
	end, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)
	ContextActionService:SetTitle("Sprint", "Sprint")
	-- Losing focus (alt-tab) never delivers the key-up; don't stay stuck sprinting.
	UserInputService.WindowFocusReleased:Connect(function()
		sprintHeld = false
		updateSprint()
	end)

	-- Jump reporting, rebound for every character.
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end

	-- Resting: any move input or jump gets you up.
	resting = player:GetAttribute("Resting") == true
	player:GetAttributeChangedSignal("Resting"):Connect(function()
		resting = player:GetAttribute("Resting") == true
		if not resting then
			stopRestSentAt = -math.huge
		end
	end)
	UserInputService.JumpRequest:Connect(requestStopRest)
	RunService.Heartbeat:Connect(function()
		if resting and moveInput().Magnitude > MOVE_THRESHOLD then
			requestStopRest()
		end
	end)

	-- Drop a carried teammate.
	player:GetAttributeChangedSignal("Carrying"):Connect(onCarryingChanged)
	onCarryingChanged()

	-- The downed player must not see their own revive/carry prompts.
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if prompt:GetAttribute("OwnerUserId") == player.UserId then
			prompt.Enabled = false
		end
	end)

	-- Sprint FOV kick, driven by the server's view of our exertion.
	player:GetAttributeChangedSignal("Exertion"):Connect(onExertionChanged)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(onExertionChanged)
	onExertionChanged()
end

return MovementController
