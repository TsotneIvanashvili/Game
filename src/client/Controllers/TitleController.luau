--!strict
-- Title screen shown once on join: "SUMMIT EXPEDITION" with Play / How to play / Gear.
-- It is the "Title" panel in ClientState, so the HUD and hotbar hide while it's open and
-- opening any other panel (Tab, B, a server prompt) closes it. A client-side BlurEffect
-- softens the world behind it.

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local UI = require(script.Parent.Parent.UI.UI)
local ClientState = require(script.Parent.Parent.ClientState)

local TitleController = {}

local PANEL_NAME = "Title"
local T = UI.Theme

local HOW_TO_PLAY = [[
<b>GOAL</b>
Climb from Base Camp past Camp 1 and Camp 2 to the Summit. Sign each camp's logbook: if you're evacuated you return to the highest camp you signed.

<b>STAY ALIVE</b>
Watch the stats in the bottom-right: health, warmth, water, food and energy. Cold, wind and wet clothes drain warmth fast. Fires and shelters warm you; eat and drink before you run low.

<b>CONTROLS</b>
WASD move  ·  Shift sprint  ·  Space jump
C climb a rock or ice face (C again to let go)
Tab / I backpack  ·  B Build Book  ·  H gear toggles
M route  ·  V first / third person  ·  G ping a spot
1-4 quick use: water, food, first aid, ice axe
X set down a teammate you're carrying

<b>TEAMWORK</b>
A downed climber can be revived or carried to safety. Give items from your backpack to teammates standing close by.

<b>WEATHER</b>
Storms are announced at the top of the screen. When one arrives, find shelter or build one before it hits.]]

local GEAR_TEXT = [[
<b>THE EQUIPMENT TENT</b>
Every expedition starts at the big equipment tent in Base Camp. Walk up to the outfitter rack and press the prompt to open it.

<b>CLOTHING</b>
Pick one item per slot: head, face, goggles, base layer, jacket, gloves, pants and boots. Warmer clothing weighs more, and weight is the real cost.

<b>PACKS</b>
Bigger packs carry more and have more slots. Over the weight limit you slow down and tire fast.

<b>SUPPLY CRATE</b>
Next to the tent, the supply crate holds your share of food, water and first aid for the climb.

<b>GEAR TOGGLES</b>
Press H (or the helmet button) to switch your helmet, mask, goggles and head lamp on or off. Items you aren't wearing show a padlock.

<b>RANKS</b>
Some gear unlocks as you rank up from Beginner Mountaineer to Expedition Leader.]]

local gui: ScreenGui
local blur: BlurEffect
local menu: Frame
local page: Frame
local pageTitle: TextLabel
local pageText: TextLabel
local pageScroll: ScrollingFrame

local function showPage(titleText: string?, body: string?)
	if titleText and body then
		pageTitle.Text = titleText
		pageText.Text = body
		pageScroll.CanvasPosition = Vector2.zero
		menu.Visible = false
		page.Visible = true
	else
		page.Visible = false
		menu.Visible = true
	end
end

local function setOpen(open: boolean)
	gui.Enabled = open
	blur.Enabled = open
	if not open then
		showPage(nil, nil)
	end
end

local function menuButton(text: string, order: number, color: Color3, height: number, onClick: () -> ())
	return UI.button(text, onClick, {
		Size = UDim2.fromOffset(320, height),
		TextSize = if height > 60 then 36 else 26,
		BackgroundColor3 = color,
		LayoutOrder = order,
		Parent = menu,
	})
end

function TitleController.Init()
	gui = UI.screen("Title", 30, true)
	blur = Instance.new("BlurEffect")
	blur.Name = "TitleBlur"
	blur.Size = 18
	blur.Enabled = false
	blur.Parent = Lighting

	local backdrop = UI.create("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = T.BlueDeep,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Parent = gui,
	}, {
		UI.create("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.6),
				NumberSequenceKeypoint.new(1, 0),
			}),
		}),
	})

	local content = UI.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(700, 640),
		BackgroundTransparency = 1,
		Parent = backdrop,
	})
	UI.autoScale(content)

	-- Logo.
	UI.icon("mountain", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(120, 120),
		Parent = content,
	})
	UI.title("SUMMIT", 96, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 108),
		Size = UDim2.new(1, 0, 0, 96),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
		Parent = content,
	})
	UI.title("EXPEDITION", 54, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 196),
		Size = UDim2.new(1, 0, 0, 58),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = T.Cyan,
		TextWrapped = false,
		Parent = content,
	})
	UI.title("Climb together. Stay warm. Reach the summit.", 20, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 258),
		Size = UDim2.new(1, 0, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = content,
	})

	-- Menu buttons.
	menu = UI.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 310),
		Size = UDim2.fromOffset(340, 300),
		BackgroundTransparency = 1,
		Parent = content,
	}, {
		UI.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 16),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local play = menuButton("PLAY", 1, T.Blue, 76, function()
		if ClientState.openPanel == PANEL_NAME then
			ClientState.setPanel(nil)
		end
	end)
	play.Modal = true -- frees the mouse while the title is up
	play:FindFirstChildOfClass("UIStroke").Thickness = 6
	menuButton("HOW TO PLAY", 2, T.Blue, 60, function()
		showPage("HOW TO PLAY", HOW_TO_PLAY)
	end)
	menuButton("GEAR", 3, T.Blue, 60, function()
		showPage("GEAR", GEAR_TEXT)
	end)

	-- Text page (How to play / Gear).
	page = UI.card({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(640, 560),
		Visible = false,
		ZIndex = 2,
		Parent = content,
	})
	pageTitle = UI.title("", 32, {
		Position = UDim2.fromOffset(24, 14),
		Size = UDim2.new(1, -48, 0, 40),
		Parent = page,
	})
	local inset = UI.inset({
		Position = UDim2.fromOffset(18, 64),
		Size = UDim2.new(1, -36, 1, -146),
		BackgroundColor3 = T.BlueDark,
		Parent = page,
	})
	pageScroll = UI.create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = T.White,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = inset,
	}, { UI.padding(16) })
	pageText = UI.label("", 16, {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextYAlignment = Enum.TextYAlignment.Top,
		RichText = true,
		LineHeight = 1.15,
		Parent = pageScroll,
	})
	local back = UI.button("BACK", function()
		showPage(nil, nil)
	end, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(200, 52),
		TextSize = 24,
		Parent = page,
	})
	back.Modal = true

	-- Gentle bob on the logo so the screen doesn't feel frozen.
	TweenService:Create(
		content,
		TweenInfo.new(2.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = UDim2.new(0.5, 0, 0.5, -6) }
	):Play()

	-- Open on join. Other controllers check ClientState.openPanel when they start.
	setOpen(true)
	ClientState.setPanel(PANEL_NAME)
end

function TitleController.Start()
	ClientState.PanelChanged:Connect(function(name)
		setOpen(name == PANEL_NAME)
	end)
	setOpen(ClientState.openPanel == PANEL_NAME)
end

return TitleController
