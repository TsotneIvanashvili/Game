--!strict
-- Client-side mirror of what the server tells us. Read-only from gameplay's point of view:
-- the UI renders it, and every change request goes back to the server through a remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

local ClientState = {
	inventory = nil :: any, -- latest InventorySync snapshot
	InventoryChanged = Signal.new(),
	openPanel = nil :: string?, -- name of the modal panel currently open (one at a time)
	PanelChanged = Signal.new(),
	placing = false, -- Build Book placement mode active
}

function ClientState.setInventory(snapshot: any)
	ClientState.inventory = snapshot
	ClientState.InventoryChanged:Fire(snapshot)
end

-- Only one modal panel at a time; opening one closes the others.
function ClientState.setPanel(name: string?)
	if ClientState.openPanel == name then
		return
	end
	ClientState.openPanel = name
	ClientState.PanelChanged:Fire(name)
end

return ClientState
