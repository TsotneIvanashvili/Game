--!strict
-- Team pings. G (or the mobile "Ping" button) marks the spot under the mouse, or the
-- centre of the screen on touch. The server checks range and rate, then broadcasts
-- PingBroadcast to everyone; each client shows a marker with the pinger's name and a
-- live distance for GameConfig.PING_LIFETIME seconds. At most MAX_MARKERS at once.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local GameConfig = require(Shared.Config.GameConfig)
local UI = require(script.Parent.Parent.UI.UI)

local PingController = {}

local player = Players.LocalPlayer
local T = UI.Theme

local MAX_MARKERS = 10
local LOCAL_COOLDOWN = 1
local LABEL_REFRESH = 0.2

type Marker = { part: Part, label: TextLabel, name: string, expires: number }

local pingRemote: RemoteEvent
local folder: Folder
local markers: { Marker } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local lastPing = -math.huge

local function removeMarker(index: number)
	local m = table.remove(markers, index)
	if m then
		m.part:Destroy()
	end
end

local function distanceText(m: Marker, from: Vector3?): string
	if not from then
		return "▼ " .. m.name
	end
	local meters = (m.part.Position - from).Magnitude * GameConfig.METERS_PER_STUD
	return string.format("▼ %s · %dm", m.name, math.floor(meters + 0.5))
end

-- Distance is measured from the character (falls back to the camera while respawning).
local function viewerPosition(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		return root.Position
	end
	local camera = workspace.CurrentCamera
	return camera and camera.CFrame.Position
end

local function addMarker(position: Vector3, name: string, userId: number)
	while #markers >= MAX_MARKERS do
		removeMarker(1) -- oldest first
	end
	local part = Instance.new("Part")
	part.Name = "Ping"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = position

	local gui = UI.create("BillboardGui", {
		Name = "PingLabel",
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(200, 28),
		StudsOffsetWorldSpace = Vector3.new(0, 2, 0),
		Adornee = part,
		Parent = part,
	})
	local own = userId == player.UserId
	local label = UI.label("▼ " .. name, 16, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Font = T.FontBold,
		TextColor3 = if own then T.Accent else T.Text,
		TextStrokeTransparency = 0.35,
		TextWrapped = false,
		Parent = gui,
	})
	part.Parent = folder

	local marker: Marker = {
		part = part,
		label = label,
		name = name,
		expires = os.clock() + GameConfig.PING_LIFETIME,
	}
	table.insert(markers, marker)
	label.Text = distanceText(marker, viewerPosition())
end

local function tryPing(fromTouch: boolean)
	local now = os.clock()
	if now - lastPing < LOCAL_COOLDOWN then
		return
	end
	local camera = workspace.CurrentCamera
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not camera or not character or not root then
		return
	end
	local screen = if fromTouch then camera.ViewportSize / 2 else UserInputService:GetMouseLocation() -- includes the GUI inset, like ViewportPointToRay
	local ray = camera:ViewportPointToRay(screen.X, screen.Y)
	rayParams.FilterDescendantsInstances = { character, folder }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * GameConfig.PING_RANGE, rayParams)
	if not hit then
		return
	end
	-- The server measures range from our root, not the camera.
	if (hit.Position - root.Position).Magnitude > GameConfig.PING_RANGE then
		return
	end
	lastPing = now
	pingRemote:FireServer(hit.Position)
end

function PingController.Init()
	folder = Instance.new("Folder")
	folder.Name = "PingMarkers"
	folder.Parent = workspace
end

function PingController.Start()
	pingRemote = Remotes.get("Ping") :: RemoteEvent

	ContextActionService:BindAction("Ping", function(_, inputState, input)
		if inputState == Enum.UserInputState.Begin then
			tryPing(input.UserInputType == Enum.UserInputType.Touch)
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.G, Enum.KeyCode.DPadUp)
	ContextActionService:SetTitle("Ping", "Ping")

	local broadcast = Remotes.get("PingBroadcast") :: RemoteEvent
	broadcast.OnClientEvent:Connect(function(position: Vector3, name: string, userId: number)
		if typeof(position) ~= "Vector3" then
			return
		end
		addMarker(position, if typeof(name) == "string" then name else "?", tonumber(userId) or 0)
	end)

	local refresh = 0
	RunService.Heartbeat:Connect(function(dt)
		if #markers == 0 then
			return
		end
		local now = os.clock()
		for i = #markers, 1, -1 do
			if now >= markers[i].expires then
				removeMarker(i)
			end
		end
		refresh += dt
		if refresh < LABEL_REFRESH then
			return
		end
		refresh = 0
		local from = viewerPosition()
		for _, m in markers do
			m.label.Text = distanceText(m, from)
		end
	end)
end

return PingController
