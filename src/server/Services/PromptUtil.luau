--!strict
-- ProximityPrompt helper. Prompts are created by the server, so their Triggered event fires
-- on the server with the real player: world interactions need no custom remotes.
-- Each prompt lives on its own Attachment so several prompts on one object don't overlap,
-- and each uses a distinct key (E / F / Q) so they never fight over input.

local PromptUtil = {}

export type PromptOptions = {
	action: string,
	object: string?,
	key: Enum.KeyCode?,
	hold: number?,
	distance: number?,
	offset: Vector3?,
	name: string?,
}

function PromptUtil.create(parent: BasePart, options: PromptOptions, onTriggered: (Player) -> ()): ProximityPrompt
	local attachment = Instance.new("Attachment")
	attachment.Name = (options.name or options.action) .. "Attachment"
	attachment.Position = options.offset or Vector3.zero
	attachment.Parent = parent

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = options.name or options.action
	prompt.ActionText = options.action
	prompt.ObjectText = options.object or ""
	prompt.KeyboardKeyCode = options.key or Enum.KeyCode.E
	prompt.HoldDuration = options.hold or 0
	prompt.MaxActivationDistance = options.distance or 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = attachment

	prompt.Triggered:Connect(function(player)
		-- Prompts can be fired by exploit tools from any distance; always re-check range.
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return
		end
		if (root.Position - attachment.WorldPosition).Magnitude > prompt.MaxActivationDistance + 4 then
			return
		end
		local ok, err = pcall(onTriggered, player)
		if not ok then
			warn("[Prompt] " .. prompt.Name .. " error: " .. tostring(err))
		end
	end)
	return prompt
end

return PromptUtil
