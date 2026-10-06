--!strict
-- Tiny declarative helpers and the visual theme. All UI is built in code (no place-file
-- GUI assets), so the whole interface lives in version control.

local UI = {}

UI.Theme = {
	Panel = Color3.fromRGB(18, 22, 28),
	PanelLight = Color3.fromRGB(32, 38, 46),
	Line = Color3.fromRGB(70, 80, 92),
	Text = Color3.fromRGB(232, 236, 240),
	Muted = Color3.fromRGB(150, 160, 170),
	Accent = Color3.fromRGB(255, 150, 60),
	Good = Color3.fromRGB(110, 200, 120),
	Warn = Color3.fromRGB(240, 190, 70),
	Danger = Color3.fromRGB(235, 80, 70),
	Cold = Color3.fromRGB(110, 170, 240),
	Font = Enum.Font.Gotham,
	FontBold = Enum.Font.GothamBold,
}

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
	return UI.create("UICorner", { CornerRadius = UDim.new(0, radius or 6) })
end

function UI.padding(px: number): UIPadding
	return UI.create("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	})
end

function UI.stroke(color: Color3?, thickness: number?): UIStroke
	return UI.create("UIStroke", { Color = color or UI.Theme.Line, Thickness = thickness or 1, Transparency = 0.3 })
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
		TextColor3 = UI.Theme.Text,
		Font = UI.Theme.Font,
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

function UI.button(text: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local p = {
		Text = text,
		TextColor3 = UI.Theme.Text,
		Font = UI.Theme.FontBold,
		TextSize = 14,
		BackgroundColor3 = UI.Theme.PanelLight,
		AutoButtonColor = true,
		Size = UDim2.new(0, 110, 0, 30),
	}
	for k, v in props or {} do
		p[k] = v
	end
	local b = UI.create("TextButton", p, { UI.corner(5), UI.stroke() })
	b.Activated:Connect(onClick)
	return b
end

function UI.panel(name: string, size: UDim2, parent: Instance): Frame
	return UI.create("Frame", {
		Name = name,
		Size = size,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = UI.Theme.Panel,
		BackgroundTransparency = 0.08,
		Visible = false,
		Parent = parent,
	}, { UI.corner(10), UI.stroke(UI.Theme.Line, 1.5) })
end

-- Screen-size aware scaling so panels fit phones. UIScale must sit on a GuiObject.
function UI.autoScale(target: GuiObject)
	local scale = UI.create("UIScale", { Parent = target })
	local camera = workspace.CurrentCamera
	local function update()
		local viewport = camera.ViewportSize
		scale.Scale = math.clamp(math.min(viewport.X / 1280, viewport.Y / 720), 0.6, 1.25)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
	update()
end

function UI.screen(name: string, order: number?): ScreenGui
	local player = game:GetService("Players").LocalPlayer
	return UI.create("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = order or 1,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
end

function UI.formatKg(kg: number): string
	return string.format("%.1f kg", kg)
end

return UI
