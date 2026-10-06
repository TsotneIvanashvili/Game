--!strict
-- Three layers of messages:
--   * event pill (top centre, under the compass): server "Banner"(text, kind), e.g.
--     "A storm has arrived. Be careful!" (storm = orange, checkpoint = green, info = blue,
--     danger = red)
--   * warning band (big text): danger Notify messages that open in capitals
--     ("YOU ARE FREEZING...")
--   * toasts (right side, under the info card): everything else.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local UI = require(script.Parent.Parent.UI.UI)

local NotificationController = {}

local T = UI.Theme
local MAX_TOASTS = 5
local BANNER_SECONDS = 6

local SEVERITY = {
	info = { color = T.BlueLight, icon = "info" },
	good = { color = T.Green, icon = "check" },
	warn = { color = T.Orange, icon = "warn" },
	danger = { color = T.Red, icon = "warn" },
}

local BANNER_KINDS = {
	storm = { color = T.Orange, icon = "storm" },
	checkpoint = { color = T.Green, icon = "flag" },
	info = { color = T.Blue, icon = "info" },
	danger = { color = T.Red, icon = "warn" },
}

local toastHolder: Frame
local warningLabel: TextLabel
local warningToken = 0
local toastOrder = 0

local banner: Frame
local bannerText: TextLabel
local bannerIconHolder: Frame
local bannerToken = 0
local SHOWN = UDim2.new(0.5, 0, 0, 100)
local HIDDEN = UDim2.new(0.5, 0, 0, -90)

function NotificationController.toast(text: string, severity: string?)
	local style = SEVERITY[severity or "info"] or SEVERITY.info
	toastOrder -= 1 -- newest first
	local toast = UI.card({
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = toastOrder,
		Parent = toastHolder,
	})
	toast:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, 14)
	toast:FindFirstChildOfClass("UIStroke").Thickness = 3
	UI.padding(10, 8).Parent = toast
	local dot = UI.create("Frame", {
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = style.color,
		BorderSizePixel = 0,
		Parent = toast,
	}, { UI.round(), UI.stroke(T.White, 2) })
	UI.icon(style.icon, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		Parent = dot,
	}, { bg = style.color, accent = T.White })
	UI.label(text, 15, {
		Position = UDim2.fromOffset(36, 0),
		Size = UDim2.new(1, -36, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = toast,
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
	warningLabel.TextColor3 = color or T.Danger
	warningLabel.TextTransparency = 0
	warningLabel.TextStrokeTransparency = 0
	task.delay(4, function()
		if token == warningToken then
			TweenService:Create(warningLabel, TweenInfo.new(1), { TextTransparency = 1, TextStrokeTransparency = 1 })
				:Play()
		end
	end)
end

-- Orange (or green/blue/red) pill at top centre. A new banner replaces the current one.
function NotificationController.banner(text: string, kind: string?)
	local style = BANNER_KINDS[kind or "info"] or BANNER_KINDS.info
	bannerToken += 1
	local token = bannerToken
	banner.BackgroundColor3 = style.color
	bannerText.Text = text
	UI.clear(bannerIconHolder)
	UI.icon(style.icon, { Parent = bannerIconHolder }, { bg = style.color, accent = T.White })
	banner.Visible = true
	banner.Position = HIDDEN
	TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = SHOWN,
	}):Play()
	task.delay(BANNER_SECONDS, function()
		if token ~= bannerToken then
			return
		end
		local out = TweenService:Create(banner, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = HIDDEN,
		})
		out.Completed:Connect(function()
			if token == bannerToken then
				banner.Visible = false
			end
		end)
		out:Play()
	end)
end

function NotificationController.Init()
	local gui = UI.screen("Notifications", 5)
	toastHolder = UI.create("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 196),
		Size = UDim2.new(0, 320, 0, 360),
		BackgroundTransparency = 1,
		Parent = gui,
	}, { UI.list(Enum.FillDirection.Vertical, 8) })
	UI.autoScale(toastHolder)

	warningLabel = UI.label("", 34, {
		Name = "Warning",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 168),
		Size = UDim2.new(0.8, 0, 0, 44),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = T.FontTitle,
		TextStrokeColor3 = T.BlueDeep,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Parent = gui,
	})

	banner = UI.create("Frame", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = HIDDEN,
		Size = UDim2.fromOffset(0, 54),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.Orange,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	}, {
		UI.round(),
		UI.stroke(T.White, 4),
		UI.padding(22, 0),
		UI.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 12),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	UI.autoScale(banner)
	bannerIconHolder = UI.create("Frame", {
		Size = UDim2.fromOffset(32, 32),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = banner,
	})
	bannerText = UI.title("", 26, {
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		TextWrapped = false,
		LayoutOrder = 2,
		Parent = banner,
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
	local bannerRemote = Remotes.get("Banner") :: RemoteEvent
	bannerRemote.OnClientEvent:Connect(function(text: any, kind: any)
		if typeof(text) == "string" then
			NotificationController.banner(text, if typeof(kind) == "string" then kind else "info")
		end
	end)
end

return NotificationController
