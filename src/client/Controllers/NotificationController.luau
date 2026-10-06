--!strict
-- Toasts (right side) and big contextual warnings (top centre) such as
-- "YOU ARE FREEZING" or "SEVERE WEATHER APPROACHING". Danger messages use the warning band.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local UI = require(script.Parent.Parent.UI.UI)

local NotificationController = {}

local MAX_TOASTS = 5
local COLORS = {
	info = UI.Theme.Text,
	good = UI.Theme.Good,
	warn = UI.Theme.Warn,
	danger = UI.Theme.Danger,
}

local toastHolder: Frame
local warningLabel: TextLabel
local warningToken = 0
local toastOrder = 0

function NotificationController.toast(text: string, severity: string?)
	local color = COLORS[severity or "info"] or UI.Theme.Text
	toastOrder -= 1 -- newest first
	local toast = UI.create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = UI.Theme.Panel,
		BackgroundTransparency = 0.2,
		LayoutOrder = toastOrder,
		Parent = toastHolder,
	}, {
		UI.corner(6),
		UI.padding(8),
		UI.create("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = color, BorderSizePixel = 0 }),
		UI.label(text, 14, {
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -10, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextColor3 = color,
		}),
	})
	local toasts = {}
	for _, child in toastHolder:GetChildren() do
		if child:IsA("Frame") then
			table.insert(toasts, child)
		end
	end
	if #toasts > MAX_TOASTS then
		table.sort(toasts, function(a, b)
			return a.LayoutOrder > b.LayoutOrder
		end)
		toasts[1]:Destroy()
	end
	task.delay(6, function()
		if toast.Parent then
			toast:Destroy()
		end
	end)
end

function NotificationController.warning(text: string, color: Color3?)
	warningToken += 1
	local token = warningToken
	warningLabel.Text = text
	warningLabel.TextColor3 = color or UI.Theme.Danger
	warningLabel.TextTransparency = 0
	warningLabel.TextStrokeTransparency = 0.4
	task.delay(4, function()
		if token == warningToken then
			TweenService:Create(warningLabel, TweenInfo.new(1), { TextTransparency = 1, TextStrokeTransparency = 1 })
				:Play()
		end
	end)
end

function NotificationController.Init()
	local gui = UI.screen("Notifications", 5)
	toastHolder = UI.create("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 90),
		Size = UDim2.new(0, 320, 0.6, 0),
		BackgroundTransparency = 1,
		Parent = gui,
	}, { UI.list(Enum.FillDirection.Vertical, 6) })
	warningLabel = UI.label("", 26, {
		Name = "Warning",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 70),
		Size = UDim2.new(0.8, 0, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = UI.Theme.FontBold,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Parent = gui,
	})
end

function NotificationController.Start()
	local notify = Remotes.get("Notify") :: RemoteEvent
	notify.OnClientEvent:Connect(function(text: string, severity: string, _key: string?)
		-- Danger messages that open in capitals ("YOU ARE FREEZING...") get the big band.
		local head = text:sub(1, 8)
		if severity == "danger" and head == head:upper() and head:match("%u%u%u") then
			NotificationController.warning(text)
		else
			NotificationController.toast(text, severity)
		end
	end)
end

return NotificationController
