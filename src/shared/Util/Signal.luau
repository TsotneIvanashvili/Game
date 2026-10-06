--!strict
-- Minimal synchronous signal for server/client module communication. Handlers run in
-- order; an error in one handler is reported and does not stop the others.

export type Connection = { Disconnect: (self: Connection) -> () }
export type Signal = {
	Connect: (self: Signal, handler: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	return setmetatable({ _handlers = {} }, Signal) :: any
end

function Signal:Connect(handler: (...any) -> ()): Connection
	local entry = { fn = handler, connected = true }
	table.insert(self._handlers, entry)
	local handlers = self._handlers
	return {
		Disconnect = function()
			if not entry.connected then
				return
			end
			entry.connected = false
			local index = table.find(handlers, entry)
			if index then
				table.remove(handlers, index)
			end
		end,
	} :: any
end

function Signal:Fire(...: any)
	-- Copy so handlers may disconnect themselves while firing.
	for _, entry in table.clone(self._handlers) do
		if entry.connected then
			local ok, err = pcall(entry.fn, ...)
			if not ok then
				warn("[Signal] handler error: " .. tostring(err))
			end
		end
	end
end

function Signal:DisconnectAll()
	for _, entry in self._handlers do
		entry.connected = false
	end
	table.clear(self._handlers)
end

return Signal
