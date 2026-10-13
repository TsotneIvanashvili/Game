-- RemoteEvent / RemoteFunction bridging between the server context and client contexts.
--
-- Arguments are copied the way the real network does: plain tables are deep-copied with
-- metatables stripped, functions become nil, mixed tables lose their string keys, tables with
-- non-string keys (sparse arrays, dictionaries keyed by numbers or Instances) get their keys
-- converted to strings, cyclic tables error, and Instances arrive by reference only when the
-- receiver can see them (client-only instances, or server instances outside replicated
-- containers, arrive as nil). Lossy conversions are recorded in M.notes.
--
-- Delivery is deferred (next resumption point). Events fired before the receiver connected
-- are queued per receiving context and delivered on the first Connect, like the engine.

return function(M)
	local S = M.S
	local fmt = string.format

	local REPLICATED = {
		Workspace = true,
		ReplicatedStorage = true,
		ReplicatedFirst = true,
		Players = true,
		Lighting = true,
		Teams = true,
		SoundService = true,
		StarterGui = true,
		StarterPack = true,
		StarterPlayer = true,
		Chat = true,
	}
	local function replicatesTo(inst, ctx): boolean
		if not M.visibleTo(inst, ctx) then
			return false
		end
		if not ctx.isClient or rawget(inst, "_owner") == ctx then
			return true
		end
		-- server-owned: must live under a replicated service
		local node = inst
		while node do
			local parent = rawget(node, "_parent")
			if parent and rawget(parent, "_isGame") then
				return REPLICATED[node._cls.name] == true
			end
			node = parent
		end
		return false
	end
	M.replicatesTo = replicatesTo

	local function note(msg: string)
		if #M.notes < 500 then
			table.insert(M.notes, msg)
		end
	end

	local function copyValue(v, target, seen, path: string, label: string)
		local t = M.typeof(v)
		if t == "nil" or t == "boolean" or t == "number" or t == "string" then
			return v
		elseif t == "function" or t == "thread" then
			note(fmt("%s: %s at %s was sent as nil (functions can't cross the network)", label, t, path))
			return nil
		elseif t == "Instance" then
			if target == nil or replicatesTo(v, target) then
				return v
			end
			note(fmt("%s: Instance %s at %s arrived as nil (not replicated to %s)", label, M.fullName(v), path, target.name))
			return nil
		elseif t == "table" then
			if seen[v] then
				error(fmt("%s: tables cannot be cyclic (at %s)", label, path), 0)
			end
			seen[v] = true
			local n = #v
			local count, hasString, hasOther = 0, false, false
			for k in v do
				count += 1
				if type(k) == "string" then
					hasString = true
				elseif not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
					hasOther = true
				end
			end
			local out = {}
			if count == n then
				for i = 1, n do
					out[i] = copyValue(v[i], target, seen, path .. "[" .. i .. "]", label)
				end
			elseif n > 0 and hasString then
				note(fmt("%s: mixed table at %s lost its string keys", label, path))
				for i = 1, n do
					out[i] = copyValue(v[i], target, seen, path .. "[" .. i .. "]", label)
				end
			else
				if hasOther then
					note(fmt("%s: non-string keys at %s were converted to strings", label, path))
				end
				for k, val in v do
					local key = if type(k) == "string" then k else tostring(k)
					out[key] = copyValue(val, target, seen, path .. "." .. key, label)
				end
			end
			seen[v] = nil
			return out
		end
		-- Roblox datatypes are immutable values: share them.
		return v
	end
	-- Copies an argument list for delivery to `target` (nil = same VM, e.g. bindables).
	function M.copyArgs(target, ...)
		local n = select("#", ...)
		local args = { ... }
		local label = if target then "remote to " .. target.name else "bindable"
		for i = 1, n do
			args[i] = copyValue(args[i], target, {}, "arg" .. i, label)
		end
		return table.unpack(args, 1, n)
	end

	-- Queued delivery ----------------------------------------------------------------------------
	local function queueFor(remote, ctx)
		local queues = rawget(remote, "_queues")
		if not queues then
			queues = {}
			rawset(remote, "_queues", queues)
		end
		local q = queues[ctx]
		if not q then
			q = {}
			queues[ctx] = q
		end
		return q
	end
	local function hasConnection(sig, ctx): boolean
		for _, c in sig._conns do
			if c.Connected and c._ctx == ctx then
				return true
			end
		end
		return #sig._waiters > 0 and (function()
			for _, w in sig._waiters do
				if w.ctx == ctx then
					return true
				end
			end
			return false
		end)()
	end
	local function onlyCtx(ctx)
		return function(c)
			return c == ctx
		end
	end
	-- One-way network latency in virtual seconds (0 = deliver at the next resumption point).
	M.latency = 0
	local function deliverNow(remote, eventName: string, ctx, args)
		if ctx.dead then
			return
		end
		local sig = M.getEvent(remote, eventName)
		if not sig._onConnect then
			sig._onConnect = function(conn)
				local queues = rawget(remote, "_queues")
				local q = queues and queues[conn._ctx]
				if q and #q > 0 then
					queues[conn._ctx] = nil
					for _, pending in q do
						M.fireFiltered(sig, onlyCtx(conn._ctx), table.unpack(pending, 1, pending.n))
					end
				end
			end
		end
		if hasConnection(sig, ctx) then
			M.fireFiltered(sig, onlyCtx(ctx), table.unpack(args, 1, args.n))
		else
			local q = queueFor(remote, ctx)
			table.insert(q, args)
			if #q == 257 then
				M.warnAs(ctx, fmt("Remote event invocation queue exhausted for %s; did you forget to implement %s?", M.fullName(remote), eventName))
			end
		end
	end

	local function deliver(remote, eventName: string, ctx, args)
		if M.latency > 0 then
			S.at(S.now + M.latency, function()
				deliverNow(remote, eventName, ctx, args)
			end)
		else
			deliverNow(remote, eventName, ctx, args)
		end
	end

	local function ctxOf()
		return S.current or M.serverCtx
	end

	function M.remoteFireServer(remote, ...)
		local ctx = ctxOf()
		if not ctx.isClient then
			error("FireServer can only be called from the client", 3)
		end
		if not rawget(remote, "_inGame") then
			error("FireServer: remote is not in the DataModel", 3)
		end
		local args = table.pack(ctx.player, M.copyArgs(M.serverCtx, ...))
		deliver(remote, "OnServerEvent", M.serverCtx, args)
	end
	function M.remoteFireClient(remote, player, ...)
		local ctx = ctxOf()
		if ctx.isClient then
			error("FireClient can only be called from the server", 3)
		end
		if not (M.isInstance(player) and player._cls.name == "Player") then
			error("FireClient: player argument must be a Player object", 3)
		end
		local target = rawget(player, "_clientCtx")
		if not target or not rawget(player, "_parent") then
			return
		end
		deliver(remote, "OnClientEvent", target, table.pack(M.copyArgs(target, ...)))
	end
	function M.remoteFireAllClients(remote, ...)
		local ctx = ctxOf()
		if ctx.isClient then
			error("FireAllClients can only be called from the server", 3)
		end
		for _, player in M.players:GetPlayers() do
			local target = rawget(player, "_clientCtx")
			if target then
				deliver(remote, "OnClientEvent", target, table.pack(M.copyArgs(target, ...)))
			end
		end
	end

	-- Invokes `callbackName` on `remote` in `targetCtx` from the current thread and yields for
	-- the result. Waits (like the engine) until a callback is assigned.
	local function invoke(remote, callbackName: string, targetCtx, firstArg, ...)
		local caller = ctxOf()
		local co, tok = S.park()
		local args = table.pack(M.copyArgs(targetCtx, ...))
		local waitedWarned = false
		local started = S.now
		local function attempt()
			if targetCtx.dead then
				S.wake(co, tok, false, "target disconnected")
				return
			end
			local fn = remote._p[callbackName]
			if not fn then
				if not waitedWarned and S.now - started > 5 then
					waitedWarned = true
					M.warnAs(caller, fmt("%s:%s is not set; the invoke is waiting", M.fullName(remote), callbackName))
				end
				S.at(S.now + 1 / 30, attempt)
				return
			end
			local handler = S.newThread(function()
				local results
				if firstArg ~= nil then
					results = table.pack(pcall(fn, firstArg, table.unpack(args, 1, args.n)))
				else
					results = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
				end
				local reply
				if not results[1] then
					reply = table.pack(false, results[2])
				else
					reply = table.pack(true, table.pack(M.copyArgs(caller, table.unpack(results, 2, results.n))))
				end
				if M.latency > 0 then
					S.at(S.now + M.latency, function()
						S.wake(co, tok, table.unpack(reply, 1, reply.n))
					end)
				else
					S.wake(co, tok, table.unpack(reply, 1, reply.n))
				end
			end, targetCtx)
			S.defer({ co = handler, ctx = targetCtx, args = table.pack() })
		end
		if M.latency > 0 then
			S.at(S.now + M.latency, function()
				S.defer({ co = S.newThread(attempt, targetCtx), ctx = targetCtx, args = table.pack() })
			end)
		else
			S.defer({ co = S.newThread(attempt, targetCtx), ctx = targetCtx, args = table.pack() })
		end
		local ok, result = coroutine.yield()
		if not ok then
			error(result, 0)
		end
		return table.unpack(result, 1, result.n)
	end

	function M.remoteInvokeServer(remote, ...)
		local ctx = ctxOf()
		if not ctx.isClient then
			error("InvokeServer can only be called from the client", 3)
		end
		return invoke(remote, "OnServerInvoke", M.serverCtx, ctx.player, ...)
	end
	function M.remoteInvokeClient(remote, player, ...)
		local ctx = ctxOf()
		if ctx.isClient then
			error("InvokeClient can only be called from the server", 3)
		end
		local target = rawget(player, "_clientCtx")
		if not target then
			error("InvokeClient: player has no client", 3)
		end
		return invoke(remote, "OnClientInvoke", target, nil, ...)
	end
end
