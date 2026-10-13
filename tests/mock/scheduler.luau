-- Virtual-time task scheduler and RBXScriptSignal emulation.
--
-- Every piece of game code runs inside a coroutine owned by this scheduler, tagged with the
-- context (server or one simulated client) it belongs to. `S.current` is the context of the
-- running thread; context-dependent APIs (Players.LocalPlayer, workspace.CurrentCamera,
-- RunService:IsClient(), per-client property overlays) read it.
--
-- Time never advances on its own: the harness calls `S.step(dt)` (default 1/30 s). A frame:
--   now += dt; RenderStepped (clients); Stepped; humanoid "physics"; resume task.wait /
--   task.delay threads that are due; Heartbeat; then the deferred queue is drained.
-- Signals use Roblox's Deferred signal behavior (the default for new places): handlers run at
-- the next resumption point (after the current thread yields or finishes), each in its own
-- coroutine, in the context that connected them.

return function(M)
	local S = {
		now = 0,
		frame = 0,
		current = nil :: any, -- running context
		deferred = {} :: { any },
		sleeping = {} :: { any },
		threadCtx = setmetatable({}, { __mode = "k" }) :: { [thread]: any },
		parked = setmetatable({}, { __mode = "k" }) :: { [thread]: any },
		seq = 0,
		frameHooks = {} :: { (dt: number) -> () },
	}
	M.S = S
	M.errors = {}

	local function cleanTrace(s: string): string
		s = string.gsub(s, '%[string "([^"]*)"%]', "%1")
		if M.root then
			s = string.gsub(s, M.root .. "/", "")
		end
		return s
	end
	M.cleanTrace = cleanTrace

	function S.report(err: any, co: thread?, ctx: any)
		local msg = tostring(err)
		local tb = if co then debug.traceback(co, msg) else debug.traceback(msg, 2)
		tb = cleanTrace(tb)
		table.insert(M.errors, { ctx = ctx, message = cleanTrace(msg), traceback = tb })
		M.log(ctx, "error", tb)
	end

	-- Resumes `co` in `ctx` (default: the context the thread was created in).
	function S.resume(co: thread, ctx: any, ...)
		if coroutine.status(co) ~= "suspended" then
			return
		end
		ctx = ctx or S.threadCtx[co] or S.current
		S.threadCtx[co] = ctx
		local prev = S.current
		S.current = ctx
		local ok, err = coroutine.resume(co, ...)
		S.current = prev
		if not ok then
			S.report(err, co, ctx)
		end
	end

	-- Parking: a thread that yields through the scheduler gets a token; only a wake carrying
	-- the same token resumes it (so a timeout and an event can't both resume one wait).
	function S.park(): (thread, any)
		local co = coroutine.running()
		if not coroutine.isyieldable() then
			error("attempt to yield from outside a coroutine (the test harness must run this via task.spawn)", 3)
		end
		local tok = {}
		S.parked[co] = tok
		return co, tok
	end
	function S.wake(co: thread, tok: any, ...)
		if S.parked[co] ~= tok then
			return false
		end
		S.parked[co] = nil
		S.resume(co, nil, ...)
		return true
	end
	function S.isParked(co: thread, tok: any): boolean
		return S.parked[co] == tok
	end

	function S.newThread(fn: (...any) -> ...any, ctx: any): thread
		local co = coroutine.create(fn)
		S.threadCtx[co] = ctx
		return co
	end

	function S.defer(entry)
		table.insert(S.deferred, entry)
	end

	-- Runs every deferred entry, including ones queued while draining.
	function S.drain()
		local n = 0
		while #S.deferred > 0 do
			local queue = S.deferred
			S.deferred = {}
			for _, d in queue do
				n += 1
				if n > 500000 then
					S.report("deferred queue did not settle (infinite task.defer / signal loop?)", nil, d.ctx)
					S.deferred = {}
					return
				end
				if d.conn then
					local c = d.conn
					if c.Connected or d.once then
						local co = S.newThread(c._fn, d.ctx)
						S.resume(co, d.ctx, table.unpack(d.args, 1, d.args.n))
					end
				elseif d.wakeCo then
					S.wake(d.wakeCo, d.tok, table.unpack(d.args, 1, d.args.n))
				elseif d.co then
					if not d.cancelled then
						S.resume(d.co, d.ctx, table.unpack(d.args, 1, d.args.n))
					end
				end
			end
		end
	end

	local function sleep(entry)
		S.seq += 1
		entry.seq = S.seq
		table.insert(S.sleeping, entry)
	end

	S.profile = {} :: { [string]: number }
	local function prof(name: string, t0: number)
		S.profile[name] = (S.profile[name] or 0) + os.clock() - t0
	end
	function S.step(dt: number)
		S.now += dt
		S.frame += 1
		for i, hook in S.frameHooks do
			local t0 = os.clock()
			hook(dt)
			S.drain()
			prof("hook" .. i, t0)
		end
		local t1 = os.clock()
		local due = {}
		local keep = {}
		for _, s in S.sleeping do
			if s.wake <= S.now + 1e-9 then
				table.insert(due, s)
			else
				table.insert(keep, s)
			end
		end
		S.sleeping = keep
		table.sort(due, function(a, b)
			if a.wake ~= b.wake then
				return a.wake < b.wake
			end
			return a.seq < b.seq
		end)
		for _, s in due do
			if s.cancelled then
				continue
			elseif s.check then
				s.check()
			elseif s.tok then
				S.wake(s.co, s.tok, S.now - s.start, S.now)
			else
				S.resume(s.co, s.ctx, table.unpack(s.args, 1, s.args.n))
			end
			S.drain()
		end
		prof("sleepers", t1)
		local t2 = os.clock()
		if M.afterResume then
			M.afterResume(dt)
		end
		S.drain()
		prof("heartbeat", t2)
	end

	-- Schedules a plain callback (not a game thread) at a virtual time.
	function S.at(t: number, fn: () -> ())
		sleep({ wake = t, check = fn })
	end

	-- task library ---------------------------------------------------------------------------
	local task = {}
	function task.wait(t: number?): number
		local seconds = tonumber(t) or 0
		local co, tok = S.park()
		sleep({ wake = S.now + math.max(seconds, 0), co = co, tok = tok, start = S.now })
		return coroutine.yield()
	end
	function task.spawn(f: any, ...): thread
		local co: thread
		if type(f) == "thread" then
			co = f
		elseif type(f) == "function" then
			co = S.newThread(f, S.current)
		else
			error("invalid argument #1 to 'spawn' (function or thread expected)", 2)
		end
		S.resume(co, S.threadCtx[co] or S.current, ...)
		return co
	end
	function task.defer(f: any, ...): thread
		local co: thread
		if type(f) == "thread" then
			co = f
		elseif type(f) == "function" then
			co = S.newThread(f, S.current)
		else
			error("invalid argument #1 to 'defer' (function or thread expected)", 2)
		end
		S.defer({ co = co, ctx = S.threadCtx[co] or S.current, args = table.pack(...) })
		return co
	end
	function task.delay(t: number?, f: any, ...): thread
		local co: thread
		if type(f) == "thread" then
			co = f
		elseif type(f) == "function" then
			co = S.newThread(f, S.current)
		else
			error("invalid argument #2 to 'delay' (function or thread expected)", 2)
		end
		local entry = { wake = S.now + math.max(tonumber(t) or 0, 0), co = co, ctx = S.current, args = table.pack(...) }
		sleep(entry)
		S.threadCtx[co] = S.current
		return co
	end
	function task.cancel(co: thread)
		if type(co) ~= "thread" then
			error("invalid argument #1 to 'cancel' (thread expected)", 2)
		end
		S.parked[co] = nil
		for _, s in S.sleeping do
			if s.co == co then
				s.cancelled = true
			end
		end
		for _, d in S.deferred do
			if d.co == co then
				d.cancelled = true
			end
		end
		if coroutine.status(co) == "suspended" then
			coroutine.close(co)
		end
	end
	function task.synchronize() end
	function task.desynchronize() end
	M.task = task

	-- Legacy globals.
	M.wait = function(t: number?)
		local elapsed = task.wait(math.max(tonumber(t) or 0, 1 / 30))
		return elapsed, S.now
	end
	M.delay = function(t, f)
		task.delay(t, f)
	end
	M.spawn = function(f)
		task.defer(f)
	end

	-- Signals --------------------------------------------------------------------------------
	local ConnMt = { __type = "RBXScriptConnection" }
	local ConnMethods = {}
	ConnMt.__index = function(_, k)
		local m = ConnMethods[k]
		if m then
			return m
		end
		error(tostring(k) .. " is not a valid member of RBXScriptConnection", 2)
	end
	function ConnMethods.Disconnect(c)
		if not c.Connected then
			return
		end
		c.Connected = false
		local list = c._sig._conns
		local i = table.find(list, c)
		if i then
			table.remove(list, i)
		end
	end

	local SigMt = { __type = "RBXScriptSignal" }
	local SigMethods = {}
	SigMt.__index = function(_, k)
		local m = SigMethods[k]
		if m then
			return m
		end
		error(tostring(k) .. " is not a valid member of RBXScriptSignal", 2)
	end
	SigMt.__tostring = function(s)
		return "Signal " .. s._name
	end
	function SigMethods.Connect(s, fn)
		if type(fn) ~= "function" then
			error("Attempt to connect failed: Passed value is not a function", 2)
		end
		local c = setmetatable({ Connected = true, _fn = fn, _ctx = S.current, _sig = s, _once = false }, ConnMt)
		table.insert(s._conns, c)
		if s._onConnect then
			s._onConnect(c)
		end
		return c
	end
	SigMethods.ConnectParallel = SigMethods.Connect
	function SigMethods.Once(s, fn)
		local c = SigMethods.Connect(s, fn)
		c._once = true
		return c
	end
	function SigMethods.Wait(s)
		local co, tok = S.park()
		table.insert(s._waiters, { co = co, tok = tok, ctx = S.current })
		return coroutine.yield()
	end

	function M.newSignal(name: string)
		return setmetatable({ _name = name, _conns = {}, _waiters = {}, _onConnect = false }, SigMt)
	end
	function M.isSignal(v): boolean
		return type(v) == "table" and getmetatable(v) == SigMt
	end

	-- Fires `sig` for every connection whose context passes `filter` (nil = all).
	function M.fireFiltered(sig, filter: ((ctx: any) -> boolean)?, ...)
		if #sig._conns == 0 and #sig._waiters == 0 then
			return
		end
		local args = table.pack(...)
		for _, c in table.clone(sig._conns) do
			if c.Connected and (filter == nil or filter(c._ctx)) then
				local once = c._once
				if once then
					ConnMethods.Disconnect(c)
				end
				S.defer({ conn = c, ctx = c._ctx, args = args, once = once })
			end
		end
		if #sig._waiters > 0 then
			local keep = {}
			for _, w in sig._waiters do
				if filter == nil or filter(w.ctx) then
					S.defer({ wakeCo = w.co, tok = w.tok, ctx = w.ctx, args = args })
				else
					table.insert(keep, w)
				end
			end
			sig._waiters = keep
		end
	end
	function M.fire(sig, ...)
		M.fireFiltered(sig, nil, ...)
	end
	function M.disconnectAll(sig)
		for _, c in table.clone(sig._conns) do
			ConnMethods.Disconnect(c)
		end
		sig._waiters = {}
	end
end
