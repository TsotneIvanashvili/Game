--!strict
-- Declarative helpers, the visual theme (docs/ART_DIRECTION.md section 9) and a small icon
-- set. All UI is built in code (no place-file GUI assets, no image asset ids), so the whole
-- interface lives in version control. Icons are composed from rounded/rotated Frames rather
-- than unicode glyphs, because fallback-font coverage for symbols varies by platform.

local TweenService = game:GetService("TweenService")

local UI = {}

local C = Color3.fromRGB

UI.Theme = {
	-- Palette (ART_DIRECTION section 3).
	Blue = C(0, 110, 200), -- panels, buttons
	BlueDark = C(0, 70, 140), -- insets
	BlueDeep = C(0, 42, 92), -- tracks, text outlines
	BlueLight = C(28, 145, 235), -- buttons sitting on a blue panel
	White = C(255, 255, 255),
	Cyan = C(0, 230, 255), -- big numbers
	Orange = C(255, 100, 20), -- warnings, storm banner
	Green = C(40, 185, 70), -- checkpoint banner, "on" toggles
	Red = C(220, 50, 50),
	Yellow = C(255, 210, 50),
	Disabled = C(110, 135, 165),

	-- Semantic names (older code and other controllers use these).
	Panel = C(0, 110, 200),
	PanelLight = C(0, 70, 140),
	Line = C(255, 255, 255),
	Text = C(255, 255, 255),
	Muted = C(190, 220, 248),
	Accent = C(0, 230, 255),
	Good = C(120, 240, 130),
	Warn = C(255, 195, 50),
	Danger = C(255, 90, 80),
	Cold = C(160, 225, 255),

	Font = Enum.Font.GothamBold, -- small text
	FontBold = Enum.Font.FredokaOne, -- everything big
	FontTitle = Enum.Font.FredokaOne,

	Stroke = 4, -- white outline on cards
	Radius = 18, -- card corner radius
}

local T = UI.Theme

function UI.create(className: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(className)
	local parent = nil
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			(inst :: any)[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function UI.corner(radius: number?): UICorner
	return UI.create("UICorner", { CornerRadius = UDim.new(0, radius or 8) })
end

-- Fully rounded ends (circles on square frames, capsules on rectangles).
function UI.round(): UICorner
	return UI.create("UICorner", { CornerRadius = UDim.new(0.5, 0) })
end

function UI.padding(px: number, py: number?): UIPadding
	return UI.create("UIPadding", {
		PaddingTop = UDim.new(0, py or px),
		PaddingBottom = UDim.new(0, py or px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	})
end

-- Border outline (never the text: ApplyStrokeMode.Border).
function UI.stroke(color: Color3?, thickness: number?): UIStroke
	return UI.create("UIStroke", {
		Color = color or T.White,
		Thickness = thickness or 3,
		Transparency = 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

-- Outline around the glyphs of a text object, for legibility over the 3D world.
function UI.textStroke(color: Color3?, thickness: number?): UIStroke
	return UI.create("UIStroke", {
		Color = color or T.BlueDeep,
		Thickness = thickness or 2,
		Transparency = 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

function UI.list(direction: Enum.FillDirection?, gap: number?): UIListLayout
	return UI.create("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

function UI.label(text: string, size: number?, props: { [string]: any }?): TextLabel
	local p = {
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = T.Text,
		Font = T.Font,
		TextSize = size or 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, (size or 14) + 6),
		TextWrapped = true,
	}
	for k, v in props or {} do
		p[k] = v
	end
	return UI.create("TextLabel", p)
end

-- Big FredokaOne text with a dark outline.
function UI.title(text: string, size: number?, props: { [string]: any }?): TextLabel
	local p: { [string]: any } = { Font = T.FontTitle }
	for k, v in props or {} do
		p[k] = v
	end
	local l = UI.label(text, size or 24, p)
	UI.textStroke(T.BlueDeep, if (size or 24) >= 30 then 3 else 2).Parent = l
	return l
end

function UI.button(text: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local p = {
		Text = text,
		TextColor3 = T.White,
		Font = T.FontBold,
		TextSize = 18,
		BackgroundColor3 = T.BlueLight,
		AutoButtonColor = true,
		Size = UDim2.new(0, 120, 0, 36),
		TextWrapped = true,
	}
	for k, v in props or {} do
		p[k] = v
	end
	local b = UI.create("TextButton", p, { UI.corner(12), UI.stroke(T.White, 3) })
	b.Activated:Connect(onClick)
	return b
end

-- Greys a button out (it still receives clicks; handlers should check their own state).
function UI.setButtonEnabled(b: TextButton, enabled: boolean, color: Color3?)
	b.AutoButtonColor = enabled
	b.BackgroundColor3 = if enabled then color or T.BlueLight else T.Disabled
	b.TextColor3 = if enabled then T.White else C(225, 232, 240)
end

-- Solid UI-blue card with the thick white outline.
function UI.card(props: { [string]: any }?): Frame
	local p = {
		BackgroundColor3 = T.Blue,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(200, 100),
	}
	for k, v in props or {} do
		p[k] = v
	end
	return UI.create("Frame", p, { UI.corner(T.Radius), UI.stroke(T.White, T.Stroke) })
end

-- Dark-blue inset inside a card (no outline).
function UI.inset(props: { [string]: any }?): Frame
	local p = {
		BackgroundColor3 = T.BlueDark,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 40),
	}
	for k, v in props or {} do
		p[k] = v
	end
	return UI.create("Frame", p, { UI.corner(12) })
end

-- Small rounded chip / pill.
function UI.pill(text: string, color: Color3, props: { [string]: any }?): TextLabel
	local p = {
		Text = text,
		Font = T.Font,
		TextSize = 13,
		TextColor3 = T.White,
		BackgroundColor3 = color,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = false,
	}
	for k, v in props or {} do
		p[k] = v
	end
	return UI.create("TextLabel", p, { UI.round(), UI.padding(10, 0), UI.stroke(T.White, 2) })
end

function UI.panel(name: string, size: UDim2, parent: Instance): Frame
	return UI.create("Frame", {
		Name = name,
		Size = size,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = T.Blue,
		BorderSizePixel = 0,
		Visible = false,
		Parent = parent,
	}, { UI.corner(24), UI.stroke(T.White, 6) })
end

-- Icons ----------------------------------------------------------------------------------
-- Each shape: { kind, centreX, centreY, width, height, rotation?, role? } in 0..1 of the icon
-- box. kind: "c" circle, "p" capsule, "r" rounded rect, "s" sharp rect.
-- role: "f" foreground (default), "b" background mask (must match what the icon sits on),
-- "a" accent. The icon box clips, so shapes may hang past its edges (mountains, tents).

type Shape = { any }

local ICONS: { [string]: { Shape } } = {
	heart = { { "s", 0.5, 0.542, 0.57, 0.57, 45 }, { "c", 0.298, 0.34, 0.57, 0.57 }, { "c", 0.702, 0.34, 0.57, 0.57 } },
	drop = { { "c", 0.5, 0.577, 0.746, 0.746 }, { "s", 0.5, 0.313, 0.373, 0.373, 45 } },
	bolt = { { "s", 0.6, 0.27, 0.2, 0.5, 25 }, { "s", 0.4, 0.73, 0.2, 0.5, 25 }, { "s", 0.5, 0.5, 0.52, 0.17 } },
	thermo = {
		{ "p", 0.5, 0.38, 0.28, 0.64 },
		{ "c", 0.5, 0.74, 0.42, 0.42 },
		{ "p", 0.5, 0.46, 0.12, 0.44, 0, "a" },
		{ "c", 0.5, 0.74, 0.26, 0.26, 0, "a" },
	},
	food = {
		{ "c", 0.38, 0.6, 0.54, 0.62 },
		{ "c", 0.62, 0.6, 0.54, 0.62 },
		{ "p", 0.52, 0.2, 0.08, 0.26, 15 },
		{ "p", 0.67, 0.2, 0.24, 0.11, -25, "a" },
	},
	mountain = {
		{ "s", 0.4, 1, 0.82, 0.82, 45 },
		{ "s", 0.78, 1, 0.51, 0.51, 45 },
		{ "s", 0.4, 0.568, 0.21, 0.21, 45, "a" },
	},
	sun = {
		{ "p", 0.5, 0.5, 0.1, 0.94, 0, "a" },
		{ "p", 0.5, 0.5, 0.1, 0.94, 45, "a" },
		{ "p", 0.5, 0.5, 0.1, 0.94, 90, "a" },
		{ "p", 0.5, 0.5, 0.1, 0.94, 135, "a" },
		{ "c", 0.5, 0.5, 0.56, 0.56, 0, "a" },
	},
	moon = { { "c", 0.5, 0.5, 0.72, 0.72 }, { "c", 0.68, 0.38, 0.58, 0.58, 0, "b" } },
	cloud = { { "c", 0.34, 0.58, 0.42, 0.42 }, { "c", 0.6, 0.46, 0.52, 0.52 }, { "p", 0.5, 0.68, 0.86, 0.3 } },
	snow = {
		{ "p", 0.5, 0.5, 0.11, 0.92, 0 },
		{ "p", 0.5, 0.5, 0.11, 0.92, 60 },
		{ "p", 0.5, 0.5, 0.11, 0.92, 120 },
		{ "c", 0.5, 0.5, 0.28, 0.28 },
	},
	storm = {
		{ "c", 0.34, 0.4, 0.4, 0.4 },
		{ "c", 0.6, 0.3, 0.48, 0.48 },
		{ "p", 0.5, 0.5, 0.86, 0.28 },
		{ "s", 0.56, 0.7, 0.12, 0.26, 25, "a" },
		{ "s", 0.46, 0.88, 0.12, 0.26, 25, "a" },
	},
	fog = { { "p", 0.5, 0.28, 0.8, 0.12 }, { "p", 0.42, 0.5, 0.72, 0.12 }, { "p", 0.56, 0.72, 0.76, 0.12 } },
	wind = { { "p", 0.42, 0.3, 0.66, 0.1 }, { "p", 0.52, 0.5, 0.86, 0.1 }, { "p", 0.38, 0.7, 0.58, 0.1 } },
	compass = {
		{ "c", 0.5, 0.5, 0.94, 0.94 },
		{ "c", 0.5, 0.5, 0.72, 0.72, 0, "b" },
		{ "p", 0.5, 0.5, 0.16, 0.6, 45, "a" },
		{ "c", 0.5, 0.5, 0.14, 0.14 },
	},
	pack = {
		{ "c", 0.5, 0.24, 0.36, 0.36 },
		{ "c", 0.5, 0.24, 0.2, 0.2, 0, "b" },
		{ "r", 0.5, 0.6, 0.64, 0.68 },
		{ "s", 0.5, 0.52, 0.64, 0.06, 0, "b" },
		{ "r", 0.5, 0.75, 0.36, 0.2, 0, "b" },
	},
	helmet = {
		{ "c", 0.5, 0.66, 0.8, 0.8 },
		{ "s", 0.5, 0.92, 1, 0.36, 0, "b" },
		{ "p", 0.5, 0.72, 0.96, 0.12 },
		{ "c", 0.5, 0.44, 0.2, 0.2, 0, "a" },
	},
	mask = {
		{ "p", 0.5, 0.54, 0.64, 0.88 },
		{ "p", 0.5, 0.42, 0.46, 0.14, 0, "b" },
		{ "p", 0.5, 0.7, 0.24, 0.08, 0, "b" },
	},
	goggles = {
		{ "p", 0.5, 0.5, 0.98, 0.1 },
		{ "r", 0.3, 0.5, 0.38, 0.34 },
		{ "r", 0.7, 0.5, 0.38, 0.34 },
		{ "r", 0.3, 0.5, 0.26, 0.2, 0, "a" },
		{ "r", 0.7, 0.5, 0.26, 0.2, 0, "a" },
	},
	light = {
		{ "p", 0.74, 0.3, 0.36, 0.08, -25 },
		{ "p", 0.78, 0.5, 0.38, 0.08 },
		{ "p", 0.74, 0.7, 0.36, 0.08, 25 },
		{ "c", 0.32, 0.5, 0.48, 0.48 },
		{ "c", 0.32, 0.5, 0.28, 0.28, 0, "a" },
	},
	hammer = { { "p", 0.42, 0.6, 0.14, 0.7, 45 }, { "r", 0.66, 0.34, 0.52, 0.2, 45 } },
	axe = { { "p", 0.46, 0.56, 0.11, 0.84, 20 }, { "p", 0.57, 0.2, 0.6, 0.13, 20 } },
	camera = {
		{ "r", 0.34, 0.26, 0.26, 0.16 },
		{ "r", 0.5, 0.58, 0.88, 0.6 },
		{ "c", 0.5, 0.58, 0.42, 0.42, 0, "b" },
		{ "c", 0.5, 0.58, 0.24, 0.24 },
	},
	lock = {
		{ "c", 0.5, 0.38, 0.52, 0.52 },
		{ "c", 0.5, 0.38, 0.3, 0.3, 0, "b" },
		{ "r", 0.5, 0.7, 0.7, 0.5 },
		{ "c", 0.5, 0.65, 0.14, 0.14, 0, "b" },
		{ "p", 0.5, 0.75, 0.07, 0.16, 0, "b" },
	},
	cross = { { "r", 0.5, 0.5, 0.28, 0.82 }, { "r", 0.5, 0.5, 0.82, 0.28 } },
	flame = {
		{ "c", 0.5, 0.62, 0.66, 0.66 },
		{ "s", 0.5, 0.387, 0.33, 0.33, 45 },
		{ "c", 0.5, 0.7, 0.32, 0.32, 0, "a" },
	},
	shirt = {
		{ "p", 0.24, 0.42, 0.18, 0.52, 35 },
		{ "p", 0.76, 0.42, 0.18, 0.52, -35 },
		{ "r", 0.5, 0.6, 0.52, 0.68 },
		{ "c", 0.5, 0.26, 0.22, 0.22, 0, "b" },
	},
	glove = { { "p", 0.24, 0.58, 0.16, 0.4, -35 }, { "r", 0.54, 0.5, 0.5, 0.62 }, { "r", 0.54, 0.88, 0.52, 0.14 } },
	boot = { { "r", 0.4, 0.4, 0.36, 0.64 }, { "r", 0.56, 0.74, 0.72, 0.32 }, { "s", 0.56, 0.92, 0.74, 0.06, 0, "b" } },
	pants = { { "r", 0.5, 0.2, 0.6, 0.16 }, { "r", 0.36, 0.6, 0.26, 0.76 }, { "r", 0.64, 0.6, 0.26, 0.76 } },
	log = { { "p", 0.5, 0.64, 0.9, 0.3, -12 }, { "p", 0.5, 0.36, 0.9, 0.3, 12 } },
	box = { { "r", 0.5, 0.56, 0.8, 0.66 }, { "s", 0.5, 0.42, 0.8, 0.06, 0, "b" }, { "s", 0.5, 0.7, 0.8, 0.06, 0, "b" } },
	tent = { { "s", 0.5, 1, 0.86, 0.86, 45 }, { "s", 0.5, 1, 0.32, 0.32, 45, "b" } },
	flag = { { "s", 0.28, 0.52, 0.08, 0.86 }, { "r", 0.54, 0.3, 0.46, 0.34, 0, "a" } },
	person = { { "c", 0.5, 0.28, 0.36, 0.36 }, { "p", 0.5, 0.86, 0.66, 0.56 } },
	check = { { "p", 0.36, 0.62, 0.14, 0.38, -45 }, { "p", 0.6, 0.48, 0.14, 0.66, 40 } },
	close = { { "p", 0.5, 0.5, 0.14, 0.86, 45 }, { "p", 0.5, 0.5, 0.14, 0.86, -45 } },
	rope = {
		{ "c", 0.5, 0.5, 0.86, 0.86 },
		{ "c", 0.5, 0.5, 0.56, 0.56, 0, "b" },
		{ "c", 0.5, 0.5, 0.4, 0.4 },
		{ "c", 0.5, 0.5, 0.2, 0.2, 0, "b" },
	},
	info = { { "c", 0.5, 0.5, 0.9, 0.9 }, { "r", 0.5, 0.6, 0.14, 0.38, 0, "b" }, { "c", 0.5, 0.3, 0.15, 0.15, 0, "b" } },
	warn = {
		{ "c", 0.5, 0.5, 0.9, 0.9 },
		{ "r", 0.5, 0.42, 0.14, 0.4, 0, "b" },
		{ "c", 0.5, 0.74, 0.15, 0.15, 0, "b" },
	},
}

local ACCENTS: { [string]: Color3 } = {
	thermo = C(255, 95, 60),
	food = C(110, 210, 90),
	mountain = T.Cyan,
	sun = T.Yellow,
	storm = T.Yellow,
	compass = C(255, 80, 80),
	helmet = T.Yellow,
	goggles = T.Cyan,
	light = T.Yellow,
	flame = T.Yellow,
	flag = C(60, 230, 90),
}

export type IconColors = { fg: Color3?, bg: Color3?, accent: Color3? }

function UI.hasIcon(kind: string): boolean
	return ICONS[kind] ~= nil
end

-- A square, clipping Frame holding the icon. Unknown kinds render as text (e.g. "O2").
function UI.icon(kind: string, props: { [string]: any }?, colors: IconColors?): Frame
	local fg = (colors and colors.fg) or T.White
	local bg = (colors and colors.bg) or T.Blue
	local accent = (colors and colors.accent) or ACCENTS[kind] or fg
	local p = {
		Name = "Icon",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
	}
	for k, v in props or {} do
		p[k] = v
	end
	local box = UI.create("Frame", p, { UI.create("UIAspectRatioConstraint", { AspectRatio = 1 }) })
	local shapes = ICONS[kind]
	if not shapes then
		UI.label(kind, 14, {
			Size = UDim2.fromScale(1, 1),
			Font = T.FontBold,
			TextScaled = true,
			TextColor3 = fg,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = box,
		})
		return box
	end
	for i, s in shapes do
		local shapeKind, role = s[1], s[7] or "f"
		local f = UI.create("Frame", {
			Name = role,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(s[2], s[3]),
			Size = UDim2.fromScale(s[4], s[5]),
			Rotation = s[6] or 0,
			BorderSizePixel = 0,
			BackgroundColor3 = if role == "b" then bg elseif role == "a" then accent else fg,
			ZIndex = i, -- later shapes (masks) draw over earlier ones
			Parent = box,
		})
		if shapeKind == "c" or shapeKind == "p" then
			UI.round().Parent = f
		elseif shapeKind == "r" then
			UI.create("UICorner", { CornerRadius = UDim.new(0.22, 0), Parent = f })
		end
	end
	return box
end

-- Recolour an icon built by UI.icon without rebuilding it.
function UI.tintIcon(icon: Instance, fg: Color3?, accent: Color3?, bg: Color3?)
	for _, f in icon:GetChildren() do
		if f:IsA("Frame") then
			if f.Name == "f" and fg then
				f.BackgroundColor3 = fg
			elseif f.Name == "a" and accent then
				f.BackgroundColor3 = accent
			elseif f.Name == "b" and bg then
				f.BackgroundColor3 = bg
			end
		elseif f:IsA("TextLabel") and fg then
			f.TextColor3 = fg
		end
	end
end

local SLOT_ICONS = {
	Head = "helmet",
	Face = "mask",
	Eyes = "goggles",
	BaseLayer = "shirt",
	Jacket = "shirt",
	Gloves = "glove",
	Pants = "pants",
	Boots = "boot",
}

function UI.slotIconKind(slot: string): string
	return SLOT_ICONS[slot] or "shirt"
end

function UI.itemIconKind(def: any): string
	local id: string = def.id
	if def.clothing then
		return SLOT_ICONS[def.clothing.slot] or "shirt"
	elseif def.backpack then
		return "pack"
	elseif def.container or def.category == "Drink" then
		return "drop"
	elseif def.category == "Food" then
		return "food"
	elseif def.category == "Medical" then
		return if id == "hand_warmer" then "flame" else "cross"
	elseif def.holdable then
		return "axe"
	elseif id == "lighter" then
		return "flame"
	elseif id == "wood" then
		return "log"
	elseif id == "rope" then
		return "rope"
	elseif id == "tarp" or string.find(id, "tent") ~= nil then
		return "tent"
	elseif def.category == "Tool" then
		return "hammer"
	end
	return "box"
end

-- Round badge in the item's colour with its icon inside.
function UI.itemBadge(def: any, props: { [string]: any }?): Frame
	local color: Color3 = def.color or T.BlueLight
	local light = color.R * 0.299 + color.G * 0.587 + color.B * 0.114 > 0.72
	local p = {
		Name = "Badge",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(48, 48),
	}
	for k, v in props or {} do
		p[k] = v
	end
	local badge = UI.create("Frame", p, {
		UI.round(),
		UI.stroke(T.White, 2),
		UI.create("UIAspectRatioConstraint", { AspectRatio = 1 }),
	})
	UI.icon(UI.itemIconKind(def), {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		Parent = badge,
	}, { fg = if light then T.BlueDeep else T.White, bg = color })
	return badge
end

-- Round blue icon button with a white outline (left-edge buttons, close buttons).
function UI.roundButton(kind: string, size: number, onClick: () -> (), props: { [string]: any }?): TextButton
	local p = {
		Text = "",
		BackgroundColor3 = T.Blue,
		AutoButtonColor = true,
		Size = UDim2.fromOffset(size, size),
	}
	for k, v in props or {} do
		p[k] = v
	end
	local b = UI.create("TextButton", p, { UI.round(), UI.stroke(T.White, if size >= 48 then 4 else 3) })
	UI.icon(kind, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.58, 0.58),
		Parent = b,
	}, { bg = p.BackgroundColor3 })
	b.Activated:Connect(onClick)
	return b
end

-- Panel header: optional icon, big title and a round red close button (Modal frees the mouse
-- in first person while the panel is open).
function UI.header(panel: GuiObject, text: string, iconKind: string?, onClose: () -> ()): (TextLabel, TextButton)
	local x = 22
	if iconKind then
		UI.icon(iconKind, {
			Position = UDim2.fromOffset(20, 14),
			Size = UDim2.fromOffset(36, 36),
			Parent = panel,
		})
		x = 64
	end
	local title = UI.title(text, 30, {
		Position = UDim2.fromOffset(x, 12),
		Size = UDim2.new(1, -x - 70, 0, 40),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = panel,
	})
	local close = UI.roundButton("close", 44, onClose, {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		BackgroundColor3 = T.Red,
		Modal = true,
		Parent = panel,
	})
	return title, close
end

-- Horizontal fill bar. Returns the track and a setter.
function UI.bar(props: { [string]: any }?, fillColor: Color3?): (Frame, (ratio: number, color: Color3?) -> ())
	local p = {
		BackgroundColor3 = T.BlueDeep,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(200, 12),
	}
	for k, v in props or {} do
		p[k] = v
	end
	local track = UI.create("Frame", p, { UI.round() })
	local fill = UI.create("Frame", {
		Name = "Fill",
		BackgroundColor3 = fillColor or T.Cyan,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = track,
	}, { UI.round() })
	local last = -1
	local function set(ratio: number, color: Color3?)
		local r = math.clamp(ratio, 0, 1)
		if math.abs(r - last) > 0.002 then
			last = r
			fill.Size = UDim2.fromScale(r, 1)
			fill.Visible = r > 0.001
		end
		if color and fill.BackgroundColor3 ~= color then
			fill.BackgroundColor3 = color
		end
	end
	return track, set
end

export type Toggle = {
	button: TextButton,
	set: (on: boolean, enabled: boolean) -> (),
}

-- Pill toggle switch. `onFlip` is called with the requested new state; the owner decides
-- and calls `set` (usually after the server confirms).
function UI.toggle(props: { [string]: any }?, onFlip: (on: boolean) -> ()): Toggle
	local p = {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = T.BlueDeep,
		Size = UDim2.fromOffset(72, 36),
	}
	for k, v in props or {} do
		p[k] = v
	end
	local button = UI.create("TextButton", p, { UI.round(), UI.stroke(T.White, 3) })
	local knob = UI.create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = T.White,
		BorderSizePixel = 0,
		Parent = button,
	}, { UI.round() })
	local lock = UI.icon("lock", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		Visible = false,
		Parent = knob,
	}, { fg = T.Disabled, bg = T.White })
	local state = { on = false, enabled = true }
	local function set(on: boolean, enabled: boolean)
		state.on, state.enabled = on, enabled
		local target = if on and enabled then UDim2.new(1, -32, 0.5, 0) else UDim2.new(0, 4, 0.5, 0)
		TweenService:Create(knob, TweenInfo.new(0.12), { Position = target }):Play()
		button.BackgroundColor3 = if not enabled then T.Disabled elseif on then T.Green else T.BlueDeep
		lock.Visible = not enabled
	end
	button.Activated:Connect(function()
		if state.enabled then
			onFlip(not state.on)
		end
	end)
	return { button = button, set = set }
end

-- Screen-size aware scaling so panels fit phones. UIScale must sit on a GuiObject.
-- Offset-sized targets are additionally shrunk to fit the viewport.
function UI.autoScale(target: GuiObject)
	local scale = UI.create("UIScale", { Parent = target })
	local function update()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local viewport = camera.ViewportSize
		local s = math.clamp(math.min(viewport.X / 1280, viewport.Y / 720), 0.55, 1.25)
		local w, h = target.Size.X.Offset, target.Size.Y.Offset
		if target.Size.X.Scale == 0 and w > 0 then
			s = math.min(s, (viewport.X - 24) / w)
		end
		if target.Size.Y.Scale == 0 and h > 0 then
			s = math.min(s, (viewport.Y - 80) / h)
		end
		scale.Scale = math.max(s, 0.35)
	end
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
	end
	update()
end

function UI.screen(name: string, order: number?, ignoreInset: boolean?): ScreenGui
	local player = game:GetService("Players").LocalPlayer
	return UI.create("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = ignoreInset == true,
		DisplayOrder = order or 1,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
end

function UI.formatKg(kg: number): string
	return string.format("%.1f kg", kg)
end

-- Sets text only when it changed (cheap guard for 10 Hz HUD refreshes).
function UI.setText(label: TextLabel | TextButton, text: string)
	if label.Text ~= text then
		label.Text = text
	end
end

-- Removes every GuiObject child (keeps layouts/corners/strokes).
function UI.clear(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

return UI
